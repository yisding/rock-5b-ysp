# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Shared helpers for conformance suite wrappers.

SUITE_DMESG_SCAN=${SUITE_DMESG_SCAN:-1}
SUITE_REQUIRE_DMESG=${SUITE_REQUIRE_DMESG:-0}
# Validator-health postflight (2026-07-30 retro item 4): lockdep reports once
# and then disables itself, so a report firing BETWEEN suite windows or before
# the first dmesg baseline leaves every later suite running without deadlock
# coverage and nothing notices — measured on the 6.18.40 boots, where the
# first decode IRQ's report killed lockdep for days of runs. Every suite
# postflight therefore also checks that the validator is still alive. Only an
# explicit "0" fails: kernels without lockdep have no /proc/lockdep_stats
# (absent), and unprivileged runs cannot read it (unreadable); both pass with
# the state recorded in dmesg-scan.tsv.
SUITE_LOCKDEP_CHECK=${SUITE_LOCKDEP_CHECK:-1}
SUITE_LOCKDEP_FILE=${SUITE_LOCKDEP_FILE:-/proc/lockdep_stats}
# NOTE (2026-07-24): the `iommu[^[:alnum:]]*(fault|...)` alternative alone could
# not match the two signatures that matter most on this board --
# "rk_iommu fdb60f00.iommu: Page fault at ..." (alphanumerics sit between
# "iommu" and "fault") and "RGA IOMMU: read fault!" (a word between them).  A
# whole boot carrying 37 such lines scanned completely clean, so every suite's
# "clean kernel scan" was blind to RGA/IOMMU page faults.  The optional
# intr/read/write group plus the explicit "Page fault at" and "bus error" terms
# close that; `iommu-machinery-fuzz.sh` already scanned for these locally via
# its own FAULT_RE.  Deliberately NOT included: `rga_job_err`, "request commit
# failed", "submit failed" -- those are the expected output of fail-closed
# rejects (e.g. the 0073 above-4G page-table reject), not faults.
# The scan runs case-INSENSITIVELY (grep -aiE), which makes unanchored words
# dangerous.  Word boundaries are load-bearing here, not decoration:
#   \bBUG:  -- bare "BUG:" matches the harness's own "rga-mmu-debug:" markers
#   \bOops  -- bare "Oops" matches "pstore.backend=ramoops" in the cmdline
# and the rga/mpp alternatives must not spell "iommu", or the benign probe line
# "rga: IOMMU binding successfully" flags every scan; genuine RGA IOMMU faults
# are caught by the dedicated iommu alternative below, which requires the word
# "fault"/"panic"/"oops".  Lock debugging can disable itself without printing
# either "WARNING:" or "lockdep", so its non-static-key, validator-off, and
# DEBUG_LOCKS signatures are explicit too.  run-root-gates.sh learned the
# \bBUG: lesson first.
SUITE_DMESG_FATAL_RE=${SUITE_DMESG_FATAL_RE:-'KASAN|KCSAN|UBSAN|KFENCE|\bBUG:|kernel BUG|\bOops|Unable to handle kernel|use-after-free|slab-out-of-bounds|out-of-bounds|general protection fault|hung task|blocked for more than|RCU stall|lockdep|DEBUG_LOCKS|trying to register non-static key|turning off the locking correctness validator|WARNING:|DMA-API.*(error|WARNING)|refcount_t:|list_[a-z_]* corruption|scheduling while atomic|sleeping function called|Page fault at|iommu[^[:alnum:]]*(intr|read|write)?[^[:alnum:]]*(fault|panic|oops)|bus error|rga[^[:alnum:]]*(fault|panic)|mpp[^[:alnum:]]*(fault|panic)'}

suite_now_ns()
{
	local now

	now=$(date +%s%N)
	case "$now" in
	*N*)
		printf "%s000000000" "$(date +%s)"
		;;
	*)
		printf "%s" "$now"
		;;
	esac
}

suite_elapsed_s()
{
	local start=$1
	local end=$2
	local delta

	delta=$((end - start))
	awk -v ns="$delta" 'BEGIN {
		if (ns < 0)
			ns = 0;
		printf "%.3f", ns / 1000000000;
	}'
}

