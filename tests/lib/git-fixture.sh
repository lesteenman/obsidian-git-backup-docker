# Git fixtures for unit tests. Runs inside the image (see tests/run.sh).
#
# new_fixture creates, in a fresh temp dir $W:
#   remote.git  bare repository standing in for GitHub
#   vault/      the container's clone (VAULT); ob sync writes here
#   claude/     a second clone standing in for anyone editing on GitHub
# seeded with note.md (line1..line3) and other.md.

LOG_TAG="test"
. /src/rootfs/usr/local/lib/log-functions.sh

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

g() { git -c init.defaultBranch=main "$@"; }

new_fixture() {
  W="$(mktemp -d)"
  g init -q --bare "${W}/remote.git"
  g clone -q "${W}/remote.git" "${W}/seed" 2>/dev/null
  printf 'line1\nline2\nline3\n' > "${W}/seed/note.md"
  printf 'keep\n' > "${W}/seed/other.md"
  g -C "${W}/seed" add -A
  g -C "${W}/seed" commit -qm seed
  g -C "${W}/seed" push -q origin main
  g clone -q "${W}/remote.git" "${W}/vault"
  g clone -q "${W}/remote.git" "${W}/claude"

  VAULT="${W}/vault"
  BRANCH=main
  push_failures=0
  remote_branch_verified=false
  LOG="${W}/watcher.log"
}

# claude_commit <shell command run in claude/> — commit and push it to remote
claude_commit() {
  (cd "${W}/claude" && { g pull -q --ff-only origin main 2>/dev/null || true; } &&
    eval "$1" && g add -A && g commit -qm "claude: $1" && g push -q origin main)
}

# One watcher cycle, as triggered by a file event.
cycle() {
  do_commit_and_push >> "${LOG}" 2>&1
}

# The vault repository is in a state the watcher can keep working from, and
# everything is on the remote.
in_sync() {
  [ ! -e "${VAULT}/.git/MERGE_HEAD" ] &&
    [ ! -d "${VAULT}/.git/rebase-merge" ] &&
    [ ! -d "${VAULT}/.git/rebase-apply" ] &&
    [ -z "$(g -C "${VAULT}" status --porcelain)" ] &&
    [ "$(g -C "${VAULT}" rev-parse HEAD)" = "$(g -C "${W}/remote.git" rev-parse main)" ]
}

conflict_copy() {  # conflict_copy <glob prefix>, e.g. "note"
  ls "${VAULT}" | grep -q "^$1 (GitHub conflict "
}
