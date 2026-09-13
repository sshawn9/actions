#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

carla_require_command clang
carla_require_command git
carla_require_command jq
carla_require_command sha256sum
carla_require_command uv
carla_validate_python_versions

patch_file="${BUILD_CARLA_DIR}/patches/carla-0.9.15-hosted-runner.patch"
git -C "${CARLA_SOURCE_DIR}" rev-parse --git-dir >/dev/null 2>&1 || \
  carla_die 'CARLA source checkout is missing'
[[ -d "${CARLA_OUTPUT_DIR}" ]] || carla_die 'wheel output directory is missing'

mapfile -t python_versions < <(carla_python_versions)
shopt -s nullglob
wheels=("${CARLA_OUTPUT_DIR}"/*.whl)
[[ ${#wheels[@]} -eq ${#python_versions[@]} ]] || \
  carla_die "expected ${#python_versions[@]} wheels, found ${#wheels[@]}"

carla_commit="$(git -C "${CARLA_SOURCE_DIR}" rev-parse HEAD)"
patch_sha256="$(sha256sum "${patch_file}" | awk '{print $1}')"
compiler="$(clang --version | head -n 1)"
glibc_version="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"
patchelf_version="$("${CARLA_SOURCE_DIR}/PythonAPI/carla/dependencies/bin/patchelf" --version | awk '{print $2}')"
cp "${CARLA_SOURCE_DIR}/LICENSE" "${CARLA_OUTPUT_DIR}/LICENSE-CARLA.txt"

for version in "${python_versions[@]}"; do
  python_tag="cp${version//./}"
  managed_python="$(carla_managed_python "${version}")"
  resolved_python_version="$("${managed_python}" -c 'import platform; print(platform.python_version())')"

  jq -n \
    --arg carla_version "${CARLA_VERSION}" \
    --arg carla_commit "${carla_commit}" \
    --arg patch_sha256 "${patch_sha256}" \
    --arg python_version "${version}" \
    --arg resolved_python_version "${resolved_python_version}" \
    --arg platform "${CARLA_WHEEL_PLATFORM}" \
    --arg compiler "${compiler}" \
    --arg glibc_version "${glibc_version}" \
    --arg patchelf_version "${patchelf_version}" \
    --arg patchelf_page_size "${CARLA_PATCHELF_PAGE_SIZE:-2097152}" \
    --slurpfile python_build "${CARLA_STATE_DIR}/python-build.json" \
    '{
      carla_version: $carla_version,
      carla_commit: $carla_commit,
      buildtools_version: $carla_version,
      hosted_runner_patch_sha256: $patch_sha256,
      python_version: $python_version,
      resolved_python_version: $resolved_python_version,
      platform: $platform,
      compiler: $compiler,
      glibc_version: $glibc_version,
      patchelf_version: $patchelf_version,
      patchelf_page_size: ($patchelf_page_size | tonumber),
      python_build: $python_build[0]
    }' > "${CARLA_OUTPUT_DIR}/build-manifest-${python_tag}.json"
done

(
  cd "${CARLA_OUTPUT_DIR}"
  sha256sum ./*.whl > SHA256SUMS
)

ls -lh "${CARLA_OUTPUT_DIR}"
