#!/usr/bin/env bash
# build.sh — Build ROS Docker images with buildx.
#
# Usage:
#   ./build.sh [OPTIONS]
#
# Options:
#   --distro  DISTROS   Comma-separated ROS distros (default: humble)
#   --stage   STAGE     base, desktop, box, or all (default: all)
#   --platform PLATS    Comma-separated platforms (default: linux/amd64,linux/arm64)
#   --push              Push to registry
#   --ali               Also push to Aliyun registry (requires --push)
#   --tag     TAG       Image tag (default: latest)
#   --username USER     Registry username (default: sshawn)
#   --dry-run           Print commands without executing

set -euo pipefail

# ---- Utility ----

# Host arch short name (amd64, arm64, ...) for use in tags.
host_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l)  echo "armv7" ;;
    *)       echo "Unsupported architecture: $arch" >&2; return 1 ;;
  esac
}

# Detect native Docker platform from host architecture.
native_platform() {
  case "$(uname -m)" in
    x86_64)  echo "linux/amd64"  ;;
    aarch64) echo "linux/arm64"  ;;
    armv7l)  echo "linux/arm/v7" ;;
    *)       echo "linux/$(uname -m)" ;;
  esac
}

run_cmd() {
  local dry_run="$1"; shift
  if [[ "$dry_run" == "true" ]]; then
    echo "[dry-run] $*"
  else
    echo "+ $*"
    "$@"
  fi
}

# ---- Core build layer ----
# Fully explicit — no resolution, no inference.
#
#   build_one <dockerfile> <base_image> <platform> <context_dir> \
#             <dry_run> <build_args_ref> <tags_ref> <output>
#
#   dockerfile      — path to Dockerfile, relative to context_dir
#   base_image      — parent image (e.g. "sshawn/humble"); added as
#                     --build-arg BASE_IMAGE=...; pass "" to skip
#   platform        — target platform(s), e.g. "linux/amd64,linux/arm64";
#                     pass "" to auto-detect host native platform
#   context_dir     — Docker build context; COPY/ADD paths resolve from here
#   dry_run         — "true" to print without executing, "false" to run
#   build_args_ref  — nameref to array of "KEY=VAL" strings, each becomes
#                     a --build-arg (e.g. "ROS_DISTRO=humble")
#   tags_ref        — nameref to array of full image references, each
#                     becomes a -t (e.g. "docker.io/sshawn/humble:latest")
#   output          — buildx output strategy:
#                       "--push" — push to remote registry
#                       "--load" — load into local docker daemon (single-platform only)
#                       ""       — build only, no output (e.g. multi-platform dry validation)
build_one() {
  local dockerfile="$1"
  local base_image="$2"
  local platform="${3:-$(native_platform)}"
  local context_dir="$4"
  local dry_run="$5"
  local -n _build_one_args=$6
  local -n _build_one_tags=$7
  local output="$8"

  echo ""
  echo "==== ${_build_one_tags[0]} ===="

  local cmd=(docker buildx build --platform "$platform" -f "$dockerfile")

  [[ -n "$base_image" ]] && cmd+=(--build-arg "BASE_IMAGE=${base_image}")

  local arg
  for arg in "${_build_one_args[@]}"; do
    cmd+=(--build-arg "$arg")
  done

  local t
  for t in "${_build_one_tags[@]}"; do
    cmd+=(-t "$t")
  done

  if [[ -n "${ACTIONS_CACHE_URL:-}" ]]; then
    cmd+=(--cache-from "type=gha" --cache-to "type=gha,mode=max")
  fi

  [[ -n "${GITEE_PAT:-}" ]] && cmd+=(--secret "id=gitee_pat,env=GITEE_PAT")

  [[ -n "$output" ]] && cmd+=("$output")
  cmd+=("$context_dir")

  run_cmd "$dry_run" "${cmd[@]}"
}

# ---- Default-parameter wrapper ----
# Fixes: platform (native), context_dir (script dir), dry_run (off),
#        build_args (none), output (--push).
# Caller provides: dockerfile, base_image, tags_ref.
#
#   build_default <dockerfile> <base_image> <tags_ref>
build_default() {
  local dockerfile="$1"
  local base_image="$2"
  local -n _build_default_tags=$3

  local platform=""
  local context_dir
  context_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local dry_run=""
  local args=()
  local output="--load"

  build_one "$dockerfile" "$base_image" \
    "$platform" "$context_dir" "$dry_run" args _build_default_tags "$output"

  # Push all tags to registry after loading locally
  local t
  for t in "${_build_default_tags[@]}"; do
    run_cmd "$dry_run" docker push "$t"
  done
}


build_base() {
  local distro="$1"
  local arch
  arch="$(host_arch)" || return 1
  local tags=("sshawn/${distro}:${arch}")

  build_default "dockerfiles/Dockerfile.base" "ros:${distro}" tags
}

build_desktop() {
  local distro="$1"
  local arch
  arch="$(host_arch)" || return 1
  local tags=("sshawn/${distro}-desktop:${arch}")

  build_default "dockerfiles/Dockerfile.desktop" "sshawn/${distro}:${arch}" tags
}

build_box() {
  local distro="$1"
  local arch
  arch="$(host_arch)" || return 1
  local tags=("sshawn/${distro}-box:${arch}")

  build_default "dockerfiles/Dockerfile.box" "sshawn/${distro}-desktop:${arch}" tags
}
