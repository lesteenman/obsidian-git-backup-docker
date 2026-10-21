# ADR-0021: Pull Strategy — File-by-File Integration with Conflict Copies

## Status

Accepted. Supersedes the conflict-resolution part of
[ADR-0016](0016-pull-rebase-merge-fallback.md); its periodic pull still
applies.

## Context

ADR-0016 pulled with `git pull --rebase`, and on failure ran
`git rebase --abort` and `git pull --no-rebase -X ours`. It assumed the
git remote is only a backup that someone occasionally edits by hand.

The working tree is also the folder obsidian-headless (`ob sync
--continuous`) watches and uploads to every device. Used as a two-way
bridge (notes edited on GitHub, for example by an AI assistant, flow back
into Obsidian), the strategy loses data. Each case below was reproduced
with the old `do_pull`:

1. **Silent loss of GitHub edits.** `-X ours` resolves overlapping hunks
   by dropping the remote side. The only trace is a log warning that also
   appears without conflicts.
2. **Stuck merges.** Modify/delete conflicts are not resolved by `-X ours`.
   The pull leaves `MERGE_HEAD`, every later push is rejected, and a note
   deleted in Obsidian comes back on all devices.
3. **Reverted writes.** `git rebase --abort` resets the working tree. Files
   ob sync wrote while the rebase was running are reverted, and ob then
   uploads the old versions. A container killed mid-rebase has the same
   effect on the next start.
4. **Conflict markers in the vault.** While the rebase is stopped, the
   files contain `<<<<<<<` markers, which ob can upload.

Options considered:

- **Keep rebase/merge, but run them in a separate clone** and copy results
  into the vault (for example with rsync). It works, but needs a second
  working tree, and the copy step still has to decide what to do when
  both sides changed a file.
- **Keep the merge, but `-X theirs` or no strategy option.** This moves
  the loss to the other side, or leaves conflict markers in the vault.
- **Integrate file by file** in the live vault, never entering a git
  rebase or merge state (chosen).

## Decision

`do_pull` (in `rootfs/usr/local/lib/git-sync-functions.sh`) fetches
`origin/<branch>` and:

- returns if the remote is already contained in HEAD;
- commits anything ob sync wrote, then fast-forwards if there are no local
  commits (git refuses, changing nothing, if a concurrent write would be
  overwritten);
- otherwise, for each path the remote changed since the merge base,
  compares the file **on disk** (so a write ob makes during the pull counts
  as a local change) with the base and remote versions:
  - unchanged locally: take the remote version, or delete;
  - same content on both sides: nothing to do;
  - Markdown or `.base` changed on both sides: `git merge-file`; if the
    changes do not overlap, write the merged result;
  - anything else changed on both sides: keep the local file and write the
    remote version next to it as `<name> (git conflict <date> <time>
    UTC).<ext>` (with " 2", " 3"… if taken), logged as `ERROR: CONFLICT:`;
  - under `.obsidian/`: keep the local file and only log, because Obsidian
    and ob treat every file there as settings;
  - deleted remotely, changed locally: keep the local file;
  - a change that cannot be applied (for example a file where the vault
    has a folder with local files): logged as a conflict with the `git show`
    command to retrieve it;
- records a merge commit (parents HEAD and the remote) with
  `commit-tree`/`update-ref`, force-adding the files it wrote so paths the
  vault's `.gitignore` matches are not deleted on the remote.

Deletions are applied first, and folders they empty are removed, so a file
can replace a folder. Each file is checked again right before it is
overwritten or deleted; if ob changed it since, it is treated as changed on
both sides. The remaining window is the rename itself.

Files are produced in `.git/ogb-integrate/` and renamed into place, so ob
never reads a half-written file. Remote content goes through git's filters
(`cat-file --filters`), so Git LFS files get their content, not the pointer.
Unrelated histories use an empty base: every file present on both sides
with different content gets a conflict copy. Paths git prints quoted (tabs,
newlines, quotes) are refused with an error rather than misread.

The watcher and init-config refuse to start on a repository with an
interrupted rebase, merge, cherry-pick or revert (left by an older version),
and init-config stops the container before ob sync starts.

## Consequences

**Easier:**

- Neither side's edit is ever discarded: overlapping changes produce a
  visible conflict copy in Obsidian.
- The repository can no longer get stuck mid-merge; pushes keep working.
- A crash at any point leaves only ordinary files; the next cycle commits
  them and integrates again, idempotently (tested).
- The behaviour is covered by `tests/unit/conflicts.sh`.

**Harder:**

- More code than `git pull`: about 150 lines of shell that must be kept
  correct. The unit tests are the safety net.
- Conflict copies need manual cleanup. They are synced to all devices like
  any note.
- The vault-side version always stays in place on conflict. If the GitHub
  version was the one you wanted, you have to copy it over by hand.
- History is non-linear: every integration with local commits is a merge
  commit.
- Only Markdown and `.base` are merged line by line. Canvas and JSON files
  changed on both sides always produce a conflict copy, because a textual
  merge could produce invalid JSON.
- A change that cannot be applied is recorded as merged, so it only
  survives in git history and the log. Retrying instead would block every
  later pull and push.
- Conflict copies are indexed by Obsidian; plugins such as Dataview list
  their content twice until they are cleaned up.
