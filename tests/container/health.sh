#!/bin/sh
# Docker health status follows the watcher's pulls and pushes.
. "$(dirname "$0")/../lib/container.sh"

health() { docker inspect -f '{{.State.Health.Status}}' "${CTR}" 2>/dev/null; }

seed_remote
start_ctr --health-interval=2s --health-retries=1 --health-start-period=0s

check "watcher started" 'wait_for 60 "logs | grep -q \"Watches established\""'
in_ctr 'echo one > /vault/one.md'
check "healthy after a successful push" 'wait_for 30 "[ \"\$(health)\" = healthy ]"'

on_vols 'mv /remote/vault.git /remote/gone.git'
in_ctr 'echo two > /vault/two.md'
check "unhealthy after a failed push" 'wait_for 30 "[ \"\$(health)\" = unhealthy ]"'
check "reason visible in docker inspect" 'docker inspect -f "{{json .State.Health.Log}}" "${CTR}" | grep -q "push failed"'

on_vols 'mv /remote/gone.git /remote/vault.git'
in_ctr 'echo three > /vault/three.md'
check "healthy again after recovery" 'wait_for 30 "[ \"\$(health)\" = healthy ]"'

finish || { logs | tail -40; exit 1; }
