# Security policy

## Reporting a vulnerability

Do not open a public issue. Use GitHub private vulnerability reporting: open the
repository's Security tab and choose "Report a vulnerability". Include the
affected version, reproduction steps, and the impact you see.

Expect an acknowledgement within 7 days. This is a volunteer project, so fix
timelines depend on severity. Critical issues get priority. Please allow a
reasonable disclosure window before publishing details.

Supported versions: there is no release yet. Once there is, only the latest
minor version receives security fixes.

## Security model

This describes the design intent. Items are not implemented until the roadmap
says so.

**Trust boundary.** The HTTP interface is the boundary. Every endpoint except
login and the static assets requires an authenticated session. Privileged
actions additionally require an admin role.

**Deployment assumptions.**
- NodOS runs on a trusted home or lab network.
- It is not exposed directly to the internet. Put it behind a VPN or a reverse
  proxy with TLS.
- The `nodos` process runs as an unprivileged user.

**Design rules.**
- No endpoint executes arbitrary commands. Actions are enumerated and take
  validated arguments passed as argv, never through a shell.
- Passwords are hashed with argon2id. No default credentials. The first admin is
  created during setup.
- Sessions use random server-side tokens in HttpOnly, SameSite cookies.
  State-changing requests require a CSRF token.
- Login attempts are rate limited.
- Administrative actions are written to an append-only audit log.
- Secrets never appear in logs or API responses.

**Known sharp edges.** Access to the Docker socket is equivalent to root on the
host. Granting NodOS that access grants that power to anyone who can
authenticate as a NodOS admin.

Good-faith research is covered by the [safe harbor statement](docs/legal/safe-harbor.md). Fixed issues are listed in [security issues](security%20issues/README.md).
