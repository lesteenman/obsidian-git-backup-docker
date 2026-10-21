#!/bin/sh
# A change still in the debounce window when the container is stopped is
# committed and pushed before exit, even if the push takes a while.
# (docker-compose.yml sets stop_grace_period: 30s; `docker stop -t 30`
# does the same here.)
. "$(dirname "$0")/../lib/container.sh"

seed_remote
# Every push to the test remote takes 8 seconds.
on_vols 'printf "#!/bin/sh\nsleep 8\n" > /remote/vault.git/hooks/pre-receive
  chmod +x /remote/vault.git/hooks/pre-receive'
start_ctr -e OBSIDIAN_GIT_DEBOUNCE_SECS=60
check "watcher started" 'wait_for 60 "logs | grep -q \"Watching for changes\""'

in_ctr 'echo "written just before stop" > /vault/last.md'
sleep 2
docker stop -t 30 "${CTR}" >/dev/null
check "pending change reached the remote" 'on_vols "git -C /remote/vault.git show main:last.md" 2>/dev/null | grep -q "just before stop"'

finish || { logs | tail -40; exit 1; }
