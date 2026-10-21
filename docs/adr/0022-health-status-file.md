# ADR-0022: Health Status File and Docker HEALTHCHECK

## Status

Accepted

## Context

Commit, pull and push failures were only written to the log. A container
whose backup had stopped reaching the remote (expired SSH key, stale
`index.lock`, rejected pushes) looked exactly like a working one in `docker
ps` and to monitoring tools.

Options considered:

1. **Healthcheck runs git itself** (for example `git fetch` and compare).
   Needs network and credentials in the check, duplicates the watcher's
   logic, and can collide with the watcher's git operations.
2. **Watcher writes a status file; the healthcheck reads it** (chosen).
   Cheap and lock-free, and reports exactly what the watcher experienced.

## Decision

The watcher writes `/config/health` after every pull and push: `ok <epoch>`
on success, `error <epoch> <reason>` on failure (written to a temp file and
renamed). It also does one pull/push at start, so the status exists early.

`rootfs/usr/local/bin/healthcheck.sh`, run by `HEALTHCHECK --interval=5m
--start-period=10m`, is unhealthy when the status is `error`, missing, or
older than three pull intervals. With `OBSIDIAN_GIT_PULL_INTERVAL=0` there
is no age limit, because the watcher may legitimately be idle until the
next change.

A failed `git add` (for example a stale `index.lock`) is now an error
instead of "No changes to commit". A stale lock found at start, when no
other git process can be running, is removed.

## Consequences

- `docker ps`, Compose and monitoring tools show a broken backup, with the
  reason in `docker inspect`.
- Conflict copies do not make the container unhealthy: they are expected
  and visible in Obsidian. They are logged as errors.
- A watcher that hangs inside a git command without returning is only
  detected by the age limit, after three pull intervals.
- The status lives on `/config`, so it survives restarts. The startup
  pull overwrites it within seconds.
