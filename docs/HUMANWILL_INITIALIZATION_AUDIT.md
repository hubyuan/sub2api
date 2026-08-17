# HumanWill low-resource initialization audit

Audit baseline: upstream `v0.1.177` commit `073e92d17178a1ccdb0a27017f572f10c9c7ab62` on 2026-08-17. This document contains no production credentials, data, or environment-file contents.

## Decision

The production candidate is one `linux/amd64` application container in `RUN_MODE=simple`, attached to an existing private application network. PostgreSQL and Redis instances may be reused only after a separate production authorization creates a dedicated PostgreSQL role and database and reserves a non-default Redis logical DB. The application is bound to `127.0.0.1`; no public route is part of initialization.

The application-only reference is `deploy/docker-compose.humanwill.example.yml`. Its production-candidate ceilings are 2 vCPU, 2 GiB memory, 2 GiB memory-swap, 512 PIDs and 65536 NOFILE. These are enforced limits, not reservations or measured usage guarantees. The smaller 0.5 vCPU, 512 MiB memory/swap, 128 PIDs and 16384 NOFILE profile exists only as a CI minimum smoke test and is not a production default.

## Code facts

- `Dockerfile` builds the frontend and a static Go binary, runs Alpine as UID/GID 1000 through `su-exec`, exposes 8080, and probes `/health`. `/app/data` contains generated `config.yaml` and `.installed`; it must persist across restarts.
- `AUTO_SETUP=true` reads `DATABASE_DBNAME` and `REDIS_DB`, tests both connections, applies embedded SQL migrations, bootstraps an admin only for an empty user table, and writes configuration/lock files. Setup connects to the `postgres` maintenance database and can create the target database when its role has permission. Production should pre-create the dedicated database and use a least-privilege owner instead.
- Migrations use `schema_migrations`, checksums and a PostgreSQL advisory lock. Some embedded migrations are explicitly non-transactional. Every upgrade therefore requires a database backup and migration review; rolling back the image does not roll back the schema.
- The candidate keeps the exact fork `main` bytes of migration 220 (runner checksum `4595baeb0dab0fd05be15da4e8f0dcf9f8e7d0ca36d60d00d223fca9bef03625`) and otherwise matches upstream runtime sources. The removed fork migration 185 may remain as an extra historical row and nullable columns. Migrations 221-223 add group pricing and timezone-aware daily usage rollups without rewriting earlier migration rows.
- The Redis client passes the configured DB to `go-redis`. Repository-wide search found no `FLUSHDB` or `FLUSHALL`. A logical DB isolates keys but not Redis availability, eviction policy, CPU, memory or ACL scope.
- `RUN_MODE=simple` is read by setup/config paths and disables SaaS behavior such as billing. `SIMPLE_MODE_CONFIRM` was mentioned only in README translations and was never read. The README statements were corrected; no runtime compatibility changed.
- `/health` is unauthenticated. `/v1/models`, `/v1/responses`, `/v1/chat/completions`, and `/backend-api/codex/responses` are registered compatibility paths and require application API authentication. `/openai/v1/responses` is not a registered API route at this baseline and falls through to the embedded web application; it must not be used as a NewAPI target. A request with a deliberately invalid test key safely exercises routing/authentication without contacting an upstream.
- The process handles SIGINT/SIGTERM and gives HTTP shutdown five seconds. Background runtimes are embedded in the same process; queue, monitoring, cleanup, token refresh and audit behavior depend on configuration. A single instance is the initial choice. Migration locking and Redis/DB coordination provide some multi-instance mechanisms, but HA is not approved by this initialization.
- Runtime network dependencies are PostgreSQL, Redis and configured AI/OAuth/email/payment/object-storage endpoints. Simple mode does not remove the core PostgreSQL, Redis or selected AI upstream dependencies.
- Back up the dedicated PostgreSQL database and `/app/data` before upgrades. Redis is cache/coordination state and should remain isolated; restoring Redis is not a substitute for restoring PostgreSQL. Never restore into the database or logical DB used by another application.

## Workflow inventory and fork isolation

| Workflow | Triggers | Jobs and effects | Secrets named |
| --- | --- | --- | --- |
| `backend-ci.yml` | every push and PR | release/Compose contracts; disposable PostgreSQL/Redis minimum and production-candidate runtime audits with loopback mock streaming; macOS deploy script checks; Go unit/integration; frontend lint/typecheck/critical Vitest; golangci-lint | none |
| `security-scan.yml` | every push/PR; Monday 03:00 UTC | `govulncheck`; production dependency audit with exception check | none |
| `cla.yml` | issue comments and `pull_request_target` events | writes CLA/status/PR state only when repository is `Wei-Shaw/sub2api` | `GITHUB_TOKEN` |
| `release.yml` | `v*` pushes and manual dispatch | upstream VERSION/frontend artifacts, Docker Hub/GHCR multi/single-arch GoReleaser artifacts, GitHub Release, Docker Hub description, Telegram notification and default-branch VERSION commit | `GITHUB_TOKEN`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |
| `humanwill-release.yml` | manual dispatch only | validates a full merged source SHA, successful post-merge CI/security and a new SemVer; builds one `linux/amd64` image, pushes one version tag to `ghcr.io/hubyuan/sub2api`, writes digest/labels to summary | `GITHUB_TOKEN` |

