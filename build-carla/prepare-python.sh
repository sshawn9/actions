#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

carla_assert_linux_x86_64
carla_require_command jq
carla_require_command uv
carla_validate_python_versions

mapfile -t python_versions < <(carla_python_versions)
mapfile -t install_versions < <(
  printf '%s\n' "${python_versions[@]}" 3.10 | sort -Vu
)

mkdir -p \
  "${CARLA_WORK_ROOT}" \
  "${CARLA_STATE_DIR}" \
  "${CARLA_PYTHON_PACKAGE_ROOT}" \
  "${CARLA_PYTHON_SHIM_DIR}"

carla_log "Installing managed CPython runtimes: ${install_versions[*]}"
uv python install --managed-python --no-bin "${install_versions[@]}"

for version in "${python_versions[@]}"; do
  managed_python="$(carla_managed_python "${version}")"
  package_dir="${CARLA_PYTHON_PACKAGE_ROOT}/python-${version}"
  wrapper="$(carla_python_shim "${version}")"

  # Do not install into a uv-managed interpreter (PEP 668). Pure-Python build
  # dependencies live in a version-specific target directory instead.
  rm -rf "${package_dir}"
  mkdir -p "${package_dir}"
  uv pip install \
    --python "${managed_python}" \
    --target "${package_dir}" \
    'distro==1.9.0' \
    'setuptools==82.0.1' \
    'wheel==0.47.0'

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'export PYTHONNOUSERSITE=1\n'
    printf 'export PYTHONPATH=%q\n' "${package_dir}"
    printf 'exec %q "$@"\n' "${managed_python}"
  } > "${wrapper}"
  chmod +x "${wrapper}"

  "${wrapper}" - <<'PY'
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
print(f"{sys.version.split()[0]}: prefix={sys.prefix}, include={include}")
print(f"distro={distro.__version__}, setuptools={setuptools.__version__}, wheel={wheel.__version__}")
PY
done

# auditwheel 6.7 requires Python >=3.10, so keep its runtime independent of the
# requested wheel versions (a Python-3.9-only build still works).
auditwheel_python="$(carla_managed_python 3.10)"
rm -rf "${CARLA_AUDITWHEEL_VENV}"
uv venv --python "${auditwheel_python}" "${CARLA_AUDITWHEEL_VENV}"
uv pip install \
  --python "${CARLA_AUDITWHEEL_VENV}/bin/python" \
  'auditwheel==6.7.0'
"${CARLA_AUDITWHEEL_VENV}/bin/python" -m auditwheel --version

jq -n \
  --argjson requested_versions "$(printf '%s\n' "${python_versions[@]}" | jq -R . | jq -s .)" \
  --arg setuptools '82.0.1' \
  --arg wheel '0.47.0' \
  --arg distro '1.9.0' \
  --arg auditwheel '6.7.0' \
  '{
    requested_python_versions: $requested_versions,
    build_packages: {
      setuptools: $setuptools,
      wheel: $wheel,
      distro: $distro,
      auditwheel: $auditwheel
    }
  }' > "${CARLA_STATE_DIR}/python-build.json"

uv cache clean
carla_show_disk_space
