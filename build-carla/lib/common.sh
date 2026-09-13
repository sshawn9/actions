#!/usr/bin/env bash

# Shared configuration for the CARLA 0.9.15 client-wheel build scripts.

BUILD_CARLA_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPOSITORY_ROOT="$(cd -- "${BUILD_CARLA_DIR}/.." && pwd -P)"
export BUILD_CARLA_DIR REPOSITORY_ROOT

export CARLA_VERSION="${CARLA_VERSION:-0.9.15}"
export CARLA_WHEEL_PLATFORM="${CARLA_WHEEL_PLATFORM:-manylinux_2_31_x86_64}"
export CARLA_BUILD_CONCURRENCY="${CARLA_BUILD_CONCURRENCY:-2}"

export CARLA_WORK_ROOT="${CARLA_WORK_ROOT:-${BUILD_CARLA_DIR}/.work}"
export CARLA_SOURCE_DIR="${CARLA_SOURCE_DIR:-${CARLA_WORK_ROOT}/source}"
export CARLA_OUTPUT_DIR="${CARLA_OUTPUT_DIR:-${BUILD_CARLA_DIR}/dist/wheels}"
export CARLA_STATE_DIR="${CARLA_STATE_DIR:-${CARLA_WORK_ROOT}/state}"
export CARLA_PYTHON_ROOT="${CARLA_PYTHON_ROOT:-${CARLA_WORK_ROOT}/python}"
export CARLA_PYTHON_PACKAGE_ROOT="${CARLA_PYTHON_PACKAGE_ROOT:-${CARLA_WORK_ROOT}/python-packages}"
export CARLA_PYTHON_SHIM_DIR="${CARLA_PYTHON_SHIM_DIR:-${CARLA_WORK_ROOT}/python-shims}"
export CARLA_AUDITWHEEL_VENV="${CARLA_AUDITWHEEL_VENV:-${CARLA_WORK_ROOT}/auditwheel-venv}"

# Keeping uv data under the build directory makes cleanup predictable and avoids
# modifying a developer's global uv installation/cache.
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-${CARLA_PYTHON_ROOT}}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-${CARLA_WORK_ROOT}/uv-cache}"

# Anchor paths before any build phase changes directory. Keep symlinks intact
# so cleanup can unlink a work directory without deleting its target.
for carla_path_variable in \
  CARLA_WORK_ROOT CARLA_SOURCE_DIR CARLA_OUTPUT_DIR CARLA_STATE_DIR \
  CARLA_PYTHON_ROOT CARLA_PYTHON_PACKAGE_ROOT CARLA_PYTHON_SHIM_DIR \
  CARLA_AUDITWHEEL_VENV UV_PYTHON_INSTALL_DIR UV_CACHE_DIR; do
  if [[ "${!carla_path_variable}" != /* ]]; then
    export "${carla_path_variable}=${PWD}/${!carla_path_variable}"
  fi
done
unset carla_path_variable

if [[ -z "${CARLA_PYTHON_VERSIONS:-}" && -z "${CARLA_PYTHON_VERSIONS_JSON:-}" ]]; then
  export CARLA_PYTHON_VERSIONS_JSON='["3.9","3.10","3.11","3.12","3.13","3.14"]'
fi

carla_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

carla_log() {
  printf '\n==> %s\n' "$*"
}

carla_require_command() {
  command -v "$1" >/dev/null 2>&1 || carla_die "required command not found: $1"
}

carla_validate_supported_python_version() {
  case "$1" in
    3.9|3.10|3.11|3.12|3.13|3.14) ;;
    *) carla_die "unsupported Python version '$1'; tested versions are 3.9 through 3.14" ;;
  esac
}

carla_validate_python_versions() {
  local version

  if [[ -n "${CARLA_PYTHON_VERSIONS:-}" ]]; then
    local -a versions=()
    IFS=',' read -r -a versions <<< "${CARLA_PYTHON_VERSIONS}"
    [[ ${#versions[@]} -gt 0 ]] || carla_die 'CARLA_PYTHON_VERSIONS is empty'
    for version in "${versions[@]}"; do
      version="${version//[[:space:]]/}"
      [[ "${version}" =~ ^3\.[0-9]+$ ]] || \
        carla_die "invalid Python version '${version}'; expected values such as 3.10"
      carla_validate_supported_python_version "${version}"
    done
    return
  fi

  carla_require_command jq
  jq -e '
    type == "array" and
    length > 0 and
    all(.[]; type == "string" and test("^3\\.[0-9]+$"))
  ' <<< "${CARLA_PYTHON_VERSIONS_JSON}" >/dev/null || \
    carla_die 'CARLA_PYTHON_VERSIONS_JSON must be a non-empty array such as ["3.9","3.10"]'

  while IFS= read -r version; do
    carla_validate_supported_python_version "${version}"
  done < <(jq -r '.[]' <<< "${CARLA_PYTHON_VERSIONS_JSON}")
}

carla_python_versions() {
  local version

  if [[ -n "${CARLA_PYTHON_VERSIONS:-}" ]]; then
    local -a versions=()
    IFS=',' read -r -a versions <<< "${CARLA_PYTHON_VERSIONS}"
    for version in "${versions[@]}"; do
      printf '%s\n' "${version//[[:space:]]/}"
    done | sort -Vu
  else
    jq -r 'unique[]' <<< "${CARLA_PYTHON_VERSIONS_JSON}" | sort -V
  fi
}

carla_python_version_csv() {
  local -a versions=()
  mapfile -t versions < <(carla_python_versions)
  local IFS=,
  printf '%s\n' "${versions[*]}"
}

carla_managed_python() {
  uv python find --managed-python "$1"
}

carla_python_shim() {
  printf '%s/python%s\n' "${CARLA_PYTHON_SHIM_DIR}" "$1"
}

carla_assert_linux_x86_64() {
  [[ "$(uname -s)" == Linux ]] || carla_die 'only Linux builds are supported'
  [[ "$(uname -m)" == x86_64 ]] || carla_die 'only x86_64 builds are supported'
}

carla_check_glibc_baseline() {
  local target_glibc host_glibc oldest
  [[ "${CARLA_WHEEL_PLATFORM}" =~ ^manylinux_([0-9]+)_([0-9]+)_x86_64$ ]] || \
    carla_die "unsupported wheel platform: ${CARLA_WHEEL_PLATFORM}"
  target_glibc="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  host_glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
  [[ -n "${host_glibc}" ]] || carla_die 'unable to detect the host glibc version'
  oldest="$(printf '%s\n%s\n' "${target_glibc}" "${host_glibc}" | sort -V | head -n 1)"

  if [[ "${oldest}" == "${target_glibc}" && "${host_glibc}" != "${target_glibc}" ]]; then
    if [[ "${CARLA_ALLOW_NEWER_GLIBC:-0}" != 1 ]]; then
      carla_die "host glibc ${host_glibc} is newer than ${target_glibc}; use run-in-container.sh or set CARLA_ALLOW_NEWER_GLIBC=1 for a non-portable test build"
    fi
    printf 'warning: host glibc %s is newer than wheel baseline %s\n' \
      "${host_glibc}" "${target_glibc}" >&2
  fi
}

carla_show_disk_space() {
  df -h "${BUILD_CARLA_DIR}" 2>/dev/null || df -h
}
