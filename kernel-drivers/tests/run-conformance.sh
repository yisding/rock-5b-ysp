#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Run the RK3588 driver-conformance catalog for one target/configuration pair.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
CATALOG=${CONFORMANCE_CATALOG:-"$TEST_DIR/conformance/TESTS.tsv"}
TARGET_DIR="$TEST_DIR/conformance/targets"
CONFIGURATION_DIR="$TEST_DIR/conformance/configurations"
# shellcheck source=conformance/runner-common.sh disable=SC1091
source "$TEST_DIR/conformance/runner-common.sh"

usage()
{
	cat <<EOF
Usage: ${0##*/} [options]

Run the standard conformance set selected from conformance/TESTS.tsv. Kernel
implementation and build instrumentation are independent axes.

  --target NAME          bsp, forward-port, rewrite, or auto (default: auto)
  --configuration NAME   production, kasan, kcsan, or auto (default: auto)
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
  sudo ${0##*/}
  sudo ${0##*/} --target bsp --configuration production
  sudo ${0##*/} --target forward-port --configuration kasan \\
    --include reset-session-kasan,ioctl-fuzz-kasan
  sudo ${0##*/} --target rewrite --configuration kcsan \\
    --include iommu-stress,recovery-stress,reset-contention
  sudo ${0##*/} --target rewrite --compare-to forward-port

With no selectors, the runner identifies the target from the booted driver
Kconfig and kernel series, and the configuration from sanitizer Kconfig.
Device-free --validate retains rewrite/production defaults. PROFILE and the
older RUN_* switches remain accepted as compatibility inputs, but new
automation should use the target/configuration and test-ID interface.

Runtime and validation actions write a machine-readable per-stage result file
and print the same PASS/FAIL/SKIP vocabulary after every stage.
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

select_action()
{
	local requested=$1

	if [ "$ACTION" != run ] && [ "$ACTION" != "$requested" ]; then
		printf 'conflicting actions: --%s cannot be combined with --%s\n' \
			"$ACTION" "$requested" >&2
		exit 2
	fi
	ACTION=$requested
}

require_option_value()
{
	local option=$1 value=${2:-}

	if [ -z "$value" ] || [[ $value == -* ]]; then
		printf '%s requires a value\n' "$option" >&2
		exit 2
	fi
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--target)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		require_option_value "$1" "$2"
		TARGET_ARG=$2
		shift 2
		;;
	--configuration|--config)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		require_option_value "$1" "$2"
		CONFIGURATION_ARG=$2
		shift 2
		;;
	--only)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		require_option_value "$1" "$2"
		ONLY_TESTS=$2
		shift 2
		;;
	--include)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		require_option_value "$1" "$2"
		INCLUDE_TESTS="${INCLUDE_TESTS:+$INCLUDE_TESTS,}$2"
		shift 2
		;;
	--skip)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		require_option_value "$1" "$2"
		SKIP_TESTS="${SKIP_TESTS:+$SKIP_TESTS,}$2"
		shift 2
		;;
	--compare-to)
		[ "$#" -ge 2 ] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
		require_option_value "$1" "$2"
		COMPARE_BASELINE=$2
		RUN_COMPARE=1
		shift 2
		;;
	--continue)
		RUN_CONTINUE_ON_FAIL=1
		shift
		;;
	--plan)
		select_action plan
		shift
		;;
	--list)
		select_action list
		shift
		;;
	--validate)
		select_action validate
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
	select_action validate
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

kernel_release()
{
	if [ -n "${CONFORMANCE_KERNEL_RELEASE:-}" ]; then
		printf '%s\n' "$CONFORMANCE_KERNEL_RELEASE"
	else
		uname -r
	fi
}

kernel_config_file()
{
	if [ -n "${CONFORMANCE_KERNEL_CONFIG:-}" ]; then
		printf '%s\n' "$CONFORMANCE_KERNEL_CONFIG"
	else
		printf '/boot/config-%s\n' "$(kernel_release)"
	fi
}

kernel_series()
{
	local release=$1

	if [[ $release =~ ^([0-9]+)\.([0-9]+)([^0-9]|$) ]]; then
		printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
		return 0
	fi
	printf 'cannot extract kernel series from release: %s\n' "$release" >&2
	return 1
}

