#!/bin/sh
# A vault left mid-rebase (container killed by an older version) must not
# be modified, nor uploaded by ob sync with conflict markers in it.
. "$(dirname "$0")/../lib/container.sh"

exited() { [ "$(docker inspect -f '{{.State.Status}}' "${CTR}" 2>/dev/null)" = exited ]; }

seed_remote
on_vols 'git clone -q /remote/vault.git /tmp/gh
  sed -i "s/line2/line2 GITHUB/" /tmp/gh/note.md
  git -C /tmp/gh commit -qam gh
  git clone -q /remote/vault.git /vault/tmp-clone
  mv /vault/tmp-clone/.git /vault/.git && mv /vault/tmp-clone/note.md /vault/ && rmdir /vault/tmp-clone
  git -C /tmp/gh push -q origin main
  sed -i "s/line2/line2 OBSIDIAN/" /vault/note.md
  git -C /vault commit -qam local
  git -C /vault pull -q --rebase origin main >/dev/null 2>&1 || true
  [ -d /vault/.git/rebase-merge ]
  cp /vault/note.md /tmp/note.before && cp /tmp/note.before /config/note.before'
start_ctr

check "container stops" 'wait_for 60 exited'
check "rebase state untouched" 'on_vols "[ -d /vault/.git/rebase-merge ]"'
check "working tree untouched" 'on_vols "cmp -s /vault/note.md /config/note.before"'
check "reason logged" 'logs | grep -q "ERROR: Interrupted git operation"'
check "ob sync never started" '! on_vols "grep -q \"ob sync \" /config/ob-calls.log 2>/dev/null"'

finish || { logs | tail -40; exit 1; }
