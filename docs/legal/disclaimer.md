# Disclaimer

NodOS is provided under the MIT License, "as is", without warranty of any kind.
The authors and contributors are not liable for any damage, data loss, downtime
or security incident that follows from using it.

Things worth knowing before you install it:

- NodOS can restart Docker containers and systemd services. Used wrongly it can
  take your services offline.
- Docker socket access is root-equivalent by nature. If you enable it, anyone
  who gains admin access to NodOS gains a path to root on the host.
- The optional auto-update installs new binaries as root. It verifies an
  Ed25519 signature, but a release can still contain a bug. It is off by default
  and marked as something most people should not enable.
- The built-in server speaks plain HTTP. Put TLS in front before exposing it
  beyond your own machine, and do not expose it to the internet without
  understanding [the security document](../security/README.md).
- You are responsible for backups, for keeping the host patched, and for
  complying with the laws that apply to the machines and data you manage.

NodOS is independent software. It is not affiliated with or endorsed by Docker,
Inc., the systemd project, GitHub, or the Zig Software Foundation. Those names
are used only to say what NodOS works with.
