#!/usr/bin/env bash
# =============================================================================
# transcode-test.sh -- end-to-end RK3588 HARDWARE transcode via ffmpeg-rockchip.
#
# Exercises all three accelerators the kernel port enabled, with NO software
# fallback possible (rkmpp/rkrga components are HW-only -- if a device can't be
# opened the command fails outright, so success == hardware was used):
#
#   Test 1:  input-1080p.h264  --[h264_rkmpp decode]-->  --[scale_rkrga 1080p->720p, nv12]-->  --[hevc_rkmpp encode]-->  720p HEVC
#   Test 2:  (test1 output)    --[hevc_rkmpp decode]-->  --[scale_rkrga 720p->640x480, nv12]-->  --[h264_rkmpp encode]-->  640x480 H.264
#
# Covers: h264 decode, hevc decode, h264 encode, hevc encode, RGA scale+CSC (x2).
#
# Devices /dev/mpp_service + /dev/rga are root-only, so:  sudo bash transcode-test.sh
# =============================================================================
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo bash $0"; exit 1; }

FFDIR=/home/yi/Code/ffmpeg-rockchip
STAGE=/home/yi/Code/rock5b-kernel-debug/ffmpeg-stack
FF="$FFDIR/ffmpeg"
PROBE="$FFDIR/ffprobe"
export LD_LIBRARY_PATH="$STAGE/lib"        # belt + suspenders (binary also has rpath)

IN="$STAGE/testdata/input-1080p.h264"
OUTDIR=/tmp/rk-transcode
mkdir -p "$OUTDIR"
OUT1="$OUTDIR/t1-720p.hevc.mp4"
OUT2="$OUTDIR/t2-480p.h264.mp4"

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
no(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }

[ -x "$FF" ] || { echo "ffmpeg not built at $FF"; exit 1; }
[ -f "$IN" ] || { echo "missing input $IN"; exit 1; }
echo "ffmpeg: $($FF -hide_banner -version 2>/dev/null | head -1)"
echo "input : $IN ($(stat -c%s "$IN") bytes)"
echo

# probe_check <file> <expect_codec> <expect_w> <expect_h> <label>
probe_check() {
  local f="$1" codec="$2" w="$3" h="$4" label="$5"
  local sz=0; [ -f "$f" ] && sz=$(stat -c%s "$f")
  local info; info=$("$PROBE" -hide_banner -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height,nb_read_packets -count_packets \
        -of default=noprint_wrappers=1 "$f" 2>/dev/null)
  echo "    ffprobe: $(echo "$info" | tr '\n' ' ')"
  local gotc gotw goth gotn
  gotc=$(sed -n 's/^codec_name=//p' <<<"$info")
  gotw=$(sed -n 's/^width=//p' <<<"$info")
  goth=$(sed -n 's/^height=//p' <<<"$info")
  gotn=$(sed -n 's/^nb_read_packets=//p' <<<"$info")
  if [ "$sz" -gt 0 ] && [ "$gotc" = "$codec" ] && [ "$gotw" = "$w" ] && [ "$goth" = "$h" ] && [ "${gotn:-0}" -gt 0 ]; then
    ok "$label PASS  ($codec ${w}x${h}, $gotn frames, $sz bytes)"; return 0
  else
    no "$label FAIL  (want $codec ${w}x${h}; got ${gotc:-?} ${gotw:-?}x${goth:-?}, ${gotn:-0} frames, $sz bytes)"; return 1
  fi
}

rc1=0; rc2=0

echo "================= TEST 1: h264 -> [RGA 1080p->720p] -> HEVC ================="
"$FF" -hide_banner -y -loglevel info \
  -hwaccel rkmpp -hwaccel_output_format drm_prime \
  -i "$IN" \
  -vf scale_rkrga=w=1280:h=720:format=nv12 \
  -c:v hevc_rkmpp -b:v 4M \
  "$OUT1" 2>"$OUTDIR/t1.log"
e=$?
grep -iE 'Stream mapping|rkmpp|rkrga|Output #0|frame=.*fps' "$OUTDIR/t1.log" | sed 's/^/    /' | tail -8
echo "  ffmpeg exit: $e"
probe_check "$OUT1" hevc 1280 720 "Test 1" || rc1=1
echo

echo "================= TEST 2: HEVC -> [RGA 720p->480p] -> h264 ================="
"$FF" -hide_banner -y -loglevel info \
  -hwaccel rkmpp -hwaccel_output_format drm_prime \
  -i "$OUT1" \
  -vf scale_rkrga=w=640:h=480:format=nv12:force_original_aspect_ratio=disable \
  -c:v h264_rkmpp -b:v 2M \
  "$OUT2" 2>"$OUTDIR/t2.log"
e=$?
grep -iE 'Stream mapping|rkmpp|rkrga|Output #0|frame=.*fps' "$OUTDIR/t2.log" | sed 's/^/    /' | tail -8
echo "  ffmpeg exit: $e"
probe_check "$OUT2" h264 640 480 "Test 2" || rc2=1
echo

echo "================= recent codec-driver dmesg (HW activity) ================="
dmesg 2>/dev/null | grep -iE 'rkvdec|rkvenc|rga|mpp' | grep -iE 'fault|error|fail|timeout|reset' | tail -5 | sed 's/^/    /' || true
echo "    (no fault/error/timeout lines above = clean HW runs)"
echo

echo "================= summary ================="
echo "  Test 1 (h264 dec + RGA + hevc enc): $([ $rc1 -eq 0 ] && echo PASS || echo FAIL)"
echo "  Test 2 (hevc dec + RGA + h264 enc): $([ $rc2 -eq 0 ] && echo PASS || echo FAIL)"
echo "  outputs in: $OUTDIR"
if [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]; then
  echo "  >>> FULL HARDWARE TRANSCODE PIPELINE WORKS (decode + RGA + encode, both codecs)"
  exit 0
else
  echo "  >>> SOMETHING FAILED -- inspect $OUTDIR/t{1,2}.log and: dmesg | grep -iE 'rkvdec|rkvenc|rga|mpp|iommu'"
  exit 1
fi