descriptor_matches_boot()
(
	local descriptor=$1 config_file=$2 series=$3 entry
	local required forbidden required_series forbidden_series

	unset CONFORMANCE_TARGET_REQUIRED_CONFIG
	unset CONFORMANCE_TARGET_FORBIDDEN_CONFIG
	unset CONFORMANCE_TARGET_REQUIRED_KERNEL_SERIES
	unset CONFORMANCE_TARGET_FORBIDDEN_KERNEL_SERIES
	unset CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG
	unset CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG
	# shellcheck disable=SC1090
	source "$descriptor"
	required="${CONFORMANCE_TARGET_REQUIRED_CONFIG:-} ${CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG:-}"
	forbidden="${CONFORMANCE_TARGET_FORBIDDEN_CONFIG:-} ${CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG:-}"
	required_series=${CONFORMANCE_TARGET_REQUIRED_KERNEL_SERIES:-}
	forbidden_series=${CONFORMANCE_TARGET_FORBIDDEN_KERNEL_SERIES:-}

	for entry in $required; do
		grep -qxF "$entry" "$config_file" || return 1
	done
	for entry in $forbidden; do
		if grep -qxF "$entry" "$config_file"; then
			return 1
		fi
	done
	if [ -n "$required_series" ]; then
		[ -n "$series" ] && list_has "$required_series" "$series" || return 1
	fi
	if [ -n "$forbidden_series" ] && [ -n "$series" ] &&
		list_has "$forbidden_series" "$series"; then
		return 1
	fi
)

detect_descriptor()
{
	local directory=$1 kind=$2 config_file=$3 series=$4 descriptor identity
	local -a matches=()

	for descriptor in "$directory"/*.env; do
		if descriptor_matches_boot "$descriptor" "$config_file" "$series"; then
			identity=${descriptor##*/}
			matches+=("${identity%.env}")
		fi
	done
	if [ "${#matches[@]}" -ne 1 ]; then
		printf 'cannot uniquely autodetect conformance %s from %s' \
			"$kind" "$config_file" >&2
		if [ -n "$series" ]; then
			printf ' (kernel series %s)' "$series" >&2
		fi
		printf '; matches: %s\n' "${matches[*]:-none}" >&2
		return 1
	fi
	printf '%s\n' "${matches[0]}"
}

autodetect_matrix()
{
	local config_file release series detected

	config_file=$(kernel_config_file)
	if [ ! -r "$config_file" ]; then
		printf 'cannot autodetect conformance matrix: unreadable kernel config %s\n' \
			"$config_file" >&2
		printf 'select --target and --configuration explicitly, or set CONFORMANCE_KERNEL_CONFIG\n' >&2
		return 1
	fi
	release=$(kernel_release)
	series=$(kernel_series "$release") || return 1

	if [ -z "$TARGET_ARG" ]; then
		detected=$(detect_descriptor "$TARGET_DIR" target "$config_file" "$series") ||
			return 1
		TARGET_ARG=$detected
		TARGET_SELECTION=autodetected
	fi
	if [ -z "$CONFIGURATION_ARG" ]; then
		detected=$(detect_descriptor "$CONFIGURATION_DIR" configuration \
			"$config_file" "$series") || return 1
		CONFIGURATION_ARG=$detected
		CONFIGURATION_SELECTION=autodetected
	fi
}

if [ -n "$LEGACY_PROFILE" ] && [ -z "$TARGET_ARG" ] &&
	[ -z "$CONFIGURATION_ARG" ]; then
	resolve_legacy_profile "$LEGACY_PROFILE"
fi

TARGET_SELECTION=explicit
CONFIGURATION_SELECTION=explicit
TARGET_AUTO_REQUESTED=0
CONFIGURATION_AUTO_REQUESTED=0
if [ "$TARGET_ARG" = auto ]; then
	TARGET_ARG=
	TARGET_AUTO_REQUESTED=1
fi
if [ "$CONFIGURATION_ARG" = auto ]; then
	CONFIGURATION_ARG=
	CONFIGURATION_AUTO_REQUESTED=1
fi
if [ "$ACTION" = validate ]; then
	if [ -z "$TARGET_ARG" ] && [ "$TARGET_AUTO_REQUESTED" = 0 ]; then
		TARGET_ARG=rewrite
	fi
	if [ -z "$CONFIGURATION_ARG" ] &&
		[ "$CONFIGURATION_AUTO_REQUESTED" = 0 ]; then
		CONFIGURATION_ARG=production
	fi
fi
if [ -z "$TARGET_ARG" ] || [ -z "$CONFIGURATION_ARG" ]; then
	autodetect_matrix
fi
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

