#!/usr/bin/env bash
# End-to-end test of `nodos update` against a local fake release server, using
# a throwaway signing key. Nothing here touches the internet or any real key.
#
# What it proves: a good signed release installs; a tampered, wrongly signed,
# unsigned, mislabelled or key-less one is refused and changes nothing;
# rollback works; unattended updates obey their extra rules.
#
# Usage: scripts/update_e2e.sh NEW_BUILD_DIR CURRENT_BIN SIGN_TOOL
#   NEW_BUILD_DIR  a zig prefix built with -Dbuild-version=9.9.9 (contains bin/nodos)
#   CURRENT_BIN    the nodos binary that plays "the installed version"
#   SIGN_TOOL      the release-sign executable
# On Linux CI the service-restart and automatic-rollback part is covered by
# scripts/update_service_e2e.sh instead, because it needs systemd.
set -euo pipefail

NEW_DIR="$1"
CURRENT="$2"
SIGN="$3"
# A random port, so a leftover server from an earlier run can't answer for us.
PORT="${UPDATE_E2E_PORT:-$((20000 + RANDOM % 20000))}"

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Native path for programs that are not MSYS aware (a no-op on Linux).
native() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "--- $*"; }

NEW_BIN="$NEW_DIR/bin/nodos"
[ -e "$NEW_BIN" ] || NEW_BIN="$NEW_DIR/bin/nodos.exe"
[ -e "$NEW_BIN" ] || fail "no binary in $NEW_DIR/bin"

case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) fail "unsupported machine $(uname -m)" ;;
esac

# --- keys: a test key, and a second one that is NOT trusted
KEYS="$("$SIGN" keygen)"
SECRET="$(printf '%s\n' "$KEYS" | sed -n 's/^secret=//p')"
PUBLIC="$(printf '%s\n' "$KEYS" | sed -n 's/^public=//p')"
OTHER="$("$SIGN" keygen)"
OTHER_SECRET="$(printf '%s\n' "$OTHER" | sed -n 's/^secret=//p')"
sign_file() { NODOS_SIGNING_KEY="$1" "$SIGN" sign "$(native "$2")"; }

# --- the "installed" binary the updater will replace
INST="$WORK/inst"; mkdir -p "$INST"
cp "$CURRENT" "$INST/nodos"
chmod +x "$INST/nodos"
INSTALLED="$INST/nodos"
installed_version() { "$INSTALLED" version | sed 's/^nodos //'; }
BEFORE="$(installed_version)"

# --- release builder: make_release TAG BINARY [TAMPER]
MIRROR="$WORK/mirror"; mkdir -p "$MIRROR"
make_release() {
    local tag="$1" bin="$2" mode="${3:-good}" name="nodos-$1-$ARCH-linux"
    local dir="$MIRROR/download/$tag"; rm -rf "$dir"; mkdir -p "$dir" "$WORK/pkg/$name"
    # cat, not cp: under MSYS, cp quietly renames an .exe to "nodos.exe".
    cat "$bin" > "$WORK/pkg/$name/nodos"
    chmod +x "$WORK/pkg/$name/nodos"
    tar -C "$WORK/pkg" -czf "$dir/$name.tar.gz" "$name"
    (cd "$dir" && sha256sum "./$name.tar.gz" > SHA256SUMS)
    case "$mode" in
        good) sign_file "$SECRET" "$dir/SHA256SUMS" > "$dir/SHA256SUMS.sig" ;;
        wrongkey) sign_file "$OTHER_SECRET" "$dir/SHA256SUMS" > "$dir/SHA256SUMS.sig" ;;
        unsigned) : ;;
        tampered)
            sign_file "$SECRET" "$dir/SHA256SUMS" > "$dir/SHA256SUMS.sig"
            # change the tarball after it was signed for
            printf 'x' >> "$dir/$name.tar.gz" ;;
        sumsedited)
            sign_file "$SECRET" "$dir/SHA256SUMS" > "$dir/SHA256SUMS.sig"
            # attacker swaps the tarball AND rewrites the checksum list to match
            printf 'x' >> "$dir/$name.tar.gz"
            (cd "$dir" && sha256sum "./$name.tar.gz" > SHA256SUMS) ;;
    esac
    cat > "$MIRROR/latest.json" <<EOF
{"tag_name":"$tag","draft":false,"prerelease":${PRERELEASE:-false},"published_at":"${PUBLISHED:-2026-01-01T00:00:00Z}","html_url":"https://example.test/$tag"}
EOF
}

