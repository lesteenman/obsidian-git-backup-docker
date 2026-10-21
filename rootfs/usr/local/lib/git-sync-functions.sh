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
# Pull from remote — integrate origin/BRANCH without stopping mid-way
#
# obsidian-headless watches /vault and uploads whatever it finds there, to
# every device. So git must never leave the working tree in an in-between
# state: no rebase or merge in progress, no conflict markers, no files
# reverted by an abort. Instead of `git pull`, the remote is integrated
# file by file:
#
#   - no local commits since the remote          -> fast-forward
#   - otherwise, for each file the remote changed since the merge base:
#       unchanged locally                        -> take the remote version
#       same content on both sides               -> nothing to do
#       Markdown changed on both, no overlap     -> three-way merged result
#       anything else changed on both sides      -> keep the local file, write
#                                                   the remote version next to
#                                                   it as "<name> (GitHub
#                                                   conflict <stamp>).<ext>"
#       deleted remotely                         -> delete if unchanged
#                                                   locally, else keep
#       changed remotely, deleted locally        -> stays deleted, remote
#                                                   version as conflict copy
#   - record a merge commit (parents: HEAD and the remote) of the result
#
# "Locally" means the file on disk, not HEAD, so a write ob sync makes
# while this runs is treated as a local change instead of being overwritten.
# Each file is written to .git/ and renamed into place, so ob sync never
# reads a half-written file. A crash at any point leaves only ordinary
# files; the next cycle commits them and integrates again, idempotently.
#
# Unrelated histories (remote initialized separately) use an empty base, so
# every file present on both sides with different content gets a conflict
# copy.
#
# Returns 0 on success or if the remote branch does not exist yet.
# Returns 1 on failure; local commits are kept and the next cycle retries.
# ---------------------------------------------------------------------------
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
INTEGRATE_TMP=".git/ogb-integrate"

_vgit() { git -C "${VAULT}" "$@"; }

# _blob_on_disk <path> — blob id of the file in the vault, or "" if absent.
# hash-object applies clean filters (git-lfs), so it matches committed blobs.
_blob_on_disk() {
  if [ -f "${VAULT}/$1" ]; then
    _vgit hash-object -- "$1"
  else
    echo ""
  fi
}

# _blob_at <rev> <path> — blob id of path at rev, or "" if absent
_blob_at() {
  _vgit rev-parse -q --verify "$1:$2" 2>/dev/null || echo ""
}

# _place <file in INTEGRATE_TMP> <vault-relative destination>
_place() {
  mkdir -p "$(dirname "${VAULT}/$2")" && mv -f "${VAULT}/${INTEGRATE_TMP}/$1" "${VAULT}/$2"
}

# _conflict_name "dir/note.md" -> "dir/note (GitHub conflict 2026-10-21 0915).md"
_conflict_name() {
  _cn_dir="$(dirname "$1")"
  _cn_file="$(basename "$1")"
  case "${_cn_file}" in
    ?*.*) _cn_new="${_cn_file%.*} (GitHub conflict ${STAMP}).${_cn_file##*.}" ;;
    *)    _cn_new="${_cn_file} (GitHub conflict ${STAMP})" ;;
  esac
  if [ "${_cn_dir}" = "." ]; then
    printf '%s' "${_cn_new}"
  else
    printf '%s/%s' "${_cn_dir}" "${_cn_new}"
  fi
}

# _integrate_file <status> <path> — apply one remote change (see above).
# Uses base, remote. Increments conflicts. Returns 1 if a write failed.
_integrate_file() {
  _st="$1"
  _p="$2"
  _base_blob="$(_blob_at "${base}" "${_p}")"
  _remote_blob="$(_blob_at "${remote}" "${_p}")"
  _local_blob="$(_blob_on_disk "${_p}")"

  [ "${_local_blob}" = "${_remote_blob}" ] && return 0   # already identical

  if [ "${_local_blob}" = "${_base_blob}" ]; then
    # Unchanged locally: take the remote side as is.
    if [ "${_st}" = D ]; then
      rm -f "${VAULT}/${_p}"
      return 0
    fi
    _vgit cat-file --filters "${remote}:${_p}" > "${VAULT}/${INTEGRATE_TMP}/file" &&
      _place file "${_p}"
    return
  fi

  # Changed on both sides.
  if [ "${_st}" = D ]; then
    log "Kept ${_p}: deleted on GitHub, changed in Obsidian"
    return 0
  fi

  case "${_p}" in
    *.md)
      if [ -n "${_local_blob}" ]; then
        if [ -n "${_base_blob}" ]; then
          _vgit cat-file blob "${_base_blob}" > "${VAULT}/${INTEGRATE_TMP}/base" || return 1
        else
          : > "${VAULT}/${INTEGRATE_TMP}/base"
        fi
        _vgit cat-file blob "${_remote_blob}" > "${VAULT}/${INTEGRATE_TMP}/theirs" || return 1
        cp "${VAULT}/${_p}" "${VAULT}/${INTEGRATE_TMP}/ours" || return 1
        if git merge-file -q "${VAULT}/${INTEGRATE_TMP}/ours" \
             "${VAULT}/${INTEGRATE_TMP}/base" "${VAULT}/${INTEGRATE_TMP}/theirs"; then
          _place ours "${_p}" || return 1
          log "Merged ${_p} (changed on both sides, no overlapping lines)"
          return 0
        fi
      fi
      ;;
  esac

  _copy="$(_conflict_name "${_p}")"
  _vgit cat-file --filters "${remote}:${_p}" > "${VAULT}/${INTEGRATE_TMP}/file" &&
    _place file "${_copy}" || return 1
  conflicts=$((conflicts + 1))
  log_error "CONFLICT: ${_p} changed in Obsidian and on GitHub. Kept the Obsidian version;"
  log_error "the GitHub version is saved as '${_copy}'. Merge by hand and delete the copy."
}

