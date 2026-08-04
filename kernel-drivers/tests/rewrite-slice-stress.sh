#!/usr/bin/env bash
# Regression stress for the rewrite encoder slice-output path.
#
# The official suite runs each slice case exactly once, which is not enough:
# the slice-poll stream-end race and the stale-interrupt attribution race are
# both timing dependent and pass a single run most of the time. On the kernels
# that carried them, h264 slice mode failed roughly once in 20-160 iterations
# under CPU contention and h265 slice mode usually failed on the first.
#
# Two failure shapes are checked, because only one of them sets an exit code:
#   * the process aborts or segfaults (SIGABRT/SIGSEGV, or a poll error), and
#   * the process exits 0 having silently desynchronised its frame framing,
#     visible only as "can not find match frm" or a hal_bufs overrun in its log.
# Checking the exit code alone misses the second shape entirely.
#
# Usage:
#   bash rewrite-slice-stress.sh                  # default iterations
#   SLICE_ITERS=400 bash rewrite-slice-stress.sh
#   SLICE_LOAD=0 bash rewrite-slice-stress.sh     # without CPU contention
#   SLICE_CODECS="h264" bash rewrite-slice-stress.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
: "${SUITE_DMESG_FATAL_RE:?suite-common.sh did not load; the kernel-log fatal scan would be silently blind}"
# shellcheck source=debugfs-counters.sh disable=SC1091
source "$TEST_DIR/debugfs-counters.sh"
: "${DEBUGFS_COUNTERS_LOADED:?debugfs-counters.sh did not load; the counter check would be silently absent}"

ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/build/rockchip-conformance"}
PROFILE=${PROFILE:-rewrite}
RUN_ID=${RUN_ID:-$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$RUN_ID-slice-stress"}
ASSETS=${ASSETS:-"$CONFORMANCE_ROOT/assets"}

SLICE_ITERS=${SLICE_ITERS:-200}
SLICE_CODECS=${SLICE_CODECS:-"h264 h265"}
SLICE_LOAD=${SLICE_LOAD:-1}
SLICE_LOAD_JOBS=${SLICE_LOAD_JOBS:-4}
# Fail rather than degrade when the driver-side counter gate cannot run.
SLICE_REQUIRE_COUNTERS=${SLICE_REQUIRE_COUNTERS:-0}
SLICE_TIMEOUT=${SLICE_TIMEOUT:-60}
SLICE_WIDTH=${SLICE_WIDTH:-1280}
SLICE_HEIGHT=${SLICE_HEIGHT:-720}
SLICE_FRAMES=${SLICE_FRAMES:-120}
SLICE_INSTANCES=${SLICE_INSTANCES:-1}
# Type codes are the MPP coding enum, not small ordinals: 7 is AVC and
# 16777220 is HEVC. Passing 16 here silently encodes something else.
SLICE_TYPE_h264=${SLICE_TYPE_h264:-7}
SLICE_TYPE_h265=${SLICE_TYPE_h265:-16777220}
SLICE_INPUT=${SLICE_INPUT:-"$ASSETS/raw_nv12_1280x720.yuv"}
ENC_BIN=${ENC_BIN:-/usr/bin/mpi_enc_mt_test}

# Desync that leaves the exit code at 0. Kept separate from the kernel-log
# regex: these are userspace-side symptoms of a kernel framing bug.
SLICE_DESYNC_RE=${SLICE_DESYNC_RE:-'can not find match frm|slice poll failed|hal_bufs_get_buf invalid input|invalid input impl'}

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

load_pids=""
start_load()
{
	[ "$SLICE_LOAD" = "1" ] || return 0
	local i
	for i in $(seq 1 "$SLICE_LOAD_JOBS"); do
		(while :; do :; done) &
		load_pids="$load_pids $!"
	done
	log "CPU load: $SLICE_LOAD_JOBS spinners (the race needs contention)"
}

stop_load()
{
	[ -n "$load_pids" ] || return 0
	# shellcheck disable=SC2086
	kill $load_pids 2>/dev/null || true
	wait $load_pids 2>/dev/null || true
	load_pids=""
}

trap 'stop_load' EXIT INT TERM

run_codec()
{
	local codec=$1
	local type_var="SLICE_TYPE_$codec"
	local type=${!type_var}
	local log_file="$OUT/$codec.log"
	local i rc
	local first_fail=0
	local reason=""

	log "== $codec slice: $SLICE_ITERS iterations"
	for i in $(seq 1 "$SLICE_ITERS"); do
		timeout "$SLICE_TIMEOUT" env \
			split_mode=2 split_arg="$SLICE_FRAMES" split_out=1 \
			"$ENC_BIN" \
			-i "$SLICE_INPUT" \
			-w "$SLICE_WIDTH" -h "$SLICE_HEIGHT" -f 0 \
			-t "$type" -n "$SLICE_FRAMES" -v f \
			-o "$OUT/$codec.out" -s "$SLICE_INSTANCES" \
			> "$log_file" 2>&1
		rc=$?

		if [ "$rc" -ne 0 ]; then
			first_fail=$i
			reason="exit rc=$rc"
		elif grep -qaE "$SLICE_DESYNC_RE" "$log_file"; then
			first_fail=$i
			reason="desync in log at exit 0"
		fi

		if [ "$first_fail" -ne 0 ]; then
			cp "$log_file" "$OUT/$codec-fail-$i.log"
			log "   FAIL iteration $i: $reason"
			printf '%s\t%s\t%s\t%s\n' "$codec" fail "$i" "$reason" \
				>> "$OUT/summary.tsv"
			return 1
		fi
	done

	log "   PASS ($SLICE_ITERS clean)"
	printf '%s\t%s\t%s\t%s\n' "$codec" pass "$SLICE_ITERS" "" \
		>> "$OUT/summary.tsv"
	return 0
}

if [ ! -x "$ENC_BIN" ]; then
	log "SKIP: $ENC_BIN is not present"
	exit 77
fi
if [ ! -r "$SLICE_INPUT" ]; then
	log "SKIP: input $SLICE_INPUT is not readable"
	exit 77
fi
if [ ! -e /dev/mpp_service ]; then
	log "SKIP: /dev/mpp_service is absent on this boot"
	exit 77
fi

mkdir -p "$OUT"
printf 'codec\tresult\titerations\treason\n' > "$OUT/summary.tsv"
log "kernel: $(uname -r)"
log "source: $(uname -v)"
log "logs:   $OUT"

suite_dmesg_start "$OUT"
debugfs_counter_snapshot "$OUT/counters-before.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite

overall=0
start_load
for codec in $SLICE_CODECS; do
	run_codec "$codec" || overall=1
done
stop_load

debugfs_counter_snapshot "$OUT/counters-after.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite
debugfs_counter_delta "$OUT/counters-before.tsv" "$OUT/counters-after.tsv" \
	"$OUT/counters-delta.tsv"

if ! suite_dmesg_finish "$OUT"; then
	log "FAIL: kernel log reported a fatal pattern (see $OUT/dmesg-fatal.txt)"
	overall=1
fi

# A clean encode that silently aborted a job or timed out in the driver is
# still a failure: the userspace symptom and the driver symptom are different
# views of the same bug and either alone is enough to fail the run.
#
# debugfs is root-only, so a non-root run captures a header-only delta and the
# driver-side gate is simply absent. Say so explicitly rather than reporting a
# pass, and never report it as "counters moved" -- that would assert a
# measurement that was never taken.
counter_rows=0
if [ -f "$OUT/counters-delta.tsv" ]; then
	counter_rows=$(awk 'NR > 1 && NF > 0' "$OUT/counters-delta.tsv" | wc -l)
fi

if [ "$counter_rows" -gt 0 ]; then
	if COUNTERS_FILE="$OUT/counters-delta.tsv" \
	   FORBID_POSITIVE_COUNTERS="mpp:aborted_job_count mpp:failed_job_count mpp:timeout_count mpp:recovery_failure_count mpp:spurious_irq_count" \
	   REQUIRE_COUNTER_FILE=1 \
		bash "$TEST_DIR/debugfs-counter-check.sh" \
		> "$OUT/counter-check.tsv" 2>&1; then
		log "driver counter gate: clean"
	else
		log "FAIL: driver counters moved (see $OUT/counter-check.tsv)"
		overall=1
	fi
	counter_gate=enforced
else
	counter_gate=unavailable
	log "driver counter gate UNAVAILABLE: debugfs is root-only and this run"
	log "  is not root, so aborted/failed/timeout counters were not checked."
	log "  Re-run with sudo for the full gate."
	if [ "$SLICE_REQUIRE_COUNTERS" = "1" ]; then
		log "FAIL: SLICE_REQUIRE_COUNTERS=1 and the counter gate was absent"
		overall=1
	fi
fi
printf 'counter_gate\t%s\n' "$counter_gate" >> "$OUT/summary.tsv"

log "================= result ================="
log "logs: $OUT"
if [ "$overall" -eq 0 ]; then
	if [ "$counter_gate" = enforced ]; then
		log "slice stress passed"
	else
		log "slice stress passed (DEGRADED: driver counter gate did not run)"
	fi
else
	log "slice stress FAILED"
fi
exit "$overall"
