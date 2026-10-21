#!/bin/sh
# obsidian-headless's sync state must survive recreating the container.
# Without it every recreate runs an "initial" sync, which ignores
# deletions made on other devices and resolves differences by mtime only.
. "$(dirname "$0")/../lib/container.sh"

ob_log() { on_vols 'cat /config/ob-calls.log' 2>/dev/null; }

seed_remote
start_ctr
check "first start: initial sync" 'wait_for 60 "ob_log | grep -q \"no state, initial sync\""'

docker rm -f "${CTR}" >/dev/null
on_vols 'rm -f /config/ob-calls.log'
start_ctr
check "recreated container resumes from saved state" 'wait_for 60 "ob_log | grep -q \"resuming from existing state\""'

finish || { logs | tail -40; exit 1; }
