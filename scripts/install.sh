#!/usr/bin/env bash
set -euo pipefail

BIN="${1:-zig-out/bin/nodos}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: run as root (sudo)" >&2
    exit 1
fi
if [ ! -x "$BIN" ]; then
    echo "install.sh: no executable at $BIN (build with: zig build -Doptimize=ReleaseSafe -Dstrip=true)" >&2
    exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
    echo "install.sh: systemd not found; install the binary and run it your own way" >&2
    exit 1
fi

if ! id nodos >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /var/lib/nodos --no-create-home --shell /usr/sbin/nologin nodos
fi

install -d -o nodos -g nodos -m 0750 /var/lib/nodos
install -d -o root -g nodos -m 0750 /etc/nodos
install -d -o root -g root -m 0755 /var/lib/nodos-update
install -m 0755 "$BIN" /usr/local/bin/nodos

if [ ! -e /etc/nodos/nodos.conf ]; then
    install -m 0640 -o root -g nodos "$HERE/packaging/nodos.conf.example" /etc/nodos/nodos.conf
    echo "wrote /etc/nodos/nodos.conf"
else
    echo "kept existing /etc/nodos/nodos.conf"
fi

install -m 0644 "$HERE/packaging/nodos.service" /etc/systemd/system/nodos.service
install -m 0644 "$HERE/packaging/nodos-update.service" /etc/systemd/system/nodos-update.service
install -m 0644 "$HERE/packaging/nodos-update.timer" /etc/systemd/system/nodos-update.timer
systemctl daemon-reload

cat <<'EOF'

NodOS is installed but not running. Next:

  1. Create the first admin (password is read from stdin, not the command line):
       printf '%s\n' 'a long passphrase' | sudo -u nodos nodos user add YOURNAME --config /etc/nodos/nodos.conf

  2. Review /etc/nodos/nodos.conf, then start it:
       sudo systemctl enable --now nodos

  3. Put a TLS reverse proxy in front before using it beyond localhost.
     See docs/installation/README.md.

Later, to update:  sudo nodos update          (checks, verifies, installs, rolls back on failure)
To only look:      nodos update --check
EOF
