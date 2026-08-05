#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Validate the rkvdec2 reset-domain lock (b37f6e9825b1) on a booted kernel.
#
# This runs the verification gate from the sibling reset-deassert race finding,
# in the order that order actually matters, and it is RESUMABLE -- because two
# of its six phases can hard-wedge the board, and a wedge must cost a reboot
# rather than the whole run.
#
#   P0  identity      the booted kernel really carries the lock commit
#   P1  kunit         the boot's KUnit suites are green and lockdep is alive
#   P2  irq-bits      sample INT_STA for softreset_rdy / dec_bus_sta / dec_rdy
#   P3  perturbation  decode/encode still work and timings have not moved
#   P4  clean         *** the fix verification: contention must be zero ***
#   P5  wedge         does the two-stream provocation still wedge the board?
#
# P0-P3 are safe. P4 runs the workload that produced 2 contention hits per 60 s
# on the pre-lock kernel, and roughly one run in three of that workload wedged
# the board; P5 exists only to repeat it. So the safe phases run first, the
# load-bearing result (P4) runs next, and the deliberately-risky repetition
# runs last where a wedge costs nothing that has not already been recorded.
#
# Every phase syncs its verdict to disk before the next one starts. If the
# board wedges, reboot and re-run the same command: completed phases are
# skipped and the run picks up where it stopped.
#
#   sudo bash kernel-drivers/tests/rewrite-reset-lock-gate.sh
#   sudo FORCE=1 bash ...        # redo everything, ignoring recorded verdicts
#   sudo SKIP_WEDGE=1 bash ...   # stop after P4, do not provoke a wedge
#   sudo WEDGE_RUNS=8 bash ...   # more repetitions in P5 (default 4)
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
: "${SUITE_DMESG_FATAL_RE:?suite-common.sh did not load; the kernel-log fatal scan would be silently blind}"

ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/build/rockchip-conformance"}
STATE=${STATE:-"$CONFORMANCE_ROOT/logs/rewrite/lock-gate"}

# The commit under test. The build stamps ` g<sha12>` into uname -v, which is
# the only identity that survives into a booted kernel -- the release string
# cannot carry it (Armbian derives kernel_version_family independently).
LOCK_SHA=${LOCK_SHA:-gb37f6e9825b1}

DEBUGFS_DIR=/sys/kernel/debug/rk_mpp_rewrite
FORCE=${FORCE:-0}
SKIP_WEDGE=${SKIP_WEDGE:-0}
WEDGE_RUNS=${WEDGE_RUNS:-4}
CONTENTION="$TEST_DIR/rewrite-reset-contention.sh"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

# A phase verdict is a file, fsynced, so a hard reset cannot lose it.
verdict_file() { printf '%s/%s.verdict' "$STATE" "$1"; }

record()
{
	local phase=$1 result=$2
	shift 2
	printf '%s\t%s\t%s\n' "$result" "$(date -Is)" "$*" \
		> "$(verdict_file "$phase")"
	sync -d "$(verdict_file "$phase")" 2>/dev/null || sync
}

done_already()
{
	local phase=$1 f
	f=$(verdict_file "$phase")
	[ "$FORCE" = 0 ] || return 1
	[ -f "$f" ] || return 1
	case "$(cut -f1 "$f")" in
	PASS|SKIP) return 0 ;;
	*) return 1 ;;
	esac
}

if [ "$(id -u)" -ne 0 ]; then
	log "SKIP: needs root -- debugfs is 0700 and dmesg is restricted"
	exit 77
fi
mkdir -p "$STATE"

log "state: $STATE  (delete it, or FORCE=1, to start over)"

# ---------------------------------------------------------------- P0 identity
# Everything below is meaningless if this is not the kernel we think it is.
# This has bitten before, which is why the build stamps a SHA at all.
if done_already p0-identity; then
	log "P0 identity: already PASS, skipping"
else
	log "P0 identity: checking for $LOCK_SHA in uname -v"
	log "  release: $(uname -r)"
	log "  source:  $(uname -v)"
	if uname -v | grep -q "$LOCK_SHA"; then
		record p0-identity PASS "$(uname -v)"
		log "P0 identity: PASS"
	else
		record p0-identity FAIL "$(uname -v)"
		log "P0 identity: FAIL -- booted kernel does not carry $LOCK_SHA."
		log "  Nothing below would mean anything. Install the lock deb and"
		log "  reboot before re-running:"
		log "    sudo RECOVERY_READY=1 PHASH='Pd0d0-Cad24' bash \\"
		log "      kernel-drivers/scripts/install-kernel.sh"
		exit 1
	fi