validate_descriptor_sets
validate_boolean_field environment RUN_COMPARE "$RUN_COMPARE"
validate_boolean_field environment RUN_CONTINUE_ON_FAIL "$RUN_CONTINUE_ON_FAIL"
validate_boolean_field environment VALIDATE_ONLY "$VALIDATE_ONLY"

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
CONFORMANCE_TARGET_REQUIRED_KERNEL_SERIES=${CONFORMANCE_TARGET_REQUIRED_KERNEL_SERIES:-}
CONFORMANCE_TARGET_FORBIDDEN_KERNEL_SERIES=${CONFORMANCE_TARGET_FORBIDDEN_KERNEL_SERIES:-}

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

	if [ ! -r "$CATALOG" ]; then
		printf 'unreadable conformance catalog: %s\n' "$CATALOG" >&2
		return 1
	fi
	if ! awk -F '\t' '
		NF != 9 {
			printf "%s:%d: expected 9 tab-separated fields, found %d\n", FILENAME, NR, NF > "/dev/stderr";
			invalid = 1;
		}
		END { exit invalid }
	' "$CATALOG"; then
		return 1
	fi

	IFS= read -r header < "$CATALOG"
	if [ "$header" != $'id\tgroup\ttargets\tconfigurations\tdefault\trunner\targument\tcompare\tdescription' ]; then
		printf 'invalid conformance catalog header: %s\n' "$CATALOG" >&2
		return 1
	fi

	while IFS=$'\t' read -r id group targets configurations default runner \
		argument compare description; do
		[ -n "$id" ] || continue
		case "$id" in
		*[!a-z0-9-]*|'')
			printf 'invalid test id in catalog: %s\n' "$id" >&2
			return 1
			;;
		esac
		case "$group" in
		*[!a-z0-9-]*|'')
			printf 'invalid group for catalog test %s: %s\n' "$id" "$group" >&2
			return 1
			;;
		esac
		if [ -z "$description" ]; then
			printf 'empty description for catalog test %s\n' "$id" >&2
			return 1
		fi
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
			if [ "$id" != "$argument" ]; then
				printf 'builtin catalog id %s must match its argument %s\n' \
					"$id" "$argument" >&2
				return 1
			fi
			;;
		suite)
			case "$argument" in mpp|librga|gstreamer|ffmpeg|rkmppenc) ;; *)
				printf 'unknown suite %s for catalog test %s\n' \
					"$argument" "$id" >&2
				return 1
				esac
			if [ "$id" != "$argument" ]; then
				printf 'suite catalog id %s must match its argument %s\n' \
					"$id" "$argument" >&2
				return 1
			fi
			;;
		script)
			if [[ $argument == /* || $argument == ../* || $argument == *../* ]]; then
				printf 'unsafe script path %s for catalog test %s\n' \
					"$argument" "$id" >&2
				return 1
			fi
			if [ ! -x "$TEST_DIR/$argument" ]; then
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
		if [ "$compare" = yes ]; then
			case "$runner:$argument" in
			builtin:abi) ;;
			suite:*)
				if [ ! -x "$TEST_DIR/$argument-suite-compare.sh" ]; then
					printf 'missing comparator for catalog test %s: %s-suite-compare.sh\n' \
						"$id" "$argument" >&2
					return 1
				fi
				;;
			*)
				printf 'catalog test %s cannot use compare=yes with %s/%s\n' \
					"$id" "$runner" "$argument" >&2
				return 1
				;;
			esac
		fi
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

validate_catalog_contract()
{
	local id target_file configuration_file target configuration selected
	local expected

	for expected in system-info matrix-identity abi mpp librga gstreamer ffmpeg; do
		if ! catalog_has_id "$expected"; then
			printf 'standard conformance catalog is missing %s\n' "$expected" >&2
			return 1
		fi
		if [ "${TEST_DEFAULT[$expected]}" != yes ] ||
			[ "${TEST_TARGETS[$expected]}" != all ] ||
			[ "${TEST_CONFIGURATIONS[$expected]}" != all ]; then
			printf 'standard conformance test %s must default on for every matrix cell\n' \
				"$expected" >&2
			return 1
		fi
	done

	for target_file in "$TARGET_DIR"/*.env; do
		target=${target_file##*/}
		target=${target%.env}
		for configuration_file in "$CONFIGURATION_DIR"/*.env; do
			configuration=${configuration_file##*/}
			configuration=${configuration%.env}
			selected=0
			for id in "${CATALOG_IDS[@]}"; do
				if [ "${TEST_DEFAULT[$id]}" = yes ] &&
					selector_matches "${TEST_TARGETS[$id]}" "$target" &&
					selector_matches "${TEST_CONFIGURATIONS[$id]}" "$configuration"; then
					selected=$((selected + 1))
				fi
			done
			if [ "$selected" -eq 0 ]; then
				printf 'catalog has no default coverage for target=%s configuration=%s\n' \
					"$target" "$configuration" >&2
				return 1
			fi
		done
	done

	return 0
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

