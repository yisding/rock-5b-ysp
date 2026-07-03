#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
BASELINE=${BASELINE:-forward-port}
CANDIDATE=${CANDIDATE:-rewrite}
BASELINE_SUMMARY=${BASELINE_SUMMARY:-}
CANDIDATE_SUMMARY=${CANDIDATE_SUMMARY:-}
PERF_MAX_RATIO=${PERF_MAX_RATIO:-}

find_latest_summary()
{
	local profile=$1
	local summary

	summary=$({ find "$CONFORMANCE_ROOT/logs/$profile" -path "*-mpp-suite/summary.tsv" \
		-type f -printf "%T@ %p\n" 2>/dev/null || true; } | sort -nr |
		awk 'NR == 1 { sub(/^[^ ]+ /, ""); print }')
	if [ -z "$summary" ]; then
		echo "No MPP suite summary found for profile '$profile'" >&2
		return 1
	fi

	printf "%s\n" "$summary"
}

if [ -z "$BASELINE_SUMMARY" ]; then
	BASELINE_SUMMARY=$(find_latest_summary "$BASELINE")
fi
if [ -z "$CANDIDATE_SUMMARY" ]; then
	CANDIDATE_SUMMARY=$(find_latest_summary "$CANDIDATE")
fi

if [ ! -f "$BASELINE_SUMMARY" ]; then
	echo "Missing baseline summary: $BASELINE_SUMMARY" >&2
	exit 2
fi
if [ ! -f "$CANDIDATE_SUMMARY" ]; then
	echo "Missing candidate summary: $CANDIDATE_SUMMARY" >&2
	exit 2
fi

awk -v baseline="$BASELINE" -v candidate="$CANDIDATE" \
    -v base_file="$BASELINE_SUMMARY" -v cand_file="$CANDIDATE_SUMMARY" \
    -v perf_max_ratio="$PERF_MAX_RATIO" '
function is_number(value) {
	return value ~ /^[0-9]+([.][0-9]+)?$/;
}

BEGIN {
	FS = "\t";
	failed = 0;
	perf_fail = (perf_max_ratio != "" && perf_max_ratio + 0 > 0);
	perf_limit = perf_max_ratio + 0;
	printf("baseline\t%s\ncandidate\t%s\n\n", base_file, cand_file);
	if (perf_fail)
		printf("perf_max_ratio\t%s\n\n", perf_max_ratio);
	printf("class\tcase\t%s_status\t%s_status\t%s_result\t%s_result\t%s_elapsed_s\t%s_elapsed_s\telapsed_ratio\tverdict\n",
	       baseline, candidate, baseline, candidate, baseline, candidate);
}

FNR == 1 {
	next;
}

FILENAME == base_file {
	class[$3] = $2;
	base_status[$3] = $4;
	base_elapsed[$3] = $5;
	base_result[$3] = $6;
	seen[$3] = 1;
	next;
}

FILENAME == cand_file {
	if (!($3 in seen))
		extra[$3] = 1;
	if (!($3 in class))
		class[$3] = $2;
	cand_status[$3] = $4;
	cand_elapsed[$3] = $5;
	cand_result[$3] = $6;
	seen[$3] = 1;
}

END {
	for (case_name in seen) {
		bs = (case_name in base_status) ? base_status[case_name] : "missing";
		cs = (case_name in cand_status) ? cand_status[case_name] : "missing";
		br = (case_name in base_result) ? base_result[case_name] : "missing";
		cr = (case_name in cand_result) ? cand_result[case_name] : "missing";
		be = (case_name in base_elapsed) ? base_elapsed[case_name] : "missing";
		ce = (case_name in cand_elapsed) ? cand_elapsed[case_name] : "missing";
		ratio = "n/a";
		if (is_number(be) && is_number(ce) && be + 0 > 0)
			ratio = sprintf("%.3f", (ce + 0) / (be + 0));
		verdict = "same";

		if (bs != cs || br != cr)
			verdict = "different";
		if (class[case_name] == "required" && br == "pass" && cr != "pass") {
			verdict = "regression";
			failed = 1;
		}
		if (class[case_name] == "required" && br != "pass" && cr == "pass")
			verdict = "candidate-only-pass";
		if (class[case_name] == "required" && br == "pass" && cr == "pass" &&
		    perf_fail && is_number(be) && is_number(ce) && be + 0 > 0 &&
		    ce + 0 > (be + 0) * perf_limit) {
			verdict = "slowdown";
			failed = 1;
		}

		printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
		       class[case_name], case_name, bs, cs, br, cr, be, ce, ratio, verdict);
	}

	exit failed;
}
' "$BASELINE_SUMMARY" "$CANDIDATE_SUMMARY"
