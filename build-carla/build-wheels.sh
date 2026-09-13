#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

carla_assert_linux_x86_64
carla_check_glibc_baseline
carla_require_command clang
carla_require_command clang++
carla_require_command file
carla_require_command make
carla_require_command uv
carla_validate_python_versions
git -C "${CARLA_SOURCE_DIR}" rev-parse --git-dir >/dev/null 2>&1 || \
  carla_die 'CARLA source is missing; run fetch-source.sh first'

mapfile -t python_versions < <(carla_python_versions)
python_version_csv="$(carla_python_version_csv)"
export PATH="${CARLA_PYTHON_SHIM_DIR}:${PATH}"

export CARLA_BOOST_TOOLSET="${CARLA_BOOST_TOOLSET:-clang}"
export CARLA_BUILD_NO_COLOR="${CARLA_BUILD_NO_COLOR:-1}"
export CARLA_CMAKE_EXTRA_OPTIONS="${CARLA_CMAKE_EXTRA_OPTIONS:--DLIBCARLA_BUILD_TEST=OFF}"
export CARLA_SYSROOT_FLAGS="${CARLA_SYSROOT_FLAGS-}"
export CARLA_VERSION_OVERRIDE="${CARLA_VERSION_OVERRIDE:-${CARLA_VERSION}}"
export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-${CARLA_BUILD_CONCURRENCY}}"
export MAKEFLAGS="${MAKEFLAGS:--j${CARLA_BUILD_CONCURRENCY}}"

if [[ -z "${CARLA_LLVM_INCLUDE:-}" ]]; then
  for candidate in /usr/lib/llvm-11/include/c++/v1 /usr/include/c++/v1; do
    if [[ -d "${candidate}" ]]; then
      export CARLA_LLVM_INCLUDE="${candidate}"
      break
    fi
  done
fi
if [[ -z "${CARLA_LLVM_LIBPATH:-}" ]]; then
  for candidate in /usr/lib/llvm-11/lib /usr/lib/x86_64-linux-gnu; do
    if [[ -f "${candidate}/libc++.so" || -f "${candidate}/libc++.a" ]]; then
      export CARLA_LLVM_LIBPATH="${candidate}"
      break
    fi
  done
fi

[[ -d "${CARLA_LLVM_INCLUDE:-}" ]] || carla_die "libc++ headers not found: ${CARLA_LLVM_INCLUDE:-unset}"
[[ -d "${CARLA_LLVM_LIBPATH:-}" ]] || carla_die "libc++ library directory not found: ${CARLA_LLVM_LIBPATH:-unset}"
printf 'libc++ headers: %s\nlibc++ libraries: %s\n' \
  "${CARLA_LLVM_INCLUDE}" "${CARLA_LLVM_LIBPATH}"

for version in "${python_versions[@]}"; do
  expected="$(carla_python_shim "${version}")"
  resolved="$(command -v "python${version}")"
  [[ "${resolved}" == "${expected}" ]] || \
    carla_die "python${version} resolves to ${resolved}, expected ${expected}"
  "${resolved}" - <<'PY'
import pathlib
import sys
import sysconfig

import distro
import setuptools
import wheel

assert sys.prefix == sys.base_prefix, (sys.prefix, sys.base_prefix)
include = pathlib.Path(sysconfig.get_path("include"))
assert (include / "Python.h").is_file(), include
assert (include / "pyconfig.h").is_file(), include
PY
  printf 'Python %s: %s\n' "${version}" "${resolved}"
done

raw_dist="${CARLA_SOURCE_DIR}/PythonAPI/carla/dist"
mkdir -p "${raw_dist}"
find "${raw_dist}" -mindepth 1 -maxdepth 1 \
  \( -name '*.whl' -o -name '*.egg' -o -name '.tmp' \) -exec rm -rf -- {} +

carla_log "Running CARLA's official setup phase for Python ${python_version_csv}"
make -C "${CARLA_SOURCE_DIR}" setup \
  ARGS="--python-version=${python_version_csv}"

carla_log "Building the LibCarla client"
"${CARLA_SOURCE_DIR}/Util/BuildTools/BuildLibCarla.sh" --client --release

carla_log "Building OSM2ODR"
"${CARLA_SOURCE_DIR}/Util/BuildTools/BuildOSM2ODR.sh" --build

carla_log "Building all Python wheels"
# These are the same three BuildTools recipes used by CARLA's PythonAPI Make
# target. Run them sequentially after the explicit multi-Python setup phase so
# Make does not invoke Setup.sh a second time with its default `python3` value.
"${CARLA_SOURCE_DIR}/Util/BuildTools/BuildPythonAPI.sh" \
  --rebuild \
  --python-version="${python_version_csv}"

shopt -s nullglob
raw_wheels=("${raw_dist}"/*.whl)
if [[ ${#raw_wheels[@]} -ne ${#python_versions[@]} ]]; then
  carla_die "expected ${#python_versions[@]} raw wheels, found ${#raw_wheels[@]}"
fi

for version in "${python_versions[@]}"; do
  python_tag="cp${version//./}"
  matching=("${raw_dist}"/*-"${python_tag}"-"${python_tag}"-*.whl)
  [[ ${#matching[@]} -eq 1 ]] || \
    carla_die "expected one raw ${python_tag} wheel, found ${#matching[@]}"
done

file "${raw_wheels[@]}"
du -sh \
  "${CARLA_SOURCE_DIR}/Build" \
  "${CARLA_SOURCE_DIR}/PythonAPI/carla/dependencies" \
  "${raw_dist}"
carla_show_disk_space
