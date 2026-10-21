# Host-side helpers for container tests. Source with the image as $1.
#
# Each test gets three named volumes (bind mounts on Docker Desktop appear
# root-owned inside the container, which trips git's ownership check):
#   ${CTR}-remote  /remote/vault.git, a bare repository standing in for GitHub
#   ${CTR}-config  the /config volume
#   ${CTR}-vault   the /vault volume
# Inspect or change them with `on_vols <shell command>`.
set -eu

IMAGE="$1"
. "$(dirname "$0")/../lib/assert.sh"

CTR="ogb-test-$$"
VOLS="-v ${CTR}-remote:/remote -v ${CTR}-config:/config -v ${CTR}-vault:/vault"

_cleanup() {
  docker rm -f "${CTR}" >/dev/null 2>&1 || true
  docker volume rm "${CTR}-remote" "${CTR}-config" "${CTR}-vault" >/dev/null 2>&1 || true
}
trap _cleanup EXIT

# on_vols <shell command> — run as root in a throwaway container with the
# test volumes mounted, using the image's git. Files end up owned by 1000.
on_vols() {
  # shellcheck disable=SC2086
  docker run --rm ${VOLS} --entrypoint sh \
    -e GIT_CONFIG_GLOBAL=/dev/null -e GIT_CONFIG_NOSYSTEM=1 \
    -e GIT_AUTHOR_NAME=test -e GIT_AUTHOR_EMAIL=test@example.invalid \
    -e GIT_COMMITTER_NAME=test -e GIT_COMMITTER_EMAIL=test@example.invalid \
    "${IMAGE}" -c "set -e; $1; chown -R 1000:1000 /remote /config /vault"
}

seed_remote() {
  on_vols 'git -c init.defaultBranch=main init -q --bare /remote/vault.git
    git clone -q /remote/vault.git /tmp/seed 2>/dev/null
    printf "line1\nline2\nline3\n" > /tmp/seed/note.md
    git -C /tmp/seed add -A
    git -C /tmp/seed commit -qm seed
    git -C /tmp/seed push -q origin HEAD:main'
}

# start_ctr [docker run options...]
start_ctr() {
  # shellcheck disable=SC2086
  docker run -d --name "${CTR}" ${VOLS} \
    -e OBSIDIAN_AUTH_TOKEN=dummy \
    -e OBSIDIAN_GIT_VAULT_NAME=test \
    -e OBSIDIAN_GIT_REMOTE_URL=/remote/vault.git \
    -e OBSIDIAN_GIT_DEBOUNCE_SECS=2 \
    -e OBSIDIAN_GIT_PULL_INTERVAL=10 \
    "$@" "${IMAGE}" >/dev/null
}

# in_ctr <shell command> — run as the obsidian user inside the container
in_ctr() {
  docker exec -u obsidian "${CTR}" sh -c "$1"
}

logs() {
  docker logs "${CTR}" 2>&1
}

# wait_for <seconds> <shell condition>
wait_for() {
  _deadline=$(( $(date +%s) + $1 ))
  while ! eval "$2"; do
    [ "$(date +%s)" -lt "${_deadline}" ] || return 1
    sleep 1
  done
}

remote_has() {  # remote_has <path> <grep pattern>
  in_ctr "git -C /remote/vault.git show 'main:$1'" 2>/dev/null | grep -q "$2"
}

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "${CTR}" 2>/dev/null)" = true ]
}
