#!/usr/bin/env python3
"""Fail CI when the fork release path loses an immutability invariant."""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/humanwill-release.yml").read_text()
UPSTREAM = (ROOT / ".github/workflows/release.yml").read_text()
COMPOSE = (ROOT / "deploy/docker-compose.humanwill.example.yml").read_text()

required = {
    "manual-only trigger": "  workflow_dispatch:\n",
    "single release concurrency": "  group: humanwill-release\n",
    "fork repository guard": "github.repository == 'hubyuan/sub2api'",
    "actions read permission": "  actions: read\n",
    "full SHA validation": "^[0-9a-fA-F]{40}$",
    "exact checked-out SHA": '[[ "$ACTUAL_SHA" == "${SOURCE_SHA,,}" ]]',
    "explicit origin/main fetch": "git fetch --no-tags origin main:refs/remotes/origin/main",
    "main ancestry check": 'git merge-base --is-ancestor "$ACTUAL_SHA" refs/remotes/origin/main',
    "unmerged SHA rejection": "source_sha must already be merged into origin/main",
    "post-merge checks gate": "Require successful post-merge CI and security",
    "post-merge CI requirement": "for workflow in 'CI' 'Security Scan'",
    "main push requirement": '.head_branch == "main"',
    "successful conclusion requirement": '.conclusion == "success"',
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

compose_required = {
    "2 vCPU": "    cpus: 2.0\n",
    "2 GiB memory": "    mem_limit: 2g\n",
    "2 GiB memory-swap": "    memswap_limit: 2g\n",
    "512 PID limit": "    pids_limit: 512\n",
    "65536 NOFILE soft limit": "        soft: 65536\n",
    "65536 NOFILE hard limit": "        hard: 65536\n",
}
missing_compose = [name for name, text in compose_required.items() if text not in COMPOSE]
if missing_compose:
    raise SystemExit("missing production-candidate Compose limits: " + ", ".join(missing_compose))

trigger_block = WORKFLOW.split("on:\n", 1)[1].split("\nconcurrency:", 1)[0]
if trigger_block.strip() != "workflow_dispatch:\n    inputs:\n      source_sha:\n        description: \"Complete 40-character source commit SHA\"\n        required: true\n        type: string\n      version:\n        description: \"New immutable SemVer (without a moving tag)\"\n        required: true\n        type: string":
    raise SystemExit("HumanWill release must remain workflow_dispatch-only with SHA/version inputs")

for moving in ("latest", "edge", "stable"):
    if f"tags: {moving}" in WORKFLOW or f":{moving}" in WORKFLOW:
        raise SystemExit(f"moving image tag is forbidden: {moving}")


def run_git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        check=check,
        capture_output=True,
        text=True,
    )


def verify_main_ancestry_semantics() -> None:
    """Exercise the same fail-closed ancestry predicate used by the workflow."""
    with tempfile.TemporaryDirectory(prefix="humanwill-release-contract-") as tmp:
        repo = Path(tmp)
        run_git(repo, "init", "--quiet", "--initial-branch=main")
        run_git(repo, "config", "user.name", "release-contract")
        run_git(repo, "config", "user.email", "release-contract@example.invalid")

        (repo / "source").write_text("main\n")
        run_git(repo, "add", "source")
        run_git(repo, "commit", "--quiet", "-m", "main")
        merged_sha = run_git(repo, "rev-parse", "HEAD").stdout.strip()
        run_git(repo, "branch", "origin-main", merged_sha)

        run_git(repo, "switch", "--quiet", "-c", "unmerged")
        (repo / "source").write_text("unmerged\n")
        run_git(repo, "commit", "--quiet", "-am", "unmerged")
        unmerged_sha = run_git(repo, "rev-parse", "HEAD").stdout.strip()

        merged = run_git(
            repo, "merge-base", "--is-ancestor", merged_sha, "origin-main", check=False
        )
        unmerged = run_git(
            repo, "merge-base", "--is-ancestor", unmerged_sha, "origin-main", check=False
        )
        if merged.returncode != 0 or unmerged.returncode == 0:
            raise SystemExit("main ancestry contract did not accept merged and reject unmerged SHAs")


verify_main_ancestry_semantics()

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
