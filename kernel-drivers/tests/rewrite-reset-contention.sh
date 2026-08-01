#!/usr/bin/env bash
# Provoke and measure the sibling-core reset deassert race on rkvdec soft CCU.
#
# WHAT THIS MEASURES
#
# rk_mpp_hw_power_on() deasserts the target core's reset unconditionally, on
# every call and not just on a 0->1 power transition. On a soft-CCU decoder,
# rk_mpp_rkvdec2_acquire_soft_ccu() reaches that for *sibling* cores holding
# only the submitting core's run_lock, while a sibling's own recovery pulses
# its reset (assert / udelay(10) / deassert) under its own run_lock. Nothing is
# common to both, so a submit on core0 can end core1's pulse after ~2 us of the
# intended 10. core1's own deassert then no-ops, rk_mpp_hw_reset_active()
# returns 0, and the job is completed as recovered without the core ever having
# been reset.
#
# The driver counts that overlap in mpp:reset_deassert_contended_count. This
# harness provokes it: several concurrent decode sessions on the CCU group,
# with one repeatedly killed mid-decode so its abort path resets a core while
# the survivors keep submitting and re-powering siblings.
#
# INTERPRETING THE RESULT
#
#   nonzero  the race is reachable on this kernel and board. Expected BEFORE
#            the per-reset-domain lock lands. This is the reachability evidence
#            that justifies the fix; run it in this mode first.
#   zero     either the fix is in, or the window was not hit this run. Zero
#            alone does not prove the fix works -- confirm the counter was
#            nonzero on the same workload beforehand, or the test proves
#            nothing.
#
# Use EXPECT=contended (pre-fix, reachability) or EXPECT=clean (post-fix,
# regression) to turn the observation into a pass/fail.
#
# Needs root: the counter lives in debugfs, which is 0700.
#
#   sudo EXPECT=contended bash rewrite-reset-contention.sh
#   sudo EXPECT=clean     bash rewrite-reset-contention.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
: "${SUITE_DMESG_FATAL_RE:?suite-common.sh did not load; the kernel-log fatal scan would be silently blind}"
# shellcheck source=debugfs-counters.sh disable=SC1091
source "$TEST_DIR/debugfs-counters.sh"
: "${DEBUGFS_COUNTERS_LOADED:?debugfs-counters.sh did not load; the counter readout would be silently absent}"

ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/rockchip-conformance"}
PROFILE=${PROFILE:-rewrite}
RUN_ID=${RUN_ID:-$(date +%Y%m%d-%H%M%S)}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$RUN_ID-reset-contention"}
ASSETS=${ASSETS:-"$CONFORMANCE_ROOT/assets"}

RESET_LOOPS=${RESET_LOOPS:-40}
RESET_SURVIVORS=${RESET_SURVIVORS:-2}
RESET_KILL_AFTER_MS=${RESET_KILL_AFTER_MS:-120}
RESET_INPUT=${RESET_INPUT:-"$ASSETS/test_h265.h265"}
RESET_CODING=${RESET_CODING:-16777220}
DEC_BIN=${DEC_BIN:-/usr/bin/mpi_dec_test}
EXPECT=${EXPECT:-report}
COUNTER=mpp:reset_deassert_contended_count
DEBUGFS_DIR=/sys/kernel/debug/rk_mpp_rewrite

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

read_counter()
{
	cat "$DEBUGFS_DIR/reset_deassert_contended_count" 2>/dev/null || echo ""
}

survivor_pids=""
start_survivors()
{
	local i
	for i in $(seq 1 "$RESET_SURVIVORS"); do
		(
			while :; do
				"$DEC_BIN" -i "$RESET_INPUT" \
					-t "$RESET_CODING" -v f \
					> /dev/null 2>&1 || true
			done
		) &
		survivor_pids="$survivor_pids $!"
	done
}

