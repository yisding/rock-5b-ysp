#!/usr/bin/env bash
# One gate for the 2026-07-31 rewrite driver fix series.
#
# Each fix in that series is a race or an error path, so the ordinary
# conformance suite passes with or without them: it runs every case once, and
# these defects need repetition, contention, or a specific failure to surface.
# This runner drives the checks that actually discriminate, and prints exactly
# which fixes it covered and which it did not.
#
# Coverage, and how strong each check actually is. "PROVEN" means the check was
# observed failing on a kernel without the fix; "GUARD" means it passes with and
# without the fix, so it can catch a future gross regression but is not evidence
# the fix works. That distinction is recorded because it was measured, not
# assumed -- every GUARD below was run against the unfixed kernel and passed.
#
#   ce2d70d slice-poll stream-end race          -> slice       PROVEN
#   5d710b0 stale IRQ attributed to next job    -> slice       PROVEN
#           (both caught on the unfixed kernel: h264 SIGABRT and h265 SIGSEGV
#           at iteration 4, plus a separate exit-0 framing desync)
#   b22a550 blocking slice poll returns early   -> slice       GUARD
#   5d710b0 -ERESTARTSYS restarts a submit      -> signals     GUARD
#           (stock libmpp submits and polls in separate ioctls, so restarting
#           a poll-only ioctl is harmless; the duplicate-submit hazard needs a
#           batched submit+poll ioctl no stock binary issues)
#   1004046 soft-CCU abort skips CCU bracket    -> abort       GUARD
#           (the unfixed kernel shows no stall here even with the coordinator
#           held powered; under root the timeout_count delta is the meaningful
#           signal, and a stall would have to reach the ~2 s watchdog)
#   d9992e3 reset deassert contention counter   -> contention  instrumentation
#
#   5d710b0 poll error after delivering records -> NOT COVERED (needs a
#           non-blocking slice poller; no stock binary issues one)
#   66ae8c0 RGA acquire fence uninterruptible   -> NOT COVERED (needs an
#           unsignalled fence; this board exposes no /dev/sw_sync)
#   66ae8c0 RGA huge userptr import allocation  -> NOT COVERED (needs a raw
#           RGA_IOC_IMPORT_BUFFER probe)
#   66ae8c0 RGA import rollback by handle       -> NOT COVERED (needs two
#           threads racing import against release on one fd)
#   66ae8c0 RGA u16 geometry truncation         -> NOT COVERED (as above)
#
#   plus baseline regression from the official MPP suite.
#
# So a green run means: the slice fixes hold where they demonstrably failed
# before, and nothing else regressed. It is NOT evidence that the RGA
# hardening, the non-blocking poll path, or the CCU bracket work.
#
# Usage:
#   sudo bash rewrite-fixes-gate.sh              # everything it can run
#   VALIDATE_ONLY=1 bash rewrite-fixes-gate.sh   # device-free config check
#   GATE_CHECKS="slice abort" bash rewrite-fixes-gate.sh
#   GATE_CONTENTION_EXPECT=contended sudo bash rewrite-fixes-gate.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
: "${SUITE_DMESG_FATAL_RE:?suite-common.sh did not load; the kernel-log fatal scan would be silently blind}"
# shellcheck source=debugfs-counters.sh disable=SC1091
source "$TEST_DIR/debugfs-counters.sh"
: "${DEBUGFS_COUNTERS_LOADED:?debugfs-counters.sh did not load; the counter checks would be silently absent}"

ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/build/rockchip-conformance"}
PROFILE=${PROFILE:-rewrite}
RUN_ID=${RUN_ID:-$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$RUN_ID-fixes-gate"}
ASSETS=${ASSETS:-"$CONFORMANCE_ROOT/assets"}
VALIDATE_ONLY=${VALIDATE_ONLY:-0}

GATE_CHECKS=${GATE_CHECKS:-"slice signals abort contention mpp-suite"}
GATE_SLICE_ITERS=${GATE_SLICE_ITERS:-120}
GATE_SIGNAL_LOOPS=${GATE_SIGNAL_LOOPS:-15}
GATE_ABORT_LOOPS=${GATE_ABORT_LOOPS:-10}
# Concurrent decoders held running across the abort loop. Without them the
# coordinator autosuspends between iterations and resets the very state the
# check is looking for.
GATE_ABORT_SURVIVORS=${GATE_ABORT_SURVIVORS:-2}
# The decoder watchdog is ~2 s. A healthy follow-up decode of the tracked
# clip is tens of milliseconds, so anything approaching the watchdog means the
# first frame after the abort stalled.
GATE_ABORT_STALL_MS=${GATE_ABORT_STALL_MS:-1200}
GATE_CONTENTION_EXPECT=${GATE_CONTENTION_EXPECT:-report}
GATE_DEC_INPUT=${GATE_DEC_INPUT:-"$ASSETS/test_h265.h265"}
GATE_DEC_CODING=${GATE_DEC_CODING:-16777220}
GATE_ENC_INPUT=${GATE_ENC_INPUT:-"$ASSETS/raw_nv12_1280x720.yuv"}
DEC_BIN=${DEC_BIN:-/usr/bin/mpi_dec_test}
ENC_BIN=${ENC_BIN:-/usr/bin/mpi_enc_mt_test}
DEBUGFS_DIR=/sys/kernel/debug/rk_mpp_rewrite

DESYNC_RE='can not find match frm|slice poll failed|hal_bufs_get_buf invalid input|invalid input impl'

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
banner() { printf '\n================= %s =================\n' "$*"; }

pass_count=0
fail_count=0
skip_count=0

record()
{
	local check=$1 result=$2 detail=$3 fixes=$4

	printf '%s\t%s\t%s\t%s\n' "$check" "$result" "$fixes" "$detail" \
		>> "$OUT/summary.tsv"
	case "$result" in
	pass) pass_count=$((pass_count + 1)); log "  PASS: $detail" ;;
	fail) fail_count=$((fail_count + 1)); log "  FAIL: $detail" ;;
	skip) skip_count=$((skip_count + 1)); log "  SKIP: $detail" ;;
	esac
}

