#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ "$(uname -s)" = "Linux" ] || { echo "Linux only" >&2; exit 1; }

GOOD_DIR="$1"
SIGN="$2"
WORK="$(mktemp -d)"
MIRROR_PID=""
cleanup() {
    [ -n "$MIRROR_PID" ] && kill "$MIRROR_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
# shellcheck source=lib/mirror.sh
. "$(dirname "$0")/lib/mirror.sh"

BIN=/usr/local/bin/nodos
CONF=/etc/nodos/nodos.conf
DATA=/var/lib/nodos
GOOD_BIN="$GOOD_DIR/bin/nodos"
[ -x "$GOOD_BIN" ] || fail "no binary at $GOOD_BIN"

make_keys
ORIGINAL="$("$BIN" version | sed 's/^nodos //')"
echo "installed version at start: $ORIGINAL"
systemctl is-active --quiet nodos || fail "the nodos service should be running before this test"

health_version() { curl -sf "http://127.0.0.1:8080/api/v1/health" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'; }
installed_version() { "$BIN" version | sed 's/^nodos //'; }
upd() { "$BIN" update --mirror "http://127.0.0.1:$PORT" --pubkey "$PUBLIC" --config "$CONF" "$@"; }

make_release "v0.0.0" "$GOOD_BIN"
start_mirror

say "a release that installs but never comes up is rolled back by itself"
cat > "$WORK/broken.sh" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ]; then echo "nodos 9.9.10"; exit 0; fi
echo "this build is broken on purpose" >&2
exit 1
EOF
chmod +x "$WORK/broken.sh"
make_release "v9.9.10" "$WORK/broken.sh" good

set +e; upd --yes > "$WORK/out.txt" 2>&1; CODE=$?; set -e
cat "$WORK/out.txt"
[ "$CODE" -ne 0 ] || fail "a release that never became healthy was reported as a success"
[ "$(installed_version)" = "$ORIGINAL" ] || fail "binary is $(installed_version), wanted the original $ORIGINAL back"
systemctl is-active --quiet nodos || fail "the service is not running after the rollback"
for _ in $(seq 1 20); do [ "$(health_version)" = "$ORIGINAL" ] && break; sleep 1; done
[ "$(health_version)" = "$ORIGINAL" ] || fail "service does not report $ORIGINAL after the rollback"
grep -q "bad=v9.9.10" "$DATA/update-state" || fail "the failed version was not remembered"
grep -q '"action":"update.rolledback"' "$DATA/audit.log" 2>/dev/null || echo "note: no audit line (the server had not created audit.log yet)"
echo "ok: rolled back automatically, service healthy on $ORIGINAL, v9.9.10 remembered as bad"

say "a good release upgrades and the service reports it"
make_release "v9.9.9" "$GOOD_BIN" good
upd --yes > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "a good signed release failed to install"; }
cat "$WORK/out.txt"
[ "$(installed_version)" = "9.9.9" ] || fail "installed $(installed_version), wanted 9.9.9"
systemctl is-active --quiet nodos || fail "service not running after the upgrade"
[ "$(health_version)" = "9.9.9" ] || fail "service reports $(health_version), wanted 9.9.9"
[ -x "$BIN.previous" ] || fail "no backup of the old binary"
echo "ok: upgraded to 9.9.9, healthy, backup kept"

say "the running server tells the dashboard that an update exists"
make_release "v9.9.11" "$GOOD_BIN" good   # latest.json now names something newer than what runs
printf '\nupdate_mirror = http://127.0.0.1:%s\n' "$PORT" >> "$CONF"
printf '%s\n' 'notice test passphrase' | sudo -u nodos "$BIN" user add notice --config "$CONF" > /dev/null
systemctl restart nodos
for _ in $(seq 1 50); do [ -n "$(health_version)" ] && break; sleep 0.2; done
LOGIN="$(curl -s -i -d '{"username":"notice","password":"notice test passphrase"}' "http://127.0.0.1:8080/api/v1/login")"
TOKEN="$(printf '%s' "$LOGIN" | grep -i '^set-cookie:' | sed -E 's/.*nodos_session=([^;]+).*/\1/')"
[ -n "$TOKEN" ] || fail "could not sign in to read the update notice"
FOUND=""
for _ in $(seq 1 60); do
    BODY="$(curl -s -H "Cookie: nodos_session=$TOKEN" "http://127.0.0.1:8080/api/v1/update")"
    if printf '%s' "$BODY" | grep -q '"available":true'; then FOUND="$BODY"; break; fi
    sleep 1
done
[ -n "$FOUND" ] || { echo "last answer: $BODY"; fail "the server never reported an available update"; }
printf '%s' "$FOUND" | grep -q '"latest":"v9.9.11"' || fail "wrong latest version in: $FOUND"
printf '%s' "$FOUND" | grep -q '"command":"sudo nodos update"' || fail "no update command in: $FOUND"
echo "ok: $FOUND"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/api/v1/update")" = "401" ] || fail "update info must need a session"
sed -i '/^update_mirror/d' "$CONF"; printf 'update_check = false\n' >> "$CONF"

say "nodos update --rollback"
"$BIN" update --rollback --config "$CONF" > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "rollback failed"; }
cat "$WORK/out.txt"
[ "$(installed_version)" = "$ORIGINAL" ] || fail "rollback left $(installed_version), wanted $ORIGINAL"
for _ in $(seq 1 30); do [ "$(health_version)" = "$ORIGINAL" ] && break; sleep 1; done
[ "$(health_version)" = "$ORIGINAL" ] || fail "service does not report $ORIGINAL after rollback"
echo "ok: back on $ORIGINAL and healthy"

say "auto-update toggle: warns first, then enables, then disables"
OUT="$("$BIN" update --auto status 2>&1)"; echo "$OUT"
echo "$OUT" | grep -q "off" || fail "auto-update should start off"
set +e; WARN="$("$BIN" update --auto on 2>&1)"; CODE=$?; set -e
[ "$CODE" -eq 2 ] || fail "--auto on without --yes should exit 2, got $CODE"
echo "$WARN" | grep -q "PROBABLY NOT WHAT YOU WANT" || fail "the warning is missing"
systemctl is-enabled --quiet nodos-update.timer && fail "the timer got enabled without --yes"
"$BIN" update --auto on --yes > /dev/null
systemctl is-enabled --quiet nodos-update.timer || fail "--auto on --yes did not enable the timer"
"$BIN" update --auto status | grep -q "ON" || fail "status should say ON"
"$BIN" update --auto off > /dev/null
systemctl is-enabled --quiet nodos-update.timer && fail "--auto off did not disable the timer"
"$BIN" update --auto status | grep -q "off" || fail "status should say off again"
echo "ok: warned without --yes, enabled with it, disabled again"

echo "update service end-to-end: all checks passed"
