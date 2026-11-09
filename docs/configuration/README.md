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