counter_of()
{
	cat "$DEBUGFS_DIR/$1" 2>/dev/null || echo ""
}

# --- checks ---------------------------------------------------------------

check_slice()
{
	banner "slice: encoder slice-output regression stress"
	local rc
	SLICE_ITERS="$GATE_SLICE_ITERS" \
	RUN_ID="$RUN_ID-gate" \
	OUT="$OUT/slice" \
		bash "$TEST_DIR/rewrite-slice-stress.sh" \
		> "$OUT/slice.log" 2>&1
	rc=$?
	case "$rc" in
	0) record slice pass "both codecs clean over $GATE_SLICE_ITERS iterations" \
		"ce2d70d,5d710b0,b22a550" ;;
	77) record slice skip "prerequisites absent (see slice.log)" \
		"ce2d70d,5d710b0,b22a550" ;;
	*) record slice fail "slice stress failed, see $OUT/slice.log" \
		"ce2d70d,5d710b0,b22a550" ;;
	esac
}

check_signals()
{
	banner "signals: interrupted poll must not restart a submitted batch"
	# Job-control stop/continue is the reliable way to make an interruptible
	# wait return -ERESTARTSYS. Before the fix that restarted the whole
	# ioctl and re-submitted jobs already on the hardware, so the frame was
	# encoded twice into one buffer and the duplicate was never reaped.
	# The observable is the same framing desync the slice check looks for,
	# plus a non-zero exit.
	local i rc bad=0
	for i in $(seq 1 "$GATE_SIGNAL_LOOPS"); do
		env split_mode=2 split_arg=60 split_out=1 \
			"$ENC_BIN" -i "$GATE_ENC_INPUT" -w 1280 -h 720 -f 0 \
			-t 7 -n 60 -v f -o "$OUT/signals.out" -s 1 \
			> "$OUT/signals.log" 2>&1 &
		local pid=$!
		# Stop/continue repeatedly while it encodes.
		for _ in 1 2 3 4 5 6; do
			sleep 0.05
			kill -STOP "$pid" 2>/dev/null || break
			sleep 0.02
			kill -CONT "$pid" 2>/dev/null || break
		done
		wait "$pid"
		rc=$?
		if [ "$rc" -ne 0 ]; then
			bad=1
			cp "$OUT/signals.log" "$OUT/signals-fail-$i.log"
			record signals fail "encode died under stop/cont at loop $i (rc=$rc)" \
				"5d710b0"
			return
		fi
		if grep -qaE "$DESYNC_RE" "$OUT/signals.log"; then
			bad=1
			cp "$OUT/signals.log" "$OUT/signals-desync-$i.log"
			record signals fail "framing desync under stop/cont at loop $i" \
				"5d710b0"
			return
		fi
	done
	[ "$bad" -eq 0 ] && record signals pass \
		"$GATE_SIGNAL_LOOPS encodes survived stop/cont cleanly" "5d710b0"
}

time_one_decode()
{
	local logfile=$1 start end
	start=$(suite_now_ns)
	"$DEC_BIN" -i "$GATE_DEC_INPUT" -t "$GATE_DEC_CODING" -v f \
		> "$logfile" 2>&1
	local rc=$?
	end=$(suite_now_ns)
	printf '%s %s' "$(( (end - start) / 1000000 ))" "$rc"
}

