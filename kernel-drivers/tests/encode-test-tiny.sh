#!/usr/bin/env bash
# Encode smoke test for the forward-ported RK3588 rkvenc2 encoder.
# Tiny-first (256x256), then auto-scales to 720p once the IOMMU path is proven.
# Aborts only on a REAL IOMMU translation fault / oops / empty output — not on
# benign warnings. Prereq: combined kernel booted (see ../scripts/) or the DKMS
# module loaded, so /dev/mpp_service is up. Root required — the script writes
# dmesg markers to /dev/kmsg and scans dmesg for faults.
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
# Only for SUITE_DMESG_FATAL_RE. The private pattern this replaced was blind to
# KASAN and to both RGA IOMMU fault spellings, and this gate aborts the run.
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
: "${SUITE_DMESG_FATAL_RE:?suite-common.sh did not load; the kernel-log fatal scan would be silently blind}"

# MPP_BUILD = an MPP build/install tree with librockchip_mpp + mpi_enc_test
# (env-overridable). Default = the rockchip-conformance install prefix (lib/+bin/);
# a raw cmake build dir (mpp/+test/) is auto-detected too.
MPP_BUILD="${MPP_BUILD:-$REPO_ROOT/../rockchip-conformance/out/mpp}"
LIB=$MPP_BUILD/lib;             [ -d "$LIB" ] || LIB=$MPP_BUILD/mpp
ENC=$MPP_BUILD/bin/mpi_enc_test; [ -x "$ENC" ] || ENC=$MPP_BUILD/test/mpi_enc_test
OUT=/tmp/rkvenc-test

if [ "$(id -u)" -ne 0 ]; then echo "Run as root (sudo)."; exit 1; fi
[ -c /dev/mpp_service ] || { echo "/dev/mpp_service missing — boot the combined kernel first (see ../scripts/)."; exit 1; }
[ -x "$ENC" ] || { echo "missing $ENC"; exit 1; }
mkdir -p "$OUT"

dmesg_since() { dmesg | sed -n "/$1/,\$p"; }

# REAL faults/crashes only. Excludes the benign iommu_set_fault_handler warning.
real_faults() {
  dmesg_since "$1" \
    | grep -aiE "$SUITE_DMESG_FATAL_RE|iova=0x|translation fault|Internal error|segfault|soft lockup|hard LOCKUP|rcu.*self-detected|watchdog: BUG|reset.*(timeout|failed)" \
    | grep -viE 'iommu_set_fault_handler|mpp_iommu_dev_activate'
}
# Non-fatal warnings to surface but not abort on (incl. the iommu_set_fault_handler
# WARN we just fixed — if it shows here, the fix did not take).
soft_warns() { dmesg_since "$1" | grep -iE 'WARNING:|warn|deprecat'; }

run_one() {
  local label="$1" type="$2" ext="$3" W="$4" H="$5" N="$6"
  local mark
  local of="$OUT/${label}.${ext}"
  mark="ENCMARK-${label}-$(date -u +%H%M%S%N)"
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
    echo ">>> Inspect the fault above, then REBOOT to reset the hardware before retrying."; return 2
  fi
  if [ ! -s "$of" ]; then
    echo ">>> OUTPUT EMPTY/MISSING (exit $rc) — encode produced no bitstream. Aborting."; return 3
  fi
  # A nonzero encoder status is a failure even when bytes were written: `timeout
  # 60` killing the 720p pass (rc=124) or an abort after frame 0 both leave a
  # short-but-nonempty file. This was printed and not checked, so every such run
  # reported PASS.
  if [ "$rc" -ne 0 ]; then
    echo ">>> ENCODER EXITED $rc — output is $(stat -c%s "$of") bytes but the run failed. Aborting."; return 4
  fi
  local sz; sz=$(stat -c%s "$of")
  local nal; nal=$(od -An -tx1 -N4 "$of" | tr -s ' ' | sed 's/^ //;s/ $//')
  if [ "$nal" != "00 00 00 01" ]; then
    echo "--- output ${of}: ${sz} bytes (first4:${nal}) ---"
    echo ">>> NO NAL START CODE — not a usable ${ext} elementary stream. Aborting."; return 5
  fi
  echo "--- output ${of}: ${sz} bytes  (first4:${nal}) NAL-start OK ---"
  local w; w=$(soft_warns "$mark" | head -n 4)
  [ -n "$w" ] && { echo "--- non-fatal kernel warnings (noted, not blocking): ---"; echo "$w"; }
  echo ">>> ${label} PASS (${sz} bytes, exit ${rc})"
  return 0
}

# rk_vcodec is built into the combined kernel (=y), so lsmod only shows it on
# the DKMS delivery path.
echo "kernel: $(uname -r)   rk_vcodec: $(lsmod | grep -q '^rk_vcodec' && echo 'module (DKMS)' || echo 'built-in (combined kernel)')"
echo

# -t values are MppCodingType: 7 = MPP_VIDEO_CodingAVC,
# 16777220 (0x01000004) = MPP_VIDEO_CodingHEVC -- see README.md.
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
echo "Nothing to unload -- the driver is built into the combined kernel."
echo "Next: bash $(dirname "$0")/test-decode.sh, then sudo bash $(dirname "$0")/transcode-test.sh"
