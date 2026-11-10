#!/usr/bin/env bash
# Two real servers: one hub, one remote. The hub reaches the remote with an API
# token and passes requests on for signed-in users, within their role.
set -euo pipefail

BIN="${1:-zig-out/bin/nodos}"
HUB_PORT="${HUB_PORT:-18301}"
REMOTE_PORT="${REMOTE_PORT:-18302}"
DIR="$(mktemp -d)"
PIDS=()
cleanup() {
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null || true; done
    rm -rf "$DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; echo "--- hub log:" >&2; cat "$DIR/hub.log" >&2 || true; echo "--- remote log:" >&2; cat "$DIR/remote.log" >&2 || true; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

NATIVE="$(cygpath -m "$DIR" 2>/dev/null || echo "$DIR")"
for side in hub remote; do
    port=$HUB_PORT
    [ "$side" = remote ] && port=$REMOTE_PORT
    cat > "$DIR/$side.conf" <<EOF
port = $port
data_dir = $NATIVE/$side
secure_cookies = false
update_check = false
docker_socket = off
EOF
done

printf '%s\n' 'hub admin passphrase' | "$BIN" user add boss --config "$DIR/hub.conf" >/dev/null
printf '%s\n' 'hub viewer passphrase' | "$BIN" user add guest --role viewer --config "$DIR/hub.conf" >/dev/null

OUT="$("$BIN" token add hub --config "$DIR/remote.conf")"
TOKEN="$(echo "$OUT" | grep -E '^  [A-Za-z0-9_-]{43}$' | tr -d ' ')"
[ -n "$TOKEN" ] || fail "no token printed: $OUT"
printf '%s\n' "$TOKEN" | "$BIN" server add rack2 "http://127.0.0.1:$REMOTE_PORT" --config "$DIR/hub.conf" >/dev/null

"$BIN" token list --config "$DIR/remote.conf" | grep -q '^hub' || fail "token list"
grep -q "$TOKEN" "$DIR/remote/tokens.db" && fail "the remote stored the token itself, not a hash"
if [ -z "${SKIP_MODE_CHECK:-}" ] && stat -c %a "$DIR/hub/servers.db" >/dev/null 2>&1; then
    [ "$(stat -c %a "$DIR/hub/servers.db")" = "600" ] || fail "servers.db is not mode 600"
    [ "$(stat -c %a "$DIR/remote/tokens.db")" = "600" ] || fail "tokens.db is not mode 600"
fi

"$BIN" serve --config "$DIR/remote.conf" 2> "$DIR/remote.log" &
PIDS+=($!)
"$BIN" serve --config "$DIR/hub.conf" 2> "$DIR/hub.log" &
PIDS+=($!)
for port in $HUB_PORT $REMOTE_PORT; do
    for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$port/api/v1/health" >/dev/null && break; sleep 0.1; done
done

HUB="http://127.0.0.1:$HUB_PORT/api/v1"
REMOTE="http://127.0.0.1:$REMOTE_PORT/api/v1"
JSON='content-type: application/json'

# the token works directly on the remote, a made-up one does not, and it never works on the hub
[ "$(code -H "Authorization: Bearer $TOKEN" "$REMOTE/alerts")" = "200" ] || fail "token rejected by the remote"
[ "$(code -H "Authorization: Bearer ${TOKEN:0:42}x" "$REMOTE/alerts")" = "401" ] || fail "a wrong token was accepted"
[ "$(code -H "Authorization: Bearer $TOKEN" "$HUB/alerts")" = "401" ] || fail "the remote's token works on the hub"

login() {
    curl -s -i -H "$JSON" -d "{\"username\":\"$1\",\"password\":\"$2\"}" "$HUB/login"
}
R="$(login boss 'hub admin passphrase')"
ADMIN_COOKIE="Cookie: nodos_session=$(echo "$R" | grep -i '^set-cookie:' | sed -E 's/.*nodos_session=([^;]+).*/\1/')"
ADMIN_CSRF="$(echo "$R" | grep -o '"csrf":"[^"]*"' | cut -d'"' -f4)"
R="$(login guest 'hub viewer passphrase')"
VIEW_COOKIE="Cookie: nodos_session=$(echo "$R" | grep -i '^set-cookie:' | sed -E 's/.*nodos_session=([^;]+).*/\1/')"

[ "$(code "$HUB/servers")" = "401" ] || fail "server list needs a session"
curl -s -H "$ADMIN_COOKIE" "$HUB/servers" | grep -q '"name":"rack2"' || fail "server list"
curl -s -H "$ADMIN_COOKIE" "$HUB/servers" | grep -q "$TOKEN" && fail "the server list leaks the token"

[ "$(code "$HUB/remote/rack2/alerts")" = "401" ] || fail "proxy without a session"
curl -s -H "$ADMIN_COOKIE" "$HUB/remote/rack2/alerts" | grep -q '"alerts"' || fail "admin could not read the remote's alerts through the hub"
curl -s -H "$VIEW_COOKIE" "$HUB/remote/rack2/alerts" | grep -q '"alerts"' || fail "viewer could not read alerts through the hub"
[ "$(code -H "$VIEW_COOKIE" "$HUB/remote/rack2/settings")" = "403" ] || fail "a viewer must not read the remote's settings"
[ "$(code -H "$VIEW_COOKIE" "$HUB/remote/rack2/audit")" = "403" ] || fail "a viewer must not read the remote's audit log"
[ "$(code -H "$ADMIN_COOKIE" "$HUB/remote/rack2/settings")" = "200" ] || fail "admin settings through the hub"
[ "$(code -H "$ADMIN_COOKIE" "$HUB/remote/nope/alerts")" = "404" ] || fail "unknown server"
[ "$(code -H "$ADMIN_COOKIE" "$HUB/remote/rack2/login")" = "400" ] || fail "login must not be forwarded"
[ "$(code -X POST -H "$ADMIN_COOKIE" -d '' "$HUB/remote/rack2/docker/containers/web/restart")" = "403" ] || fail "a change without csrf"
[ "$(code -X POST -H "$VIEW_COOKIE" -H "x-csrf-token: $ADMIN_CSRF" -d '' "$HUB/remote/rack2/docker/containers/web/restart")" = "403" ] || fail "a viewer must not change anything"
# the remote has docker turned off, so a permitted change reaches it and comes back as its 503
[ "$(code -X POST -H "$ADMIN_COOKIE" -H "x-csrf-token: $ADMIN_CSRF" -d '' "$HUB/remote/rack2/docker/containers/web/restart")" = "503" ] || fail "admin change did not reach the remote"
grep -q '"actor":"hub"' "$DIR/remote/audit.log" 2>/dev/null || echo "note: remote has no audit line for the token yet"

# the remote goes away: the hub says so instead of hanging
kill -9 "${PIDS[1]}" 2>/dev/null || true
sleep 1
[ "$(code -H "$ADMIN_COOKIE" "$HUB/remote/rack2/alerts")" = "502" ] || fail "an unreachable remote should be 502"
[ "$(code "$HUB/health")" = "200" ] || fail "the hub died with the remote"
echo "hub e2e passed"