validate_resolved_selection()
{
	local id selected=0 comparable=0

	for id in "${CATALOG_IDS[@]}"; do
		test_selected "$id" || continue
		selected=$((selected + 1))
		if [ "${TEST_COMPARE[$id]}" = yes ]; then
			comparable=$((comparable + 1))
		fi
	done

	if [ "$selected" -eq 0 ]; then
		printf 'no conformance tests are selected for target=%s configuration=%s\n' \
			"$CONFORMANCE_TARGET" "$CONFORMANCE_CONFIGURATION" >&2
		printf 'adjust --only/--include/--skip, or use --list to inspect compatibility\n' >&2
		return 1
	fi
	if [ "$RUN_COMPARE" = "1" ] && [ "$comparable" -eq 0 ]; then
		printf '%s\n' '--compare-to was requested, but the selected set has no comparable tests' >&2
		return 1
	fi
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
validate_catalog_contract
legacy_toggle RUN_SYSTEM_INFO system-info
legacy_toggle RUN_ABI_REPLAY abi
legacy_toggle RUN_MPP_SUITE mpp
legacy_toggle RUN_LIBRGA_SUITE librga
legacy_toggle RUN_GSTREAMER_SUITE gstreamer
legacy_toggle RUN_FFMPEG_SUITE ffmpeg
legacy_toggle RUN_RKMPPENC_SUITE rkmppenc
legacy_toggle RUN_KUNIT_CHECK kunit
validate_requested_tests
if [ "$ACTION" != list ]; then
	validate_resolved_selection
fi

print_plan()
{
	local id
	printf 'kind\tname\tgroup\tdefault\tselection\tdescription\n'
	printf 'matrix\taction\tidentity\t-\t%s\tRequested runner action\n' "$ACTION"
	printf 'matrix\tprofile\tidentity\t-\t%s\t%s\n' \
		"$PROFILE" "$PROFILE_DESCRIPTION"
	printf 'matrix\ttarget\tidentity\t-\t%s\t%s\n' \
		"$CONFORMANCE_TARGET" "$CONFORMANCE_TARGET_DESCRIPTION"
	printf 'matrix\ttarget-selection\tidentity\t-\t%s\tHow the target was selected\n' \
		"$TARGET_SELECTION"
	printf 'matrix\tconfiguration\tidentity\t-\t%s\t%s\n' \
		"$CONFORMANCE_CONFIGURATION" \
		"$CONFORMANCE_CONFIGURATION_DESCRIPTION"
	printf 'matrix\tconfiguration-selection\tidentity\t-\t%s\tHow the configuration was selected\n' \
		"$CONFIGURATION_SELECTION"
	for id in "${CATALOG_IDS[@]}"; do
		printf 'test\t%s\t%s\t%s\t%s\t%s\n' "$id" "${TEST_GROUP[$id]}" \
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
case "$RUN_ID" in
*[!A-Za-z0-9._-]*|'')
	printf 'invalid RUN_ID: %s\n' "$RUN_ID" >&2
	exit 2
	;;
esac
case "$COMPARE_BASELINE:$COMPARE_CANDIDATE" in
*[!A-Za-z0-9._:-]*|:*|*:)
	printf 'invalid comparison profile: %s/%s\n' \
		"$COMPARE_BASELINE" "$COMPARE_CANDIDATE" >&2
	exit 2
	;;
esac
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

for boolean_field in PM_STRESS RUN_COUNTER_CHECKS CONFORMANCE_COUNTER_DEFAULTS \
	SUITE_DMESG_SCAN SUITE_REQUIRE_DMESG LIBRGA_FORCE_RGA_USERPTR_IOMMU \
	REQUIRE_COUNTER_FILE REQUIRE_FORBIDDEN_COUNTERS; do
	validate_boolean_field environment "$boolean_field" "${!boolean_field}"
done

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
declare -a FAILED_STAGE_IDS=()
RUN_RESULTS=${RUN_RESULTS:-"$LOG_ROOT/$RUN_ID-conformance-results.tsv"}
RUN_FINALIZED=0
# shellcheck disable=SC2034 # Read by the sourced stage-reporting helper.
RUN_STARTED_NS=$(runner_now_ns)

run_system_info()
{
	local collector
	local out=${OUT:-}

	collector=${SYSTEM_INFO_COLLECTOR:-"$TEST_DIR/conformance/scripts/collect-system-info.sh"}

	if [ ! -f "$collector" ]; then
		printf "Missing system-info collector: %s\n" "$collector" >&2
		return 2
	fi

	(
		cd "$CONFORMANCE_ROOT"
		if [ -n "$out" ]; then
			PROFILE="$PROFILE" OUT="$out" bash "$collector"
		else
			PROFILE="$PROFILE" bash "$collector"
		fi
	)
}

