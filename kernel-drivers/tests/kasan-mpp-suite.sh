#!/usr/bin/env bash
# Full MPP codec matrix under the KASAN/ramoops debug kernel, with a kernel-log
# scan around it. This is the memory-safety gate that gets past the preflight
# Oops which crashed forward-port run 20260717-230531: it exercises decode /
# multi-thread / multi-instance / encode / slice / rate-control paths (the same
# paths as findings 0042 reset-session and 0043 rkvenc2_wait_result). Pass =
# every required case passes AND kernel-log-flags.txt is empty.
#
# Inputs default to the tracked conformance assets; AVS2 is omitted (no asset).
# Override MPP_REQUIRED_CASES / MPP_*_INPUT to change the matrix. Must run on the
# KASAN/ramoops debug kernel; see kernel-drivers/docs/debug-kernel.md.
set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=kasan-scan.sh disable=SC1091
source "$TEST_DIR/kasan-scan.sh"

ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/build/rockchip-conformance"}
ASSETS=${ASSETS:-"$CONFORMANCE_ROOT/assets"}
PROFILE=${PROFILE:-forward-port}
TS=$(date +%Y%m%d-%H%M%S)
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$TS-kasan-mpp-suite"}

MPP_H264_INPUT=${MPP_H264_INPUT:-"$ASSETS/test_h264.h264"}
MPP_H265_INPUT=${MPP_H265_INPUT:-"$ASSETS/test_h265.h265"}
MPP_VP9_INPUT=${MPP_VP9_INPUT:-"$ASSETS/test_vp9.ivf"}
MPP_ENC_INPUT=${MPP_ENC_INPUT:-"$ASSETS/raw_nv12_1280x720.yuv"}
MPP_ENC_WIDTH=${MPP_ENC_WIDTH:-1280}
MPP_ENC_HEIGHT=${MPP_ENC_HEIGHT:-720}
MPP_ENC_FORMAT=${MPP_ENC_FORMAT:-0}
MPP_REQUIRED_CASES=${MPP_REQUIRED_CASES:-"mpp_info_test mpi_dec_h264 mpi_dec_h265 mpi_dec_vp9 mpi_dec_mt_h264 mpi_dec_multi_h265 mpi_enc_h264 mpi_enc_h265 mpi_enc_h264_slice mpi_enc_h265_slice mpi_enc_mt_h265 mpi_rc2_h264"}

log() { printf '%s %s\n' "$(date +%T)" "$*"; }

kasan_scan_begin "$OUT"
log "MPP suite (KASAN) start -> $OUT"

set +e
PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" OUT="$OUT" \
	MPP_H264_INPUT="$MPP_H264_INPUT" MPP_H265_INPUT="$MPP_H265_INPUT" \
	MPP_VP9_INPUT="$MPP_VP9_INPUT" \
	MPP_ENC_INPUT="$MPP_ENC_INPUT" MPP_ENC_WIDTH="$MPP_ENC_WIDTH" \
	MPP_ENC_HEIGHT="$MPP_ENC_HEIGHT" MPP_ENC_FORMAT="$MPP_ENC_FORMAT" \
	MPP_REQUIRED_CASES="$MPP_REQUIRED_CASES" \
	bash "$TEST_DIR/mpp-suite.sh"
suite_status=$?
set -e
log "MPP suite done status=$suite_status"

flags=$(kasan_scan_end "$OUT") && clean=1 || clean=0

echo
echo "===== per-case results (summary.tsv) ====="
column -t -s"$(printf '\t')" "$OUT/summary.tsv" 2>/dev/null || cat "$OUT/summary.tsv" 2>/dev/null || true
echo
echo "RESULT suite_status=$suite_status flagged_kernel_lines=$flags clean=$clean out=$OUT"

# Fail if any required case failed or any fatal kernel signature appeared.
{ [ "$suite_status" -eq 0 ] && [ "$clean" -eq 1 ]; } || exit 1
