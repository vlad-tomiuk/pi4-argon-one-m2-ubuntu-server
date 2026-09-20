#!/usr/bin/env bash
# install-commands.sh — put bin/* into /usr/local/bin and the shared UI into /usr/local/lib.
#
# Run after every `git pull` of this repo:
#     sudo bash scripts/install-commands.sh
# or simply:  server-update --self

set -euo pipefail
[ "$EUID" -eq 0 ] || exec sudo "$0" "$@"

REPO=$(cd "$(dirname "$0")/.." && pwd)
LIB=/usr/local/lib/pi-server

install -d "$LIB"
install -m 644 "$REPO/bin/lib/ui.sh" "$LIB/ui.sh"

for cmd in server-status server-update disk-status password-status bookmarks-status argon-fan argon-check argon-fan-test; do
    [ -f "$REPO/bin/$cmd" ] || continue
    install -m 755 "$REPO/bin/$cmd" "/usr/local/bin/$cmd"
    echo "  /usr/local/bin/$cmd"
done

# systemd units for the fallback fan controller
if [ -d "$REPO/systemd" ]; then
    for unit in "$REPO"/systemd/*.service; do
        [ -f "$unit" ] || continue
        install -m 644 "$unit" "/etc/systemd/system/$(basename "$unit")"
    done
    systemctl daemon-reload
fi

echo "Команди встановлено."
