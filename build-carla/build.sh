#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: build.sh [options]

Build CARLA 0.9.15 client wheels with the same scripts used by GitHub Actions.

Options:
  --python-versions LIST  Comma-separated versions (default: 3.9,...,3.14)
  --work-dir PATH         Source, Python runtimes, and intermediate build files
  --output-dir PATH       Repaired wheels and build metadata
  --source-dir PATH       Use or create a CARLA source checkout at PATH
  -h, --help              Show this help

Relative directory paths are resolved from the current working directory.

On a non-Debian-11 host, use run-in-container.sh to preserve glibc 2.31
compatibility. Install host dependencies separately with
install-dependencies-debian.sh when building natively.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --python-versions)
      [[ $# -ge 2 ]] || { printf 'missing value for %s\n' "$1" >&2; exit 2; }
      export CARLA_PYTHON_VERSIONS="$2"
      shift 2
      ;;
    --work-dir)
      [[ $# -ge 2 ]] || { printf 'missing value for %s\n' "$1" >&2; exit 2; }
      export CARLA_WORK_ROOT="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { printf 'missing value for %s\n' "$1" >&2; exit 2; }
      export CARLA_OUTPUT_DIR="$2"
      shift 2
      ;;
    --source-dir)
      [[ $# -ge 2 ]] || { printf 'missing value for %s\n' "$1" >&2; exit 2; }
      export CARLA_SOURCE_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

source "${SCRIPT_DIR}/lib/common.sh"
carla_validate_python_versions

carla_log "Build root: ${CARLA_WORK_ROOT}"
carla_log "Output: ${CARLA_OUTPUT_DIR}"
carla_log "Python versions: $(carla_python_version_csv)"

"${SCRIPT_DIR}/prepare-python.sh"
"${SCRIPT_DIR}/fetch-source.sh"
"${SCRIPT_DIR}/build-wheels.sh"
"${SCRIPT_DIR}/repair-wheels.sh"
"${SCRIPT_DIR}/write-metadata.sh"

carla_log "Build complete: ${CARLA_OUTPUT_DIR}"
