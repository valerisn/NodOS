# Roadmap

Legend: done, in progress, planned. Nothing is marked done until it is
implemented and tested.

## Phase 1: Foundation (done)

- [x] Repository, license, editor and git settings
- [x] Zig 0.17 build system, `nodos version` and `nodos help`
- [x] Architecture and decision records
- [x] CI: format, build, test, cross-compile (first run green)
- [x] Release workflow: dry run verified in CI (artifacts, checksums, installer included); the publish step runs for the first time on the first tag
- [x] Issue and pull request templates
- [x] Contribution, conduct and security policies

## Phase 2: Core (done)

- [x] Config file loading and validation
- [x] Logging (stderr, runtime level)
- [x] HTTP server (std.http.Server on std.Io)
- [x] Authentication: argon2id passwords, server-side sessions, CSRF, login rate limiting
- [x] Audit log for logins and logouts
- [x] Idle connection reaper (slowloris), verified with stalled sockets
- [x] Graceful shutdown on SIGINT and SIGTERM (Linux), checked by the CI smoke test
- [x] TLS decision: reverse proxy, documented with Caddy and nginx examples (D9)
- [x] Trusted proxy setting for client addresses (rightmost X-Forwarded-For from a named proxy; tested live)
- [x] Hostile-input tests for every parser and the login path run on every build (src/robustness.zig); a long `--fuzz` campaign is still open

## Phase 3: Monitoring (done)

- [x] Parsers for `/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `/proc/uptime`, mounts (unit tested on fixtures)
- [x] Mounts, filesystem usage (statfs), thermal zones, verified against a real Linux host in CI
- [x] Sampler with in-memory history
- [x] SSE live stream, verified end to end on Linux in CI

## Phase 4: Dashboard (in progress)

- [x] Layout, navigation, login (embedded in the binary, no build step)
- [x] Overview page with live strip charts
- [x] Storage and network pages
- [x] Settings page: read-only view of the running configuration for admins. Editing stays in the config file and the `nodos user` commands on purpose, so the web interface has no write path to the host

## Phase 5: Management (in progress)

- [x] Docker: list, start, stop, restart, logs, with a request timeout. Verified against fake daemons on real sockets, including one that never answers
- [x] Docker: per-container stats (CPU, memory, processes, network) and an image list
- [x] systemd services: status, start, stop, logs, allowlisted per unit (parsers tested; real-systemd status check in CI smoke test)
- [x] Alerts: threshold rules with hysteresis, audit-logged, live in the dashboard (in-app only; outbound webhooks and email are not built)
- [x] Audit log viewer (admin)
- [x] Outbound notifications: webhook (`webhook_url`, works with ntfy, Gotify, Slack, Discord). Email is not built

## Phase 6: Release (in progress)

- [x] Security self-review written (docs/security); independent review and fuzzing still open
- [x] Performance measured on Linux against the budget (CI step, numbers in docs/development/performance.md); long soak still to do
- [x] Install docs, hardened systemd unit and installer; CI installs and starts the service on Ubuntu (not yet tried on a real home server)
- [x] Update notice, `nodos update` with signature verification, atomic swap, health check and automatic rollback, opt-in auto-update (tested end to end on Linux under systemd)
- [x] Release signing key generated and the public half committed (`src/update/signing.pub`); the first signed release is waiting for the maintainer to tag it
- [x] Storage health: mdadm RAID, ZFS pools and SMART (opt-in) with alerts

- [x] Apps: catalog of 22 apps installed through Docker
- [x] Multiple servers: hub with API tokens and a role-aware proxy

## Later

Proxmox and VM management, backups of more than NodOS itself, updating installed apps, users and roles, custom
widgets, plugins.

## Known technical risks

1. **Zig churn.** The standard library changes between releases and 0.17 is
   recent. Mitigation: pin the version, keep OS-facing code in small modules.
2. **HTTP in std.** `std.http.Server` crashed on one class of input and was
   guarded; more edges are likely. Mitigation: hostile-input tests on every
   build, a CI flood test, and a documented reverse proxy in front. TLS is the
   proxy's job.
3. **Privileged operations.** Docker is root-equivalent. Mitigation: opt-in,
   admin-only, three verbs, audited, can be switched off; systemd control is
   limited by both a config allowlist and a polkit rule (see the architecture
   overview). Residual risk is documented, not removed.
4. **Scope.** The feature list is large. Mitigation: monitoring and Docker must
   be excellent before anything on the "Later" list starts.
5. **Linux-only collectors.** Other platforms get a compiling binary and no
   data. Documented, not hidden.
