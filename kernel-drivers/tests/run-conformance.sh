#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Run the RK3588 driver-conformance catalog for one target/configuration pair.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CATALOG="$TEST_DIR/conformance/TESTS.tsv"
TARGET_DIR="$TEST_DIR/conformance/targets"
CONFIGURATION_DIR="$TEST_DIR/conformance/configurations"

usage()
{
	cat <<EOF
Usage: ${0##*/} [options]

Run the standard conformance set selected from conformance/TESTS.tsv. Kernel
implementation and build instrumentation are independent axes.

  --target NAME          bsp, forward-port, or rewrite (default: rewrite)
  --configuration NAME   production, kasan, or kcsan (default: production)
  --only IDS             run only these comma-separated compatible test IDs
  --include IDS          add opt-in compatible test IDs to the standard set
  --skip IDS             remove test IDs from the selected set
  --compare-to PROFILE   compare comparable suites with an existing profile
  --continue             run remaining tests after a failure
  --plan                 print the resolved plan without touching the board
  --list                 list the catalog and compatibility for this matrix
  --validate             run device-free harness and suite selftests
  -h, --help             show this help

Examples:
  sudo ${0##*/} --target bsp --configuration production
  sudo ${0##*/} --target forward-port --configuration kasan \\
    --include reset-session-kasan,ioctl-fuzz-kasan
  sudo ${0##*/} --target rewrite --configuration kcsan \\
    --include iommu-stress,recovery-stress,reset-contention
  sudo ${0##*/} --target rewrite --compare-to forward-port

PROFILE and the older RUN_* switches remain accepted as compatibility inputs,
but new automation should use the target/configuration and test-ID interface.
EOF
}

ACTION=run
TARGET_ARG=${CONFORMANCE_TARGET:-}
CONFIGURATION_ARG=${CONFORMANCE_CONFIGURATION:-}
ONLY_TESTS=${CONFORMANCE_ONLY_TESTS:-}
INCLUDE_TESTS=${CONFORMANCE_INCLUDE_TESTS:-}
SKIP_TESTS=${CONFORMANCE_SKIP_TESTS:-}
COMPARE_BASELINE=${COMPARE_BASELINE:-}
RUN_COMPARE=${RUN_COMPARE:-0}
RUN_CONTINUE_ON_FAIL=${RUN_CONTINUE_ON_FAIL:-0}
VALIDATE_ONLY=${VALIDATE_ONLY:-0}
LEGACY_PROFILE=${PROFILE:-}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--target)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		TARGET_ARG=$2
		shift 2
		;;
	--configuration|--config)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		CONFIGURATION_ARG=$2
		shift 2
		;;
	--only)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		ONLY_TESTS=$2
		shift 2
		;;
	--include)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		INCLUDE_TESTS="${INCLUDE_TESTS:+$INCLUDE_TESTS,}$2"
		shift 2
		;;
	--skip)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		SKIP_TESTS="${SKIP_TESTS:+$SKIP_TESTS,}$2"
		shift 2
		;;
	--compare-to)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		COMPARE_BASELINE=$2
		RUN_COMPARE=1
		shift 2
		;;
	--continue)
		RUN_CONTINUE_ON_FAIL=1
		shift
		;;
	--plan)
		ACTION=plan
		shift
		;;
	--list)
		ACTION=list
		shift
		;;
	--validate)
		ACTION=validate
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	-*)
		printf 'unknown option: %s\n' "$1" >&2
		usage >&2
		exit 2
		;;
	*)
		if [ -n "$TARGET_ARG" ]; then
			printf 'unexpected positional argument: %s\n' "$1" >&2
			exit 2
		fi
		TARGET_ARG=$1
		shift
		;;
	esac
done

if [ "$VALIDATE_ONLY" = "1" ]; then
	ACTION=validate
fi

list_has()
{
	local list=$1 wanted=$2 item
	local -a items

	list=${list//,/ }
	read -r -a items <<< "$list"
	for item in "${items[@]}"; do
		if [ "$item" = "$wanted" ]; then
			return 0
		fi
	done
	return 1
}

append_test()
{
	local variable=$1 value=$2 current

	current=${!variable:-}
	if ! list_has "$current" "$value"; then
		printf -v "$variable" '%s%s' "${current:+$current,}" "$value"
	fi
}

resolve_legacy_profile()
{
	local profile=$1 target_file configuration_file target configuration

	for target_file in "$TARGET_DIR"/*.env; do
		target=${target_file##*/}
		target=${target%.env}
		if [ "$profile" = "$target" ]; then
			TARGET_ARG=$target
			CONFIGURATION_ARG=production
			return 0
		fi
		for configuration_file in "$CONFIGURATION_DIR"/*.env; do
			configuration=${configuration_file##*/}
			configuration=${configuration%.env}
			if [ "$configuration" != production ] &&
				[ "$profile" = "$target-$configuration" ]; then
				TARGET_ARG=$target
				CONFIGURATION_ARG=$configuration
				return 0
			fi
		done
	done

	printf 'PROFILE=%s does not identify a known target/configuration pair\n' \
		"$profile" >&2
	return 1
}

if [ -n "$LEGACY_PROFILE" ] && [ -z "$TARGET_ARG" ] &&
	[ -z "$CONFIGURATION_ARG" ]; then
	resolve_legacy_profile "$LEGACY_PROFILE"
fi

TARGET_ARG=${TARGET_ARG:-rewrite}
CONFIGURATION_ARG=${CONFIGURATION_ARG:-production}
case "$TARGET_ARG:$CONFIGURATION_ARG" in
*[!a-z0-9-:]*|:*|*:)
	printf 'invalid target/configuration: %s/%s\n' \
		"$TARGET_ARG" "$CONFIGURATION_ARG" >&2
	exit 2
	;;
