#!/usr/bin/env bash
set -euo pipefail

UV_VERSION="0.11.28"
UV_ARCHIVE="uv-x86_64-unknown-linux-gnu.tar.gz"
UV_ARCHIVE_SHA256="e490a6464492183c5d4534a5527fb4440f7f2bb2f228162ad7e4afe076dc0224"
UV_BIN_DIR="${CARLA_UV_BIN_DIR:-/usr/local/bin}"

if command -v uv >/dev/null 2>&1 && [[ "$(uv --version)" == "uv ${UV_VERSION}" ]]; then
  printf 'uv %s is already installed at %s\n' "${UV_VERSION}" "$(command -v uv)"
  exit 0
fi

[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
  printf 'error: this installer supports only Linux x86_64\n' >&2
  exit 1
}

for command_name in curl install mktemp sha256sum tar; do
  command -v "${command_name}" >/dev/null 2>&1 || {
    printf 'error: required command not found: %s\n' "${command_name}" >&2
    exit 1
  }
done

temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT
archive="${temporary_dir}/${UV_ARCHIVE}"

curl -fsSLo "${archive}" \
  --retry 3 \
  --retry-all-errors \
  "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_ARCHIVE}"
printf '%s  %s\n' "${UV_ARCHIVE_SHA256}" "${archive}" | sha256sum --check --status
tar -xzf "${archive}" -C "${temporary_dir}"

mkdir -p "${UV_BIN_DIR}"
install -m 0755 \
  "${temporary_dir}/uv-x86_64-unknown-linux-gnu/uv" \
  "${UV_BIN_DIR}/uv"
install -m 0755 \
  "${temporary_dir}/uv-x86_64-unknown-linux-gnu/uvx" \
  "${UV_BIN_DIR}/uvx"

"${UV_BIN_DIR}/uv" --version
