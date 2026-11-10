# NODOS-2026-006: Root updater followed symlinks in a directory the service user owns

**Severity:** High
**Status:** Fixed before any release
**Affected versions:** none published

## Problem

`nodos update` runs as root (from the optional auto-update timer, or by hand with sudo). It kept its skip list and history in the service data directory `/var/lib/nodos`, which belongs to the unprivileged `nodos` user, and it opened those files by following symlinks.

## Impact

An attacker who compromises the web service (running as `nodos`) replaces `update-state` or `audit.log` with a symlink to a root-owned file such as `/etc/sudoers`. The next update run, which writes the skip list after a rollback and appends an audit line, overwrites or corrupts the target as root. That is a local privilege escalation or host denial of service reachable from a compromised web process.

## Where

`src/update/updater.zig` `rememberBad`, `writeAudit`, and the state read in `cmdApply`.

## Fix

All updater state moved to `/var/lib/nodos-update`, created by `install.sh` as `root:root 0755`. The state file is written atomically (temporary file, then rename, which replaces a link instead of following it). The updater no longer touches the service's `audit.log`; it writes its own `update.log` in the state directory. `nodos-update.service` only allows writes to `/usr/local/bin` and the state directory. A `--state-dir` option exists for tests. Fixed in commit 64d380b.

## Regression tests

`scripts/update_service_e2e.sh` plants symlinks at `/var/lib/nodos/update-state` and `/var/lib/nodos/audit.log` as the `nodos` user, pointing at a root-owned canary file, then runs a failing update that rolls back. The canary must be unchanged. `scripts/update_e2e.sh` covers the new state path.

## Residual risk

The old skip list in `/var/lib/nodos/update-state` is ignored now, which at worst retries a version that was already rolled back once. No release shipped with the old behavior.
