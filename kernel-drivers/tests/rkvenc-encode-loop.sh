#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# =============================================================================
# rkvenc-encode-loop.sh -- repeat one fixed-QP RKVENC encode and measure how
# often it comes out wrong.
#
# The forward-port's intermittent H.264/HEVC encode corruption
# (findings/2026-08-16-forward-port-rkvenc-intermittent-encode-corruption.md)
# needs a rate, not one sample. With rate control removed (CQP), identical
# input must give an identical bitstream, so every run is checked two ways:
#   - determinism: the md5 of each bitstream (one distinct md5 is correct);
#   - quality: software-decode the stream and PSNR it frame-for-frame against
#     the raw source, both as raw YUV, so frame pairing cannot drift.
#
# MODES selects how frames reach the encoder (space-separated list):
#   plain     software frames, as the conformance case sends them; the encoder
#             creates its own rkmpp device (non-cacheable request)
#   device0   explicit -init_hw_device rkmpp with cacheable=0: same request,
#             through a caller-supplied device (path control for device1)
#   device1   explicit device with cacheable=1: FFmpeg asks for cached
#             buffers and brackets every CPU upload with DMA_BUF_IOCTL_SYNC
# If device0 corrupts and device1 does not, the cache flush is what differs.
#
# Usage: rkvenc-encode-loop.sh [ITERATIONS]   (default 12)
# Env:   FF (hardware ffmpeg), FFSW (software ffmpeg for decode/PSNR),
#        CODEC (h264|hevc), W, H, DUR, RATE, QP, MODES, OUT, PSNR_GATE
# Output: $OUT/runs.tsv (one row per run) and $OUT/summary.tsv (one per mode).
# Exit: 0 when every mode is deterministic and above PSNR_GATE in every run,
#       1 when any run fails, 2 on a setup error.
# =============================================================================
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}

ITERATIONS=${1:-${ITERATIONS:-12}}
FF=${FF:-"$ROCK5B_WORKSPACE/ffmpeg/ffmpeg-rockchip-81/ffmpeg"}
FFSW=${FFSW:-ffmpeg}
CODEC=${CODEC:-h264}
W=${W:-640}
H=${H:-360}
DUR=${DUR:-2}
RATE=${RATE:-30}
QP=${QP:-26}
MODES=${MODES:-"plain device0 device1"}
PSNR_GATE=${PSNR_GATE:-35}
OUT=${OUT:-"$ROCK5B_WORKSPACE/build/rkvenc-encode-loop/$(date +%Y%m%d-%H%M%S)-$CODEC"}

case "$CODEC" in
h264) ENC=h264_rkmpp FMT=h264 ;;
hevc) ENC=hevc_rkmpp FMT=hevc ;;
*) echo "CODEC must be h264 or hevc, not '$CODEC'" >&2; exit 2 ;;
esac
case "$ITERATIONS" in
'' | *[!0-9]* | 0) echo "ITERATIONS must be a positive integer" >&2; exit 2 ;;
esac
[ -x "$FF" ] || { echo "hardware ffmpeg not executable: $FF" >&2; exit 2; }
command -v "$FFSW" >/dev/null || { echo "software ffmpeg not found: $FFSW" >&2; exit 2; }

mkdir -p "$OUT"
SRC="testsrc2=size=${W}x${H}:rate=${RATE}:duration=${DUR}"
REF="$OUT/reference-${W}x${H}.yuv"

# The reference is the exact source the encoder sees, kept in the decoder's
# output format (yuv420p) so the comparison needs no conversion.
"$FFSW" -nostdin -hide_banner -loglevel error -y -f lavfi -i "$SRC" \
	-pix_fmt yuv420p -f rawvideo "$REF"
frame_bytes=$((W * H * 3 / 2))
ref_frames=$(($(stat -c %s "$REF") / frame_bytes))

{
	printf "# hw_ffmpeg\t%s\n" "$FF"
	printf "# hw_ffmpeg_version\t%s\n" "$("$FF" -hide_banner -version | head -1)"
	printf "# kernel\t%s\n" "$(uname -r)"
	printf "# source\t%s\n" "$SRC"
	printf "# encoder\t%s -rc_mode CQP -qp_init %s\n" "$ENC" "$QP"
	printf "# reference_frames\t%s\n" "$ref_frames"
} > "$OUT/identity.txt"

