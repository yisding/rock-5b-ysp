#!/usr/bin/env bash
# =============================================================================
# run-root-gates.sh -- run the forward-port test gates that require root.
#
# These are the gates the unprivileged campaign skips because they write
# /dev/kmsg markers, read dmesg (dmesg_restrict=1), touch debugfs, or self-check
# `id -u`. Run the unprivileged battery first (decode-differential, kasan-mpp-
# suite, librga-smoke, ffmpeg-suite); this
# script covers what's left.
#
#   sudo bash kernel-drivers/tests/run-root-gates.sh
#
# Each gate is run with its output captured under $OUT and a per-gate kernel-log
# scan (journalctl cursor) for KASAN/BUG/Oops/UAF/OOB/WARN/iommu-fault. A gate is
# PASS iff it exits 0 AND its kernel-log window is clean.
#
# ffmpeg: this forces the hardware-accelerated distro build /usr/bin/ffmpeg
# (8.0.3-rk1, rkmpp+rkrga) for every ffmpeg-consuming gate, so a linuxbrew (or
# any other) ffmpeg on PATH is bypassed. Override with FFMPEG=/path/to/ffmpeg.
#
# The VP9 show_existing_frame gate (mpp-vp9-show-existing-repro.sh) runs last, by
# default. It drives the show_existing_frame path that once NULL-deref'd and
# hard-locked this board; that crash is fixed (0053/0058), so it is now a normal
# regression gate rather than an opt-in. It still sets kernel.panic_on_oops=0 for
# its window so a would-be process-context oops prints a trace instead of
# rebooting.
# =============================================================================
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT="${CONFORMANCE_ROOT:-$ROCK5B_WORKSPACE/rockchip-conformance}"

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root:  sudo bash $0 $*" >&2
	exit 1
fi

# --- hardware ffmpeg (bypass linuxbrew / PATH) -------------------------------
FFMPEG="${FFMPEG:-/usr/bin/ffmpeg}"
if [ ! -x "$FFMPEG" ] || ! "$FFMPEG" -hide_banner -hwaccels 2>/dev/null | grep -q rkmpp; then
	echo "ERROR: $FFMPEG is missing or has no rkmpp hwaccel. Set FFMPEG=..." >&2
	exit 1
fi
echo "ffmpeg (hw): $("$FFMPEG" -hide_banner -version 2>/dev/null | head -1)"

for a in "$@"; do
	case "$a" in
	-h|--help) sed -n '2,34p' "$0"; exit 0 ;;
	*) echo "unknown arg: $a" >&2; exit 2 ;;
	esac
done

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$CONFORMANCE_ROOT/logs/forward-port/${TS}-root-gates}"
mkdir -p "$OUT"
echo "OUT: $OUT"
echo "kernel: $(uname -r)  build: $(cat /proc/mpp_service/version 2>/dev/null)"

# NB: \bBUG: (word boundary), not bare BUG: — the scan runs case-insensitively
# and a bare BUG: matches the "de(bug:)" in gate markers like "rga-mmu-debug:".
# \bOops for the same reason: bare Oops matches "pstore.backend=ramoops".
#
# 2026-07-24: the iommu alternative alone could not match this board's two real
# fault signatures — "rk_iommu …: Page fault at …" (alphanumerics between
# "iommu" and "fault") and "RGA IOMMU: read fault!" (a word between them) — so a
# gate could report kernel_flags=0 through a burst of RGA IOMMU faults.  Added
# the optional intr/read/write group plus explicit "Page fault at"/"bus error".
# Byte-identical to SUITE_DMESG_FATAL_RE in suite-common.sh (this script stays
# standalone deliberately: it must run as root without sourcing the suite
# helpers, so the set is duplicated).  That identity is enforced by
# scripts/tests/test_repo_checks.py — the copies had already drifted apart once,
# losing KCSAN, lockdep, DMA-API, the atomic-sleep pair, and the rga/mpp fault
# alternatives, so "change both together" is no longer left to discipline.
FATAL_RE='KASAN|KCSAN|UBSAN|KFENCE|\bBUG:|kernel BUG|\bOops|Unable to handle kernel|use-after-free|slab-out-of-bounds|out-of-bounds|general protection fault|hung task|blocked for more than|RCU stall|lockdep|DEBUG_LOCKS|trying to register non-static key|turning off the locking correctness validator|WARNING:|DMA-API.*(error|WARNING)|refcount_t:|list_[a-z_]* corruption|scheduling while atomic|sleeping function called|Page fault at|iommu[^[:alnum:]]*(intr|read|write)?[^[:alnum:]]*(fault|panic|oops)|bus error|rga[^[:alnum:]]*(fault|panic)|mpp[^[:alnum:]]*(fault|panic)'

SUMMARY="$OUT/summary.tsv"
printf 'gate\texit\tkernel_flags\tresult\n' > "$SUMMARY"

