#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

carla_require_command git
patch_file="${BUILD_CARLA_DIR}/patches/carla-0.9.15-hosted-runner.patch"
[[ -f "${patch_file}" ]] || carla_die "patch not found: ${patch_file}"
mkdir -p "${CARLA_WORK_ROOT}" "${CARLA_STATE_DIR}"

if [[ -d "${CARLA_SOURCE_DIR}/.git" ]] && \
   ! git -C "${CARLA_SOURCE_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
  # A local container may see a host-owned mounted checkout as dubious. Git's
  # safe.directory setting is only honored from protected config scopes on the
  # older Debian 11 Git package, so register it globally inside the container.
  git config --global --add safe.directory "${CARLA_SOURCE_DIR}"
  git -C "${CARLA_SOURCE_DIR}" rev-parse --git-dir >/dev/null 2>&1 || \
    carla_die "existing source is not a usable Git checkout: ${CARLA_SOURCE_DIR}"
fi

if [[ ! -e "${CARLA_SOURCE_DIR}" ]]; then
  carla_log "Sparse-cloning official CARLA ${CARLA_VERSION} client source"
  export GIT_LFS_SKIP_SMUDGE=1
  git clone \
    --no-checkout \
    --depth 1 \
    --filter=blob:none \
    --branch "${CARLA_VERSION}" \
    --single-branch \
    https://github.com/carla-simulator/carla.git \
    "${CARLA_SOURCE_DIR}"

  # CARLA 0.9.15 is an annotated tag. Point HEAD at its peeled commit before
  # enabling sparse checkout; otherwise older Git versions treat the tag
  # object itself as HEAD and fail to populate the index.
  carla_commit="$(git -C "${CARLA_SOURCE_DIR}" rev-parse "${CARLA_VERSION}^{}")"
  git -C "${CARLA_SOURCE_DIR}" update-ref --no-deref HEAD "${carla_commit}"
  git -C "${CARLA_SOURCE_DIR}" sparse-checkout init --cone
  git -C "${CARLA_SOURCE_DIR}" sparse-checkout set LibCarla PythonAPI Util
  git -C "${CARLA_SOURCE_DIR}" read-tree -mu HEAD
elif ! git -C "${CARLA_SOURCE_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
  carla_die "CARLA_SOURCE_DIR exists but is not a Git checkout: ${CARLA_SOURCE_DIR}"
fi

carla_commit="$(git -C "${CARLA_SOURCE_DIR}" rev-parse HEAD)"
tag_commit="$(git -C "${CARLA_SOURCE_DIR}" rev-list -n 1 "${CARLA_VERSION}" 2>/dev/null || true)"
[[ -n "${tag_commit}" && "${carla_commit}" == "${tag_commit}" ]] || \
  carla_die "source HEAD ${carla_commit} is not the ${CARLA_VERSION} tag"

if git -C "${CARLA_SOURCE_DIR}" apply --reverse --check "${patch_file}" 2>/dev/null; then
  carla_log 'Hosted-runner patch is already applied'
elif git -C "${CARLA_SOURCE_DIR}" apply --check "${patch_file}"; then
  carla_log 'Applying the minimal hosted-runner compatibility patch'
  git -C "${CARLA_SOURCE_DIR}" apply "${patch_file}"
else
  carla_die 'the hosted-runner patch does not apply cleanly; use a fresh 0.9.15 checkout'
fi

grep -q 'CARLA_LLVM_INCLUDE' "${CARLA_SOURCE_DIR}/Util/BuildTools/Setup.sh"
grep -q 'PyObject_CallMethod' "${CARLA_SOURCE_DIR}/Util/BuildTools/Setup.sh"
grep -q 'a218babc8daee904a83f550fb66e5cb3f1cb3013' \
  "${CARLA_SOURCE_DIR}/Util/BuildTools/Setup.sh"
grep -q 'Replacing non-sparse OSM2ODR source cache' \
  "${CARLA_SOURCE_DIR}/Util/BuildTools/BuildOSM2ODR.sh"
grep -q 'PATCHELF_VERSION=0.18.0' "${CARLA_SOURCE_DIR}/Util/BuildTools/Setup.sh"
grep -q 'CARLA_VERSION_OVERRIDE' "${CARLA_SOURCE_DIR}/Util/BuildTools/Environment.sh"

printf '%s\n' "${carla_commit}" > "${CARLA_STATE_DIR}/carla-commit"
git -C "${CARLA_SOURCE_DIR}" diff --stat
carla_show_disk_space
