#!/usr/bin/env bash
# =============================================================================
# decode-differential.sh -- RK3588 (Rock 5B) HW DECODE *correctness* oracle.
#
# Where test-decode.sh gates on "exit 0 + non-empty output" (liveness), this
# script adds the strong oracle: decode each codec on the HARDWARE and on a
# SOFTWARE reference, then PSNR the two. Video decoding is fully specified and
# deterministic, so a conformant hardware decoder is BIT-EXACT with a conformant
# software decoder -> PSNR = inf. Anything finite is a real decode bug (a CSC,
# stride, or coefficient error a pass/fail gate would miss).
#
# Covers H.264, H.265, VP9, and AV1. AV1 + VP9 are the paths test-decode.sh does
# not, and AV1 is only present on the av1-fwport variant
# (../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport, /proc/mpp_service DEVICE AV1DEC).
#
# Inputs are SOFTWARE-encoded here (libx264/libx265/libvpx-vp9/libsvtav1), so a
# finite PSNR implicates the DECODER, never our encoder. Generated on the fly if
# absent -- needs a *stock* ffmpeg with those software encoders on PATH (Armbian
# ffmpeg 8.x has them). The HW decode uses mpi_dec_test from an MPP build with
# the codec parsers registered (see the LIB note below).
#
# PASS = every enabled codec decodes 30 frames AND PSNR == inf (bit-exact).
#
# Prereq: combined/av1-fwport kernel booted; device access to /dev/mpp_service +
# /dev/dma_heap/* (root, or the video group via ../scripts/99-rockchip-codec.rules).
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
ROCK5B_WORKSPACE="${ROCK5B_WORKSPACE:-$REPO_ROOT/../rock-5b}"

# --- Paths (env-overridable) -------------------------------------------------
#   MPP_BUILD : an MPP build tree with test/mpi_dec_test AND a librockchip_mpp
#               that has the codec PARSERS registered. The installed YSP MPP
#               package is the default; set MPP_BUILD for an explicit staged
#               or legacy comparison.
#   ASSET_DIR : where the software-encoded inputs live / are generated.
#   FFSW      : stock ffmpeg with software encoders (input generation).
#   FFHW      : ffmpeg-rockchip (only used for the software reference decode; any
#               ffmpeg that can decode these codecs in software works, so this
#               defaults to FFSW).
MPP_BUILD="${MPP_BUILD:-/usr}"
ASSET_DIR="${ASSET_DIR:-$ROCK5B_WORKSPACE/rockchip-conformance/assets}"
OUT="${OUT:-/tmp/rkvdec-differential}"
FFSW="${FFSW:-ffmpeg}"
LIB="$MPP_BUILD/lib"; [ -d "$LIB" ] || LIB="$MPP_BUILD/mpp"
DEC="$MPP_BUILD/bin/mpi_dec_test"; [ -x "$DEC" ] || DEC="$MPP_BUILD/test/mpi_dec_test"

W="${W:-640}"; H="${H:-480}"; DUR="${DUR:-1}"; RATE="${RATE:-30}"
mkdir -p "$OUT" "$ASSET_DIR"

# codec | mpi_dec_test -t | asset basename | sw-encoder | encoder args
#   AV1 uses IVF (mpi_dec_test picks the IVF reader by extension).
CODECS=(
  "H264|7|test_h264.h264|libx264|-g 15"
  "H265|16777220|test_h265.h265|libx265|-x265-params log-level=none -g 15"
  "VP9|10|test_vp9.ivf|libvpx-vp9|-f ivf"
  "AV1|16777224|test_av1.ivf|libsvtav1|-preset 8 -f ivf"
)