encode()
{
	local mode=$1 out=$2 log=$3
	local -a dev=()

	case "$mode" in
	plain) ;;
	device0) dev=(-init_hw_device "rkmpp=mpp:,cacheable=0") ;;
	device1) dev=(-init_hw_device "rkmpp=mpp:,cacheable=1") ;;
	*) echo "unknown mode $mode" >&2; return 2 ;;
	esac

	"$FF" -nostdin -hide_banner -loglevel verbose -y "${dev[@]}" \
		-f lavfi -i "$SRC" -pix_fmt nv12 \
		-c:v "$ENC" -rc_mode CQP -qp_init "$QP" -f "$FMT" "$out" \
		> "$log" 2>&1
}

printf "mode\titer\texit\tbytes\tmd5\tframes\tpsnr_avg\tpsnr_min\n" > "$OUT/runs.tsv"
for mode in $MODES; do
	for i in $(seq 1 "$ITERATIONS"); do
		bs="$OUT/$mode-$i.$FMT"
		dec="$OUT/$mode-$i.yuv"
		rc=0
		encode "$mode" "$bs" "$OUT/$mode-$i.log" || rc=$?
		bytes=0 md5=- frames=0 avg=- min=-
		if [ "$rc" -eq 0 ] && [ -s "$bs" ]; then
			bytes=$(stat -c %s "$bs")
			md5=$(md5sum "$bs" | cut -d' ' -f1)
			"$FFSW" -nostdin -hide_banner -loglevel error -y -i "$bs" \
				-pix_fmt yuv420p -f rawvideo "$dec"
			frames=$(($(stat -c %s "$dec") / frame_bytes))
			psnr=$("$FFSW" -nostdin -hide_banner -loglevel info \
				-f rawvideo -pix_fmt yuv420p -s "${W}x${H}" -i "$dec" \
				-f rawvideo -pix_fmt yuv420p -s "${W}x${H}" -i "$REF" \
				-lavfi psnr -f null - 2>&1 | grep -o 'average:[^ ]* min:[^ ]*' | tail -1)
			avg=$(sed -E 's/average:([^ ]*) .*/\1/' <<<"$psnr")
			min=$(sed -E 's/.*min:([^ ]*)/\1/' <<<"$psnr")
			rm -f "$dec"
		fi
		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"$mode" "$i" "$rc" "$bytes" "$md5" "$frames" "$avg" "$min" \
			>> "$OUT/runs.tsv"
		printf "%-8s run %2d/%d  exit=%s bytes=%s psnr_avg=%s min=%s\n" \
			"$mode" "$i" "$ITERATIONS" "$rc" "$bytes" "$avg" "$min"
	done
done

# Per mode: distinct bitstreams, PSNR range, and runs below the gate. A run
# fails when it exits nonzero, loses frames, or scores below PSNR_GATE ("inf"
# is a pass); a mode fails when any run fails or its bitstreams differ.
awk -F'\t' -v gate="$PSNR_GATE" -v want="$ref_frames" '
NR == 1 { next }
{
	m = $1; n[m]++
	if (!(m in order)) { order[m] = ++nm; names[nm] = m }
	if (!seen[m, $5]++) distinct[m]++
	bad = ($3 != 0 || $6 != want || $7 == "-" || ($7 != "inf" && $7 + 0 < gate))
	below[m] += bad
	v = ($7 == "inf") ? 1e9 : $7 + 0
	if (!(m in lo) || v < lo[m]) lo[m] = v
	if (!(m in hi) || v > hi[m]) hi[m] = v
}
END {
	print "mode\truns\tdistinct_md5\tfailed_runs\tpsnr_avg_lo\tpsnr_avg_hi\tverdict"
	fail = 0
	for (k = 1; k <= nm; k++) {
		m = names[k]
		v = (below[m] == 0 && distinct[m] == 1) ? "pass" : "fail"
		if (v == "fail") fail = 1
		printf "%s\t%d\t%d\t%d\t%s\t%s\t%s\n", m, n[m], distinct[m], below[m],
			(lo[m] >= 1e9 ? "inf" : lo[m]), (hi[m] >= 1e9 ? "inf" : hi[m]), v
	}
	exit fail
}' "$OUT/runs.tsv" > "$OUT/summary.tsv" && status=0 || status=$?

echo
column -t -s$'\t' "$OUT/summary.tsv"
echo "$OUT"
exit "$status"