fi

# ------------------------------------------------------------------- P1 kunit
if done_already p1-kunit; then
	log "P1 kunit: already PASS, skipping"
else
	log "P1 kunit: checking the boot's KUnit suites"
	if bash "$TEST_DIR/rewrite-kunit-log-check.sh" > "$STATE/p1-kunit.log" 2>&1; then
		record p1-kunit PASS "suites green"
		log "P1 kunit: PASS"
	else
		rc=$?
		record p1-kunit FAIL "exit $rc -- see p1-kunit.log"
		log "P1 kunit: FAIL (exit $rc). Tail:"
		tail -20 "$STATE/p1-kunit.log" | sed 's/^/  /'
		log "  A red KUnit boot invalidates the rest. Stopping."
		exit 1
	fi
fi

# ---------------------------------------------------------------- P2 irq bits
# Free measurement of the hardware self-reset question: the driver already
# records every IRQ's raw INT_STA into the 64-entry debug ring, so no counter
# commit is needed. The ring wraps fast under provocation, so this samples.
if done_already p2-irqbits; then
	log "P2 irq-bits: already done, skipping"
elif [ ! -d "$DEBUGFS_DIR" ]; then
	record p2-irqbits SKIP "no $DEBUGFS_DIR"
	log "P2 irq-bits: SKIP (no rewrite debugfs)"
else
	log "P2 irq-bits: sampling INT_STA over a 5s provocation"
	prev_mask=$(cat "$DEBUGFS_DIR/trace_mask" 2>/dev/null || echo 0)
	echo 2 > "$DEBUGFS_DIR/trace_mask" 2>/dev/null || true
	RESET_DURATION_S=5 EXPECT=report bash "$CONTENTION" \
		> "$STATE/p2-provoke.log" 2>&1 || true
	cat "$DEBUGFS_DIR/events" > "$STATE/p2-events.txt" 2>/dev/null || true
	echo "$prev_mask" > "$DEBUGFS_DIR/trace_mask" 2>/dev/null || true

	bits=$(awk '$3 == "irq" {
			n++; v = strtonum($11)
			if (int(v / 512) % 2) sr++
			if (int(v / 8)   % 2) bus++
			if (int(v / 4)   % 2) rdy++
			if (int(v / 8) % 2 && int(v / 4) % 2) both++
		}
		END { printf "irq=%d softreset_rdy=%d dec_bus=%d dec_rdy=%d bus_with_rdy=%d",
			     n+0, sr+0, bus+0, rdy+0, both+0 }' \
		"$STATE/p2-events.txt" 2>/dev/null)
	record p2-irqbits PASS "$bits"
	log "P2 irq-bits: $bits"
	log "  softreset_rdy>0 confirms the hardware self-reset (TRM SWREG224 bit 9)."
	log "  dec_bus>0 is the AXI-error bit that sits outside our 0xf0 err_mask;"
	log "  bus_with_rdy decides whether widening the mask is safe."
fi

# ----------------------------------------------------------- P3 perturbation
# A leaf lock on the submit path must not move decode/encode timings. This is
# also the ordinary liveness check: the lock kernel has never decoded anything.
if done_already p3-perturbation; then
	log "P3 perturbation: already PASS, skipping"
else
	log "P3 perturbation: decode/encode/transcode smoke + timing counters"
	if bash "$TEST_DIR/rewrite-smoke.sh" > "$STATE/p3-smoke.log" 2>&1; then
		record p3-perturbation PASS "rewrite-smoke clean"
		log "P3 perturbation: PASS"
	else
		rc=$?
		if [ "$rc" -eq 77 ]; then
			record p3-perturbation SKIP "device nodes absent"
			log "P3 perturbation: SKIP (exit 77)"
		else
			record p3-perturbation FAIL "exit $rc -- see p3-smoke.log"
			log "P3 perturbation: FAIL (exit $rc). Tail:"
			tail -20 "$STATE/p3-smoke.log" | sed 's/^/  /'
			log "  Continuing anyway: P4 is the load-bearing result and a"
			log "  smoke failure does not invalidate it."
		fi
	fi
	grep -E 'hw_total_ns|hw_max_ns' "$STATE/p3-smoke.log" 2>/dev/null \
		| head -8 | sed 's/^/  /'
