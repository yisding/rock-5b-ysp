#!/usr/bin/env bash
# Controlled crash-capture for the MPP VP9 show_existing_frame NULL-deref.
#
# Reproduces the leg-2/leg-3 crash (see
# ../../findings/2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md)
# by decoding the show_existing_frame conformance vector on the RK3588 HW
# decoder via mpi_dec_test, in a loop and with concurrent instances to hit the
# reference-buffer / session-teardown race.
#
# REQUIRES panic_on_oops=0 so a process-context oops prints its full call trace
# to the kernel log and the board survives long enough for journald to drain it
# (this KASAN debug kernel ships panic_on_oops=1 + panic=10, which reboots
# before the trace lands — that is why no trace has survived). Set it with:
#   sudo sysctl -w kernel.panic_on_oops=0
#
# The full call trace is the deliverable: it names the exact faulting function
# the 0053/0054 guards missed.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Only for SUITE_DMESG_FATAL_RE. The private pattern this replaced missed every
# RK3588 IOMMU/RGA fault line and matched `debug:` via a bare `BUG:` and
# `ramoops` via a bare `Oops`.
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
: "${SUITE_DMESG_FATAL_RE:?suite-common.sh did not load; the kernel-log fatal scan would be silently blind}"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT="${CONFORMANCE_ROOT:-$ROCK5B_WORKSPACE/build/rockchip-conformance}"
# shellcheck source=kasan-scan.sh disable=SC1091
source "$TEST_DIR/kasan-scan.sh"

# The show_existing_frame conformance vector is tracked under the conformance
# assets; override with IVF=... to point at another copy.
IVF="${IVF:-$CONFORMANCE_ROOT/assets/vp9-show-existing.ivf}"
OUT="${OUT:-$CONFORMANCE_ROOT/logs/forward-port/$(date +%Y%m%d-%H%M%S)-vp9-show-existing}"
LOOPS="${LOOPS:-30}"
CONCURRENCY="${CONCURRENCY:-4}"
VP9_TYPE=10

[ -f "$IVF" ] || { echo "missing VP9 ES: $IVF" >&2; exit 2; }

poo=$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null || echo '?')
echo "panic_on_oops=$poo (need 0 to capture the trace instead of rebooting)"
if [ "$poo" != "0" ]; then
	echo "REFUSING to run: set 'sudo sysctl -w kernel.panic_on_oops=0' first." >&2
	exit 3
fi

mkdir -p "$OUT"
decoder_ok=0
decoder_fail=0
decoder_pids=()
kasan_scan_begin "$OUT"
echo "capture start -> $OUT  (loops=$LOOPS concurrency=$CONCURRENCY)"

for i in $(seq 1 "$LOOPS"); do
	# Fire a burst of concurrent decoders of the show_existing vector, then
	# let them all exit together (session teardown storm = the race window).
	for c in $(seq 1 "$CONCURRENCY"); do
		timeout 20 mpi_dec_test -t "$VP9_TYPE" -i "$IVF" -n 16 \
			> "$OUT/dec-$i-$c.log" 2>&1 &
		decoder_pids+=("$!")
	done
	# Count decoders that actually ran. Without this the gate asserts only "no
	# flagged kernel lines", so a run where every decode failed (missing
	# mpi_dec_test, no PATH under the orchestrator, unreadable asset) printed
	# "PASS: no flagged kernel lines" -- a stronger claim than an empty run
	# supports. Its two siblings already gate on suite status AND cleanliness.
	for pid in "${decoder_pids[@]}"; do
		if wait "$pid"; then
			decoder_ok=$((decoder_ok + 1))
		else
			decoder_fail=$((decoder_fail + 1))
		fi
	done
	decoder_pids=()
	# Abort early if the oops already fired (KASAN/BUG in the window so far).
	if journalctl -k --after-cursor "$(cat "$OUT/journal-cursor.txt")" 2>/dev/null \
		| grep -aiqE "$SUITE_DMESG_FATAL_RE"; then
		echo "fault signature appeared at loop $i — stopping to preserve the trace"
		break
	fi
	printf 'loop %d/%d done\n' "$i" "$LOOPS"
done

# Give any deferred async worker time to fire (the finding saw ~47 s deferral).
echo "waiting 60s for deferred async fault..."
for s in $(seq 1 60); do
	if journalctl -k --after-cursor "$(cat "$OUT/journal-cursor.txt")" 2>/dev/null \
		| grep -aiqE "$SUITE_DMESG_FATAL_RE"; then
		echo "deferred fault appeared after ${s}s"
		break
	fi
	sleep 1
done

flags=$(kasan_scan_end "$OUT") && clean=1 || clean=0
echo "RESULT flagged_kernel_lines=$flags clean=$clean out=$OUT"
echo "===== captured fault trace (if any) ====="
awk '/Unable to handle kernel|KASAN|BUG:|Oops|rk_vcodec/{p=1} p' "$OUT/kernel-log-during.txt" 2>/dev/null | head -120

# The awk pipeline above used to be the last command, so IT decided the exit
# status: a captured oops printed a trace and exited 0, while a clean run with no
# log file exited 2. `clean` was computed and only printed. Gate on it explicitly.
echo "decoders: $decoder_ok ok, $decoder_fail failed"
if [ "$clean" != "1" ]; then
	echo ">>> FAIL: $flags flagged kernel line(s) during the run — see $OUT"
	exit 1
fi
if [ "$decoder_ok" -eq 0 ]; then
	echo ">>> FAIL: no decoder run succeeded, so the show_existing_frame path was"
	echo "    never driven — a clean kernel log proves nothing here. See $OUT/dec-*.log"
	exit 1
fi
echo ">>> PASS: $decoder_ok decode runs drove the path, no flagged kernel lines"
