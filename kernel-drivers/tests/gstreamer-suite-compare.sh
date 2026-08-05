#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: LGPL-2.1-or-later
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/build/rockchip-conformance"}
BASELINE=${BASELINE:-forward-port}
CANDIDATE=${CANDIDATE:-rewrite}
BASELINE_SUMMARY=${BASELINE_SUMMARY:-}
CANDIDATE_SUMMARY=${CANDIDATE_SUMMARY:-}
PERF_MAX_RATIO=${PERF_MAX_RATIO:-}
REQUIRE_ARTIFACTS=${REQUIRE_ARTIFACTS:-1}

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

BASELINE_ARTIFACTS=${BASELINE_ARTIFACTS:-"$(dirname "$BASELINE_SUMMARY")/artifacts.tsv"}
CANDIDATE_ARTIFACTS=${CANDIDATE_ARTIFACTS:-"$(dirname "$CANDIDATE_SUMMARY")/artifacts.tsv"}

set +e
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
		if (class[case_name] == "required") {
			# Count only cases present on BOTH sides. Counting the union let a
			# single candidate-only row satisfy the guard, so an empty *baseline*
			# -- the exact "find_latest_summary picked by mtime from a run that
			# produced no cases" scenario -- still exited 0 via
			# candidate-only-pass, and the error text below described an
			# intersection test the code did not implement.
			if (case_name in base_result && case_name in cand_result)
				compared++;
			if (br == "pass" && cr != "pass") {
				verdict = "regression";
				failed = 1;
			}
			# A required case failing on BOTH sides is not a regression, but it
			# is not a pass either. Without this, a baseline picked by mtime from
			# an unsuccessful run (mpp-suite.sh emits missing-env/missing/timeout
			# rows for cases it could not run) permanently exempted those cases
			# in every later candidate.
			if (br != "pass" && cr != "pass") {
				verdict = "required-fail-both";
				failed = 1;
			}
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

	# Comparing nothing used to exit 0: the loop simply did not run, so `failed`
	# stayed 0 and the caller recorded "no regression". Header-only or empty
	# summaries reach here whenever find_latest_summary picks by mtime from a run
	# that produced no cases. The artifact half of this script already had the
	# equivalent guard.
	if (compared == 0) {
		printf("ERROR: no required cases compared -- baseline %s and candidate %s share no required rows, so this comparison proves nothing\n", base_file, cand_file) > "/dev/stderr";
		failed = 1;
	}

	exit failed;
}
' "$BASELINE_SUMMARY" "$CANDIDATE_SUMMARY"
summary_status=$?
set -e

artifact_status=0
if [ -f "$BASELINE_ARTIFACTS" ] && [ -f "$CANDIDATE_ARTIFACTS" ]; then
	set +e
	awk -v baseline="$BASELINE" -v candidate="$CANDIDATE" \
	    -v base_file="$BASELINE_ARTIFACTS" -v cand_file="$CANDIDATE_ARTIFACTS" \
	    -v require_artifacts="$REQUIRE_ARTIFACTS" '
	BEGIN {
		FS = "\t";
		failed = 0;
		artifact_count = 0;
		require = (require_artifacts != "" && require_artifacts != "0");
		printf("\nartifact_baseline\t%s\nartifact_candidate\t%s\n\n",
		       base_file, cand_file);
		printf("class\tcase\tkind\t%s_bytes\t%s_bytes\t%s_sha256\t%s_sha256\tverdict\n",
		       baseline, candidate, baseline, candidate);
	}

	FNR == 1 {
		next;
	}

	FILENAME == base_file {
		key = $3 "\t" $4;
		class[key] = $2;
		base_bytes[key] = $5;
		base_sha[key] = $6;
		seen[key] = 1;
		next;
	}

	FILENAME == cand_file {
		key = $3 "\t" $4;
		if (!(key in class))
			class[key] = $2;
		cand_bytes[key] = $5;
		cand_sha[key] = $6;
		seen[key] = 1;
	}

	END {
		for (key in seen) {
			artifact_count++;
			split(key, parts, "\t");
			case_name = parts[1];
			kind = parts[2];
			bb = (key in base_bytes) ? base_bytes[key] : "missing";
			cb = (key in cand_bytes) ? cand_bytes[key] : "missing";
			bs = (key in base_sha) ? base_sha[key] : "missing";
			cs = (key in cand_sha) ? cand_sha[key] : "missing";
			verdict = "same";

			if (bb == "missing" || cb == "missing" ||
			    bs == "missing" || cs == "missing")
				verdict = "artifact-missing";
			else if (bb != cb || bs != cs)
				verdict = "artifact-mismatch";

			if (class[key] == "required" && verdict != "same")
				failed = 1;

			printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
			       class[key], case_name, kind, bb, cb, bs, cs, verdict);
		}

		if (require && artifact_count == 0) {
			printf("required\t<none>\t<none>\tmissing\tmissing\tmissing\tmissing\tartifact-missing\n");
			failed = 1;
		}

		exit failed;
	}
	' "$BASELINE_ARTIFACTS" "$CANDIDATE_ARTIFACTS"
	artifact_status=$?
	set -e
else
	echo
	echo "artifact_compare	skipped"
	echo "artifact_baseline	$BASELINE_ARTIFACTS"
	echo "artifact_candidate	$CANDIDATE_ARTIFACTS"
	echo "reason	missing artifact manifest from one or both runs"
	if [ -n "$REQUIRE_ARTIFACTS" ] && [ "$REQUIRE_ARTIFACTS" != "0" ]; then
		echo "hint	set REQUIRE_ARTIFACTS=0 for legacy pass/fail-only comparisons"
		artifact_status=1
	fi
fi

if [ "$summary_status" -ne 0 ] || [ "$artifact_status" -ne 0 ]; then
	exit 1
fi
