# ADR-0024: Docker-Based Test Suite

## Status

Accepted

## Context

The project had no automated tests. The data-loss bugs fixed alongside this
ADR (ADR-0021 to 0023) were found with throwaway experiment scripts, and
the fixes need regression tests. The scripts run under BusyBox ash with
Alpine's git, which behave differently from a developer's macOS or
glibc-based shell (for example `sed -i`, `grep --exclude-dir`, `touch -d`).

## Decision

- Move the watcher's git functions into
  `rootfs/usr/local/lib/git-sync-functions.sh` so tests can source them
  without inotify or s6.
- `tests/run.sh` builds the image and runs:
  - `tests/unit/*.sh` inside the image, sourcing the checkout's scripts
    (mounted read-only at `/src`), against local bare repositories;
  - `tests/container/*.sh` on the host, starting the whole image with a
    stub `ob` (`tests/container/stub/`) and named volumes. Bind mounts are
    avoided because Docker Desktop shows them as root-owned, which trips
    git's ownership check.
- Plain POSIX sh with a tiny `check`/`finish` helper, no test framework.

## Consequences

- Tests exercise the exact BusyBox and git versions that ship.
- No Obsidian account or network is needed. The flip side: obsidian-headless
  itself is not exercised. Its behaviour (initial sync, conflict strategy,
  config handling) still has to be checked against the real service by
  hand.
- A full run takes a few minutes because container tests start real
  containers. `SKIP_BUILD=1` and per-file runs keep iteration fast.
- Not wired into CI yet.
