# Decisions

Each entry: the decision, the alternatives, and the trade-off. Add an entry
before adding a dependency or a language.

## D1. Zig 0.17, single static binary

Zig matches the brief: explicit memory, small output, trivial cross-compilation.
The cost is that the language and standard library still move between releases
(0.17 already differs from 0.15 in `main` and I/O). We pin `minimum_zig_version`
and bump it deliberately. Contributors need the exact toolchain version.

## D2. One process, modules not services

Alternatives: separate `nodos-core` and `nodos-agent` binaries from day one.
Rejected for now because there is no second host to run an agent on. The module
boundary is kept clean so `nodos agent` can become a remote reporter in the
multi-server phase without a rewrite.

## D3. Source layout under `src/`, not `cmd/` + `core/`

The brief's example tree is Go-flavored. Zig convention is `src/` with a
`root.zig` library and a thin `main.zig`. Top-level `core/`, `agent/` and
`integrations/` become `src/core/`, `src/agent/`, `src/integrations/`, created
when they contain code. No empty directories.

## D4. Frontend: plain HTML, CSS and JavaScript, no framework, no bundler

Alternatives: React, Svelte, Preact, TypeScript with a build step.

The dashboard is a handful of tables, a few graphs, and some buttons. A
framework adds a second language ecosystem, a node toolchain in CI, and a
dependency tree to audit, all on a security-sensitive admin tool. Plain ES
modules and a small hand-rolled canvas or SVG graph keep the whole thing
embeddable and reviewable. The trade-off is more manual DOM code and no type
checking. JSDoc plus `tsc --checkJs` can be added later without a build step if
the code grows. Revisit if a page needs heavy client state.

## D5. Live updates: Server-Sent Events, not WebSocket

The brief mentions WebSocket efficiency. The live data flow is one-directional
(server pushes metrics), and commands are ordinary POST requests. SSE does that
over plain HTTP with built-in reconnect, needs no framing or masking code, and
passes through proxies more reliably. WebSocket is only worth its complexity if
we need browser-to-server streaming, which a future web terminal would. We do
not plan a web terminal (see Security). Decision stands unless that changes.

## D6. License: NodOS Free Use License 1.1 (changed from MIT after v0.1.0)

The maintainer wants NodOS free for everyone to use, read, modify and share, and
never sold or monetized. No standard open source license does that: the Open
Source Definition forbids restricting commercial use. So NodOS now uses its own
license, which is source-available rather than open source. Version 1.1 is
strict on purpose: free for personal and non-profit use only, business use needs
written permission, rights end the instant a term is broken, and profits made in
breach are forfeit. Consequences:
distros and some package indexes only carry OSI-approved licenses, some
companies will not touch non-commercial code, and the text has had no lawyer's
review. The v0.1.0 release stays under MIT for the people who received it. A
well-tested alternative with the same intent is PolyForm Noncommercial 1.0.0.

## D7. No arbitrary command execution, ever

There is no endpoint, setting or plugin hook that runs a user-supplied string
through a shell. Actions are an enumerated set; arguments are validated and
passed as an argv array, never concatenated into a command line. This rules out
a web terminal and a "run command" widget by design.

## D8. HTTP: std.http.Server over std.Io streams

Spike result: `std.http.Server` takes a plain Reader/Writer pair, so it sits on
`Io.net.Stream` with one task per connection and a connection cap. Routing,
keep-alive, HEAD and error paths work; Debug build RSS was about 7 MB after 300
requests. A hand-written server is not justified.

Costs found while testing: the standard library asserts instead of returning an
error when a POST has no Content-Length or Transfer-Encoding, which lets any
client crash the process. `server.zig` guards against it and answers 411.
Expect more edges like this. Fuzz the request path before release. There are
also no read timeouts yet (see the TODO in `server.zig`).

## Resolved from the early open list

- **HTTP server**: `std.http.Server`, D8.
- **TLS**: reverse proxy, D9.
- **Password hashing**: argon2id from `std.crypto.pwhash`, OWASP minimum
  parameters (19 MiB, t=2, p=1), stored as PHC strings so they can be raised later.
- **Storage format**: flat files, see the architecture overview.
- **Privileged action path**: polkit, see the architecture overview.
- **Live stream under load**: 16 concurrent streams measured at about 8 MB RSS
  on Linux, see `docs/development/performance.md`.

## Open decisions

- **Outbound notifications** (email, webhook): alerts are in-app only. An
  outbound HTTP client means TLS client code and a place to store secrets. Not
  decided; probably a webhook first, behind its own config, off by default.
- **Multiple servers**: the Agent is a module today. A remote agent needs an
  authenticated channel that does not exist yet.
- **Settings and user management in the browser**: users are CLI-only today.
  Doing it in the web UI means a writable user store inside the network-facing
  process, which is a trade-off, not an oversight.

## D9. TLS: reverse proxy, not built in

`std.crypto.tls` has no server side in 0.17, and a hand-rolled TLS server is the
wrong place to spend risk in a security tool. NodOS speaks HTTP on loopback by
default and the installation guide shows Caddy and nginx in front. Trade-off:
one more moving part for the admin, in exchange for certificate handling,
renewal and protocol hygiene done by software that specializes in it. Revisit
when the standard library gains a maintained server implementation.

## D10. Docker and systemd integrations call out; they never embed a shell

Docker is spoken to over its socket with a minimal HTTP/1.0 client. systemd is
driven through `systemctl` and `journalctl` with fixed argument vectors and a
10 second timeout. Both are allowlist-shaped: three verbs each, container
references validated by character set, systemd units matched against the config.
Both are admin-only for anything that reads logs or changes state, and audited.
