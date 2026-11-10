# NODOS-2026-007: Login accepted any content type, allowing cross-site login requests

**Severity:** Low
**Status:** Fixed before any release
**Affected versions:** none published

## Problem

The login endpoint parsed a JSON body without checking the request's content type.

## Impact

A web page on another origin can submit a form with `text/plain` encoding whose body parses as JSON. The victim's browser then signs in as an account the attacker chose (login CSRF), which can be used to trick the victim into acting inside the attacker's account. A cross-site request with a JSON content type needs a CORS preflight, which the server never approves.

## Where

`src/server.zig` `login()`.

## Fix

Login now requires `Content-Type: application/json` and answers 415 otherwise. The smoke test, update test and CI install job send the header. Fixed in commit 66dba81.

## Regression tests

`server.zig`: "login insists on application/json". `scripts/smoke.sh` asserts a login without the header gets 415.

## Residual risk

The session cookie is `SameSite=Strict` and every state-changing call needs the CSRF token, so the remaining exposure was limited to login itself.
