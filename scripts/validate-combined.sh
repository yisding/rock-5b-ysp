#!/usr/bin/env bash
# =============================================================================
# validate-combined.sh   -- run AFTER rebooting into the combined kernel.
# Checks that all three vendor accelerators probed at boot (no overlay, no
# insmod). rkvdec1 core 1 binds at its resolved address fdc40000 (TRM-canonical,
# confirmed on hardware) once the cores probe in ccu->core0->core1 order.
# =============================================================================
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo bash $0"; exit 1; }

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }

echo "================= kernel ================="
echo "  uname -r: $(uname -r)   (advisory: this port was validated on 6.18.37;"
echo "            a different version just means you rebuilt/resynced -- see ../docs/12-resyncing.md)"
echo "  tainted:  $(cat /proc/sys/kernel/tainted)   (0 = clean boot)"
echo "  rkvdec2 boot overlay gone? $(grep -qE '^user_overlays=.*rkvdec2' /boot/armbianEnv.txt && echo 'NO -- still listed!' || echo 'yes ✓')"
echo

echo "================= 1. MPP service (/dev/mpp_service) ================="
[ -c /dev/mpp_service ] && ok "/dev/mpp_service present" || no "/dev/mpp_service ABSENT"
echo "  cores under /proc/mpp_service:"
for c in rkvenc-core0 rkvenc-core1; do
  [ -d "/proc/mpp_service/$c" ] && ok "$c (encoder)" || no "$c  (absent)"
done
# Decoder cores keep the mainline DT node name -- patch 02 converts Armbian's
# "video-codec@..." nodes IN PLACE (probe dispatches by compatible, not name),
# so they show up as video-codec0/1 (verified 2026-07-01, 6.18.37 #7). Earlier
# standalone-node/overlay revisions named them rkvdec-core0/1; accept both.
shopt -s nullglob
dec=(/proc/mpp_service/video-codec* /proc/mpp_service/rkvdec-core*)
shopt -u nullglob
if [ ${#dec[@]} -ge 2 ]; then
  for d in "${dec[@]}"; do ok "$(basename "$d") (decoder)"; done
else
  no "decoder cores: expected 2 (video-codec0/1 or rkvdec-core0/1), found ${#dec[@]}"
fi
echo

echo "================= 2. RGA (/dev/rga) ================="
[ -c /dev/rga ] && ok "/dev/rga present" || no "/dev/rga ABSENT"
[ -e /sys/kernel/debug/rkrga/load ] && cat /sys/kernel/debug/rkrga/load 2>/dev/null | sed 's/^/    /' | head -5
echo

echo "================= 3. boot-time probe dmesg (all three) ================="
echo "--- encoder ---";  dmesg | grep -iE 'rkvenc' | grep -iE 'probe|core|ccu|attach|fail' | tail -6 | sed 's/^/    /'
echo "--- decoder (core0 + core1 @ fdc40000 both probe) ---"
dmesg | grep -iE 'rkvdec' | grep -iE 'probe|core|ccu|attach|hw_version|EBUSY|ioremap|fail|defer' | tail -10 | sed 's/^/    /'
echo "--- rga ---";      dmesg | grep -iE 'rga' | grep -iE 'probe|version|fail|load' | tail -6 | sed 's/^/    /'
echo "--- any iommu fault / oops / -EBUSY anywhere in the vcodec drivers? ---"
dmesg | grep -iE 'mpp_|rkvenc|rkvdec|rga' | grep -iE 'Unable to handle|BUG|Oops|fault|EBUSY|-12|error -' | tail -8 | sed 's/^/    /' || echo "    (none)"
echo

echo "================= summary ================="
ND=$(ls -d /proc/mpp_service/video-codec* /proc/mpp_service/rkvdec-core* 2>/dev/null | wc -l)
NE=$(ls -d /proc/mpp_service/rkvenc-core* 2>/dev/null | wc -l)
echo "  encoder cores: $NE   decoder cores: $ND   /dev/rga: $([ -c /dev/rga ] && echo yes || echo no)"
echo
TESTS="$(cd "$(dirname "$0")/../tests" 2>/dev/null && pwd || echo '../tests')"
echo "If all present, run the end-to-end userspace tests (see $TESTS/README.md):"
echo "  decode:    bash $TESTS/test-decode.sh          (device access is enough)"
echo "  encode:    sudo bash $TESTS/encode-test-tiny.sh"
echo "  transcode: sudo bash $TESTS/transcode-test.sh  (needs ffmpeg-rockchip -- ../ffmpeg/)"
