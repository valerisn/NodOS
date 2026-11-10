# NODOS-2026-004: IPv6 clients could dodge the throttle by rotating addresses

**Severity:** Medium
**Status:** Fixed before any release
**Affected versions:** none published

## Problem

The throttle keyed on the full 128-bit client address. An IPv6 customer normally controls a whole /64.

## Impact

One attacker has 2^64 distinct source addresses and a fresh bucket for each, so the per-address limit never triggers.

## Where

`src/server.zig` `clientKey`.

## Fix

IPv6 addresses are collapsed to their /64 before use as a key (`ratelimit.bucketIp6`). IPv4-mapped IPv6 addresses keep all their bytes, since they are really IPv4. Fixed in commit 66dba81.

## Regression tests

`ratelimit.zig`: "ipv6 clients share one bucket per /64, ipv4 and mapped addresses stay exact". `server.zig`: "ipv6 attackers share a throttle bucket per /64".

## Residual risk

Behind a trusted proxy the forwarded address is used and the same bucketing applies.