abort_survivor_pids=""
start_abort_survivors()
{
	local i
	for i in $(seq 1 "$GATE_ABORT_SURVIVORS"); do
		(
			while :; do
				"$DEC_BIN" -i "$GATE_DEC_INPUT" \
					-t "$GATE_DEC_CODING" -v f \
					> /dev/null 2>&1 || true
			done
		) &
		abort_survivor_pids="$abort_survivor_pids $!"
	done
}

stop_abort_survivors()
{
	[ -n "$abort_survivor_pids" ] || return 0
	# shellcheck disable=SC2086
	pkill -P $abort_survivor_pids 2>/dev/null || true
	# shellcheck disable=SC2086
	kill $abort_survivor_pids 2>/dev/null || true
	# shellcheck disable=SC2086
	wait $abort_survivor_pids 2>/dev/null || true
	abort_survivor_pids=""
}

check_abort()
{
	banner "abort: a killed decode must not stall the next job on that core"
	# Before the soft-CCU bracket fix, aborting a job reset its core without
	# first disconnecting it from the coordinator or reconnecting it after,
	# so the coordinator kept the core registered as work-pending and the
	# next job on it produced no completion interrupt until its ~2 s
	# watchdog fired.
	#
	# That stale state only survives while something keeps the coordinator
	# powered -- otherwise it autosuspends and its register file resets,
	# which quietly clears the very state under test. So this runs
	# concurrent survivor decoders throughout, and calibrates against a
	# baseline measured under the same load rather than a guessed constant.
	local before_timeout after_timeout i ms rc baseline=0 worst=0 out

	before_timeout=$(counter_of timeout_count)
	start_abort_survivors
	trap 'stop_abort_survivors' RETURN

	# Baseline: same survivor load, no abort in front of it.
	for _ in 1 2 3; do
		out=$(time_one_decode "$OUT/abort-baseline.log")
		ms=${out% *}
		[ "$ms" -gt "$baseline" ] && baseline=$ms
	done

	for i in $(seq 1 "$GATE_ABORT_LOOPS"); do
		"$DEC_BIN" -i "$GATE_DEC_INPUT" -t "$GATE_DEC_CODING" -v f \
			> /dev/null 2>&1 &
		local victim=$!
		sleep 0.08
		kill -9 "$victim" 2>/dev/null || true
		wait "$victim" 2>/dev/null || true

		out=$(time_one_decode "$OUT/abort-followup.log")
		ms=${out% *}
		rc=${out#* }
		[ "$ms" -gt "$worst" ] && worst=$ms

		if [ "$rc" -ne 0 ]; then
			stop_abort_survivors
			record abort fail \
				"follow-up decode failed after abort at loop $i (rc=$rc)" \
				"1004046"
			return
		fi
	done
	stop_abort_survivors

	after_timeout=$(counter_of timeout_count)
	local detail="follow-up worst ${worst}ms vs baseline ${baseline}ms over $GATE_ABORT_LOOPS aborts"
	local failed=0

	if [ -n "$before_timeout" ] && [ -n "$after_timeout" ]; then
		local grew=$((after_timeout - before_timeout))
		detail="$detail, timeout_count +$grew"
		[ "$grew" -gt 0 ] && failed=1
	else
		detail="$detail, timeout_count unreadable (not root)"
	fi

	# A watchdog stall adds seconds, so require the follow-up to stay near
	# the baseline measured under identical load.
	if [ "$worst" -ge $((baseline + GATE_ABORT_STALL_MS)) ]; then
		failed=1
		detail="$detail -- follow-up stalled past baseline+${GATE_ABORT_STALL_MS}ms"
	fi

	if [ "$failed" -eq 0 ]; then
		record abort pass "$detail" "1004046"
	else
		record abort fail "$detail" "1004046"
	fi
}

check_contention()
{
	banner "contention: sibling-core reset deassert overlap"
	local rc
	EXPECT="$GATE_CONTENTION_EXPECT" \
	RUN_ID="$RUN_ID-gate" \
	OUT="$OUT/contention" \
		bash "$TEST_DIR/rewrite-reset-contention.sh" \
		> "$OUT/contention.log" 2>&1
	rc=$?
	case "$rc" in
	0) record contention pass \
		"EXPECT=$GATE_CONTENTION_EXPECT satisfied (see contention.log)" \
		"d9992e3" ;;
	77) record contention skip \
		"needs root and a kernel carrying the counter" "d9992e3" ;;
	78) record contention fail \
		"inconclusive: the provocation was too weak to measure the race at all (resets/expected-hits in contention.log), so this says nothing about EXPECT=$GATE_CONTENTION_EXPECT" \
		"d9992e3" ;;
	*) record contention fail \
		"EXPECT=$GATE_CONTENTION_EXPECT not satisfied, see $OUT/contention.log" \
		"d9992e3" ;;
	esac
}

