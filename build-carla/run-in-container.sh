#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if command -v docker >/dev/null 2>&1; then
  container_engine=docker
elif command -v podman >/dev/null 2>&1; then
  container_engine=podman
else
  printf 'error: docker or podman is required\n' >&2
  exit 1
fi

[[ "$(uname -m)" == x86_64 ]] || {
  printf 'error: only x86_64 builds are supported\n' >&2
  exit 1
}

exec "${container_engine}" run --rm \
  --user root \
  --env CI=false \
  --env CARLA_HOST_UID="$(id -u)" \
  --env CARLA_HOST_GID="$(id -g)" \
  --env CARLA_PYTHON_VERSIONS="${CARLA_PYTHON_VERSIONS:-}" \
  --env CARLA_PYTHON_VERSIONS_JSON="${CARLA_PYTHON_VERSIONS_JSON:-}" \
  --volume "${REPOSITORY_ROOT}:/workspace" \
  --workdir /workspace \
  debian:bullseye-slim \
  /workspace/build-carla/container-entrypoint.sh "$@"