esac

target_file="$TARGET_DIR/$TARGET_ARG.env"
configuration_file="$CONFIGURATION_DIR/$CONFIGURATION_ARG.env"
if [ ! -f "$target_file" ]; then
	printf 'unknown conformance target: %s\n' "$TARGET_ARG" >&2
	exit 2
fi
if [ ! -f "$configuration_file" ]; then
	printf 'unknown conformance configuration: %s\n' "$CONFIGURATION_ARG" >&2
	exit 2
fi

# shellcheck disable=SC1090
source "$target_file"
# shellcheck disable=SC1090
source "$configuration_file"
if [ "$CONFORMANCE_TARGET" != "$TARGET_ARG" ] ||
	[ "$CONFORMANCE_CONFIGURATION" != "$CONFIGURATION_ARG" ]; then
	printf 'descriptor identity mismatch for %s/%s\n' \
		"$TARGET_ARG" "$CONFIGURATION_ARG" >&2
	exit 2
fi

PROFILE=$CONFORMANCE_TARGET
if [ -n "$CONFORMANCE_CONFIGURATION_PROFILE_SUFFIX" ]; then
	PROFILE="$PROFILE-$CONFORMANCE_CONFIGURATION_PROFILE_SUFFIX"
fi
PROFILE_DESCRIPTION="$CONFORMANCE_TARGET_DESCRIPTION; $CONFORMANCE_CONFIGURATION_DESCRIPTION"
if [ -z "$COMPARE_BASELINE" ]; then
	COMPARE_BASELINE=forward-port
	if [ -n "$CONFORMANCE_CONFIGURATION_PROFILE_SUFFIX" ]; then
		COMPARE_BASELINE="$COMPARE_BASELINE-$CONFORMANCE_CONFIGURATION_PROFILE_SUFFIX"
	fi
fi
COMPARE_CANDIDATE=${COMPARE_CANDIDATE:-$PROFILE}
export CONFORMANCE_TARGET CONFORMANCE_CONFIGURATION PROFILE

declare -a CATALOG_IDS=()
declare -A TEST_GROUP=()
declare -A TEST_TARGETS=()
declare -A TEST_CONFIGURATIONS=()
declare -A TEST_DEFAULT=()
declare -A TEST_RUNNER=()
declare -A TEST_ARGUMENT=()
declare -A TEST_COMPARE=()
declare -A TEST_DESCRIPTION=()

catalog_has_id()
{
	local wanted=$1 id
	for id in "${CATALOG_IDS[@]}"; do
		[ "$id" = "$wanted" ] && return 0
	done
	return 1
}

selector_valid()
{
	local selector=$1 directory=$2 kind=$3 value
	local -a values

	[ "$selector" = all ] && return 0
	selector=${selector//,/ }
	read -r -a values <<< "$selector"
	[ "${#values[@]}" -gt 0 ] || return 1
	for value in "${values[@]}"; do
		if [ ! -f "$directory/$value.env" ]; then
			printf 'catalog references unknown %s %s\n' "$kind" "$value" >&2
			return 1
		fi
	done
}

load_catalog()
{
	local header id group targets configurations default runner argument compare
	local description

	IFS= read -r header < "$CATALOG"
	if [ "$header" != $'id\tgroup\ttargets\tconfigurations\tdefault\trunner\targument\tcompare\tdescription' ]; then
		printf 'invalid conformance catalog header: %s\n' "$CATALOG" >&2
		return 1
	fi

	while IFS=$'\t' read -r id group targets configurations default runner \
		argument compare description; do
		[ -n "$id" ] || continue
		case "$id" in
		*[!a-z0-9-]*)
			printf 'invalid test id in catalog: %s\n' "$id" >&2
			return 1
			;;
		esac
		if catalog_has_id "$id"; then
			printf 'duplicate test id in catalog: %s\n' "$id" >&2
			return 1
		fi
		case "$default:$compare" in
		yes:yes|yes:no|no:yes|no:no) ;;
		*)
			printf 'invalid yes/no fields for catalog test %s\n' "$id" >&2
			return 1
			;;
		esac
		case "$runner" in
		builtin)
			case "$argument" in kunit|system-info|matrix-identity|abi) ;; *)
				printf 'unknown builtin %s for catalog test %s\n' \
					"$argument" "$id" >&2
				return 1
				esac
			;;
		suite)
			case "$argument" in mpp|librga|gstreamer|ffmpeg|rkmppenc) ;; *)
				printf 'unknown suite %s for catalog test %s\n' \
					"$argument" "$id" >&2
				return 1
				esac
			;;
		script)
			if [ ! -f "$TEST_DIR/$argument" ]; then
				printf 'missing script %s for catalog test %s\n' \
					"$argument" "$id" >&2
				return 1
			fi
			;;
		*)
			printf 'unknown runner %s for catalog test %s\n' "$runner" "$id" >&2
			return 1
			;;
		esac
		selector_valid "$targets" "$TARGET_DIR" target || return 1
		selector_valid "$configurations" "$CONFIGURATION_DIR" configuration || return 1
		CATALOG_IDS+=("$id")
		TEST_GROUP[$id]=$group
		TEST_TARGETS[$id]=$targets
		TEST_CONFIGURATIONS[$id]=$configurations
		TEST_DEFAULT[$id]=$default
		TEST_RUNNER[$id]=$runner
		TEST_ARGUMENT[$id]=$argument
		TEST_COMPARE[$id]=$compare
		TEST_DESCRIPTION[$id]=$description
	done < <(tail -n +2 "$CATALOG")

	[ "${#CATALOG_IDS[@]}" -gt 0 ] || {
		printf 'empty conformance catalog: %s\n' "$CATALOG" >&2
		return 1
	}
}

