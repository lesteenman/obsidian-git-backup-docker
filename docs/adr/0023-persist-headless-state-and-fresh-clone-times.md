# ADR-0023: Persist obsidian-headless State; Prepare Fresh Clones for Initial Sync

## Status

Accepted

## Context

obsidian-headless keeps per-vault sync state (`state.db`) and settings in
`$XDG_CONFIG_HOME/obsidian-headless`, which defaulted to
`/home/obsidian/.config`. That directory is not a volume, so every container
recreation lost the state. Without state, ob runs an "initial" sync (from
the headless 0.0.8 and 0.0.14 source; not yet verified against the real
service):

- server-side deletions are ignored, so notes deleted on another device
  while the container was being recreated come back;
- files that differ are resolved by modification time, newer wins, with no
  merge.

`git clone` stamps every file with the current time, so after a fresh clone
the git copy was "newer" than every edit already in Obsidian Sync and
overwrote it.

Persisting the state creates the opposite risk: if `/vault` is re-cloned
but `/config` is kept, the saved state describes files that are gone. ob
would take every difference for a local edit and every missing file (never
committed, or ignored by git) for a local deletion, and upload both.

## Decision

- `ENV XDG_CONFIG_HOME=/config/xdg`: ob's state lives on the `/config`
  volume. `docker-compose.yml` now marks `/vault` as required, so the two
  persist together.
- After a **fresh clone**, init-config:
  - sets each cloned file's modification time to the last first-parent
    commit that changed it, so edits made in Obsidian after that commit win
    the initial sync and git wins only where its change is newer (ties go
    to the local file);
  - removes any `state.db` left in `/config/xdg`, so ob starts with an
    initial sync, which never pushes deletions.
- init-config refuses to clone into a `/vault` that already contains files.
  A failed clone attempt was cleaned up by deleting everything in `/vault`.

## Consequences

- Recreating the container (image updates, Compose changes) resumes
  syncing instead of re-running an initial sync.
- On upgrade from an older image, the first start has no saved state yet
  and runs one initial sync, as every start did before.
- The modification time is the commit time, not the moment of the edit:
  a change still inside the debounce window when the commit was made can
  lose to the git copy by a few seconds.
- The initial sync still does not sync deletions: notes deleted on one side
  but present on the other come back. Removing stale state is the lesser
  evil, because stale state would push deletions instead.
- Bringing an existing vault folder into a new container is no longer
  possible by mounting it as `/vault`. Start empty and let git and Obsidian
  Sync fill it.