suite_dmesg_capture()
{
	local target=$1
	local error_file=${target%.txt}.error.txt

	if [ "$SUITE_DMESG_SCAN" != "1" ] &&
		[ "$SUITE_REQUIRE_DMESG" != "1" ]; then
		: > "$target"
		printf "dmesg capture disabled\n" > "$error_file"
		return 0
	fi

	if dmesg > "$target" 2> "$error_file"; then
		rm -f "$error_file"
		return 0
	fi

	: > "$target"
	[ "$SUITE_REQUIRE_DMESG" != "1" ]
}

suite_dmesg_delta()
{
	local before=$1
	local after=$2
	local target=$3

	if [ ! -s "$before" ] || [ ! -s "$after" ]; then
		: > "$target"
		return 2
	fi

	if awk '
		NR == FNR {
			before[++before_lines] = $0;
			next;
		}
		FNR <= before_lines {
			if ($0 != before[FNR])
				mismatch = 1;
		}
		FNR > before_lines {
			after[++after_lines] = $0;
		}
		END {
			if (FNR < before_lines || mismatch)
				exit 2;
			for (line = 1; line <= after_lines; line++)
				print after[line];
		}
	' "$before" "$after" > "$target"; then
		return 0
	fi

	{
		printf "# dmesg ring wrapped; full after snapshot follows\n"
		cat "$after"
	} > "$target"
}

suite_lockdep_state()
{
	if [ "$SUITE_LOCKDEP_CHECK" != "1" ]; then
		printf "skipped"
		return
	fi
	if [ ! -e "$SUITE_LOCKDEP_FILE" ]; then
		printf "absent"
		return
	fi
	if [ ! -r "$SUITE_LOCKDEP_FILE" ]; then
		printf "unreadable"
		return
	fi
	awk '
		NR == 1 && /^[01][[:space:]]*$/ { print $1; found = 1; exit }
		$1 == "debug_locks:" { print $2; found = 1; exit }
		END { if (!found) print "unavailable" }
	' "$SUITE_LOCKDEP_FILE"
}

suite_dmesg_scan_snapshots()
{
	local out=$1
	local before="$out/dmesg-before.txt"
	local after="$out/dmesg-after.txt"
	local new="$out/dmesg-new.txt"
	local fatal="$out/dmesg-fatal.txt"
	local report="$out/dmesg-scan.tsv"
	local delta_status=0
	local status=clean
	local new_lines=0
	local fatal_lines=0
	local lockdep_state

	if [ "$SUITE_DMESG_SCAN" != "1" ]; then
		: > "$new"
		: > "$fatal"
		status=skipped
	else
		suite_dmesg_delta "$before" "$after" "$new" || delta_status=$?
		if [ "$delta_status" -ne 0 ]; then
			status=unavailable
			: > "$fatal"
		else
			grep -aiE "$SUITE_DMESG_FATAL_RE" "$new" > "$fatal" || :
			if [ -s "$fatal" ]; then
				status=fatal
			fi
		fi
	fi

	lockdep_state=$(suite_lockdep_state)
	if [ "$lockdep_state" = "0" ] && [ "$status" != "fatal" ]; then
		status=lockdep-disabled
	fi

	if [ -f "$new" ]; then
		new_lines=$(wc -l < "$new" | tr -d '[:space:]')
	fi
	if [ -f "$fatal" ]; then
		fatal_lines=$(wc -l < "$fatal" | tr -d '[:space:]')
	fi
	{
		printf "field\tvalue\n"
		printf "status\t%s\n" "$status"
		printf "new_lines\t%s\n" "$new_lines"
		printf "fatal_lines\t%s\n" "$fatal_lines"
		printf "lockdep_state\t%s\n" "$lockdep_state"
		printf "fatal_regex\t%s\n" "$SUITE_DMESG_FATAL_RE"
	} > "$report"

	case "$status" in
	clean)
		return 0
		;;
	skipped)
		[ "$SUITE_REQUIRE_DMESG" != "1" ]
		;;
	unavailable)
		[ "$SUITE_REQUIRE_DMESG" != "1" ]
		;;
	*)
		# fatal and lockdep-disabled both fail the suite.
		return 1
		;;
	esac
}

suite_dmesg_start()
{
	local out=$1

	suite_dmesg_capture "$out/dmesg-before.txt"
}

suite_dmesg_finish()
{
	local out=$1
	local capture_status=0

	suite_dmesg_capture "$out/dmesg-after.txt" || capture_status=$?
	suite_dmesg_scan_snapshots "$out" || return $?
	return "$capture_status"
}
