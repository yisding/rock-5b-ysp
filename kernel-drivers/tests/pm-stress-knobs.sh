#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Collapse runtime-PM autosuspend windows on the rewrite MPP/RGA cores so
# power-transition races surface deterministically instead of depending on
# case-scheduling luck.
#
# Retro item 2 (2026-07-30): the soft-CCU group-power wedge lived entirely
# inside the 200 ms autosuspend delay — a sibling core left registered in
# CORE_WORK autosuspended ~200 ms after its session closed, inside the next
# session's first-frame window, and a coordinator poke at the gated register
# file stalled the interconnect. Forcing autosuspend_delay_ms to 0 makes that
# gating happen the instant a core idles, turning a scheduling-dependent race
# into a near-deterministic one.
#
# Usage:
#   pm-stress-knobs.sh apply     # save originals, set delay to 0 (needs root)
#   pm-stress-knobs.sh restore   # write originals back, remove state file
#   pm-stress-knobs.sh show      # print current per-device delays
#   pm-stress-knobs.sh --validate  # device-free selftest (enumeration + I/O)
set -euo pipefail

PM_STRESS_DELAY_MS=${PM_STRESS_DELAY_MS:-0}
PM_STRESS_DRIVERS=${PM_STRESS_DRIVERS:-"rk-mpp-rewrite-hw rockchip-rga-rewrite"}
PM_STRESS_SYSFS=${PM_STRESS_SYSFS:-/sys/bus/platform/drivers}
PM_STRESS_STATE=${PM_STRESS_STATE:-/run/rewrite-pm-stress.state}

# Enumerate "<device_dir>\t<autosuspend_delay_ms path>" for every rewrite core
# whose device exposes the knob. Bind/unbind/uevent/module control files are
# not device directories and are skipped by the power/ existence test.
pm_stress_enumerate()
{
	local drv dev ad
	for drv in $PM_STRESS_DRIVERS; do
		for dev in "$PM_STRESS_SYSFS/$drv"/*/; do
			[ -d "$dev" ] || continue
			ad="${dev}power/autosuspend_delay_ms"
			[ -w "$ad" ] || continue
			printf "%s\t%s\n" "${dev%/}" "$ad"
		done
	done
}

pm_stress_show()
{
	local dev ad
	while IFS=$'\t' read -r dev ad; do
		printf "%s\t%s\n" "$(basename "$dev")" "$(cat "$ad" 2>/dev/null)"
	done < <(pm_stress_enumerate)
}

pm_stress_apply()
{
	local dev ad count=0

	if [ -e "$PM_STRESS_STATE" ]; then
		echo "pm-stress state already present; restore first: $PM_STRESS_STATE" >&2
		return 1
	fi
	mkdir -p "$(dirname "$PM_STRESS_STATE")"
	: > "$PM_STRESS_STATE"
	while IFS=$'\t' read -r dev ad; do
		printf "%s\t%s\n" "$ad" "$(cat "$ad")" >> "$PM_STRESS_STATE"
		printf "%s" "$PM_STRESS_DELAY_MS" > "$ad"
		count=$((count + 1))
	done < <(pm_stress_enumerate)

	if [ "$count" -eq 0 ]; then
		rm -f "$PM_STRESS_STATE"
		echo "pm-stress found no rewrite PM knobs (driver bound? root?)" >&2
		return 1
	fi
	printf "pm-stress: set autosuspend_delay_ms=%s on %s cores\n" \
		"$PM_STRESS_DELAY_MS" "$count"
}

pm_stress_restore()
{
	local ad value

	if [ ! -e "$PM_STRESS_STATE" ]; then
		echo "pm-stress: no state file, nothing to restore" >&2
		return 0
	fi
	while IFS=$'\t' read -r ad value; do
		[ -w "$ad" ] || continue
		printf "%s" "$value" > "$ad"
	done < "$PM_STRESS_STATE"
	rm -f "$PM_STRESS_STATE"
	printf "pm-stress: restored original autosuspend delays\n"
}

# Device-free selftest: prove enumeration, apply, and restore round-trip
# against a fake sysfs tree, so the runner's VALIDATE_ONLY path and check-repo
# exercise the logic without touching real power state.
pm_stress_validate()
{
	local root dev ad
	root=$(mktemp -d "${TMPDIR:-/tmp}/pm-stress-validate.XXXXXX")
	trap 'rm -rf "$root"' RETURN

	for dev in fdc38100.video-codec fdc40100.video-codec; do
		ad="$root/drv/rk-mpp-rewrite-hw/$dev/power"
		mkdir -p "$ad"
		printf "200" > "$ad/autosuspend_delay_ms"
	done
	# A non-device control file that must be skipped.
	mkdir -p "$root/drv/rk-mpp-rewrite-hw/bind" 2>/dev/null || :

	PM_STRESS_SYSFS="$root/drv" PM_STRESS_DRIVERS="rk-mpp-rewrite-hw" \
		PM_STRESS_STATE="$root/state" PM_STRESS_DELAY_MS=0 \
		bash "$0" apply >/dev/null
	for dev in fdc38100.video-codec fdc40100.video-codec; do
		ad="$root/drv/rk-mpp-rewrite-hw/$dev/power/autosuspend_delay_ms"
		if [ "$(cat "$ad")" != "0" ]; then
			echo "validate: apply did not zero $dev" >&2
			return 1
		fi
	done
	PM_STRESS_SYSFS="$root/drv" PM_STRESS_DRIVERS="rk-mpp-rewrite-hw" \
		PM_STRESS_STATE="$root/state" \
		bash "$0" restore >/dev/null
	for dev in fdc38100.video-codec fdc40100.video-codec; do
		ad="$root/drv/rk-mpp-rewrite-hw/$dev/power/autosuspend_delay_ms"
		if [ "$(cat "$ad")" != "200" ]; then
			echo "validate: restore did not return $dev to 200" >&2
			return 1
		fi
	done
	if [ -e "$root/state" ]; then
		echo "validate: state file survived restore" >&2
		return 1
	fi
	echo "pm-stress knob selftest passed"
}

case "${1:-}" in
apply)   pm_stress_apply ;;
restore) pm_stress_restore ;;
show)    pm_stress_show ;;
--validate) pm_stress_validate ;;
--help|-h)
	grep '^#' "$0" | sed 's/^# \{0,1\}//'
	;;
*)
	echo "usage: ${0##*/} {apply|restore|show|--validate}" >&2
	exit 2
	;;
esac
