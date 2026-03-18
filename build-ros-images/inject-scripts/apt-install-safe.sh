#!/usr/bin/env bash
# apt-install-safe.sh — Robust apt package installer with availability checking.
#
# Usage: apt-install-safe.sh [--log <path>] [--debug] pkg1 pkg2 pkg3 ...
#
# Features:
#   - Deduplicates the input package list
#   - Runs apt-get update with retries
#   - Checks each package via apt-cache policy; skips unavailable ones
#   - Installs only available packages
#   - Logs requested / installed / skipped packages with structured output
#   - Cleans up /var/lib/apt/lists/* after install
#   - Exits non-zero only if apt-get install itself fails

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Constants ─────────────────────────────────────────────────────────────────

_START_TIME=$(date +%s)
LOG="/var/log/apt/install-safe.log"
_PREFIX="[apt-install-safe]"
_DEBUG=false

_LOG_SEP="════════════════════════════════════════════════════════════════════════════════"
_LOG_SEC="────────────────────────────────────────────────────────────────────────────────"

# ── Globals (populated by phase functions) ────────────────────────────────────

PKGS=()
UNIQUE=()
TO_INSTALL=()
SKIPPED=()
INSTALL_STATUS="success"
INSTALL_RC=0

# ── Helper functions ──────────────────────────────────────────────────────────

as_root() { [[ $EUID -eq 0 ]] && "$@" || sudo "$@"; }

log_section() {
  echo "$_LOG_SEC"
  printf "  %-76s\n" "$1"
  echo "$_LOG_SEC"
}

log_item() {
  printf "    %-4s  %s\n" "$1" "$2"
}

_log_numbered_list() {
  local title="$1"
  shift
  log_section "$title"
  if [[ $# -eq 0 ]]; then
    printf '    (none)\n'
  else
    local idx=1
    for p in "$@"; do
      log_item "$idx." "$p"
      ((idx++)) || true
    done
  fi
  echo
}

# ── Phase functions ───────────────────────────────────────────────────────────

_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --log)
      LOG="$2"
      shift 2
      ;;
    --debug)
      _DEBUG=true
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      PKGS+=("$1")
      shift
      ;;
    esac
  done
}

