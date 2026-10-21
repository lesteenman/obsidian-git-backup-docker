#!/bin/sh
# After a fresh clone, obsidian-headless runs an "initial" sync, where the
# copy with the newer modification time wins. Cloned files must carry the
# time of the last commit, not the time of the clone; otherwise the git
# copy beats every newer edit already in Obsidian Sync.
. "$(dirname "$0")/../lib/container.sh"

on_vols 'git -c init.defaultBranch=main init -q --bare /remote/vault.git
  git clone -q /remote/vault.git /tmp/seed 2>/dev/null
  mkdir -p "/tmp/seed/Sub folder"
  echo old > "/tmp/seed/Sub folder/old note.md"
  git -C /tmp/seed add -A
  GIT_COMMITTER_DATE=@1577836800 git -C /tmp/seed commit -qm seed
  git -C /tmp/seed push -q origin HEAD:main'
# Sync state left from an earlier vault volume.
on_vols 'mkdir -p /config/xdg/obsidian-headless/sync/stub-vault
  touch /config/xdg/obsidian-headless/sync/stub-vault/state.db'
start_ctr

mtime() { in_ctr "stat -c %Y \"/vault/$1\"" 2>/dev/null; }
check "init completes" 'wait_for 60 "logs | grep -q \"Initialization complete\""'
check "cloned file has the commit time" '[ "$(mtime "Sub folder/old note.md")" = 1577836800 ]'
check "stale sync state discarded" 'wait_for 30 "on_vols \"grep -q \\\"no state, initial sync\\\" /config/ob-calls.log\""'

finish || { logs | tail -40; exit 1; }
