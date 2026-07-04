#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rk-suite-compare.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE="$TMP_ROOT/base.tsv"
GOOD="$TMP_ROOT/good.tsv"
SLOW="$TMP_ROOT/slow.tsv"
REGRESSION="$TMP_ROOT/regression.tsv"

write_summary()
{
	local file=$1
	local profile=$2
	local required_result=$3
	local required_elapsed=$4
	local diagnostic_elapsed=$5

	{
		printf "profile\tclass\tcase\tstatus\telapsed_s\tresult\n"
		printf "%s\trequired\tcodec\t0\t%s\t%s\n" \
			"$profile" "$required_elapsed" "$required_result"
		printf "%s\tdiagnostic\tdiag\t0\t%s\tpass\n" \
			"$profile" "$diagnostic_elapsed"
	} > "$file"
}

write_artifacts()
{
	local file=$1
	local profile=$2
	local sha=$3

	{
		printf "profile\tclass\tcase\tkind\tbytes\tsha256\tpath\n"
		printf "%s\trequired\tcodec\tdecoded\t4\t%s\t/tmp/%s-codec.raw\n" \
			"$profile" "$sha" "$profile"
	} > "$file"
}

run_compare()
{
	local script=$1
	local candidate=$2
	local output=$3
	shift 3

	BASELINE_SUMMARY="$BASE" CANDIDATE_SUMMARY="$candidate" env "$@" \
		bash "$TEST_DIR/$script" > "$output"
}

expect_fail()
{
	local script=$1
	local candidate=$2
	local output=$3
	shift 3
	local status

	set +e
	run_compare "$script" "$candidate" "$output" "$@"
	status=$?
	set -e

	if [ "$status" -eq 0 ]; then
		echo "$script unexpectedly passed" >&2
		exit 1
	fi
}

check_compare_script()
{
	local script=$1
	local out_prefix="$TMP_ROOT/$script"
	shift

	run_compare "$script" "$GOOD" "$out_prefix.good" PERF_MAX_RATIO=1.25 "$@"
	grep -q "1.200" "$out_prefix.good"
	grep -q "2.000" "$out_prefix.good"
	if grep -q "slowdown" "$out_prefix.good"; then
		echo "$script reported an unexpected slowdown" >&2
		exit 1
	fi

	expect_fail "$script" "$SLOW" "$out_prefix.slow" PERF_MAX_RATIO=1.25 "$@"
	grep -q "slowdown" "$out_prefix.slow"

	expect_fail "$script" "$REGRESSION" "$out_prefix.regression" PERF_MAX_RATIO=1.25 "$@"
	grep -q "regression" "$out_prefix.regression"
}

check_artifact_compare()
{
	local script=$1
	local label=$2
	local base_dir="$TMP_ROOT/$label-base"
	local cand_dir="$TMP_ROOT/$label-cand"
	local out_good="$TMP_ROOT/$label-artifacts.good"
	local out_bad="$TMP_ROOT/$label-artifacts.bad"
	local out_missing="$TMP_ROOT/$label-artifacts.missing"
	local out_legacy="$TMP_ROOT/$label-artifacts.legacy"
	local status

	mkdir -p "$base_dir" "$cand_dir"
	write_summary "$base_dir/summary.tsv" forward-port pass 10 4
	write_summary "$cand_dir/summary.tsv" rewrite pass 10 4
	write_artifacts "$base_dir/artifacts.tsv" forward-port abcd
	write_artifacts "$cand_dir/artifacts.tsv" rewrite abcd

	BASELINE_SUMMARY="$base_dir/summary.tsv" \
		CANDIDATE_SUMMARY="$cand_dir/summary.tsv" \
		REQUIRE_ARTIFACTS=1 \
		bash "$TEST_DIR/$script" > "$out_good"
	grep -q "artifact_baseline" "$out_good"
	grep -q "same" "$out_good"

	write_artifacts "$cand_dir/artifacts.tsv" rewrite dead
	set +e
	BASELINE_SUMMARY="$base_dir/summary.tsv" \
		CANDIDATE_SUMMARY="$cand_dir/summary.tsv" \
		REQUIRE_ARTIFACTS=1 \
		bash "$TEST_DIR/$script" > "$out_bad"
	status=$?
	set -e
	if [ "$status" -eq 0 ]; then
		echo "$label artifact mismatch unexpectedly passed" >&2
		exit 1
	fi
	grep -q "artifact-mismatch" "$out_bad"

	rm -f "$cand_dir/artifacts.tsv"
	set +e
	BASELINE_SUMMARY="$base_dir/summary.tsv" \
		CANDIDATE_SUMMARY="$cand_dir/summary.tsv" \
		REQUIRE_ARTIFACTS=1 \
		bash "$TEST_DIR/$script" > "$out_missing"
	status=$?
	set -e
	if [ "$status" -eq 0 ]; then
		echo "missing $label artifact manifest unexpectedly passed" >&2
		exit 1
	fi
	grep -q "artifact_compare	skipped" "$out_missing"
	grep -q "REQUIRE_ARTIFACTS=0" "$out_missing"

	BASELINE_SUMMARY="$base_dir/summary.tsv" \
		CANDIDATE_SUMMARY="$cand_dir/summary.tsv" \
		REQUIRE_ARTIFACTS=0 \
		bash "$TEST_DIR/$script" > "$out_legacy"
	grep -q "artifact_compare	skipped" "$out_legacy"
}

check_librga_latest_filter()
{
	local root="$TMP_ROOT/conformance"
	local base_librga="$root/logs/forward-port/20260703-010000-librga-suite/summary.tsv"
	local cand_librga="$root/logs/rewrite/20260703-010000-librga-suite/summary.tsv"
	local base_mpp="$root/logs/forward-port/20260703-020000-mpp-suite/summary.tsv"
	local cand_mpp="$root/logs/rewrite/20260703-020000-mpp-suite/summary.tsv"
	local out="$TMP_ROOT/librga-latest.out"

	mkdir -p "$(dirname "$base_librga")" "$(dirname "$cand_librga")" \
		"$(dirname "$base_mpp")" "$(dirname "$cand_mpp")"
	cp "$BASE" "$base_librga"
	cp "$GOOD" "$cand_librga"
	cp "$REGRESSION" "$base_mpp"
	cp "$REGRESSION" "$cand_mpp"

	touch -t 202607030100 "$base_librga" "$cand_librga"
	touch -t 202607030200 "$base_mpp" "$cand_mpp"

	CONFORMANCE_ROOT="$root" bash "$TEST_DIR/librga-suite-compare.sh" > "$out"
	grep -q -- "-librga-suite/summary.tsv" "$out"
	if grep -q -- "-mpp-suite/summary.tsv" "$out"; then
		echo "librga comparator selected a non-librga summary" >&2
		exit 1
	fi
}

write_summary "$BASE" forward-port pass 10 4
write_summary "$GOOD" rewrite pass 12 8
write_summary "$SLOW" rewrite pass 14 8
write_summary "$REGRESSION" rewrite fail 12 8

check_compare_script mpp-suite-compare.sh
check_compare_script librga-suite-compare.sh
check_compare_script gstreamer-suite-compare.sh REQUIRE_ARTIFACTS=0
check_compare_script ffmpeg-suite-compare.sh REQUIRE_ARTIFACTS=0
check_artifact_compare mpp-suite-compare.sh mpp
check_artifact_compare gstreamer-suite-compare.sh gstreamer
check_artifact_compare ffmpeg-suite-compare.sh ffmpeg
check_librga_latest_filter

echo "suite comparator selftest passed"
