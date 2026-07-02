#!/usr/bin/env bash
# Build the rk3588-codec-udev .deb from the canonical kernel-driver rule.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$DIR/../../kernel-drivers/scripts/99-rockchip-codec.rules" \
   "$DIR/root/usr/lib/udev/rules.d/99-rockchip-codec.rules"
chmod 0644 "$DIR/root/usr/lib/udev/rules.d/99-rockchip-codec.rules"
chmod 0755 "$DIR/root/DEBIAN/postinst"
OUT="$DIR/rk3588-codec-udev_1.0_all.deb"
dpkg-deb --build --root-owner-group "$DIR/root" "$OUT"
echo "built: $OUT"
