# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154

native() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
say() { echo "--- $*"; }

case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) echo "FAIL: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac

PORT="${UPDATE_E2E_PORT:-$((20000 + RANDOM % 20000))}"
MIRROR="$WORK/mirror"
mkdir -p "$MIRROR"

make_keys() {
    local keys other
    keys="$("$SIGN" keygen)"
    SECRET="$(printf '%s\n' "$keys" | sed -n 's/^secret=//p')"
    PUBLIC="$(printf '%s\n' "$keys" | sed -n 's/^public=//p')"
    other="$("$SIGN" keygen)"
    OTHER_SECRET="$(printf '%s\n' "$other" | sed -n 's/^secret=//p')"
}

sign_file() { NODOS_SIGNING_KEY="$1" "$SIGN" sign "$(native "$2")"; }

make_release() {
    local tag="$1" bin="$2" mode="${3:-good}" name="nodos-$1-$ARCH-linux"
    local dir="$MIRROR/download/$tag"
    rm -rf "$dir" "$WORK/pkg/$name"; mkdir -p "$dir" "$WORK/pkg/$name"
    # cat not cp, msys cp renames an exe to nodos.exe
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
            printf 'x' >> "$dir/$name.tar.gz" ;;
        sumsedited)
            sign_file "$SECRET" "$dir/SHA256SUMS" > "$dir/SHA256SUMS.sig"
            printf 'x' >> "$dir/$name.tar.gz"
            (cd "$dir" && sha256sum "./$name.tar.gz" > SHA256SUMS) ;;
        *) fail "make_release: unknown mode $mode" ;;
    esac
    cat > "$MIRROR/latest.json" <<EOF
{"tag_name":"$tag","draft":false,"prerelease":${PRERELEASE:-false},"published_at":"${PUBLISHED:-2026-01-01T00:00:00Z}","html_url":"https://example.test/$tag"}
EOF
}

start_mirror() {
    python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$(native "$MIRROR")" >/dev/null 2>&1 &
    MIRROR_PID=$!
    for _ in $(seq 1 100); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/latest.json" && break; sleep 0.1; done
    curl -sf -o /dev/null "http://127.0.0.1:$PORT/latest.json" || fail "the mirror server did not start on port $PORT"
}
