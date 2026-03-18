#!/usr/bin/env bash
# install-protobuf.sh — Build and install protobuf from source.
#
# Skips if the correct version is already installed (protoc --version matches).
# Works both as root (Docker build) and as a normal user (auto-uses sudo).
#
# Offline / cached usage:
#   Place the tarball (e.g. protobuf-all-21.5.tar.gz) in the same directory as
#   this script before running.  The script will use it directly and skip the
#   network download, which is useful in air-gapped environments or CI caches.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Run a command as root, using sudo when needed.
# Uses $EUID (bash built-in) to avoid forking a subshell.
if [[ $EUID -ne 0 ]] && ! command -v sudo &>/dev/null; then
  echo "ERROR: not root and sudo is unavailable" >&2
  exit 1
fi
as_root() { [[ $EUID -eq 0 ]] && "$@" || sudo "$@"; }

PROTOBUF_VERSION="3.21.5"
PROTOBUF_TAG="v21.5"
PROTOBUF_TARBALL="protobuf-all-21.5.tar.gz"
PROTOBUF_URL="https://github.com/protocolbuffers/protobuf/releases/download/${PROTOBUF_TAG}/${PROTOBUF_TARBALL}"

# -------------------------------------------------------------------
# Check if already installed
# -------------------------------------------------------------------
if command -v protoc &>/dev/null; then
  if protoc --version 2>/dev/null | grep -q "libprotoc ${PROTOBUF_VERSION}"; then
    echo "Protobuf ${PROTOBUF_VERSION} is already installed."
    exit 0
  fi
fi

# -------------------------------------------------------------------
# Install build dependencies
# -------------------------------------------------------------------
as_root apt-get update
as_root apt-get install --no-install-recommends -y \
  autoconf automake libtool curl make g++ unzip wget

# -------------------------------------------------------------------
# Download
# -------------------------------------------------------------------
WORKDIR="$(mktemp -d)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "${SCRIPT_DIR}/${PROTOBUF_TARBALL}" ]]; then
  echo "Found local tarball ${SCRIPT_DIR}/${PROTOBUF_TARBALL}, skipping download."
  cp "${SCRIPT_DIR}/${PROTOBUF_TARBALL}" "$WORKDIR/"
else
  cd "$WORKDIR"
  echo "Downloading ${PROTOBUF_URL} ..."
  wget -t 10 "$PROTOBUF_URL"

  if [[ ! -f $PROTOBUF_TARBALL ]]; then
    echo "Failed to download ${PROTOBUF_TARBALL}" >&2
    exit 1
  fi
fi

cd "$WORKDIR"

# -------------------------------------------------------------------
# Build & install
# -------------------------------------------------------------------
mkdir protobuf_build
tar -xzf "$PROTOBUF_TARBALL" -C protobuf_build
cd protobuf_build/protobuf*

./configure
make -j"$(nproc)"
as_root make install
as_root ldconfig

# -------------------------------------------------------------------
# Cleanup
# -------------------------------------------------------------------
cd /
rm -rf "$WORKDIR"

echo "Protobuf ${PROTOBUF_VERSION} installed successfully."
protoc --version
