# Configuration

NodOS reads one file, passed with `--config`:

```sh
nodos serve --config /etc/nodos/nodos.conf
```

With no `--config`, defaults apply. Format: `key = value`, one per line, `#`
starts a comment. Unknown keys and bad values stop startup with the file and
line number.

| Key | Default | Meaning |
| --- | --- | --- |
| `listen` | `127.0.0.1` | IP address to bind. Loopback by default; widen it on purpose |
| `port` | `8080` | TCP port |
| `data_dir` | `/var/lib/nodos` | Holds `users.db` and `audit.log`. Created if missing |
| `log_level` | `info` | `err`, `warn`, `info` or `debug`. Logs go to stderr |
| `secure_cookies` | `true` | Mark session cookies `Secure`. Set `false` only for plain-HTTP LANs |
| `trusted_proxy` | empty | IP of a reverse proxy whose `X-Forwarded-For` header is believed (rightmost entry). Empty ignores the header |
| `update_check` | `true` | Look for new releases about every 12 hours and show a notice. The only outbound connection NodOS makes. `false` disables it |
| `update_mirror` | empty | Fetch releases from this URL instead of GitHub: a directory holding `latest.json` and `download/<tag>/`. https only, or http to this machine |
| `services` | empty | Comma separated systemd units NodOS may show and control, without `.service`. Empty turns the feature off |
| `docker_socket` | `/var/run/docker.sock` | Docker Engine socket, or `off`. See the warning below |
| `sample_interval_ms` | `2000` | Metrics sampling interval, 500 to 60000. Unused until Phase 3 |

## Creating users

There is no default account. Create the first admin from the CLI, with the
password on stdin so it never appears in `ps` or shell history:

```sh
printf '%s\n' 'a long passphrase' | nodos user add alice --config /etc/nodos/nodos.conf
printf '%s\n' 'another passphrase' | nodos user add bob --role viewer --config /etc/nodos/nodos.conf
```

Names are 1 to 32 characters of `a-z`, `0-9`, `-` and `_`. Passwords are 10 to
256 bytes and are stored as argon2id hashes in `data_dir/users.db` (mode 0600
on POSIX). Restart the server to pick up new users.

On Windows PowerShell 5.1, piping text into a native program can change its
encoding. Redirect from a UTF-8 file with `cmd /c "nodos user add alice < pw.txt"`
instead.

## Services access

```
services = ssh, nginx, postgresql
```

This is an allowlist, not a pattern. Only these units can be shown, read logs
for, or controlled, and each name must be letters, digits and `_ . - @ :`,
starting with a letter or digit (so a typo can never become a command line
option). Everyone signed in sees status; admins read logs and start, stop and
restart, with every action audited.

Control needs OS permission because NodOS runs as an unprivileged user. Grant
it per unit with a polkit rule instead of running NodOS as root:

```js
// /etc/polkit-1/rules.d/50-nodos.rules
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        subject.user == "nodos" &&
        ["nginx.service", "postgresql.service"].indexOf(action.lookup("unit")) >= 0) {
        return polkit.Result.YES;
    }
});
```

List only the units you want controllable. Status and logs work without it;
the user needs to be in the `systemd-journal` group to read journal logs.

## Docker access

NodOS reads the container list, shows logs, and can start, stop and restart
containers. To do that, the user running NodOS needs read and write access to
the Docker socket, usually by being in the `docker` group.

Be clear about what that grants: **anyone who can write to the Docker socket
can get root on the host.** NodOS limits what it asks Docker to do (three
fixed verbs, validated container names, admin only, audited), but the process
itself holds that power. If you don't want that, set `docker_socket = off` and
the Docker page and routes turn off. Create viewer accounts for anyone who
should only look: viewers can list containers but cannot read logs or act.

## Files in data_dir

- `users.db`: `id:name:role:hash`, one per line. Written atomically.
- `audit.log`: one JSON object per line, append-only. Records logins (success,
  failure, throttled) and logouts with timestamp, actor, address and result.
  Never records passwords or tokens.
