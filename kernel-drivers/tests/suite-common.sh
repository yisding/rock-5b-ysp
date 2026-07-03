#!/usr/bin/env bash
# Shared helpers for conformance suite wrappers.

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
