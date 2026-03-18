#!/usr/bin/env bash
# ops-sync-to-aliyun.sh — Sync selected Docker Hub images to Aliyun ACR
#
# Usage:
#   Local: ./sync-to-aliyun.sh              (use existing regctl login session)
#   Local: SYNC_SOURCE=local ./sync-to-aliyun.sh   (push from local Docker daemon)
#   CI:    env DOCKERHUB_PASSWORD=xxx ALIYUN_PASSWORD=xxx ./sync-to-aliyun.sh
#
# Environment variables:
#   SYNC_SOURCE         — "registry" (default) or "local" (use local Docker daemon)
#   DOCKERHUB_USERNAME  — Docker Hub username (default: sshawn)
#   DOCKERHUB_PASSWORD  — Docker Hub password/token (not needed for local mode)
#   ALIYUN_USERNAME     — Aliyun ACR username (default: sshawn)
#   ALIYUN_PASSWORD     — Aliyun ACR password
#
# Requires: regctl (https://github.com/regclient/regclient)
#           skopeo (for local mode, https://github.com/containers/skopeo)
set -euo pipefail

# =====================================================================
# Configuration: image list and registry addresses
# =====================================================================

SYNC_SOURCE="${SYNC_SOURCE:-registry}" # "registry" or "local"
DOCKERHUB_USER="${DOCKERHUB_USERNAME:-sshawn}"
ALIYUN_REGISTRY="registry.cn-beijing.aliyuncs.com"
ALIYUN_USER="${ALIYUN_USERNAME:-sshawn}"
ALIYUN_NAMESPACE="sshawn"

# Repos to sync (names under DOCKERHUB_USER, all tags will be synced)
SYNC_LIST=(
  melodic
  melodic-desktop
  melodic-box
  noetic
  noetic-desktop
  noetic-box
  humble
  humble-desktop
  humble-box
  jazzy
  jazzy-desktop
  jazzy-box
  rolling
  rolling-desktop
  rolling-box
)

# =====================================================================
# Utility functions
# =====================================================================
log() { echo "[$(date -Iseconds)] $*"; }

# Ensure regctl is installed
check_regctl() {
  if ! command -v regctl &>/dev/null; then
    log "ERROR: regctl not found. See https://github.com/regclient/regclient"
    exit 1
  fi
}

# Auto-login if password env vars are set; otherwise rely on existing session
login_registries() {
  if [[ -n ${DOCKERHUB_PASSWORD:-} ]]; then
    log "Logging in to Docker Hub ..."
    regctl registry login docker.io -u "${DOCKERHUB_USER}" -p "${DOCKERHUB_PASSWORD}"
  else
    log "DOCKERHUB_PASSWORD not set, skipping Docker Hub login (using existing session)"
  fi

  if [[ -n ${ALIYUN_PASSWORD:-} ]]; then
    log "Logging in to Aliyun ACR ..."
    regctl registry login "${ALIYUN_REGISTRY}" -u "${ALIYUN_USER}" -p "${ALIYUN_PASSWORD}"
  else
    log "ALIYUN_PASSWORD not set, skipping Aliyun login (using existing session)"
  fi
}

# Sync all tags of a single repo
# Args: $1 = repo name (e.g. humble)
# Returns: number of failed tags
sync_repo() {
  local repo="$1"
  local src="${DOCKERHUB_USER}/${repo}"
  local dest="${ALIYUN_REGISTRY}/${ALIYUN_NAMESPACE}/${repo}"
  local errors=0

  # In local mode, list tags from local Docker daemon
  if [[ ${SYNC_SOURCE} == "local" ]]; then
    log "[${repo}] Listing local tags for ${src} ..."
    local tags
    tags=$(docker images "${src}" --format '{{.Tag}}' 2>/dev/null | grep -v '<none>') || {
      log "[${repo}] WARN: No local images found, skipping"
      return 1
    }
  else
    # List all tags from source registry
    log "[${repo}] Listing tags for ${src} ..."
    local tags
    tags=$(regctl tag ls "${src}" 2>/dev/null) || {
      log "[${repo}] WARN: Failed to list tags, skipping"
      return 1
    }
  fi

  if [[ -z ${tags} ]]; then
    log "[${repo}] No tags found, skipping"
    return 0
  fi

  local tag_count
  tag_count=$(echo "${tags}" | wc -l)
  log "[${repo}] Found ${tag_count} tag(s)"

  # Copy each tag
  local tag
  while IFS= read -r tag; do
    [[ -z ${tag} ]] && continue
    sync_tag "${src}" "${dest}" "${tag}" || ((errors++)) || true
  done <<<"${tags}"

  log "[${repo}] Done (failed: ${errors}/${tag_count})"
  return "${errors}"
}

# Copy a single tag from source to destination
# Args: $1 = source repo, $2 = dest repo, $3 = tag
sync_tag() {
  local src="$1" dest="$2" tag="$3"
  if [[ ${SYNC_SOURCE} == "local" ]]; then
    log "  [local] ${src}:${tag} -> ${dest}:${tag}"
    if ! skopeo copy --all "docker-daemon:${src}:${tag}" "docker://${dest}:${tag}"; then
      log "  ERROR: Failed to copy ${src}:${tag}"
      return 1
    fi
  else
    log "  ${src}:${tag} -> ${dest}:${tag}"
    if ! regctl image copy "${src}:${tag}" "${dest}:${tag}"; then
      log "  ERROR: Failed to copy ${src}:${tag}"
      return 1
    fi
  fi
}

# =====================================================================
# Main
# =====================================================================
main() {
  check_regctl
  login_registries

  local total_errors=0

  local src_label
  if [[ ${SYNC_SOURCE} == "local" ]]; then
    src_label="local Docker daemon"
  else
    src_label="docker.io/${DOCKERHUB_USER}"
  fi

  log "Starting sync: ${#SYNC_LIST[@]} repo(s)"
  log "Direction: ${src_label} -> ${ALIYUN_REGISTRY}/${ALIYUN_NAMESPACE}"
  log "---"

  for repo in "${SYNC_LIST[@]}"; do
    sync_repo "${repo}" || ((total_errors += $?)) || true
  done

  log "==="
  if [[ ${total_errors} -gt 0 ]]; then
    log "Sync completed with ${total_errors} error(s)"
    exit 1
  fi
  log "All images synced successfully"
}

main "$@"
