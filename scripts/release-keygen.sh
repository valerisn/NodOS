#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
PUBFILE="src/update/signing.pub"
BACKUP="${NODOS_KEY_BACKUP:-$HOME/.nodos/release-signing-key.txt}"
REPO="${NODOS_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

if [ -s "$PUBFILE" ] && [ "${1:-}" != "--rotate" ]; then
    echo "release-keygen: $PUBFILE already has a key. Use --rotate only if you mean it." >&2
    exit 1
fi
if [ -e "$BACKUP" ] && [ "${1:-}" != "--rotate" ]; then
    echo "release-keygen: $BACKUP already exists, not overwriting it." >&2
    exit 1
fi

zig build sign-tool --prefix .zig-cache/sign-tool
TOOL=.zig-cache/sign-tool/bin/release-sign
[ -x "$TOOL" ] || TOOL=.zig-cache/sign-tool/bin/release-sign.exe

KEYS="$("$TOOL" keygen)"
SECRET="$(printf '%s\n' "$KEYS" | sed -n 's/^secret=//p')"
PUBLIC="$(printf '%s\n' "$KEYS" | sed -n 's/^public=//p')"
[ "${#SECRET}" -eq 64 ] && [ "${#PUBLIC}" -eq 64 ] || { echo "release-keygen: unexpected keygen output" >&2; exit 1; }

mkdir -p "$(dirname "$BACKUP")"
umask 077
{
    echo "NodOS release signing key (Ed25519 seed, hex). Keep private and back it up."
    echo "GitHub cannot show the secret again after it is stored."
    echo "secret=$SECRET"
    echo "public=$PUBLIC"
} > "$BACKUP"
chmod 600 "$BACKUP" 2>/dev/null || true

printf '%s' "$SECRET" | gh secret set NODOS_SIGNING_KEY --repo "$REPO"
printf '%s\n' "$PUBLIC" > "$PUBFILE"

echo
echo "Done."
echo "  secret stored in GitHub as NODOS_SIGNING_KEY ($REPO)"
echo "  backup (keep it safe, e.g. in a password manager): $BACKUP"
echo "  public key written to $PUBFILE:"
echo "    $PUBLIC"
echo
echo "Now commit and push $PUBFILE so builds trust releases signed with this key."
