#!/usr/bin/env bash
# End-to-end smoke test against the built binary. CI runs this on Linux; it is
# also how graceful shutdown gets tested, since that path is Linux only.
#
# Usage: scripts/smoke.sh [path-to-nodos]   (run `zig build` first)
set -euo pipefail

BIN="${1:-zig-out/bin/nodos}"
PORT="${SMOKE_PORT:-18099}"
DIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null || true
    rm -rf "$DIR"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; echo "--- server log:" >&2; cat "$DIR/server.log" >&2 || true; exit 1; }
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# cygpath only exists under Git Bash, where a native .exe can't see /tmp.
NATIVE_DIR="$(cygpath -m "$DIR" 2>/dev/null || echo "$DIR")"
cat > "$DIR/nodos.conf" <<EOF
port = $PORT
data_dir = $NATIVE_DIR/data
secure_cookies = false
log_level = debug
EOF

printf '%s\n' 'smoke test passphrase' | "$BIN" user add smoke --config "$DIR/nodos.conf" >/dev/null
# SMOKE_SKIP_POSIX=1 lets a developer run the HTTP half of this on Windows.
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

# Regression: a bodiless POST used to crash the whole process via a std assert.
[ "$(status -X POST -H 'Content-Length:' "$URL/login")" = "411" ] || fail "bodiless POST should be 411"
kill -0 "$SERVER_PID" || fail "server died after bodiless POST"

[ "$(status -d '{"username":"smoke","password":"wrong wrong wrong"}' "$URL/login")" = "401" ] || fail "bad login"

LOGIN="$(curl -s -i -d '{"username":"smoke","password":"smoke test passphrase"}' "$URL/login")"
echo "$LOGIN" | head -1 | grep -q '200' || fail "good login"
TOKEN="$(echo "$LOGIN" | grep -i '^set-cookie:' | sed -E 's/.*nodos_session=([^;]+).*/\1/')"
CSRF="$(echo "$LOGIN" | grep -o '"csrf":"[^"]*"' | cut -d'"' -f4)"
[ -n "$TOKEN" ] && [ -n "$CSRF" ] || fail "no token or csrf in login response"

[ "$(status -H "Cookie: nodos_session=$TOKEN" "$URL/me")" = "200" ] || fail "me with cookie"
[ "$(status "$URL/system")" = "401" ] || fail "system without cookie should be 401"
if [ -z "${SMOKE_SKIP_POSIX:-}" ]; then
    # Linux only: real /proc data. Default interval is 2 s, so by 5 s there
    # are at least two samples and one plotted history point.
    sleep 5
    SYS="$(curl -s -H "Cookie: nodos_session=$TOKEN" "$URL/system")"
    echo "$SYS" | grep -Eq '"hostname":"[^"]+"' || fail "system: no hostname: $SYS"
    echo "$SYS" | grep -Eq '"total_kb":[1-9][0-9]*' || fail "system: no memory total: $SYS"
    echo "$SYS" | grep -Eq '"cores":\[[0-9.]+' || fail "system: no cpu cores: $SYS"
    HIST="$(curl -s -H "Cookie: nodos_session=$TOKEN" "$URL/history")"
    echo "$HIST" | grep -Eq '"ts":\[[0-9]+' || fail "history empty after sampling: $HIST"

    # Live stream: ~6 s at a 2 s interval should deliver at least two events.
    # curl exits 28 on --max-time, which is the expected way this ends.
    STREAM="$(curl -s -N --max-time 6 -H "Cookie: nodos_session=$TOKEN" "$URL/stream" || true)"
    EVENTS="$(echo "$STREAM" | grep -c '^event: snapshot' || true)"
    [ "$EVENTS" -ge 2 ] || fail "stream delivered $EVENTS snapshot events, wanted at least 2"
fi
[ "$(status "$URL/stream")" = "401" ] || fail "stream without cookie should be 401"

[ "$(status -X POST -d '' -H "Cookie: nodos_session=$TOKEN" "$URL/logout")" = "403" ] || fail "logout without csrf"
[ "$(status -X POST -d '' -H "Cookie: nodos_session=$TOKEN" -H "x-csrf-token: $CSRF" "$URL/logout")" = "200" ] || fail "logout"
[ "$(status -H "Cookie: nodos_session=$TOKEN" "$URL/me")" = "401" ] || fail "me after logout"

grep -q '"action":"auth.login","target":"","ok":true' "$DIR/data/audit.log" || fail "audit log missing successful login"
grep -q 'password' "$DIR/data/audit.log" && fail "audit log contains the word password"

if [ -n "${SMOKE_SKIP_POSIX:-}" ]; then
    echo "smoke test passed (shutdown check skipped)"
    exit 0
fi

# Graceful shutdown: SIGTERM must end the process with exit 0, quickly.
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
