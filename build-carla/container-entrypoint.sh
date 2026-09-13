#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  exec "${SCRIPT_DIR}/build.sh" "$@"
fi

restore_ownership() {
  if [[ -n "${CARLA_HOST_UID:-}" && -n "${CARLA_HOST_GID:-}" ]]; then
    for path in "${SCRIPT_DIR}/.work" "${SCRIPT_DIR}/dist"; do
      if [[ -e "${path}" ]]; then
        chown -R "${CARLA_HOST_UID}:${CARLA_HOST_GID}" "${path}" || true
      fi
    done
  fi
}
trap restore_ownership EXIT

export CARLA_RECLAIM_APT_SPACE=1
"${SCRIPT_DIR}/install-dependencies-debian.sh"
"${SCRIPT_DIR}/install-uv.sh"
"${SCRIPT_DIR}/build.sh" "$@"
