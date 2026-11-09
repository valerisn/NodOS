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

### Fixed
- Server no longer crashes on a body-bearing request without framing headers
  (standard library assertion), it answers 411.
