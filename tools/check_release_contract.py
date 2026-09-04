#!/usr/bin/env python3
"""Validate the local immutable release path without building or publishing."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "tools/release_humanwill_image.sh").read_text(encoding="utf-8")
DOCKERFILE = (ROOT / "Dockerfile").read_text(encoding="utf-8")

required_script_invariants = {
    "exact immutable version": "readonly EXPECTED_VERSION='0.1.185-humanwill.1'",
    "fork registry": "readonly IMAGE='ghcr.io/hubyuan/sub2api'",
    "fork OCI source": "readonly OCI_SOURCE='https://github.com/hubyuan/sub2api'",
    "dev uid": "-eq 1001",
    "rootless socket": "unix:///run/user/1001/docker.sock",
    "rootless data root": "/data/dev/docker",
    "full source commit": "^[0-9a-f]{40}$",
    "exact HEAD": "git rev-parse HEAD",
    "clean source": "git status --porcelain --untracked-files=all",
    "amd64 host": "uname -m",
    "fail closed existing version": "already exists; refusing to overwrite",
    "fail closed ambiguity": "Registry absence check failed closed",
    "single target platform": "--platform linux/amd64",
    "push immutable version": '--tag "${IMAGE}:${version}"',
    "pinned Go builder": "GOLANG_IMAGE=golang:1.27.0-alpine",
    "OCI source label": "org.opencontainers.image.source=${OCI_SOURCE}",
    "OCI revision label": "org.opencontainers.image.revision=${source_sha}",
    "OCI version label": "org.opencontainers.image.version=${version}",
    "build metadata": "--metadata-file",
}
missing = [name for name, value in required_script_invariants.items() if value not in SCRIPT]
if missing:
    raise SystemExit("missing release invariants: " + ", ".join(missing))

build_invocations = len(re.findall(r"(?m)^docker buildx build \\\s*$", SCRIPT))
if build_invocations != 1:
    raise SystemExit(f"release script has {build_invocations} build invocations, want exactly one")
for moving in ("latest", "edge", "stable", "main", "master"):
    if re.search(rf"--tag\s+[^\n]*:{moving}(?:\s|$)", SCRIPT):
        raise SystemExit(f"moving image tag is forbidden: {moving}")

dockerfile_required = {
    "BuildKit syntax": "# syntax=docker/dockerfile:1.7",
    "pinned Go default": "ARG GOLANG_IMAGE=golang:1.27.0-alpine",
    "target OS": "ARG TARGETOS",
    "target architecture": "ARG TARGETARCH",
    "static cross compile": "CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH}",
}
missing_dockerfile = [name for name, value in dockerfile_required.items() if value not in DOCKERFILE]
if missing_dockerfile:
    raise SystemExit("Dockerfile release contract missing: " + ", ".join(missing_dockerfile))

print("HumanWill local release contract verified: one immutable linux/amd64 Rootless build path")
