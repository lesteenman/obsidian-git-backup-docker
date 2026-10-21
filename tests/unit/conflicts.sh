#!/bin/sh
# Changes to the same file on GitHub and in Obsidian. Neither side may be
# lost, the vault must never contain conflict markers (ob sync would upload
# them), and the repository must never be left mid-rebase or mid-merge.
set -u
. /src/tests/lib/assert.sh
. /src/tests/lib/git-fixture.sh
. /src/rootfs/usr/local/lib/git-sync-functions.sh

no_markers() {
  [ -z "$(find "${VAULT}" -path "${VAULT}/.git" -prune -o -type f -exec grep -l '^<<<<<<<' {} +)" ]
}

echo "same line edited on both sides"
new_fixture
claude_commit "sed -i 's/line2/line2 CLAUDE/' note.md"
sed -i 's/line2/line2 OBSIDIAN/' "${VAULT}/note.md"
cycle
check "Obsidian version kept in note.md" 'grep -q OBSIDIAN "${VAULT}/note.md"'
check "GitHub version kept as conflict copy" 'cat "${VAULT}"/note\ \(git\ conflict\ *.md 2>/dev/null | grep -q CLAUDE'
check "no conflict markers" no_markers
check "in sync" in_sync
check "conflict logged as error" 'grep -q "ERROR: CONFLICT: note.md" "${LOG}"'

echo "different lines of the same note edited on both sides"
new_fixture
claude_commit "sed -i 's/line1/line1 CLAUDE/' note.md"
sed -i 's/line3/line3 OBSIDIAN/' "${VAULT}/note.md"
cycle
check "both edits merged" 'grep -q "line1 CLAUDE" "${VAULT}/note.md" && grep -q "line3 OBSIDIAN" "${VAULT}/note.md"'
check "no conflict copy" '! conflict_copy note'
check "in sync" in_sync

echo "deleted on GitHub, edited in Obsidian"
new_fixture
claude_commit "git rm -q note.md"
echo edit >> "${VAULT}/note.md"
cycle
check "Obsidian edit kept" 'grep -q edit "${VAULT}/note.md"'
check "in sync" in_sync

echo "edited on GitHub, deleted in Obsidian"
new_fixture
claude_commit "echo claude >> note.md"
rm "${VAULT}/note.md"
cycle
check "Obsidian deletion kept" '[ ! -f "${VAULT}/note.md" ]'
check "GitHub edit kept as conflict copy" 'conflict_copy note'
check "in sync" in_sync

echo "binary file changed on both sides"
new_fixture
claude_commit "printf BIN-BASE > img.png"
do_pull >> "${LOG}" 2>&1
claude_commit "printf BIN-CLAUDE > img.png"
printf BIN-OBSIDIAN > "${VAULT}/img.png"
cycle
check "Obsidian binary kept" 'grep -q OBSIDIAN "${VAULT}/img.png"'
check "GitHub binary kept as conflict copy" 'cat "${VAULT}"/img\ \(git\ conflict\ *.png 2>/dev/null | grep -q CLAUDE'
check "in sync" in_sync

echo "same change made on both sides"
new_fixture
claude_commit "echo same >> note.md"
echo same >> "${VAULT}/note.md"
cycle
check "no conflict copy" '! conflict_copy note'
check "in sync" in_sync

echo "ob sync writes another file between commit and pull"
new_fixture
claude_commit "echo new > claude.md"
echo A > "${VAULT}/a.md"
g -C "${VAULT}" add -A && g -C "${VAULT}" commit -qm local
echo "written mid-cycle" >> "${VAULT}/other.md"
do_pull >> "${LOG}" 2>&1
check "mid-cycle write kept" 'grep -q "written mid-cycle" "${VAULT}/other.md"'
check "remote file arrived" '[ -f "${VAULT}/claude.md" ]'
check "no rebase or merge left in progress" '[ ! -e "${VAULT}/.git/MERGE_HEAD" ] && [ ! -d "${VAULT}/.git/rebase-merge" ]'

