#!/bin/sh
# Basic end-to-end path: clone the remote, push a change ob sync writes.
. "$(dirname "$0")/../lib/container.sh"

seed_remote
start_ctr

check "remote cloned into /vault" 'wait_for 60 "in_ctr \"[ -f /vault/note.md ]\" 2>/dev/null"'
check "watcher started" 'wait_for 30 "logs | grep -q \"Watching for changes\""'
in_ctr 'echo "from obsidian" > /vault/new.md'
check "change committed and pushed" 'wait_for 30 "remote_has new.md \"from obsidian\""'

finish || { logs | tail -40; exit 1; }
