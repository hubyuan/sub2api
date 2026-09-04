#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROLLBACK_IMAGE='ghcr.io/hubyuan/sub2api@sha256:1750a60b9e1ae8303f32366cf53c14e2ddd7fa6b6383df3c50e589f3cb3e1a32'
readonly EXPECTED_SOURCE='2ac784c51a5d0925b324efef2ba6b3446c364781'
readonly DOCKER_SOCKET='unix:///run/user/1001/docker.sock'
readonly DEV_CPU_MAX_PATH='/sys/fs/cgroup/user.slice/user-1001.slice/cpu.max'
readonly EXPECTED_DEV_CPU_MAX='200000 100000'
readonly PG_PORT=55485
readonly REDIS_PORT=56385
readonly SIMPLE_PORT=18085
readonly UPGRADE_PORT=18086
readonly MOCK_PORT=19095
readonly HISTORICAL_MIGRATION_185='185_add_openai_responses_early_event.sql'
readonly HISTORICAL_MIGRATION_185_RAW_SHA256='1db8fc73188ad59919b1549799fd70abfce5cc6fd252d016782366cd47dcb855'
readonly HISTORICAL_MIGRATION_185_RUNNER_SHA256='f27a4a07e9692c9c0659797e0fb9b7e0c221959284bd27fd097b6c6b5f05bc0f'
readonly MIGRATION_220_RUNNER_SHA256='4595baeb0dab0fd05be15da4e8f0dcf9f8e7d0ca36d60d00d223fca9bef03625'