# run_gate <label> <env-assignments...> -- <command...>
run_gate() {
	local label="$1"; shift
	local -a envs=()
	while [ "$1" != "--" ]; do envs+=("$1"); shift; done
	shift # drop --
	local log="$OUT/${label}.log"
	local klog="$OUT/${label}.kernel.txt"
	local cur
	cur="$(journalctl -k -n1 --show-cursor 2>/dev/null | tail -1 | sed 's/-- cursor: //')"
	# Write our own marker immediately after taking the cursor, so the post-gate
	# read can tell a genuinely quiet window (marker present, nothing else) from a
	# broken one (marker absent). Without it, both look like "-- No entries --".
	local marker
	marker="ROOTGATE-${label}-$$-$(date -u +%H%M%S%N)"
	if ! echo "=== ${marker} ===" > /dev/kmsg 2>/dev/null; then
		echo "  FATAL: cannot write /dev/kmsg, so the per-gate window cannot be"
		echo "  validated. This script requires root; check it is actually running as"
		echo "  root and that /dev/kmsg is writable."
		printf '%s\t%s\t%s\t%s\n' "$label" "-" "-" "FAIL" | tee -a "$SUMMARY"
		echo
		return 1
	fi
	# An empty or unusable cursor makes the post-gate window empty, so the
	# "kernel-log window is clean" half of the documented PASS rule is satisfied
	# vacuously. That happens when journalctl prints "-- No entries --", when it
	# is missing, or when the kernel journal is unreadable. Fail loudly instead:
	# these gates exist to catch kernel faults.
	if [ -z "$cur" ] || ! journalctl -k --after-cursor "$cur" -n0 --no-pager >/dev/null 2>&1; then
		echo "  FATAL: cannot obtain a usable kernel-journal cursor -- the per-gate"
		echo "  fatal scan would read an empty window and report every gate clean."
		echo "  Check journalctl -k works as this user (persistent journal, group access)."
		# Record the row. Returning without one made the gate absent from
		# summary.tsv, and the verdict counts rows -- so a single gate failing
		# this probe still printed "ALL ROOT GATES PASS" with everything else
		# green, which is the outcome this whole check exists to prevent.
		printf '%s\t%s\t%s\t%s\n' "$label" "-" "-" "FAIL" | tee -a "$SUMMARY"
		echo
		return 1
	fi

	echo "==================== $label ===================="
	# A gate can wedge on a kernel-side D-state hang (e.g. the rkrga/mm_session
	# UAF, findings/2026-07-22-rga-mm-session-debugfs-uaf-freed-task-struct.md).
	# timeout lets the wrapper detach and run the remaining gates -- but note a
	# D-state task survives SIGKILL, so the orphan lingers until reboot.
	# Redirect stdin from /dev/null: a gate child that reads the terminal
	# (e.g. ffmpeg's interactive control) would otherwise take SIGTTIN and stop
	# (state T) when this script isn't the foreground process group -- as happens
	# when launched via the Claude Code `!` prefix -- silently stalling the gate.
	timeout --signal=KILL "${GATE_TIMEOUT:-900}" \
		env "${envs[@]}" "$@" >"$log" 2>&1 </dev/null
	local ec=$?
	[ "$ec" -eq 137 ] && echo "  (gate hit GATE_TIMEOUT=${GATE_TIMEOUT:-900}s and was killed; a D-state kernel hang may persist until reboot)"

	# Settle before reading: a fault printed as the gate exits can otherwise miss
	# the window (kasan-scan.sh syncs, encode-test-tiny sleeps 1).
	sync
	journalctl -k --after-cursor "$cur" --no-pager >"$klog" 2>/dev/null
	# The window must contain our marker. A well-formed but unresolvable cursor
	# makes journalctl exit 0 and print "-- No entries --"; a cursor whose entry
	# rotates out *during* the gate does the same (gate 3 floods the log with RGA
	# timing lines). Either way the fatal scan reads nothing and the gate would
	# pass its kernel-log half blind -- which the pre-gate probe cannot detect.
	# Checking for the marker rather than for emptiness keeps a legitimately quiet
	# window (marker present, nothing else) a PASS.
	if ! grep -qF -- "$marker" "$klog"; then
		echo "  FATAL: the post-gate kernel-log window does not contain this gate's own"
		echo "  marker, so the fatal scan proves nothing. The cursor was unresolvable or"
		echo "  its entry rotated out of the journal during the gate."
		printf '%s\t%s\t%s\t%s\n' "$label" "$ec" "-" "FAIL" | tee -a "$SUMMARY"
		echo
		return 1
	fi
	local flags
	flags=$(grep -icE "$FATAL_RE" "$klog")

	# Exit 77 is the conventional "skipped" code (e.g. mpp-debug-capture when the
	# rewrite debugfs is absent on a forward-port kernel) — not a failure.
	local result="PASS"
	if [ "$ec" -eq 77 ]; then
		result="SKIP"
	elif [ "$ec" -ne 0 ] || [ "$flags" -ne 0 ]; then
		result="FAIL"
	fi
	printf '%s\t%s\t%s\t%s\n' "$label" "$ec" "$flags" "$result" | tee -a "$SUMMARY"
	[ "$result" = "FAIL" ] && {
		echo "  --- last log lines ---"; tail -6 "$log"
		[ "$flags" -ne 0 ] && { echo "  --- flagged kernel lines ---"; grep -iE "$FATAL_RE" "$klog" | head -5; }
	}
	echo
}

