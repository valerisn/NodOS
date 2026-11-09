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

## Upgrading

Build or download the new binary and run `sudo scripts/install.sh` again. It
replaces the binary and unit file, keeps your config and data, and doesn't
restart the service, so finish with `sudo systemctl restart nodos`. Everyone is
signed out, because sessions live in memory.

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
