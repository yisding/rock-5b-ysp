#!/usr/bin/env bash
# Audit whether paired forward-port/rewrite conformance evidence exists.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
# The --selftest cases re-invoke this script. They used $0, which is only a usable
# path when the caller passed one: `cd kernel-drivers/tests &&
# bash rewrite-evidence-audit.sh --selftest` died with "command not found" (rc 127)
# because a bare name is searched on PATH. Resolve it from BASH_SOURCE instead.
SELF="$TEST_DIR/$(basename "${BASH_SOURCE[0]}")"

CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
LIBRGA_FORCE_RGA_USERPTR_IOMMU=${LIBRGA_FORCE_RGA_USERPTR_IOMMU:-${LIBRGA_FORCE_ROUTE_B:-0}}
BASELINE=${BASELINE:-forward-port}
CANDIDATE=${CANDIDATE:-rewrite}
SUITES=${SUITES:-"mpp librga gstreamer ffmpeg"}
REQUIRE_ARTIFACTS=${REQUIRE_ARTIFACTS:-1}
REQUIRE_COUNTER_DELTAS=${REQUIRE_COUNTER_DELTAS:-1}
REQUIRE_DMESG_EVIDENCE=${REQUIRE_DMESG_EVIDENCE:-1}
REQUIRE_KUNIT_EVIDENCE=${REQUIRE_KUNIT_EVIDENCE:-}
KUNIT_EVIDENCE_SUITES=${KUNIT_EVIDENCE_SUITES:-"rk_mpp_rewrite:84 rockchip-rga-rewrite:148"}
KUNIT_MANIFEST=${KUNIT_MANIFEST:-"$TEST_DIR/rewrite-kunit-manifest.tsv"}
KUNIT_EXPECTED_SOURCE_COMMIT=${KUNIT_EXPECTED_SOURCE_COMMIT:-}
KUNIT_EXPECTED_CONFIG_SHA256=${KUNIT_EXPECTED_CONFIG_SHA256:-}
KUNIT_EXPECTED_PACKAGE_ID=${KUNIT_EXPECTED_PACKAGE_ID:-}
REQUIRE_DIAGNOSTIC_PASS=${REQUIRE_DIAGNOSTIC_PASS:-0}
AUDIT_REQUIRED_CASES=${AUDIT_REQUIRED_CASES:-}
REQUIRE_MPP_CORE_CASES=${REQUIRE_MPP_CORE_CASES:-}
MPP_CORE_CASE_NAMES=${MPP_CORE_CASE_NAMES:-"mpp_info_test mpi_dec_h264 mpi_dec_h265 mpi_dec_vp9 mpi_dec_avs2 mpi_dec_mt_h264 mpi_dec_multi_h265 mpi_enc_h264 mpi_enc_h265 mpi_enc_h264_slice mpi_enc_h265_slice mpi_enc_mt_h265 mpi_rc2_h264"}
PERF_MAX_RATIO=${PERF_MAX_RATIO:-1.25}
AUDIT_COUNTER_CHECKS=${AUDIT_COUNTER_CHECKS:-}
RUN_COMPARATORS=${RUN_COMPARATORS:-1}

if [ -z "$REQUIRE_KUNIT_EVIDENCE" ]; then
	case "$CANDIDATE" in
	*rewrite*) REQUIRE_KUNIT_EVIDENCE=1 ;;
	*) REQUIRE_KUNIT_EVIDENCE=0 ;;
	esac
fi
if [ -z "$REQUIRE_MPP_CORE_CASES" ]; then
	case "$CANDIDATE" in
	*rewrite*) REQUIRE_MPP_CORE_CASES=1 ;;
	*) REQUIRE_MPP_CORE_CASES=0 ;;
	esac
