# Privacy

NodOS is software you run yourself. The project does not operate a service, has
no accounts, and receives no data from your installation.

## Stored on your machine

| Data | Where | Notes |
| --- | --- | --- |
| Usernames and password hashes (argon2id) | `users.db` in the data directory, mode 0600 | Passwords are never stored or logged |
| Audit log | `audit.log` in the data directory | Usernames, actions, targets, client IP addresses, timestamps. No passwords or tokens |
| Updater history | `/var/lib/nodos-update` | Versions installed or rolled back |
| Sessions | Memory only | Gone after a restart |

IP addresses in the audit log are personal data in some jurisdictions. If other
people use your NodOS, you are the operator and decide how long to keep it.
Delete or rotate `audit.log` as you see fit.

## Network

NodOS makes one outbound connection: about every twelve hours it fetches the
latest release information from GitHub (or your `update_mirror`), sending a
`nodos/<version>` User-Agent. GitHub sees your IP address as it would for any
web request, and its own privacy statement applies to that. Set
`update_check = false` to stop it. `nodos update` contacts the same server only
when you run it.

If you set `webhook_url`, NodOS also sends alert messages (host name, alert
type, affected mount or interface, value) to that address and nowhere else.
The address is yours; the receiver's privacy terms apply.

There is no telemetry, no crash reporting, and no analytics. The dashboard sets
one cookie, a session cookie needed to stay signed in. It uses no third-party
resources.
