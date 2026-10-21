#!/bin/sh
# The health file the Docker HEALTHCHECK reads (see healthcheck.sh).
set -u
. /src/tests/lib/assert.sh
. /src/tests/lib/git-fixture.sh
. /src/rootfs/usr/local/lib/git-sync-functions.sh

healthcheck() {
  HEALTH_FILE="${HEALTH_FILE}" sh /src/rootfs/usr/local/bin/healthcheck.sh >/dev/null 2>&1
}
state() { cut -d' ' -f1 "${HEALTH_FILE}" 2>/dev/null; }

echo "no status yet"
new_fixture
check "unhealthy" '! healthcheck'

echo "successful push"
new_fixture
echo x > "${VAULT}/x.md"
cycle
check "state ok" '[ "$(state)" = ok ]'
check "healthy" healthcheck

echo "failed push"
new_fixture
cycle
g -C "${VAULT}" remote set-url origin "${W}/missing.git"
echo x > "${VAULT}/x.md"
cycle
check "state error" '[ "$(state)" = error ]'
check "unhealthy" '! healthcheck'
check "reason recorded" 'grep -q "push failed" "${HEALTH_FILE}"'

echo "failed git add"
new_fixture
touch "${VAULT}/.git/index.lock"
echo x > "${VAULT}/x.md"
cycle
check "state error" '[ "$(state)" = error ]'

echo "periodic pull: nothing to do"
new_fixture
do_periodic_pull >> "${LOG}" 2>&1
check "state ok" '[ "$(state)" = ok ]'

echo "periodic pull: fetch fails"
new_fixture
do_periodic_pull >> "${LOG}" 2>&1
g -C "${VAULT}" remote set-url origin "${W}/missing.git"
do_periodic_pull >> "${LOG}" 2>&1
check "state error" '[ "$(state)" = error ]'

echo "recovery after an error"
g -C "${VAULT}" remote set-url origin "${W}/remote.git"
do_periodic_pull >> "${LOG}" 2>&1
check "state ok again" '[ "$(state)" = ok ]'

echo "stale ok status"
new_fixture
printf 'ok %s\n' "$(( $(date +%s) - 4 * 3600 ))" > "${HEALTH_FILE}"
check "unhealthy after 3 pull intervals" '! OBSIDIAN_GIT_PULL_INTERVAL=3600 healthcheck'
check "no age limit with periodic pull disabled" 'OBSIDIAN_GIT_PULL_INTERVAL=0 healthcheck'

finish
