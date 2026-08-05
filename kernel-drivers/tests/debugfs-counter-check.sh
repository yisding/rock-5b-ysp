#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Validate rewrite debugfs counter deltas captured by the conformance suites.
set -euo pipefail

SUMMARY=${SUMMARY:-${1:-}}
COUNTERS_FILE=${COUNTERS_FILE:-}
REQUIRED_POSITIVE_COUNTERS=${REQUIRED_POSITIVE_COUNTERS:-}
REQUIRED_POSITIVE_COUNTER_PREFIXES=${REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
REQUIRED_ZERO_AFTER_COUNTERS=${REQUIRED_ZERO_AFTER_COUNTERS:-}
FORBID_POSITIVE_COUNTERS=${FORBID_POSITIVE_COUNTERS:-"mpp:timeout_count mpp:recovery_failure_count mpp:iommu_fault_count mpp:iommu_idle_fault_count mpp:spurious_irq_count mpp:av1_afbc_stale_status_timeout_count mpp:av1_reset_idle_unproven_count rga:timeout_count rga:irq_error_count rga:irq_spurious_count rga:rga2_config_error_count rga:iommu_fault_count rga:recovery_failure_count rga:shadow_setup_failure_count"}
REQUIRE_FORBIDDEN_COUNTERS=${REQUIRE_FORBIDDEN_COUNTERS:-0}
REQUIRE_COUNTER_FILE=${REQUIRE_COUNTER_FILE:-0}

# Publish the forbidden-counter default so fixtures can be built from it
# instead of restating it. REQUIRE_FORBIDDEN_COUNTERS=1 demands every entry be
# present in the delta file, so a counter added here silently invalidates any
# fixture that hardcodes the old list -- which is exactly how the
# rewrite-evidence-audit selftest came to fail on three counters it had never
# heard of.
if [ "${1:-}" = "--print-forbid-defaults" ]; then
	printf '%s\n' "$FORBID_POSITIVE_COUNTERS"
	exit 0
fi

if [ -z "$COUNTERS_FILE" ] && [ -n "$SUMMARY" ]; then
	COUNTERS_FILE="$(dirname "$SUMMARY")/debugfs-counters-delta.tsv"
fi

if [ -z "$COUNTERS_FILE" ]; then
	echo "missing COUNTERS_FILE or SUMMARY" >&2
	exit 2
fi

if [ ! -f "$COUNTERS_FILE" ]; then
	echo "counter_check	skipped"
	echo "counter_file	$COUNTERS_FILE"
	echo "reason	missing debugfs counter delta file"
	if [ "$REQUIRE_COUNTER_FILE" = "1" ] ||
		[ -n "$REQUIRED_POSITIVE_COUNTERS" ] ||
		[ -n "$REQUIRED_POSITIVE_COUNTER_PREFIXES" ] ||
		[ -n "$REQUIRED_ZERO_AFTER_COUNTERS" ] ||
		[ "$REQUIRE_FORBIDDEN_COUNTERS" = "1" ]; then
		exit 1
	fi
	exit 0
fi

# REQUIRE_COUNTER_FILE=1 tested only for the file's existence, so a header-only
# delta satisfied it. debugfs-counters.sh writes exactly that when the debugfs
# directory is absent (a forward-port kernel, or any non-root run -- debugfs is
# 0700), and with zero rows every forbidden spec resolves to
# "component-not-captured", which does not set `failed`. So the strictest mode
# passed a file that recorded nothing. rewrite-evidence-audit.sh already rejects
# this; align with it.
counter_rows=$(awk 'NR > 1 && NF > 0' "$COUNTERS_FILE" | wc -l)
if [ "$counter_rows" -eq 0 ]; then
	echo "counter_check	skipped"
	echo "counter_file	$COUNTERS_FILE"
	echo "reason	counter delta file has no data rows"
	if [ "$REQUIRE_COUNTER_FILE" = "1" ] ||
		[ -n "$REQUIRED_POSITIVE_COUNTERS" ] ||
		[ -n "$REQUIRED_POSITIVE_COUNTER_PREFIXES" ] ||
		[ -n "$REQUIRED_ZERO_AFTER_COUNTERS" ] ||
		[ "$REQUIRE_FORBIDDEN_COUNTERS" = "1" ]; then
		exit 1
	fi
	exit 0
fi

awk -v required_specs="$REQUIRED_POSITIVE_COUNTERS" \
    -v required_prefix_specs="$REQUIRED_POSITIVE_COUNTER_PREFIXES" \
    -v required_zero_after_specs="$REQUIRED_ZERO_AFTER_COUNTERS" \
    -v forbid_specs="$FORBID_POSITIVE_COUNTERS" \
    -v require_forbidden="$REQUIRE_FORBIDDEN_COUNTERS" \
    -v counter_file="$COUNTERS_FILE" '
function split_specs(value, array,    n, i, token) {
	n = split(value, tokens, /[[:space:]]+/);
	for (i = 1; i <= n; i++) {
		token = tokens[i];
		if (token == "")
			continue;
		array[++array[0]] = token;
	}
}

function split_spec(spec, parts) {
	if (split(spec, parts, ":") != 2)
		return 0;
	if (parts[1] == "" || parts[2] == "")
		return 0;
	return 1;
}

function split_prefix_spec(spec, parts) {
	if (split(spec, parts, ":") != 3)
		return 0;
	if (parts[1] == "" || parts[2] == "" || parts[3] == "")
		return 0;
	if (parts[3] !~ /^[0-9]+$/ || parts[3] + 0 <= 0)
		return 0;
	return 1;
}

function spec_matches(spec, component, counter,    parts) {
	if (!split_spec(spec, parts))
		return 0;
	if (parts[1] != "*" && parts[1] != component)
		return 0;
	if (parts[2] != "*" && parts[2] != counter)
		return 0;
	return 1;
}

function prefix_spec_matches(spec, component, counter,    parts) {
	if (!split_prefix_spec(spec, parts))
		return 0;
	if (parts[1] != "*" && parts[1] != component)
		return 0;
	if (index(counter, parts[2]) != 1)
		return 0;
	return 1;
}

function spec_delta_sum(spec,    key, total) {
	total = 0;
	for (key in delta_by_key) {
		if (spec_matches(spec, component_by_key[key], counter_by_key[key]))
			total += delta_by_key[key];
	}
	return total;
}

function spec_seen_count(spec,    key, total) {
	total = 0;
	for (key in seen) {
		if (spec_matches(spec, component_by_key[key], counter_by_key[key]))
			total++;
	}
	return total;
}

function spec_component_seen_count(spec,    key, parts, total) {
	if (!split_spec(spec, parts))
		return 0;
	total = 0;
	for (key in seen) {
		if (parts[1] == "*" || parts[1] == component_by_key[key])
			total++;
	}
	return total;
}

function spec_after_sum(spec,    key, total) {
	total = 0;
	for (key in after_by_key) {
		if (spec_matches(spec, component_by_key[key], counter_by_key[key]))
			total += after_by_key[key];
	}
	return total;
}

function spec_after_non_numeric_count(spec,    key, total) {
	total = 0;
	for (key in seen) {
		if (spec_matches(spec, component_by_key[key], counter_by_key[key]) &&
		    !after_numeric_by_key[key])
			total++;
	}
	return total;
}

function prefix_positive_count(spec,    key, total) {
	total = 0;
	for (key in delta_by_key) {
		if (prefix_spec_matches(spec, component_by_key[key],
					counter_by_key[key]) &&
		    delta_by_key[key] > 0)
			total++;
	}
	return total;
}

BEGIN {
	FS = OFS = "\t";
	failed = 0;
	split_specs(required_specs, required);
	split_specs(required_prefix_specs, required_prefix);
	split_specs(required_zero_after_specs, required_zero_after);
	split_specs(forbid_specs, forbidden);
	print "counter_file", counter_file;
	print "required_positive", required_specs;
	print "required_positive_prefixes", required_prefix_specs;
	print "required_zero_after", required_zero_after_specs;
	print "forbid_positive", forbid_specs;
	print "require_forbidden_present", require_forbidden;
	print "";
	print "component", "counter", "before", "after", "delta", "verdict";
}

FNR == 1 {
	next;
}

{
	key = $1 SUBSEP $2;
	component_by_key[key] = $1;
	counter_by_key[key] = $2;
	before_by_key[key] = $3;
	after_by_key[key] = ($4 ~ /^-?[0-9]+$/) ? $4 + 0 : 0;
	after_numeric_by_key[key] = ($4 ~ /^-?[0-9]+$/) ? 1 : 0;
	delta_by_key[key] = ($5 ~ /^-?[0-9]+$/) ? $5 + 0 : 0;
	seen[key] = 1;
}

END {
	for (key in seen) {
		verdict = "ok";
		for (i = 1; i <= forbidden[0]; i++) {
			if (spec_matches(forbidden[i], component_by_key[key],
					 counter_by_key[key]) &&
			    delta_by_key[key] > 0) {
				verdict = "forbidden-positive";
				failed = 1;
			}
		}

		print component_by_key[key], counter_by_key[key],
		      before_by_key[key], after_by_key[key], delta_by_key[key],
		      verdict;
	}

	if (required[0] || forbidden[0])
		print "";
	if (required[0])
		print "require_spec", "observed_delta", "verdict";
	for (i = 1; i <= required[0]; i++) {
		if (!split_spec(required[i], parts)) {
			print required[i], "n/a", "invalid-spec";
			failed = 1;
			continue;
		}
		sum = spec_delta_sum(required[i]);
		if (sum > 0) {
			print required[i], sum, "ok";
		} else {
			print required[i], sum, "missing-or-zero";
			failed = 1;
		}
	}

	if (required_prefix[0])
		print "require_prefix_spec", "positive_counter_count", "verdict";
	for (i = 1; i <= required_prefix[0]; i++) {
		if (!split_prefix_spec(required_prefix[i], parts)) {
			print required_prefix[i], "n/a", "invalid-spec";
			failed = 1;
			continue;
		}
		count = prefix_positive_count(required_prefix[i]);
		needed = parts[3] + 0;
		if (count >= needed) {
			print required_prefix[i], count, "ok";
		} else {
			print required_prefix[i], count, "missing-or-low";
			failed = 1;
		}
	}

	if (required_zero_after[0])
		print "require_zero_after_spec", "observed_after", "verdict";
	for (i = 1; i <= required_zero_after[0]; i++) {
		if (!split_spec(required_zero_after[i], parts)) {
			print required_zero_after[i], "n/a", "invalid-spec";
			failed = 1;
			continue;
		}
		seen_count = spec_seen_count(required_zero_after[i]);
		missing_after = spec_after_non_numeric_count(required_zero_after[i]);
		sum = spec_after_sum(required_zero_after[i]);
		if (seen_count == 0) {
			print required_zero_after[i], "missing", "missing";
			failed = 1;
		} else if (missing_after > 0) {
			print required_zero_after[i], "missing", "missing-after";
			failed = 1;
		} else if (sum == 0) {
			print required_zero_after[i], sum, "ok";
		} else {
			print required_zero_after[i], sum, "nonzero-after";
			failed = 1;
		}
	}

	if (forbidden[0])
		print "forbid_spec", "observed_delta", "verdict";
	for (i = 1; i <= forbidden[0]; i++) {
		if (!split_spec(forbidden[i], parts)) {
			print forbidden[i], "n/a", "invalid-spec";
			failed = 1;
			continue;
		}
		seen_count = spec_seen_count(forbidden[i]);
		component_seen = spec_component_seen_count(forbidden[i]);
		if (require_forbidden == 1 && component_seen == 0) {
			print forbidden[i], "n/a", "component-not-captured";
			continue;
		}
		if (require_forbidden == 1 && seen_count == 0) {
			print forbidden[i], "missing", "missing";
			failed = 1;
			continue;
		}
		sum = spec_delta_sum(forbidden[i]);
		if (sum > 0) {
			print forbidden[i], sum, "forbidden-positive";
			failed = 1;
		} else {
			print forbidden[i], sum, "ok";
		}
	}

	exit failed;
}
' "$COUNTERS_FILE"
