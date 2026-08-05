#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Capture one focused MPP rewrite reproduction without losing failure evidence.
#
# Exit 0  = capture-only or wrapped workload passed
# Exit 77 = the rewrite debugfs journal is not present on this boot
# Other   = wrapped workload status, or a capture/control error
set -uo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=debugfs-counters.sh disable=SC1091
source "$TEST_DIR/debugfs-counters.sh"
: "${DEBUGFS_COUNTERS_LOADED:?debugfs-counters.sh did not load; the counter/leak check would be silently absent}"

DEBUGFS_ROOT=${MPP_DEBUGFS_ROOT:-/sys/kernel/debug/rk_mpp_rewrite}
PROC_ROOT=${MPP_DEBUG_PROC_ROOT:-/proc/mpp_service}
OUT=${MPP_DEBUG_OUT:-"$PWD/mpp-debug-$(date +%Y%m%d-%H%M%S)"}
CLEAR_EVENTS=${MPP_DEBUG_CLEAR_EVENTS:-1}
TRACE_MASK=${MPP_DEBUG_TRACE_MASK:-}
SKIP_DMESG=${MPP_DEBUG_SKIP_DMESG:-0}
REQUIRE_DMESG=${MPP_DEBUG_REQUIRE_DMESG:-0}
VALIDATE_ONLY=${MPP_DEBUG_VALIDATE_ONLY:-0}

trace_changed=0
saved_trace_mask=