fi

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
  REQUIRE_DMESG_EVIDENCE=0
                          allow missing or non-clean dmesg-scan.tsv records
  REQUIRE_KUNIT_EVIDENCE=0
                          allow a rewrite candidate without a persisted green
                          booted-KUnit report from rewrite-conformance-run.sh
  KUNIT_EXPECTED_SOURCE_COMMIT
                          require the KUnit source commit to match this prefix
  KUNIT_EXPECTED_CONFIG_SHA256
                          require the KUnit config to match this SHA-256
  KUNIT_EXPECTED_PACKAGE_ID
                          require this exact image package=name/version identity
  REQUIRE_DIAGNOSTIC_PASS=1
                          require diagnostic cases recorded in the selected
                          summaries to pass too
  AUDIT_REQUIRED_CASES    whitespace-separated suite:case list that must be
                          present and passing in both profiles; use *:case to
                          match any selected suite
  REQUIRE_MPP_CORE_CASES=0
                          do not add the representative official-MPP codec,
                          multi-thread, multi-instance, encode, and RC cases to
                          audits that select the MPP suite (enabled by default
                          when CANDIDATE contains "rewrite")
  MPP_CORE_CASE_NAMES     override the default official-MPP core case list
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

add_default_core_cases()
{
	local case_name

	if [ "$REQUIRE_MPP_CORE_CASES" != "1" ]; then
		return 0
	fi
	if ! suite_selected mpp; then
		return 0
	fi

	for case_name in $MPP_CORE_CASE_NAMES; do
		AUDIT_REQUIRED_CASES="$AUDIT_REQUIRED_CASES mpp:$case_name"
	done
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

check_core_mpp_artifacts()
{
	local summary=$1
	local suite=$2
	local profile=$3
	local artifacts
	local case_name

	if [ "$suite" != "mpp" ] || [ "$REQUIRE_MPP_CORE_CASES" != "1" ] ||
		[ "$REQUIRE_ARTIFACTS" != "1" ]; then
		return 0
	fi

	artifacts="$(dirname "$summary")/artifacts.tsv"
	for case_name in $MPP_CORE_CASE_NAMES; do
		if [ "$case_name" = "mpp_info_test" ]; then
			continue
		fi
		if ! awk -F '\t' -v required_case="$case_name" '
			NR == 1 { next }
			$3 == required_case && $5 ~ /^[0-9]+$/ && $5 + 0 > 0 &&
			$6 != "" && $6 != "missing" {
				found = 1;
			}
			END { exit found ? 0 : 1 }
		' "$artifacts"; then
			printf "missing core MPP artifact: profile=%s case=%s path=%s (decode runs need MPP_DUMP_OUTPUTS=1)\n" \
				"$profile" "$case_name" "$artifacts" >&2
			return 1
		fi
	done
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

check_dmesg_evidence()
{
	local summary=$1
	local suite=$2
	local profile=$3
	local report

	report="$(dirname "$summary")/dmesg-scan.tsv"
	if [ "$REQUIRE_DMESG_EVIDENCE" != "1" ]; then
		printf "dmesg audit skipped: profile=%s suite=%s report=%s\n" \
			"$profile" "$suite" "$report"
		return 0
	fi

	if [ ! -s "$report" ]; then
		printf "missing dmesg scan evidence: profile=%s suite=%s path=%s\n" \
			"$profile" "$suite" "$report" >&2
		return 1
	fi

	if ! awk -F '\t' '
		$1 == "status" {
			found = 1;
			status = $2;
		}
		END {
			exit found && status == "clean" ? 0 : 1;
		}
	' "$report"; then
		printf "dmesg scan is not clean: profile=%s suite=%s path=%s\n" \
			"$profile" "$suite" "$report" >&2
		return 1
	fi
}

check_kunit_evidence()
{
	local candidate_summary=$1
	local audit_suite=$2
	local candidate_dir
	local candidate_run
	local run_id
	local report
	local dmesg_report
	local spec
	local kunit_suite
	local expected
	local manifest_hash
	local report_release
	local report_source
	local report_config
	local report_package
	local failed=0

	if [ "$REQUIRE_KUNIT_EVIDENCE" != "1" ]; then
		return 0
	fi

	candidate_dir=$(dirname "$candidate_summary")
	candidate_run=$(basename "$candidate_dir")
	case "$candidate_run" in
	*"-$audit_suite-suite")
		run_id=${candidate_run%-"$audit_suite"-suite}
		;;
	*)
		printf "cannot correlate candidate suite with KUnit run: suite=%s summary=%s\n" \
			"$audit_suite" "$candidate_summary" >&2
		return 1
		;;
	esac
	report="$(dirname "$candidate_dir")/$run_id-kunit.tsv"
	if [ ! -s "$report" ]; then
		printf "missing run-correlated booted KUnit evidence: candidate=%s suite=%s run=%s report=%s\n" \
			"$CANDIDATE" "$audit_suite" "$run_id" "$report" >&2
		return 1
	fi
	dmesg_report="$(dirname "$candidate_dir")/$run_id-kunit-dmesg-scan.tsv"
	if [ ! -s "$dmesg_report" ]; then
		printf "missing run-correlated KUnit boot-log evidence: candidate=%s suite=%s run=%s report=%s\n" \
			"$CANDIDATE" "$audit_suite" "$run_id" "$dmesg_report" >&2
		return 1
	fi
	read -r report_release report_source report_config report_package < <(
		awk -F '\t' 'NR == 2 { print $9, $10, $11, $12 }' "$report"
	)
	if ! awk -F '\t' -v release="$report_release" \
		-v source="$report_source" -v config="$report_config" \
		-v package="$report_package" '
		$1 == "status" { status = $2 }
		$1 == "interval_status" { interval_status = $2 }
		$1 == "interval_lines" { interval_lines = $2 }
		$1 == "fatal_lines" { fatal_lines = $2 }
		$1 == "lockdep_state" { lockdep_state = $2 }
		$1 == "kernel_release" { kernel_release = $2 }
		$1 == "source_commit" { source_commit = $2 }
		$1 == "config_sha256" { config_sha256 = $2 }
		$1 == "package_id" { package_id = $2 }
		END {
			exit status == "clean" && interval_status == 0 &&
			     interval_lines > 0 && fatal_lines == 0 &&
			     lockdep_state == 1 &&
			     kernel_release == release &&
			     source_commit == source &&
			     config_sha256 == config &&
			     package_id == package ? 0 : 1;
		}
	' "$dmesg_report"; then
		printf "KUnit boot-log evidence is incomplete, fatal, or has disabled lockdep: report=%s\n" \
			"$dmesg_report" >&2
		return 1
	fi

	for spec in $KUNIT_EVIDENCE_SUITES; do
		kunit_suite=${spec%%:*}
		expected=${spec#*:}
		manifest_hash=$(awk -F '\t' -v suite="$kunit_suite" \
			'$1 == suite { print $3 }' "$KUNIT_MANIFEST")
		if [ -z "$manifest_hash" ]; then
			printf "missing KUnit manifest identity: suite=%s manifest=%s\n" \
				"$kunit_suite" "$KUNIT_MANIFEST" >&2
			failed=1
			continue
		fi
		if ! awk -F '\t' -v suite="$kunit_suite" -v expected="$expected" \
			-v manifest_hash="$manifest_hash" \
			-v expected_source="$KUNIT_EXPECTED_SOURCE_COMMIT" \
			-v expected_config="$KUNIT_EXPECTED_CONFIG_SHA256" \
			-v expected_package="$KUNIT_EXPECTED_PACKAGE_ID" \
			-v report_release="$report_release" \
			-v report_source="$report_source" \
			-v report_config="$report_config" \
			-v report_package="$report_package" '
			NR == 1 { next }
			$1 == suite {
				seen++;
				if ($2 != expected || $3 != expected || $4 != expected ||
				    $5 != 0 || $6 != 0 || $7 != "ok" || $8 != "pass" ||
				    $9 == "" || $10 !~ /^[0-9a-f]{12,40}$/ ||
				    index($9, "-g" substr($10, 1, 12)) == 0 ||
				    $11 !~ /^[0-9a-f]{64}$/ || $12 == "" ||
				    $13 != manifest_hash ||
				    $9 != report_release || $10 != report_source ||
				    $11 != report_config || $12 != report_package ||
				    (expected_source != "" &&
				     index($10, expected_source) != 1) ||
				    (expected_config != "" && $11 != expected_config) ||
				    (expected_package != "" && $12 != expected_package))
					bad = 1;
			}
			END { exit seen == 1 && !bad ? 0 : 1 }
		' "$report"; then
			printf "KUnit evidence is missing or not green: suite=%s expected=%s report=%s\n" \
				"$kunit_suite" "$expected" "$report" >&2
			failed=1
		fi
	done

	if [ "$failed" -ne 0 ]; then
		return 1
	fi
	printf "KUnit evidence ok: candidate=%s suite=%s run=%s report=%s boot_log=%s\n" \
		"$CANDIDATE" "$audit_suite" "$run_id" "$report" "$dmesg_report"
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
		counter_check_zero_after=${MPP_REQUIRED_ZERO_AFTER_COUNTERS:-"mpp:import_count mpp:queued_job_count"}
		;;
	librga)
		counter_check_positive=${LIBRGA_REQUIRED_POSITIVE_COUNTERS:-"rga:started_job_count rga:hw_total_ns rga:release_fence_count"}
		counter_check_prefix=${LIBRGA_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
		counter_check_zero_after=${LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS:-"rga:import_count rga:shadow_head_active_count rga:shadow_tail_active_count *:active"}
		if [ "$LIBRGA_FORCE_RGA_USERPTR_IOMMU" = "1" ]; then
			case " $counter_check_positive " in
			*" *:attempt "*)
				;;
			*)
				counter_check_positive="$counter_check_positive *:attempt"
				;;
			esac
			case " $counter_check_positive " in
			*" *:ok "*)
				;;
			*)
				counter_check_positive="$counter_check_positive *:ok"
				;;
			esac
		fi
		;;
	gstreamer)
		counter_check_positive=${GSTREAMER_REQUIRED_POSITIVE_COUNTERS:-"mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns"}
		counter_check_prefix=${GSTREAMER_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
		counter_check_zero_after=${GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS:-"mpp:import_count mpp:queued_job_count rga:import_count rga:shadow_head_active_count rga:shadow_tail_active_count"}
		;;
	ffmpeg)
		counter_check_positive=${FFMPEG_REQUIRED_POSITIVE_COUNTERS:-"mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns"}
		counter_check_prefix=${FFMPEG_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
		counter_check_zero_after=${FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS:-"mpp:import_count mpp:queued_job_count rga:import_count rga:shadow_head_active_count rga:shadow_tail_active_count"}
		;;
	rkmppenc)
		counter_check_positive=${RKMPPENC_REQUIRED_POSITIVE_COUNTERS:-"mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns"}
		counter_check_prefix=${RKMPPENC_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
		counter_check_zero_after=${RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS:-"mpp:import_count mpp:queued_job_count rga:import_count rga:shadow_head_active_count rga:shadow_tail_active_count"}
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
		REQUIRE_FORBIDDEN_COUNTERS=1 \
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
	check_core_mpp_artifacts "$baseline_summary" "$suite" "$BASELINE" ||
		suite_failed=1
	check_core_mpp_artifacts "$candidate_summary" "$suite" "$CANDIDATE" ||
		suite_failed=1
	check_counter_deltas "$baseline_summary" "$suite" "$BASELINE" ||
		suite_failed=1
	check_counter_deltas "$candidate_summary" "$suite" "$CANDIDATE" ||
		suite_failed=1
	check_dmesg_evidence "$baseline_summary" "$suite" "$BASELINE" ||
		suite_failed=1
	check_dmesg_evidence "$candidate_summary" "$suite" "$CANDIDATE" ||
		suite_failed=1
	check_kunit_evidence "$candidate_summary" "$suite" ||
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
	local case_name
	local kind

	mkdir -p "$dir"
	cat > "$dir/summary.tsv" <<EOF
profile	class	case	status	elapsed_s	result
$profile	required	${suite}_required	0	1.000	pass
$profile	diagnostic	${suite}_diagnostic	0	1.000	pass
EOF
	if [ "$suite" = "mpp" ]; then
		for case_name in $MPP_CORE_CASE_NAMES; do
			printf "%s\trequired\t%s\t0\t1.000\tpass\n" \
				"$profile" "$case_name" >> "$dir/summary.tsv"
		done
	fi
	cat > "$dir/artifacts.tsv" <<EOF
profile	class	case	kind	bytes	sha256
$profile	required	${suite}_required	output	4	0123456789abcdef
EOF
	if [ "$suite" = "mpp" ]; then
		for case_name in $MPP_CORE_CASE_NAMES; do
			if [ "$case_name" = "mpp_info_test" ]; then
				continue
			fi
			case "$case_name" in
			mpi_dec_*) kind=decoded ;;
			*) kind=encoded ;;
			esac
			printf "%s\trequired\t%s\t%s\t4\t0123456789abcdef\n" \
				"$profile" "$case_name" "$kind" >> "$dir/artifacts.tsv"
		done
	fi
	cat > "$dir/debugfs-counters-delta.tsv" <<EOF