selector_matches()
{
	local selector=$1 value=$2
	[ "$selector" = all ] || list_has "$selector" "$value"
}

test_compatible()
{
	local id=$1
	selector_matches "${TEST_TARGETS[$id]}" "$CONFORMANCE_TARGET" &&
		selector_matches "${TEST_CONFIGURATIONS[$id]}" \
			"$CONFORMANCE_CONFIGURATION"
}

test_selected()
{
	local id=$1

	test_compatible "$id" || return 1
	list_has "$SKIP_TESTS" "$id" && return 1
	if [ -n "$ONLY_TESTS" ]; then
		list_has "$ONLY_TESTS" "$id"
		return
	fi
	[ "${TEST_DEFAULT[$id]}" = yes ] || list_has "$INCLUDE_TESTS" "$id"
}

selection_reason()
{
	local id=$1
	if ! test_compatible "$id"; then
		printf 'incompatible'
	elif list_has "$SKIP_TESTS" "$id"; then
		printf 'skipped'
	elif [ -n "$ONLY_TESTS" ] && ! list_has "$ONLY_TESTS" "$id"; then
		printf 'not-requested'
	elif test_selected "$id"; then
		printf 'selected'
	else
		printf 'opt-in'
	fi
}

validate_requested_tests()
{
	local list id
	local -a ids

	for list in "$ONLY_TESTS" "$INCLUDE_TESTS" "$SKIP_TESTS"; do
		list=${list//,/ }
		read -r -a ids <<< "$list"
		for id in "${ids[@]}"; do
			if ! catalog_has_id "$id"; then
				printf 'unknown conformance test id: %s\n' "$id" >&2
				return 1
			fi
		done
	done

	for list in "$ONLY_TESTS" "$INCLUDE_TESTS"; do
		list=${list//,/ }
		read -r -a ids <<< "$list"
		for id in "${ids[@]}"; do
			if ! test_compatible "$id"; then
				printf 'test %s is incompatible with target=%s configuration=%s\n' \
					"$id" "$CONFORMANCE_TARGET" \
					"$CONFORMANCE_CONFIGURATION" >&2
				return 1
			fi
		done
	done
}

legacy_toggle()
{
	local variable=$1 id=$2 value

	if [[ -v $variable ]]; then
		value=${!variable}
		case "$value" in
		0) append_test SKIP_TESTS "$id" ;;
		1) append_test INCLUDE_TESTS "$id" ;;
		*)
			printf '%s must be 0 or 1, got %s\n' "$variable" "$value" >&2
			return 1
			;;
		esac
	fi
}

load_catalog
legacy_toggle RUN_SYSTEM_INFO system-info
legacy_toggle RUN_ABI_REPLAY abi
legacy_toggle RUN_MPP_SUITE mpp
legacy_toggle RUN_LIBRGA_SUITE librga
legacy_toggle RUN_GSTREAMER_SUITE gstreamer
legacy_toggle RUN_FFMPEG_SUITE ffmpeg
legacy_toggle RUN_RKMPPENC_SUITE rkmppenc
legacy_toggle RUN_KUNIT_CHECK kunit
validate_requested_tests

print_plan()
{
	local id
	printf 'profile\t%s\n' "$PROFILE"
	printf 'profile-description\t%s\n' "$PROFILE_DESCRIPTION"
	printf 'target\t%s\t%s\n' "$CONFORMANCE_TARGET" \
		"$CONFORMANCE_TARGET_DESCRIPTION"
	printf 'configuration\t%s\t%s\n' "$CONFORMANCE_CONFIGURATION" \
		"$CONFORMANCE_CONFIGURATION_DESCRIPTION"
	printf 'test\tgroup\tdefault\tselection\tdescription\n'
	for id in "${CATALOG_IDS[@]}"; do
		printf '%s\t%s\t%s\t%s\t%s\n' "$id" "${TEST_GROUP[$id]}" \
			"${TEST_DEFAULT[$id]}" "$(selection_reason "$id")" \
			"${TEST_DESCRIPTION[$id]}"
	done
}

if [ "$ACTION" = list ] || [ "$ACTION" = plan ]; then
	print_plan
	exit 0
