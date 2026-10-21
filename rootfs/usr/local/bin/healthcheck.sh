#!/bin/sh
# =============================================================================
# healthcheck.sh — Docker HEALTHCHECK for the git watcher
#
# Healthy when the watcher's last pull or push succeeded (HEALTH_FILE says
# "ok") and that was less than 3 pull intervals ago. With the periodic pull
# disabled (OBSIDIAN_GIT_PULL_INTERVAL=0) there is no age limit, since the
# watcher may legitimately do nothing until the next change in Obsidian.
#
# Prints the reason on failure; `docker inspect` shows it under .State.Health.
# =============================================================================
HEALTH_FILE="${HEALTH_FILE:-/config/health}"
PULL_INTERVAL="${OBSIDIAN_GIT_PULL_INTERVAL:-3600}"

if ! read -r state since reason < "${HEALTH_FILE}" 2>/dev/null; then
  echo "no pull or push has completed yet"
  exit 1
fi

if [ "${state}" != ok ]; then
  echo "last pull/push failed: ${reason}"
  exit 1
fi

if [ "${PULL_INTERVAL}" -gt 0 ]; then
  age=$(( $(date +%s) - since ))
  if [ "${age}" -ge $(( PULL_INTERVAL * 3 )) ]; then
    echo "no successful pull or push in ${age}s"
    exit 1
  fi
fi

echo "ok"
