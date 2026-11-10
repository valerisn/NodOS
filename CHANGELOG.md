# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

First public release is not cut yet; everything here is on `main`.

### Security

Found in the pre-release review, all fixed before any release. Details in
[security issues](security%20issues/README.md).
- Login throttle counts attempts before checking the password, so parallel
  bursts no longer bypass it; successes no longer reset failures.
- Per-account limit, IPv6 /64 bucketing, bounded throttle table, at most four
  password hashes at once.
- Login requires `Content-Type: application/json`.
- The root updater keeps its state in `/var/lib/nodos-update` instead of the
  service's data directory, closing a symlink privilege escalation.

### Added

- Docker page: image list and on-demand container stats (CPU, memory, processes, network).

- Alert webhook (`webhook_url`): JSON POST on raised, escalated and cleared alerts.

**Server and security**
- HTTP server on `std.http.Server`: login, logout, session info, health, with
  security headers and a strict CSP on every response.
- argon2id passwords, server-side sessions with idle and absolute expiry, CSRF
  tokens, per-address login throttling, admin and viewer roles.
- Append-only JSON audit log for logins, logouts, Docker and service actions
  and alerts, with an admin-only viewer.
- Trusted-proxy support for `X-Forwarded-For` (`trusted_proxy`), so throttling
  and the audit log see real client addresses behind a reverse proxy.
- Idle and stalled connections are cut after 15 seconds; 256 connection cap.
- `nodos user add`, `passwd`, `remove` and `list`. The last admin cannot be removed.
- Graceful shutdown on SIGINT and SIGTERM (Linux).

**Monitoring**
- Linux host monitoring: CPU and per-core load, memory and swap, load average,
  uptime, disk usage per mount, network rates per interface, temperatures.
- Ten minutes of in-memory history and a Server-Sent Events live stream.
- Threshold alerts (CPU, memory, swap, disk, temperature) with hysteresis,
  written to the audit log and shown in the dashboard.

**Management**
- Docker: list containers, read logs, start, stop and restart. Admin only for
  logs and actions, with request timeout.
- systemd: status, logs, start, stop and restart for an allowlist of units
  named in the config.

**Dashboard**
- Embedded in the binary, no build step: sign in, overview with live strip
  charts, storage, network, Docker, services and audit log. Dark and light.

**Updates**
- A dashboard notice when a newer release exists (checked about every 12 hours,
  can be turned off with `update_check = false`), and `GET /api/v1/update`.
- `nodos update [--check | --rollback | --auto on|off|status]`: Ed25519
  signature and checksum verification, a sanity run of the new binary, an
  atomic swap that keeps the old binary, a health check after the restart and
  automatic rollback with the failed version remembered.
- Opt-in automatic updates through a systemd timer, limited to patch releases
  at least three days old, with a prominent warning.
- `release-sign` tool and `scripts/release-keygen.sh` for the maintainer; the
  release workflow signs `SHA256SUMS` and refuses to publish unsigned.

**Packaging and operations**
- Hardened systemd unit, installer script, example config and polkit rule.
- Installation, configuration, API, security, troubleshooting and development docs.
- Release workflow producing x86_64 and aarch64 Linux tarballs with checksums,
  with a manual dry-run mode.

**Build and CI**
- `-Dstrip` (a stripped Linux binary is under 0.8 MB) and `-Dfake-host`
  (synthetic data for developing the UI off Linux).
- CI on Linux, macOS and Windows, cross-compilation for five targets, a Linux
  end to end smoke test, a real service install under systemd, shellcheck, and
  a connection flood test. Workflow actions are pinned to commit SHAs.
- Hostile-input tests for every parser and the login path.

### Fixed
- The server no longer crashes on a body-bearing request without framing
  headers (a standard library assertion); it answers 411.
- The live stream flushes the body writer before the connection, so events
  actually leave the process (found by the Linux smoke test).
