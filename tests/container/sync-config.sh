#!/bin/sh
# Settings passed to `ob sync-config`.
. "$(dirname "$0")/../lib/container.sh"

sync_config_call() { on_vols 'grep "ob sync-config " /config/ob-calls.log' 2>/dev/null; }
init_done() { logs | grep -q "Initialization complete"; }

seed_remote
start_ctr -e OBSIDIAN_GIT_SYNC_CONFIGS= -e OBSIDIAN_GIT_SYNC_CONFLICT_STRATEGY=conflict
check "init completes" 'wait_for 60 init_done'
call="$(sync_config_call)"
echo "  (${call})"
check "empty OBSIDIAN_GIT_SYNC_CONFIGS disables config sync" 'printf "%s\n" "${call}" | grep -Eq -- "--configs( +--| *$)"'
check "file types keep their default" 'printf "%s\n" "${call}" | grep -q -- "--file-types image,audio,video,pdf,unsupported"'
check "empty configs warned about" 'logs | grep -q "WARNING: OBSIDIAN_GIT_SYNC_CONFIGS is set but empty"'
check "conflict strategy passed through" 'printf "%s\n" "${call}" | grep -q -- "--conflict-strategy conflict"'
docker rm -f "${CTR}" >/dev/null

start_ctr -e OBSIDIAN_GIT_SYNC_CONFLICT_STRATEGY=ask-me
check "invalid conflict strategy stops the container" 'wait_for 60 "[ \"\$(docker inspect -f {{.State.Status}} ${CTR})\" = exited ]"'
check "invalid conflict strategy explained" 'logs | grep -q "OBSIDIAN_GIT_SYNC_CONFLICT_STRATEGY must be"'

finish || { logs | tail -40; exit 1; }
