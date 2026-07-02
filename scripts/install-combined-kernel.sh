#!/usr/bin/env bash
# =============================================================================
# install-combined-kernel.sh
#
# Installs the combined RK3588 (Radxa Rock 5B) kernel that has all three vendor
# accelerators BUILT IN (=y):
#   * VEPU580 / rkvenc2  H.264/H.265 encoder
#   * rkvdec2            H.264/H.265/VP9 decoder
#   * RGA3/RGA2          2D accelerator (/dev/rga)
# ...and removes the now-obsolete 'rkvdec2' BOOT OVERLAY (the decoder is in the
# in-tree dtb now; the overlay would collide -- duplicate nodes + a second
# mpp-srv -- and re-introduce the alias bug that oopsed earlier).
#
# Non-destructive: backs up armbianEnv.txt; the old kernel stays installed and
# selectable. Run as root:  sudo bash install-combined-kernel.sh
# =============================================================================
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo bash $0"; exit 1; }

# Where build-combined-kernel.sh writes its debs: <repo>/armbian-build/output/debs.
# All four knobs are env-overridable, e.g.  sudo DEBS=/path/to/debs bash $0
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBS="${DEBS:-$REPO/armbian-build/output/debs}"
ENV="${ENV:-/boot/armbianEnv.txt}"
HASH="${HASH:-6.18.37}"            # kernel version of the just-built debs
PHASH="${PHASH:-Pb6ab-Cb831}"      # patch+config hash pinning this exact build
                                   # (printed by build-combined-kernel.sh -- update after each build)

[ -d "$DEBS" ] || { echo "No deb dir: $DEBS -- run build-combined-kernel.sh first (or set DEBS=)"; exit 1; }

echo "================= STEP 1: locate the just-built debs ================="
IMG=$(ls -t "$DEBS"/linux-image-current-rockchip64_*"$HASH"*"$PHASH"*.deb 2>/dev/null | head -1)
DTB=$(ls -t "$DEBS"/linux-dtb-current-rockchip64_*"$HASH"*"$PHASH"*.deb 2>/dev/null | head -1)
HDR=$(ls -t "$DEBS"/linux-headers-current-rockchip64_*"$HASH"*"$PHASH"*.deb 2>/dev/null | head -1)
for f in "$IMG" "$DTB" "$HDR"; do
  [ -f "$f" ] || { echo "  MISSING a $HASH/$PHASH deb -- aborting"; exit 1; }
  echo "  $(basename "$f")"
done
echo

echo "================= STEP 2: remove the rkvdec2 boot overlay ================="
if grep -qE '^user_overlays=' "$ENV"; then
  cp -v "$ENV" "$ENV.bak-precombined-$(date +%s)"
  # drop rkvdec2 from the overlay list, and remove an empty user_overlays= line
  sed -i -E 's/^(user_overlays=.*)\brkvdec2\b ?/\1/; /^user_overlays=[[:space:]]*$/d' "$ENV"
  echo "  user_overlays now: $(grep -E '^user_overlays=' "$ENV" || echo '(removed -- good)')"
else
  echo "  no user_overlays line -- nothing to remove"
fi
rm -fv /boot/overlay-user/rkvdec2.dtbo 2>/dev/null || true
echo

echo "================= STEP 3: install image + dtb + headers ================="
dpkg -i "$IMG" "$DTB" "$HDR" || { echo "  dpkg failed -- inspect above"; exit 1; }
echo

echo "================= STEP 4: verify install ================="
KV=$(dpkg-deb -f "$IMG" Package | sed 's/linux-image-//')   # e.g. current-rockchip64
NEWDTB=$(find /boot -path '*rockchip/rk3588-rock-5b.dtb' -newermt '-3 minutes' 2>/dev/null | head -1)
echo "  /boot/Image -> $(readlink -f /boot/Image 2>/dev/null || echo /boot/Image)"
if [ -n "$NEWDTB" ]; then
  echo "  installed dtb: $NEWDTB"
  echo "  vendor nodes in it: $(dtc -I dtb -O dts "$NEWDTB" 2>/dev/null | grep -cE 'rkv-encoder-v2-core|rkv-decoder-v2"|rga3_core0')"
fi
echo
echo "DONE.  Reboot into the combined kernel when ready:"
echo "    sudo reboot"
echo "After reboot, validate all three accelerators:"
echo "    sudo bash $REPO/scripts/validate-combined.sh"
echo
echo "ROLLBACK (if needed): pick the previous kernel in the boot menu, or restore"
echo "  $ENV.bak-precombined-* and re-run apt/dpkg for the old linux-image."
