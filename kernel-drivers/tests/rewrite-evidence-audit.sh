#!/usr/bin/env bash
# Audit whether paired forward-port/rewrite conformance evidence exists.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
BASELINE=${BASELINE:-forward-port}
CANDIDATE=${CANDIDATE:-rewrite}
SUITES=${SUITES:-"mpp librga gstreamer ffmpeg"}
REQUIRE_ARTIFACTS=${REQUIRE_ARTIFACTS:-1}
REQUIRE_COUNTER_DELTAS=${REQUIRE_COUNTER_DELTAS:-1}
REQUIRE_DIAGNOSTIC_PASS=${REQUIRE_DIAGNOSTIC_PASS:-0}
AUDIT_REQUIRED_CASES=${AUDIT_REQUIRED_CASES:-}
PERF_MAX_RATIO=${PERF_MAX_RATIO:-1.25}
AUDIT_COUNTER_CHECKS=${AUDIT_COUNTER_CHECKS:-}
RUN_COMPARATORS=${RUN_COMPARATORS:-1}

if [ -z "$AUDIT_COUNTER_CHECKS" ]; then
	case "$CANDIDATE" in
	*rewrite*)
		AUDIT_COUNTER_CHECKS=1
		;;
	*)
		AUDIT_COUNTER_CHECKS=0
		;;
	esac
fi

usage()
{
	cat <<EOF
Usage: ${0##*/} [--selftest]

Environment:
  CONFORMANCE_ROOT       conformance bundle root (default: ../rockchip-conformance)
  BASELINE               baseline profile (default: forward-port)
  CANDIDATE              candidate profile (default: rewrite)
  SUITES                 suites to audit (default: mpp librga gstreamer ffmpeg)
  REQUIRE_ARTIFACTS=0    allow pass/fail-only suite logs
  REQUIRE_COUNTER_DELTAS=0
                          allow missing debugfs-counters-delta.tsv files
  REQUIRE_DIAGNOSTIC_PASS=1
                          require diagnostic cases recorded in the selected
                          summaries to pass too
  AUDIT_REQUIRED_CASES    whitespace-separated suite:case list that must be
                          present and passing in both profiles; use *:case to
                          match any selected suite
  PERF_MAX_RATIO=1.25    fail comparator-clean audit if a required candidate
                          pass is slower than baseline by this ratio; set 0 to
                          disable the elapsed-time gate
  AUDIT_COUNTER_CHECKS=0 skip candidate counter-content checks. By default this
                          is enabled when CANDIDATE contains "rewrite".
                          Override per-suite specs with
                          MPP_REQUIRED_POSITIVE_COUNTERS,
                          LIBRGA_REQUIRED_POSITIVE_COUNTERS,
                          GSTREAMER_REQUIRED_POSITIVE_COUNTERS,
                          FFMPEG_REQUIRED_POSITIVE_COUNTERS,
                          RKMPPENC_REQUIRED_POSITIVE_COUNTERS, plus matching
                          *_REQUIRED_POSITIVE_COUNTER_PREFIXES and
                          *_REQUIRED_ZERO_AFTER_COUNTERS variables.
  RUN_COMPARATORS=0      skip suite comparator execution
EOF
}

find_latest_summary()
{
	local profile=$1
	local suite=$2
	local summary

	summary=$({ find "$CONFORMANCE_ROOT/logs/$profile" \
		-path "*-$suite-suite/summary.tsv" -type f \
		-printf "%T@ %p\n" 2>/dev/null || true; } |
		sort -nr | awk 'NR == 1 { sub(/^[^ ]+ /, ""); print }')
	if [ -z "$summary" ]; then
		printf "missing latest %s summary for profile %s\n" \
			"$suite" "$profile" >&2
		return 1
	fi

	printf "%s\n" "$summary"
}

check_case_results()
{
	local summary=$1
	local suite=$2
	local profile=$3

	awk -v suite="$suite" -v profile="$profile" \
	    -v require_diagnostic="$REQUIRE_DIAGNOSTIC_PASS" '
	BEGIN {
		FS = "\t";
		required = 0;
		diagnostic = 0;
		failed = 0;
		require_diagnostic = require_diagnostic == "1";
	}
	NR == 1 {
		next;
	}
	$2 == "required" {
		required++;
		if ($6 != "pass") {
			printf("required case failed: profile=%s suite=%s case=%s result=%s status=%s\n",
			       profile, suite, $3, $6, $4) > "/dev/stderr";
			failed++;
		}
	}
	$2 == "diagnostic" {
		diagnostic++;
		if (require_diagnostic && $6 != "pass") {
			printf("diagnostic case failed: profile=%s suite=%s case=%s result=%s status=%s\n",
			       profile, suite, $3, $6, $4) > "/dev/stderr";
			failed++;
		}
	}
	END {
		if (required == 0) {
			printf("no required cases recorded: profile=%s suite=%s summary=%s\n",
			       profile, suite, FILENAME) > "/dev/stderr";
			exit 1;
		}
		exit failed ? 1 : 0;
	}
	' "$summary"
}

check_named_cases()
{
	local summary=$1
	local suite=$2
	local profile=$3
	local spec
	local spec_suite
	local spec_case
	local failed=0

	if [ -z "$AUDIT_REQUIRED_CASES" ]; then
		return 0
	fi

	for spec in $AUDIT_REQUIRED_CASES; do
		case "$spec" in
		*:*)
			spec_suite=${spec%%:*}
			spec_case=${spec#*:}
			;;
		*)
			printf "invalid AUDIT_REQUIRED_CASES entry (want suite:case): %s\n" \
				"$spec" >&2
			return 1
			;;
		esac

		if [ "$spec_suite" != "$suite" ] && [ "$spec_suite" != "*" ]; then
			continue
		fi

		if ! awk -v suite="$suite" -v profile="$profile" \
			-v required_case="$spec_case" '
		BEGIN {
			FS = "\t";
			found = 0;
			failed = 0;
		}
		NR == 1 {
			next;
		}
		$3 == required_case {
			found = 1;
			if ($6 != "pass") {
				printf("audited case failed: profile=%s suite=%s case=%s class=%s result=%s status=%s\n",
				       profile, suite, $3, $2, $6, $4) > "/dev/stderr";
				failed = 1;
			}
		}
		END {
			if (!found) {
				printf("missing audited case: profile=%s suite=%s case=%s summary=%s\n",
				       profile, suite, required_case, FILENAME) > "/dev/stderr";
				exit 1;
			}
			exit failed ? 1 : 0;
		}
		' "$summary"; then
			failed=1
		fi
	done

	return "$failed"
}