component	counter	before	after	delta
mpp	started_job_count	0	1	1
mpp	hw_total_ns	0	1000	1000
mpp	import_count	0	0	0
mpp	queued_job_count	0	0	0
mpp	timeout_count	0	0	0
mpp	recovery_failure_count	0	0	0
mpp	iommu_fault_count	0	0	0
mpp	spurious_irq_count	0	0	0
rga	started_job_count	0	1	1
rga	hw_total_ns	0	1000	1000
rga	release_fence_count	0	1	1
rga	import_count	0	0	0
rga	shadow_head_active_count	0	0	0
rga	shadow_tail_active_count	0	0	0
rga	timeout_count	0	0	0
rga	irq_error_count	0	0	0
rga	irq_spurious_count	0	0	0
rga	rga2_config_error_count	0	0	0
rga	iommu_fault_count	0	0	0
rga	recovery_failure_count	0	0	0
rga	shadow_setup_failure_count	0	0	0
rga_userptr_iommu	attempt	0	1	1
rga_userptr_iommu	ok	0	1	1
rga_userptr_iommu	active	0	0	0
EOF
	cat > "$dir/dmesg-scan.tsv" <<EOF
field	value
status	clean
new_lines	0
fatal_lines	0
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
	mkdir -p "$tmp_root/logs/$CANDIDATE"
	cat > "$tmp_root/logs/$CANDIDATE/20260706-000000-kunit.tsv" <<EOF