stop_survivors()
{
	[ -n "$survivor_pids" ] || return 0
	# shellcheck disable=SC2086
	kill $survivor_pids 2>/dev/null || true
	# The loops respawn the decoder, so kill the whole process group of each.
	# shellcheck disable=SC2086
	pkill -P $survivor_pids 2>/dev/null || true
	wait $survivor_pids 2>/dev/null || true
	survivor_pids=""
}

trap 'stop_survivors' EXIT INT TERM

if [ "$(id -u)" -ne 0 ]; then
	log "SKIP: debugfs is root-only and this run is not root"
	exit 77
fi
if [ ! -x "$DEC_BIN" ]; then
	log "SKIP: $DEC_BIN is not present"
	exit 77
fi
if [ ! -r "$RESET_INPUT" ]; then
	log "SKIP: input $RESET_INPUT is not readable"
	exit 77
fi
if [ ! -d "$DEBUGFS_DIR" ]; then
	log "SKIP: $DEBUGFS_DIR is absent (not a rewrite kernel?)"
	exit 77
fi
if [ -z "$(read_counter)" ]; then
	log "SKIP: this kernel has no reset_deassert_contended_count counter."
	log "  It is the instrumentation this test reads; rebuild with it first."
	exit 77
fi

mkdir -p "$OUT"
log "kernel: $(uname -r)"
log "source: $(uname -v)"
log "logs:   $OUT"

before=$(read_counter)
log "reset_deassert_contended_count before: $before"

suite_dmesg_start "$OUT"
debugfs_counter_snapshot "$OUT/counters-before.tsv" mpp "$DEBUGFS_DIR"

start_survivors
log "provoking: $RESET_LOOPS kill cycles against $RESET_SURVIVORS survivors"
for loop in $(seq 1 "$RESET_LOOPS"); do
	"$DEC_BIN" -i "$RESET_INPUT" -t "$RESET_CODING" -v f \
		> /dev/null 2>&1 &
	victim=$!
	# Kill mid-decode so the abort path resets the core while the survivors
	# are still submitting and re-powering their siblings.
	sleep "$(awk -v ms="$RESET_KILL_AFTER_MS" 'BEGIN{print ms/1000}')"
	kill -9 "$victim" 2>/dev/null || true
	wait "$victim" 2>/dev/null || true
done
stop_survivors

debugfs_counter_snapshot "$OUT/counters-after.tsv" mpp "$DEBUGFS_DIR"
debugfs_counter_delta "$OUT/counters-before.tsv" "$OUT/counters-after.tsv" \
	"$OUT/counters-delta.tsv"

after=$(read_counter)
delta=$((after - before))
log "reset_deassert_contended_count after:  $after (delta $delta)"

status=0
if ! suite_dmesg_finish "$OUT"; then
	log "FAIL: kernel log reported a fatal pattern (see $OUT/dmesg-fatal.txt)"
	status=1
fi

{
	printf 'counter\tbefore\tafter\tdelta\texpect\n'
	printf '%s\t%s\t%s\t%s\t%s\n' "$COUNTER" "$before" "$after" "$delta" \
		"$EXPECT"
} > "$OUT/summary.tsv"

case "$EXPECT" in
contended)
	if [ "$delta" -gt 0 ]; then
		log "PASS: race reproduced ($delta overlaps) -- reachable here"
	else
		log "FAIL: no overlap observed; the provocation did not hit the"
		log "  window. Raise RESET_LOOPS/RESET_SURVIVORS, or the race may"
		log "  not be reachable in this configuration."
		status=1
	fi
	;;
clean)
	if [ "$delta" -eq 0 ]; then
		log "PASS: no overlap observed"
		log "  NOTE: only meaningful if this same workload showed a"
		log "  nonzero delta before the fix."
	else
		log "FAIL: $delta overlaps still observed after the fix"
		status=1
	fi
	;;
*)
	log "report-only (EXPECT=contended or EXPECT=clean to gate)"
	;;
esac

log "================= result ================="
log "logs: $OUT"
exit "$status"