suite_selected()
{
	local want=$1
	local suite

	for suite in $SUITES; do
		if [ "$suite" = "$want" ]; then
			return 0
		fi
	done

	return 1
}

validate_named_case_specs()
{
	local spec
	local spec_suite

	if [ -z "$AUDIT_REQUIRED_CASES" ]; then
		return 0
	fi

	for spec in $AUDIT_REQUIRED_CASES; do
		case "$spec" in
		*:*)
			spec_suite=${spec%%:*}
			;;
		*)
			printf "invalid AUDIT_REQUIRED_CASES entry (want suite:case): %s\n" \
				"$spec" >&2
			return 1
			;;
		esac

		if [ "$spec_suite" != "*" ] && ! suite_selected "$spec_suite"; then
			printf "AUDIT_REQUIRED_CASES suite is not selected: %s (SUITES=%s)\n" \
				"$spec_suite" "$SUITES" >&2
			return 1
		fi
	done
}

check_artifacts()
{
	local summary=$1
	local suite=$2
	local profile=$3
	local artifacts

	artifacts="$(dirname "$summary")/artifacts.tsv"
	if [ "$REQUIRE_ARTIFACTS" != "1" ]; then
		printf "artifact audit skipped: profile=%s suite=%s artifacts=%s\n" \
			"$profile" "$suite" "$artifacts"
		return 0
	fi

	if [ ! -s "$artifacts" ]; then
		printf "missing artifact manifest: profile=%s suite=%s path=%s\n" \
			"$profile" "$suite" "$artifacts" >&2
		return 1
	fi

	if ! awk 'NR > 1 { found = 1 } END { exit found ? 0 : 1 }' "$artifacts"; then
		printf "empty artifact manifest: profile=%s suite=%s path=%s\n" \
			"$profile" "$suite" "$artifacts" >&2
		return 1
	fi
}

