#!/usr/bin/env bash
set -Eeuo pipefail

readonly IMAGE='ghcr.io/hubyuan/sub2api'
readonly EXPECTED_VERSION='0.1.185-humanwill.1'
readonly OCI_SOURCE='https://github.com/hubyuan/sub2api'
readonly DOCKER_SOCKET='unix:///run/user/1001/docker.sock'

die() {
  printf 'RELEASE BLOCKED: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s check|build <version> <40-char-source-commit> [metadata-json]\n' "$0" >&2
  exit 2
}

[[ $# -ge 3 && $# -le 4 ]] || usage
mode=$1
version=$2
source_sha=$3
metadata_path=${4:-}

[[ $mode == check || $mode == build ]] || usage
[[ ${EUID:-$(id -u)} -eq 1001 ]] || die 'must run as dev (uid 1001)'
[[ $version == "$EXPECTED_VERSION" ]] || die "version must be $EXPECTED_VERSION"
[[ $source_sha =~ ^[0-9a-f]{40}$ ]] || die 'source commit must be 40 lowercase hexadecimal characters'
[[ $(git rev-parse HEAD) == "$source_sha" ]] || die 'source commit does not match HEAD'
[[ -z $(git status --porcelain --untracked-files=all) ]] || die 'source worktree is not clean'
[[ $(uname -m) == x86_64 ]] || die 'development host is not amd64'

export DOCKER_HOST=$DOCKER_SOCKET
docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null) || die 'dev Rootless Docker is unavailable'
[[ $docker_root == /data/dev/docker ]] || die "unexpected Docker data root: $docker_root"

registry_output=$(mktemp)
trap 'rm -f "$registry_output"' EXIT
if docker buildx imagetools inspect "${IMAGE}:${version}" >"$registry_output" 2>&1; then
  die "version ${version} already exists; refusing to overwrite"
fi
if ! grep -Eiq 'manifest unknown|no such manifest|not found' "$registry_output"; then
  printf 'Registry response did not prove version absence:\n' >&2
  sed -n '1,20p' "$registry_output" >&2
  die 'Registry absence check failed closed'
fi
printf 'VERSION ABSENT: %s:%s\n' "$IMAGE" "$version"

if [[ $mode == check ]]; then
  exit 0
fi
[[ -n $metadata_path ]] || die 'build mode requires a metadata JSON output path'
[[ ! -e $metadata_path ]] || die "metadata output already exists: $metadata_path"
mkdir -p "$(dirname "$metadata_path")"

docker buildx build \
  --platform linux/amd64 \
  --push \
  --provenance=mode=min \
  --sbom=false \
  --tag "${IMAGE}:${version}" \
  --label "org.opencontainers.image.source=${OCI_SOURCE}" \
  --label "org.opencontainers.image.revision=${source_sha}" \
  --label "org.opencontainers.image.version=${version}" \
  --build-arg 'GOLANG_IMAGE=golang:1.27.0-alpine' \
  --build-arg "VERSION=${version}" \
  --build-arg "COMMIT=${source_sha}" \
  --metadata-file "$metadata_path" \
  --file Dockerfile \
  .

printf 'SINGLE RELEASE BUILD PUSHED: %s:%s\n' "$IMAGE" "$version"
printf 'BUILDX METADATA: %s\n' "$metadata_path"
