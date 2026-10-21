#!/bin/sh
# The periodic pull (no local file events for PULL_INTERVAL seconds).
set -u
. /src/tests/lib/assert.sh
. /src/tests/lib/git-fixture.sh
. /src/rootfs/usr/local/lib/git-sync-functions.sh

echo "remote change is pulled"
new_fixture
claude_commit 'echo gh > gh.md'
do_periodic_pull >> "${LOG}" 2>&1
check "file arrived" '[ -f "${VAULT}/gh.md" ]'
check "in sync" in_sync

echo "unpushed local commit (e.g. push cut off at shutdown) is pushed"
new_fixture
echo late > "${VAULT}/late.md"
g -C "${VAULT}" add -A && g -C "${VAULT}" commit -qm "shutdown sync"
do_periodic_pull >> "${LOG}" 2>&1
check "pushed" 'g -C "${W}/remote.git" show main:late.md 2>/dev/null | grep -q late'
check "in sync" in_sync

echo "unpushed local commit and a remote change"
new_fixture
echo late > "${VAULT}/late.md"
g -C "${VAULT}" add -A && g -C "${VAULT}" commit -qm "shutdown sync"
claude_commit 'echo gh > gh.md'
do_periodic_pull >> "${LOG}" 2>&1
check "both on remote" 'g -C "${W}/remote.git" show main:late.md >/dev/null 2>&1 && [ -f "${VAULT}/gh.md" ]'
check "in sync" in_sync

finish