check_counter_deltas()
{
	local summary=$1
	local suite=$2
	local profile=$3
	local counters

	counters="$(dirname "$summary")/debugfs-counters-delta.tsv"
	if [ "$REQUIRE_COUNTER_DELTAS" != "1" ]; then
		printf "counter audit skipped: profile=%s suite=%s counters=%s\n" \
			"$profile" "$suite" "$counters"
		return 0
	fi

	if [ ! -s "$counters" ]; then
		printf "missing counter delta file: profile=%s suite=%s path=%s\n" \
			"$profile" "$suite" "$counters" >&2
		return 1
	fi

	if ! awk 'NR > 1 { found = 1 } END { exit found ? 0 : 1 }' "$counters"; then
		printf "empty counter delta file: profile=%s suite=%s path=%s\n" \
			"$profile" "$suite" "$counters" >&2
		return 1
	fi
}

set_counter_specs_for_suite()
{
	local suite=$1

	counter_check_positive=
	counter_check_prefix=
	counter_check_zero_after=

	case "$suite" in
	mpp)
		counter_check_positive=${MPP_REQUIRED_POSITIVE_COUNTERS:-}
		counter_check_prefix=${MPP_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
		counter_check_zero_after=${MPP_REQUIRED_ZERO_AFTER_COUNTERS:-}
		;;
	librga)
		counter_check_positive=${LIBRGA_REQUIRED_POSITIVE_COUNTERS:-"rga:started_job_count rga:hw_total_ns"}
		counter_check_prefix=${LIBRGA_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
		counter_check_zero_after=${LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS:-}
		if [ "${LIBRGA_FORCE_ROUTE_B:-0}" = "1" ]; then
			case " $counter_check_positive " in
			*" rga_route_b:attempt "*)
				;;
			*)
				counter_check_positive="$counter_check_positive rga_route_b:attempt"
				;;
			esac
			case " $counter_check_positive " in
			*" rga_route_b:ok "*)
				;;
			*)
				counter_check_positive="$counter_check_positive rga_route_b:ok"
				;;
			esac
			case " $counter_check_zero_after " in
			*" rga_route_b:active "*)
				;;
			*)
				counter_check_zero_after="$counter_check_zero_after rga_route_b:active"
				;;
			esac
		fi
		;;
	gstreamer)
		counter_check_positive=${GSTREAMER_REQUIRED_POSITIVE_COUNTERS:-"mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns"}
		counter_check_prefix=${GSTREAMER_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
		counter_check_zero_after=${GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS:-}
		;;
	ffmpeg)
		counter_check_positive=${FFMPEG_REQUIRED_POSITIVE_COUNTERS:-"mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns"}
		counter_check_prefix=${FFMPEG_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
		counter_check_zero_after=${FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS:-}
		;;
	rkmppenc)
		counter_check_positive=${RKMPPENC_REQUIRED_POSITIVE_COUNTERS:-"mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns"}
		counter_check_prefix=${RKMPPENC_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
		counter_check_zero_after=${RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS:-}
		;;
	esac
}

run_candidate_counter_check()
{
	local summary=$1
	local suite=$2

	if [ "$AUDIT_COUNTER_CHECKS" != "1" ] ||
		[ "$REQUIRE_COUNTER_DELTAS" != "1" ]; then
		return 0
	fi

	set_counter_specs_for_suite "$suite"

	if ! SUMMARY="$summary" \
		REQUIRED_POSITIVE_COUNTERS="$counter_check_positive" \
		REQUIRED_POSITIVE_COUNTER_PREFIXES="$counter_check_prefix" \
		REQUIRED_ZERO_AFTER_COUNTERS="$counter_check_zero_after" \
		REQUIRE_COUNTER_FILE=1 \
		bash "$TEST_DIR/debugfs-counter-check.sh" >/dev/null; then
		printf "candidate counter check failed: suite=%s summary=%s\n" \
			"$suite" "$summary" >&2
		return 1
	fi
}

