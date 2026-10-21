#!/bin/sh
# =============================================================================
# git-watcher.sh — Watches vault for changes and commits/pushes to git
#
# Uses inotifywait (event-driven, not polling) to detect filesystem changes.
# Debounces events to avoid committing during active Obsidian syncs.
#
# Runs as an s6 longrun service — s6 will restart it if it crashes.
#
# NOTE: This script uses BusyBox ash extensions (read -t) which are available
# on Alpine but are not POSIX-standard. The shebang is /bin/sh which is
# BusyBox ash on Alpine.
# =============================================================================
set -eu

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
LOG_TAG="git-watcher"
. /usr/local/lib/log-functions.sh

# ---------------------------------------------------------------------------
# Configuration (from environment, with defaults)
# ---------------------------------------------------------------------------
DEBOUNCE="${OBSIDIAN_GIT_DEBOUNCE_SECS:-30}"
PULL_INTERVAL="${OBSIDIAN_GIT_PULL_INTERVAL:-3600}"
VAULT="/vault"
BRANCH="${OBSIDIAN_GIT_BRANCH:-main}"

# ---------------------------------------------------------------------------
# Validate configuration
# ---------------------------------------------------------------------------
case "${DEBOUNCE}" in
  ''|*[!0-9]*)
    log_error "OBSIDIAN_GIT_DEBOUNCE_SECS must be a positive integer, got: '${DEBOUNCE}'"
    exit 1
    ;;
  0)
    log_error "OBSIDIAN_GIT_DEBOUNCE_SECS must be >= 1 (got 0). A zero debounce commits on every file event."
    exit 1
    ;;
esac

case "${PULL_INTERVAL}" in
  ''|*[!0-9]*)
    log_error "OBSIDIAN_GIT_PULL_INTERVAL must be a non-negative integer, got: '${PULL_INTERVAL}'"
    exit 1
    ;;
esac

# Minimum pull interval is 10 seconds (when enabled). Values 1-9 are too
# aggressive for a network operation and would cause issues with the
# EOF-vs-timeout detection in the main loop.
if [ "${PULL_INTERVAL}" -gt 0 ] && [ "${PULL_INTERVAL}" -lt 10 ]; then
  log_error "OBSIDIAN_GIT_PULL_INTERVAL must be 0 (disabled) or >= 10, got: '${PULL_INTERVAL}'"
  exit 1
fi

# Track consecutive push failures for escalating warnings
push_failures=0

# Track whether the remote branch exists. Starts false — set to true after
# the first successful push, or if ls-remote confirms the branch exists.
# Avoids a network round-trip (ls-remote) on every commit cycle.
remote_branch_verified=false

# ---------------------------------------------------------------------------
# Pull / commit / push
# ---------------------------------------------------------------------------
. /usr/local/lib/git-sync-functions.sh

# ---------------------------------------------------------------------------
# FIFO for inotifywait output
#
# inotifywait writes to a named FIFO; the main loop reads from it.
# This keeps the read loop in the main shell process (not a pipe
# subshell), so signal traps work correctly — in particular, the
# shutdown trap that commits pending changes before the container stops.
#
# A pipe (inotifywait | while read ...) would put the while loop in a
# subshell where POSIX requires traps to be reset to default disposition.
# ---------------------------------------------------------------------------
EVENTS_FIFO="$(mktemp -u /tmp/git-watcher-events.XXXXXX)"
mkfifo "${EVENTS_FIFO}"

