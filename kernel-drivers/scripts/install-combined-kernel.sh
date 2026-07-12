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
# Kernel package installation can replace the current package's files, and this
# board has no U-Boot kernel-selection menu. The script backs up armbianEnv.txt
# but requires an explicit acknowledgement that rescue media and known-good
# image/DTB debs are ready. Run as root:
#   sudo RECOVERY_READY=1 PHASH='P####-C####' bash install-combined-kernel.sh
# =============================================================================
set -uo pipefail
[ "${1:-}" != "-h" ] && [ "${1:-}" != "--help" ] || {
  sed -n '2,19p' "$0"
  exit 0
}
[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo RECOVERY_READY=1 PHASH='P####-C####' bash $0"; exit 1; }

# Where the build scripts write their debs: the external workspace's
# armbian-build/output/debs. All knobs env-overridable, e.g. sudo DEBS=/path bash $0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE="$(cd "$HERE/../../.." && pwd)"                       # ~/Code
WORKSPACE="${WORKSPACE:-$CODE/kernel/rock5b-kernel-build}"
DEBS="${DEBS:-${ARMBIAN_BUILD:-$WORKSPACE/armbian-build}/output/debs}"
ENV="${ENV:-/boot/armbianEnv.txt}"
HASH="${HASH:-}"                  # optional kernel version filter, e.g. 6.18.38
PHASH="${PHASH:-}"                # required patch+config hash pinning this exact build
                                  # (printed by build-combined-kernel.sh/build-armbian-deb.sh)
RECOVERY_READY="${RECOVERY_READY:-0}"

[ -d "$DEBS" ] || { echo "No deb dir: $DEBS -- run build-combined-kernel.sh first (or set DEBS=)"; exit 1; }

print_recent_images() {
  echo "  recent image debs:"
  find "$DEBS" -maxdepth 1 -type f -name 'linux-image-current-rockchip64_*.deb' -printf '      %f\n' |
    sort -V |
    tail -8
}

describe_filter() {
  printf 'PHASH=%s' "$PHASH"
  [ -n "$HASH" ] && printf ', HASH=%s' "$HASH"
}

find_deb() {
  local package="$1"
  local f base
  local matches=()

  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    [[ "$base" == *"$PHASH"* ]] || continue
    if [ -n "$HASH" ] && [[ "$base" != *"$HASH"* ]]; then
      continue
    fi
    matches+=("$f")
  done < <(find "$DEBS" -maxdepth 1 -type f -name "${package}_*.deb" -print0)

  [ "${#matches[@]}" -gt 0 ] || return 1
  printf '%s\n' "${matches[@]}" | sort -V | tail -1
}

if [ -z "$PHASH" ]; then
  echo "Set PHASH to the build hash printed by the build script, e.g.:"
  echo "  sudo RECOVERY_READY=1 PHASH='P60c0-Cb831' bash $0"
  print_recent_images
  exit 1
fi

echo "================= STEP 1: locate the just-built debs ================="
echo "  filter: $(describe_filter)"
IMG=$(find_deb linux-image-current-rockchip64 || true)
DTB=$(find_deb linux-dtb-current-rockchip64 || true)
HDR=$(find_deb linux-headers-current-rockchip64 || true)
for f in "$IMG" "$DTB" "$HDR"; do
  [ -f "$f" ] || { echo "  MISSING a deb matching $(describe_filter) -- aborting"; print_recent_images; exit 1; }
  echo "  $(basename "$f")"
done
echo

if [ "$RECOVERY_READY" != 1 ]; then
  echo "ABORT: kernel recovery has not been acknowledged."
  echo "  ROCK 5B Armbian has no kernel-selection boot menu, and dpkg may"
  echo "  replace the currently installed kernel package files."
  echo "  Before retrying:"
  echo "    sudo bash $HERE/kernel-revert.sh list"
  echo "    keep known-good image + DTB debs on rescue-accessible storage"
  echo "    verify an SD rescue boot can reach the internal root"
  echo "  Then rerun with RECOVERY_READY=1. See install.md section 3."
  exit 1
fi

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
echo "    sudo bash $HERE/validate-combined.sh"
echo
echo "ROLLBACK (if needed): there is no kernel-selection boot menu. From the"
echo "  prepared rescue boot, use $HERE/kernel-revert.sh --auto switch <version>"
echo "  or --auto reinstall <known-good-image.deb> <known-good-dtb.deb>."
echo "  Restore $ENV.bak-precombined-* as needed. See install.md section 3."
