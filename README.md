<p align="center">
  <img src="assets/logo.svg" alt="NodOS" width="320">
</p>

<p align="center">
  A fast, minimal home server management platform written in Zig.
</p>

<p align="center">
  <a href="https://github.com/valerisn/NodOS/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/valerisn/NodOS/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
  <img alt="Zig 0.17.0" src="https://img.shields.io/badge/zig-0.17.0-f7a41d">
  <img alt="Status: pre-alpha" src="https://img.shields.io/badge/status-pre--alpha-orange">
</p>

> **Status: pre-alpha.** The foundation, HTTP server and authentication work.
> Monitoring and the dashboard are not built yet. See the
> [roadmap](ROADMAP.md) for what exists. Release and download badges will be
> added once the first release exists.

## What NodOS is

One small static binary that watches your home server and lets you manage it
from a browser: system resources, storage, network, Docker containers and
system services. Dark-first interface, no framework, no database server, no
runtime dependencies.

## Planned features

- CPU, memory, disk, network and temperature monitoring with live graphs
- Storage and filesystem overview
- Docker: containers, logs, stats, start, stop, restart
- systemd service status, control and logs
- Notifications for failures, high usage and low disk space
- Authentication, sessions and an audit log from the start

Later: Proxmox and VM management, backups, multiple servers, roles, plugins.

## Architecture

A single process with four modules: Core (HTTP, auth, config), Agent (host
data collection), Integrations (Docker and others) and Dashboard (static
frontend embedded in the binary). Live metrics use Server-Sent Events. Read the
[overview](docs/architecture/overview.md) and the
[decision records](docs/architecture/decisions.md).

## Requirements

- Linux for monitoring features (x86_64 or aarch64)
- Zig 0.17.0 to build from source
- The binary itself has no runtime dependencies

macOS and Windows builds compile and run the CLI, but collectors are not
implemented there.

## Build from source

```sh
git clone https://github.com/valerisn/NodOS.git
cd NodOS
zig build
./zig-out/bin/nodos version
```

Run the tests with `zig build test` and check formatting with `zig build fmt`.

## Run it

```sh
printf '%s\n' 'a long passphrase' | ./zig-out/bin/nodos user add alice --config nodos.conf
./zig-out/bin/nodos serve --config nodos.conf
```

Today the server exposes health and authentication only. See
[configuration](docs/configuration/README.md) and the [API](docs/api/README.md).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Please follow the
[code of conduct](CODE_OF_CONDUCT.md).

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
The same file documents the security model and deployment assumptions.

## License

[MIT](LICENSE)