make_release "v0.0.0" "$NEW_BIN"
# --directory (not a cd in a subshell) so $! is the python process itself and
# cleanup really stops it. A leftover server would answer the next run's
# requests from a deleted directory.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$(native "$MIRROR")" >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 100); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/latest.json" && break; sleep 0.1; done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/latest.json" || fail "the mirror server did not start on port $PORT"

CONF="$WORK/nodos.conf"
# The server creates its data directory at first start; do the same here.
mkdir -p "$WORK/data"
printf 'data_dir = %s\n' "$(native "$WORK/data")" > "$CONF"
UPDATE=("$CURRENT" update --binary "$(native "$INSTALLED")" --mirror "http://127.0.0.1:$PORT" --config "$(native "$CONF")")

expect_refused() {
    local label="$1"; shift
    if "${UPDATE[@]}" "$@" > "$WORK/out.txt" 2>&1; then cat "$WORK/out.txt"; fail "$label: should have been refused"; fi
    [ "$(installed_version)" = "$BEFORE" ] || fail "$label: the installed binary changed ($BEFORE -> $(installed_version))"
    [ ! -e "$INST/nodos.new" ] || fail "$label: left a nodos.new behind"
    echo "ok: $label refused, installed binary untouched ($BEFORE)"
}

# 1. nothing newer yet (the mirror starts out serving v0.0.0)
say "up to date"
"${UPDATE[@]}" --check > "$WORK/out.txt" 2>&1 || { [ $? -eq 10 ] && fail "reported an update when none exists"; }
grep -q "up to date" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "expected 'up to date'"; }

# 2. a newer release exists: --check says so, with exit code 10
make_release "v9.9.9" "$NEW_BIN" good
say "check finds it"
set +e; "${UPDATE[@]}" --check > "$WORK/out.txt" 2>&1; CODE=$?; set -e
[ "$CODE" -eq 10 ] || { cat "$WORK/out.txt"; fail "--check should exit 10 when an update exists, got $CODE"; }
grep -q "9.9.9" "$WORK/out.txt" || fail "--check did not name the version"

# 3. attacks
say "attacks"
make_release "v9.9.9" "$NEW_BIN" tampered
expect_refused "tampered tarball" --pubkey "$PUBLIC" --yes
make_release "v9.9.9" "$NEW_BIN" sumsedited
expect_refused "tarball swapped and checksum list rewritten" --pubkey "$PUBLIC" --yes
make_release "v9.9.9" "$NEW_BIN" wrongkey
expect_refused "signed with an untrusted key" --pubkey "$PUBLIC" --yes
make_release "v9.9.9" "$NEW_BIN" unsigned
expect_refused "unsigned release" --pubkey "$PUBLIC" --yes
make_release "v9.9.9" "$NEW_BIN" good
expect_refused "no signing key available to this build" --yes
grep -q "no release signing key" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "the no-key refusal should explain itself"; }
expect_refused "garbage public key" --pubkey "not hex" --yes

# 4. a signed release whose binary lies about its version
LIAR="$WORK/liar"; mkdir -p "$LIAR"
if [ "$(uname -s)" = "Linux" ]; then
    printf '#!/bin/sh\necho "nodos 1.2.3"\n' > "$LIAR/nodos"; chmod +x "$LIAR/nodos"
    make_release "v9.9.9" "$LIAR/nodos" good
    expect_refused "binary that reports a different version" --pubkey "$PUBLIC" --yes
fi

# 5. the real thing
say "good release installs"
make_release "v9.9.9" "$NEW_BIN" good
"${UPDATE[@]}" --pubkey "$PUBLIC" --yes > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "a good signed release was refused"; }
[ "$(installed_version)" = "9.9.9" ] || fail "installed version is $(installed_version), wanted 9.9.9"
[ -e "$INST/nodos.previous" ] || fail "no nodos.previous backup"
[ "$("$INST/nodos.previous" version | sed 's/^nodos //')" = "$BEFORE" ] || fail "backup is not the old version"
[ ! -e "$INST/nodos.new" ] || fail "left nodos.new behind"
echo "ok: installed 9.9.9, backup holds $BEFORE"

# 6. already current
say "second run is a no-op"
RUN=("$INSTALLED" update --binary "$(native "$INSTALLED")" --mirror "http://127.0.0.1:$PORT" --config "$(native "$CONF")" --pubkey "$PUBLIC")
"${RUN[@]}" --yes > "$WORK/out.txt" 2>&1 || true
grep -q "Nothing to do" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "should say nothing to do"; }

