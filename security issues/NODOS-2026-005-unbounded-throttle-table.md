# NODOS-2026-005: Unbounded growth of the throttle table

**Severity:** Medium
**Status:** Fixed before any release
**Affected versions:** none published

## Problem

The throttle kept one entry per source address and only removed an entry when that address came back. Entries for addresses that never returned stayed forever.

## Impact

Combined with IPv6 rotation (004), an attacker can create entries without limit and grow the process memory until it is killed.

## Where

`src/ratelimit.zig`.

## Fix

The table is capped at 4096 entries. When full, an expired entry is removed, or the oldest one if none has expired. Fixed in commit 66dba81.

## Regression tests

`ratelimit.zig`: "memory is bounded however many sources show up" (12288 sources, table stays at or under 4096).

## Residual risk

With thousands of live sources an attacker can push their own history out early. With /64 bucketing that takes thousands of separate networks, which is not a home server threat.
