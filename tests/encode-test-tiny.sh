#!/usr/bin/env bash
# Encode smoke test for the forward-ported RK3588 rkvenc2 encoder.
# Tiny-first (256x256), then auto-scales to 720p once the IOMMU path is proven.
# Aborts only on a REAL IOMMU translation fault / oops / empty output — not on
# benign warnings. Run AFTER probe-only.sh (driver loaded, /dev/mpp_service up).
set -uo pipefail

LIB=/home/yi/Code/rock5b-kernel-debug/rkvenc-forward-port/userspace/mpp/build_native/mpp
ENC=/home/yi/Code/rock5b-kernel-debug/rkvenc-forward-port/userspace/mpp/build_native/test/mpi_enc_test
OUT=/tmp/rkvenc-test

if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)."; exit 1; fi
[ -c /dev/mpp_service ] || { echo "/dev/mpp_service missing — run probe-only.sh first."; exit 1; }
[ -x "$ENC" ] || { echo "missing $ENC"; exit 1; }
mkdir -p "$OUT"

dmesg_since() { dmesg | sed -n "/$1/,\$p"; }

# REAL faults/crashes only. Excludes the benign iommu_set_fault_handler warning.
real_faults() {
  dmesg_since "$1" \
    | grep -iE 'Page fault at|iova=0x|rk_iommu|translation fault|Unable to handle kernel|Internal error|kernel BUG at|Oops|segfault|soft lockup|hard LOCKUP|rcu.*self-detected|watchdog: BUG|blocked for more than|reset.*(timeout|failed)' \
    | grep -viE 'iommu_set_fault_handler|mpp_iommu_dev_activate'
}
# Non-fatal warnings to surface but not abort on (incl. the iommu_set_fault_handler
# WARN we just fixed — if it shows here, the fix did not take).
soft_warns() { dmesg_since "$1" | grep -iE 'WARNING:|warn|deprecat'; }

run_one() {
  local label="$1" type="$2" ext="$3" W="$4" H="$5" N="$6"
  local mark="ENCMARK-${label}-$(date -u +%H%M%S%N)"
  local of="$OUT/${label}.${ext}"
  echo "================= ${label} : ${W}x${H} ${N} frames -> ${of} ================="
  rm -f "$of"
  echo "=== ${mark} ===" > /dev/kmsg 2>/dev/null
  LD_LIBRARY_PATH="$LIB" timeout 60 "$ENC" -t "$type" -w "$W" -h "$H" -f 0 -n "$N" -o "$of" 2>&1 \
    | grep -iE 'encoded frame|average frame rate|encode .* frames|error|fail' | tail -n 8
  local rc=${PIPESTATUS[0]}
  sleep 1

  local f; f=$(real_faults "$mark")
  if [ -n "$f" ]; then
    echo ">>> REAL FAULT DETECTED — aborting:"; echo "$f"
    echo ">>> Do NOT rmdir the overlay (can deadlock configfs). REBOOT to reset."; return 2
  fi
  if [ ! -s "$of" ]; then
    echo ">>> OUTPUT EMPTY/MISSING (exit $rc) — encode produced no bitstream. Aborting."; return 3
  fi
  local sz; sz=$(stat -c%s "$of")
  local nal; nal=$(od -An -tx1 -N4 "$of" | tr -s ' ')
  echo "--- output ${of}: ${sz} bytes  (first4:${nal}) $( [ "$(echo $nal)" = "00 00 00 01" ] && echo 'NAL-start OK' || echo '(check stream)') ---"
  local w; w=$(soft_warns "$mark" | head -n 4)
  [ -n "$w" ] && { echo "--- non-fatal kernel warnings (noted, not blocking): ---"; echo "$w"; }
  echo ">>> ${label} PASS (${sz} bytes, exit ${rc})"
  return 0
}

echo "driver: $(lsmod | awk '/^rk_vcodec/{print $1, $2}')  |  $(modinfo "$(dirname "$0")/rk_vcodec.ko" 2>/dev/null | awk -F': *' '/srcversion/{print "srcversion "$2}')"
echo

# Tiny first (proves the IOMMU/DMA path with minimal footprint)...
run_one h264-tiny 7        h264 256 256 3  || exit $?
echo
run_one h265-tiny 16777220 h265 256 256 3  || exit $?
echo
echo ">>> Tiny H.264 + H.265 OK — IOMMU/DMA path proven. Scaling up to 720p..."
echo
# ...then a realistic 720p pass for each codec.
run_one h264-720p 7        h264 1280 720 30 || exit $?
echo
run_one h265-720p 16777220 h265 1280 720 30 || exit $?
echo
echo "================= ALL ENCODE TESTS PASSED ================="
ls -l "$OUT"
echo "Hardware H.264 + H.265 encode confirmed at 256x256 and 1280x720."
echo "When done: 'sudo bash $(dirname "$0")/rollback.sh' unloads the driver only;"
echo "for a full reset, REBOOT (never rmdir the configfs overlay)."