# 7. rollback
say "rollback"
if [ "$(uname -s)" = "Linux" ]; then
    # on Linux the rollback runs as the (root) installed binary on its own file
    "$CURRENT" update --rollback --binary "$INSTALLED" --config "$CONF" > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "rollback failed"; }
else
    "$CURRENT" update --rollback --binary "$(native "$INSTALLED")" --config "$(native "$CONF")" > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "rollback failed"; }
fi
[ "$(installed_version)" = "$BEFORE" ] || fail "rollback left $(installed_version), wanted $BEFORE"
[ "$("$INST/nodos.previous" version | sed 's/^nodos //')" = "9.9.9" ] || fail "rollback should keep the replaced version as previous"
grep -q "bad=v9.9.9" "$WORK/data/update-state" || fail "rolled-back version was not remembered as bad"
echo "ok: rolled back to $BEFORE and remembered 9.9.9"

# 8. a version marked bad is not reinstalled without --force
make_release "v9.9.9" "$NEW_BIN" good
expect_refused "version known to be bad" --pubkey "$PUBLIC" --yes
grep -q "failed" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "should explain it failed before"; }
"${UPDATE[@]}" --pubkey "$PUBLIC" --yes --force > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "--force should override"; }
[ "$(installed_version)" = "9.9.9" ] || fail "--force did not install"
echo "ok: --force overrides a remembered failure"

# 9. unattended rules
say "auto-run policy"
cp "$CURRENT" "$INST/nodos"; chmod +x "$INST/nodos"; rm -f "$INST/nodos.previous" "$WORK/data/update-state"
make_release "v9.9.9" "$NEW_BIN" good
"${UPDATE[@]}" --pubkey "$PUBLIC" --auto-run > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "auto-run should exit 0 when it chooses to wait"; }
grep -q "waits for a manual" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "a big jump must wait for a human"; }
[ "$(installed_version)" = "$BEFORE" ] || fail "auto-run installed a non-patch release"
echo "ok: auto-run will not take a big jump"

# 10. the case unattended updates are FOR: a patch release that has been out a while
if [ -n "${PATCH_DIR:-}" ]; then
    PATCH_BIN="$PATCH_DIR/bin/nodos"
    [ -e "$PATCH_BIN" ] || PATCH_BIN="$PATCH_DIR/bin/nodos.exe"
    say "auto-run takes a mature patch release, waits for a fresh one, skips a bad one"
    cat "$NEW_BIN" > "$INST/nodos"; chmod +x "$INST/nodos"; rm -f "$INST/nodos.previous" "$WORK/data/update-state"
    [ "$(installed_version)" = "9.9.9" ] || fail "setup: expected 9.9.9 installed"

    # fresh: published just now, inside the soak window
    PUBLISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" make_release "v9.9.10" "$PATCH_BIN" good
    "${UPDATE[@]}" --pubkey "$PUBLIC" --auto-run > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "auto-run should exit 0 when it waits"; }
    grep -q "waiting for it to prove itself" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "a fresh release must wait out the soak period"; }
    [ "$(installed_version)" = "9.9.9" ] || fail "auto-run installed a release inside its soak period"
    echo "ok: fresh release waits"

    # known bad
    printf 'bad=v9.9.10\n' > "$WORK/data/update-state"
    PUBLISHED="2026-01-01T00:00:00Z" make_release "v9.9.10" "$PATCH_BIN" good
    "${UPDATE[@]}" --pubkey "$PUBLIC" --auto-run > "$WORK/out.txt" 2>&1 || fail "auto-run should exit 0 when it skips"
    grep -q "failed here before" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "a known-bad version must be skipped"; }
    [ "$(installed_version)" = "9.9.9" ] || fail "auto-run installed a known-bad version"
    echo "ok: known-bad release is skipped"

    # mature, patch, not bad: installs
    rm -f "$WORK/data/update-state"
    "${UPDATE[@]}" --pubkey "$PUBLIC" --auto-run > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "a mature patch release should install under auto-run"; }
    [ "$(installed_version)" = "9.9.10" ] || { cat "$WORK/out.txt"; fail "installed $(installed_version), wanted 9.9.10"; }
    echo "ok: mature patch release installed unattended"

    # a prerelease is never taken unattended
    PUBLISHED="2026-01-01T00:00:00Z" PRERELEASE=true make_release "v9.9.11" "$PATCH_BIN" good
    "${UPDATE[@]}" --pubkey "$PUBLIC" --auto-run > "$WORK/out.txt" 2>&1 || true
    [ "$(installed_version)" = "9.9.10" ] || fail "auto-run took a prerelease"
    echo "ok: prerelease ignored"
fi

echo "update end-to-end: all checks passed"
