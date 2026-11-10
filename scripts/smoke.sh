#!/usr/bin/env bash
set -euo pipefail

BIN="${1:-zig-out/bin/nodos}"
PORT="${SMOKE_PORT:-18099}"
DIR="$(mktemp -d)"
SERVER_PID=""
FAKE_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null || true
    [ -n "$FAKE_PID" ] && kill -9 "$FAKE_PID" 2>/dev/null || true
    rm -rf "$DIR"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; echo "--- server log:" >&2; cat "$DIR/server.log" >&2 || true; exit 1; }
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

NATIVE_DIR="$(cygpath -m "$DIR" 2>/dev/null || echo "$DIR")"
cat > "$DIR/nodos.conf" <<EOF
port = $PORT
data_dir = $NATIVE_DIR/data
secure_cookies = false
log_level = debug
docker_socket = $NATIVE_DIR/docker.sock
services = ssh
EOF

FAKE_PID=""
if [ -z "${SMOKE_SKIP_POSIX:-}" ]; then
    python3 "$(dirname "$0")/fake_docker.py" "$DIR/docker.sock" "$DIR/docker-requests.log" &
    FAKE_PID=$!
    for _ in $(seq 1 50); do [ -S "$DIR/docker.sock" ] && break; sleep 0.1; done
    [ -S "$DIR/docker.sock" ] || { echo "FAIL: fake docker did not start" >&2; exit 1; }
fi

printf '%s\n' 'smoke test passphrase' | "$BIN" user add smoke --config "$DIR/nodos.conf" >/dev/null
if [ -z "${SMOKE_SKIP_POSIX:-}" ]; then
    [ "$(stat -c %a "$DIR/data/users.db")" = "600" ] || fail "users.db is not mode 600"
fi

"$BIN" serve --config "$DIR/nodos.conf" 2> "$DIR/server.log" &
SERVER_PID=$!

