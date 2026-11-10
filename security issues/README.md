# Security issues

Every security problem found in NodOS, how it was fixed, and what is still open. IDs are internal to this project. None of these have a CVE and none affected a published release: they were found and fixed in the pre-release security review.

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| [NODOS-2026-001](NODOS-2026-001-login-throttle-race.md) | Login throttle bypass through parallel requests | High | Fixed before release |
| [NODOS-2026-002](NODOS-2026-002-unauthenticated-memory-exhaustion-concurrent-hashing.md) | Unauthenticated memory exhaustion through concurrent password hashing | High | Fixed before release |
| [NODOS-2026-003](NODOS-2026-003-throttle-reset-and-no-account-limit.md) | Failed-login count reset by a successful login, and no per-account limit | Medium | Fixed before release |
| [NODOS-2026-004](NODOS-2026-004-ipv6-throttle-bucket-evasion.md) | IPv6 clients could dodge the throttle by rotating addresses | Medium | Fixed before release |
| [NODOS-2026-005](NODOS-2026-005-unbounded-throttle-table.md) | Unbounded growth of the throttle table | Medium | Fixed before release |
| [NODOS-2026-006](NODOS-2026-006-updater-symlink-privilege-escalation.md) | Root updater followed symlinks in a directory the service user owns | High | Fixed before release |
| [NODOS-2026-007](NODOS-2026-007-login-csrf-content-type.md) | Login accepted any content type, allowing cross-site login requests | Low | Fixed before release |

## Reviewed and accepted

These came up in the review and were left as they are on purpose.

- **The health endpoint reports the version without a login.** The dashboard and the update check need it. It tells an attacker which release runs; keep NodOS updated and behind a proxy or VPN.
- **No Host header validation.** NodOS never builds absolute URLs or reset links from it, so a forged Host has nothing to poison.
- **The services list runs `systemctl` per request.** Only allowlisted unit names are passed, in a fixed argument list with no shell. It needs a login and costs one short-lived process per call.
- **Update metadata is protected by signatures, not by TLS pinning.** Release files are verified with an Ed25519 key compiled into the binary, so a hostile mirror can withhold updates but cannot make NodOS install an unsigned one.

## Reporting

Open a private security advisory on the GitHub repository. Please do not file public issues for vulnerabilities.