Every job in upstream `release.yml` is repository-gated to `Wei-Shaw/sub2api`, including its branch-writing final job. The CLA workflow already had the same upstream-only gate. HumanWill branch/tag pushes cannot publish, deploy, create a Release, update Docker Hub, notify Telegram or modify the default branch. Only the fork-owned manual workflow can publish, and its concurrency group allows one production image workflow at a time. It never emits `latest`, `edge`, a branch tag or a GitHub Release.

## Immutable release and rollback review

Before dispatch, supply the complete merged `main` SHA and the authorized immutable SemVer without a leading `v`. The workflow checks out that exact commit, verifies ancestry on `origin/main`, requires successful `push` runs of both `CI` and `Security Scan` for the same SHA, rejects an existing registry version, builds only `linux/amd64`, and records OCI `source`, `revision`, and `version`. The release contract exercises merged/unmerged ancestry and checks these fail-closed workflow gates. Copy the resulting full `image@sha256:...` from the workflow summary; production must deploy by digest.

Before production, review migrations between the currently deployed and proposed commits and take a restorable PostgreSQL backup plus `/app/data` backup. Image rollback is compatible only when the old binary supports the migrated schema. When it does not, restore the database and `/app/data` together during a separately authorized maintenance operation. Redis keys may be discarded only within the dedicated logical DB and only with explicit production authorization.

## Configuration checklist

Required application settings (values supplied outside Git): `RUN_MODE=simple`, `AUTO_SETUP=true` for the first start only, `SERVER_HOST`, `SERVER_PORT`, `DATA_DIR`, `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_DBNAME`, `DATABASE_SSLMODE`, `REDIS_HOST`, `REDIS_PORT`, optional `REDIS_USERNAME`, `REDIS_PASSWORD`, non-default `REDIS_DB`, optional `REDIS_ENABLE_TLS`, `JWT_SECRET`, first-start `ADMIN_EMAIL` and `ADMIN_PASSWORD`, `TZ`, and optional `SETUP_MIGRATION_TIMEOUT_SECONDS`.

After first setup, persist `/app/data`, remove first-start admin values and disable `AUTO_SETUP`. Confirm the generated config points only to the dedicated database and Redis DB without printing its contents. Secrets must come from the production secret mechanism, not Compose or Git.

NewAPI should use its existing OpenAI-compatible/Codex-capable channel support with Sub2API's internal base URL and an independently generated Sub2API API key. Validate `/v1/models`, `/v1/responses` streaming and `/v1/chat/completions` in an internal canary before adding traffic. No NewAPI or Caddy change is included here.

## Verification evidence and open gates

Static checks completed locally: workflow/Compose inspection, `docker compose ... config --no-interpolate`, release-contract validation, shell syntax, repository search for simple-mode and Redis destructive commands, and relevant Go tests. The Apple-container test is macOS-specific and remains covered by its existing macOS CI job. PR checks are authoritative for the complete upstream CI matrix.

The local development host exposed a Docker CLI but denied access to the daemon, so no local container was started and no figures were invented. `backend-ci.yml` therefore contains the authoritative isolated `low-resource-runtime` audit. It uses disposable PostgreSQL 16 and Redis 7 service containers, creates a dedicated non-superuser role/database, reserves Redis DB 9, and builds the exact PR source for `linux/amd64`.

The migration audit initializes a sanitized production-shape database with the exact rollback image `ghcr.io/hubyuan/sub2api@sha256:dcf36d1d00db16355e85ba1c50163bc02f6054bfef9bcc59fa876c34d5f0aa73`. It asserts the extra historical 185 row and production-compatible 220 checksum, applies 221-223, compares every prior migration row byte-for-byte, repeats startup, verifies `America/New_York` historical aggregation and watermark publication, then starts the rollback image against the forward schema. Rollback must pass health, login, authenticated streaming, usage insertion and retained insert/update/delete rollup-trigger checks.

The resource audit runs the candidate at the production limits and verifies Docker's effective NanoCPUs, memory, memory-swap, PID and NOFILE values. Through normal application APIs it logs in as the disposable admin, discovers the simple-mode OpenAI group, creates an OpenAI API-key account pointed only at a Python server bound to runner loopback, and creates an application API key. That key must receive valid SSE terminal events from both authenticated `/v1/responses` and `/backend-api/codex/responses`; `/openai/v1/responses` remains intentionally unused because it is not registered.

The audit retains samples and reports CPU, memory and PID peaks for migration/startup, five minutes of idle, management operations, authenticated streaming and stream-active shutdown. It also asserts that the DB 0 sentinel is the only DB 0 key, DB 9 contains application keys, every other checked logical DB is empty, and migrations exist only in the dedicated PostgreSQL database. Idle SIGTERM and stream-active SIGTERM must both produce exit code 0 within Docker's grace period; the summary records whether the slow client stream completed or was interrupted by the application's five-second HTTP shutdown window. Finally, the already-initialized application is restarted under 0.5 vCPU, 512 MiB memory/swap, 128 PIDs and 16384 NOFILE solely as a minimum smoke test. The latest-head CI summary and logs are the measurement evidence gate.

Do not dispatch `humanwill-release.yml`, merge, package or deploy until the compatibility PR is approved and the user gives the separate `发布 PR #X` instruction.
