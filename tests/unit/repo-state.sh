#!/bin/sh
# Leftovers from a killed git process must be reported, never silently
# ignored or "fixed" by resetting the working tree.
set -u
. /src/tests/lib/assert.sh
. /src/tests/lib/git-fixture.sh
. /src/rootfs/usr/local/lib/git-sync-functions.sh

echo "commit cycle with a stale index.lock"
new_fixture
touch "${VAULT}/.git/index.lock"
echo change >> "${VAULT}/note.md"
do_commit_and_push >> "${LOG}" 2>&1
rc=$?
check "cycle reports failure" '[ "${rc}" -ne 0 ]'
check "error logged" 'grep -q "ERROR: git add failed" "${LOG}"'
check "not reported as 'No changes to commit'" '! grep -q "No changes to commit" "${LOG}"'

echo "startup check removes a stale index.lock"
new_fixture
touch "${VAULT}/.git/index.lock"
check_repo_state >> "${LOG}" 2>&1
rc=$?
check "check passes" '[ "${rc}" -eq 0 ]'
check "lock removed" '[ ! -e "${VAULT}/.git/index.lock" ]'

echo "startup check refuses an interrupted rebase"
new_fixture
claude_commit "sed -i 's/line2/line2 CLAUDE/' note.md"
sed -i 's/line2/line2 OBSIDIAN/' "${VAULT}/note.md"
g -C "${VAULT}" commit -qam local
g -C "${VAULT}" pull -q --rebase origin main >/dev/null 2>&1
check "fixture: rebase stopped on conflict" '[ -d "${VAULT}/.git/rebase-merge" ]'
before="$(cat "${VAULT}/note.md")"
check_repo_state >> "${LOG}" 2>&1
rc=$?
check "check fails" '[ "${rc}" -ne 0 ]'
check "rebase state untouched" '[ -d "${VAULT}/.git/rebase-merge" ]'
check "working tree untouched" '[ "$(cat "${VAULT}/note.md")" = "${before}" ]'
check "error logged" 'grep -q "ERROR: .*rebase-merge" "${LOG}"'

echo "startup check refuses an interrupted merge"
new_fixture
claude_commit "echo claude >> note.md"
rm "${VAULT}/note.md"
g -C "${VAULT}" commit -qam local
g -C "${VAULT}" pull -q --no-rebase origin main >/dev/null 2>&1
check "fixture: merge stopped on conflict" '[ -e "${VAULT}/.git/MERGE_HEAD" ]'
check_repo_state >> "${LOG}" 2>&1
rc=$?
check "check fails" '[ "${rc}" -ne 0 ]'
check "merge state untouched" '[ -e "${VAULT}/.git/MERGE_HEAD" ]'

echo "startup check passes on a clean repository"
new_fixture
check_repo_state >> "${LOG}" 2>&1
rc=$?
check "check passes" '[ "${rc}" -eq 0 ]'

finish
