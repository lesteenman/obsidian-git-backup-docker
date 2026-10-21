#!/bin/sh
# Baseline behaviour of the pull/commit/push cycle without conflicts.
set -u
. /src/tests/lib/assert.sh
. /src/tests/lib/git-fixture.sh
. /src/rootfs/usr/local/lib/git-sync-functions.sh

echo "local change is committed and pushed"
new_fixture
echo "from obsidian" > "${VAULT}/new.md"
cycle
check "pushed" 'g -C "${W}/remote.git" show main:new.md | grep -q "from obsidian"'
check "in sync" in_sync

echo "remote change is pulled"
new_fixture
claude_commit 'echo "from github" > gh.md'
do_pull >> "${LOG}" 2>&1
check "file arrived" 'grep -q "from github" "${VAULT}/gh.md"'
check "in sync" in_sync

echo "different files changed on both sides"
new_fixture
claude_commit 'echo claude >> other.md'
echo obsidian >> "${VAULT}/note.md"
cycle
check "remote change arrived" 'grep -q claude "${VAULT}/other.md"'
check "local change kept" 'grep -q obsidian "${VAULT}/note.md"'
check "in sync" in_sync

finish
