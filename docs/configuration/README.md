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

## Files in data_dir

- `users.db`: `id:name:role:hash`, one per line. Written atomically.
- `audit.log`: one JSON object per line, append-only. Records logins (success,
  failure, throttled) and logouts with timestamp, actor, address and result.
  Never records passwords or tokens.
