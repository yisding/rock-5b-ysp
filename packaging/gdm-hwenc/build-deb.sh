#!/usr/bin/env bash
# Build the gnome-remote-desktop-gdm-hwenc .deb (opt-in greeter codec access).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod 0644 "$DIR/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules"
chmod 0755 "$DIR/root/DEBIAN/postinst"
OUT="$DIR/gnome-remote-desktop-gdm-hwenc_1.0_all.deb"
dpkg-deb --build --root-owner-group "$DIR/root" "$OUT"
echo "built: $OUT"
