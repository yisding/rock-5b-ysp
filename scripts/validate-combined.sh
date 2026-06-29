#!/usr/bin/env bash
# =============================================================================
# validate-combined.sh   -- run AFTER rebooting into the combined kernel.
# Checks that all three vendor accelerators probed at boot (no overlay, no
# insmod), and settles the open rkvdec1 address question (fdc48000 vs fdc40000)
# now that the cores probe in the correct ccu->core0->core1 order.
# =============================================================================
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo bash $0"; exit 1; }

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }

echo "================= kernel ================="
echo "  uname -r: $(uname -r)   (expect 6.18.37-...)"
echo "  tainted:  $(cat /proc/sys/kernel/tainted)   (0 = clean boot)"
echo "  rkvdec2 boot overlay gone? $(grep -qE '^user_overlays=.*rkvdec2' /boot/armbianEnv.txt && echo 'NO -- still listed!' || echo 'yes ✓')"
echo

echo "================= 1. MPP service (/dev/mpp_service) ================="
[ -c /dev/mpp_service ] && ok "/dev/mpp_service present" || no "/dev/mpp_service ABSENT"
echo "  cores under /proc/mpp_service:"
for c in rkvenc-core0 rkvenc-core1 rkvdec-core0 rkvdec-core1; do
  [ -d "/proc/mpp_service/$c" ] && ok "$c" || no "$c  (absent)"
done
echo

echo "================= 2. RGA (/dev/rga) ================="
[ -c /dev/rga ] && ok "/dev/rga present" || no "/dev/rga ABSENT"
[ -e /sys/kernel/debug/rkrga/load ] && cat /sys/kernel/debug/rkrga/load 2>/dev/null | sed 's/^/    /' | head -5
echo

echo "================= 3. boot-time probe dmesg (all three) ================="
echo "--- encoder ---";  dmesg | grep -iE 'rkvenc' | grep -iE 'probe|core|ccu|attach|fail' | tail -6 | sed 's/^/    /'
echo "--- decoder (does core1 @ fdc48000 fully probe? = address answer) ---"
dmesg | grep -iE 'rkvdec' | grep -iE 'probe|core|ccu|attach|hw_version|EBUSY|ioremap|fail|defer' | tail -10 | sed 's/^/    /'
echo "--- rga ---";      dmesg | grep -iE 'rga' | grep -iE 'probe|version|fail|load' | tail -6 | sed 's/^/    /'
echo "--- any iommu fault / oops / -EBUSY anywhere in the vcodec drivers? ---"
dmesg | grep -iE 'mpp_|rkvenc|rkvdec|rga' | grep -iE 'Unable to handle|BUG|Oops|fault|EBUSY|-12|error -' | tail -8 | sed 's/^/    /' || echo "    (none)"
echo

echo "================= summary ================="
ND=$(ls -d /proc/mpp_service/rkvdec-core* 2>/dev/null | wc -l)
NE=$(ls -d /proc/mpp_service/rkvenc-core* 2>/dev/null | wc -l)
echo "  encoder cores: $NE   decoder cores: $ND   /dev/rga: $([ -c /dev/rga ] && echo yes || echo no)"
echo
echo "If all present, run the end-to-end userspace tests:"
echo "  encode:  sudo bash /home/yi/Code/rock5b-kernel-debug/rkvenc-forward-port/test-bundle/encode-test-tiny.sh"
echo "  (decode + RGA + ffmpeg-rockchip transcode tests next)"
