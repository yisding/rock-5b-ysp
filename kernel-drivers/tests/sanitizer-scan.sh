# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Shared helper: run a workload on an instrumented debug kernel and scan the
# kernel log emitted during it for sanitizer/crash signatures. Sourced by the
# configuration-specific safety tests. Uses journalctl (no sudo/dmesg-cap needed) with a cursor
# so the scan window is exactly the workload, and reuses suite-common.sh's
# SUITE_DMESG_FATAL_RE so the fatal-signature set stays in one place.
#
# Usage:
#   source sanitizer-scan.sh
#   sanitizer_scan_begin "$OUT"    # records cursor + uname + boot id
#   ...run the workload...
#   sanitizer_scan_end "$OUT"      # writes kernel-log-{during,flags}.txt; prints count
#                                  # returns non-zero if any fatal signature matched

# shellcheck source=suite-common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/suite-common.sh"
: "${SUITE_DMESG_FATAL_RE:?suite-common.sh did not load; the kernel-log fatal scan would be silently blind}"

sanitizer_scan_begin()
{
	local out=$1

	mkdir -p "$out"
	uname -a > "$out/uname.txt" 2>/dev/null || true
	cat /proc/sys/kernel/random/boot_id > "$out/boot-id.txt" 2>/dev/null || true
	journalctl -k -n 1 --show-cursor 2>/dev/null \
		| sed -n 's/^-- cursor: //p' > "$out/journal-cursor.txt" || true
	sync
}

# Echoes the number of matched (flagged) lines; returns 0 if clean, 1 if any.
sanitizer_scan_end()
{
	local out=$1
	local cursor
	local flags

	sync
	cursor=$(cat "$out/journal-cursor.txt" 2>/dev/null || true)
	if [ -n "$cursor" ]; then
		journalctl -k --after-cursor "$cursor" \
			> "$out/kernel-log-during.txt" 2>&1
	else
		# No cursor: this used to fall back to the last 4000 kernel lines, i.e.
		# most of the boot, with no indication in the output. That turns any
		# pre-existing boot-time WARNING or iommu-fault line into a flag for a
		# workload that was actually clean -- it over-fails rather than
		# under-fails, but either way the scan no longer describes the workload.
		echo "sanitizer-scan: WARNING no journal cursor was recorded; scanning the last" \
			"4000 kernel lines instead of the workload window. Flags below may" \
			"predate the workload." >&2
		# The note goes in a SIDECAR, never into the scanned file. A banner
		# containing the word "sanitizer-scan" matches the sanitizer name in the
		# fatal set when the helper itself is named after that sanitizer, which
		# is grepped case-insensitively -- so announcing the degraded window
		# inside the window turned every clean no-cursor run into a hard FAIL.
		# Same trap run-root-gates.sh documents for `de(bug:)` in gate markers.
		printf 'no journal cursor was recorded; window is the last 4000 kernel lines\n' \
			> "$out/kernel-log-window-degraded.txt"
		journalctl -k -n 4000 > "$out/kernel-log-during.txt" 2>&1
	fi

	# -ai to match suite-common.sh's scan: the fatal set contains
	# case-varying signatures (e.g. "IOMMU"/"iommu"), and a
	# case-sensitive scan here silently missed them.
	grep -aiE "$SUITE_DMESG_FATAL_RE" "$out/kernel-log-during.txt" \
		> "$out/kernel-log-flags.txt" 2>/dev/null || true
	flags=$(wc -l < "$out/kernel-log-flags.txt" 2>/dev/null || echo 0)
	printf '%s' "$flags"

	[ "$flags" -eq 0 ]
}