run_suite_comparator()
{
	local suite=$1
	local baseline_summary=$2
	local candidate_summary=$3
	local comparator="$TEST_DIR/$suite-suite-compare.sh"

	if [ "$RUN_COMPARATORS" != "1" ]; then
		return 0
	fi

	if [ ! -x "$comparator" ]; then
		printf "missing comparator for suite %s: %s\n" "$suite" "$comparator" >&2
		return 1
	fi

	BASELINE="$BASELINE" CANDIDATE="$CANDIDATE" \
		BASELINE_SUMMARY="$baseline_summary" \
		CANDIDATE_SUMMARY="$candidate_summary" \
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
		REQUIRE_ARTIFACTS="$REQUIRE_ARTIFACTS" \
		PERF_MAX_RATIO="$PERF_MAX_RATIO" \
		bash "$comparator" >/dev/null
}

audit_one_suite()
{
	local suite=$1
	local baseline_summary
	local candidate_summary
	local suite_failed=0

	if ! baseline_summary="$(find_latest_summary "$BASELINE" "$suite")"; then
		return 1
	fi
	if ! candidate_summary="$(find_latest_summary "$CANDIDATE" "$suite")"; then
		return 1
	fi

	check_case_results "$baseline_summary" "$suite" "$BASELINE" ||
		suite_failed=1
	check_case_results "$candidate_summary" "$suite" "$CANDIDATE" ||
		suite_failed=1
	check_named_cases "$baseline_summary" "$suite" "$BASELINE" ||
		suite_failed=1
	check_named_cases "$candidate_summary" "$suite" "$CANDIDATE" ||
		suite_failed=1
	check_artifacts "$baseline_summary" "$suite" "$BASELINE" ||
		suite_failed=1
	check_artifacts "$candidate_summary" "$suite" "$CANDIDATE" ||
		suite_failed=1
	check_counter_deltas "$baseline_summary" "$suite" "$BASELINE" ||
		suite_failed=1
	check_counter_deltas "$candidate_summary" "$suite" "$CANDIDATE" ||
		suite_failed=1
	run_candidate_counter_check "$candidate_summary" "$suite" ||
		suite_failed=1
	run_suite_comparator "$suite" "$baseline_summary" "$candidate_summary" ||
		suite_failed=1

	if [ "$suite_failed" -ne 0 ]; then
		return 1
	fi

	printf "evidence ok: suite=%s baseline=%s candidate=%s\n" \
		"$suite" "$baseline_summary" "$candidate_summary"
}

write_fixture_suite()
{
	local root=$1
	local profile=$2
	local suite=$3
	local dir="$root/logs/$profile/20260706-000000-$suite-suite"

	mkdir -p "$dir"
	cat > "$dir/summary.tsv" <<EOF
profile	class	case	status	elapsed_s	result
$profile	required	${suite}_required	0	1.000	pass
$profile	diagnostic	${suite}_diagnostic	0	1.000	pass
EOF
	cat > "$dir/artifacts.tsv" <<EOF
profile	class	case	kind	bytes	sha256
$profile	required	${suite}_required	output	4	0123456789abcdef
EOF
	cat > "$dir/debugfs-counters-delta.tsv" <<EOF
component	counter	before	after	delta
mpp	started_job_count	0	1	1
mpp	hw_total_ns	0	1000	1000
mpp	timeout_count	0	0	0
mpp	iommu_fault_count	0	0	0
rga	started_job_count	0	1	1
rga	hw_total_ns	0	1000	1000
rga	timeout_count	0	0	0
rga	irq_error_count	0	0	0
rga	iommu_fault_count	0	0	0
rga_route_b	attempt	0	1	1
rga_route_b	ok	0	1	1
rga_route_b	active	0	0	0
EOF
}

