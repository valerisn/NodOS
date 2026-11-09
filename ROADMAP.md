# Roadmap

Legend: done, in progress, planned. Nothing is marked done until it is
implemented and tested.

## Phase 1: Foundation (done)

- [x] Repository, license, editor and git settings
- [x] Zig 0.17 build system, `nodos version` and `nodos help`
- [x] Architecture and decision records
- [x] CI: format, build, test, cross-compile (first run green)
- [ ] Release workflow (written, never run; first tag will be its test)
- [x] Issue and pull request templates
- [x] Contribution, conduct and security policies

## Phase 2: Core (in progress)

- [x] Config file loading and validation
- [x] Logging (stderr, runtime level)
- [x] HTTP server (std.http.Server on std.Io)
- [x] Authentication: argon2id passwords, server-side sessions, CSRF, login rate limiting
- [x] Audit log for logins and logouts
- [x] Idle connection reaper (slowloris), verified with stalled sockets
- [ ] Graceful shutdown on SIGINT and SIGTERM (written, compiles for Linux, awaiting first CI smoke run)
- [ ] TLS decision (built-in or documented reverse proxy)
- [ ] Trusted proxy setting for client addresses
- [ ] Fuzz the request path

## Phase 3: Monitoring (in progress)

- [x] Parsers for `/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `/proc/uptime`, mounts (unit tested on fixtures)
- [x] Mounts, filesystem usage (statfs), thermal zones (compiles for Linux; real-host test runs in CI)
- [x] Sampler with in-memory history
- [x] SSE live stream (verified end to end with the synthetic host; real-host run in CI)

## Phase 4: Dashboard (in progress)

- [x] Layout, navigation, login (embedded in the binary, no build step)
- [x] Overview page with live strip charts
- [x] Storage and network pages
- [ ] Settings

## Phase 5: Management (in progress)

- [x] Docker: list, start, stop, restart, logs (stats still to do). Verified against a fake daemon on a real socket; real-daemon run is the smoke test in CI
- [ ] systemd services: status, start, stop, logs
- [ ] Notifications and thresholds
- [ ] Audit log viewer

## Phase 6: Release

- [ ] Security review
- [ ] Performance measurements recorded against the budget
- [ ] Install docs tested on a clean machine
- [ ] Signed release builds, first public release

## Later

Proxmox and VM management, backups, multiple servers, users and roles, custom
widgets, plugins.

## Known technical risks

1. **Zig churn.** The standard library changes between releases and 0.17 is
   recent. Mitigation: pin the version, keep OS-facing code in small modules.
2. **HTTP and TLS in std.** Server-side maturity is unproven for this use.
   Mitigation: Phase 2 starts with a measured spike, and TLS can fall back to a
   reverse proxy.
3. **Privileged operations.** Service control and Docker are root-equivalent.
   Mitigation: privilege separation design is a release blocker (see overview).
4. **Scope.** The feature list is large. Mitigation: monitoring and Docker must
   be excellent before anything on the "Later" list starts.
5. **Linux-only collectors.** Other platforms get a compiling binary and no
   data. Documented, not hidden.