echo "ob sync writes the file GitHub changed, between commit and pull"
new_fixture
claude_commit "echo claude >> other.md"
echo "ob write" >> "${VAULT}/other.md"
do_pull >> "${LOG}" 2>&1
check "ob write kept" 'grep -q "ob write" "${VAULT}/other.md"'
check "GitHub change kept as conflict copy" 'cat "${VAULT}"/other\ \(git\ conflict\ *.md 2>/dev/null | grep -q claude'
check "no conflict markers" no_markers

echo "interrupted integration (files written, no merge commit) converges"
new_fixture
claude_commit "echo claude > c1.md; echo claude > c2.md"
echo A > "${VAULT}/a.md"
g -C "${VAULT}" add -A && g -C "${VAULT}" commit -qm local
g -C "${VAULT}" fetch -q origin main
g -C "${VAULT}" cat-file blob FETCH_HEAD:c1.md > "${VAULT}/c1.md"
cycle
check "no spurious conflict copies" '! conflict_copy c1 && [ -f "${VAULT}/c2.md" ]'
check "in sync" in_sync

echo "conflicts in a subfolder and in names with spaces"
new_fixture
claude_commit "mkdir -p 'Daily notes' && printf 'a\n' > 'Daily notes/2026 10 21.md'"
do_pull >> "${LOG}" 2>&1
claude_commit "printf 'a CLAUDE\n' > 'Daily notes/2026 10 21.md'"
printf 'a OBSIDIAN\n' > "${VAULT}/Daily notes/2026 10 21.md"
cycle
check "Obsidian version kept" 'grep -q OBSIDIAN "${VAULT}/Daily notes/2026 10 21.md"'
check "GitHub version kept as conflict copy next to it" 'cat "${VAULT}/Daily notes"/2026\ 10\ 21\ \(git\ conflict\ *.md 2>/dev/null | grep -q CLAUDE'
check "in sync" in_sync

echo "unrelated histories (remote re-initialized separately)"
new_fixture
rm -rf "${W}/claude/.git"
g init -q "${W}/claude"
printf 'other start\n' > "${W}/claude/note.md"
echo fresh > "${W}/claude/fresh.md"
(cd "${W}/claude" && g add -A && g commit -qm reinit && g remote add origin "${W}/remote.git" && g push -qf origin main)
echo local >> "${VAULT}/note.md"
cycle
check "local note kept" 'grep -q local "${VAULT}/note.md"'
check "remote note kept as conflict copy" 'conflict_copy note'
check "remote-only file arrived" '[ -f "${VAULT}/fresh.md" ]'
check "in sync" in_sync

echo "Git LFS files are written with their content, not the pointer"
new_fixture
for r in vault claude; do
  g -C "${W}/${r}" lfs install --local >/dev/null
done
claude_commit "echo '*.png filter=lfs diff=lfs merge=lfs -text' > .gitattributes; printf PNG-BASE > img.png"
do_pull >> "${LOG}" 2>&1
check "LFS file pulled with content" 'grep -q PNG-BASE "${VAULT}/img.png"'
claude_commit "printf PNG-CLAUDE > img.png"
echo local >> "${VAULT}/note.md"
cycle
check "unchanged LFS file updated with content" 'grep -q PNG-CLAUDE "${VAULT}/img.png"'
claude_commit "printf PNG-CLAUDE2 > img.png"
printf PNG-OBSIDIAN > "${VAULT}/img.png"
cycle
check "local LFS file kept" 'grep -q PNG-OBSIDIAN "${VAULT}/img.png"'
check "LFS conflict copy has content" 'cat "${VAULT}"/img\ \(git\ conflict\ *.png 2>/dev/null | grep -q PNG-CLAUDE2'
check "in sync" in_sync

finish