_validate_input() {
  if [[ ${#PKGS[@]} -eq 0 ]]; then
    echo "No packages specified." >&2
    exit 0
  fi
}

_deduplicate() {
  declare -A seen
  for p in "${PKGS[@]}"; do
    if [[ -z ${seen[$p]+x} ]]; then
      seen[$p]=1
      UNIQUE+=("$p")
    fi
  done
}

_check_sudo() {
  if [[ $EUID -ne 0 ]] && ! command -v sudo &>/dev/null; then
    echo "$_PREFIX ERROR: not root and sudo is unavailable" >&2
    exit 1
  fi
}

_setup_error_trap() {
  trap 'rc=$?
    tail -n 80 /var/log/apt/term.log 2>/dev/null || true
    tail -n 80 /var/log/dpkg.log    2>/dev/null || true
    exit $rc' ERR
}

_apt_update() {
  echo "$_PREFIX Configured apt sources:"
  find /etc/apt/sources.list.d/ -name '*.list' -o -name '*.sources' 2>/dev/null |
    sort | while read -r f; do echo "  $f"; done
  [[ -f /etc/apt/sources.list ]] && echo "  /etc/apt/sources.list"

  echo "$_PREFIX Running apt-get update ..."
  local output
  output="$(as_root apt-get update -o Acquire::Retries=5 2>&1)" || {
    echo "$_PREFIX apt-get update FAILED (exit $?)"
    echo "$output"
    exit 1
  }

  local warnings
  warnings="$(grep -iE '^(W:|E:|Err:|Hit:|Ign:)' <<<"$output" || true)"
  if [[ -n $warnings ]]; then
    echo "$_PREFIX apt-get update warnings/status:"
    echo "$warnings"
  fi
}

_fix_apt_permissions() {
  as_root install -d -m 0755 /var/cache/apt/archives/partial
  as_root chmod -R u+rwX,go+rX /var/cache/apt/archives
}

_check_availability() {
  for p in "${UNIQUE[@]}"; do
    local pol cand
    pol="$(apt-cache policy "$p" 2>/dev/null || true)"
    cand="$(awk -F': ' '/Candidate:/ {print $2; exit}' <<<"$pol" || true)"
    if [[ -n $cand && $cand != "(none)" ]]; then
      TO_INSTALL+=("$p")
    else
      SKIPPED+=("$p")
      echo "$_PREFIX SKIP '$p' — apt-cache policy output:"
      echo "$pol" | sed 's/^/    /'
    fi
  done
}

_print_debug_diagnostics() {
  $_DEBUG || return 0
  echo ""
  echo "======== [DEBUG] apt-cache policy for each requested package ========"
  for p in "${UNIQUE[@]}"; do
    echo "--- $p ---"
    apt-cache policy "$p" 2>&1 || true
  done
  echo ""
  echo "======== [DEBUG] apt-cache stats ========"
  apt-cache stats 2>&1 || true
  echo ""
  echo "======== [DEBUG] dpkg architecture info ========"
  dpkg --print-architecture 2>&1 || true
  dpkg --print-foreign-architectures 2>&1 || true
  echo ""
  echo "======== [DEBUG] ROS_DISTRO=${ROS_DISTRO:-<unset>} ========"
  echo "======== [DEBUG] end ========"
  echo ""
}

_write_log_header() {
  as_root mkdir -p "$(dirname "$LOG")"

  local buf
  buf="$(
    printf '\n\n\n'
    echo "$_LOG_SEP"
    printf '  apt-install-safe  |  %s  |  host: %s  |  pid: %d\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(hostname -s 2>/dev/null || echo '?')" "$$"
    echo "$_LOG_SEP"
    _log_numbered_list "PACKAGES REQUESTED  (${#UNIQUE[@]})" "${UNIQUE[@]}"
    _log_numbered_list "TO INSTALL  (${#TO_INSTALL[@]})" ${TO_INSTALL[@]+"${TO_INSTALL[@]}"}
    _log_numbered_list "SKIPPED — not found in any enabled repository  (${#SKIPPED[@]})" ${SKIPPED[@]+"${SKIPPED[@]}"}
  )"
  echo "$buf" | as_root tee -a "$LOG" >/dev/null

  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "$_PREFIX Skipping unavailable packages: ${SKIPPED[*]}"
  fi
}

_install() {
  if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
    echo "$_PREFIX Installing ${#TO_INSTALL[@]} packages: ${TO_INSTALL[*]}"
    as_root apt-get install -y --no-install-recommends "${TO_INSTALL[@]}" || {
      INSTALL_RC=$?
      INSTALL_STATUS="FAILED (exit ${INSTALL_RC})"
      echo "$_PREFIX install failed with exit code ${INSTALL_RC}"
      echo "$_PREFIX Last 40 lines of /var/log/apt/term.log:"
      tail -n 40 /var/log/apt/term.log 2>/dev/null || true
      echo "$_PREFIX Last 40 lines of /var/log/dpkg.log:"
      tail -n 40 /var/log/dpkg.log 2>/dev/null || true
    }
  else
    echo "$_PREFIX Nothing to install."
  fi
}

_cleanup() {
  as_root rm -rf /var/lib/apt/lists/*
}

_write_log_footer() {
  local elapsed=$(($(date +%s) - _START_TIME))

  local buf
  buf="$(
    log_section "RESULT"
    printf '    %-10s  %s\n' "Status:" "$INSTALL_STATUS"
    printf '    %-10s  %ds\n' "Elapsed:" "$elapsed"
    echo "$_LOG_SEC"
  )"
  echo "$buf" | as_root tee -a "$LOG" >/dev/null

  echo "$_PREFIX Done.  (${elapsed}s)"
}

# ── Entry point ───────────────────────────────────────────────────────────────

main() {
  _parse_args "$@"
  _validate_input
  _deduplicate
  _check_sudo
  _setup_error_trap
  _apt_update
  _fix_apt_permissions
  _check_availability
  _print_debug_diagnostics
  _write_log_header
  _install
  _cleanup
  _write_log_footer
  exit "$INSTALL_RC"
}

main "$@"
