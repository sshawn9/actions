#!/usr/bin/env bash
# apt-install-safe.sh — Robust apt package installer with availability checking.
#
# Usage: apt-install-safe.sh [--log <path>] pkg1 pkg2 pkg3 ...
#
# Features:
#   - Deduplicates the input package list
#   - Runs apt-get update with retries
#   - Checks each package via apt-cache policy; skips unavailable ones
#   - Installs only available packages
#   - Logs requested / installed / skipped packages with structured output
#   - Cleans up /var/lib/apt/lists/* after install
#   - Exits non-zero only if apt-get install itself fails

# -e: exit on any error; -u: unset variables are errors; -o pipefail: catch pipe failures
set -euo pipefail
# Suppress interactive prompts during package installation (required in Docker/CI)
export DEBIAN_FRONTEND=noninteractive
# Record wall-clock start time for elapsed reporting
_START_TIME=$(date +%s)

# ── Constants ─────────────────────────────────────────────────────────────────

# Grouped with apt's own logs under /var/log/apt/ for consistent log management
LOG="/var/log/apt/install-safe.log"

# Heavy separator wraps each invocation; light separator wraps each section
_LOG_SEP="════════════════════════════════════════════════════════════════════════════════"
_LOG_SEC="────────────────────────────────────────────────────────────────────────────────"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Print a section header block to stdout (caller redirects to the log)
log_section() {
  echo "$_LOG_SEC"
  printf "  %-76s\n" "$1"
  echo "$_LOG_SEC"
}

# Print a single indented numbered item to stdout
log_item() {
  printf "    %-4s  %s\n" "$1" "$2"
}

# Run a command as root: use sudo only when the current user is not root
as_root() { [[ $EUID -eq 0 ]] && "$@" || sudo "$@"; }

# ── Arguments ─────────────────────────────────────────────────────────────────

PKGS=()

# Standard option-parsing loop: consumes $@ left-to-right
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)
      LOG="$2"
      shift 2   # skip both the flag and its value
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

# ── Validate ──────────────────────────────────────────────────────────────────

if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "No packages specified." >&2
  exit 0
fi

# ── Deduplicate ───────────────────────────────────────────────────────────────

# Use an associative array as a seen-set to preserve first-occurrence order
declare -A _seen
UNIQUE=()
for p in "${PKGS[@]}"; do
  # "${_seen[$p]+x}" expands to "x" if the key exists, "" if not —
  # the only reliable way to test key existence in a bash associative array
  if [[ -z "${_seen[$p]+x}" ]]; then
    _seen[$p]=1
    UNIQUE+=("$p")
  fi
done

# ── Error trap ────────────────────────────────────────────────────────────────

# On any unexpected error: dump the last 80 lines of apt/dpkg logs, then
# re-exit with the original non-zero code to preserve the error signal
trap 'rc=$?
  tail -n 80 /var/log/apt/term.log 2>/dev/null || true
  tail -n 80 /var/log/dpkg.log    2>/dev/null || true
  exit $rc' ERR

# ── apt-get update ────────────────────────────────────────────────────────────

# [PERMANENT] Show apt source list for diagnostics
echo "[apt-install-safe] Configured apt sources:"
find /etc/apt/sources.list.d/ -name '*.list' -o -name '*.sources' 2>/dev/null | sort | while read -r f; do
  echo "  $f"
done
[[ -f /etc/apt/sources.list ]] && echo "  /etc/apt/sources.list"

# -o Acquire::Retries=5: retry downloads up to 5 times on transient network errors
echo "[apt-install-safe] Running apt-get update ..."
APT_UPDATE_OUTPUT="$(as_root apt-get update -o Acquire::Retries=5 2>&1)" || {
  echo "[apt-install-safe] apt-get update FAILED (exit $?)"
  echo "$APT_UPDATE_OUTPUT"
  exit 1
}

# [PERMANENT] Show warnings/errors from apt-get update (Failed to fetch, hash mismatch, etc.)
APT_UPDATE_WARNINGS="$(grep -iE '^(W:|E:|Err:|Hit:|Ign:)' <<<"$APT_UPDATE_OUTPUT" || true)"
if [[ -n "$APT_UPDATE_WARNINGS" ]]; then
  echo "[apt-install-safe] apt-get update warnings/status:"
  echo "$APT_UPDATE_WARNINGS"
fi

# ── Fix permissions ───────────────────────────────────────────────────────────

