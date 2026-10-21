#!/bin/sh
# Changes pushed to GitHub while the container was down arrive at start,
# not one pull interval later.
. "$(dirname "$0")/../lib/container.sh"

seed_remote
start_ctr -e OBSIDIAN_GIT_PULL_INTERVAL=3600
check "watcher started" 'wait_for 60 "logs | grep -q \"Watching for changes\""'
docker stop -t 30 "${CTR}" >/dev/null

on_vols 'rm -f /config/health
  git clone -q /remote/vault.git /tmp/c
  echo "while down" > /tmp/c/down.md
  git -C /tmp/c add -A && git -C /tmp/c commit -qm down && git -C /tmp/c push -q origin main'

docker start "${CTR}" >/dev/null
check "remote change pulled at start" 'wait_for 60 "in_ctr \"[ -f /vault/down.md ]\" 2>/dev/null"'
check "health status written" 'wait_for 10 "in_ctr \"grep -q ^ok /config/health\" 2>/dev/null"'

finish || { logs | tail -40; exit 1; }