suite	expected_cases	plan_cases	result_cases	failed_cases	skipped_cases	summary	verdict	kernel_release	source_commit	config_sha256	package_id	ordered_case_names_sha256
rk_mpp_rewrite	84	84	84	0	0	ok	pass	6.18.0-rewrite-g0123456789ab	0123456789abcdef0123456789abcdef01234567	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	linux-image-test=1	19262f865967585574d51bef7e6c120765a3d0645592510f25715ae04f9ca1fe
rockchip-rga-rewrite	148	148	148	0	0	ok	pass	6.18.0-rewrite-g0123456789ab	0123456789abcdef0123456789abcdef01234567	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa	linux-image-test=1	251a81835636d0f7df3ef0a0155a8b8f93ecd4ed0c2795077d514de703d1fe69
EOF
	cat > "$tmp_root/logs/$CANDIDATE/20260706-000000-kunit-dmesg-scan.tsv" <<EOF
field	value
status	clean
interval_status	0
interval_lines	232
fatal_lines	0
lockdep_state	1
kernel_release	6.18.0-rewrite-g0123456789ab
source_commit	0123456789abcdef0123456789abcdef01234567
config_sha256	aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
package_id	linux-image-test=1
EOF
	mv "$tmp_root/logs/$CANDIDATE/20260706-000000-kunit.tsv" \
		"$tmp_root/logs/$CANDIDATE/20260705-000000-kunit.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="mpp" \
		REQUIRE_KUNIT_EVIDENCE=1 REQUIRE_ARTIFACTS=1 \
		REQUIRE_COUNTER_DELTAS=1 REQUIRE_DMESG_EVIDENCE=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected stale KUnit evidence to fail run correlation\n" >&2
		return 1
	fi
	mv "$tmp_root/logs/$CANDIDATE/20260705-000000-kunit.tsv" \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-kunit.tsv"

	CONFORMANCE_ROOT="$tmp_root" SUITES="mpp librga gstreamer ffmpeg rkmppenc" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		REQUIRE_DMESG_EVIDENCE=1 \
		RUN_COMPARATORS=1 PERF_MAX_RATIO=1.25 "$SELF" >/dev/null

	sed -i 's/status\tclean/status\tfatal/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-mpp-suite/dmesg-scan.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="mpp" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		REQUIRE_DMESG_EVIDENCE=1 RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected fatal dmesg evidence to fail\n" >&2
		return 1
	fi
	sed -i 's/status\tfatal/status\tclean/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-mpp-suite/dmesg-scan.tsv"

	sed -i 's/rk_mpp_rewrite\t84\t84\t84\t0\t0\tok\tpass/rk_mpp_rewrite\t84\t84\t84\t1\t0\tnot-ok\tfail/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-kunit.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="mpp" \
		REQUIRE_KUNIT_EVIDENCE=1 REQUIRE_ARTIFACTS=1 \
		REQUIRE_COUNTER_DELTAS=1 REQUIRE_DMESG_EVIDENCE=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected failing KUnit evidence to fail\n" >&2
		return 1
	fi
	sed -i 's/rk_mpp_rewrite\t84\t84\t84\t1\t0\tnot-ok\tfail/rk_mpp_rewrite\t84\t84\t84\t0\t0\tok\tpass/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-kunit.tsv"

	sed -i 's/status\tclean/status\tfatal/; s/fatal_lines\t0/fatal_lines\t1/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-kunit-dmesg-scan.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="mpp" \
		REQUIRE_KUNIT_EVIDENCE=1 REQUIRE_ARTIFACTS=1 \
		REQUIRE_COUNTER_DELTAS=1 REQUIRE_DMESG_EVIDENCE=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected fatal KUnit boot-log evidence to fail\n" >&2
		return 1
	fi
	sed -i 's/status\tfatal/status\tclean/; s/fatal_lines\t1/fatal_lines\t0/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-kunit-dmesg-scan.tsv"

	sed -i 's/lockdep_state\t1/lockdep_state\t0/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-kunit-dmesg-scan.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="mpp" \
		REQUIRE_KUNIT_EVIDENCE=1 REQUIRE_ARTIFACTS=1 \
		REQUIRE_COUNTER_DELTAS=1 REQUIRE_DMESG_EVIDENCE=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected disabled-lockdep KUnit evidence to fail\n" >&2
		return 1
	fi
	sed -i 's/lockdep_state\t0/lockdep_state\t1/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-kunit-dmesg-scan.tsv"

	sed -i '/\tmpi_dec_avs2\tdecoded\t/d' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-mpp-suite/artifacts.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="mpp" \
		REQUIRE_MPP_CORE_CASES=1 REQUIRE_ARTIFACTS=1 \
		REQUIRE_COUNTER_DELTAS=1 REQUIRE_DMESG_EVIDENCE=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected missing AVS2 artifact to fail\n" >&2
		return 1
	fi
	printf "%s\trequired\tmpi_dec_avs2\tdecoded\t4\t0123456789abcdef\n" \
		"$CANDIDATE" >> \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-mpp-suite/artifacts.tsv"

	sed -i '/\tmpi_dec_multi_h265\t/d' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-mpp-suite/summary.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="mpp" \
		REQUIRE_MPP_CORE_CASES=1 REQUIRE_ARTIFACTS=1 \
		REQUIRE_COUNTER_DELTAS=1 REQUIRE_DMESG_EVIDENCE=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected missing core MPP case to fail\n" >&2
		return 1
	fi
	printf "%s\trequired\tmpi_dec_multi_h265\t0\t1.000\tpass\n" \
		"$CANDIDATE" >> \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-mpp-suite/summary.tsv"

	CONFORMANCE_ROOT="$tmp_root" SUITES="librga" LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null
	sed -i 's/rga_userptr_iommu\tactive\t0\t0\t0/rga_userptr_iommu\tactive\t0\t1\t1/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-librga-suite/debugfs-counters-delta.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="librga" LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected RGA userptr-IOMMU active-gauge audit to fail\n" >&2
		return 1
	fi
	sed -i 's/rga_userptr_iommu\tactive\t0\t1\t1/rga_userptr_iommu\tactive\t0\t0\t0/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-librga-suite/debugfs-counters-delta.tsv"

	sed -i 's/rga\timport_count\t0\t0\t0/rga\timport_count\t0\t1\t1/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-librga-suite/debugfs-counters-delta.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="librga" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected retained RGA import audit to fail\n" >&2
		return 1
	fi
	sed -i 's/rga\timport_count\t0\t1\t1/rga\timport_count\t0\t0\t0/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-librga-suite/debugfs-counters-delta.tsv"

	sed -i 's/mpp\timport_count\t0\t0\t0/mpp\timport_count\t0\t1\t1/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-mpp-suite/debugfs-counters-delta.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="mpp" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected retained MPP import audit to fail\n" >&2
		return 1
	fi
	sed -i 's/mpp\timport_count\t0\t1\t1/mpp\timport_count\t0\t0\t0/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-mpp-suite/debugfs-counters-delta.tsv"

	sed -i 's/rga\tstarted_job_count\t0\t1\t1/rga\tstarted_job_count\t0\t0\t0/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-gstreamer-suite/debugfs-counters-delta.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected missing candidate hardware counter audit to fail\n" >&2
		return 1
	fi
	CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 AUDIT_COUNTER_CHECKS=0 "$SELF" >/dev/null
	sed -i 's/rga\tstarted_job_count\t0\t0\t0/rga\tstarted_job_count\t0\t1\t1/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-gstreamer-suite/debugfs-counters-delta.tsv"

	sed -i 's/gstreamer_required\t0\t1.000\tpass/gstreamer_required\t0\t2.000\tpass/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-gstreamer-suite/summary.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=1 PERF_MAX_RATIO=1.25 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected default performance audit to fail\n" >&2
		return 1
	fi
	CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=1 PERF_MAX_RATIO=0 "$SELF" >/dev/null
	sed -i 's/gstreamer_required\t0\t2.000\tpass/gstreamer_required\t0\t1.000\tpass/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-gstreamer-suite/summary.tsv"

	rm -f "$tmp_root/logs/$CANDIDATE/20260706-000000-ffmpeg-suite/artifacts.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="ffmpeg" REQUIRE_ARTIFACTS=1 \
		REQUIRE_COUNTER_DELTAS=1 RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected missing artifact audit to fail\n" >&2
		return 1
	fi

	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		AUDIT_REQUIRED_CASES="gstreamer:not_recorded" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected missing named case audit to fail\n" >&2
		return 1
	fi

	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		AUDIT_REQUIRED_CASES="rkmppenc:rkmppenc_avhw_h264_to_hevc_rga_resize" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected unselected named-case suite audit to fail\n" >&2
		return 1
	fi

	sed -i 's/gstreamer_diagnostic\t0\t1.000\tpass/gstreamer_diagnostic\t1\t1.000\tfail/' \
		"$tmp_root/logs/$CANDIDATE/20260706-000000-gstreamer-suite/summary.tsv"
	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		REQUIRE_DIAGNOSTIC_PASS=1 REQUIRE_ARTIFACTS=1 \
		REQUIRE_COUNTER_DELTAS=1 RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
		printf "selftest expected diagnostic failure audit to fail\n" >&2
		return 1
	fi
	if CONFORMANCE_ROOT="$tmp_root" SUITES="gstreamer" \
		AUDIT_REQUIRED_CASES="gstreamer:gstreamer_diagnostic" \
		REQUIRE_ARTIFACTS=1 REQUIRE_COUNTER_DELTAS=1 \
		RUN_COMPARATORS=0 "$SELF" >/dev/null 2>&1; then
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

add_default_core_cases
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
