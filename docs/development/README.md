# Development

## Toolchain

Zig 0.17.0 exactly. Nothing else is required: the dashboard is plain files
embedded at compile time, so there is no node toolchain and no bundler.

```sh
zig build                    # compile to zig-out/bin/nodos
zig build test               # unit tests
zig build fmt                # formatting check, fix with: zig fmt .
zig build run -- serve --config nodos.conf
bash scripts/smoke.sh        # end-to-end test of the built binary (Linux)
```

## Working without a Linux box

Host monitoring reads `/proc`, so on Windows or macOS the dashboard has no
data. Build with synthetic data instead:

```sh
zig build -Dfake-host=true
```

The server logs a warning at startup and serves invented but plausible numbers
(moving CPU load, growing network counters, three mounts). This exists for UI
work and for exercising the live stream. It is off by default and must never be
used for a release.

To run the HTTP half of the smoke test on Windows under Git Bash:

```sh
SMOKE_SKIP_POSIX=1 bash scripts/smoke.sh zig-out/bin/nodos.exe
```

## Layout

```
src/main.zig        CLI entry point and process wiring
src/cli.zig         argument parsing
src/config.zig      config file parser
src/server.zig      HTTP, routing, auth flow, live stream
src/auth.zig        argon2id hashing, sessions, CSRF
src/users.zig       user file
src/ratelimit.zig   failed-login throttle
src/audit.zig       append-only audit log
src/signals.zig     graceful shutdown (Linux)
src/assets.zig      embeds src/web/*
src/agent/          host data: proc.zig parsers, collect.zig, sampler.zig, encode.zig
src/web/            the dashboard: HTML, CSS, JavaScript modules
```

## Conventions

- Parsers take text and return structs; file reading is separate. That is what
  makes the Linux collectors testable on any machine.
- New JavaScript files must be added to `src/assets.zig`. A test fails if one
  is imported but not registered.
- The CSP forbids inline scripts and styles. Set dynamic styles through the DOM
  (`el.style.width = ...`), never through `setAttribute("style", ...)`.
- Build DOM with `h()` in `views.js`. Never assign server data to `innerHTML`.
- Linux-only code needs a real-host test guarded by `builtin.os.tag`, which CI
  runs on Ubuntu.