run_matrix_identity()
{
	local config_file release series
	local report="$LOG_ROOT/$RUN_ID-matrix-identity.tsv"
	local required forbidden required_series forbidden_series entry failed=0

	config_file=$(kernel_config_file)
	release=$(kernel_release)
	series=$(kernel_series "$release") || return 1

	if [ ! -r "$config_file" ]; then
		printf 'cannot verify declared matrix: unreadable kernel config %s\n' \
			"$config_file" >&2
		return 1
	fi

	required="$CONFORMANCE_TARGET_REQUIRED_CONFIG $CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG"
	forbidden="$CONFORMANCE_TARGET_FORBIDDEN_CONFIG $CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG"
	required_series=$CONFORMANCE_TARGET_REQUIRED_KERNEL_SERIES
	forbidden_series=$CONFORMANCE_TARGET_FORBIDDEN_KERNEL_SERIES
	{
		printf 'kind\tentry\tstatus\n'
		printf 'kernel-release\t%s\tobserved\n' "$release"
		printf 'kernel-series\t%s\tobserved\n' "$series"
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
		if [ -n "$required_series" ]; then
			if list_has "$required_series" "$series"; then
				printf 'required-kernel-series\t%s\tmatched\n' \
					"$required_series"
			else
				printf 'required-kernel-series\t%s\tmismatch\n' \
					"$required_series"
				failed=1
			fi
		fi
		if [ -n "$forbidden_series" ]; then
			if list_has "$forbidden_series" "$series"; then
				printf 'forbidden-kernel-series\t%s\tmatched\n' \
					"$forbidden_series"
				failed=1
			else
				printf 'forbidden-kernel-series\t%s\tabsent\n' \
					"$forbidden_series"
			fi
		fi
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
	CONFORMANCE_TARGET_FORBIDDEN_CONFIG='CONFIG_ROCKCHIP_MPP_SERVICE=y CONFIG_ROCKCHIP_MULTI_RGA=y' \
	CONFORMANCE_TARGET_REQUIRED_KERNEL_SERIES='' \
	CONFORMANCE_TARGET_FORBIDDEN_KERNEL_SERIES='' \
	CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG='CONFIG_KASAN=y' \
	CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG='CONFIG_KCSAN=y' \
	CONFORMANCE_KERNEL_CONFIG="$config_file" CONFORMANCE_KERNEL_RELEASE=6.18.38-ysp \
		LOG_ROOT="$out" RUN_ID=good \
		run_matrix_identity > /dev/null

	if CONFORMANCE_TARGET_REQUIRED_CONFIG='CONFIG_ROCKCHIP_MPP_REWRITE=y CONFIG_ROCKCHIP_RGA_REWRITE=y' \
		CONFORMANCE_TARGET_FORBIDDEN_CONFIG='' \
		CONFORMANCE_TARGET_REQUIRED_KERNEL_SERIES='' \
		CONFORMANCE_TARGET_FORBIDDEN_KERNEL_SERIES='' \
		CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG='CONFIG_KCSAN=y' \
		CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG='CONFIG_KASAN=y' \
		CONFORMANCE_KERNEL_CONFIG="$config_file" CONFORMANCE_KERNEL_RELEASE=6.18.38-ysp \
		LOG_ROOT="$out" RUN_ID=bad \
		run_matrix_identity > /dev/null 2>&1; then
		printf 'matrix identity mismatch unexpectedly passed\n' >&2
		return 1
	fi
	if CONFORMANCE_TARGET_REQUIRED_CONFIG='CONFIG_ROCKCHIP_MPP_REWRITE=y CONFIG_ROCKCHIP_RGA_REWRITE=y' \
		CONFORMANCE_TARGET_FORBIDDEN_CONFIG='' \
		CONFORMANCE_TARGET_REQUIRED_KERNEL_SERIES='5.10 6.1 6.6' \
		CONFORMANCE_TARGET_FORBIDDEN_KERNEL_SERIES='' \
		CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG='CONFIG_KASAN=y' \
		CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG='CONFIG_KCSAN=y' \
		CONFORMANCE_KERNEL_CONFIG="$config_file" CONFORMANCE_KERNEL_RELEASE=6.18.38-ysp \
		LOG_ROOT="$out" RUN_ID=bad-series \
		run_matrix_identity > /dev/null 2>&1; then
		printf 'matrix kernel-series mismatch unexpectedly passed\n' >&2
		return 1
	fi
	printf 'matrix identity selftest passed\n'
}

matrix_autodetect_selftest()
{
	local out="$CONFORMANCE_ROOT/build/harness-validation/matrix-autodetect"
	local vendor_config="$out/vendor.config"
	local rewrite_config="$out/rewrite.config"
	local both_sanitizers_config="$out/both-sanitizers.config"
	local release expected result

	mkdir -p "$out"
	{
		printf 'CONFIG_ROCKCHIP_MPP_SERVICE=y\n'
		printf 'CONFIG_ROCKCHIP_MULTI_RGA=y\n'
		printf 'CONFIG_VIDEO_ROCKCHIP_RGA=m\n'
	} > "$vendor_config"
	{
		printf 'CONFIG_ROCKCHIP_MPP_REWRITE=y\n'
		printf 'CONFIG_ROCKCHIP_RGA_REWRITE=y\n'
		printf 'CONFIG_KASAN=y\n'
	} > "$rewrite_config"
	{
		printf 'CONFIG_ROCKCHIP_MPP_SERVICE=y\n'
		printf 'CONFIG_ROCKCHIP_MULTI_RGA=y\n'
		printf 'CONFIG_VIDEO_ROCKCHIP_RGA=m\n'
		printf 'CONFIG_KASAN=y\n'
		printf 'CONFIG_KCSAN=y\n'
	} > "$both_sanitizers_config"

	for release in 5.10.221-vendor 6.1.99-vendor 6.6.80-vendor; do
		expected=bsp/production
		result=$(
			TARGET_ARG='' CONFIGURATION_ARG=''
			CONFORMANCE_KERNEL_CONFIG="$vendor_config"
			CONFORMANCE_KERNEL_RELEASE=$release
			autodetect_matrix
			printf '%s/%s\n' "$TARGET_ARG" "$CONFIGURATION_ARG"
		) || return 1
		if [ "$result" != "$expected" ]; then
			printf 'autodetected %s as %s, expected %s\n' \
				"$release" "$result" "$expected" >&2
			return 1
		fi
	done

	for release in 6.7.12-ysp 6.18.38-ysp 7.2.0-rc5-ysp; do
		expected=forward-port/production
		result=$(
			TARGET_ARG='' CONFIGURATION_ARG=''
			CONFORMANCE_KERNEL_CONFIG="$vendor_config"
			CONFORMANCE_KERNEL_RELEASE=$release
			autodetect_matrix
			printf '%s/%s\n' "$TARGET_ARG" "$CONFIGURATION_ARG"
		) || return 1
		if [ "$result" != "$expected" ]; then
			printf 'autodetected %s as %s, expected %s\n' \
				"$release" "$result" "$expected" >&2
			return 1
		fi
	done

	result=$(
		TARGET_ARG='' CONFIGURATION_ARG=''
		CONFORMANCE_KERNEL_CONFIG="$rewrite_config"
		CONFORMANCE_KERNEL_RELEASE=6.6.80-rewrite
		autodetect_matrix
		printf '%s/%s\n' "$TARGET_ARG" "$CONFIGURATION_ARG"
	) || return 1
	if [ "$result" != rewrite/kasan ]; then
		printf 'rewrite/KASAN autodetection returned %s\n' "$result" >&2
		return 1
	fi

	if (
		TARGET_ARG='' CONFIGURATION_ARG=''
		CONFORMANCE_KERNEL_CONFIG="$both_sanitizers_config"
		CONFORMANCE_KERNEL_RELEASE=6.18.38-ysp
		autodetect_matrix
	) > /dev/null 2>&1; then
		printf 'ambiguous sanitizer configuration unexpectedly autodetected\n' >&2
		return 1
	fi
	printf 'matrix autodetection selftest passed\n'
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

	run_step "$label.counters" "$label: check rewrite debugfs counters" \
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

	run_step "$suite" "$label" \
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
		run_step "$id" "$id: ${TEST_DESCRIPTION[$id]}" \
			env CONFORMANCE_ROOT="$CONFORMANCE_ROOT" PROFILE="$PROFILE" \
			BUILD_DIR="$CONFORMANCE_ROOT/build/ioctl-fuzz" \
			IOCTL_FUZZ_OUT="$out" \
			IOCTL_FUZZ_DMESG_SCAN=1 IOCTL_FUZZ_REQUIRE_DMESG=1 \
			IOCTL_FUZZ_FAIL_NTH_MAX="${IOCTL_FUZZ_FAIL_NTH_MAX:-4}" \
			bash "$TEST_DIR/$script"
		;;
	*)
		run_step "$id" "$id: ${TEST_DESCRIPTION[$id]}" \
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
		run_step "$id" "kunit: require booted rewrite suites green" \
			env KUNIT_REPORT="$LOG_ROOT/$RUN_ID-kunit.tsv" \
			bash "$TEST_DIR/rewrite-kunit-log-check.sh"
		;;
	builtin:system-info)
		OUT="$LOG_ROOT/$RUN_ID-system" \
			run_step "$id" "system: collect profile state" run_system_info
		;;
	builtin:matrix-identity)
		run_step "$id" "identity: verify target/configuration kernel config" \
			run_matrix_identity
		;;
	builtin:abi)
		run_step "$id" "abi: replay normalized ioctl contract" \
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
			run_step "$id.compare" "abi: compare normalized ioctl contract" \
				env PROFILE="$candidate" BASELINE="$baseline" \
				bash "$TEST_DIR/abi-replay.sh"
			;;
		*)
			run_step "$id.compare" "$id: compare latest suite summaries" \
				env BASELINE="$baseline" CANDIDATE="$candidate" \
				CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
				PERF_MAX_RATIO="$perf_max_ratio" \
				bash "$TEST_DIR/$argument-suite-compare.sh"
			;;
		esac
	done
}