do_pull() {
  # Check if the remote branch exists yet. On a brand-new bare repo the
  # remote has no branches at all — fetching would fail with
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

  if ! fetch_output="$(_vgit fetch --quiet origin "${BRANCH}" 2>&1)"; then
    log_error "git fetch failed: ${fetch_output}"
    log_error "Local commits are safe. Pull will be retried on the next cycle."
    return 1
  fi
  remote="$(_vgit rev-parse "origin/${BRANCH}")"

  # Up to date, or only local commits to push.
  _vgit merge-base --is-ancestor "${remote}" HEAD && return 0

  # Commit whatever ob sync wrote since the last cycle.
  _vgit add -A || { log_error "git add failed"; return 1; }
  if ! _vgit diff --cached --quiet; then
    _vgit commit --quiet -m "vault sync: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" ||
      { log_error "git commit failed"; return 1; }
  fi

  if _vgit merge-base --is-ancestor HEAD "${remote}"; then
    # git refuses (and changes nothing) if ob sync wrote a file the
    # fast-forward would overwrite; the next cycle commits it and merges.
    if ff_output="$(_vgit merge --ff-only --quiet "${remote}" 2>&1)"; then
      log "Pulled from origin/${BRANCH} (fast-forward)"
      return 0
    fi
    log_error "Fast-forward failed (will retry next cycle): ${ff_output}"
    return 1
  fi

  base="$(_vgit merge-base HEAD "${remote}" 2>/dev/null || echo "${EMPTY_TREE}")"
  STAMP="$(date -u '+%Y-%m-%d %H%M')"
  conflicts=0
  rm -rf "${VAULT:?}/${INTEGRATE_TMP}"
  mkdir -p "${VAULT}/${INTEGRATE_TMP}"

  _vgit -c core.quotePath=false diff --no-renames --name-status "${base}" "${remote}" \
    > "${VAULT}/${INTEGRATE_TMP}/changes" || { log_error "git diff failed"; return 1; }
  # Paths with tabs, newlines or quotes are printed quoted; refuse rather
  # than misread them.
  if grep -q "$(printf '\t')\"" "${VAULT}/${INTEGRATE_TMP}/changes"; then
    log_error "Remote changes include a path with special characters git quotes:"
    log_error "$(grep "$(printf '\t')\"" "${VAULT}/${INTEGRATE_TMP}/changes" | head -n 3)"
    log_error "Not integrating origin/${BRANCH}. Rename the file on GitHub."
    return 1
  fi

  failed=false
  while IFS="$(printf '\t')" read -r status path; do
    _integrate_file "${status}" "${path}" || {
      log_error "Could not write ${path}"
      failed=true
    }
  done < "${VAULT}/${INTEGRATE_TMP}/changes"
  rm -rf "${VAULT:?}/${INTEGRATE_TMP}"

  if "${failed}"; then
    log_error "Integration of origin/${BRANCH} incomplete (will retry next cycle)"
    return 1
  fi

  _vgit add -A || { log_error "git add failed"; return 1; }
  tree="$(_vgit write-tree)" &&
    commit="$(_vgit commit-tree "${tree}" -p HEAD -p "${remote}" \
      -m "merge origin/${BRANCH} (conflict copies: ${conflicts})")" &&
    _vgit update-ref -m "integrate origin/${BRANCH}" HEAD "${commit}" ||
    { log_error "Could not record merge commit (will retry next cycle)"; return 1; }

  if [ "${conflicts}" -gt 0 ]; then
    log_error "Pulled from origin/${BRANCH} with ${conflicts} conflict(s); see CONFLICT lines above"
  else
    log "Pulled from origin/${BRANCH} (merged)"
  fi
  return 0
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

# ---------------------------------------------------------------------------
# Periodic pull — run when no local file events arrived for PULL_INTERVAL
# ---------------------------------------------------------------------------
do_periodic_pull() {
  if do_pull; then
    # Push whenever local is ahead: a merge commit from do_pull, or an
    # earlier commit whose push failed or was cut off at shutdown.
    if ! "${remote_branch_verified}" ||
       [ -n "$(git -C "${VAULT}" rev-list -n 1 "origin/${BRANCH}..HEAD" 2>/dev/null)" ]; then
      log "Local commits not on origin/${BRANCH} yet. Pushing..."
      push_output="$(git -C "${VAULT}" push -u origin "${BRANCH}" 2>&1)" && {
        log "Pushed to origin/${BRANCH}"
        push_failures=0
        remote_branch_verified=true
      } || {
        log_error "Push after periodic pull failed: ${push_output}"
      }
    fi
  else
    log_error "Periodic pull failed (will retry next interval)"
  fi
}
