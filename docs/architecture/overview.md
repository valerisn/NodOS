# Architecture overview

Status: design. Only the CLI skeleton exists today. Nothing below this line is
implemented unless the roadmap marks it done.

## Shape

NodOS ships as one static binary, `nodos`. The four components from the project
brief are Zig modules inside it, not separate processes.

```
                 browser
                    |  HTTPS: REST (commands) + SSE (live metrics)
                    v
+-------------------------------------------------------+
| nodos (single process)                                |
|                                                       |
|  Core         http server, auth, sessions, config,    |
|               audit log, routing, notifications       |
|    |                                                  |
|    +-- Agent         collectors: cpu, mem, disk, net, |
|    |                 temps, services (reads /proc,    |
|    |                 /sys, systemd)                   |
|    |                                                  |
|    +-- Integrations  docker (unix socket), later      |
|                      proxmox, vms                     |
|                                                       |
|  Dashboard    static HTML/CSS/JS embedded in binary   |
+-------------------------------------------------------+
        |                      |
   /proc /sys /run/systemd   /var/run/docker.sock
```

Core, Agent and Integrations talk through plain Zig function calls and a small
in-memory snapshot store. No IPC, no message bus.

## Why one process

A home server box does not need a distributed system. One process means one
thing to install, one thing to restart, and no internal network protocol to
secure. The cost is that privileged work and the network-facing HTTP server
share an address space. See "Privilege separation" below for how that gets
fixed before 1.0 without changing the module boundaries.

## Components

**Core** owns everything a user can reach over the network: HTTP routing,
authentication, sessions, CSRF, rate limiting, configuration, the audit log, and
notification rules. It never reads `/proc` directly. It asks the Agent.

**Agent** is a library of collectors. Each collector is a pure function from raw
OS data to a typed struct, with the parsing separated from the file reading so
parsers can be unit tested against fixture text. A sampler runs on a timer,
writes the latest snapshot, and keeps a short ring buffer of history for graphs.

**Integrations** wrap external APIs behind a narrow interface: list, inspect,
and a fixed set of actions. Docker comes first. Each integration declares its
actions up front, and Core authorizes against that list. There is no generic
"run this" path.

**Dashboard** is static files served from the binary via `@embedFile`. It talks
to Core over the public API only, so it has no special access.

## Platform support

Linux is the first-class target because that is where home servers live. The
Agent collectors read `/proc`, `/sys` and systemd. On other operating systems
the binary compiles and the CLI runs, but collectors return
`error.Unsupported`. macOS and FreeBSD collectors are welcome contributions,
not roadmap items. Windows is a development host only.

## Data and persistence

Flat files, no database. `users.db` is one line per user, rewritten atomically
(write to a temporary file, then rename) with mode 0600. `audit.log` is
append-only JSON lines. Sessions, metric history, rate-limit state and active
alerts live in memory and are intentionally lost on restart. The data is small
enough that a database would add a C dependency and a failure mode for no
benefit; revisit if user counts or audit volume ever make that false.

## Privilege separation

Running a web server as root is not acceptable, so it doesn't. What is built:

1. `nodos serve` runs as an unprivileged `nodos` user under a hardened systemd
   unit (no capabilities, `ProtectSystem=strict`, restricted address families,
   one writable directory). CI installs it that way and checks it still works.
2. systemd control goes through polkit, not a helper process. The admin lists
   units in the config (the allowlist NodOS enforces) and writes a polkit rule
   naming the same units (the permission the OS enforces). Two independent
   gates, each narrower than "all services".
3. Docker access is the `docker` group, opt-in through a drop-in, off with
   `docker_socket = off`. The docs say plainly that it is root-equivalent.

A helper process with a fixed enum of operations was the alternative; polkit
won because it adds no code that runs as root and the OS already audits it.

## Performance budget

These are targets to measure against, not claims. Measurements get recorded in
`docs/development/performance.md` once there is something to measure.

| Metric | Target |
| --- | --- |
| Idle RSS | under 20 MB |
| Idle CPU | under 1% on a 4 core box |
| Sample interval | 2 s default, configurable |
| API p99 latency (local) | under 10 ms |
| Binary size (ReleaseSafe) | under 5 MB including the dashboard |