selftest()
{
	local tmp_root

	tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rk-evidence-audit.XXXXXX")"
	trap 'rm -rf "$tmp_root"' RETURN

	for suite in mpp librga gstreamer ffmpeg rkmppenc; do
		write_fixture_suite "$tmp_root" "$BASELINE" "$suite"
		write_fixture_suite "$tmp_root" "$CANDIDATE" "$suite"
	done

	CONFORMANCE_ROOT="$tmp_root" SUITES="mpp librga gstreamer ffmpeg rkmppenc" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=1 PERF_MAX_RATIO=1.25 "$0" >/dev/null

	CONFORMANCE_ROOT="$tmp_root" SUITES="librga" LIBRGA_FORCE_ROUTE_B=1 \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$0" >/dev/null
	sed -i 's/rga_route_b\tactive\t0\t0\t0/rga_route_b\tactive\t0\t1\t1/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-librga-suite/debugfs-counters-delta.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="librga" LIBRGA_FORCE_ROUTE_B=1 \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$0" >/dev/null 2>&1; then
		printf "selftest expected Route B active-gauge audit to fail\n" >&2
		return 1
	fi
	sed -i 's/rga_route_b\tactive\t0\t1\t1/rga_route_b\tactive\t0\t0\t0/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-librga-suite/debugfs-counters-delta.tsv"

	sed -i 's/rga\tstarted_job_count\t0\t1\t1/rga\tstarted_job_count\t0\t0\t0/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-gstreamer-suite/debugfs-counters-delta.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$0" >/dev/null 2>&1; then
		printf "selftest expected missing candidate hardware counter audit to fail\n" >&2
		return 1
	fi
	CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 AUDIT_COUNTER_CHECKS=0 "$0" >/dev/null
	sed -i 's/rga\tstarted_job_count\t0\t0\t0/rga\tstarted_job_count\t0\t1\t1/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-gstreamer-suite/debugfs-counters-delta.tsv"

	sed -i 's/gstreamer_required\t0\t1.000\tpass/gstreamer_required\t0\t2.000\tpass/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-gstreamer-suite/summary.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=1 PERF_MAX_RATIO=1.25 "$0" >/dev/null 2>&1; then
		printf "selftest expected default performance audit to fail\n" >&2
		return 1
	fi
	CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=1 PERF_MAX_RATIO=0 "$0" >/dev/null
	sed -i 's/gstreamer_required\t0\t2.000\tpass/gstreamer_required\t0\t1.000\tpass/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-gstreamer-suite/summary.tsv"

	rm -f "$tmp_root/logs/$CANDIDATE/20260706-000000-ffmpeg-suite/artifacts.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="ffmpeg" REQUIRE_ARTIFACTS=1 \
		REQUIRE_COUNTER_DELTAS=1 RUN_COMPARATORS=0 "$0" >/dev/null 2>&1; then
		printf "selftest expected missing artifact audit to fail\n" >&2
		return 1
	fi

	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		AUDIT_REQUIRED_CASES="gstreamer:not_recorded" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$0" >/dev/null 2>&1; then
		printf "selftest expected missing named case audit to fail\n" >&2
		return 1
	fi

	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		AUDIT_REQUIRED_CASES="rkmppenc:rkmppenc_avhw_h264_to_hevc_rga_resize" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$0" >/dev/null 2>&1; then
		printf "selftest expected unselected named-case suite audit to fail\n" >&2
		return 1
	fi

	sed -i 's/gstreamer_diagnostic\t0\t1.000\tpass/gstreamer_diagnostic\t1\t1.000\tfail/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-gstreamer-suite/summary.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		REQUIRE_DIAGNOSTIC_PASS=1 REQUIRE_ARTIFACTS=1 \
		REQUIRE_COUNTER_DELTAS=1 RUN_COMPARATORS=0 "$0" >/dev/null 2>&1; then
		printf "selftest expected diagnostic failure audit to fail\n" >&2
		return 1
	fi
	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		AUDIT_REQUIRED_CASES="gstreamer:gstreamer_diagnostic" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$0" >/dev/null 2>&1; then
		printf "selftest expected named diagnostic failure audit to fail\n" >&2
		return 1
	fi

	printf "PASS: rewrite evidence audit selftest\n"
}

case "${1:-}" in
--help|-h)
	usage
	exit 0
	;;
--selftest)
	selftest
	exit 0
	;;
"")
	;;
*)
	usage >&2
	exit 2
	;;
esac

validate_named_case_specs

failed=0
for suite in $SUITES; do
	if ! audit_one_suite "$suite"; then
		failed=1
	fi
done

if [ "$failed" -ne 0 ]; then
	printf "rewrite evidence audit failed\n" >&2
	exit 1
fi

printf "rewrite evidence audit passed\n"
