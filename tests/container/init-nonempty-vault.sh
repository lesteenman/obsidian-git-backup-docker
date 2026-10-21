#!/bin/sh
# A /vault with files but no git repository (e.g. a vault folder copied in
# by hand) must never be deleted to make room for the clone.
. "$(dirname "$0")/../lib/container.sh"

exited() { [ "$(docker inspect -f '{{.State.Status}}' "${CTR}" 2>/dev/null)" = exited ]; }

seed_remote
on_vols 'echo "only copy" > "/vault/My note.md"; mkdir /vault/.obsidian; echo {} > /vault/.obsidian/app.json'
start_ctr

check "container stops" 'wait_for 60 exited'
check "existing note kept" 'on_vols "grep -q \"only copy\" \"/vault/My note.md\""'
check "existing .obsidian kept" 'on_vols "[ -f /vault/.obsidian/app.json ]"'
check "nothing cloned over it" 'on_vols "[ ! -e /vault/.git ] && [ ! -e /vault/note.md ]"'
check "reason logged" 'logs | grep -q "ERROR: /vault contains files but no git repository"'
check "ob sync never started" '! on_vols "grep -q \"ob sync \" /config/ob-calls.log 2>/dev/null"'

finish || { logs | tail -40; exit 1; }
