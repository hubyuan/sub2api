#!/usr/bin/env python3
"""Verify the HumanWill candidate stays within the upstream provenance allowlist."""

from hashlib import sha256
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_COMMIT = "073e92d17178a1ccdb0a27017f572f10c9c7ab62"
MIGRATION_220 = ROOT / "backend/migrations/220_clear_non_grok_video_generation_config.sql"
MIGRATION_220_RAW_SHA256 = "9335aa80e464e774bbde71ce0ca847186a3555dae5bd6c9201d01bd0fd8791f9"
MIGRATION_220_RUNNER_CHECKSUM = "4595baeb0dab0fd05be15da4e8f0dcf9f8e7d0ca36d60d00d223fca9bef03625"
MIGRATION_224 = ROOT / "backend/migrations/224_add_openai_responses_compatibility.sql"
MIGRATION_224_RAW_SHA256 = "1db8fc73188ad59919b1549799fd70abfce5cc6fd252d016782366cd47dcb855"
MIGRATION_224_RUNNER_CHECKSUM = "f27a4a07e9692c9c0659797e0fb9b7e0c221959284bd27fd097b6c6b5f05bc0f"
RESPONSES_COMPAT_ALLOWLIST = ROOT / "tools/responses_compat_provenance_allowlist.txt"

ALLOWED_DIFFERENCES = {
    ".github/workflows/backend-ci.yml",
    ".github/workflows/humanwill-release.yml",
    ".github/workflows/release.yml",
    ".gitignore",
    "backend/migrations/220_clear_non_grok_video_generation_config.sql",
    "backend/migrations/migration_220_contract_test.go",
    "deploy/docker-compose.humanwill.example.yml",
    "docs/HUMANWILL_INITIALIZATION_AUDIT.md",
    "tools/check_humanwill_release.py",
    "tools/check_upstream_provenance.py",
    "tools/container_resource_sampler.py",
    "tools/mock_openai_upstream.py",
    "tools/responses_compat_provenance_allowlist.txt",
}

responses_compat_differences = {
    line.strip()
    for line in RESPONSES_COMPAT_ALLOWLIST.read_text().splitlines()
    if line.strip() and not line.lstrip().startswith("#")
}
if len(responses_compat_differences) != len(
    [line for line in RESPONSES_COMPAT_ALLOWLIST.read_text().splitlines() if line.strip()]
):
    raise SystemExit("Responses compatibility provenance allowlist contains duplicates")
ALLOWED_DIFFERENCES |= responses_compat_differences


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout


git("cat-file", "-e", f"{UPSTREAM_COMMIT}^{{commit}}")
changed = {
    line.strip()
    for line in git("diff", "--name-only", UPSTREAM_COMMIT, "--", ".").splitlines()
    if line.strip()
}
unexpected = sorted(changed - ALLOWED_DIFFERENCES)
if unexpected:
    raise SystemExit("unexpected differences from upstream v0.1.177:\n" + "\n".join(unexpected))

raw_220 = MIGRATION_220.read_bytes()
if sha256(raw_220).hexdigest() != MIGRATION_220_RAW_SHA256:
    raise SystemExit("migration 220 bytes differ from the fork main compatibility copy")
if sha256(raw_220.strip()).hexdigest() != MIGRATION_220_RUNNER_CHECKSUM:
    raise SystemExit("migration 220 runner checksum differs from production")

raw_224 = MIGRATION_224.read_bytes()
if sha256(raw_224).hexdigest() != MIGRATION_224_RAW_SHA256:
    raise SystemExit("migration 224 bytes differ from the reviewed compatibility migration")
if sha256(raw_224.strip()).hexdigest() != MIGRATION_224_RUNNER_CHECKSUM:
    raise SystemExit("migration 224 runner checksum differs from the reviewed migration")

if (ROOT / "backend/migrations/185_add_openai_responses_early_event.sql").exists():
    raise SystemExit("historical migration 185 must not be restored")

for required_path in (
    "backend/internal/service/openai_responses_reasoning_content_retry.go",
    "backend/internal/service/openai_responses_reasoning_content_retry_test.go",
    "backend/migrations/224_add_openai_responses_compatibility.sql",
):
    if not (ROOT / required_path).is_file():
        raise SystemExit(f"required Responses compatibility file is missing: {required_path}")

required_public_fields = (
    "openai_responses_stream_event_mode",
    "first_sse_event_ms",
)
public_contract = "\n".join(
    path.read_text(encoding="utf-8", errors="ignore")
    for tree in (ROOT / "backend", ROOT / "frontend")
    for path in tree.rglob("*")
    if path.is_file() and path.suffix in {".go", ".sql", ".ts", ".vue", ".json"}
)
for field in required_public_fields:
    if field not in public_contract:
        raise SystemExit(f"required Responses compatibility field is missing: {field}")

print(f"Upstream provenance verified at {UPSTREAM_COMMIT}")
print("Runtime differences: migration 220 plus reviewed Responses compatibility allowlist")
print("Known late tool-name loss is outside this candidate and is not declared fixed")
