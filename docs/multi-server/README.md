# Several servers

One NodOS can show other NodOS servers, so a rack, a NAS and a spare box can be
looked after from one dashboard. Nothing is installed besides NodOS itself.

## How it works

The server you log in to is the hub. For each other server it keeps an address
and an API token. When you pick another server in the Server menu, the hub
passes your requests on, using that token, and shows the answers. The other
server is polled every two seconds, so its live view is a little less smooth
than the one you are signed in to.

Your hub login still decides what you may do: viewers can read overview, alerts,
storage health, container and service lists, images and container stats;
administrators can do everything they could do on that server, with the CSRF
protection and audit logging they have locally. Changes made through a hub show
up in the other server's audit log under the token's name.

## Connect a server

On the server that will be looked at (call it rack2):

```sh
sudo -u nodos nodos token add hub --config /etc/nodos/nodos.conf
sudo systemctl restart nodos
```

The command prints the token once. NodOS keeps only its hash. Then on the hub:

```sh
printf '%s\n' 'THE-TOKEN' | sudo -u nodos nodos server add rack2 http://192.168.1.20:8080 --config /etc/nodos/nodos.conf
sudo systemctl restart nodos
```

Use `https://` addresses whenever the connection crosses anything you do not
control. Plain `http://` is fine on a home network you trust, but the token
travels in clear text. Both machines need a version with this feature.

Remove access with `nodos token remove hub` on the remote server (restart it)
and `nodos server remove rack2` on the hub. Use `--role viewer` when making
the token if the hub should only be able to read.

## Security notes

- The hub stores each token in `servers.db` (mode 0600, readable only by the
  `nodos` user). Whoever controls the hub can act on every connected server
  with that token's role. Treat the hub like a jump host and protect it
  accordingly: two-factor login, HTTPS, few admins.
- A token with `--role viewer` limits the damage if the hub is compromised, at
  the price of administrators not being able to act on that server from the hub.
- Tokens are 256 random bits. Wrong ones are throttled per source address.
- The hub never follows redirects when talking to another server, so a hostile
  address cannot be used to capture a token, and only the plain `http(s)://host:port`
  form is accepted.
- A hub cannot be chained through another hub, and a token cannot be used to
  sign in to the dashboard.