cleanup() {
  rm -f "${EVENTS_FIFO}"
  # Kill inotifywait if still running
  [ -n "${INOTIFY_PID:-}" ] && kill "${INOTIFY_PID}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Graceful shutdown: commit any pending changes before exit
# ---------------------------------------------------------------------------
shutdown() {
  log "Shutting down — committing any pending changes..."
  do_commit_and_push || log_error "Final commit/push failed"
  cleanup
  exit 0
}

trap shutdown TERM INT
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Main: watch for filesystem events and debounce
# ---------------------------------------------------------------------------
log "Starting filesystem watcher on ${VAULT}"
if [ "${PULL_INTERVAL}" -gt 0 ]; then
  log "Debounce: ${DEBOUNCE}s | Pull interval: ${PULL_INTERVAL}s | Branch: ${BRANCH}"
else
  log "Debounce: ${DEBOUNCE}s | Periodic pull: disabled (pull only before push) | Branch: ${BRANCH}"
fi

# Wait for the vault to be ready (git repo must exist)
while [ ! -d "${VAULT}/.git" ]; do
  log "Waiting for git repository at ${VAULT}..."
  sleep 5
done

if ! check_repo_state; then
  # Stay up instead of exiting: s6 would restart the watcher in a loop.
  exec sleep infinity
fi

log "Git repository found. Watching for changes..."

# inotifywait monitors recursively, excluding noisy paths.
# These exclusions should be a superset of the vault .gitignore:
# any gitignored file should also be excluded here to avoid
# unnecessary watcher trigger → debounce → "no changes" cycles.
#
#   .git/                — git internals (would cause feedback loops)
#   .trash/              — Obsidian trash
#   cache/               — Obsidian cache (rebuilt automatically)
#   workspace*.json      — Obsidian workspace state (high churn)
#   graph.json           — Obsidian graph view state
#
# Note: plugin data.json files are NOT excluded here because they
# contain user settings (Templater, Tasks, etc.) that should be backed
# up. The vault .gitignore also does not ignore them by default.
#
# -m = monitor mode (don't exit after first event)
# -r = recursive
# -e = event types to watch
# --format = output format (we only care that *something* changed)
#
# inotifywait writes to the FIFO in the background. The main loop
# reads from the FIFO, keeping traps active in the main process.

inotifywait -m -r \
  --exclude '/\.(git|trash)(/|$)|/\.obsidian/(workspace.*\.json|graph\.json|cache/)' \
  -e modify,create,delete,move \
  --format '%w%f' \
  "${VAULT}" > "${EVENTS_FIFO}" 2>&1 &
INOTIFY_PID=$!

# Main event loop — reads from the FIFO (not a pipe subshell).
# This runs in the main shell process where trap shutdown TERM INT
# is active, ensuring graceful shutdown commits work correctly.
while true; do
  # Wait for the next filesystem event OR a pull-interval timeout.
  # - If PULL_INTERVAL=0, block until a file event arrives (no periodic pull).
  # - If PULL_INTERVAL>0, timeout after PULL_INTERVAL seconds of silence to
  #   pull any remote changes even when no local files have changed.
  #
  # read -t returns non-zero on BOTH timeout and EOF (FIFO closed).
  # We distinguish them by measuring wall-clock time: a real timeout takes
  # ~PULL_INTERVAL seconds, while EOF returns almost instantly (< 2s).
  # The minimum PULL_INTERVAL of 10s provides a large safety margin.
  if [ "${PULL_INTERVAL}" -gt 0 ]; then
    read_start="$(date +%s)"
    if ! read -t "${PULL_INTERVAL}" -r changed_file; then
      read_elapsed=$(( $(date +%s) - read_start ))
      if [ "${read_elapsed}" -lt 2 ]; then
        # EOF — inotifywait exited (FIFO closed almost immediately)
        break
      fi
      # Timeout — no local changes, but the remote may have advanced.
      log "No local changes in ${PULL_INTERVAL}s. Checking remote..."
      do_periodic_pull
      continue
    fi
  else
    if ! read -r changed_file; then
      # EOF — inotifywait exited
      break
    fi
  fi

  log "Change detected: ${changed_file}. Waiting ${DEBOUNCE}s for more changes..."

  # Debounce: drain events until DEBOUNCE seconds of silence.
  # read -t returns non-zero when the timeout expires (no more events
  # within DEBOUNCE seconds). This is safe under set -eu because the
  # while loop tests read's exit code as its condition — a non-zero
  # return simply terminates the loop without triggering set -e.
  debounce_count=0
  while read -t "${DEBOUNCE}" -r _; do
    debounce_count=$((debounce_count + 1))
  done

  [ "${debounce_count}" -gt 0 ] && log "Debounced ${debounce_count} additional change(s)"
  log "Committing changes..."

  do_commit_and_push || log_error "Commit/push cycle failed (will retry on next change)"
done < "${EVENTS_FIFO}"

# If we get here, inotifywait exited unexpectedly
log_error "inotifywait exited unexpectedly. s6 will restart this service."
cleanup
exit 1
