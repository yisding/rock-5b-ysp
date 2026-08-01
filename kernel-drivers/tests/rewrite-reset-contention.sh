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
# The driver counts that overlap in mpp:reset_deassert_contended_count.
#
# HOW IT PROVOKES IT, AND WHY IT IS SHAPED THIS WAY
#
# The race needs two things happening at once: a reset pulse on one core, and a
# deassert issued for that same core by a sibling's submit. Both rates matter,
# and the expected number of hits is roughly
#
#     resets * (deasserts on that core per second) * 10 us
#
# -- see HOW THE EXPECTED-HIT ESTIMATE IS BUILT below for how each term is
# obtained.
#
# The first version of this harness drove resets only by killing a decoder
# mid-decode, betting that the abort path would reset the core. That is far too
# weak, and the 2026-07-31 run proved it: 40 kill cycles produced 1 abort, zero
# resets, and therefore a meaningless zero in the contention counter. A kill
# lands on an in-flight job only a few percent of the time, because at ~26
# frames of ~480 us per 300 ms process lifetime the hardware is busy about 4%
# of the wall clock. Expected hits came to ~5e-3 per run.
#
# So resets are driven from the error path instead. rk_mpp_rkvdec2_*_thread()
# resets the core whenever the decode interrupt status hits the error mask, and
# a stream with damaged slice payloads hits it every frame -- hundreds of resets
# per second rather than one per twenty seconds. rewrite-corrupt-stream.py
# builds that stream, damaging only slice payloads so the parameter sets still
# parse and userspace still submits. Three engines run concurrently:
#
#   error     N loops decoding the corrupt stream -- the reset source
#   survivor  N loops decoding the clean stream   -- the sibling submit source
#   kill      one loop killed mid-decode          -- the session-abort reset
#             path that 1004046 changed, kept because it is the path the
#             finding describes even though it is the weaker source
#
# INTERPRETING THE RESULT
#
# The harness reports resets, deasserts, and submits alongside the contention
# count, because a zero contention count means nothing on its own -- it may mean
# the provocation never ran. Three outcomes:
#
#   INCONCLUSIVE  no resets happened, or the run's expected-hit count came out
#                 under RESET_MIN_EXPECT. The measurement had no power; it says
#                 nothing about the race either way. Raise RESET_DURATION_S,
#                 RESET_ERROR_STREAMS or RESET_SURVIVORS and re-run.
#   contended     the overlap is reachable on this kernel and board. Expected
#                 BEFORE the per-reset-domain lock lands; this is the
#                 reachability evidence that justifies the fix.
#   clean         resets and submits both happened at a rate that should have
#                 produced hits, and none did. Meaningful only against a run
#                 that showed hits on the same workload beforehand.
#
# The counter brackets the whole pulse -- it is incremented before the assert
# and decremented after the deassert -- so it slightly over-counts: a deassert
# landing before the assert, or after this core's own deassert, is harmless.
# That is fine for reachability, where the question is whether the two paths
# overlap at all, but it means the count is an upper bound on real damage.
#
# HOW THE EXPECTED-HIT ESTIMATE IS BUILT
#
# On a kernel carrying the per-core reset/deassert counters, both terms are
# measured and the sum is taken per core, over *cross-core* deasserts only:
#
#     sum over cores of  resets(core) * cross_core_deasserts(core)/second * 10 us
#
# Per core rather than in aggregate, because the overlap is a property of one
# core: a pulse on core0 can only be ended by a deassert issued for core0, so an
# aggregate product would be wrong whenever the load is lopsided.
#
# Cross-core rather than all, because rk_mpp_rkvdec2_submit() holds the
# *submitting* core's run_lock across both its own rk_mpp_hw_power_on() and the
# group power-on inside acquire_soft_ccu(), while that core's reset runs in its
# IRQ thread under the same run_lock. A core's own submits therefore cannot
# contend with its own reset; only submits dispatched elsewhere in the group can.
# On a two-core group each core sees three deasserts per submit -- one from every
# submit's group power-on, plus one more from its own submit's direct power-on --
# and only the group power-ons from the *other* core qualify, so counting all of
# them overstates the expectation by 3x.
#
# That is not a rounding error. The 2026-08-01 run reported ~12.7 expected and
# zero observed, which reads as a decisive negative (p ~ 3e-6). The corrected
# figure was ~4.2, where a zero is a 1.5% outcome -- unusual, but nothing to
# conclude from. Overstating the power of a measurement is exactly the failure
# this harness exists to prevent, so it is computed the narrow way now.
#
# On a kernel without them the harness falls back to the *submit* rate as a
# stand-in for the deassert rate, and says so, because that is an upper bound
# rather than the real figure: rk_mpp_rkvdec2_acquire_soft_ccu() only calls
# rk_mpp_rkvdec2_power_on_ccu_cores() when the job has no power hold yet
# (`!job->rkvdec_ccu_powered_core_count`), and
# rk_mpp_rkvdec2_transfer_powered_ccu_cores() hands an existing hold to the next
# queued job on the coordinator. So a run of pipelined jobs powers the group up
# once and the rest inherit it, and the deassert rate can be far below the
# submit rate.
#
# The consequence of that fallback is asymmetric. A non-zero contention count is
# solid either way -- the overlap either happened or it did not. A zero against
# a large *upper-bound* estimate is not proof the race is unreachable, because
# the estimate may be inflated by exactly that factor. Only the measured basis
# makes a zero mean something.
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