for _ in $(seq 1 50); do
    [ "$(status "http://127.0.0.1:$PORT/api/v1/health" || true)" = "200" ] && break
    sleep 0.1
done
URL="http://127.0.0.1:$PORT/api/v1"

[ "$(status "$URL/health")" = "200" ] || fail "health"
[ "$(status "$URL/me")" = "401" ] || fail "me without cookie should be 401"
[ "$(status "$URL/nope")" = "404" ] || fail "unknown path should be 404"

[ "$(status -X POST -H 'Content-Length:' "$URL/login")" = "411" ] || fail "bodiless POST should be 411"
kill -0 "$SERVER_PID" || fail "server died after bodiless POST"

[ "$(status -H 'content-type: application/json' -d '{"username":"smoke","password":"wrong wrong wrong"}' "$URL/login")" = "401" ] || fail "bad login"
[ "$(status -d '{"username":"smoke","password":"x"}' "$URL/login")" = "415" ] || fail "login must insist on application/json"

LOGIN="$(curl -s -i -H 'content-type: application/json' -d '{"username":"smoke","password":"smoke test passphrase"}' "$URL/login")"
echo "$LOGIN" | head -1 | grep -q '200' || fail "good login"
TOKEN="$(echo "$LOGIN" | grep -i '^set-cookie:' | sed -E 's/.*nodos_session=([^;]+).*/\1/')"
CSRF="$(echo "$LOGIN" | grep -o '"csrf":"[^"]*"' | cut -d'"' -f4)"
[ -n "$TOKEN" ] && [ -n "$CSRF" ] || fail "no token or csrf in login response"

[ "$(status -H "Cookie: nodos_session=$TOKEN" "$URL/me")" = "200" ] || fail "me with cookie"
[ "$(status "$URL/system")" = "401" ] || fail "system without cookie should be 401"
if [ -z "${SMOKE_SKIP_POSIX:-}" ]; then
    sleep 5
    SYS="$(curl -s -H "Cookie: nodos_session=$TOKEN" "$URL/system")"
    echo "$SYS" | grep -Eq '"hostname":"[^"]+"' || fail "system: no hostname: $SYS"
    echo "$SYS" | grep -Eq '"total_kb":[1-9][0-9]*' || fail "system: no memory total: $SYS"
    echo "$SYS" | grep -Eq '"cores":\[[0-9.]+' || fail "system: no cpu cores: $SYS"
    HIST="$(curl -s -H "Cookie: nodos_session=$TOKEN" "$URL/history")"
    echo "$HIST" | grep -Eq '"ts":\[[0-9]+' || fail "history empty after sampling: $HIST"

    curl -s -i -N --max-time 6 -H "Cookie: nodos_session=$TOKEN" "$URL/stream" > "$DIR/stream.out" || true
    EVENTS="$(grep -c '^event: snapshot' "$DIR/stream.out" || true)"
    if [ "$EVENTS" -lt 2 ]; then
        echo "--- raw stream response (first 40 lines, 200 cols):" >&2
        head -n 40 "$DIR/stream.out" | cut -c1-200 >&2
        echo "--- /system was ${#SYS} bytes" >&2
        fail "stream delivered $EVENTS snapshot events, wanted at least 2"
    fi
fi
[ "$(status "$URL/stream")" = "401" ] || fail "stream without cookie should be 401"

if [ -z "${SMOKE_SKIP_POSIX:-}" ]; then
    AUTH=(-H "Cookie: nodos_session=$TOKEN")
    [ "$(status "$URL/docker/containers")" = "401" ] || fail "docker list without cookie should be 401"
    LIST="$(curl -s "${AUTH[@]}" "$URL/docker/containers")"
    echo "$LIST" | grep -q '"name":"web"' || fail "docker list missing web: $LIST"
    echo "$LIST" | grep -q '"total":2' || fail "docker list total: $LIST"
    curl -s "${AUTH[@]}" "$URL/docker/containers/web/logs?tail=5" | grep -q 'listening on :8080' || fail "docker logs"

    [ "$(status -X POST -d '' "${AUTH[@]}" "$URL/docker/containers/web/restart")" = "403" ] || fail "docker restart without csrf"
    [ "$(status -X POST -d '' "${AUTH[@]}" -H "x-csrf-token: $CSRF" "$URL/docker/containers/web/restart")" = "200" ] || fail "docker restart"
    [ "$(status -X POST -d '' "${AUTH[@]}" -H "x-csrf-token: $CSRF" "$URL/docker/containers/web/kill")" = "404" ] || fail "docker kill must be 404"
    [ "$(status -X POST -d '' "${AUTH[@]}" -H "x-csrf-token: $CSRF" "$URL/docker/containers/nope/restart")" = "404" ] || fail "docker unknown container"
    [ "$(status -X POST -d '' "${AUTH[@]}" -H "x-csrf-token: $CSRF" "$URL/docker/containers/-rf/restart")" = "400" ] || fail "docker bad ref"

    if command -v systemctl >/dev/null 2>&1; then
        SVC="$(curl -s "${AUTH[@]}" "$URL/services")"
        echo "$SVC" | grep -q '"unit":"ssh"' || fail "services list missing ssh: $SVC"
    fi
    [ "$(status "$URL/services")" = "401" ] || fail "services without cookie should be 401"
    [ "$(status -X POST -d '' "${AUTH[@]}" -H "x-csrf-token: $CSRF" "$URL/services/sshd/restart")" = "404" ] || fail "service off the allowlist must be 404"
    [ "$(status -X POST -d '' "${AUTH[@]}" "$URL/services/ssh/restart")" = "403" ] || fail "service restart without csrf"

    [ "$(status "${AUTH[@]}" "$URL/alerts")" = "200" ] || fail "alerts route"
    AUDIT="$(curl -s "${AUTH[@]}" "$URL/audit?limit=20")"
    echo "$AUDIT" | grep -q '"action":"auth.login"' || fail "audit route missing login: $AUDIT"
    [ "$(status "$URL/audit")" = "401" ] || fail "audit without cookie should be 401"

    grep -q 'POST /containers/web/restart' "$DIR/docker-requests.log" || fail "restart never reached docker"
    if grep -Eq 'kill|DELETE|/rm|exec|-rf' "$DIR/docker-requests.log"; then fail "unexpected request reached docker: $(cat "$DIR/docker-requests.log")"; fi
    grep -q '"action":"docker.restart","target":"web","ok":true' "$DIR/data/audit.log" || fail "docker restart not audited"
fi

[ "$(status -X POST -d '' -H "Cookie: nodos_session=$TOKEN" "$URL/logout")" = "403" ] || fail "logout without csrf"
[ "$(status -X POST -d '' -H "Cookie: nodos_session=$TOKEN" -H "x-csrf-token: $CSRF" "$URL/logout")" = "200" ] || fail "logout"
[ "$(status -H "Cookie: nodos_session=$TOKEN" "$URL/me")" = "401" ] || fail "me after logout"

grep -q '"action":"auth.login","target":"","ok":true' "$DIR/data/audit.log" || fail "audit log missing successful login"
grep -q 'password' "$DIR/data/audit.log" && fail "audit log contains the word password"

if [ -n "${SMOKE_SKIP_POSIX:-}" ]; then
    echo "smoke test passed (shutdown check skipped)"
    exit 0
fi

python3 "$(dirname "$0")/flood_check.py" "$PORT" || fail "idle connection flood was not recovered from"
kill -0 "$SERVER_PID" || fail "server died during the connection flood"

kill -TERM "$SERVER_PID"
for _ in $(seq 1 50); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$SERVER_PID" 2>/dev/null; then fail "server still running 5s after SIGTERM"; fi
wait "$SERVER_PID" && CODE=0 || CODE=$?
SERVER_PID=""
[ "$CODE" = "0" ] || fail "server exited with $CODE after SIGTERM"
grep -q 'shutting down' "$DIR/server.log" || fail "no shutdown message in log"

echo "smoke test passed"
