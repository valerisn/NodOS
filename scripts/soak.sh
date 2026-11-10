#!/usr/bin/env bash
# Runs the server for a while under steady traffic and checks that memory and
# open file descriptors stop growing. Linux only (reads /proc).
#   scripts/soak.sh [minutes] [binary]
set -euo pipefail

MINUTES="${1:-10}"
BIN="${2:-zig-out/bin/nodos}"
PORT="${SOAK_PORT:-18188}"
DIR="$(mktemp -d)"
SERVER_PID=""
FAKE_PID=""
LOAD_PID=""
cleanup() {
    [ -n "$LOAD_PID" ] && kill "$LOAD_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null || true
    [ -n "$FAKE_PID" ] && kill -9 "$FAKE_PID" 2>/dev/null || true
    rm -rf "$DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; tail -20 "$DIR/server.log" >&2 || true; exit 1; }

cat > "$DIR/nodos.conf" <<EOF
port = $PORT
data_dir = $DIR/data
secure_cookies = false
docker_socket = $DIR/docker.sock
services = ssh
update_check = false
sample_interval_ms = 1000
EOF

python3 "$(dirname "$0")/fake_docker.py" "$DIR/docker.sock" "$DIR/docker-requests.log" &
FAKE_PID=$!
for _ in $(seq 1 50); do [ -S "$DIR/docker.sock" ] && break; sleep 0.1; done

printf '%s\n' 'soak test passphrase' | "$BIN" user add soak --config "$DIR/nodos.conf" >/dev/null
"$BIN" serve --config "$DIR/nodos.conf" 2> "$DIR/server.log" &
SERVER_PID=$!
for _ in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$PORT/api/v1/health" >/dev/null && break
    sleep 0.1
done
URL="http://127.0.0.1:$PORT/api/v1"

login() {
    curl -s -i -H 'content-type: application/json' -d '{"username":"soak","password":"soak test passphrase"}' "$URL/login"
}
R="$(login)"
TOKEN="$(echo "$R" | grep -i '^set-cookie:' | sed -E 's/.*nodos_session=([^;]+).*/\1/')"
[ -n "$TOKEN" ] || fail "could not sign in"
COOKIE="Cookie: nodos_session=$TOKEN"

# steady traffic: reads, a live stream that comes and goes, and logins that fail
(
    while true; do
        for path in system history alerts docker/containers docker/images services storage-health audit; do
            curl -s -o /dev/null -H "$COOKIE" "$URL/$path" || true
        done
        curl -s -o /dev/null -N --max-time 2 -H "$COOKIE" "$URL/stream" || true
        curl -s -o /dev/null -H 'content-type: application/json' -d '{"username":"nobody","password":"wrong wrong wrong"}' "$URL/login" || true
        sleep 0.2
    done
) &
LOAD_PID=$!

rss_kb() { awk '/^VmRSS:/ {print $2}' "/proc/$SERVER_PID/status"; }
fds() { ls "/proc/$SERVER_PID/fd" | wc -l; }

WARMUP=$(( MINUTES * 60 / 5 ))
[ "$WARMUP" -ge 20 ] || WARMUP=20
END=$(( $(date +%s) + MINUTES * 60 ))
echo "soaking for $MINUTES minutes, warm-up $WARMUP seconds"

BASE_RSS=""
BASE_FDS=""
MAX_RSS=0
START=$(date +%s)
while [ "$(date +%s)" -lt "$END" ]; do
    kill -0 "$SERVER_PID" 2>/dev/null || fail "server died during the soak"
    NOW=$(date +%s)
    R=$(rss_kb)
    F=$(fds)
    [ "$R" -gt "$MAX_RSS" ] && MAX_RSS=$R
    if [ -z "$BASE_RSS" ] && [ $(( NOW - START )) -ge "$WARMUP" ]; then
        BASE_RSS=$R
        BASE_FDS=$F
        echo "baseline after warm-up: ${BASE_RSS} kB, ${BASE_FDS} fds"
    fi
    printf '%s rss=%s kB fds=%s\n' "$(date +%T)" "$R" "$F"
    sleep 30
done

[ -n "$BASE_RSS" ] || fail "run was too short to take a baseline"
FINAL_RSS=$(rss_kb)
FINAL_FDS=$(fds)
echo "final: ${FINAL_RSS} kB, ${FINAL_FDS} fds (peak ${MAX_RSS} kB)"

LIMIT=$(( BASE_RSS + BASE_RSS / 4 + 4096 ))
[ "$FINAL_RSS" -le "$LIMIT" ] || fail "memory grew from ${BASE_RSS} kB to ${FINAL_RSS} kB (limit ${LIMIT} kB)"
[ "$FINAL_FDS" -le $(( BASE_FDS + 20 )) ] || fail "open descriptors grew from ${BASE_FDS} to ${FINAL_FDS}"
grep -qi 'panic\|out of memory' "$DIR/server.log" && fail "server log has a panic"
echo "soak test passed"
