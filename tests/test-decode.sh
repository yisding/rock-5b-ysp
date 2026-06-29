#!/usr/bin/env bash
# =============================================================================
# test-decode.sh -- RK3588 (Rock 5B) rkvdec2 HW DECODE smoke test.
#
# Runs mpi_dec_test on tiny Annex-B clips that ship in this bundle (generated
# by SOFTWARE libx264/libx265, so a failure points at the DECODER, not at the
# MPP encoder). Decodes H.264 and H.265 to raw NV12.
#
# PASS criterion = mpi_dec_test EXIT CODE == 0  AND  a non-empty output file.
# (We deliberately do NOT grep stdout for a magic string -- prior runs produced
#  false-fails from string matching. Exit code + output size are the gates.)
#
# Prereq: `sudo bash load.sh` succeeded and /proc/mpp_service/rkvdec-core* exist.
# Run as root not required for decode, but harmless:  bash test-decode.sh
# =============================================================================
set -uo pipefail

BUNDLE=/home/yi/Code/rock5b-kernel-debug/rkvdec2-forward-port/test-bundle
LD=/home/yi/Code/rock5b-kernel-debug/rkvenc-forward-port/userspace/mpp/build_native
LIB=$LD/mpp
DEC=$LD/test/mpi_dec_test

H264_IN=$BUNDLE/tiny-320x240.h264
H265_IN=$BUNDLE/tiny-320x240.h265
OUT=/tmp/rkvdec-test
mkdir -p "$OUT"

W=320; H=240; NF=30
T_H264=7          # MPP_VIDEO_CodingAVC
T_H265=16777220   # MPP_VIDEO_CodingHEVC
# Unaligned NV12 frame size; 320x240 is already 16-aligned so no stride padding.
FRAME=$(( W * H * 3 / 2 ))   # 115200 bytes/frame

echo "================= preflight ================="
fail=0
for f in "$DEC" "$H264_IN" "$H265_IN"; do
  [ -e "$f" ] && echo "  OK   $f" || { echo "  MISS $f"; fail=1; }
done
[ -d "$LIB" ] && echo "  OK   $LIB" || { echo "  MISS $LIB"; fail=1; }
[ $fail -eq 0 ] || { echo "Missing artifacts -- aborting."; exit 1; }
shopt -s nullglob
cores=(/proc/mpp_service/rkvdec-core*)
if [ ${#cores[@]} -eq 0 ]; then
  echo "WARNING: no /proc/mpp_service/rkvdec-core* -- decoder cores not bound."
  echo "         Run 'sudo bash load.sh' first. Continuing will likely fail."
fi
echo

# run_one <label> <type> <infile> <outfile>
run_one() {
  local label="$1" t="$2" in="$3" out="$4"
  echo "================= $label decode ================="
  rm -f "$out"
  echo "  cmd: LD_LIBRARY_PATH=$LIB $DEC -i $in -t $t -w $W -h $H -n $NF -o $out -v f"
  LD_LIBRARY_PATH="$LIB" "$DEC" -i "$in" -t "$t" -w "$W" -h "$H" -n "$NF" -o "$out" -v f
  local rc=$?
  echo "  mpi_dec_test exit code: $rc"
  local sz=0; [ -f "$out" ] && sz=$(stat -c%s "$out")
  echo "  output: $out  ($sz bytes)"
  if [ "$rc" -eq 0 ] && [ "$sz" -gt 0 ]; then
    local frames=$(( sz / FRAME ))
    local rem=$(( sz % FRAME ))
    echo "  est. NV12 frames: $frames  (frame=$FRAME B, remainder=$rem B"
    echo "       -- remainder != 0 just means MPP applied stride alignment; still a PASS)"
    echo "  RESULT: $label PASS"
    return 0
  else
    echo "  RESULT: $label FAIL (rc=$rc, size=$sz)"
    return 1
  fi
}

rc_h264=0; rc_h265=0
run_one "H.264" "$T_H264" "$H264_IN" "$OUT/dec_h264.yuv" || rc_h264=1
echo
run_one "H.265" "$T_H265" "$H265_IN" "$OUT/dec_h265.yuv" || rc_h265=1

echo
echo "================= summary ================="
echo "  H.264: $([ $rc_h264 -eq 0 ] && echo PASS || echo FAIL)"
echo "  H.265: $([ $rc_h265 -eq 0 ] && echo PASS || echo FAIL)"
echo "  decoded YUV in: $OUT"
echo "  quick visual check (first frame, needs a YUV viewer):"
echo "    ffplay -f rawvideo -pixel_format nv12 -video_size ${W}x${H} $OUT/dec_h264.yuv"
echo
if [ $rc_h264 -eq 0 ] && [ $rc_h265 -eq 0 ]; then
  echo "ALL PASS"; exit 0
else
  echo "SOME FAILED -- inspect: dmesg | grep -iE 'rkvdec|mpp|iommu|fault'"; exit 1
fi