fi

ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/build/rockchip-conformance"}
# PM_STRESS=1 collapses the rewrite cores' runtime-PM autosuspend window to 0
# for the duration of the suites, so power-transition races (the 2026-07-30
# soft-CCU group-power wedge class) surface deterministically. Restored via an
# EXIT trap even if a suite fails; a hard wedge is recovered by the watchdog,
# and the knobs reset to their defaults on reboot regardless.
PM_STRESS=${PM_STRESS:-0}
RUN_COUNTER_CHECKS=${RUN_COUNTER_CHECKS:-$CONFORMANCE_TARGET_COUNTER_DEFAULTS}
CONFORMANCE_COUNTER_DEFAULTS=${CONFORMANCE_COUNTER_DEFAULTS:-${REWRITE_COUNTER_DEFAULTS:-1}}
SUITE_REQUIRE_DMESG_WAS_SET=${SUITE_REQUIRE_DMESG+x}
SUITE_DMESG_SCAN=${SUITE_DMESG_SCAN:-1}
SUITE_REQUIRE_DMESG=${SUITE_REQUIRE_DMESG:-0}
LIBRGA_FORCE_RGA_USERPTR_IOMMU=${LIBRGA_FORCE_RGA_USERPTR_IOMMU:-${LIBRGA_FORCE_ROUTE_B:-0}}
RUN_ID=${RUN_ID:-$(date +%Y%m%d-%H%M%S)}
LOG_ROOT=${LOG_ROOT:-"$CONFORMANCE_ROOT/logs/$PROFILE"}
MPP_SUITE_OUT=${MPP_SUITE_OUT:-"$LOG_ROOT/$RUN_ID-mpp-suite"}
LIBRGA_SUITE_OUT=${LIBRGA_SUITE_OUT:-"$LOG_ROOT/$RUN_ID-librga-suite"}
GSTREAMER_SUITE_OUT=${GSTREAMER_SUITE_OUT:-"$LOG_ROOT/$RUN_ID-gstreamer-suite"}
FFMPEG_SUITE_OUT=${FFMPEG_SUITE_OUT:-"$LOG_ROOT/$RUN_ID-ffmpeg-suite"}
RKMPPENC_SUITE_OUT=${RKMPPENC_SUITE_OUT:-"$LOG_ROOT/$RUN_ID-rkmppenc-suite"}
MPP_REQUIRED_POSITIVE_COUNTERS=${MPP_REQUIRED_POSITIVE_COUNTERS:-}
LIBRGA_REQUIRED_POSITIVE_COUNTERS=${LIBRGA_REQUIRED_POSITIVE_COUNTERS:-}
GSTREAMER_REQUIRED_POSITIVE_COUNTERS=${GSTREAMER_REQUIRED_POSITIVE_COUNTERS:-}
FFMPEG_REQUIRED_POSITIVE_COUNTERS=${FFMPEG_REQUIRED_POSITIVE_COUNTERS:-}
RKMPPENC_REQUIRED_POSITIVE_COUNTERS=${RKMPPENC_REQUIRED_POSITIVE_COUNTERS:-}
MPP_REQUIRED_POSITIVE_COUNTER_PREFIXES=${MPP_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
LIBRGA_REQUIRED_POSITIVE_COUNTER_PREFIXES=${LIBRGA_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
GSTREAMER_REQUIRED_POSITIVE_COUNTER_PREFIXES=${GSTREAMER_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
FFMPEG_REQUIRED_POSITIVE_COUNTER_PREFIXES=${FFMPEG_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
RKMPPENC_REQUIRED_POSITIVE_COUNTER_PREFIXES=${RKMPPENC_REQUIRED_POSITIVE_COUNTER_PREFIXES:-}
MPP_REQUIRED_ZERO_AFTER_COUNTERS=${MPP_REQUIRED_ZERO_AFTER_COUNTERS:-}
LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS=${LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS:-}
GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS=${GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS:-}
FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS=${FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS:-}
RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS=${RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS:-}
REQUIRE_COUNTER_FILE_WAS_SET=${REQUIRE_COUNTER_FILE+x}
REQUIRE_COUNTER_FILE=${REQUIRE_COUNTER_FILE:-0}
REQUIRE_FORBIDDEN_COUNTERS_WAS_SET=${REQUIRE_FORBIDDEN_COUNTERS+x}
REQUIRE_FORBIDDEN_COUNTERS=${REQUIRE_FORBIDDEN_COUNTERS:-0}

if [ -z "$SUITE_REQUIRE_DMESG_WAS_SET" ] &&
	{ [ "$CONFORMANCE_TARGET_REQUIRE_DMESG" = 1 ] ||
	  [ "$CONFORMANCE_CONFIGURATION_REQUIRE_DMESG" = 1 ]; }; then
	SUITE_REQUIRE_DMESG=1
fi

if [ "$CONFORMANCE_TARGET" = rewrite ]; then
	if [ -z "$SUITE_REQUIRE_DMESG_WAS_SET" ]; then
		SUITE_REQUIRE_DMESG=$CONFORMANCE_TARGET_REQUIRE_DMESG
	fi
	if [ "$RUN_COUNTER_CHECKS" = "1" ] &&
		[ "$CONFORMANCE_COUNTER_DEFAULTS" = "1" ]; then
		if [ -z "$REQUIRE_COUNTER_FILE_WAS_SET" ]; then
			REQUIRE_COUNTER_FILE=1
		fi
		if [ -z "$REQUIRE_FORBIDDEN_COUNTERS_WAS_SET" ]; then
			REQUIRE_FORBIDDEN_COUNTERS=1
		fi
		if [ -z "$LIBRGA_REQUIRED_POSITIVE_COUNTERS" ]; then
			LIBRGA_REQUIRED_POSITIVE_COUNTERS="rga:started_job_count rga:hw_total_ns rga:release_fence_count"
			if [ "$LIBRGA_FORCE_RGA_USERPTR_IOMMU" = "1" ]; then
				LIBRGA_REQUIRED_POSITIVE_COUNTERS="$LIBRGA_REQUIRED_POSITIVE_COUNTERS *:attempt *:ok"
			fi
		fi
		: "${MPP_REQUIRED_POSITIVE_COUNTERS:=mpp:started_job_count mpp:hw_total_ns}"
		if [ -z "$MPP_REQUIRED_ZERO_AFTER_COUNTERS" ]; then
			MPP_REQUIRED_ZERO_AFTER_COUNTERS="mpp:import_count mpp:queued_job_count"
		fi
		if [ -z "$LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS" ]; then
			LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS="rga:import_count rga:shadow_head_active_count rga:shadow_tail_active_count *:active"
		fi
		: "${GSTREAMER_REQUIRED_POSITIVE_COUNTERS:=mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns}"
		: "${GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS:=mpp:import_count mpp:queued_job_count rga:import_count rga:shadow_head_active_count rga:shadow_tail_active_count}"
		: "${FFMPEG_REQUIRED_POSITIVE_COUNTERS:=mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns}"
		: "${FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS:=mpp:import_count mpp:queued_job_count rga:import_count rga:shadow_head_active_count rga:shadow_tail_active_count}"
		if test_selected rkmppenc; then
			: "${RKMPPENC_REQUIRED_POSITIVE_COUNTERS:=mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns}"
			: "${RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS:=mpp:import_count mpp:queued_job_count rga:import_count rga:shadow_head_active_count rga:shadow_tail_active_count}"
		fi
		if [ -n "${MPP_REQUIRED_CASES:-}" ]; then
			: "${MPP_REQUIRED_POSITIVE_COUNTERS:=mpp:started_job_count mpp:hw_total_ns}"
		fi
	fi
fi

export SUITE_DMESG_SCAN SUITE_REQUIRE_DMESG

# RUN_CONTINUE_ON_FAIL=1 (or --continue) records a suite failure and moves on to the
# remaining suites instead of aborting the whole run at the first failure
# (2026-07-24 harness-gap fix: a red librga demo matrix or GStreamer suite
# used to block the FFmpeg suite entirely).  The runner still exits
# non-zero at the end when any suite failed.
FAILED_STEPS=""

step_failed()
{
	local name=$1 rc=$2

	printf "%s FAILED with exit code %s\n" "$name" "$rc" >&2
	if [ "$RUN_CONTINUE_ON_FAIL" = "1" ]; then
		FAILED_STEPS="$FAILED_STEPS $name"
		return 0
	fi
	exit "$rc"
}

run_step()
{
	local name=$1
	shift
	local rc

	printf "================= %s =================\n" "$name"
	set +e
	"$@"
	rc=$?
	set -e
	printf "\n"

	if [ "$rc" -ne 0 ]; then
		step_failed "$name" "$rc"
	fi
}

run_optional_step()
{
	local name=$1
	shift
	local rc

	printf "================= %s =================\n" "$name"
	set +e
	"$@"
	rc=$?
	set -e
	printf "\n"

	case "$rc" in
	0)
		return 0
		;;
	77)
		printf "%s SKIPPED with exit code 77\n" "$name"
		return 0
		;;
	*)
		step_failed "$name" "$rc"
		;;
	esac
}

run_system_info()
{
	local collector="$CONFORMANCE_ROOT/scripts/collect-system-info.sh"
	local out=${OUT:-}

	if [ ! -x "$collector" ]; then
		printf "Missing system-info collector: %s\n" "$collector" >&2
		return 2
	fi

	(
		cd "$CONFORMANCE_ROOT"
		if [ -n "$out" ]; then
			PROFILE="$PROFILE" OUT="$out" ./scripts/collect-system-info.sh
		else
			PROFILE="$PROFILE" ./scripts/collect-system-info.sh
		fi
	)
}

run_matrix_identity()
{
	local config_file=${CONFORMANCE_KERNEL_CONFIG:-"/boot/config-$(uname -r)"}
	local report="$LOG_ROOT/$RUN_ID-matrix-identity.tsv"
	local required forbidden entry failed=0

	if [ ! -r "$config_file" ]; then
		printf 'cannot verify declared matrix: unreadable kernel config %s\n' \
			"$config_file" >&2
		return 1
	fi

	required="$CONFORMANCE_TARGET_REQUIRED_CONFIG $CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG"
	forbidden="$CONFORMANCE_TARGET_FORBIDDEN_CONFIG $CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG"
	{
		printf 'kind\tentry\tstatus\n'
		for entry in $required; do
			if grep -qxF "$entry" "$config_file"; then
				printf 'required\t%s\tpresent\n' "$entry"
			else
				printf 'required\t%s\tmissing\n' "$entry"
				failed=1
			fi
		done
		for entry in $forbidden; do
			if grep -qxF "$entry" "$config_file"; then
				printf 'forbidden\t%s\tpresent\n' "$entry"
				failed=1
			else
				printf 'forbidden\t%s\tabsent\n' "$entry"
			fi
		done
	} > "$report"
	cat "$report"

	if [ "$failed" -ne 0 ]; then
		printf 'booted kernel config does not match target=%s configuration=%s\n' \
			"$CONFORMANCE_TARGET" "$CONFORMANCE_CONFIGURATION" >&2
		return 1
	fi
	printf 'booted kernel config matches target=%s configuration=%s\n' \
		"$CONFORMANCE_TARGET" "$CONFORMANCE_CONFIGURATION"
}

matrix_identity_selftest()
{
	local out="$CONFORMANCE_ROOT/build/harness-validation/matrix-identity"
	local config_file="$out/config"

	mkdir -p "$out"
	{
		printf 'CONFIG_ROCKCHIP_MPP_REWRITE=y\n'
		printf 'CONFIG_ROCKCHIP_RGA_REWRITE=y\n'
		printf 'CONFIG_KASAN=y\n'
	} > "$config_file"

	CONFORMANCE_TARGET_REQUIRED_CONFIG='CONFIG_ROCKCHIP_MPP_REWRITE=y CONFIG_ROCKCHIP_RGA_REWRITE=y' \
	CONFORMANCE_TARGET_FORBIDDEN_CONFIG='CONFIG_ROCKCHIP_MPP_SERVICE=y CONFIG_VIDEO_ROCKCHIP_RGA=y' \
	CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG='CONFIG_KASAN=y' \
	CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG='CONFIG_KCSAN=y' \
	CONFORMANCE_KERNEL_CONFIG="$config_file" LOG_ROOT="$out" RUN_ID=good \
		run_matrix_identity > /dev/null

	if CONFORMANCE_TARGET_REQUIRED_CONFIG='CONFIG_ROCKCHIP_MPP_REWRITE=y CONFIG_ROCKCHIP_RGA_REWRITE=y' \
		CONFORMANCE_TARGET_FORBIDDEN_CONFIG='' \
		CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG='CONFIG_KCSAN=y' \
		CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG='CONFIG_KASAN=y' \
		CONFORMANCE_KERNEL_CONFIG="$config_file" LOG_ROOT="$out" RUN_ID=bad \
		run_matrix_identity > /dev/null 2>&1; then
		printf 'matrix identity mismatch unexpectedly passed\n' >&2
		return 1
	fi
	printf 'matrix identity selftest passed\n'
}

run_counter_check()
{
	local label=$1
	local summary=$2
	local required=$3
	local required_prefix=$4
	local required_zero_after=$5

	if [ "$RUN_COUNTER_CHECKS" != "1" ]; then
		return
	fi

	run_step "$label: check rewrite debugfs counters" \
		env SUMMARY="$summary" \
		REQUIRED_POSITIVE_COUNTERS="$required" \
		REQUIRED_POSITIVE_COUNTER_PREFIXES="$required_prefix" \
		REQUIRED_ZERO_AFTER_COUNTERS="$required_zero_after" \
		FORBID_POSITIVE_COUNTERS="${FORBID_POSITIVE_COUNTERS:-}" \
		REQUIRE_FORBIDDEN_COUNTERS="$REQUIRE_FORBIDDEN_COUNTERS" \
		REQUIRE_COUNTER_FILE="$REQUIRE_COUNTER_FILE" \
		bash "$TEST_DIR/debugfs-counter-check.sh"
}

counter_list_has()
{
	local counters=$1
	local required=$2

	case " $counters " in
	*" $required "*)
		return 0
		;;
	esac

	return 1
}

