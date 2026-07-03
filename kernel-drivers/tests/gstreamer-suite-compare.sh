#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
BASELINE=${BASELINE:-forward-port}
CANDIDATE=${CANDIDATE:-rewrite}
BASELINE_SUMMARY=${BASELINE_SUMMARY:-}
CANDIDATE_SUMMARY=${CANDIDATE_SUMMARY:-}

find_latest_summary()
{
	local profile=$1
	local summary

	summary=$({ find "$CONFORMANCE_ROOT/logs/$profile" -path "*-gstreamer-suite/summary.tsv" \
		-type f -printf "%T@ %p\n" 2>/dev/null || true; } | sort -nr |
		awk 'NR == 1 { sub(/^[^ ]+ /, ""); print }')
	if [ -z "$summary" ]; then
		echo "No GStreamer suite summary found for profile '$profile'" >&2
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
    -v base_file="$BASELINE_SUMMARY" -v cand_file="$CANDIDATE_SUMMARY" '
BEGIN {
	FS = "\t";
	failed = 0;
	printf("baseline\t%s\ncandidate\t%s\n\n", base_file, cand_file);
	printf("class\tcase\t%s_status\t%s_status\t%s_result\t%s_result\tverdict\n",
	       baseline, candidate, baseline, candidate);
}

FNR == 1 {
	next;
}

FILENAME == base_file {
	class[$3] = $2;
	base_status[$3] = $4;
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
	cand_result[$3] = $6;
	seen[$3] = 1;
}

END {
	for (case_name in seen) {
		bs = (case_name in base_status) ? base_status[case_name] : "missing";
		cs = (case_name in cand_status) ? cand_status[case_name] : "missing";
		br = (case_name in base_result) ? base_result[case_name] : "missing";
		cr = (case_name in cand_result) ? cand_result[case_name] : "missing";
		verdict = "same";

		if (bs != cs || br != cr)
			verdict = "different";
		if (class[case_name] == "required" && br == "pass" && cr != "pass") {
			verdict = "regression";
			failed = 1;
		}
		if (class[case_name] == "required" && br != "pass" && cr == "pass")
			verdict = "candidate-only-pass";

		printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
		       class[case_name], case_name, bs, cs, br, cr, verdict);
	}

	exit failed;
}
' "$BASELINE_SUMMARY" "$CANDIDATE_SUMMARY"
