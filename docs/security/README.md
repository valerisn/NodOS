# Security model and review

This is the working security document: what NodOS defends, how, and what it
does not. It is written for people deciding whether to run it and people
reviewing it. Reporting instructions are in [SECURITY.md](../../SECURITY.md).

The review below is a self-review by the author. It is not an independent
audit. Treat NodOS as pre-1.0 software that holds sensitive access.

## What is at stake

NodOS reads host details and can, for admins, start and stop Docker containers
and systemd services. Whoever controls an admin session controls those. Docker
socket access is root-equivalent, so for a host that has it enabled, an admin
session is effectively root. The design goal is to make that hard to reach, hard
to widen, and visible afterwards.

## Trust boundary and assumptions

- The HTTP interface is the boundary. Everything except `GET /`, static assets,
  `GET /api/v1/health` and `POST /api/v1/login` needs a session.
- NodOS runs as an unprivileged `nodos` user under a hardened systemd unit.
- It is reached over a network you trust, through a TLS reverse proxy. NodOS
  itself does not terminate TLS.
- The host is not already compromised, and `/var/lib/nodos` is only readable by
  `nodos` and root.

## Controls

| Area | What is done |
| --- | --- |
| Passwords | argon2id (19 MiB, t=2, p=1, OWASP minimum), PHC strings with per-user salt, 10 to 256 bytes |
| Login | Per-address throttle: 5 failures in 15 minutes locks that address out, even for the right password. Unknown user and wrong password are indistinguishable in response and in time (a dummy hash is verified) |
| Sessions | 256-bit random token from the OS CSPRNG, only its SHA-256 is stored, memory only, 30 minute idle and 12 hour absolute limits, 1024 session cap |
| Cookies | `HttpOnly`, `SameSite=Strict`, `Secure` by default |
| CSRF | Every state-changing request needs an `x-csrf-token` header matching the session, compared in constant time. `SameSite=Strict` is a second layer |
| Authorization | Two roles. Viewers see status. Admins read logs, the audit log, and control Docker and services |
| Input | Bodies capped at 1 KiB, URLs at 128 bytes, headers at 8 KiB. Container ids and unit names validated against strict character sets. Requests with a body but no framing get 411 (this avoids a crash in the Zig standard library) |
| Commands | No endpoint runs a command or takes one. Docker has three verbs. systemd has three verbs on an allowlist of units from the config. `systemctl` and `journalctl` run with fixed argument vectors, no shell |
| Browser | CSP `default-src 'self'; frame-ancestors 'none'`, no inline script or style, `nosniff`, `X-Frame-Options: DENY`, `no-referrer`, `no-store`. The frontend builds DOM with text nodes, never `innerHTML` |
| Availability | 256 connection cap, 15 second idle and stall cutoff, 16 stream cap, 10 second timeout on external commands |
| Audit | Append-only JSON lines for logins (success, failure, throttled), logouts, every Docker and service action, and alerts. Never records passwords or tokens. Untrusted strings are JSON-escaped, so a hostile username cannot forge a line |
| Updates | The server only reports that a release exists; installing is a root command run by a person. Releases need a valid Ed25519 signature (public key compiled in) and a matching checksum, the new binary must report the signed version, and a failed health check rolls back. Automatic updates are opt-in and limited to aged patch releases |
| Host | Unprivileged user, `NoNewPrivileges`, `ProtectSystem=strict`, empty capability set, restricted address families, no writable paths except the data directory |

## Known limitations

These are real. None is hidden elsewhere.

1. **No TLS in the binary.** Use a reverse proxy. Without one, passwords and
   cookies cross the network in clear text.
2. **Sessions are in memory.** Restarting signs everyone out. There is no
   "sign out everywhere" and no way to list sessions.
3. **The audit log is not tamper-evident.** It is a plain append-only file. An
   attacker with write access to `/var/lib/nodos` can edit it. Ship it
   elsewhere if you need integrity.
4. **No second factor.** Passwords only.
5. **Throttling is per address and per account.** An address (an IPv6 /64) gets
   5 attempts per 15 minutes and an account gets 20, so many addresses can guess
   slowly at best. The cost is that anyone can lock a known account for 15
   minutes; `nodos user passwd` on the host still works. Behind a proxy it only
   works if `trusted_proxy` is configured correctly; if it is wrong, every user
   may share one bucket.
6. **Roles are coarse.** Two roles, set at creation. No per-container or
   per-unit permissions beyond the config allowlist.
7. **Docker access is root-equivalent** by nature of the socket, whatever NodOS
   restricts itself to.
8. **User changes need a restart**, and the user file is only readable by
   `nodos`; there is no live user management through the web interface.
9. **Thresholds for alerts are fixed**, and alerts are in-app only. There is no
   outbound email or webhook, so an alert nobody is looking at is silent.
10. **The update system is a trust decision.** Anyone who can sign a release
    can run code as root on every machine that installs it, so the signing key
    is the most valuable secret in the project. It lives in a GitHub Actions
    secret and one offline backup. If it leaks, rotate it with
    `scripts/release-keygen.sh --rotate`; machines on the old key then have to
    be reinstalled by hand. The metadata that names the latest release is not
    signed, so a network attacker can hide an update or point at an older signed
    release; the updater refuses to go backwards, but it cannot make you update.
    The update check contacts GitHub (see the README for what is sent).
11. **An idle-connection flood denies service while it lasts.** The server
    holds 256 connections; an attacker who keeps opening idle ones keeps them
    all busy, and each is only cut after 15 seconds. It recovers by itself as
    soon as the attacker stops (verified in CI), but while it continues, real
    users are locked out. Put rate limiting in the reverse proxy. On Windows
    (development only) the cutoff does not free slots until the client lets go.
12. **The standard library is young.** `std.http.Server` crashed on one class of
    input (fixed with a guard). More such edges are likely. Parsers and the
    login path get mutation tests on every build, but there has been no long
    fuzzing campaign.
13. **No independent review or penetration test has been done.**

## Self-review checklist (2026-11-09)

- [x] No hardcoded credentials or secrets in the repository or binary
- [x] All non-public endpoints require a session (covered by tests per route)
- [x] Privileged routes check role, then CSRF, then validate input, then act
  (covered by tests including hostile names and unknown verbs)
- [x] No shell invocation; external commands use fixed argv with timeouts
- [x] Secrets absent from logs and the audit log (checked in the smoke test)
- [x] Cookies and security headers set on every response
- [x] Resource caps on connections, bodies, streams, sessions, alerts, output
- [x] Hostile-input tests on every parser and the login path (about 30,000 mutated inputs per run)
- [ ] Long fuzzing campaign (`zig build test --fuzz`) of the HTTP request path
- [ ] Independent review
- [ ] Load and soak testing on a Linux host (see
  [performance](../development/performance.md))

## Hardening checklist for operators

- Run behind TLS. Keep `secure_cookies = true`.
- Don't expose NodOS to the internet. Use a VPN or SSH tunnel.
- Leave Docker off (`docker_socket = off`) unless you want it.
- Keep the `services` allowlist and the polkit rule to the units you need.
- Use viewer accounts for anyone who only needs to look.
- Forward `audit.log` somewhere you trust.
- Use long unique passwords. Remove accounts you no longer need.
