# NODOS-2026-003: Failed-login count reset by a successful login, and no per-account limit

**Severity:** Medium
**Status:** Fixed before any release
**Affected versions:** none published

## Problem

A successful login cleared the failure count for the source address. There was also no limit per account, only per address.

## Impact

An attacker with any valid account logs in successfully between guesses and gets a fresh budget every time, so guessing against another account is effectively unlimited. Separately, an attacker with many addresses gets 5 guesses per address against the same account.

## Where

`src/server.zig` `login()`, `src/ratelimit.zig`.

## Fix

A success now only refunds its own attempt and never erases earlier failures. A second limiter keyed on a hash of the username allows 20 attempts per account per 15 minutes regardless of source address. Fixed in commit 66dba81.

## Regression tests

`ratelimit.zig`: "a good login gives its attempt back but does not erase earlier failures", "interleaving good logins cannot buy unlimited guesses". `server.zig`: "a success from the same address does not reset the failure count", "an account is limited across addresses, so spreading out does not help".

## Residual risk

Trade-off: anyone can lock a known account for 15 minutes by failing 20 times. For a home server that is the better side of the trade. `nodos user passwd` on the host still works while an account is locked.