die() {
  printf 'ISOLATED AUDIT BLOCKED: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || die "usage: $0 <absolute-candidate-binary> <absolute-evidence-directory>"
candidate_binary=$1
evidence_dir=$2
[[ ${EUID:-$(id -u)} -eq 1001 ]] || die 'must run as dev (uid 1001)'
[[ $candidate_binary == /* && -x $candidate_binary ]] || die 'candidate binary must be an absolute executable path'
[[ $evidence_dir == /* ]] || die 'evidence directory must be absolute'
[[ $(git rev-parse "$EXPECTED_SOURCE^{commit}") == "$EXPECTED_SOURCE" ]] || die 'exact upstream source is unavailable'
[[ $(git merge-base HEAD "$EXPECTED_SOURCE") == "$EXPECTED_SOURCE" ]] || die 'candidate does not descend from exact upstream source'
[[ -z $(git status --porcelain --untracked-files=all) ]] || die 'worktree must be clean'

export DOCKER_HOST=$DOCKER_SOCKET
[[ $(docker info --format '{{.DockerRootDir}}') == /data/dev/docker ]] || die 'unexpected Docker daemon'
[[ -r $DEV_CPU_MAX_PATH ]] || die 'root-owned dev CPU limit is unreadable'
dev_cpu_max=$(tr -s '[:space:]' ' ' <"$DEV_CPU_MAX_PATH")
dev_cpu_max=${dev_cpu_max% }
[[ $dev_cpu_max == "$EXPECTED_DEV_CPU_MAX" ]] ||
  die "root-owned dev CPU limit is not exactly 2 CPUs: ${dev_cpu_max:-missing}"
historical_migration_185_sql=$'ALTER TABLE api_keys\n    ADD COLUMN IF NOT EXISTS openai_responses_stream_event_mode VARCHAR(20) NOT NULL DEFAULT \'strict\';\n\nALTER TABLE usage_logs\n    ADD COLUMN IF NOT EXISTS first_sse_event_ms INTEGER NULL;'
[[ $(printf '%s\n' "$historical_migration_185_sql" | sha256sum | awk '{print $1}') == "$HISTORICAL_MIGRATION_185_RAW_SHA256" ]] ||
  die 'historical migration 185 raw fixture checksum mismatch'
[[ $(printf '%s' "$historical_migration_185_sql" | sha256sum | awk '{print $1}') == "$HISTORICAL_MIGRATION_185_RUNNER_SHA256" ]] ||
  die 'historical migration 185 runner fixture checksum mismatch'
mkdir -p "$evidence_dir"
[[ -z $(find "$evidence_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || die 'evidence directory must be empty'
printf '%s\n' "$dev_cpu_max" >"$evidence_dir/dev-user-slice-cpu.max"

run_suffix=$(date -u +%Y%m%dT%H%M%SZ)-$$
pg_container="sub2api-0185-pg-${run_suffix}"
redis_container="sub2api-0185-redis-${run_suffix}"
simple_container="sub2api-0185-simple-${run_suffix}"
upgrade_container="sub2api-0185-upgrade-${run_suffix}"
pg_volume="sub2api-0185-pg-${run_suffix}"
redis_volume="sub2api-0185-redis-${run_suffix}"
simple_volume="sub2api-0185-simple-${run_suffix}"
upgrade_volume="sub2api-0185-upgrade-${run_suffix}"
mock_pid=''
sampler_pid=''

cleanup() {
  if [[ -n $sampler_pid ]] && kill -0 "$sampler_pid" 2>/dev/null; then
    kill -TERM "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
  fi
  if [[ -n $mock_pid ]] && kill -0 "$mock_pid" 2>/dev/null; then
    kill -TERM "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
  fi
  docker rm -f "$simple_container" "$upgrade_container" "$pg_container" "$redis_container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for port in "$PG_PORT" "$REDIS_PORT" "$SIMPLE_PORT" "$UPGRADE_PORT" "$MOCK_PORT"; do
  if ss -Hln "sport = :$port" | grep -q .; then
    die "required loopback port is occupied: $port"
  fi
done

for volume in "$pg_volume" "$redis_volume" "$simple_volume" "$upgrade_volume"; do
  docker volume create "$volume" >/dev/null
done
printf '%s\n' "$pg_volume" "$redis_volume" "$simple_volume" "$upgrade_volume" >"$evidence_dir/preserved-dev-volumes.txt"

docker run -d --name "$pg_container" \
  --memory 1g --memory-swap 1g --pids-limit 256 \
  --ulimit nofile=32768:32768 \
  --volume "$pg_volume":/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=audit-only-postgres-password \
  -p "127.0.0.1:${PG_PORT}:5432" postgres:16-alpine >/dev/null
docker run -d --name "$redis_container" \
  --memory 256m --memory-swap 256m --pids-limit 128 \
  --ulimit nofile=16384:16384 \
  --volume "$redis_volume":/data \
  -p "127.0.0.1:${REDIS_PORT}:6379" redis:7-alpine >/dev/null

for attempt in $(seq 1 90); do
  pg_ready=false
  redis_ready=false
  docker exec "$pg_container" pg_isready -U postgres >/dev/null 2>&1 && pg_ready=true
  docker exec "$redis_container" redis-cli ping >/dev/null 2>&1 && redis_ready=true
  if [[ $pg_ready == true && $redis_ready == true ]]; then break; fi
  [[ $attempt -lt 90 ]] || die 'isolated PostgreSQL/Redis did not become ready'
  sleep 1
done

docker exec "$redis_container" redis-cli -n 0 SET minimal-release:audit:sentinel untouched >/dev/null
for database in sub2api_simple sub2api_upgrade; do
  role=${database}
  password="audit-only-${database}-password"
  docker exec "$pg_container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE ROLE ${role} LOGIN PASSWORD '${password}'" >/dev/null
  docker exec "$pg_container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE ${database} OWNER ${role}" >/dev/null
done

python3 tools/mock_openai_upstream.py --port "$MOCK_PORT" \
  --state-file "$evidence_dir/mock-state.txt" >"$evidence_dir/mock.log" 2>&1 &
mock_pid=$!
for attempt in $(seq 1 30); do
  if curl --silent --fail "http://127.0.0.1:${MOCK_PORT}/health" >/dev/null; then break; fi
  [[ $attempt -lt 30 ]] || die 'loopback mock did not become ready'
  sleep 1
done

create_candidate_container() {
  local name=$1
  local volume=$2
  local database=$3
  local redis_db=$4
  local port=$5
  local auto_setup=$6
  docker create --name "$name" --network host \
    --memory 2g --memory-swap 2g --pids-limit 512 \
    --ulimit nofile=65536:65536 \
    --volume "$volume":/app/data \
    --mount "type=bind,src=${candidate_binary},dst=/app/sub2api,readonly" \
    --mount "type=bind,src=$(pwd)/backend/resources,dst=/app/resources,readonly" \
    -e RUN_MODE=simple -e AUTO_SETUP="$auto_setup" -e DATA_DIR=/app/data \
    -e TZ=Asia/Shanghai \
    -e SERVER_HOST=127.0.0.1 -e SERVER_PORT="$port" \
    -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT="$PG_PORT" \
    -e DATABASE_USER="$database" -e DATABASE_PASSWORD="audit-only-${database}-password" \
    -e DATABASE_DBNAME="$database" -e DATABASE_SSLMODE=disable \
    -e REDIS_HOST=127.0.0.1 -e REDIS_PORT="$REDIS_PORT" -e REDIS_DB="$redis_db" \
    -e ADMIN_EMAIL="${database}@example.invalid" -e ADMIN_PASSWORD=audit-only-admin-password \
    -e JWT_SECRET=audit-only-jwt-secret-at-least-32-characters \
    "$ROLLBACK_IMAGE" >/dev/null
}

create_rollback_container() {
  local name=$1
  local volume=$2
  local database=$3
  local redis_db=$4
  local port=$5
  local auto_setup=$6
  docker create --name "$name" --network host \
    --memory 2g --memory-swap 2g --pids-limit 512 \
    --ulimit nofile=65536:65536 \
    --volume "$volume":/app/data \
    -e RUN_MODE=simple -e AUTO_SETUP="$auto_setup" -e DATA_DIR=/app/data \
    -e TZ=Asia/Shanghai \
    -e SERVER_HOST=127.0.0.1 -e SERVER_PORT="$port" \
    -e DATABASE_HOST=127.0.0.1 -e DATABASE_PORT="$PG_PORT" \
    -e DATABASE_USER="$database" -e DATABASE_PASSWORD="audit-only-${database}-password" \
    -e DATABASE_DBNAME="$database" -e DATABASE_SSLMODE=disable \
    -e REDIS_HOST=127.0.0.1 -e REDIS_PORT="$REDIS_PORT" -e REDIS_DB="$redis_db" \
    -e ADMIN_EMAIL="${database}@example.invalid" -e ADMIN_PASSWORD=audit-only-admin-password \
    -e JWT_SECRET=audit-only-jwt-secret-at-least-32-characters \
    "$ROLLBACK_IMAGE" >/dev/null
}

wait_for_health() {
  local name=$1
  local port=$2
  for attempt in $(seq 1 120); do
    if curl --silent --fail "http://127.0.0.1:${port}/health" >/dev/null; then return; fi
    if [[ $attempt -eq 120 ]]; then
      docker logs --tail=120 "$name" >&2 || true
      return 1
    fi
    sleep 1
  done
}

start_sampler() {
  local name=$1
  local output=$2
  local duration=${3:-0}
  if [[ $duration -gt 0 ]]; then
    python3 tools/container_resource_sampler.py --container "$name" \
      --output "$output" --interval 5 --duration "$duration" &
  else
    python3 tools/container_resource_sampler.py --container "$name" \
      --output "$output" --interval 1 &
  fi
  sampler_pid=$!
}

stop_sampler() {
  local output=$1
  kill -TERM "$sampler_pid"
  wait "$sampler_pid"
  sampler_pid=''
  [[ $(jq -r '.sample_count > 0' "$output") == true ]]
}

configure_mock_account() {
  local port=$1
  local email=$2
  local key_name=$3
  local custom_key=$4
  local login_response admin_token groups_response openai_group_id account_payload key_payload key_response
  login_response=$(curl --silent --show-error --fail-with-body \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"audit-only-admin-password\"}" \
    "http://127.0.0.1:${port}/api/v1/auth/login")
  admin_token=$(jq -er '.data.access_token' <<<"$login_response")
  curl --silent --show-error --fail-with-body \
    -H "Authorization: Bearer ${admin_token}" -H 'Content-Type: application/json' \
    -d '{"phrase":"I have read, understood, and agree to the Sub2API Deployment and Operation Compliance Commitment","language":"en"}' \
    "http://127.0.0.1:${port}/api/v1/admin/compliance/accept" \
    | jq -e '.code == 0 and .data.required == false' >/dev/null
  groups_response=$(curl --silent --show-error --fail-with-body \
    -H "Authorization: Bearer ${admin_token}" \
    "http://127.0.0.1:${port}/api/v1/groups/available")
  openai_group_id=$(jq -er 'first(.data[] | select(.platform == "openai")).id' <<<"$groups_response")
  account_payload=$(jq -nc --argjson group_id "$openai_group_id" --arg port "$MOCK_PORT" \
    '{name:"mock-openai",platform:"openai",type:"apikey",credentials:{api_key:"audit-only-upstream-key",base_url:("http://127.0.0.1:" + $port + "/v1")},concurrency:1,priority:1,group_ids:[$group_id]}')
  curl --silent --show-error --fail-with-body \
    -H "Authorization: Bearer ${admin_token}" -H 'Content-Type: application/json' \
    -d "$account_payload" "http://127.0.0.1:${port}/api/v1/admin/accounts" \
    | jq -e '.code == 0 and .data.id > 0' >/dev/null
  key_payload=$(jq -nc --argjson group_id "$openai_group_id" --arg name "$key_name" --arg key "$custom_key" \
    '{name:$name,custom_key:$key,group_id:$group_id}')
  key_response=$(curl --silent --show-error --fail-with-body \
    -H "Authorization: Bearer ${admin_token}" -H 'Content-Type: application/json' \
    -d "$key_payload" "http://127.0.0.1:${port}/api/v1/keys")
  [[ $(jq -er '.data.key' <<<"$key_response") == "$custom_key" ]]
}

request_stream() {
  local port=$1
  local key=$2
  local route=$3
  local output=$4
  local status=''
  for attempt in $(seq 1 20); do
    status=$(curl --silent --show-error --no-buffer --max-time 30 \
      --output "$output" --write-out '%{http_code}' \
      -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' \
      -d '{"model":"gpt-5.4","input":"AUDIT_FAST_STREAM","stream":true}' \
      "http://127.0.0.1:${port}${route}" || true)
    if [[ $status == 200 ]]; then break; fi
    [[ $attempt -lt 20 ]] || die "stream request failed: route=${route} status=${status}"
    sleep 1
  done
  grep -q 'response.created' "$output"
  grep -q 'response.output_text.delta' "$output"
  grep -q 'response.completed' "$output"
  grep -q 'audit-ok' "$output"
}

docker pull "$ROLLBACK_IMAGE" >/dev/null

# Fresh-install, low-resource simple-mode audit using the locally compiled candidate binary.
create_candidate_container "$simple_container" "$simple_volume" sub2api_simple 9 "$SIMPLE_PORT" true
[[ $(docker inspect --format '{{.HostConfig.Memory}}' "$simple_container") == 2147483648 ]]
[[ $(docker inspect --format '{{.HostConfig.MemorySwap}}' "$simple_container") == 2147483648 ]]
[[ $(docker inspect --format '{{.HostConfig.PidsLimit}}' "$simple_container") == 512 ]]
[[ $(docker inspect --format '{{range .HostConfig.Ulimits}}{{if eq .Name "nofile"}}{{.Soft}}:{{.Hard}}{{end}}{{end}}' "$simple_container") == 65536:65536 ]]
start_sampler "$simple_container" "$evidence_dir/simple-startup-resources.json"
docker start "$simple_container" >/dev/null
wait_for_health "$simple_container" "$SIMPLE_PORT"
sleep 2
stop_sampler "$evidence_dir/simple-startup-resources.json"
configure_mock_account "$SIMPLE_PORT" sub2api_simple@example.invalid simple-audit sk-audit-only-simple-key
start_sampler "$simple_container" "$evidence_dir/simple-streaming-resources.json"
request_stream "$SIMPLE_PORT" sk-audit-only-simple-key /v1/responses "$evidence_dir/simple-responses.sse"
request_stream "$SIMPLE_PORT" sk-audit-only-simple-key /backend-api/codex/responses "$evidence_dir/simple-codex-responses.sse"
sleep 2
stop_sampler "$evidence_dir/simple-streaming-resources.json"
for attempt in $(seq 1 30); do
  simple_usage_count=$(docker exec "$pg_container" psql -U postgres -d sub2api_simple -tAc 'SELECT COUNT(*) FROM usage_logs' | tr -d '\r ')
  if [[ $simple_usage_count -ge 2 ]]; then break; fi
  [[ $attempt -lt 30 ]] || die 'fresh candidate did not write usage rows'
  sleep 1
done
[[ $(docker exec "$redis_container" redis-cli -n 0 GET minimal-release:audit:sentinel | tr -d '\r') == untouched ]]
[[ $(docker exec "$redis_container" redis-cli -n 0 DBSIZE | tr -d '\r') == 1 ]]
[[ $(docker exec "$redis_container" redis-cli -n 9 DBSIZE | tr -d '\r') -gt 0 ]]
start_sampler "$simple_container" "$evidence_dir/simple-idle-resources.json" 300
wait "$sampler_pid"
sampler_pid=''
[[ $(jq -r '.sample_count > 0' "$evidence_dir/simple-idle-resources.json") == true ]]
docker stop --time 10 "$simple_container" >/dev/null
[[ $(docker inspect --format '{{.State.ExitCode}}' "$simple_container") == 0 ]]
docker start "$simple_container" >/dev/null
wait_for_health "$simple_container" "$SIMPLE_PORT"
docker stop --time 10 "$simple_container" >/dev/null
docker rm "$simple_container" >/dev/null

# Production-shape fixture: initialize with the exact rollback image and retain its custom rows/columns.
create_rollback_container "$upgrade_container" "$upgrade_volume" sub2api_upgrade 10 "$UPGRADE_PORT" true
docker start "$upgrade_container" >/dev/null
wait_for_health "$upgrade_container" "$UPGRADE_PORT"
configure_mock_account "$UPGRADE_PORT" sub2api_upgrade@example.invalid upgrade-audit sk-audit-only-upgrade-key
request_stream "$UPGRADE_PORT" sk-audit-only-upgrade-key /v1/responses "$evidence_dir/rollback-before-upgrade-responses.sse"
docker stop --time 10 "$upgrade_container" >/dev/null
docker rm "$upgrade_container" >/dev/null

# A fresh install of the current rollback image records only the later
# migration 224 copy of this SQL. Production also retains the earlier 185 row
# from its actual upgrade history, so add that metadata-only fixture without
# restoring the removed migration file or executing its SQL again.
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM schema_migrations WHERE filename='${HISTORICAL_MIGRATION_185}'" | tr -d '\r ') == 0 ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM schema_migrations WHERE filename='224_add_openai_responses_compatibility.sql' AND checksum='${HISTORICAL_MIGRATION_185_RUNNER_SHA256}'" | tr -d '\r ') == 1 ]]
docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -v ON_ERROR_STOP=1 \
  -c "INSERT INTO schema_migrations (filename, checksum) VALUES ('${HISTORICAL_MIGRATION_185}', '${HISTORICAL_MIGRATION_185_RUNNER_SHA256}')" >/dev/null
historical_rows=$(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM schema_migrations WHERE filename IN ('${HISTORICAL_MIGRATION_185}','224_add_openai_responses_compatibility.sql') AND checksum='${HISTORICAL_MIGRATION_185_RUNNER_SHA256}'" | tr -d '\r ')
[[ $historical_rows == 2 ]]
historical_columns=$(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND (table_name,column_name) IN (('api_keys','openai_responses_stream_event_mode'),('usage_logs','first_sse_event_ms'))" | tr -d '\r ')
[[ $historical_columns == 2 ]]
actual_220=$(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT checksum FROM schema_migrations WHERE filename='220_clear_non_grok_video_generation_config.sql'" | tr -d '\r ')
[[ $actual_220 == "$MIGRATION_220_RUNNER_SHA256" ]]
prior_migration_count=$(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc 'SELECT COUNT(*) FROM schema_migrations' | tr -d '\r ')
fingerprint_account_id=$(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -qAtc \
  "INSERT INTO accounts(name,platform,type,credentials,extra,concurrency,priority,status) VALUES ('audit-fingerprint','openai','oauth','{}'::jsonb,'{\"codex_fingerprint_mode\":\"device\",\"codex_fingerprint_seed\":\"\"}'::jsonb,1,50,'disabled') RETURNING id" | tr -d '\r ')
[[ $fingerprint_account_id =~ ^[0-9]+$ ]]

# Candidate applies every upstream migration through 231 and tolerates historical extra state.
create_candidate_container "$upgrade_container" "$upgrade_volume" sub2api_upgrade 10 "$UPGRADE_PORT" false
docker start "$upgrade_container" >/dev/null
wait_for_health "$upgrade_container" "$UPGRADE_PORT"
request_stream "$UPGRADE_PORT" sk-audit-only-upgrade-key /v1/responses "$evidence_dir/candidate-after-upgrade-responses.sse"
docker stop --time 10 "$upgrade_container" >/dev/null

expected_new_migrations=(
  224_user_platform_quotas_add_cn_providers.sql
  225_backfill_codex_fingerprint_seed.sql
  225_channel_model_time_pricing.sql
  226_add_usage_log_effective_model_indexes_notx.sql
  226_channel_monitor_quota_mode.sql
  227_composite_routes_add_cn_providers.sql
  228_channel_pricing_multipliers.sql
  229_plugins.sql
  230_plugin_artifacts.sql
  231_add_usage_log_native_compaction_v2.sql
  231_add_usage_log_requested_reasoning_effort.sql
  231_user_restrict_public_groups.sql
)
for migration in "${expected_new_migrations[@]}"; do
  [[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
    "SELECT COUNT(*) FROM schema_migrations WHERE filename='${migration}'" | tr -d '\r ') == 1 ]]
done
after_migration_count=$(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc 'SELECT COUNT(*) FROM schema_migrations' | tr -d '\r ')
[[ $after_migration_count -eq $((prior_migration_count + ${#expected_new_migrations[@]})) ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM pg_indexes WHERE schemaname='public' AND indexname IN ('idx_usage_logs_effective_requested_model_created','idx_usage_logs_effective_upstream_model_created')" | tr -d '\r ') == 2 ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE c.relname IN ('idx_usage_logs_effective_requested_model_created','idx_usage_logs_effective_upstream_model_created') AND i.indisvalid AND i.indisready" | tr -d '\r ') == 2 ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND (table_name,column_name) IN (('channel_model_pricing','time_pricing'),('channel_monitors','check_mode'),('channel_monitors','account_id'),('channel_monitor_histories','quota'),('channel_model_pricing','fast_multiplier'),('channel_model_pricing','flex_multiplier'),('channel_pricing_intervals','input_multiplier'),('channel_pricing_intervals','output_multiplier'),('channel_pricing_intervals','cache_write_multiplier'),('channel_pricing_intervals','cache_read_multiplier'),('sub2api_plugin_installations','artifact_data'),('usage_logs','native_compaction_v2'),('usage_logs','requested_reasoning_effort'),('users','restrict_public_groups'))" | tr -d '\r ') == 14 ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM pg_constraint WHERE conname IN ('channel_model_pricing_fast_multiplier_positive','channel_model_pricing_flex_multiplier_positive','channel_pricing_intervals_input_multiplier_positive','channel_pricing_intervals_output_multiplier_positive','channel_pricing_intervals_cache_write_multiplier_positive','channel_pricing_intervals_cache_read_multiplier_positive')" | tr -d '\r ') == 6 ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM pg_indexes WHERE schemaname='public' AND indexname IN ('idx_channel_monitors_account_id','idx_sub2api_plugin_bindings_plugin_id','idx_sub2api_plugin_bindings_enabled_scope','idx_sub2api_plugin_bindings_one_enabled_scope')" | tr -d '\r ') == 4 ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT column_default IN ('false','false::boolean') FROM information_schema.columns WHERE table_schema='public' AND table_name='usage_logs' AND column_name='native_compaction_v2'" | tr -d '\r ') == t ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT column_default IS NULL AND is_nullable='YES' FROM information_schema.columns WHERE table_schema='public' AND table_name='usage_logs' AND column_name='requested_reasoning_effort'" | tr -d '\r ') == t ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT column_default IN ('false','false::boolean') FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='restrict_public_groups'" | tr -d '\r ') == t ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COALESCE((SELECT value FROM settings WHERE key='channel_monitor_show_quota'),'false')" | tr -d '\r ') == false ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COALESCE((SELECT value FROM settings WHERE key='plugin_management_enabled'),'false')" | tr -d '\r ') == false ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM pg_constraint WHERE conname IN ('user_platform_quotas_platform_check','channel_monitors_provider_check','channel_monitor_request_templates_provider_check','composite_model_routes_target_platform_check') AND pg_get_constraintdef(oid) LIKE '%kimi%' AND pg_get_constraintdef(oid) LIKE '%zhipu%' AND pg_get_constraintdef(oid) LIKE '%deepseek%'" | tr -d '\r ') == 4 ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  'SELECT COUNT(*) FROM sub2api_plugin_installations' | tr -d '\r ') == 0 ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  'SELECT COUNT(*) FROM sub2api_plugin_bindings' | tr -d '\r ') == 0 ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT COUNT(*) FROM sub2api_plugin_installations WHERE state <> 'disabled' OR artifact_data IS NOT NULL" | tr -d '\r ') == 0 ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  'SELECT COUNT(*) FROM sub2api_plugin_bindings WHERE enabled' | tr -d '\r ') == 0 ]]
fingerprint_seed=$(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT extra->>'codex_fingerprint_seed' FROM accounts WHERE id=${fingerprint_account_id}" | tr -d '\r ')
[[ $fingerprint_seed =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
[[ $fingerprint_seed != 00000000-0000-0000-0000-000000000000 ]]

# A second candidate startup is idempotent and preserves the seed and migration rows.
docker start "$upgrade_container" >/dev/null
wait_for_health "$upgrade_container" "$UPGRADE_PORT"
docker stop --time 10 "$upgrade_container" >/dev/null
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc 'SELECT COUNT(*) FROM schema_migrations' | tr -d '\r ') == "$after_migration_count" ]]
[[ $(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc \
  "SELECT extra->>'codex_fingerprint_seed' FROM accounts WHERE id=${fingerprint_account_id}" | tr -d '\r ') == "$fingerprint_seed" ]]
docker rm "$upgrade_container" >/dev/null

# Exact pre-deploy image remains application-compatible with the post-migration schema.
create_rollback_container "$upgrade_container" "$upgrade_volume" sub2api_upgrade 10 "$UPGRADE_PORT" false
docker start "$upgrade_container" >/dev/null
wait_for_health "$upgrade_container" "$UPGRADE_PORT"
rollback_login=$(curl --silent --show-error --fail-with-body \
  -H 'Content-Type: application/json' \
  -d '{"email":"sub2api_upgrade@example.invalid","password":"audit-only-admin-password"}' \
  "http://127.0.0.1:${UPGRADE_PORT}/api/v1/auth/login")
jq -e '.data.access_token | strings | length > 0' <<<"$rollback_login" >/dev/null
usage_before=$(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc 'SELECT COUNT(*) FROM usage_logs' | tr -d '\r ')
request_stream "$UPGRADE_PORT" sk-audit-only-upgrade-key /v1/responses "$evidence_dir/rollback-after-upgrade-responses.sse"
for attempt in $(seq 1 30); do
  usage_after=$(docker exec "$pg_container" psql -U postgres -d sub2api_upgrade -tAc 'SELECT COUNT(*) FROM usage_logs' | tr -d '\r ')
  if [[ $usage_after -gt $usage_before ]]; then break; fi
  [[ $attempt -lt 30 ]] || die 'rollback image did not write usage on post-migration schema'
  sleep 1
done
docker stop --time 10 "$upgrade_container" >/dev/null
[[ $(docker inspect --format '{{.State.ExitCode}}' "$upgrade_container") == 0 ]]

jq -n \
  --arg source_head "$(git rev-parse HEAD)" \
  --arg candidate_binary_sha256 "$(sha256sum "$candidate_binary" | awk '{print $1}')" \
  --arg rollback_image "$ROLLBACK_IMAGE" \
  --arg historical_migration_185_checksum "$HISTORICAL_MIGRATION_185_RUNNER_SHA256" \
  --argjson simple_usage_rows "$simple_usage_count" \
  --argjson historical_custom_rows "$historical_rows" \
  --argjson historical_custom_columns "$historical_columns" \
  --arg migration_220_checksum "$actual_220" \
  --argjson migrations_before "$prior_migration_count" \
  --argjson migrations_after "$after_migration_count" \
  --argjson new_migrations "${#expected_new_migrations[@]}" \
  '{source_head:$source_head,candidate_binary_sha256:$candidate_binary_sha256,rollback_image:$rollback_image,postgres:"16-alpine",redis:"7-alpine",candidate_limits:{cpus:2,cpu_enforcement:"inherited_root_owned_user_slice",memory_bytes:2147483648,memory_swap_bytes:2147483648,pids:512,nofile:65536},simple_usage_rows:$simple_usage_rows,historical_custom_rows:$historical_custom_rows,historical_custom_columns:$historical_custom_columns,historical_migration_185_fixture_seeded:true,historical_migration_185_checksum:$historical_migration_185_checksum,migration_220_checksum:$migration_220_checksum,migrations_before:$migrations_before,migrations_after:$migrations_after,new_migrations:$new_migrations,fingerprint_seed_valid:true,fingerprint_seed_idempotent:true,nontransactional_indexes_valid:true,migration_schema_defaults_valid:true,plugins_enabled:false,plugin_installations:0,plugin_bindings:0,rollback_health:true,rollback_authentication:true,rollback_streaming_responses:true,rollback_usage_write:true,data_restore_required:false}' \
  >"$evidence_dir/summary.json"

printf 'ISOLATED RELEASE AUDIT PASSED\n'
printf 'evidence=%s\n' "$evidence_dir"
printf 'preserved_dev_volumes=%s,%s,%s,%s\n' "$pg_volume" "$redis_volume" "$simple_volume" "$upgrade_volume"
