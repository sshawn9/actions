#!/usr/bin/env bash
# set-msg-ws.sh — Clone a private Gitee msg workspace and build it.
#
# Usage: set-msg-ws.sh [--pat <token>] [--dest <path>]
#
# Options:
#   --pat <token>   Gitee personal access token (overrides $GITEE_PAT)
#   --dest <path>   Clone destination (default: script's own directory)
#
# Environment variables:
#   GITEE_PAT       Personal access token (used when --pat is not given)

set -euo pipefail

REPO="https://gitee.com/beili-huidong/msg_ws.git"

as_root() { [[ $EUID -eq 0 ]] && "$@" || sudo "$@"; }

# ── Source ROS ────────────────────────────────────────────────────────────────
source_ros() {
    local -a setup_files=(/opt/ros/*/setup.bash)
    [[ -f "${setup_files[0]}" ]] || { echo "ERROR: No ROS installation found under /opt/ros." >&2; exit 1; }
    [[ ${#setup_files[@]} -gt 1 ]] && echo "WARNING: Multiple ROS installations found, using ${setup_files[0]}."
    # shellcheck disable=SC1090
    set +u
    source "${setup_files[0]}"
    set -u
}

# ── Clone ─────────────────────────────────────────────────────────────────────
clone_repo() {
    local repo_dir=$1 pat=$2
    local authed_url="${REPO/https:\/\//https:\/\/oauth2:${pat}@}"
    git clone --depth 1 "$authed_url" "$repo_dir"
}

# ── Build ─────────────────────────────────────────────────────────────────────
build() {
    local repo_dir=$1
    cd "$repo_dir"
    # ROS_VERSION is exported by setup.bash: 1 = ROS 1 (catkin), 2 = ROS 2 (colcon)
    case "${ROS_VERSION}" in
        1) catkin build ;;
        2) colcon build ;;
        *) echo "ERROR: Unknown ROS_VERSION '${ROS_VERSION}'." >&2; exit 1 ;;
    esac
}

# ── Install debs ──────────────────────────────────────────────────────────────
install_debs() {
    local repo_dir=$1
    [[ -f "$repo_dir/build-debs.sh" ]] || return 0
    "$repo_dir/build-debs.sh" --install
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    local dest
    dest="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local pat=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pat)  pat="$2";  shift 2 ;;
            --dest) dest="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    pat="${pat:-${GITEE_PAT:-}}"
    [[ -n "$pat" ]] || { echo "ERROR: no PAT. Pass --pat or set GITEE_PAT." >&2; exit 1; }

    local repo_dir="$dest/$(basename "${REPO%.git}")"
    clone_repo "$repo_dir" "$pat"
    source_ros
    build "$repo_dir"
    install_debs "$repo_dir"
    rm -rf "$repo_dir"
}

main "$@"
