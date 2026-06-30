#!/usr/bin/env bash
# Build the rk3588-vcodec-dkms .deb: stage the vendor driver source from the
# forward-port kernel tree, drop in the DKMS config + out-of-tree Kbuilds,
# compile the device-tree overlay, and assemble a DKMS .deb.
#
# Dev-box path below — adjust KSRC for your layout (the driver source is the
# forward-port tree; equivalently you can extract it by applying patches/01 to a
# pristine v6.18 and pointing KSRC at drivers/video/rockchip).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NAME=rk3588-vcodec
VERSION=1.0
KSRC="${KSRC:-/home/yi/Code/linux-6.18-rkvenc/drivers/video/rockchip}"
OVERLAY=rk3588-rock5b-vcodec

OUT="$DIR/build"
ROOT="$OUT/${NAME}-dkms_${VERSION}_arm64"
SRC="$ROOT/usr/src/${NAME}-${VERSION}"
rm -rf "$OUT"; mkdir -p "$SRC/mpp" "$SRC/rga3" "$ROOT/boot/overlay-user" "$ROOT/DEBIAN"

echo "== stage driver source from $KSRC =="
[ -d "$KSRC/mpp" ] || { echo "ERROR: $KSRC/mpp not found — set KSRC"; exit 1; }
cp -r "$KSRC/mpp/."  "$SRC/mpp/"
cp -r "$KSRC/rga3/." "$SRC/rga3/"
# Keep ONLY source (.c/.h). This drops the in-tree Makefile/Kconfig (our Kbuilds
# replace them) AND any stale build artifacts (.o/.cmd/.a/.ko/Module.symvers/...)
# left in the kernel tree by an in-tree build — DKMS must start from clean source.
find "$SRC" -type f ! -name '*.c' ! -name '*.h' -delete
find "$SRC" -depth -type d -empty -delete
# the re-guard (patches/01) must be present so governor.h is never pulled OOT
if grep -q '^#ifdef CONFIG_PM_DEVFREQ$' "$SRC/mpp/mpp_rkvenc2.c"; then
  echo "ERROR: staged mpp_rkvenc2.c still has a bare CONFIG_PM_DEVFREQ guard —"
  echo "       KSRC tree is missing the devfreq re-guard (rock-5b-ysp commit 23cbe21)."
  exit 1
fi

echo "== install DKMS config + Kbuilds =="
cp "$DIR/dkms.conf"          "$SRC/dkms.conf"
cp "$DIR/kbuild/Kbuild"      "$SRC/Kbuild"
cp "$DIR/kbuild/mpp.Kbuild"  "$SRC/mpp/Kbuild"
cp "$DIR/kbuild/rga3.Kbuild" "$SRC/rga3/Kbuild"

echo "== compile the device-tree overlay (cpp -> dtc -@) =="
KROOT="${KROOT:-${KSRC%/drivers/video/rockchip}}"   # kernel tree root, for dt-bindings
if command -v dtc >/dev/null 2>&1 && [ -d "$KROOT/include/dt-bindings" ]; then
  cpp -nostdinc -I "$KROOT/include" -undef -x assembler-with-cpp "$DIR/overlay/${OVERLAY}.dts" \
    | dtc -@ -I dts -O dtb -o "$ROOT/boot/overlay-user/${OVERLAY}.dtbo" - 2>/dev/null
  echo "   -> /boot/overlay-user/${OVERLAY}.dtbo ($(du -h "$ROOT/boot/overlay-user/${OVERLAY}.dtbo" | cut -f1))"
else
  echo "   WARNING: dtc and/or $KROOT/include/dt-bindings missing; overlay not built."
  echo "            (need device-tree-compiler + the kernel dt-bindings headers; set KROOT)"
fi

echo "== assemble .deb =="
cp "$DIR/deb/DEBIAN/control" "$DIR/deb/DEBIAN/postinst" "$DIR/deb/DEBIAN/prerm" "$ROOT/DEBIAN/"
# record the installed size
chmod -R u+rwX,go+rX "$ROOT"
dpkg-deb --build --root-owner-group "$ROOT" "$OUT/${NAME}-dkms_${VERSION}_arm64.deb" >/dev/null
echo
echo "built: $OUT/${NAME}-dkms_${VERSION}_arm64.deb"
dpkg-deb --info "$OUT/${NAME}-dkms_${VERSION}_arm64.deb" | sed -n '1,3p;/Description/,$p' | sed 's/^/  /'
echo "  source files staged: mpp=$(ls "$SRC/mpp"/*.c | wc -l)c rga3=$(ls "$SRC/rga3"/*.c | wc -l)c"
