# NODOS-2026-001: Login throttle bypass through parallel requests

**Severity:** High
**Status:** Fixed before any release
**Affected versions:** none published

## Problem

The login throttle checked the failure count first, verified the password, and only then recorded a failure. Requests that arrived together all passed the check before any of them recorded anything.

## Impact

An attacker sends a burst of parallel login requests. Every request in the burst passes the lockout check, so the limit of 5 failures per address does not hold. Online password guessing goes from 5 tries per 15 minutes to as many as the attacker can send at once.

## Where

`src/server.zig` `login()` and `src/ratelimit.zig` (old check-then-record design).

## Fix

The limiter now admits and counts an attempt before the password is verified (`Limiter.admit`). The count is handed back (`Limiter.refund`) only when the login succeeds, so the stored number is failures plus attempts still in flight. A burst can no longer pass a check made before the others finished. Fixed in commit 66dba81.

## Regression tests

`ratelimit.zig`: "a burst of parallel attempts is cut off at the limit" (100 attempts, exactly 5 admitted). `server.zig`: "lockout after repeated failures". A parallel curl burst against the old and new binaries was used to confirm the before and after behavior.

## Residual risk

Per address only. See 003 for the per-account limit.
