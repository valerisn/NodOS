#!/usr/bin/env bash
# Installs a real app through the API against the real Docker daemon, checks
# that it runs and that its folder is mounted read-only, then removes it.
set -euo pipefail

BIN="${1:-zig-out/bin/nodos}"
PORT="${APPS_PORT:-18166}"
APP_PORT="${APPS_APP_PORT:-18533}"
DIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null || true
    docker rm -f nodos-navidrome-app >/dev/null 2>&1 || true
    docker network rm nodos-navidrome >/dev/null 2>&1 || true
    docker volume rm nodos-navidrome-data >/dev/null 2>&1 || true
    rm -rf "$DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; tail -20 "$DIR/server.log" >&2 || true; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "docker not available, skipping"; exit 0; }
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable, skipping"; exit 0; }

mkdir -p "$DIR/music"
cat > "$DIR/nodos.conf" <<EOF
port = $PORT
data_dir = $DIR/data
secure_cookies = false
update_check = false
EOF

printf '%s\n' 'apps e2e passphrase' | "$BIN" user add tester --config "$DIR/nodos.conf" >/dev/null
"$BIN" serve --config "$DIR/nodos.conf" 2> "$DIR/server.log" &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/api/v1/health" >/dev/null && break; sleep 0.1; done
URL="http://127.0.0.1:$PORT/api/v1"

LOGIN="$(curl -s -i -H 'content-type: application/json' -d '{"username":"tester","password":"apps e2e passphrase"}' "$URL/login")"
TOKEN="$(echo "$LOGIN" | grep -i '^set-cookie:' | sed -E 's/.*nodos_session=([^;]+).*/\1/')"
CSRF="$(echo "$LOGIN" | grep -o '"csrf":"[^"]*"' | cut -d'"' -f4)"
[ -n "$TOKEN" ] || fail "could not sign in"
AUTH=(-H "Cookie: nodos_session=$TOKEN")
POST=(-H 'content-type: application/json' -H "x-csrf-token: $CSRF")

curl -s "${AUTH[@]}" "$URL/apps" | grep -q '"docker":"ok"' || fail "catalog does not see docker"
curl -s "${AUTH[@]}" "$URL/apps" | grep -q '"id":"navidrome"' || fail "catalog is missing navidrome"

CODE="$(curl -s -o "$DIR/out.txt" -w '%{http_code}' "${AUTH[@]}" "${POST[@]}" -d '{"id":"navidrome"}' "$URL/apps/install")"
[ "$CODE" = "400" ] || fail "install without the required folder should be 400, got $CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "${POST[@]}" -d '{"id":"navidrome","paths":{"music":"/etc"}}' "$URL/apps/install")"
[ "$CODE" = "400" ] || fail "a system folder must be refused, got $CODE"

CODE="$(curl -s -o "$DIR/out.txt" -w '%{http_code}' "${AUTH[@]}" "${POST[@]}" -d "{\"id\":\"navidrome\",\"port\":$APP_PORT,\"paths\":{\"music\":\"$DIR/music\"}}" "$URL/apps/install")"
[ "$CODE" = "202" ] || { cat "$DIR/out.txt"; fail "install not accepted, got $CODE"; }

STATE=""
for _ in $(seq 1 120); do
    JOBS="$(curl -s "${AUTH[@]}" "$URL/apps/jobs")"
    STATE="$(echo "$JOBS" | grep -o '"state":"[a-z]*"' | head -1 | cut -d'"' -f4)"
    [ "$STATE" = "done" ] || [ "$STATE" = "failed" ] && break
    sleep 2
done
[ "$STATE" = "done" ] || fail "install ended in state '$STATE': $JOBS"

[ "$(docker inspect -f '{{.State.Running}}' nodos-navidrome-app)" = "true" ] || fail "container is not running"
[ "$(docker inspect -f '{{index .Config.Labels "nodos.app"}}' nodos-navidrome-app)" = "navidrome" ] || fail "container has no nodos.app label"
docker inspect -f '{{range .Mounts}}{{.Source}}={{.RW}} {{end}}' nodos-navidrome-app | grep -q "$DIR/music=false" || fail "music folder is not mounted read-only"
curl -s "${AUTH[@]}" "$URL/apps" | grep -q '"installed":true' || fail "catalog does not show the app as installed"

for _ in $(seq 1 30); do curl -sf -o /dev/null "http://127.0.0.1:$APP_PORT/" && break; sleep 1; done
curl -sf -o /dev/null "http://127.0.0.1:$APP_PORT/" || fail "the app does not answer on port $APP_PORT"

CODE="$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "${POST[@]}" -d "{\"id\":\"navidrome\",\"port\":$APP_PORT,\"paths\":{\"music\":\"$DIR/music\"}}" "$URL/apps/install")"
[ "$CODE" = "202" ] || fail "second install request got $CODE"
for _ in $(seq 1 30); do
    STATE="$(curl -s "${AUTH[@]}" "$URL/apps/jobs" | grep -o '"state":"[a-z]*"' | tr '\n' ' ')"
    echo "$STATE" | grep -q 'failed' && break
    sleep 1
done
echo "$STATE" | grep -q 'failed' || fail "installing twice should fail, got: $STATE"
[ "$(docker inspect -f '{{.State.Running}}' nodos-navidrome-app)" = "true" ] || fail "the failed second install damaged the first"

CODE="$(curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "${POST[@]}" -d "" "$URL/apps/navidrome/remove")"
[ "$CODE" = "200" ] || fail "remove returned $CODE"
docker inspect nodos-navidrome-app >/dev/null 2>&1 && fail "container survived removal"
docker volume inspect nodos-navidrome-data >/dev/null 2>&1 || fail "removal must keep the data volume"
grep -q '"action":"app.install"' "$DIR/data/audit.log" || fail "install not audited"
grep -q '"action":"app.remove"' "$DIR/data/audit.log" || fail "remove not audited"
echo "apps e2e passed"
