# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Zig 0.17 project skeleton with `nodos version` and `nodos help`.
- Architecture overview, decision records, roadmap, security policy.
- Config file parser (`nodos serve --config`).
- HTTP server with `/api/v1/health`, `/login`, `/me`, `/logout`.
- argon2id password hashing, in-memory sessions, CSRF tokens, login throttling.
- `nodos user add` and an append-only JSON audit log.

- Host monitoring for Linux: CPU, memory, load, network rates, storage usage,
  temperatures. `/api/v1/system`, `/api/v1/history` and a Server-Sent Events
  stream at `/api/v1/stream`.
- Dashboard embedded in the binary: sign in, overview with live strip charts,
  storage and network pages. Light and dark themes.
- Alerts for CPU, memory, swap, disk and temperature with hysteresis, shown in the dashboard and written to the audit log.
- Audit log viewer for admins at `/api/v1/audit` and in the dashboard.
- systemd services: status, logs, start, stop, restart for an allowlist of units from the config.
- Docker: container list, logs, start, stop and restart, admin-gated, CSRF-protected and audited.
- Idle and stalled connections are closed after 15 seconds.
- Graceful shutdown on SIGINT and SIGTERM (Linux).
- `-Dstrip` and `-Dfake-host` build options. A stripped Linux release binary is
  under 0.7 MB.

### Fixed
- Server no longer crashes on a body-bearing request without framing headers
  (standard library assertion), it answers 411.
