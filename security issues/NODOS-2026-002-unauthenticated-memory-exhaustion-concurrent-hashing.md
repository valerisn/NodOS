# NODOS-2026-002: Unauthenticated memory exhaustion through concurrent password hashing

**Severity:** High
**Status:** Fixed before any release
**Affected versions:** none published

## Problem

Every login attempt runs argon2id with 19 MiB of memory. Nothing limited how many ran at once, and the throttle did not apply until after hashing, so unauthenticated requests could start any number of hashes at the same time.

## Impact

N parallel login requests allocate roughly N times 19 MiB. On a small home server this can get the process killed by the kernel OOM killer. No credentials are needed.

## Where

`src/server.zig` `login()`.

## Fix

A global gate (`max_concurrent_hashes = 4`) turns further attempts away with 503 before any memory is allocated, and hands their throttle attempts back so being turned away costs nobody their budget. The throttle now runs before hashing, so a locked-out source never reaches argon2. Fixed in commit 66dba81.

## Regression tests

`server.zig`: "too many hashes at once are turned away and their attempts handed back". Server working set under a parallel burst was measured before and after the change.

## Residual risk

An attacker can keep the four hash slots busy and make real logins return 503 while the flood lasts. That only affects sign-in; the rest of the server keeps running. A reverse proxy rate limit in front removes even that.
