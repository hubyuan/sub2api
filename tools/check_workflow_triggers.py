#!/usr/bin/env python3
"""Audit fork safety for every GitHub Actions workflow."""

from __future__ import annotations

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
UPSTREAM_REPOSITORY_GUARD = "github.repository == 'Wei-Shaw/sub2api'"
PUBLISHING_MARKERS = (
    "packages: write",
    "docker/login-action",
    "docker/build-push-action",
    "goreleaser/goreleaser-action",
    "dockerhub-description",
    "api.telegram.org",
    "git push",
    "contents: write",
)


def top_level_block(text: str, key: str) -> str:
    match = re.search(rf"(?m)^{re.escape(key)}:\s*$", text)
    if not match:
        return ""
    tail = text[match.end() :]
    end = re.search(r"(?m)^[A-Za-z0-9_-]+:\s*(?:#.*)?$", tail)
    return tail[: end.start()] if end else tail


def jobs(text: str) -> dict[str, str]:
    jobs_match = re.search(r"(?m)^jobs:\s*$", text)
    if not jobs_match:
        return {}
    body = text[jobs_match.end() :]
    starts = list(re.finditer(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", body))
    result: dict[str, str] = {}
    for index, match in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(body)
        result[match.group(1)] = body[match.start() : end]
    return result


workflow_paths = sorted(
    path for path in WORKFLOWS.iterdir() if path.suffix in {".yml", ".yaml"}
)
if not workflow_paths:
    raise SystemExit("no GitHub Actions workflows found")

for path in workflow_paths:
    text = path.read_text(encoding="utf-8")
    trigger_block = top_level_block(text, "on")
    if not trigger_block:
        raise SystemExit(f"unable to parse trigger block: {path.name}")
    trigger_names = re.findall(r"(?m)^  ([A-Za-z0-9_-]+):", trigger_block)
    publishing = any(marker in text for marker in PUBLISHING_MARKERS)
    parsed_jobs = jobs(text)
    if not parsed_jobs:
        raise SystemExit(f"unable to parse jobs: {path.name}")

    if "pull_request_target" in trigger_names:
        unguarded = [name for name, block in parsed_jobs.items() if UPSTREAM_REPOSITORY_GUARD not in block]
        if unguarded:
            raise SystemExit(
                f"pull_request_target workflow has unguarded jobs ({path.name}): "
                + ", ".join(unguarded)
            )

    if publishing:
        unguarded = [
            name
            for name, block in parsed_jobs.items()
            if any(marker in block for marker in PUBLISHING_MARKERS)
            and UPSTREAM_REPOSITORY_GUARD not in block
        ]
        if unguarded:
            raise SystemExit(
                f"publishing-capable jobs can run in the fork ({path.name}): "
                + ", ".join(unguarded)
            )
    print(
        f"WORKFLOW\t{path.name}\ttriggers={','.join(trigger_names)}\t"
        f"publishing_capable={str(publishing).lower()}\tfork_guarded=true"
    )

release = (WORKFLOWS / "release.yml").read_text(encoding="utf-8")
for required_job in ("update-version", "build-frontend", "release", "sync-version-file"):
    block = jobs(release).get(required_job, "")
    if UPSTREAM_REPOSITORY_GUARD not in block:
        raise SystemExit(f"upstream release job is not fork-isolated: {required_job}")

print("All workflow triggers are fork-safe; fork events cannot publish upstream artifacts or deploy")
