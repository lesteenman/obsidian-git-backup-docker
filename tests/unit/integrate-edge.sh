#!/bin/sh
# Edge cases of the file-by-file integration (do_pull), mostly from review.
set -u
. /src/tests/lib/assert.sh
. /src/tests/lib/git-fixture.sh
. /src/rootfs/usr/local/lib/git-sync-functions.sh

remote_has_path() { g -C "${W}/remote.git" cat-file -e "main:$1" 2>/dev/null; }

echo "remote file matching the vault's .gitignore is not deleted"
new_fixture
claude_commit "echo '*.log' > .gitignore"
do_pull >> "${LOG}" 2>&1
claude_commit "echo keep > keep.log && git add -f keep.log"
echo local >> "${VAULT}/note.md"
cycle
check "file written to the vault" '[ -f "${VAULT}/keep.log" ]'
check "file still on the remote" 'remote_has_path keep.log'

echo "folder replaced by a file of the same name on the remote"
new_fixture
claude_commit "mkdir -p topic && echo x > topic/a.md"
do_pull >> "${LOG}" 2>&1
claude_commit "git rm -rq topic && echo file > topic"
echo local >> "${VAULT}/note.md"
cycle
check "folder replaced by the file" '[ -f "${VAULT}/topic" ] && grep -q file "${VAULT}/topic"'
check "in sync" in_sync

echo "remote file where the vault has a folder with local files"
new_fixture
mkdir "${VAULT}/topic" && echo mine > "${VAULT}/topic/mine.md"
cycle
claude_commit "git rm -rq topic && echo file > topic"
echo new > "${VAULT}/topic/new.md"
cycle
check "new local file in the folder kept" 'grep -q new "${VAULT}/topic/new.md"'
check "no stray file inside the folder" '[ ! -e "${VAULT}/topic/file" ]'
check "remote file kept as conflict copy" 'ls "${VAULT}" | grep -q "^topic (git conflict "'
check "in sync" in_sync

echo "two conflicts on the same file in the same minute keep both copies"
new_fixture
claude_commit "sed -i 's/line2/line2 GIT-A/' note.md"
sed -i 's/line2/line2 OBS-A/' "${VAULT}/note.md"
cycle
claude_commit "sed -i 's/line2.*/line2 GIT-B/' note.md"
sed -i 's/line2.*/line2 OBS-B/' "${VAULT}/note.md"
cycle
check "first copy kept" 'cat "${VAULT}"/note\ \(git\ conflict*.md | grep -q GIT-A'
check "second copy kept" 'cat "${VAULT}"/note\ \(git\ conflict*.md | grep -q GIT-B'
check "copy name says UTC" 'ls "${VAULT}" | grep -q "^note (git conflict [0-9-]* [0-9]* UTC).md$"'
check "in sync" in_sync

echo "settings under .obsidian get no conflict copy"
new_fixture
claude_commit "mkdir -p .obsidian && echo '{\"a\":1}' > .obsidian/app.json"
do_pull >> "${LOG}" 2>&1
claude_commit "echo '{\"a\":2}' > .obsidian/app.json"
echo '{"a":3}' > "${VAULT}/.obsidian/app.json"
cycle
check "vault settings kept" 'grep -q 3 "${VAULT}/.obsidian/app.json"'
check "no copy in .obsidian" '! ls "${VAULT}/.obsidian" | grep -q conflict'
check "logged" 'grep -q "ERROR: CONFLICT: .obsidian/app.json" "${LOG}"'
check "in sync" in_sync

echo ".base files and upper-case .MD are merged line by line"
new_fixture
claude_commit "printf 'a\nb\nc\n' > view.base; printf 'a\nb\nc\n' > UP.MD"
do_pull >> "${LOG}" 2>&1
claude_commit "sed -i 's/^a$/a GIT/' view.base UP.MD"
sed -i 's/^c$/c OBS/' "${VAULT}/view.base" "${VAULT}/UP.MD"
cycle
check ".base merged" 'grep -q "a GIT" "${VAULT}/view.base" && grep -q "c OBS" "${VAULT}/view.base"'
check ".MD merged" 'grep -q "a GIT" "${VAULT}/UP.MD" && grep -q "c OBS" "${VAULT}/UP.MD"'
check "in sync" in_sync

finish