stage_reporting_selftest()
{
	local out="$CONFORMANCE_ROOT/build/harness-validation/stage-reporting"
	local results="$out/results.tsv"
	local fail_results="$out/fail-fast-results.tsv"
	local fail_status

	mkdir -p "$out"
	if ! (
		RUN_RESULTS="$results"
		RUN_CONTINUE_ON_FAIL=1
		# shellcheck disable=SC2034 # Read by the sourced helper.
		RUN_FINALIZED=0
		FAILED_STAGE_IDS=()
		init_run_results
		run_step fixture-pass "reporting pass fixture" true
		run_optional_step fixture-skip "reporting skip fixture" \
			bash -c 'exit 77'
		run_step fixture-fail "reporting failure fixture" \
			bash -c 'exit 9'
		[ "${FAILED_STAGE_IDS[*]}" = fixture-fail ]
	) > "$out/output.txt" 2>&1; then
		printf 'stage reporting fixture did not complete; see %s\n' \
			"$out/output.txt" >&2
		return 1
	fi

	awk -F '\t' '
		NR == 1 && $0 == "stage\trequirement\tstatus\texit_code\telapsed_s\tdescription" { header = 1 }
		$1 == "fixture-pass" && $2 == "required" && $3 == "pass" && $4 == 0 { pass = 1 }
		$1 == "fixture-skip" && $2 == "optional" && $3 == "skip" && $4 == 77 { skip = 1 }
		$1 == "fixture-fail" && $2 == "required" && $3 == "fail" && $4 == 9 { fail = 1 }
		END { exit !(header && pass && skip && fail && NR == 4) }
	' "$results" || {
		printf 'stage reporting result schema failed; see %s\n' "$results" >&2
		return 1
	}

	set +e
	(
		RUN_RESULTS="$fail_results"
		RUN_CONTINUE_ON_FAIL=0
		# shellcheck disable=SC2034 # Read by the sourced helper.
		RUN_FINALIZED=0
		FAILED_STAGE_IDS=()
		init_run_results
		run_step fixture-stop "reporting fail-fast fixture" \
			bash -c 'exit 6'
	) > "$out/fail-fast-output.txt" 2>&1
	fail_status=$?
	set -e
	if [ "$fail_status" -ne 6 ]; then
		printf 'stage reporting fail-fast fixture returned %s, expected 6\n' \
			"$fail_status" >&2
		return 1
	fi
	awk -F '\t' '
		$1 == "fixture-stop" && $3 == "fail" && $4 == 6 { failed = 1 }
		$1 == "overall" && $2 == "run" && $3 == "fail" && $4 == 6 { overall = 1 }
		END { exit !(failed && overall && NR == 3) }
	' "$fail_results" || {
		printf 'stage reporting fail-fast result failed; see %s\n' \
			"$fail_results" >&2
		return 1
	}

	printf 'stage reporting selftest passed\n'
}

