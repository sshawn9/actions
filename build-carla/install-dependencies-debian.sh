#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

[[ "$(id -u)" -eq 0 ]] || carla_die 'run this dependency installer as root (for example with sudo)'
[[ -r /etc/os-release ]] || carla_die '/etc/os-release is unavailable'
source /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) carla_die "unsupported distribution '${ID:-unknown}'; install equivalent packages manually" ;;
esac

carla_log "Installing CARLA build dependencies on ${PRETTY_NAME}"
apt-get update
apt-get install -y --no-install-recommends \
  autoconf \
  automake \
  build-essential \
  ca-certificates \
  clang \
  cmake \
  curl \
  file \
  git \
  jq \
  libjpeg-dev \
  libpng-dev \
  libtiff-dev \
  libc++-dev \
  libc++abi-dev \
  libtool \
  libxml2-dev \
  lld \
  ninja-build \
  rsync \
  tzdata \
  unzip \
  wget \
  xz-utils \
  zlib1g-dev

if [[ "${CI:-false}" == true || "${CARLA_RECLAIM_APT_SPACE:-0}" == 1 ]]; then
  rm -rf /var/lib/apt/lists/*
fi

clang --version | head -n 1
cmake --version | head -n 1
carla_show_disk_space
