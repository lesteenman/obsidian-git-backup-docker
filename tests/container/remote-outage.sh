#!/bin/sh
# An unreachable remote is reported, but the watcher keeps running and
# recovers by itself once the remote is back.
. "$(dirname "$0")/../lib/container.sh"

starts() { logs | grep -c "Starting filesystem watcher"; }

seed_remote
start_ctr
check "watcher started" 'wait_for 60 "logs | grep -q \"Watches established\""'
on_vols 'mv /remote/vault.git /remote/gone.git'
sleep 25   # two periodic pulls (interval 10s) against the missing remote
check "pull failure logged" 'logs | grep -q "Periodic pull failed"'
check "watcher not restarted" '[ "$(starts)" -eq 1 ]'
on_vols 'mv /remote/gone.git /remote/vault.git'
in_ctr 'echo back > /vault/back.md'
check "pushes again after recovery" 'wait_for 40 "remote_has back.md back"'

finish || { logs | tail -40; exit 1; }