validate_counter_defaults()
{
	local suite positive zero required_counter

	if [ "$CONFORMANCE_TARGET" != rewrite ]; then
		printf "counter defaults skipped for profile '%s'\n" "$PROFILE"
		return 0
	fi

	if [ "$RUN_COUNTER_CHECKS" != "1" ]; then
		printf "counter defaults skipped because RUN_COUNTER_CHECKS=%s\n" \
			"$RUN_COUNTER_CHECKS"
		return 0
	fi
	if [ "$REQUIRE_FORBIDDEN_COUNTERS" != "1" ]; then
		printf "rewrite counter defaults did not require safety-counter presence\n" >&2
		return 1
	fi

	if [ "$CONFORMANCE_COUNTER_DEFAULTS" != "1" ]; then
		printf "counter defaults skipped because CONFORMANCE_COUNTER_DEFAULTS=%s\n" \
			"$CONFORMANCE_COUNTER_DEFAULTS"
		return 0
	fi

	if [ "$REQUIRE_COUNTER_FILE" != "1" ]; then
		printf "rewrite counter defaults did not require counter files\n" >&2
		return 1
	fi


	for suite in mpp librga gstreamer ffmpeg rkmppenc; do
		test_selected "$suite" || continue
		case "$suite" in
		mpp)
			positive=$MPP_REQUIRED_POSITIVE_COUNTERS
			zero=$MPP_REQUIRED_ZERO_AFTER_COUNTERS
			set -- mpp:import_count mpp:queued_job_count
			;;
		librga)
			positive=$LIBRGA_REQUIRED_POSITIVE_COUNTERS
			zero=$LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS
			set -- rga:import_count rga:shadow_head_active_count \
				rga:shadow_tail_active_count '*:active'
			;;
		gstreamer)
			positive=$GSTREAMER_REQUIRED_POSITIVE_COUNTERS
			zero=$GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS
			set -- mpp:import_count mpp:queued_job_count rga:import_count \
				rga:shadow_head_active_count rga:shadow_tail_active_count
			;;
		ffmpeg)
			positive=$FFMPEG_REQUIRED_POSITIVE_COUNTERS
			zero=$FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS
			set -- mpp:import_count mpp:queued_job_count rga:import_count \
				rga:shadow_head_active_count rga:shadow_tail_active_count
			;;
		rkmppenc)
			positive=$RKMPPENC_REQUIRED_POSITIVE_COUNTERS
			zero=$RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS
			set -- mpp:import_count mpp:queued_job_count rga:import_count \
				rga:shadow_head_active_count rga:shadow_tail_active_count
			;;
		esac
		if [ -z "$positive" ]; then
			printf 'rewrite counter defaults did not require %s hardware counters\n' \
				"$suite" >&2
			return 1
		fi
		for required_counter in "$@"; do
			if ! counter_list_has "$zero" "$required_counter"; then
				printf 'rewrite %s counter defaults did not require idle gauge %s to return to zero\n' \
					"$suite" "$required_counter" >&2
				return 1
			fi
		done
	done

	if test_selected librga &&
		[ "$LIBRGA_FORCE_RGA_USERPTR_IOMMU" = "1" ]; then
		case " $LIBRGA_REQUIRED_POSITIVE_COUNTERS " in
		*" *:attempt "*)
			;;
		*)
			printf "forced RGA userptr-IOMMU mode did not require attempts\n" >&2
			return 1
			;;
		esac
		case " $LIBRGA_REQUIRED_POSITIVE_COUNTERS " in
		*" *:ok "*)
			;;
		*)
			printf "forced RGA userptr-IOMMU mode did not require successes\n" >&2
			return 1
			;;
		esac
	fi
	if test_selected mpp && [ -n "${MPP_REQUIRED_CASES:-}" ] &&
		[ -z "$MPP_REQUIRED_POSITIVE_COUNTERS" ]; then
		printf "rewrite counter defaults did not require MPP counters for explicit MPP cases\n" >&2
		return 1
	fi

	printf "rewrite counter defaults validated\n"
}

