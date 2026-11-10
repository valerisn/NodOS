#!/usr/bin/env bash
set -euo pipefail

NEW_DIR="$1"
CURRENT="$2"
# shellcheck disable=SC2034
SIGN="$3"
WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# shellcheck source=lib/mirror.sh
. "$(dirname "$0")/lib/mirror.sh"

NEW_BIN="$NEW_DIR/bin/nodos"
[ -e "$NEW_BIN" ] || NEW_BIN="$NEW_DIR/bin/nodos.exe"
[ -e "$NEW_BIN" ] || fail "no binary in $NEW_DIR/bin"

make_keys

INST="$WORK/inst"; mkdir -p "$INST"
cp "$CURRENT" "$INST/nodos"
chmod +x "$INST/nodos"
INSTALLED="$INST/nodos"
installed_version() { "$INSTALLED" version | sed 's/^nodos //'; }
BEFORE="$(installed_version)"

make_release "v0.0.0" "$NEW_BIN"
start_mirror
SERVER_PID="$MIRROR_PID"

CONF="$WORK/nodos.conf"
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

say "up to date"
"${UPDATE[@]}" --check > "$WORK/out.txt" 2>&1 || { [ $? -eq 10 ] && fail "reported an update when none exists"; }
grep -q "up to date" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "expected 'up to date'"; }

make_release "v9.9.9" "$NEW_BIN" good
say "check finds it"
set +e; "${UPDATE[@]}" --check > "$WORK/out.txt" 2>&1; CODE=$?; set -e
[ "$CODE" -eq 10 ] || { cat "$WORK/out.txt"; fail "--check should exit 10 when an update exists, got $CODE"; }
grep -q "9.9.9" "$WORK/out.txt" || fail "--check did not name the version"

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

LIAR="$WORK/liar"; mkdir -p "$LIAR"
if [ "$(uname -s)" = "Linux" ]; then
    printf '#!/bin/sh\necho "nodos 1.2.3"\n' > "$LIAR/nodos"; chmod +x "$LIAR/nodos"
    make_release "v9.9.9" "$LIAR/nodos" good
    expect_refused "binary that reports a different version" --pubkey "$PUBLIC" --yes
fi

say "good release installs"
make_release "v9.9.9" "$NEW_BIN" good
"${UPDATE[@]}" --pubkey "$PUBLIC" --yes > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "a good signed release was refused"; }
[ "$(installed_version)" = "9.9.9" ] || fail "installed version is $(installed_version), wanted 9.9.9"
[ -e "$INST/nodos.previous" ] || fail "no nodos.previous backup"
[ "$("$INST/nodos.previous" version | sed 's/^nodos //')" = "$BEFORE" ] || fail "backup is not the old version"
[ ! -e "$INST/nodos.new" ] || fail "left nodos.new behind"
echo "ok: installed 9.9.9, backup holds $BEFORE"

say "second run is a no-op"
RUN=("$INSTALLED" update --binary "$(native "$INSTALLED")" --mirror "http://127.0.0.1:$PORT" --config "$(native "$CONF")" --pubkey "$PUBLIC")
"${RUN[@]}" --yes > "$WORK/out.txt" 2>&1 || true
grep -q "Nothing to do" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "should say nothing to do"; }

say "rollback"
if [ "$(uname -s)" = "Linux" ]; then
    "$CURRENT" update --rollback --binary "$INSTALLED" --config "$CONF" > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "rollback failed"; }
else
    "$CURRENT" update --rollback --binary "$(native "$INSTALLED")" --config "$(native "$CONF")" > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "rollback failed"; }
fi
[ "$(installed_version)" = "$BEFORE" ] || fail "rollback left $(installed_version), wanted $BEFORE"
[ "$("$INST/nodos.previous" version | sed 's/^nodos //')" = "9.9.9" ] || fail "rollback should keep the replaced version as previous"
grep -q "bad=v9.9.9" "$WORK/data/update-state" || fail "rolled-back version was not remembered as bad"
echo "ok: rolled back to $BEFORE and remembered 9.9.9"

make_release "v9.9.9" "$NEW_BIN" good
expect_refused "version known to be bad" --pubkey "$PUBLIC" --yes
grep -q "failed" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "should explain it failed before"; }
"${UPDATE[@]}" --pubkey "$PUBLIC" --yes --force > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "--force should override"; }
[ "$(installed_version)" = "9.9.9" ] || fail "--force did not install"
echo "ok: --force overrides a remembered failure"

say "auto-run policy"
cp "$CURRENT" "$INST/nodos"; chmod +x "$INST/nodos"; rm -f "$INST/nodos.previous" "$WORK/data/update-state"
make_release "v9.9.9" "$NEW_BIN" good
"${UPDATE[@]}" --pubkey "$PUBLIC" --auto-run > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "auto-run should exit 0 when it chooses to wait"; }
grep -q "waits for a manual" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "a big jump must wait for a human"; }
[ "$(installed_version)" = "$BEFORE" ] || fail "auto-run installed a non-patch release"
echo "ok: auto-run will not take a big jump"

if [ -n "${PATCH_DIR:-}" ]; then
    PATCH_BIN="$PATCH_DIR/bin/nodos"
    [ -e "$PATCH_BIN" ] || PATCH_BIN="$PATCH_DIR/bin/nodos.exe"
    say "auto-run takes a mature patch release, waits for a fresh one, skips a bad one"
    cat "$NEW_BIN" > "$INST/nodos"; chmod +x "$INST/nodos"; rm -f "$INST/nodos.previous" "$WORK/data/update-state"
    [ "$(installed_version)" = "9.9.9" ] || fail "setup: expected 9.9.9 installed"

    PUBLISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" make_release "v9.9.10" "$PATCH_BIN" good
    "${UPDATE[@]}" --pubkey "$PUBLIC" --auto-run > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "auto-run should exit 0 when it waits"; }
    grep -q "waiting for it to prove itself" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "a fresh release must wait out the soak period"; }
    [ "$(installed_version)" = "9.9.9" ] || fail "auto-run installed a release inside its soak period"
    echo "ok: fresh release waits"

    printf 'bad=v9.9.10\n' > "$WORK/data/update-state"
    PUBLISHED="2026-01-01T00:00:00Z" make_release "v9.9.10" "$PATCH_BIN" good
    "${UPDATE[@]}" --pubkey "$PUBLIC" --auto-run > "$WORK/out.txt" 2>&1 || fail "auto-run should exit 0 when it skips"
    grep -q "failed here before" "$WORK/out.txt" || { cat "$WORK/out.txt"; fail "a known-bad version must be skipped"; }
    [ "$(installed_version)" = "9.9.9" ] || fail "auto-run installed a known-bad version"
    echo "ok: known-bad release is skipped"

    rm -f "$WORK/data/update-state"
    "${UPDATE[@]}" --pubkey "$PUBLIC" --auto-run > "$WORK/out.txt" 2>&1 || { cat "$WORK/out.txt"; fail "a mature patch release should install under auto-run"; }
    [ "$(installed_version)" = "9.9.10" ] || { cat "$WORK/out.txt"; fail "installed $(installed_version), wanted 9.9.10"; }
    echo "ok: mature patch release installed unattended"

    PUBLISHED="2026-01-01T00:00:00Z" PRERELEASE=true make_release "v9.9.11" "$PATCH_BIN" good
    "${UPDATE[@]}" --pubkey "$PUBLIC" --auto-run > "$WORK/out.txt" 2>&1 || true
    [ "$(installed_version)" = "9.9.10" ] || fail "auto-run took a prerelease"
    echo "ok: prerelease ignored"
fi

echo "update end-to-end: all checks passed"