validate_static_contract()
{
	validate_descriptor_sets
	validate_catalog_contract
}

run_validation()
{
	run_step validate.catalog "catalog: validate descriptors and coverage contract" \
		validate_static_contract

	run_step validate.stage-reporting "runner: validate stage result reporting" \
		stage_reporting_selftest

	run_step validate.matrix-autodetect "identity: validate matrix autodetection" \
		matrix_autodetect_selftest

	run_step validate.matrix-identity "identity: validate matrix config gate" \
		matrix_identity_selftest

	run_step validate.counter-defaults "counter defaults: validate wiring" \
		validate_counter_defaults

	run_step validate.system-info "identity: validate system-info redaction" \
		bash "$TEST_DIR/conformance/scripts/collect-system-info.sh" --selftest

	run_step validate.mpp-debug-capture \
		"debugging: validate focused MPP capture workflow" \
		env MPP_DEBUG_VALIDATE_ONLY=1 \
		bash "$TEST_DIR/mpp-debug-capture.sh"

	run_step validate.dmesg "kernel log: fatal-signature gate selftest" \
		bash "$TEST_DIR/suite-common-selftest.sh"

	run_step validate.kunit "kunit: boot-result parser selftest" \
		bash "$TEST_DIR/rewrite-kunit-log-check.sh" --selftest

	# The two syzlang checks that used to run here moved to the private
	# rock-5b-security repository along with the syzkaller description
	# itself; run them from there when validating the fuzzing description.

	run_step validate.ioctl-fuzz "fuzzing: validate ioctl mutator build" \
		env IOCTL_FUZZ_VALIDATE_BUILD=1 \
		BUILD_DIR="$CONFORMANCE_ROOT/build/harness-validation/ioctl-fuzz" \
		bash "$TEST_DIR/ioctl-fuzz-smoke.sh"

	run_step validate.librga-smoke "rga: validate direct librga smoke build" \
		env LIBRGA_SMOKE_VALIDATE_BUILD=1 \
		bash "$TEST_DIR/librga-smoke.sh"

	run_step validate.librga-log-parser \
		"rga: validate official-sample result classification" \
		env LIBRGA_SUITE_VALIDATE_LOG_PARSER=1 \
		bash "$TEST_DIR/librga-suite.sh"

	run_step validate.librga-cases "rga: validate default and opt-in case lists" \
		env LIBRGA_SUITE_VALIDATE_CASES=1 \
		bash "$TEST_DIR/librga-suite.sh"

	run_optional_step validate.gstreamer-event-build \
		"gstreamer: validate event harness build" \
		env GST_EVENT_HARNESS_VALIDATE_BUILD=1 \
		bash "$TEST_DIR/build-gstreamer-rockchip.sh"

	run_step validate.iommu-fuzz "iommu: validate RGA scatter fuzzer build" \
		env IOMMU_FUZZ_VALIDATE_BUILD=1 \
		OUT="$CONFORMANCE_ROOT/build/harness-validation/iommu-fuzz" \
		bash "$TEST_DIR/iommu-machinery-fuzz.sh"

	run_step validate.recovery "recovery: validate stress harness config" \
		env RECOVERY_VALIDATE_ONLY=1 \
		bash "$TEST_DIR/rewrite-recovery-stress.sh"

	run_step validate.pm-knobs "pm: validate autosuspend stress knobs" \
		bash "$TEST_DIR/pm-stress-knobs.sh" --validate

	run_step validate.case-pair-matrix "pm: validate case-pair matrix" \
		env VALIDATE_ONLY=1 bash "$TEST_DIR/rewrite-case-pair-matrix.sh"

	run_step validate.mpp-cases "mpp: validate case builders" \
		env MPP_VALIDATE_CASES=1 PROFILE="$PROFILE" \
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
		MPP_H264_INPUT=/dev/null MPP_H265_INPUT=/dev/null \
		MPP_VP9_INPUT=/dev/null MPP_AVS2_INPUT=/dev/null \
		MPP_DEC_INPUT=/dev/null MPP_DEC_TYPE=7 \
		MPP_ENC_INPUT=/dev/null MPP_ENC_WIDTH=16 MPP_ENC_HEIGHT=16 \
		MPP_ENC_TYPE=7 \
		MPP_REQUIRED_CASES="mpp_info_test mpi_dec_h264 mpi_dec_h265 mpi_dec_vp9 mpi_dec_avs2 mpi_dec_custom mpi_dec_mt_h264 mpi_dec_mt_h265 mpi_dec_mt_vp9 mpi_dec_mt_avs2 mpi_dec_mt_custom mpi_dec_multi_h264 mpi_dec_multi_h265 mpi_dec_multi_vp9 mpi_dec_multi_avs2 mpi_dec_multi_custom mpi_enc_h264 mpi_enc_h265 mpi_enc_h264_slice mpi_enc_h265_slice mpi_enc_custom mpi_enc_mt_h264 mpi_enc_mt_h265 mpi_enc_mt_custom mpi_rc2_h264 mpi_rc2_h265 mpi_rc2_custom vpu_api_dec_h264 vpu_api_dec_h265 vpu_api_dec_avs2 vpu_api_dec_custom" \
		bash "$TEST_DIR/mpp-suite.sh"

	run_step validate.gstreamer-cases "gstreamer: validate case builders" \
		env GST_VALIDATE_CASES=1 PROFILE="$PROFILE" \
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
		bash "$TEST_DIR/gstreamer-suite.sh"

	run_step validate.ffmpeg-cases "ffmpeg: validate case list" \
		env FFMPEG_VALIDATE_CASES=1 PROFILE="$PROFILE" \
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
		bash "$TEST_DIR/ffmpeg-suite.sh"

	run_step validate.rkmppenc-cases "rkmppenc: validate optional case list" \
		env RKMPPENC_VALIDATE_CASES=1 PROFILE="$PROFILE" \
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
		bash "$TEST_DIR/rkmppenc-suite.sh"

	run_step validate.comparators "comparators: regression selftest" \
		bash "$TEST_DIR/suite-compare-selftest.sh"

	run_step validate.abi "abi replay: filter selftest" \
		bash "$TEST_DIR/abi-replay.sh" --selftest

	run_step validate.evidence-audit "evidence: audit selftest" \
		bash "$TEST_DIR/rewrite-evidence-audit.sh" --selftest
}

