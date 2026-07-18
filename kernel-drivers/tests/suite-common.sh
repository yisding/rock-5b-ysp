#!/usr/bin/env bash
# Shared helpers for conformance suite wrappers.

SUITE_DMESG_SCAN=${SUITE_DMESG_SCAN:-1}
SUITE_REQUIRE_DMESG=${SUITE_REQUIRE_DMESG:-0}
SUITE_DMESG_FATAL_RE=${SUITE_DMESG_FATAL_RE:-'KASAN|KCSAN|UBSAN|KFENCE|BUG:|kernel BUG|Oops|Unable to handle kernel|use-after-free|slab-out-of-bounds|out-of-bounds|general protection fault|hung task|blocked for more than|RCU stall|lockdep|WARNING:|DMA-API.*(error|WARNING)|refcount_t:|list_[a-z_]* corruption|scheduling while atomic|sleeping function called|iommu[^[:alnum:]]*(fault|panic|oops)|rga[^[:alnum:]]*(fault|panic|iommu)|mpp[^[:alnum:]]*(fault|panic|iommu)'}

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
