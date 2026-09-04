#!/usr/bin/env python3
"""Fail closed unless the candidate is exact upstream plus reviewed release assets."""

from __future__ import annotations

from hashlib import sha256
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_COMMIT = "2ac784c51a5d0925b324efef2ba6b3446c364781"
UPSTREAM_TAG_OBJECT = "c8134f0f55b75719ac228b75a0861f2050b4e164"
ALLOWLIST = ROOT / "tools/minimal_release_provenance_allowlist.tsv"
MIGRATION_220 = ROOT / "backend/migrations/220_clear_non_grok_video_generation_config.sql"
MIGRATION_220_RAW_SHA256 = "9335aa80e464e774bbde71ce0ca847186a3555dae5bd6c9201d01bd0fd8791f9"
MIGRATION_220_RUNNER_SHA256 = "4595baeb0dab0fd05be15da4e8f0dcf9f8e7d0ca36d60d00d223fca9bef03625"
RUNTIME_PREFIXES = ("backend/", "frontend/")
ALLOWED_RUNTIME = {
    "backend/migrations/220_clear_non_grok_video_generation_config.sql",
    "backend/migrations/migration_220_contract_test.go",
}
FORBIDDEN_CUSTOM_FIELDS = (
    "openai_responses_stream_event_mode",
    "first_sse_event_ms",
)


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout.strip()


def parse_allowlist() -> dict[str, tuple[str, str]]:
    entries: dict[str, tuple[str, str]] = {}
    for line_number, raw_line in enumerate(ALLOWLIST.read_text(encoding="utf-8").splitlines(), 1):
        if not raw_line or raw_line.startswith("#"):
            continue
        fields = raw_line.split("\t")
        if len(fields) != 3 or not all(fields):
            raise SystemExit(f"invalid provenance allowlist line {line_number}")
        path, classification, reason = fields
        if path in entries:
            raise SystemExit(f"duplicate provenance allowlist path: {path}")
        entries[path] = (classification, reason)
    return entries


def strip_sql_comments(data: bytes) -> str:
    text = re.sub(r"(?m)--.*$", "", data.decode("utf-8"))
    text = re.sub(
        r"(?is)COMMENT\s+ON\s+TABLE\s+groups_video_price_backup_220\s+IS\s+'[^']*';",
        "",
        text,
    )
    return " ".join(text.split())


git("cat-file", "-e", f"{UPSTREAM_COMMIT}^{{commit}}")
tag_object = git("rev-parse", "v0.1.185")
if tag_object != UPSTREAM_TAG_OBJECT:
    raise SystemExit(f"v0.1.185 tag object = {tag_object}, want {UPSTREAM_TAG_OBJECT}")
tag_commit = git("rev-parse", "v0.1.185^{commit}")
if tag_commit != UPSTREAM_COMMIT:
    raise SystemExit(f"v0.1.185 source commit = {tag_commit}, want {UPSTREAM_COMMIT}")
merge_base = git("merge-base", "HEAD", UPSTREAM_COMMIT)
if merge_base != UPSTREAM_COMMIT:
    raise SystemExit(f"candidate does not descend directly from exact upstream: {merge_base}")
if git("rev-list", "--count", f"{UPSTREAM_COMMIT}..HEAD") != "1":
    raise SystemExit("candidate must contain exactly one reviewed fork commit above upstream v0.1.185")

allowlist = parse_allowlist()
changed = {
    line
    for line in git("diff", "--name-only", UPSTREAM_COMMIT, "--", ".").splitlines()
    if line
}
allowed = set(allowlist)
unexpected = sorted(changed - allowed)
missing = sorted(allowed - changed)
if unexpected or missing:
    details: list[str] = []
    if unexpected:
        details.append("unexpected differences:\n" + "\n".join(unexpected))
    if missing:
        details.append("allowlisted paths without a candidate difference:\n" + "\n".join(missing))
    raise SystemExit("\n".join(details))

runtime_changes = {
    path for path in changed if path.startswith(RUNTIME_PREFIXES)
}
if runtime_changes != ALLOWED_RUNTIME:
    raise SystemExit(
        "runtime-tree differences are not limited to migration 220 and its test:\n"
        + "\n".join(sorted(runtime_changes))
    )

raw = MIGRATION_220.read_bytes()
if sha256(raw).hexdigest() != MIGRATION_220_RAW_SHA256:
    raise SystemExit("migration 220 raw bytes are not the production-compatible fork copy")
if sha256(raw.strip()).hexdigest() != MIGRATION_220_RUNNER_SHA256:
    raise SystemExit("migration 220 runner checksum is not the production value")
upstream_raw = subprocess.run(
    [
        "git",
        "show",
        f"{UPSTREAM_COMMIT}:backend/migrations/220_clear_non_grok_video_generation_config.sql",
    ],
    cwd=ROOT,
    check=True,
    capture_output=True,
).stdout
if strip_sql_comments(raw) != strip_sql_comments(upstream_raw):
    raise SystemExit("migration 220 executable SQL differs from exact upstream v0.1.185")

public_tree = "\n".join(
    path.read_text(encoding="utf-8", errors="ignore")
    for root_name in ("backend", "frontend")
    for path in (ROOT / root_name).rglob("*")
    if path.is_file() and path.suffix in {".go", ".sql", ".ts", ".vue", ".json"}
)
for field in FORBIDDEN_CUSTOM_FIELDS:
    if field in public_tree:
        raise SystemExit(f"forbidden HumanWill runtime/API/UI field remains: {field}")

for forbidden_path in (
    ROOT / "backend/internal/service/openai_responses_reasoning_content_retry.go",
    ROOT / "backend/internal/service/openai_responses_reasoning_content_retry_test.go",
    ROOT / "backend/migrations/224_add_openai_responses_compatibility.sql",
):
    if forbidden_path.exists():
        raise SystemExit(f"forbidden HumanWill runtime file remains: {forbidden_path.relative_to(ROOT)}")

plugin_dir = ROOT / "plugins"
if plugin_dir.exists() and any(plugin_dir.iterdir()):
    raise SystemExit("plugin artifacts are forbidden in the release candidate")
if "/plugins/" not in (ROOT / ".dockerignore").read_text(encoding="utf-8"):
    raise SystemExit("Docker context does not fail closed on local plugin artifacts")

print(f"Exact upstream source verified: {UPSTREAM_COMMIT}")
print(f"Annotated tag object verified: {UPSTREAM_TAG_OBJECT}")
for path in sorted(changed):
    classification, reason = allowlist[path]
    print(f"ALLOW\t{path}\t{classification}\t{reason}")
print("Runtime behavior difference: migration 220 comment bytes only; executable SQL is upstream-equivalent")
