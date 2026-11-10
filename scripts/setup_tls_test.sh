#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$W/bin" "$W/etc"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/caddy"
chmod +x "$W/bin/caddy"
printf 'port = 8080\ntrusted_proxy = 10.0.0.1\nsecure_cookies = false\n' > "$W/nodos.conf"

export PATH="$W/bin:$PATH" NODOS_CONF="$W/nodos.conf" CADDY_SNIPPET="$W/etc/nodos.caddy"
bash "$HERE/setup-tls.sh" nodos.home.lan --port 9000 > "$W/out.txt"

grep -q '^nodos.home.lan {' "$CADDY_SNIPPET" || fail "site block missing"
grep -q 'reverse_proxy 127.0.0.1:9000' "$CADDY_SNIPPET" || fail "wrong upstream"
grep -q '^trusted_proxy = 127.0.0.1$' "$NODOS_CONF" || fail "trusted_proxy not rewritten"
grep -q '^secure_cookies = true$' "$NODOS_CONF" || fail "secure_cookies not set"
[ "$(grep -c '^trusted_proxy' "$NODOS_CONF")" = "1" ] || fail "trusted_proxy duplicated"

bash "$HERE/setup-tls.sh" nodos.home.lan --port 9000 > /dev/null
[ "$(grep -c '^secure_cookies' "$NODOS_CONF")" = "1" ] || fail "second run duplicated a key"

for bad in 'a b' 'x;rm' '-x' '.a' 'a.' ''; do
    if bash "$HERE/setup-tls.sh" "$bad" --dry-run >/dev/null 2>&1; then fail "accepted bad name '$bad'"; fi
done

if PATH="/usr/bin:/bin" bash -c "command -v caddy" >/dev/null 2>&1; then
    echo "note: real caddy present, skipping missing-caddy check"
elif PATH="/usr/bin:/bin" bash "$HERE/setup-tls.sh" x.lan >/dev/null 2>&1; then
    fail "ran without caddy"
fi
echo "setup-tls test passed"
