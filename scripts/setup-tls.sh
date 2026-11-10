#!/usr/bin/env bash
# Puts Caddy in front of NodOS so the dashboard is served over HTTPS.
# It does not install Caddy for you: pick the package from caddyserver.com/docs/install
# so the key and repository are ones you chose, not ones a script fetched.
set -euo pipefail

usage() {
    echo "usage: sudo scripts/setup-tls.sh NAME [--port 8080] [--dry-run]" >&2
    echo "  NAME is the host name you will type in the browser, e.g. nodos.home.lan" >&2
    exit 2
}

NAME=""
PORT=8080
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="${2:-}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage ;;
        -*) usage ;;
        *) [ -z "$NAME" ] || usage; NAME="$1"; shift ;;
    esac
done
[ -n "$NAME" ] || usage

case "$NAME" in
    *[!A-Za-z0-9.-]*|.*|*.|-*|"") echo "setup-tls: NAME may only hold letters, digits, dots and dashes" >&2; exit 2 ;;
esac
case "$PORT" in
    ""|*[!0-9]*) echo "setup-tls: --port must be a number" >&2; exit 2 ;;
esac

CONF="${NODOS_CONF:-/etc/nodos/nodos.conf}"
SNIPPET="${CADDY_SNIPPET:-/etc/caddy/conf.d/nodos.caddy}"

SITE="$NAME {
    encode zstd gzip
    reverse_proxy 127.0.0.1:$PORT {
        header_up X-Forwarded-For {remote_host}
        flush_interval -1
    }
}"

if [ "$DRY" -eq 1 ]; then
    echo "would write $SNIPPET:"
    echo "$SITE"
    echo "would make sure $CONF has: trusted_proxy = 127.0.0.1 and secure_cookies = true"
    exit 0
fi

if [ -z "${CADDY_SNIPPET:-}" ] && [ "$(id -u)" -ne 0 ]; then
    echo "setup-tls: run as root (sudo)" >&2
    exit 1
fi
if ! command -v caddy >/dev/null 2>&1; then
    echo "setup-tls: caddy is not installed. Install it first: https://caddyserver.com/docs/install" >&2
    exit 1
fi
if [ ! -f "$CONF" ]; then
    echo "setup-tls: $CONF not found; install NodOS first" >&2
    exit 1
fi

install -d -m 0755 "$(dirname "$SNIPPET")"
printf '%s\n' "$SITE" > "$SNIPPET"
chmod 0644 "$SNIPPET"
echo "wrote $SNIPPET"

if ! grep -q '^[[:space:]]*import[[:space:]].*conf.d' /etc/caddy/Caddyfile 2>/dev/null; then
    echo "note: /etc/caddy/Caddyfile does not import conf.d yet. Add this line to it:"
    echo "      import /etc/caddy/conf.d/*.caddy"
fi

set_key() {
    key="$1"
    value="$2"
    if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$CONF"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$CONF"
    else
        printf '%s = %s\n' "$key" "$value" >> "$CONF"
    fi
}
set_key trusted_proxy 127.0.0.1
set_key secure_cookies true
echo "updated $CONF (trusted_proxy, secure_cookies)"

caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || echo "warning: caddy validate failed; check /etc/caddy/Caddyfile"
if [ -z "${CADDY_SNIPPET:-}" ]; then
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || echo "reload caddy yourself"
    systemctl restart nodos 2>/dev/null || true
fi

echo
echo "done. Open https://$NAME/"
echo "Names on a private network (.lan, .home.arpa) get a certificate from Caddy's own authority:"
echo "run 'caddy trust' once on each device that opens the dashboard, or use a public name."
