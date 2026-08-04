#!/usr/bin/env bash
# Run ordered MPP decode-case pairs to surface sequence-dependent wedges that a
# single fixed case order hides.
#
# Retro item 2 (2026-07-30): all three soft-CCU wedges were order-dependent
# (mpi_dec_mt_h264 -> mpi_dec_h265 wedged; either case alone passed). The
# standard suite runs one fixed order and cannot find these. This driver runs
# every ordered pair from a case set as its own two-case mpp-suite invocation,
# persisting progress after each pair with sync() so that when a pair wedges
# the board, the matrix TSV on disk names the exact predecessor->successor
# ordering that triggered it (the wedge itself leaves no trace; the surrounding
# record does). Best paired with pm-stress-knobs.sh apply, which collapses the
# autosuspend window the wedge class hides in.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/build/rockchip-conformance"}
PROFILE=${PROFILE:-rewrite}
RUN_ID=${RUN_ID:-$(date +%Y%m%d-%H%M%S)}
LOG_ROOT=${LOG_ROOT:-"$CONFORMANCE_ROOT/logs/$PROFILE"}
MATRIX_OUT=${MATRIX_OUT:-"$LOG_ROOT/$RUN_ID-case-pair-matrix"}
MATRIX_TSV=${MATRIX_TSV:-"$MATRIX_OUT/matrix.tsv"}

# Cases that exercise the soft-CCU decode path. Both mt (both cores busy) and
# single-threaded (one core) variants are included because the wedge needs a
# multi-core session to leave a sibling registered, then a following session to
# poke it.
PAIR_CASES=${PAIR_CASES:-"mpi_dec_mt_h264 mpi_dec_h265 mpi_dec_h264 mpi_dec_mt_h265 mpi_dec_vp9 mpi_dec_avs2"}
# Include A,A identity pairs as controls (a case that wedges only after itself
# is still a finding). Off by default to keep the matrix to distinct orderings.
PAIR_INCLUDE_IDENTITY=${PAIR_INCLUDE_IDENTITY:-0}
# Optional idle seconds inserted between the two cases of a pair, for the
# natural-timing (unstressed) control. With pm-stress applied the window is
# already collapsed, so the default is no gap.
PAIR_GAP_S=${PAIR_GAP_S:-0}
VALIDATE_ONLY=${VALIDATE_ONLY:-0}

emit_pairs()
{
	local a b
	for a in $PAIR_CASES; do
		for b in $PAIR_CASES; do
			if [ "$a" = "$b" ] && [ "$PAIR_INCLUDE_IDENTITY" != "1" ]; then
				continue
			fi
			printf "%s\t%s\n" "$a" "$b"
		done
	done
}

if [ "$VALIDATE_ONLY" = "1" ]; then
	# Device-free: prove pair enumeration and that mpp-suite is reachable.
	pairs=$(emit_pairs | wc -l | tr -d '[:space:]')
	if [ "$pairs" -lt 2 ]; then
		echo "pair matrix: too few pairs from PAIR_CASES" >&2
		exit 1
	fi
	if [ ! -x "$TEST_DIR/mpp-suite.sh" ] && [ ! -r "$TEST_DIR/mpp-suite.sh" ]; then
		echo "pair matrix: mpp-suite.sh not found beside this script" >&2
		exit 1
	fi
	printf "case-pair matrix validation passed (%s pairs)\n" "$pairs"
	exit 0
fi

mkdir -p "$MATRIX_OUT"
{
	printf "run_id\t%s\n" "$RUN_ID"
	printf "profile\t%s\n" "$PROFILE"
	printf "gap_s\t%s\n" "$PAIR_GAP_S"
	printf "# first_case\tsecond_case\tstatus\n"
} > "$MATRIX_TSV"
sync

index=0
while IFS=$'\t' read -r first second; do
	index=$((index + 1))
	pair_out="$MATRIX_OUT/$(printf '%03d' "$index")-${first}__${second}"

	# Record the pair as "started" and sync BEFORE running: if this pair
	# wedges the board, the started row is what survives the reset and names
	# the killer ordering.
	printf "%s\t%s\tstarted\n" "$first" "$second" >> "$MATRIX_TSV"
	sync
	printf "PROGRESS pair %s: %s -> %s\n" "$index" "$first" "$second"

	if [ "$PAIR_GAP_S" != "0" ]; then
		# Natural-timing control: run the two cases as separate suite
		# invocations with an idle gap, so the autosuspend timer fires
		# between them.
		rc=0
		env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			OUT="$pair_out-a" MPP_REQUIRED_CASES="$first" \
			bash "$TEST_DIR/mpp-suite.sh" || rc=$?
		sleep "$PAIR_GAP_S"
		if [ "$rc" -eq 0 ]; then
			env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
				OUT="$pair_out-b" MPP_REQUIRED_CASES="$second" \
				bash "$TEST_DIR/mpp-suite.sh" || rc=$?
		fi
	else
		# Stressed/back-to-back: one invocation, ordered pair. The
		# cross-session boundary inside the run is the trigger.
		rc=0
		env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			OUT="$pair_out" MPP_REQUIRED_CASES="$first $second" \
			bash "$TEST_DIR/mpp-suite.sh" || rc=$?
	fi

	# Rewrite the started row to its outcome (pass = rc 0, fail otherwise).
	if [ "$rc" -eq 0 ]; then
		outcome=pass
	else
		outcome="fail:$rc"
	fi
	sed -i "s#^${first}\t${second}\tstarted\$#${first}\t${second}\t${outcome}#" \
		"$MATRIX_TSV"
	sync
	printf "PROGRESS pair %s: %s -> %s = %s\n" "$index" "$first" "$second" "$outcome"
done < <(emit_pairs)

fails=$(awk -F '\t' '$3 ~ /^fail/ { n++ } END { print n + 0 }' "$MATRIX_TSV")
printf "case-pair matrix complete: %s pairs, %s failed; matrix=%s\n" \
	"$index" "$fails" "$MATRIX_TSV"
[ "$fails" -eq 0 ]