fi

# ------------------------------------------------------------------- P4 clean
# The fix verification. Same workload that produced 2 hits per 60 s twice on
# the pre-lock kernel; EXPECT=clean fails the run on any non-zero delta.
if done_already p4-clean; then
	log "P4 clean: already PASS, skipping"
else
	log "P4 clean: *** fix verification -- contention must be zero ***"
	log "  This is the workload that wedged the board roughly 1 run in 3"
	log "  before the lock. If the board dies here, reboot and re-run."
	sync
	EXPECT=clean bash "$CONTENTION" 2>&1 | tee "$STATE/p4-clean.log"
	rc=${PIPESTATUS[0]}
	# Take the run directory from the harness's own "logs:" line rather than
	# globbing for the newest: a concurrent run would make the glob pick the
	# wrong summary, and this run's identity is already in the log.
	run_dir=$(awk '$2 == "logs:" {print $3}' "$STATE/p4-clean.log" | tail -1)
	contended=$(awk -F'\t' '$1 == "mpp:reset_deassert_contended_count" {print $4}' \
		"$run_dir/summary.tsv" 2>/dev/null)
	case "$rc" in
	0)
		record p4-clean PASS "contended=${contended:-0}"
		log "P4 clean: PASS -- contention delta ${contended:-0}"
		;;
	78)
		record p4-clean INCONCLUSIVE "exit 78, contended=${contended:-?}"
		log "P4 clean: INCONCLUSIVE (exit 78) -- the run lacked the power"
		log "  to produce a non-zero, so a zero proves nothing. Re-run."
		;;
	*)
		record p4-clean FAIL "exit $rc, contended=${contended:-?}"
		log "P4 clean: FAIL (exit $rc, contended=${contended:-?})"
		log "  A non-zero here means the lock did not serialize what it"
		log "  was supposed to. That is a real regression, not noise."
		;;
	esac
fi

# ------------------------------------------------------------------- P5 wedge
if [ "$SKIP_WEDGE" != 0 ]; then
	log "P5 wedge: skipped by SKIP_WEDGE=$SKIP_WEDGE"
elif done_already p5-wedge; then
	log "P5 wedge: already done, skipping"
else
	log "P5 wedge: $WEDGE_RUNS repetitions of the two-stream provocation"
	log "  Purpose: the lock closes the sibling power-on deassert but cannot"
	log "  touch the hard-IRQ MMIO candidate. If the board still wedges, the"
	log "  wedge is the second mechanism and the two bugs are separate."
	survived=0
	for i in $(seq 1 "$WEDGE_RUNS"); do
		# Record the attempt BEFORE running it, so a wedge is visible as
		# an attempt with no completion rather than as a run that never
		# happened.
		printf 'attempt %d of %d started %s\n' "$i" "$WEDGE_RUNS" "$(date -Is)" \
			>> "$STATE/p5-attempts.txt"
		sync -d "$STATE/p5-attempts.txt" 2>/dev/null || sync
		log "  wedge run $i/$WEDGE_RUNS"
		EXPECT=report bash "$CONTENTION" \
			> "$STATE/p5-run$i.log" 2>&1 && survived=$((survived + 1))
		printf 'attempt %d of %d completed %s\n' "$i" "$WEDGE_RUNS" "$(date -Is)" \
			>> "$STATE/p5-attempts.txt"
		sync -d "$STATE/p5-attempts.txt" 2>/dev/null || sync
	done
	record p5-wedge PASS "survived $survived/$WEDGE_RUNS"
	log "P5 wedge: survived $survived/$WEDGE_RUNS runs"
fi

# ------------------------------------------------------------------- summary
echo
log "================= summary ================="
for phase in p0-identity p1-kunit p2-irqbits p3-perturbation p4-clean p5-wedge; do
	f=$(verdict_file "$phase")
	if [ -f "$f" ]; then
		printf '  %-16s %s\n' "$phase" "$(cut -f1,3 "$f" | tr '\t' ' ')"
	else
		printf '  %-16s (not run)\n' "$phase"
	fi
done
log "logs: $STATE"

# The gate's verdict is P4's. Everything else is context.
p4=$(cut -f1 "$(verdict_file p4-clean)" 2>/dev/null || echo MISSING)
[ "$p4" = PASS ] || exit 1
exit 0