run_suite_test()
{
	local suite=$1 label out required required_prefix required_zero

	case "$suite" in
	mpp)
		label="mpp: official test suite"
		out=$MPP_SUITE_OUT
		required=$MPP_REQUIRED_POSITIVE_COUNTERS
		required_prefix=$MPP_REQUIRED_POSITIVE_COUNTER_PREFIXES
		required_zero=$MPP_REQUIRED_ZERO_AFTER_COUNTERS
		;;
	librga)
		label="rga: official librga suite"
		out=$LIBRGA_SUITE_OUT
		required=$LIBRGA_REQUIRED_POSITIVE_COUNTERS
		required_prefix=$LIBRGA_REQUIRED_POSITIVE_COUNTER_PREFIXES
		required_zero=$LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS
		;;
	gstreamer)
		label="gstreamer: JeffyCN plugin suite"
		out=$GSTREAMER_SUITE_OUT
		required=$GSTREAMER_REQUIRED_POSITIVE_COUNTERS
		required_prefix=$GSTREAMER_REQUIRED_POSITIVE_COUNTER_PREFIXES
		required_zero=$GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS
		;;
	ffmpeg)
		label="ffmpeg: rkmpp/rkrga CLI suite"
		out=$FFMPEG_SUITE_OUT
		required=$FFMPEG_REQUIRED_POSITIVE_COUNTERS
		required_prefix=$FFMPEG_REQUIRED_POSITIVE_COUNTER_PREFIXES
		required_zero=$FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS
		;;
	rkmppenc)
		label="rkmppenc: application-level MPP/RGA suite"
		out=$RKMPPENC_SUITE_OUT
		required=$RKMPPENC_REQUIRED_POSITIVE_COUNTERS
		required_prefix=$RKMPPENC_REQUIRED_POSITIVE_COUNTER_PREFIXES
		required_zero=$RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS
		;;
	esac

	run_step "$label" \
		env PROFILE="$PROFILE" CONFORMANCE_TARGET="$CONFORMANCE_TARGET" \
		CONFORMANCE_CONFIGURATION="$CONFORMANCE_CONFIGURATION" \
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" OUT="$out" \
		bash "$TEST_DIR/$suite-suite.sh"
	run_counter_check "$suite" "$out/summary.tsv" "$required" \
		"$required_prefix" "$required_zero"
}