usage()
{
	cat <<EOF
Usage: ${0##*/} [options] [--] [workload [args...]]

Capture the MPP rewrite's state, recent event journal, numeric counters,
/proc discovery data, and dmesg before and after one command. With no command,
capture the current state only.

Options:
  -o DIR            output directory (default: ./mpp-debug-TIMESTAMP)
  --trace-mask MASK temporarily set trace_mask for the reproduction
  --no-clear        retain older event-journal entries
  --capture-only    do not run a workload
  -h, --help        show this help

Environment equivalents:
  MPP_DEBUG_OUT, MPP_DEBUG_TRACE_MASK, MPP_DEBUG_CLEAR_EVENTS,
  MPP_DEBUGFS_ROOT, MPP_DEBUG_PROC_ROOT, MPP_DEBUG_REQUIRE_DMESG.

Example:
  sudo ${0##*/} -o /tmp/mpp-decode -- mpi_dec_test -i input.h264 -t 7
EOF
}

restore_trace_mask()
{
	if [ "$trace_changed" = 1 ] && [ -w "$DEBUGFS_ROOT/trace_mask" ]; then
		printf '%s\n' "$saved_trace_mask" > "$DEBUGFS_ROOT/trace_mask" 2>/dev/null || :
	fi
	trace_changed=0
}

capture_dmesg()
{
	local target=$1
	local error_file=${target%.txt}.error.txt

	if [ "$SKIP_DMESG" = 1 ]; then
		printf 'dmesg capture skipped\n' > "$target"
		return 0
	fi

	if dmesg --time-format iso > "$target" 2> "$error_file"; then
		rm -f "$error_file"
		return 0
	fi
	if dmesg > "$target" 2> "$error_file"; then
		rm -f "$error_file"
		return 0
	fi

	printf 'dmesg unavailable; see %s\n' "$(basename "$error_file")" > "$target"
	[ "$REQUIRE_DMESG" != 1 ]
}

snapshot_proc()
{
	local target=$1
	local file

	: > "$target"
	if [ ! -e "$PROC_ROOT" ]; then
		printf '%s is absent\n' "$PROC_ROOT" > "$target"
		return
	fi

	if [ -f "$PROC_ROOT" ]; then
		cat "$PROC_ROOT" > "$target" 2>&1 || :
		return
	fi

	while IFS= read -r file; do
		printf -- '== %s ==\n' "$file" >> "$target"
		cat "$file" >> "$target" 2>&1 || :
	done < <(find "$PROC_ROOT" -maxdepth 2 -type f -print 2>/dev/null | sort)
}

snapshot()
{
	local phase=$1
	local dir="$OUT/$phase"
	local rc=0

	mkdir -p "$dir"
	cat "$DEBUGFS_ROOT/state" > "$dir/state.txt" 2> "$dir/state.error.txt" || rc=1
	cat "$DEBUGFS_ROOT/events" > "$dir/events.txt" 2> "$dir/events.error.txt" || rc=1
	debugfs_counter_snapshot "$dir/counters.tsv" mpp "$DEBUGFS_ROOT"
	snapshot_proc "$dir/proc-mpp-service.txt"
	capture_dmesg "$dir/dmesg.txt" || rc=1

	[ -s "$dir/state.error.txt" ] || rm -f "$dir/state.error.txt"
	[ -s "$dir/events.error.txt" ] || rm -f "$dir/events.error.txt"
	return "$rc"
}

write_dmesg_delta()
{
	local before="$OUT/before/dmesg.txt"
	local after="$OUT/after/dmesg.txt"
	local target="$OUT/dmesg-new.txt"
	local before_lines
	local after_lines

	if [ ! -f "$before" ] || [ ! -f "$after" ]; then
		printf 'before/after dmesg capture is incomplete\n' > "$target"
		return
	fi

	before_lines=$(wc -l < "$before")
	after_lines=$(wc -l < "$after")
	if [ "$after_lines" -ge "$before_lines" ]; then
		tail -n "+$((before_lines + 1))" "$after" > "$target"
	else
		{
			printf '# dmesg ring wrapped; full after snapshot follows\n'
			cat "$after"
		} > "$target"
	fi
}

write_event_summary()
{
	local events="$OUT/after/events.txt"
	local target="$OUT/event-summary.txt"

	if [ ! -s "$events" ]; then
		printf 'no retained MPP rewrite events\n' > "$target"
		return
	fi

	awk '
		BEGIN { total = 0; failed = 0 }
		/^#/ || NF < 12 { next }
		{
			total++;
			count[$3]++;
			if (($10 + 0) != 0)
				failed++;
		}
		END {
			printf "events=%d nonzero_results=%d\n", total, failed;
			for (event in count)
				printf "%s=%d\n", event, count[event];
		}
	' "$events" > "$target"

	{
		printf '\n# events with a nonzero result\n'
		awk '!/^#/ && NF >= 12 && ($10 + 0) != 0' "$events"
	} >> "$target"
}

validate_capture_workflow()
{
	local tmp
	local rc

	tmp=$(mktemp -d -t mpp-debug-capture.XXXXXX) || return 1
	mkdir -p "$tmp/debugfs" "$tmp/proc"
	printf 'version=test queued=0\n' > "$tmp/debugfs/state"
	printf '%s\n' \
		'# seq timestamp_ns event device hw core session job client result irq data' \
		'1 10 queued test rkvdec2 0 7 3 9 0 0 1' \
		'2 20 done test rkvdec2 0 7 3 9 -5 0 100' > "$tmp/debugfs/events"
	printf '2\n' > "$tmp/debugfs/completed_job_count"
	printf '1\n' > "$tmp/debugfs/failed_job_count"
	printf '0\n' > "$tmp/debugfs/trace_mask"
	printf 'DEVICE[9]:RKVDEC\n' > "$tmp/proc/supports-device"

	env MPP_DEBUG_VALIDATE_ONLY=0 \
		MPP_DEBUGFS_ROOT="$tmp/debugfs" \
		MPP_DEBUG_PROC_ROOT="$tmp/proc" \
		MPP_DEBUG_OUT="$tmp/out" \
		MPP_DEBUG_CLEAR_EVENTS=0 \
		MPP_DEBUG_TRACE_MASK=7 \
		MPP_DEBUG_SKIP_DMESG=1 \
		bash "$0" -- bash -c 'exit 23'
	rc=$?

	if [ "$rc" -ne 23 ] ||
		[ ! -s "$tmp/out/after/state.txt" ] ||
		[ ! -s "$tmp/out/after/events.txt" ] ||
		[ ! -s "$tmp/out/after/counters.tsv" ] ||
		[ "$(cat "$tmp/out/workload.exit")" != 23 ] ||
		[ "$(cat "$tmp/debugfs/trace_mask")" != 0 ] ||
		! grep -q '^done=1$' "$tmp/out/event-summary.txt"; then
		printf 'MPP debug capture selftest failed; artifacts kept at %s\n' "$tmp" >&2
		return 1
	fi

	rm -rf "$tmp"
	printf 'MPP debug capture workflow validated\n'
}

if [ "$VALIDATE_ONLY" = 1 ]; then
	validate_capture_workflow
	exit $?
fi

capture_only=0
command_args=()
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		OUT=$2
		shift 2
		;;
	--trace-mask)
		[ "$#" -ge 2 ] || { usage >&2; exit 2; }
		TRACE_MASK=$2
		shift 2
		;;
	--no-clear)
		CLEAR_EVENTS=0
		shift
		;;
	--capture-only)
		capture_only=1
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	--)
		shift
		command_args=("$@")
		break
		;;
	*)
		command_args=("$@")
		break
		;;
	esac
