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

## D6. License: MIT

Short, permissive, universally understood. Apache-2.0 adds a patent grant,
which matters more for corporate contributors than for a home server tool.
Copyleft (GPL/AGPL) would deter some contributors and does not protect against
the realistic threats to this project. Changing license later needs every
contributor's consent, so this is the one to get right now. Say so if you want
Apache-2.0 instead.

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

## Open decisions

- **SSE under load**: still unmeasured. Many idle streaming connections need a
  test before the live stream ships.
- **TLS**: terminate in NodOS (std.crypto.tls server support is limited) or
  require a reverse proxy. Leaning toward documented reverse-proxy deployment
  plus optional certificate loading if the standard library can do it safely.
- **Password hashing**: `std.crypto.pwhash` provides argon2id and scrypt.
  Leaning argon2id with documented parameters.
- **Storage format**: flat files versus embedded SQLite. See overview.
- **Privileged action path**: polkit versus helper process. See overview.
