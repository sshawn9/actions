#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

carla_assert_linux_x86_64
carla_require_command jq
carla_require_command sha256sum
carla_require_command uv
carla_validate_python_versions

auditwheel_python="${CARLA_AUDITWHEEL_VENV}/bin/python"
patchelf_dir="${CARLA_SOURCE_DIR}/PythonAPI/carla/dependencies/bin"
patchelf_wrapper_dir="${BUILD_CARLA_DIR}/bin"
raw_dist="${CARLA_SOURCE_DIR}/PythonAPI/carla/dist"
[[ -x "${auditwheel_python}" ]] || carla_die 'auditwheel environment is missing; run prepare-python.sh first'
[[ -x "${patchelf_dir}/patchelf" ]] || carla_die 'CARLA-built patchelf is missing; run build-wheels.sh first'
[[ -x "${patchelf_wrapper_dir}/patchelf" ]] || carla_die 'patchelf alignment wrapper is missing'
export CARLA_REAL_PATCHELF="${patchelf_dir}/patchelf"
export CARLA_PATCHELF_PAGE_SIZE="${CARLA_PATCHELF_PAGE_SIZE:-2097152}"
export PATH="${patchelf_wrapper_dir}:${patchelf_dir}:${PATH}"

patchelf_version="$(patchelf --version | awk '{print $2}')"
oldest="$(printf '%s\n%s\n' 0.14 "${patchelf_version}" | sort -V | head -n 1)"
[[ "${oldest}" == 0.14 ]] || \
  carla_die "auditwheel requires patchelf >=0.14, found ${patchelf_version}"
printf 'Using %s (%s, page size %s)\n' \
  "$(command -v patchelf)" "$(patchelf --version)" "${CARLA_PATCHELF_PAGE_SIZE}"

mapfile -t python_versions < <(carla_python_versions)
expected_wheel_count="${#python_versions[@]}"
mkdir -p "${CARLA_OUTPUT_DIR}"
find "${CARLA_OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type f \
  \( -name '*.whl' -o -name 'build-manifest-*.json' -o -name SHA256SUMS -o -name LICENSE-CARLA.txt \) \
  -delete

shopt -s nullglob
raw_wheels=("${raw_dist}"/*.whl)
[[ ${#raw_wheels[@]} -eq ${expected_wheel_count} ]] || \
  carla_die "expected ${expected_wheel_count} raw wheels, found ${#raw_wheels[@]}"

for raw_wheel in "${raw_wheels[@]}"; do
  "${auditwheel_python}" -m auditwheel show "${raw_wheel}"
  "${auditwheel_python}" -m auditwheel repair \
    --plat "${CARLA_WHEEL_PLATFORM}" \
    --wheel-dir "${CARLA_OUTPUT_DIR}" \
    "${raw_wheel}"
done

repaired_wheels=("${CARLA_OUTPUT_DIR}"/*.whl)
[[ ${#repaired_wheels[@]} -eq ${expected_wheel_count} ]] || \
  carla_die "expected ${expected_wheel_count} repaired wheels, found ${#repaired_wheels[@]}"

verify_root="${CARLA_WORK_ROOT}/verify"
rm -rf "${verify_root}"
mkdir -p "${verify_root}"

for version in "${python_versions[@]}"; do
  python_tag="cp${version//./}"
  matching=("${CARLA_OUTPUT_DIR}"/*-"${python_tag}"-"${python_tag}"-*.whl)
  [[ ${#matching[@]} -eq 1 ]] || \
    carla_die "expected one repaired ${python_tag} wheel, found ${#matching[@]}"

  "${auditwheel_python}" -m auditwheel show "${matching[0]}"
  managed_python="$(carla_managed_python "${version}")"
  verify_venv="${verify_root}/${python_tag}"
  uv venv --python "${managed_python}" "${verify_venv}"
  uv pip install \
    --python "${verify_venv}/bin/python" \
    --no-deps \
    "${matching[0]}"
  "${verify_venv}/bin/python" - <<'PY'
import carla

client_version = carla.Client("127.0.0.1", 2000).get_client_version()
assert client_version == "0.9.15", client_version
location = carla.Location(x=1.0, y=2.0, z=3.0)
assert (location.x, location.y, location.z) == (1.0, 2.0, 3.0)
print(f"Imported {carla.__file__}")
print(f"CARLA client version: {client_version}")
PY
done

rm -rf "${verify_root}"
carla_show_disk_space
