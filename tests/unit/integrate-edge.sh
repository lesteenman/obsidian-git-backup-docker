#!/bin/sh
# Edge cases of the file-by-file integration (do_pull), mostly from review.
set -u
. /src/tests/lib/assert.sh
. /src/tests/lib/git-fixture.sh
. /src/rootfs/usr/local/lib/git-sync-functions.sh

remote_has_path() { g -C "${W}/remote.git" cat-file -e "main:$1" 2>/dev/null; }

echo "remote file matching the vault's .gitignore is not deleted"
new_fixture
claude_commit "echo '*.log' > .gitignore"
do_pull >> "${LOG}" 2>&1
claude_commit "echo keep > keep.log && git add -f keep.log"
echo local >> "${VAULT}/note.md"
cycle
check "file written to the vault" '[ -f "${VAULT}/keep.log" ]'
check "file still on the remote" 'remote_has_path keep.log'

finish