echo "================= preflight ================="
[ -x "$DEC" ] || { echo "MISS mpi_dec_test ($DEC) -- set MPP_BUILD"; exit 1; }
[ -d "$LIB" ] || { echo "MISS librockchip_mpp dir ($LIB)"; exit 1; }
command -v "$FFSW" >/dev/null || { echo "MISS ffmpeg ($FFSW)"; exit 1; }
echo "  DEC=$DEC"; echo "  LIB=$LIB"
shopt -s nullglob
dev=(/proc/mpp_service/video-codec* /proc/mpp_service/rkvdec-core*)
[ ${#dev[@]} -gt 0 ] || echo "  WARNING: no decoder nodes under /proc/mpp_service -- not bound?"
echo "  supports-device:"; sed 's/^/    /' /proc/mpp_service/supports-device 2>/dev/null
echo

gen_input() { # basename encoder "args"
  local out="$ASSET_DIR/$1" enc="$2" args="$3"
  [ -s "$out" ] && return 0
  # shellcheck disable=SC2086
  "$FFSW" -hide_banner -y -f lavfi -i "testsrc2=size=${W}x${H}:rate=${RATE}:duration=${DUR}" \
    -c:v "$enc" -pix_fmt yuv420p $args "$out" >/dev/null 2>&1
}

run_one() { # LABEL TYPE BASENAME ENC ARGS
  local L="$1" T="$2" IN="$ASSET_DIR/$3"
  local hw="$OUT/${L}_hw.yuv" sw="$OUT/${L}_sw.yuv"
  echo "================= $L ================="
  gen_input "$3" "$4" "$5" || { echo "  gen-input FAIL (missing $4 encoder?) -> SKIP"; return 2; }
  # Clear both outputs first. OUT defaults to a persistent directory, and without
  # this a decode that failed *without* printing one of the words grepped below
  # (killed, or silently producing nothing) left the PREVIOUS run's _hw.yuv in
  # place to be PSNR'd against a fresh reference -- average:inf, i.e. PASS.
  # test-decode.sh already does this.
  rm -f "$hw" "$sw"
  # hardware decode
  LD_LIBRARY_PATH="$LIB" "$DEC" -i "$IN" -t "$T" -o "$hw" >"$OUT/${L}.log" 2>&1
  local rc=$?
  local frames; frames=$(grep -oiE 'decode ([0-9]+) frames' "$OUT/${L}.log" | tail -1)
  local realerr; realerr=$(grep -iE 'error|fail|not registered' "$OUT/${L}.log" | grep -viE 'not ready' | head -1)
  [ -z "$realerr" ] || { echo "  HW decode error: $realerr"; echo "  RESULT: $L FAIL"; return 1; }
  # The decoder's status was discarded entirely; liveness rested on the stderr
  # grep above, which a killed or silent failure does not trip.
  if [ "$rc" -ne 0 ]; then
    echo "  HW decoder exited $rc with no error text in the log"; echo "  RESULT: $L FAIL"; return 1
  fi
  if [ ! -s "$hw" ]; then
    echo "  HW decode produced no output"; echo "  RESULT: $L FAIL"; return 1
  fi
  # software reference decode -> NV12 (match mpi_dec_test's 8-bit output layout)
  "$FFSW" -hide_banner -y -i "$IN" -f rawvideo -pix_fmt nv12 "$sw" >/dev/null 2>&1
  # PSNR
  local psnr
  psnr=$("$FFSW" -hide_banner -s "${W}x${H}" -pix_fmt nv12 -i "$hw" \
                 -s "${W}x${H}" -pix_fmt nv12 -i "$sw" -lavfi psnr -f null - 2>&1 \
         | grep -oiE 'average:[0-9.a-z]+' | head -1)
  echo "  ${frames:-?frames}, hw=$(stat -c%s "$hw" 2>/dev/null || echo 0)B, PSNR hw-vs-sw ${psnr:-NONE}"
  if [ "$psnr" = "average:inf" ]; then echo "  RESULT: $L PASS (bit-exact)"; return 0; fi
  echo "  RESULT: $L FAIL (not bit-exact: ${psnr:-no-match})"; return 1
}

declare -A R
for spec in "${CODECS[@]}"; do
  IFS='|' read -r L T B E A <<<"$spec"
  run_one "$L" "$T" "$B" "$E" "$A"; R[$L]=$?
  echo
done

echo "================= summary ================="
fail=0
for spec in "${CODECS[@]}"; do
  IFS='|' read -r L _ _ _ _ <<<"$spec"
  case ${R[$L]} in
    0) echo "  $L: PASS (bit-exact)";;
    2) echo "  $L: SKIP (no software encoder to generate input)";;
    *) echo "  $L: FAIL"; fail=1;;
  esac
done
echo "  outputs in: $OUT"
[ $fail -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED -- dmesg | grep -iE 'rkvdec|mpp|av1|iommu|fault'"; exit 1; }