check_mpp_suite()
{
	banner "mpp-suite: baseline conformance regression"
	local rc
	PROFILE="$PROFILE" RUN_ID="$RUN_ID-gate" \
	MPP_SUITE_OUT="$OUT/mpp-suite" \
		bash "$TEST_DIR/mpp-suite.sh" > "$OUT/mpp-suite.log" 2>&1
	rc=$?
	case "$rc" in
	0) record mpp-suite pass "official suite green" "regression" ;;
	77) record mpp-suite skip "suite prerequisites absent" "regression" ;;
	*) record mpp-suite fail "official suite failed, see $OUT/mpp-suite.log" \
		"regression" ;;
	esac
}

# --- main -----------------------------------------------------------------

if [ "$VALIDATE_ONLY" = "1" ]; then
	log "VALIDATE_ONLY: checking configuration only, no hardware work"
	status=0
	for check in $GATE_CHECKS; do
		case "$check" in
		slice|signals|abort|contention|mpp-suite)
			log "  check '$check' is known" ;;
		*)
			log "  UNKNOWN check '$check'"; status=1 ;;
		esac
	done
	for helper in rewrite-slice-stress.sh rewrite-reset-contention.sh \
		mpp-suite.sh; do
		if [ -r "$TEST_DIR/$helper" ]; then
			bash -n "$TEST_DIR/$helper" || status=1
		else
			log "  MISSING helper $helper"; status=1
		fi
	done
	[ "$status" -eq 0 ] && log "configuration OK" || log "configuration INVALID"
	exit "$status"
fi

mkdir -p "$OUT"
printf 'check\tresult\tfixes\tdetail\n' > "$OUT/summary.tsv"
log "kernel: $(uname -r)"
log "source: $(uname -v)"
log "logs:   $OUT"
if [ "$(id -u)" -ne 0 ]; then
	log "NOTE: not root -- debugfs counter gates and the contention check will"
	log "  skip or degrade. Re-run with sudo for the full gate."
fi

suite_dmesg_start "$OUT"
debugfs_counter_snapshot "$OUT/counters-before.tsv" mpp "$DEBUGFS_DIR" \
	rga /sys/kernel/debug/rk_rga_rewrite

for check in $GATE_CHECKS; do
	case "$check" in
	slice)      check_slice ;;
	signals)    check_signals ;;
	abort)      check_abort ;;
	contention) check_contention ;;
	mpp-suite)  check_mpp_suite ;;
	*)          record "$check" fail "unknown check name" "-" ;;
	esac
done

debugfs_counter_snapshot "$OUT/counters-after.tsv" mpp "$DEBUGFS_DIR" \
	rga /sys/kernel/debug/rk_rga_rewrite
debugfs_counter_delta "$OUT/counters-before.tsv" "$OUT/counters-after.tsv" \
	"$OUT/counters-delta.tsv"

banner "kernel log"
if suite_dmesg_finish "$OUT"; then
	log "  clean"
else
	log "  FAIL: fatal pattern in new dmesg (see $OUT/dmesg-fatal.txt)"
	fail_count=$((fail_count + 1))
	printf 'dmesg\tfail\t-\tfatal pattern in new kernel log\n' \
		>> "$OUT/summary.tsv"
fi

banner "result"
column -t -s "$(printf '\t')" "$OUT/summary.tsv" 2>/dev/null || cat "$OUT/summary.tsv"
printf '\n'
log "pass=$pass_count fail=$fail_count skip=$skip_count"
log "logs: $OUT"
cat <<'EOF'

Coverage strength: only the 'slice' check is PROVEN -- it was observed failing
on a kernel without the fixes. 'signals' and 'abort' pass with and without
them, so they guard against a future gross regression but are not evidence
those fixes work.

NOT COVERED at all (a green run says nothing about these):
  - RGA acquire-fence interruptibility  (needs an unsignalled fence; this
    board exposes no /dev/sw_sync)
  - RGA oversized userptr import, import-rollback handle reuse, and u16
    geometry rejection (each needs a raw RGA_IOC_IMPORT_BUFFER probe)
  - the slice poll returning records alongside an error on the non-blocking
    path (no stock binary issues a non-blocking slice poll)
EOF

[ "$fail_count" -eq 0 ] || exit 1
exit 0