run_script_test()
{
	local id=$1 script=$2 out
	out="$LOG_ROOT/$RUN_ID-$id"

	case "$id" in
	ioctl-fuzz-kasan)
		run_step "$id: ${TEST_DESCRIPTION[$id]}" \
			env CONFORMANCE_ROOT="$CONFORMANCE_ROOT" PROFILE="$PROFILE" \
			BUILD_DIR="$CONFORMANCE_ROOT/build/ioctl-fuzz" \
			IOCTL_FUZZ_OUT="$out" \
			IOCTL_FUZZ_DMESG_SCAN=1 IOCTL_FUZZ_REQUIRE_DMESG=1 \
			IOCTL_FUZZ_FAIL_NTH_MAX="${IOCTL_FUZZ_FAIL_NTH_MAX:-4}" \
			bash "$TEST_DIR/$script"
		;;
	*)
		run_step "$id: ${TEST_DESCRIPTION[$id]}" \
			env CONFORMANCE_ROOT="$CONFORMANCE_ROOT" PROFILE="$PROFILE" \
			CONFORMANCE_TARGET="$CONFORMANCE_TARGET" \
			CONFORMANCE_CONFIGURATION="$CONFORMANCE_CONFIGURATION" \
			RUN_ID="$RUN_ID" OUT="$out" bash "$TEST_DIR/$script"
		;;
	esac
}

run_catalog_test()
{
	local id=$1 runner argument
	runner=${TEST_RUNNER[$id]}
	argument=${TEST_ARGUMENT[$id]}

	case "$runner:$argument" in
	builtin:kunit)
		run_step "kunit: require booted rewrite suites green" \
			env KUNIT_REPORT="$LOG_ROOT/$RUN_ID-kunit.tsv" \
			bash "$TEST_DIR/rewrite-kunit-log-check.sh"
		;;
	builtin:system-info)
		OUT="$LOG_ROOT/$RUN_ID-system" \
			run_step "system: collect profile state" run_system_info
		;;
	builtin:matrix-identity)
		run_step "identity: verify target/configuration kernel config" \
			run_matrix_identity
		;;
	builtin:abi)
		run_step "abi: replay normalized ioctl contract" \
			env PROFILE="$PROFILE" bash "$TEST_DIR/abi-replay.sh"
		;;
	suite:*)
		run_suite_test "$argument"
		;;
	script:*)
		run_script_test "$id" "$argument"
		;;
	esac
}

run_profile_tests()
{
	local id
	for id in "${CATALOG_IDS[@]}"; do
		test_selected "$id" || continue
		run_catalog_test "$id"
	done
}

run_comparators()
{
	local baseline=$COMPARE_BASELINE candidate=$COMPARE_CANDIDATE id argument
	local perf_max_ratio=${PERF_MAX_RATIO:-}

	if [ "$CONFORMANCE_CONFIGURATION_PERF_VALID" != 1 ] &&
		[ -z "$perf_max_ratio" ]; then
		perf_max_ratio=0
	fi

	for id in "${CATALOG_IDS[@]}"; do
		test_selected "$id" || continue
		[ "${TEST_COMPARE[$id]}" = yes ] || continue
		argument=${TEST_ARGUMENT[$id]}
		case "$argument" in
		abi)
			run_step "abi: compare normalized ioctl contract" \
				env PROFILE="$candidate" BASELINE="$baseline" \
				bash "$TEST_DIR/abi-replay.sh"
			;;
		*)
			run_step "$id: compare latest suite summaries" \
				env BASELINE="$baseline" CANDIDATE="$candidate" \
				CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
				PERF_MAX_RATIO="$perf_max_ratio" \
				bash "$TEST_DIR/$argument-suite-compare.sh"
			;;
		esac
	done
}