RESET_DURATION_S=${RESET_DURATION_S:-60}
RESET_ERROR_STREAMS=${RESET_ERROR_STREAMS:-2}
RESET_SURVIVORS=${RESET_SURVIVORS:-2}
RESET_KILL=${RESET_KILL:-1}
RESET_KILL_AFTER_MS=${RESET_KILL_AFTER_MS:-120}
# Expected hits below which a zero result is treated as no measurement rather
# than as evidence. Three is enough that a zero is a ~5% outcome by chance.
RESET_MIN_EXPECT=${RESET_MIN_EXPECT:-3}
# The udelay() inside the pulse, in seconds -- the window a sibling deassert
# has to land in. Used only for the expected-hit estimate.
RESET_WINDOW_S=${RESET_WINDOW_S:-0.00001}
RESET_INPUT=${RESET_INPUT:-"$ASSETS/test_h265.h265"}
RESET_CODING=${RESET_CODING:-16777220}
DEC_BIN=${DEC_BIN:-/usr/bin/mpi_dec_test}
EXPECT=${EXPECT:-report}
COUNTER=mpp:reset_deassert_contended_count
DEBUGFS_DIR=/sys/kernel/debug/rk_mpp_rewrite
CORRUPTER="$TEST_DIR/rewrite-corrupt-stream.py"

# Exit codes: 0 pass, 1 fail, 77 skip, 78 inconclusive (no measurement).
EXIT_INCONCLUSIVE=78

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

read_counter()
{
	cat "$DEBUGFS_DIR/$1" 2>/dev/null || echo ""
}

loop_pids=""
start_loops()
{
	local count=$1
	local input=$2

	for _ in $(seq 1 "$count"); do
		(
			while :; do
				"$DEC_BIN" -i "$input" \
					-t "$RESET_CODING" -v f \
					> /dev/null 2>&1 || true
			done
		) &
		loop_pids="$loop_pids $!"
	done
}

stop_loops()
{
	local pid
	local children

	[ -n "$loop_pids" ] || return 0
	for pid in $loop_pids; do
		# Kill the loop shell first so it cannot respawn the decoder,
		# then the decoder it currently owns. `pkill -P` takes a comma
		# list, not several arguments -- passing them as arguments makes
		# everything after the first a *pattern*, which silently matches
		# nothing and leaks decoders into the next run.
		kill "$pid" 2>/dev/null || true
		children=$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')
		# shellcheck disable=SC2086
		[ -z "$children" ] || kill -9 $children 2>/dev/null || true
	done
	# shellcheck disable=SC2086
	wait $loop_pids 2>/dev/null || true
	loop_pids=""
}

