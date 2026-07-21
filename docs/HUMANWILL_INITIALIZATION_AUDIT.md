# HumanWill low-resource initialization audit

Audit baseline: `b8b72e1b18310c908668e79112e43c1e7c682696` on 2026-07-21. This document contains no production identifiers, credentials, data, or environment-file contents.

## Decision

The production candidate is one `linux/amd64` application container in `RUN_MODE=simple`, attached to an existing private application network. PostgreSQL and Redis instances may be reused only after a separate production authorization creates a dedicated PostgreSQL role and database and reserves a non-default Redis logical DB. The application is bound to `127.0.0.1`; no public route is part of initialization.

The application-only reference is `deploy/docker-compose.humanwill.example.yml`. Its 0.5 CPU, 512 MiB memory/swap, 128 PID and 16384 NOFILE values are candidates, not measured guarantees.

## Code facts

- `Dockerfile` builds the frontend and a static Go binary, runs Alpine as UID/GID 1000 through `su-exec`, exposes 8080, and probes `/health`. `/app/data` contains generated `config.yaml` and `.installed`; it must persist across restarts.
- `AUTO_SETUP=true` reads `DATABASE_DBNAME` and `REDIS_DB`, tests both connections, applies embedded SQL migrations, bootstraps an admin only for an empty user table, and writes configuration/lock files. Setup connects to the `postgres` maintenance database and can create the target database when its role has permission. Production should pre-create the dedicated database and use a least-privilege owner instead.
- Migrations use `schema_migrations`, checksums and a PostgreSQL advisory lock. Some embedded migrations are explicitly non-transactional. Every upgrade therefore requires a database backup and migration review; rolling back the image does not roll back the schema.
- The Redis client passes the configured DB to `go-redis`. Repository-wide search found no `FLUSHDB` or `FLUSHALL`. A logical DB isolates keys but not Redis availability, eviction policy, CPU, memory or ACL scope.
- `RUN_MODE=simple` is read by setup/config paths and disables SaaS behavior such as billing. `SIMPLE_MODE_CONFIRM` was mentioned only in README translations and was never read. The README statements were corrected; no runtime compatibility changed.
- `/health` is unauthenticated. `/v1/models`, `/v1/responses`, `/v1/chat/completions`, and `/backend-api/codex/responses` are registered compatibility paths and require application API authentication. `/openai/v1/responses` is not a registered API route at this baseline and falls through to the embedded web application; it must not be used as a NewAPI target. A request with a deliberately invalid test key safely exercises routing/authentication without contacting an upstream.
- The process handles SIGINT/SIGTERM and gives HTTP shutdown five seconds. Background runtimes are embedded in the same process; queue, monitoring, cleanup, token refresh and audit behavior depend on configuration. A single instance is the initial choice. Migration locking and Redis/DB coordination provide some multi-instance mechanisms, but HA is not approved by this initialization.
- Runtime network dependencies are PostgreSQL, Redis and configured AI/OAuth/email/payment/object-storage endpoints. Simple mode does not remove the core PostgreSQL, Redis or selected AI upstream dependencies.
- Back up the dedicated PostgreSQL database and `/app/data` before upgrades. Redis is cache/coordination state and should remain isolated; restoring Redis is not a substitute for restoring PostgreSQL. Never restore into the database or logical DB used by another application.

## Workflow inventory and fork isolation

| Workflow | Triggers | Jobs and effects | Secrets named |
| --- | --- | --- | --- |
| `backend-ci.yml` | every push and PR | macOS deploy script checks; Go unit/integration; frontend lint/typecheck/critical Vitest; golangci-lint | none |
| `security-scan.yml` | every push/PR; Monday 03:00 UTC | `govulncheck`; production dependency audit with exception check | none |
| `cla.yml` | issue comments and `pull_request_target` events | writes CLA/status/PR state only when repository is `Wei-Shaw/sub2api` | `GITHUB_TOKEN` |
| `release.yml` | `v*` pushes and manual dispatch | upstream VERSION/frontend artifacts, Docker Hub/GHCR multi/single-arch GoReleaser artifacts, GitHub Release, Docker Hub description, Telegram notification and default-branch VERSION commit | `GITHUB_TOKEN`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |
| `humanwill-release.yml` | manual dispatch only | validates a full source SHA and new SemVer, builds one `linux/amd64` image, pushes one version tag to `ghcr.io/hubyuan/sub2api`, writes digest/labels to summary | `GITHUB_TOKEN` |