mkdir -p "$LOG_ROOT"
init_run_results
PLAN_FILE="$LOG_ROOT/$RUN_ID-conformance-plan.tsv"
print_plan | tee "$PLAN_FILE"
printf 'Stage results: %s\n\n' "$RUN_RESULTS"

if [ "$ACTION" = validate ]; then
	run_validation
	if [ "${#FAILED_STAGE_IDS[@]}" -ne 0 ]; then
		printf 'Conformance harness validation failed stages: %s\n' \
			"${FAILED_STAGE_IDS[*]}" >&2
		finalize_run 1 \
			"Device-free validation failed stages: ${FAILED_STAGE_IDS[*]}"
		exit 1
	fi
	printf "\nConformance harness validation passed\n"
	finalize_run 0 "All device-free validation stages passed"
	exit 0
fi

if [ "$PM_STRESS" = "1" ]; then
	run_step pm.apply "pm: collapse autosuspend windows for the run" \
		bash "$TEST_DIR/pm-stress-knobs.sh" apply
	trap 'bash "$TEST_DIR/pm-stress-knobs.sh" restore || :' EXIT
fi

run_profile_tests

if [ "$RUN_COMPARE" = "1" ]; then
	run_comparators
fi

if [ "${#FAILED_STAGE_IDS[@]}" -ne 0 ]; then
	printf "Conformance profile '%s' completed with failed stages: %s\n" \
		"$PROFILE" "${FAILED_STAGE_IDS[*]}" >&2
	finalize_run 1 "Completed with failed stages: ${FAILED_STAGE_IDS[*]}"
	exit 1
fi

printf "Conformance profile '%s' completed\n" "$PROFILE"
finalize_run 0 "All selected conformance stages passed"
