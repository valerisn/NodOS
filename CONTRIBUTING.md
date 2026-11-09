# Contributing to NodOS

Thanks for helping. This file covers the practical parts.

## Setup

Install Zig 0.17.0 exactly (see `minimum_zig_version` in `build.zig.zon`), then:

```sh
zig build            # compile
zig build test       # unit tests
zig build fmt        # formatting check, fix with: zig fmt .
zig build run -- version
```

## Rules

1. Keep the project compiling and tests green on every commit.
2. Run `zig fmt .` before committing. CI rejects unformatted code.
3. No new dependencies without an entry in `docs/architecture/decisions.md`.
4. Handle errors explicitly. Do not discard an error you could act on.
5. Parsers of OS data take text in and return structs, so they can be tested
   against fixture strings. Put file reading in a separate thin function.
6. Anything that touches the host (services, containers, files) must go through
   an enumerated action with validated arguments. Never build a shell string.
7. Update docs in the same pull request as the behavior change.
8. Comments explain why, not what.

## Pull requests

Small and focused beats large and thorough. Fill in the template: what changed,
why, how you tested it, and screenshots for UI changes. Link the issue.

## Reporting security issues

Not here. See [SECURITY.md](SECURITY.md).