Every job in upstream `release.yml` is repository-gated to `Wei-Shaw/sub2api`, including its branch-writing final job. The CLA workflow already had the same upstream-only gate. HumanWill branch/tag pushes cannot publish, deploy, create a Release, update Docker Hub, notify Telegram or modify the default branch. Only the fork-owned manual workflow can publish, and its concurrency group allows one production image workflow at a time. It never emits `latest`, `edge`, a branch tag or a GitHub Release.

## Immutable release and rollback review

Before dispatch, verify CI on the merged commit and supply its complete 40-character SHA plus a new immutable SemVer without a leading `v`. The workflow checks out and verifies that exact commit, rejects an existing registry version, builds only `linux/amd64`, and records OCI `source`, `revision`, and `version`. Copy the resulting full `image@sha256:...` from the workflow summary; production must deploy by digest.

Before production, review migrations between the currently deployed and proposed commits and take a restorable PostgreSQL backup plus `/app/data` backup. Image rollback is compatible only when the old binary supports the migrated schema. When it does not, restore the database and `/app/data` together during a separately authorized maintenance operation. Redis keys may be discarded only within the dedicated logical DB and only with explicit production authorization.

## Configuration checklist

Required application settings (values supplied outside Git): `RUN_MODE=simple`, `AUTO_SETUP=true` for the first start only, `SERVER_HOST`, `SERVER_PORT`, `DATA_DIR`, `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_USER`, `DATABASE_PASSWORD`, `DATABASE_DBNAME`, `DATABASE_SSLMODE`, `REDIS_HOST`, `REDIS_PORT`, optional `REDIS_USERNAME`, `REDIS_PASSWORD`, non-default `REDIS_DB`, optional `REDIS_ENABLE_TLS`, `JWT_SECRET`, first-start `ADMIN_EMAIL` and `ADMIN_PASSWORD`, `TZ`, and optional `SETUP_MIGRATION_TIMEOUT_SECONDS`.

After first setup, persist `/app/data`, remove first-start admin values and disable `AUTO_SETUP`. Confirm the generated config points only to the dedicated database and Redis DB without printing its contents. Secrets must come from the production secret mechanism, not Compose or Git.

NewAPI should use its existing OpenAI-compatible/Codex-capable channel support with Sub2API's internal base URL and an independently generated Sub2API API key. Validate `/v1/models`, `/v1/responses` streaming and `/v1/chat/completions` in an internal canary before adding traffic. No NewAPI or Caddy change is included here.

## Verification evidence and open gates

Static checks completed locally: workflow/Compose inspection, `docker compose ... config --no-interpolate`, release-contract validation, shell syntax, repository search for simple-mode and Redis destructive commands, and relevant Go tests. The Apple-container test is macOS-specific and remains covered by its existing macOS CI job. PR checks are authoritative for the complete upstream CI matrix.

The local development host exposed a Docker CLI but denied access to the daemon, so no local container was started and no figures were invented. `backend-ci.yml` therefore includes an isolated `low-resource-runtime` job using disposable PostgreSQL 16 and Redis 7 service containers, a dedicated non-superuser role/database and Redis DB 9. It builds the exact PR source for `linux/amd64`, starts it with the candidate limits, verifies migration/health/compatibility authentication paths/DB 0 sentinel preservation and graceful SIGTERM, and records samples in the workflow summary. CI completion is the evidence gate. An authenticated streaming peak with a local mock upstream remains deferred because this initialization has no account fixture or real upstream credential.

On an authorized isolated development runner, complete the remaining streaming measurement and recheck:

1. First-start migration completes under the candidate limits and creates migration records only in the dedicated database.
2. DB 0's sentinel survives setup, authenticated management operations and a safe simulated streaming `/v1/responses` request; Sub2API keys occur only in DB 9.
3. `/health` is 200; invalid test authentication reaches `/v1/models`, `/v1/responses`, `/v1/chat/completions` and `/backend-api/codex/responses` without upstream traffic; a local mock upstream produces valid streaming events.
4. Record peak CPU, memory and PIDs during migration, five-minute idle, a management operation and the mock stream. Accept 0.5 CPU/512 MiB/128 PIDs only if there is at least 20% headroom and no OOM, throttling-induced health failure or restart. Otherwise raise only the observed constrained limit and attach the samples to the release handoff.
5. Send SIGTERM during idle and during a mock stream; confirm exit within the orchestrator grace period and document whether the client stream drains within the application's five-second HTTP shutdown window.

Do not dispatch `humanwill-release.yml`, merge, package or deploy until the initialization PR is approved and the user gives the separate `发布 PR #X` instruction.
