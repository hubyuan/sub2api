# HumanWill minimal Sub2API release path

This branch starts directly from upstream tag `v0.1.185`, annotated tag object
`c8134f0f55b75719ac228b75a0861f2050b4e164`, source commit
`2ac784c51a5d0925b324efef2ba6b3446c364781`.

Runtime and business behavior remain upstream. The only runtime-tree exception is
the exact migration 220 byte sequence already recorded by production at fork
commit `115317ef1f29465515b0725df69a94bd4890ec60`. Its raw SHA-256 is
`9335aa80e464e774bbde71ce0ca847186a3555dae5bd6c9201d01bd0fd8791f9`, its
trimmed migration-runner checksum is
`4595baeb0dab0fd05be15da4e8f0dcf9f8e7d0ca36d60d00d223fca9bef03625`, and
its executable SQL is identical to upstream v0.1.185. The complete difference
allowlist is machine-readable at `tools/minimal_release_provenance_allowlist.tsv`.

The historical HumanWill fields `openai_responses_stream_event_mode` and
`first_sse_event_ms` are intentionally absent from current source. Existing
database columns and migration rows are tolerated and retained. Removing
`early_event` can delay the first non-keepalive protocol event, but does not
delay model token generation; upstream buffering preserves a larger safe
failover window.

The local release gate is serial:

1. provenance, release-contract, workflow-trigger, and shell checks;
2. Go unit and integration suites;
3. frozen frontend install, lint, typecheck, full Vitest, and build;
4. pinned golangci-lint, govulncheck, gosec, and production pnpm audit policy;
5. locally compiled test binary under the isolated low-resource and
   production-shape migration/rollback audit;
6. `dev-release-preflight`, fail-closed Registry version-absence proof, and the
   one `linux/amd64` Rootless Docker release build/push;
7. immutable digest smoke, OCI identity verification, and canonical v2 bundle.

Upstream publishing jobs remain in `.github/workflows/release.yml` for upstream
provenance, but every publishing or default-branch-write job is guarded to run
only in `Wei-Shaw/sub2api`. Fork events cannot publish upstream artifacts,
create GitHub Releases, send Telegram notifications, or perform deployment.