done

if [ "$capture_only" = 1 ]; then
	command_args=()
fi

if [ ! -d "$DEBUGFS_ROOT" ] ||
	[ ! -r "$DEBUGFS_ROOT/state" ] ||
	[ ! -r "$DEBUGFS_ROOT/events" ]; then
	printf 'SKIP: MPP rewrite state/events are absent or unreadable under %s\n' \
		"$DEBUGFS_ROOT" >&2
	exit 77
fi

mkdir -p "$OUT"
{
	printf 'captured_at=%s\n' "$(date --iso-8601=seconds)"
	printf 'kernel=%s\n' "$(uname -r)"
	printf 'debugfs=%s\n' "$DEBUGFS_ROOT"
	printf 'clear_events=%s\n' "$CLEAR_EVENTS"
	printf 'trace_mask=%s\n' "${TRACE_MASK:-unchanged}"
	printf 'command='
	if [ "${#command_args[@]}" -eq 0 ]; then
		printf '(capture only)'
	else
		printf '%q ' "${command_args[@]}"
	fi
	printf '\n'
} > "$OUT/metadata.txt"

trap restore_trace_mask EXIT
trap 'restore_trace_mask; exit 130' INT
trap 'restore_trace_mask; exit 143' TERM

if ! snapshot before; then
	printf 'failed to capture required before state\n' >&2
	exit 1
fi

if [ "$CLEAR_EVENTS" = 1 ]; then
	if [ -w "$DEBUGFS_ROOT/events" ]; then
		{ printf '1\n' > "$DEBUGFS_ROOT/events"; } \
			2> "$OUT/events-clear.error.txt" || :
		[ -s "$OUT/events-clear.error.txt" ] || rm -f "$OUT/events-clear.error.txt"
	else
		printf '%s is not writable; old journal entries retained\n' \
			"$DEBUGFS_ROOT/events" > "$OUT/events-clear.error.txt"
	fi
fi

if [ -n "$TRACE_MASK" ]; then
	if [ ! -r "$DEBUGFS_ROOT/trace_mask" ] || [ ! -w "$DEBUGFS_ROOT/trace_mask" ]; then
		printf 'requested trace mask but %s/trace_mask is not readable/writable\n' \
			"$DEBUGFS_ROOT" >&2
		exit 1
	fi
	saved_trace_mask=$(tr -d '[:space:]' < "$DEBUGFS_ROOT/trace_mask")
	printf '%s\n' "$TRACE_MASK" > "$DEBUGFS_ROOT/trace_mask" || exit 1
	trace_changed=1
fi

workload_status=0
if [ "${#command_args[@]}" -gt 0 ]; then
	"${command_args[@]}" 2>&1 | tee "$OUT/workload.log"
	workload_status=${PIPESTATUS[0]}
else
	: > "$OUT/workload.log"
fi
printf '%s\n' "$workload_status" > "$OUT/workload.exit"

restore_trace_mask
capture_status=0
snapshot after || capture_status=1
debugfs_counter_delta "$OUT/before/counters.tsv" "$OUT/after/counters.tsv" \
	"$OUT/counter-delta.tsv"
write_dmesg_delta
write_event_summary

{
	printf 'workload_exit=%s\n' "$workload_status"
	printf 'capture_exit=%s\n' "$capture_status"
} >> "$OUT/metadata.txt"

printf 'MPP debug bundle: %s\n' "$OUT"
if [ "$workload_status" -ne 0 ]; then
	exit "$workload_status"
fi
exit "$capture_status"
