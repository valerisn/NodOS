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
- [ ] Read timeouts and slowloris protection
- [ ] Graceful shutdown on SIGINT and SIGTERM
- [ ] TLS decision (built-in or documented reverse proxy)
- [ ] Trusted proxy setting for client addresses
- [ ] Fuzz the request path

## Phase 3: Monitoring

- [ ] Parsers for `/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `/proc/uptime`
- [ ] Disks, mounts, filesystem usage, temperature sensors
- [ ] Sampler with in-memory history
- [ ] SSE live stream

## Phase 4: Dashboard

- [ ] Layout, navigation, login
- [ ] Overview page with resource graphs
- [ ] Storage and network pages
- [ ] Settings

## Phase 5: Management

- [ ] Docker: list, start, stop, restart, logs, stats
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
