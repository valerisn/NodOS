# Installation

NodOS is one static binary. These steps are for a Linux machine with systemd.
Other systems can run the binary, but host monitoring is Linux only for now.

## Requirements

- Linux, x86_64 or aarch64, with systemd
- For the Docker page: a Docker Engine you can reach by socket
- To build from source: Zig 0.17.0 (nothing else)

## 1. Get the binary

There is no tagged release yet. Build it:

```sh
git clone https://github.com/valerisn/NodOS.git
cd NodOS
zig build -Doptimize=ReleaseSafe -Dstrip=true
```

Cross-compiling for a Raspberry Pi or another box works from anywhere, for
example `-Dtarget=aarch64-linux-musl`. The result is statically linked and
under one megabyte.

## 2. Install

```sh
sudo scripts/install.sh zig-out/bin/nodos
```

Read the script first, it is about thirty lines. It creates an unprivileged
`nodos` user, a data directory at `/var/lib/nodos`, installs the binary to
`/usr/local/bin`, writes `/etc/nodos/nodos.conf` if it doesn't exist, and
installs a hardened systemd unit. It does not start anything.

## 3. Create the first admin

There is no default account. The password comes from stdin so it never shows
up in `ps` or shell history:

```sh
printf '%s\n' 'a long passphrase' | sudo -u nodos nodos user add YOURNAME --config /etc/nodos/nodos.conf
```

Passwords need 10 or more characters. Add read-only accounts with `--role viewer`.
Other commands: `nodos user list`, `nodos user passwd NAME`, `nodos user remove NAME`.
Restart the service after changing users.

## 4. Start it

```sh
sudo systemctl enable --now nodos
curl http://127.0.0.1:8080/api/v1/health
```

By default NodOS listens on `127.0.0.1:8080` only. Open it with an SSH tunnel
(`ssh -L 8080:127.0.0.1:8080 yourbox`) or put a reverse proxy in front.

## 5. Put TLS in front

NodOS speaks plain HTTP. Anything that crosses a network should go through a
reverse proxy that terminates TLS. Two examples, both on the same machine.

Caddy (gets a certificate by itself when the name is public or uses its
internal CA otherwise):

```
nodos.example.lan {
    reverse_proxy 127.0.0.1:8080
}
```

nginx:

```nginx
server {
    listen 443 ssl;
    server_name nodos.example.lan;
    ssl_certificate     /etc/ssl/nodos.crt;
    ssl_certificate_key /etc/ssl/nodos.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header X-Forwarded-For $remote_addr;   # overwrite, don't append client input
        proxy_buffering off;                              # keeps the live stream live
        proxy_read_timeout 1h;
    }
}
```

Then tell NodOS to trust that proxy, so the login throttle and the audit log see
real client addresses instead of `127.0.0.1`:

```
trusted_proxy = 127.0.0.1
```

Only name a proxy you run. With `$remote_addr` as above, the proxy always writes
the true peer address as the last entry, which is the one NodOS uses.

Keep `secure_cookies = true` (the default) when using HTTPS.

## Optional: Docker

Add the service to the `docker` group through a drop-in, then restart:

```sh
sudo systemctl edit nodos
```
```ini
[Service]
SupplementaryGroups=docker
```

**Anyone who can reach the Docker socket can become root on the host.** NodOS
restricts itself to listing containers, reading logs and three actions (start,
stop, restart), but it holds that power while running. Leave this out, or set
`docker_socket = off`, if you don't want to hand it over.

## Optional: systemd services

List the units in `/etc/nodos/nodos.conf`:

```
services = ssh, nginx
```

Reading status is open to any signed-in user. To let admins start, stop and
restart units from the dashboard, grant exactly those units to the `nodos` user
with polkit and add the `systemd-journal` group if you want logs. Start from
`packaging/50-nodos.rules.example`:

```sh
sudo install -m 0644 packaging/50-nodos.rules.example /etc/polkit-1/rules.d/50-nodos.rules
sudoedit /etc/polkit-1/rules.d/50-nodos.rules   # list your units
```

## Updating

NodOS checks for new releases and tells you in the dashboard. Installing one is
a command you run:

```sh
nodos update --check      # just look; exit status 10 means an update is waiting
sudo nodos update         # download, verify, install, restart
sudo nodos update --rollback
```

What `sudo nodos update` does, in order:

1. asks the release server for the latest release
2. downloads the tarball, `SHA256SUMS` and its signature
3. checks the Ed25519 signature, then the checksum. Anything that does not
   verify is refused and nothing on disk changes
4. unpacks the binary next to the installed one and runs it once, insisting it
   reports exactly the version the signed release names
5. keeps your current binary as `nodos.previous`, then swaps the new one in
   with a single atomic rename
6. restarts the service and waits up to 30 seconds for it to report the new
   version. If it doesn't, the old binary is put back, the service is restarted
   again, and that version is remembered as bad so it is not tried again
   automatically

Everyone is signed out afterwards, because sessions live in memory.
`sudo nodos update --rollback` swaps the previous binary back in, and running it
twice returns to where you started.

**The web interface never installs anything.** The server runs as an
unprivileged user and can only tell you an update exists. Installing needs root,
and only you, at a terminal, do that.

Releases are signed with a key whose public half is compiled into the binary.
If you run your own mirror signed with your own key, pass `--pubkey HEX`; see
[configuration](../configuration/README.md) for `update_mirror`.

### Turning the update check off

```
update_check = false
```

The check is the only outbound connection NodOS makes: one HTTPS request to
GitHub about every twelve hours, carrying a `User-Agent` of `nodos/<version>`
and nothing else. GitHub sees your IP address, as it would for any download.
Setting `update_check = false` stops it, and `nodos update` still works when you
run it yourself.

### Automatic updates (probably don't)

```sh
sudo nodos update --auto status
sudo nodos update --auto on --yes     # without --yes it only prints the warning
sudo nodos update --auto off
```

This enables a systemd timer that runs once a day. **It is off by default and
we recommend leaving it off.** Software that changes itself while nobody is
watching can break a server at 3 am, and if a release turns out to be broken
it will be installed on your machine anyway until the maintainers notice and
pull it.

What is done to make it less risky:

- only patch releases of the version you already run (0.1.2 to 0.1.3, never
  0.1.x to 0.2.0); bigger jumps wait for you
- a release must be at least 3 days old, so a bad one is usually pulled first
- prereleases are never installed
- the same signature and checksum checks as a manual update
- the new version has to come up healthy, or it is rolled back and added to a
  skip list

It is still not risk free. Read the changelog and run `sudo nodos update`
yourself when it suits you; that is the safer habit.

## Backup and restore

```sh
sudo -u nodos nodos backup --out /var/backups/nodos.tar --config /etc/nodos/nodos.conf
sudo systemctl stop nodos
sudo -u nodos nodos restore /var/backups/nodos.tar --force --config /etc/nodos/nodos.conf
sudo systemctl start nodos
```

The backup is a plain tar file (open it with `tar tf`) holding `users.db`, the
audit log and a small manifest. It contains password hashes, so it is written
with mode 0600; keep it somewhere private. It does not include
`/etc/nodos/nodos.conf`, which you manage yourself.

`backup` refuses to overwrite an existing file and `restore` refuses to
overwrite existing users unless you pass `--force`. A restore reads only the
three known file names, rejects anything else in the archive, and checks that
the user list parses and contains an admin before it writes anything.

## Uninstalling

```sh
sudo systemctl disable --now nodos
sudo rm /etc/systemd/system/nodos.service /usr/local/bin/nodos
sudo systemctl daemon-reload
# optional, deletes users and the audit log:
sudo rm -r /etc/nodos /var/lib/nodos
sudo userdel nodos
```

Problems? See [troubleshooting](../troubleshooting/README.md).
