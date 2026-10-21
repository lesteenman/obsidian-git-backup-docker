# =============================================================================
# git-sync-functions.sh — Git pull/commit/push logic used by git-watcher.sh
#
# Kept separate from the watcher's event loop so the functions can be sourced
# and exercised by the test suite (tests/) without inotify or s6.
#
# The sourcing script must define log/log_error (log-functions.sh) and set:
#   VAULT                   path of the git work tree
#   BRANCH                  branch to pull from and push to
#   push_failures           consecutive push failure counter (start at 0)
#   remote_branch_verified  "true"/"false" — remote branch known to exist
# =============================================================================

# ---------------------------------------------------------------------------
# Pull from remote — rebase first, merge fallback if rebase fails
#
# Strategy:
#   1. Try git pull --rebase (linear history, clean)
#   2. If rebase fails (conflicts), abort and fall back to merge with
#      -X ours (local/Obsidian content wins conflicts, remote history
#      is fully preserved in the merge commit)
#   3. --allow-unrelated-histories handles the case where local and
#      remote were initialized independently (e.g., container started
#      against an empty remote, then the remote was initialized
#      separately from another machine)
#
# Returns 0 on success or if remote is empty. Returns 1 on failure.
# On failure, local commits are preserved — the caller should still
# attempt to push (which will fail on divergence but succeed if the
# issue was transient).
# ---------------------------------------------------------------------------
do_pull() {
  # Check if the remote branch exists yet. On a brand-new bare repo the
  # remote has no branches at all — pulling would fail with
  # "couldn't find remote ref <branch>".
  #
  # We cache the result after the first successful push to avoid a network
  # round-trip (ls-remote) on every commit cycle.
  if ! "${remote_branch_verified}"; then
    if git -C "${VAULT}" ls-remote --exit-code --heads origin "${BRANCH}" >/dev/null 2>&1; then
      remote_branch_verified=true
    else
      log "Remote branch origin/${BRANCH} does not exist yet — skipping pull"
      return 0
    fi
  fi

  # Strategy 1: Rebase (preferred — keeps linear history)
  # --allow-unrelated-histories handles independently initialized repos.
  # The exit code of the command substitution is tested via && — this is
  # correct in BusyBox ash (the assignment propagates the subcommand's
  # exit code to the && test).
  pull_output="$(git -C "${VAULT}" pull --rebase --allow-unrelated-histories origin "${BRANCH}" 2>&1)" && {
    log "Pulled from origin/${BRANCH} (rebase)"
    return 0
  }

  # Rebase failed — log at info level since we have a fallback.
  # Only escalate to log_error if both strategies fail.
  log "Rebase failed, attempting merge fallback..."

  # Abort the failed rebase to restore the working tree
  git -C "${VAULT}" rebase --abort 2>/dev/null || true

  # Strategy 2: Merge fallback with local wins (-X ours)
  # Creates a merge commit but preserves ALL history from both sides.
  # -X ours: for conflicting hunks, keep the local (Obsidian) version.
  # Non-conflicting remote changes are still merged in normally.
  merge_output="$(git -C "${VAULT}" pull --no-rebase --allow-unrelated-histories -X ours origin "${BRANCH}" 2>&1)" && {
    log "Pulled from origin/${BRANCH} (merge, local wins)"
    log_error "WARNING: Merge fallback was used — remote changes were merged with local"
    log_error "content taking priority for any conflicts. Files from the remote may"
    log_error "have appeared in your vault and will be synced to all Obsidian devices."
    log_error "Review /vault for unexpected files if the remote was independently initialized."
    return 0
  }

  # Both strategies failed — this is unusual (e.g., network error, lock file)
  log_error "git pull failed (both rebase and merge strategies):"
  log_error "${merge_output}"
  log_error "Local commits are safe. Pull will be retried on the next cycle."
  return 1
}

# ---------------------------------------------------------------------------
# Commit and push any staged changes
# ---------------------------------------------------------------------------
do_commit_and_push() {
  # Stage everything (use -C to avoid cd side effects)
  git -C "${VAULT}" add -A

  # Only commit if there are actual changes
  if git -C "${VAULT}" diff --cached --quiet; then
    log "No changes to commit"
    return 0
  fi

  TIMESTAMP="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  COMMIT_MSG="vault sync: ${TIMESTAMP}"

  if git -C "${VAULT}" commit -m "${COMMIT_MSG}"; then
    log "Committed: ${COMMIT_MSG}"
  else
    log_error "git commit failed"
    return 1
  fi

  # Pull before push to handle any divergence with the remote
  do_pull || true  # don't abort on pull failure — still attempt push

  # Use -u (--set-upstream) so the first push to an empty remote creates the
  # branch. On subsequent pushes this is a harmless no-op.
  push_output="$(git -C "${VAULT}" push -u origin "${BRANCH}" 2>&1)" && {
    log "Pushed to origin/${BRANCH}"
    push_failures=0
    remote_branch_verified=true
    return 0
  }

  # Push failed
  push_failures=$((push_failures + 1))
  log_error "git push failed (${push_failures} consecutive failure(s)):"
  log_error "${push_output}"
  log_error "Your commit is saved locally. Push will be retried on the next file change."

  if [ "${push_failures}" -ge 5 ]; then
    log_error "WARNING: ${push_failures} consecutive push failures. Backup is NOT reaching the remote."
    log_error "Check your SSH key, network, and git remote configuration."
  fi

  # Don't return error — commit is local, push will be retried
}
