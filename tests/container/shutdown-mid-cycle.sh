#!/bin/sh
# A stop that arrives while a commit/push cycle is running waits for the
# cycle to finish, instead of starting a second cycle inside it.
. "$(dirname "$0")/../lib/container.sh"

seed_remote
on_vols 'printf "#!/bin/sh\nsleep 8\n" > /remote/vault.git/hooks/pre-receive
  chmod +x /remote/vault.git/hooks/pre-receive'
start_ctr -e OBSIDIAN_GIT_DEBOUNCE_SECS=1 -e OBSIDIAN_GIT_PULL_INTERVAL=3600
check "watcher started" 'wait_for 90 "logs | grep -q \"Watches established\""'
in_ctr 'echo one > /vault/one.md'
check "cycle started" 'wait_for 30 "logs | grep -q \"Committing changes\""'
docker stop -t 30 "${CTR}" >/dev/null

order="$(logs | grep -E "Pushed to origin|Shutting down" | sed 's/.*\] //' | tr '\n' '|')"
echo "  (${order})"
check "cycle finished before shutdown started" 'case "${order}" in *"Pushed to origin/main|Shutting down"*) true ;; *) false ;; esac'
check "change on the remote" 'on_vols "git -C /remote/vault.git show main:one.md" 2>/dev/null | grep -q one'

finish || { logs | tail -40; exit 1; }
