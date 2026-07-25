# shellcheck shell=bash
# Shared helper: run a workload on the KASAN/ramoops debug kernel and scan the
# kernel log emitted during it for sanitizer/crash signatures. Sourced by the
# kasan-*.sh runners. Uses journalctl (no sudo/dmesg-cap needed) with a cursor
# so the scan window is exactly the workload, and reuses suite-common.sh's
# SUITE_DMESG_FATAL_RE so the fatal-signature set stays in one place.
#
# Usage:
#   source kasan-scan.sh
#   kasan_scan_begin "$OUT"        # records cursor + uname + boot id
#   ...run the workload...
#   kasan_scan_end   "$OUT"        # writes kernel-log-{during,flags}.txt; prints count
#                                  # returns non-zero if any fatal signature matched

# shellcheck source=suite-common.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/suite-common.sh"

kasan_scan_begin()
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
kasan_scan_end()
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
