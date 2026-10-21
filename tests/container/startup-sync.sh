#!/bin/sh
# Files ob sync writes while the watcher is still starting (before its
# inotify watches exist) are committed and pushed without waiting for a
# later change.
. "$(dirname "$0")/../lib/container.sh"

seed_remote
start_ctr -e STUB_INITIAL_FILE=initial.md -e OBSIDIAN_GIT_PULL_INTERVAL=3600
check "file written at sync start reaches the remote" 'wait_for 60 "remote_has initial.md \"at sync start\""'

finish || { logs | tail -40; exit 1; }
