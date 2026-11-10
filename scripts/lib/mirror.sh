# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# Shared helpers for the update tests: a fake release mirror served over
# loopback http, signed with a throwaway key. Source this, don't run it.
#
# Needs these set by the caller before use:
#   WORK   scratch directory
#   SIGN   path to the release-sign tool
# Provides: native, fail, say, make_keys, make_release, start_mirror, PORT,
#           MIRROR, ARCH, SECRET, PUBLIC, OTHER_SECRET

# Native path for programs that are not MSYS aware (a no-op on Linux).
native() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "--- $*"; }

case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) echo "FAIL: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac

# A random port, so a leftover server from an earlier run can't answer for us.
PORT="${UPDATE_E2E_PORT:-$((20000 + RANDOM % 20000))}"
MIRROR="$WORK/mirror"
mkdir -p "$MIRROR"

# A trusted test key, and a second one that nothing trusts.
make_keys() {
    local keys other
    keys="$("$SIGN" keygen)"
    SECRET="$(printf '%s\n' "$keys" | sed -n 's/^secret=//p')"
    PUBLIC="$(printf '%s\n' "$keys" | sed -n 's/^public=//p')"
    other="$("$SIGN" keygen)"
    OTHER_SECRET="$(printf '%s\n' "$other" | sed -n 's/^secret=//p')"
}

sign_file() { NODOS_SIGNING_KEY="$1" "$SIGN" sign "$(native "$2")"; }

# make_release TAG BINARY [MODE]
#   MODE: good (default), wrongkey, unsigned, tampered, sumsedited
# Also reads PUBLISHED and PRERELEASE from the environment for latest.json.
make_release() {
    local tag="$1" bin="$2" mode="${3:-good}" name="nodos-$1-$ARCH-linux"
    local dir="$MIRROR/download/$tag"
    rm -rf "$dir" "$WORK/pkg/$name"; mkdir -p "$dir" "$WORK/pkg/$name"
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
        *) fail "make_release: unknown mode $mode" ;;
    esac
    cat > "$MIRROR/latest.json" <<EOF
{"tag_name":"$tag","draft":false,"prerelease":${PRERELEASE:-false},"published_at":"${PUBLISHED:-2026-01-01T00:00:00Z}","html_url":"https://example.test/$tag"}
EOF
}

# --directory (not a cd in a subshell) so $! is the python process itself and
# cleanup really stops it. Sets MIRROR_PID.
start_mirror() {
    python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$(native "$MIRROR")" >/dev/null 2>&1 &
    MIRROR_PID=$!
    for _ in $(seq 1 100); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/latest.json" && break; sleep 0.1; done
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/latest.json" || fail "the mirror server did not start on port $PORT"
}