# --- safe root gates ---------------------------------------------------------

# 1. rkvenc2 encoder smoke (writes /dev/kmsg markers, scans for IOMMU faults)
run_gate encode-test-tiny \
	MPP_BUILD=/usr \
	-- bash "$TEST_DIR/encode-test-tiny.sh"

# 2. end-to-end HW transcode (h264/hevc decode+encode + RGA scale/CSC).
#    FFDIR=/usr/bin -> $FFDIR/ffmpeg == the hw ffmpeg; STAGE points at an empty
#    dir so the script's LD_LIBRARY_PATH export can't shadow the distro libs.
#    transcode-test wants a 1080p H.264 input; synthesize a clean one with the
#    distro ffmpeg's *software* encoder so the HW decode path is what's tested.
_emptylib="$OUT/.emptystage"; mkdir -p "$_emptylib/lib"
_txin="$OUT/testdata/input-1080p.h264"; mkdir -p "$(dirname "$_txin")"
if [ ! -s "$_txin" ]; then
	"$FFMPEG" -hide_banner -loglevel error -y \
		-f lavfi -i testsrc=size=1920x1080:rate=30:duration=3 \
		-c:v libx264 -pix_fmt yuv420p -g 30 "$_txin" \
		|| echo "WARN: could not generate transcode input" >&2
fi
run_gate transcode \
	FFDIR="$(dirname "$FFMPEG")" STAGE="$_emptylib" IN="$_txin" \
	-- bash "$TEST_DIR/transcode-test.sh"

# 3. RGA MMU / librga sample matrix (copy/resize/rotate over the fixtures)
run_gate rga-mmu-debug \
	RGA_SAMPLE_DATA_DIR="$CONFORMANCE_ROOT/assets/rga-fixtures" \
	-- bash "$TEST_DIR/rga-mmu-debug.sh"

# 4. whole-SoC IOMMU stress with correctness oracles (RGA userptr + video-codec
#    cores + AV1 vsi-iommu). Uses hw ffmpeg for any HW ref, distro ffmpeg for
#    the software reference in decode-differential.
run_gate iommu-machinery-fuzz \
	MPP_BUILD=/usr \
	FFSW="$FFMPEG" FFHW="$FFMPEG" \
	-- bash "$TEST_DIR/iommu-machinery-fuzz.sh"

# 5. focused MPP debug capture (debugfs counters around a decode workload).
run_gate mpp-debug-capture \
	-- bash "$TEST_DIR/mpp-debug-capture.sh" -o "$OUT/mpp-debug-capture.d" -- \
	/usr/bin/mpi_dec_test -t 7 \
	-i "$CONFORMANCE_ROOT/assets/test_h264.h264" -n 60

# 6. VP9 show_existing_frame regression gate. Once a NULL-deref board hard-lock,
#    now fixed (0053/0058), so it runs every time. panic_on_oops=0 for its window
#    so a regression prints a process-context trace instead of rebooting.
prev_poo=$(cat /proc/sys/kernel/panic_on_oops 2>/dev/null)
sysctl -w kernel.panic_on_oops=0 >/dev/null
run_gate vp9-show-existing \
	-- env OUT="$OUT/vp9-show-existing" bash "$TEST_DIR/mpp-vp9-show-existing-repro.sh"
[ -n "${prev_poo:-}" ] && sysctl -w kernel.panic_on_oops="$prev_poo" >/dev/null

# --- verdict -----------------------------------------------------------------
echo "==================== SUMMARY ===================="
column -t "$SUMMARY"
fails=$(awk -F'\t' 'NR>1 && $4=="FAIL"' "$SUMMARY" | wc -l)
skips=$(awk -F'\t' 'NR>1 && $4=="SKIP"' "$SUMMARY" | wc -l)
ran=$(awk -F'\t' 'NR>1 && $4=="PASS"' "$SUMMARY" | wc -l)
echo
if [ "$fails" -eq 0 ]; then
	# Say how many actually ran. "ALL ROOT GATES PASS" over a run that skipped
	# most of them reads as full coverage, which is how a skipped gate becomes
	# indistinguishable from a green one in the record.
	if [ "$ran" -eq 0 ]; then
		echo "NO ROOT GATE RAN -- $skips skipped, 0 passed ($OUT)"
		exit 1
	fi
	echo "ALL ROOT GATES PASS -- $ran passed, $skips skipped ($OUT)"
	exit 0
fi
echo "$fails gate(s) FAILED ($ran passed, $skips skipped) -- see $OUT"
exit 1
