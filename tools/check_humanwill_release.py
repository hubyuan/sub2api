#!/usr/bin/env python3
"""Fail CI when the fork release path loses an immutability invariant."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/humanwill-release.yml").read_text()
UPSTREAM = (ROOT / ".github/workflows/release.yml").read_text()

required = {
    "manual-only trigger": "  workflow_dispatch:\n",
    "single release concurrency": "  group: humanwill-release\n",
    "fork repository guard": "github.repository == 'hubyuan/sub2api'",
    "full SHA validation": "^[0-9a-fA-F]{40}$",
    "exact checked-out SHA": '[[ "$ACTUAL_SHA" == "${SOURCE_SHA,,}" ]]',
    "existing version rejection": "already exists; refusing to overwrite",
    "amd64-only build": "platforms: linux/amd64",
    "version-only image tag": "tags: ${{ env.IMAGE }}:${{ steps.validate.outputs.version }}",
    "OCI source label": "org.opencontainers.image.source=https://github.com/hubyuan/sub2api",
    "OCI revision label": "org.opencontainers.image.revision=${{ steps.validate.outputs.source_sha }}",
    "OCI version label": "org.opencontainers.image.version=${{ steps.validate.outputs.version }}",
    "digest output": "${{ steps.build.outputs.digest }}",
}

missing = [name for name, text in required.items() if text not in WORKFLOW]
if missing:
    raise SystemExit("missing release invariants: " + ", ".join(missing))

trigger_block = WORKFLOW.split("on:\n", 1)[1].split("\nconcurrency:", 1)[0]
if trigger_block.strip() != "workflow_dispatch:\n    inputs:\n      source_sha:\n        description: \"Complete 40-character source commit SHA\"\n        required: true\n        type: string\n      version:\n        description: \"New immutable SemVer (without a moving tag)\"\n        required: true\n        type: string":
    raise SystemExit("HumanWill release must remain workflow_dispatch-only with SHA/version inputs")

for moving in ("latest", "edge", "stable"):
    if f"tags: {moving}" in WORKFLOW or f":{moving}" in WORKFLOW:
        raise SystemExit(f"moving image tag is forbidden: {moving}")

upstream_jobs = ("update-version", "build-frontend", "release", "sync-version-file")
job_starts = list(re.finditer(r"(?m)^  ([A-Za-z0-9_-]+):\n", UPSTREAM))
for job in upstream_jobs:
    match = next((item for item in job_starts if item.group(1) == job), None)
    if match is None:
        raise SystemExit(f"upstream workflow job missing: {job}")
    next_match = next((item for item in job_starts if item.start() > match.start()), None)
    block = UPSTREAM[match.start() : next_match.start() if next_match else None]
    if "github.repository == 'Wei-Shaw/sub2api'" not in block:
        raise SystemExit(f"upstream release job is not fork-isolated: {job}")

print("HumanWill immutable release contract verified")