trap 'stop_loops' EXIT INT TERM

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
if ! command -v python3 > /dev/null 2>&1; then
	log "SKIP: python3 is absent; it builds the corrupt stream that drives"
	log "  the reset side of this test"
	exit 77
fi
if [ ! -r "$CORRUPTER" ]; then
	log "SKIP: $CORRUPTER is absent"
	exit 77
fi
if [ ! -d "$DEBUGFS_DIR" ]; then
	log "SKIP: $DEBUGFS_DIR is absent (not a rewrite kernel?)"
	exit 77
fi
if [ -z "$(read_counter reset_deassert_contended_count)" ]; then
	log "SKIP: this kernel has no reset_deassert_contended_count counter."
	log "  It is the instrumentation this test reads; rebuild with it first."
	exit 77
fi
if [ -z "$(read_counter reset_count)" ]; then
	log "SKIP: this kernel has no reset_count counter. Without it a zero"
	log "  contention count cannot be told apart from a provocation that"
	log "  never reset anything, which is the failure this test guards."
	exit 77
fi

mkdir -p "$OUT"
log "kernel: $(uname -r)"
log "source: $(uname -v)"
log "logs:   $OUT"

CORRUPT_INPUT="$OUT/corrupt-$(basename "$RESET_INPUT")"
if ! python3 "$CORRUPTER" --input "$RESET_INPUT" \
	--output "$CORRUPT_INPUT" > "$OUT/corrupt-stream.log" 2>&1; then
	log "FAIL: could not build the corrupt stream:"
	sed 's/^/  /' "$OUT/corrupt-stream.log"
	exit 1
fi
log "corrupt stream: $(cat "$OUT/corrupt-stream.log")"

before_contended=$(read_counter reset_deassert_contended_count)
before_resets=$(read_counter reset_count)
before_dispatched=$(read_counter dispatched_job_count)
log "reset_deassert_contended_count before: $before_contended"
log "reset_count before:                    $before_resets"

suite_dmesg_start "$OUT"
debugfs_counter_snapshot "$OUT/counters-before.tsv" mpp "$DEBUGFS_DIR"

started=$(date +%s.%N)
start_loops "$RESET_ERROR_STREAMS" "$CORRUPT_INPUT"
start_loops "$RESET_SURVIVORS" "$RESET_INPUT"
log "provoking for ${RESET_DURATION_S}s: $RESET_ERROR_STREAMS error streams," \
	"$RESET_SURVIVORS survivors, kill=$RESET_KILL"

kill_cycles=0
deadline=$(awk -v s="$started" -v d="$RESET_DURATION_S" 'BEGIN{printf "%.3f", s+d}')
kill_sleep=$(awk -v ms="$RESET_KILL_AFTER_MS" 'BEGIN{print ms/1000}')
while :; do
	now=$(date +%s.%N)
	[ "$(awk -v a="$now" -v b="$deadline" 'BEGIN{print (a<b)?1:0}')" -eq 1 ] \
		|| break
	if [ "$RESET_KILL" -eq 1 ]; then
		# Kill mid-decode so the abort path resets the core while the
		# other engines are submitting and re-powering siblings.
		"$DEC_BIN" -i "$RESET_INPUT" -t "$RESET_CODING" -v f \
			> /dev/null 2>&1 &
		victim=$!
		sleep "$kill_sleep"
		kill -9 "$victim" 2>/dev/null || true
		wait "$victim" 2>/dev/null || true
		kill_cycles=$((kill_cycles + 1))
	else
		sleep 1
	fi
done
stop_loops
ended=$(date +%s.%N)
elapsed=$(awk -v a="$started" -v b="$ended" 'BEGIN{printf "%.3f", b-a}')

debugfs_counter_snapshot "$OUT/counters-after.tsv" mpp "$DEBUGFS_DIR"
debugfs_counter_delta "$OUT/counters-before.tsv" "$OUT/counters-after.tsv" \
	"$OUT/counters-delta.tsv"

