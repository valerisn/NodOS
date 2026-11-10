# Troubleshooting

Start with the log: `journalctl -u nodos -e`. Set `log_level = debug` in the
config for more detail.

## The service won't start

`nodos: /etc/nodos/nodos.conf:7: unknown key` means the config has a typo. The
message names the file and line. Every key is listed in
[configuration](../configuration/README.md).

`cannot create data_dir`: the `nodos` user can't write the data directory. It
should be owned by `nodos` (`sudo chown nodos:nodos /var/lib/nodos`). The unit
only allows writes to `/var/lib/nodos`; if you changed `data_dir`, add the new
path to `ReadWritePaths=` with `systemctl edit nodos`.

`AddressInUse`: another program is on that port. Change `port`.

## I can't sign in

The sign-in page says the password is wrong when it is, and also when the user
doesn't exist; that is deliberate. Check `nodos user list`.

After five failed attempts from one address you are locked out for 15 minutes,
the page says so. Restarting NodOS clears the lockout.

You can sign in but the page sends you back to sign-in: the cookie is being
dropped. Over plain `http://` (not localhost) browsers refuse `Secure` cookies.
Either use HTTPS through a reverse proxy, or for a trusted LAN set
`secure_cookies = false`.

New users don't work until the service restarts, because users are read at
startup.

## The dashboard says "Connecting" or "No data"

"No data" with a note about Linux means the host is not Linux, where host
monitoring is not implemented. On Linux, check `journalctl -u nodos` for a
`sample failed` line.

Behind a reverse proxy, the live stream needs buffering off (`proxy_buffering
off` in nginx) or events arrive in clumps or not at all.

## The Docker page says Docker is not reachable

The socket must exist and the `nodos` user must be able to open it. Check
`ls -l /var/run/docker.sock` (group `docker`) and that the service has
`SupplementaryGroups=docker`. See the installation guide.

## Starting or stopping a service fails with "Interactive authentication required"

NodOS runs unprivileged, so systemd asks polkit. Add a rule for that unit, as
in `packaging/50-nodos.rules.example`. Unit names in the rule end in
`.service`; names in `nodos.conf` do not.

A service shows "not installed" when systemd has no unit with that name.

## Logs for a service are empty or an error

Reading the journal needs the `systemd-journal` group for the `nodos` user.

## Updating

`nodos update` says it has no release signing key: this binary was built
without one, as development builds are. Official release binaries include it.

`the release signature is NOT valid`: the download was corrupted or tampered
with, or the release was signed with a different key than this binary trusts.
Nothing was changed. Try again later; if it persists, open a private security
report.

`the release server has no published release yet`: there is no release to
install, or the address is wrong (check `update_mirror`).

An update installed but the service did not start: it was rolled back
automatically and the version is on a skip list in
`/var/lib/nodos/update-state`. See `journalctl -u nodos -e` for why, and remove
the line to try again, or use `sudo nodos update --force`.

The dashboard never shows an update notice: the check runs 30 seconds after
start and then twice a day, needs outbound HTTPS, and is off when
`update_check = false`.

## Reporting a bug

Open an issue with the output of `nodos version`, your OS, and the relevant
log lines. Remove anything private first. Security problems go through the
private route in [SECURITY.md](../../SECURITY.md).