run_validation()
{
	run_step "identity: validate matrix config gate" matrix_identity_selftest

	run_step "counter defaults: validate wiring" validate_counter_defaults

	run_step "debugging: validate focused MPP capture workflow" \
		env MPP_DEBUG_VALIDATE_ONLY=1 \
		bash "$TEST_DIR/mpp-debug-capture.sh"

	run_step "kernel log: fatal-signature gate selftest" \
		bash "$TEST_DIR/suite-common-selftest.sh"

	run_step "kunit: boot-result parser selftest" \
		bash "$TEST_DIR/rewrite-kunit-log-check.sh" --selftest

	# The two syzlang checks that used to run here moved to the private
	# rock-5b-security repository along with the syzkaller description
	# itself; run them from there when validating the fuzzing description.

	run_step "fuzzing: validate ioctl mutator build" \
		env IOCTL_FUZZ_VALIDATE_BUILD=1 \
		BUILD_DIR="$CONFORMANCE_ROOT/build/harness-validation/ioctl-fuzz" \
		bash "$TEST_DIR/ioctl-fuzz-smoke.sh"

	run_step "rga: validate direct librga smoke build" \
		env LIBRGA_SMOKE_VALIDATE_BUILD=1 \
		bash "$TEST_DIR/librga-smoke.sh"

	run_optional_step "gstreamer: validate event harness build" \
		env GST_EVENT_HARNESS_VALIDATE_BUILD=1 \
		bash "$TEST_DIR/build-gstreamer-rockchip.sh"

	run_step "iommu: validate RGA scatter fuzzer build" \
		env IOMMU_FUZZ_VALIDATE_BUILD=1 \
		OUT="$CONFORMANCE_ROOT/build/harness-validation/iommu-fuzz" \
		bash "$TEST_DIR/iommu-machinery-fuzz.sh"

	run_step "recovery: validate stress harness config" \
		env RECOVERY_VALIDATE_ONLY=1 \
		bash "$TEST_DIR/rewrite-recovery-stress.sh"

	run_step "pm: validate autosuspend stress knobs" \
		bash "$TEST_DIR/pm-stress-knobs.sh" --validate

	run_step "pm: validate case-pair matrix" \
		env VALIDATE_ONLY=1 bash "$TEST_DIR/rewrite-case-pair-matrix.sh"

	run_step "mpp: validate case builders" \
		env MPP_VALIDATE_CASES=1 PROFILE="$PROFILE" \
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
		MPP_H264_INPUT=/dev/null MPP_H265_INPUT=/dev/null \
		MPP_VP9_INPUT=/dev/null MPP_AVS2_INPUT=/dev/null \
		MPP_DEC_INPUT=/dev/null MPP_DEC_TYPE=7 \
		MPP_ENC_INPUT=/dev/null MPP_ENC_WIDTH=16 MPP_ENC_HEIGHT=16 \
		MPP_ENC_TYPE=7 \
		MPP_REQUIRED_CASES="mpp_info_test mpi_dec_h264 mpi_dec_h265 mpi_dec_vp9 mpi_dec_avs2 mpi_dec_custom mpi_dec_mt_h264 mpi_dec_mt_h265 mpi_dec_mt_vp9 mpi_dec_mt_avs2 mpi_dec_mt_custom mpi_dec_multi_h264 mpi_dec_multi_h265 mpi_dec_multi_vp9 mpi_dec_multi_avs2 mpi_dec_multi_custom mpi_enc_h264 mpi_enc_h265 mpi_enc_h264_slice mpi_enc_h265_slice mpi_enc_custom mpi_enc_mt_h264 mpi_enc_mt_h265 mpi_enc_mt_custom mpi_rc2_h264 mpi_rc2_h265 mpi_rc2_custom vpu_api_dec_h264 vpu_api_dec_h265 vpu_api_dec_avs2 vpu_api_dec_custom" \
		bash "$TEST_DIR/mpp-suite.sh"

	run_step "gstreamer: validate case builders" \
		env GST_VALIDATE_CASES=1 PROFILE="$PROFILE" \
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
		bash "$TEST_DIR/gstreamer-suite.sh"

	run_step "ffmpeg: validate case list" \
		env FFMPEG_VALIDATE_CASES=1 PROFILE="$PROFILE" \
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
		bash "$TEST_DIR/ffmpeg-suite.sh"

	run_step "rkmppenc: validate optional case list" \
		env RKMPPENC_VALIDATE_CASES=1 PROFILE="$PROFILE" \
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
		bash "$TEST_DIR/rkmppenc-suite.sh"

	run_step "comparators: regression selftest" \
		bash "$TEST_DIR/suite-compare-selftest.sh"

	run_step "abi replay: filter selftest" \
		bash "$TEST_DIR/abi-replay.sh" --selftest

	run_step "evidence: audit selftest" \
		bash "$TEST_DIR/rewrite-evidence-audit.sh" --selftest
}

if [ "$ACTION" = validate ]; then
	run_validation
	printf "Conformance harness validation passed\n"
	exit 0
fi

mkdir -p "$LOG_ROOT"
print_plan | tee "$LOG_ROOT/$RUN_ID-conformance-plan.tsv"
printf '\n'

if [ "$PM_STRESS" = "1" ]; then
	run_step "pm: collapse autosuspend windows for the run" \
		bash "$TEST_DIR/pm-stress-knobs.sh" apply
	trap 'bash "$TEST_DIR/pm-stress-knobs.sh" restore || :' EXIT
fi

run_profile_tests

if [ "$RUN_COMPARE" = "1" ]; then
	run_comparators
fi

if [ -n "$FAILED_STEPS" ]; then
	printf "Conformance profile '%s' completed with FAILED suites:%s\n" \
		"$PROFILE" "$FAILED_STEPS" >&2
	exit 1
fi

printf "Conformance profile '%s' completed\n" "$PROFILE"