after_contended=$(read_counter reset_deassert_contended_count)
after_resets=$(read_counter reset_count)
after_dispatched=$(read_counter dispatched_job_count)
delta=$((after_contended - before_contended))
resets=$((after_resets - before_resets))
dispatched=$((after_dispatched - before_dispatched))

submit_rate=$(awk -v n="$dispatched" -v t="$elapsed" \
	'BEGIN{printf "%.1f", (t>0)?n/t:0}')
deasserts=$(awk -F'\t' 'NR>1 && $2=="reset_deassert_count"{print $5}' \
	"$OUT/counters-delta.tsv")
deasserts=${deasserts:-}

# Preferred estimate: both terms measured, resolved per core, and counting only
# the deasserts that can actually contend.
#
# Not every deassert on a core is a candidate. rk_mpp_rkvdec2_submit() takes the
# *submitting* core's run_lock and holds it across both its own
# rk_mpp_hw_power_on() and the group power-on in acquire_soft_ccu(), while that
# core's reset runs in its IRQ thread under the same run_lock. So a core's own
# submits are already serialized against its own reset and can never contend --
# only submits dispatched to a *different* core in the group can. Counting all
# deasserts on a core therefore overstates the expectation, by 3x on a two-core
# group, which is enough to turn "under-powered, inconclusive" into a confident
# and wrong "real negative".
#
# Cross-core deasserts for core i = (all submits in the client's group) - (submits
# on core i), and the expectation is the per-core sum of resets * that rate * the
# pulse width.
expected=$(awk -F'\t' -v elapsed="$elapsed" -v w="$RESET_WINDOW_S" '
	NR == 1 { next }
	$2 ~ /^reset_(av1dec|rkvdec|rkvenc)_core[0-9]+_count$/ {
		key = $2; sub(/^reset_/, "", key); r[key] = $5; seen_r = 1; next
	}
	$2 ~ /^dispatched_(av1dec|rkvdec|rkvenc)_core[0-9]+_count$/ {
		key = $2; sub(/^dispatched_/, "", key); d[key] = $5
		client = key; sub(/_core[0-9]+_count$/, "", client)
		group[client] += $5
		seen_d = 1
		next
	}
	END {
		if (elapsed <= 0 || !seen_r || !seen_d) { printf ""; exit }
		total = 0
		for (k in r) {
			if (!(k in d))
				continue
			client = k; sub(/_core[0-9]+_count$/, "", client)
			cross = group[client] - d[k]
			if (cross < 0)
				cross = 0
			total += r[k] * (cross / elapsed) * w
		}
		printf "%.3f", total
	}' "$OUT/counters-delta.tsv")

if [ -n "$expected" ]; then
	expected_basis=measured
else
	# Pre-counter kernel: stand the submit rate in for the deassert rate.
	# That over-estimates, because a job inheriting a coordinator power hold
	# issues no deassert at all.
	expected=$(awk -v r="$resets" -v s="$submit_rate" -v w="$RESET_WINDOW_S" \
		'BEGIN{printf "%.3f", r*s*w}')
	expected_basis=upper-bound
fi

log "elapsed:      ${elapsed}s (kill cycles: $kill_cycles)"
log "resets:       $resets"
log "submits:      $dispatched (${submit_rate}/s)"
log "deasserts:    ${deasserts:-unavailable}"
if [ "$expected_basis" = measured ]; then
	log "expected hits: ~$expected  (per core: resets * deassert rate *" \
		"${RESET_WINDOW_S}s)"
else
	log "expected hits: <=$expected  (resets * submit rate * ${RESET_WINDOW_S}s)"
	log "  UPPER BOUND: this kernel has no reset_deassert_count, so submits"
	log "  stand in for sibling deasserts and a job that inherits a power"
	log "  hold issues none. The true figure is lower by an unmeasured"
	log "  factor -- build a kernel carrying the deassert counter to close"
	log "  this, or a zero below proves nothing."
fi
log "reset_deassert_contended_count after:  $after_contended (delta $delta)"

status=0
if ! suite_dmesg_finish "$OUT"; then
	log "FAIL: kernel log reported a fatal pattern (see $OUT/dmesg-fatal.txt)"
	status=1
fi

{
	printf 'counter\tbefore\tafter\tdelta\texpect\n'
	printf '%s\t%s\t%s\t%s\t%s\n' "$COUNTER" "$before_contended" \
		"$after_contended" "$delta" "$EXPECT"
	printf 'mpp:reset_count\t%s\t%s\t%s\t\n' "$before_resets" \
		"$after_resets" "$resets"
	printf 'mpp:dispatched_job_count\t%s\t%s\t%s\t\n' "$before_dispatched" \
		"$after_dispatched" "$dispatched"
	printf 'mpp:reset_deassert_count\t\t\t%s\t\n' "${deasserts:-}"
	printf 'derived:elapsed_s\t\t\t%s\t\n' "$elapsed"
	printf 'derived:submit_rate_hz\t\t\t%s\t\n' "$submit_rate"
	printf 'derived:expected_hits\t\t\t%s\t\n' "$expected"
	printf 'derived:expected_basis\t\t\t%s\t\n' "$expected_basis"
} > "$OUT/summary.tsv"

# A zero contention count is only evidence if the run had the power to produce
# a non-zero one. Decide that first, for every mode.
underpowered=0
if [ "$resets" -eq 0 ]; then
	underpowered=1
elif [ "$(awk -v e="$expected" -v m="$RESET_MIN_EXPECT" \
	'BEGIN{print (e<m)?1:0}')" -eq 1 ]; then
	underpowered=1
fi

if [ "$delta" -eq 0 ] && [ "$underpowered" -eq 1 ] && [ "$EXPECT" != report ]; then
	log "INCONCLUSIVE: this run could not have measured the race."
	if [ "$resets" -eq 0 ]; then
		log "  No reset happened at all ($resets resets in ${elapsed}s), so"
		log "  the contention counter had nothing to contend with. The"
		log "  reset side of the provocation is dead -- check that the"
		log "  corrupt stream still reaches the hardware error path."
	else
		log "  Expected hits ~$expected is under RESET_MIN_EXPECT="
		log "  $RESET_MIN_EXPECT, so a zero is the likely outcome even if"
		log "  the race is fully reachable."
	fi
	log "  Raise RESET_DURATION_S (now $RESET_DURATION_S),"
	log "  RESET_ERROR_STREAMS (now $RESET_ERROR_STREAMS) or"
	log "  RESET_SURVIVORS (now $RESET_SURVIVORS) and re-run."
	log "================= result ================="
	log "logs: $OUT"
	exit "$EXIT_INCONCLUSIVE"
fi

case "$EXPECT" in
contended)
	if [ "$delta" -gt 0 ]; then
		log "PASS: race reproduced ($delta overlaps) -- reachable here"
	else
		log "FAIL: no overlap in $resets resets, where ~$expected were"
		log "  expected ($expected_basis basis)."
		if [ "$expected_basis" = measured ]; then
			log "  Both terms were measured and only cross-core deasserts"
			log "  were counted, so this is a real negative for this"
			log "  workload: either the fix is already in this kernel, or"
			log "  the race is not reachable in this configuration."
			log "  Before concluding the latter, confirm the expectation"
			log "  is comfortably above RESET_MIN_EXPECT -- a zero against"
			log "  ~4 is a 1-in-70 outcome, not a proof."
		else
			log "  NOT evidence that the race is unreachable: that"
			log "  estimate is an upper bound built from the submit rate,"
			log "  and the deassert rate it stands in for is lower by an"
			log "  unmeasured factor, because a job inheriting a"
			log "  coordinator power hold deasserts nothing. Re-run on a"
			log "  kernel carrying reset_deassert_count before concluding"
			log "  anything from this zero."
		fi
		status=1
	fi
	;;
clean)
	if [ "$delta" -eq 0 ]; then
		log "PASS: no overlap in $resets resets, where ~$expected were"
		log "  expected ($expected_basis basis)"
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
