#!/bin/sh
# Only filesystem events may trigger a commit cycle. inotifywait's own
# messages ("Setting up watches", errors such as running out of watches)
# belong in the log, not in the event stream.
. "$(dirname "$0")/../lib/container.sh"

seed_remote
start_ctr -e OBSIDIAN_GIT_DEBOUNCE_SECS=1
check "watcher started" 'wait_for 60 "logs | grep -q \"Watches established\""'
sleep 5
check "no change detected without a file change" '! logs | grep -q "Change detected: [^/]"'

finish || { logs | tail -40; exit 1; }
