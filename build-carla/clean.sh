#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: clean.sh --work | --output | --all

  --work   Remove the cloned CARLA tree, managed Pythons, and build state
  --output Remove repaired wheels and metadata
  --all    Remove both
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
case "$1" in
  --work)
    targets=("${CARLA_WORK_ROOT}")
    ;;
  --output)
    targets=("${CARLA_OUTPUT_DIR}")
    ;;
  --all)
    targets=("${CARLA_WORK_ROOT}" "${CARLA_OUTPUT_DIR}")
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

carla_require_command realpath

# Resolve aliases for the safety check, but remove the original path so a
# symlink is unlinked rather than recursively deleting the directory it names.
# Validate all targets first so --all cannot partially clean an unsafe request.
for target in "${targets[@]}"; do
  resolved_target="$(realpath -m -- "${target}")"
  [[ "${resolved_target}" != / && \
     "${BUILD_CARLA_DIR}" != "${resolved_target}" && \
     "${BUILD_CARLA_DIR}" != "${resolved_target}/"* ]] || \
    carla_die "refusing unsafe cleanup target: ${target}"
done

for target in "${targets[@]}"; do
  # A trailing slash makes rm follow a directory symlink instead of unlinking it.
  while [[ "${target}" == */ ]]; do
    target="${target%/}"
  done
  if [[ -e "${target}" || -L "${target}" ]]; then
    printf 'Removing %s\n' "${target}"
    rm -rf -- "${target}"
  fi
done