# Some environments leave the partial dir missing or with wrong perms, causing apt to fail
as_root install -d -m 0755 /var/cache/apt/archives/partial
# u+rwX: owner read/write/execute-on-dirs; go+rX: others read/execute-on-dirs
as_root chmod -R u+rwX,go+rX /var/cache/apt/archives

# ── Check availability ────────────────────────────────────────────────────────

TO_INSTALL=()
SKIPPED=()

for p in "${UNIQUE[@]}"; do
  # Suppress errors for unknown package names
  pol="$(apt-cache policy "$p" 2>/dev/null || true)"
  # Extract the "Candidate:" value; -F': ' splits on colon+space
  cand="$(awk -F': ' '/Candidate:/ {print $2; exit}' <<<"$pol" || true)"
  # A candidate of "(none)" means the package is not in any enabled repo
  if [[ -n "$cand" && "$cand" != "(none)" ]]; then
    TO_INSTALL+=("$p")
  else
    SKIPPED+=("$p")
    # [PERMANENT] Show why a package was skipped
    echo "[apt-install-safe] SKIP '$p' — apt-cache policy output:"
    echo "$pol" | sed 's/^/    /'
  fi
done

# ── DEBUG: detailed package diagnostics ───────────────────────────────────────
# [DEBUG] Remove this block after troubleshooting exit-code-100 issue
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
# [DEBUG] end
# ──────────────────────────────────────────────────────────────────────────────

# ── Log header ────────────────────────────────────────────────────────────────

as_root mkdir -p "$(dirname "$LOG")"

{
  # Three blank lines before each run make boundaries obvious when tailing
  printf '\n\n\n'
  echo "$_LOG_SEP"
  printf '  apt-install-safe  |  %s  |  host: %s  |  pid: %d\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$(hostname -s 2>/dev/null || echo '?')" "$$"
  echo "$_LOG_SEP"

  log_section "PACKAGES REQUESTED  (${#UNIQUE[@]})"
  idx=1
  for p in "${UNIQUE[@]}"; do
    log_item "$idx." "$p"
    (( idx++ )) || true
  done
  echo

  log_section "TO INSTALL  (${#TO_INSTALL[@]})"
  if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
    idx=1
    for p in "${TO_INSTALL[@]}"; do
      log_item "$idx." "$p"
      (( idx++ )) || true
    done
  else
    printf '    (none)\n'
  fi
  echo

  log_section "SKIPPED — not found in any enabled repository  (${#SKIPPED[@]})"
  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    idx=1
    for p in "${SKIPPED[@]}"; do
      log_item "$idx." "$p"
      (( idx++ )) || true
    done
  else
    printf '    (none)\n'
  fi
  echo

} | as_root tee -a "$LOG" > /dev/null

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "[apt-install-safe] Skipping unavailable packages: ${SKIPPED[*]}"
fi

# ── Install ───────────────────────────────────────────────────────────────────

INSTALL_STATUS="success"
INSTALL_RC=0

if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
  # [PERMANENT] Show exact install command for reproducibility
  echo "[apt-install-safe] Installing ${#TO_INSTALL[@]} packages: ${TO_INSTALL[*]}"
  as_root apt-get install -y --no-install-recommends "${TO_INSTALL[@]}" || {
    INSTALL_RC=$?
    INSTALL_STATUS="FAILED (exit ${INSTALL_RC})"
    # [PERMANENT] On failure, dump detailed apt/dpkg state
    echo "[apt-install-safe] install failed with exit code ${INSTALL_RC}"
    echo "[apt-install-safe] Last 40 lines of /var/log/apt/term.log:"
    tail -n 40 /var/log/apt/term.log 2>/dev/null || true
    echo "[apt-install-safe] Last 40 lines of /var/log/dpkg.log:"
    tail -n 40 /var/log/dpkg.log 2>/dev/null || true
  }
else
  echo "[apt-install-safe] Nothing to install."
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────

# Remove package index files to reduce image layer size (standard Docker practice)
as_root rm -rf /var/lib/apt/lists/*

# ── Log footer ────────────────────────────────────────────────────────────────

_ELAPSED=$(( $(date +%s) - _START_TIME ))

{
  log_section "RESULT"
  printf '    %-10s  %s\n'  "Status:"  "$INSTALL_STATUS"
  printf '    %-10s  %ds\n' "Elapsed:" "$_ELAPSED"
  echo "$_LOG_SEP"
} | as_root tee -a "$LOG" > /dev/null

echo "[apt-install-safe] Done.  (${_ELAPSED}s)"
exit $INSTALL_RC
