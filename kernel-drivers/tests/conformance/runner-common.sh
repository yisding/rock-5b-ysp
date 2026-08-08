# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Shared validation and stage-reporting primitives for run-conformance.sh.

validate_boolean_field()
{
	local owner=$1 field=$2 value=$3

	case "$value" in
	0|1) ;;
	*)
		printf '%s has invalid %s=%s; expected 0 or 1\n' \
			"$owner" "$field" "$value" >&2
		return 1
		;;
	esac
}

validate_descriptor_file()
(
	local descriptor=$1 kind=$2 expected=$3 field
	local identity_field description_field identity description
	local -a required_fields boolean_fields

	case "$expected" in
	*[!a-z0-9-]*|'')
		printf 'invalid %s descriptor filename: %s\n' "$kind" "$descriptor" >&2
		return 1
		;;
	esac

	unset CONFORMANCE_TARGET CONFORMANCE_TARGET_DESCRIPTION
	unset CONFORMANCE_TARGET_REQUIRED_CONFIG CONFORMANCE_TARGET_FORBIDDEN_CONFIG
	unset CONFORMANCE_TARGET_REQUIRED_KERNEL_SERIES
	unset CONFORMANCE_TARGET_FORBIDDEN_KERNEL_SERIES
	unset CONFORMANCE_TARGET_COUNTER_DEFAULTS CONFORMANCE_TARGET_REQUIRE_DMESG
	unset CONFORMANCE_CONFIGURATION CONFORMANCE_CONFIGURATION_DESCRIPTION
	unset CONFORMANCE_CONFIGURATION_PROFILE_SUFFIX
	unset CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG
	unset CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG
	unset CONFORMANCE_CONFIGURATION_REQUIRE_DMESG
	unset CONFORMANCE_CONFIGURATION_PERF_VALID
	# shellcheck disable=SC1090
	source "$descriptor"

	case "$kind" in
	target)
		identity_field=CONFORMANCE_TARGET
		description_field=CONFORMANCE_TARGET_DESCRIPTION
		required_fields=(
			"$identity_field" "$description_field"
			CONFORMANCE_TARGET_REQUIRED_CONFIG
			CONFORMANCE_TARGET_FORBIDDEN_CONFIG
			CONFORMANCE_TARGET_REQUIRED_KERNEL_SERIES
			CONFORMANCE_TARGET_FORBIDDEN_KERNEL_SERIES
			CONFORMANCE_TARGET_COUNTER_DEFAULTS
			CONFORMANCE_TARGET_REQUIRE_DMESG
		)
		boolean_fields=(
			CONFORMANCE_TARGET_COUNTER_DEFAULTS
			CONFORMANCE_TARGET_REQUIRE_DMESG
		)
		;;
	configuration)
		identity_field=CONFORMANCE_CONFIGURATION
		description_field=CONFORMANCE_CONFIGURATION_DESCRIPTION
		required_fields=(
			"$identity_field" "$description_field"
			CONFORMANCE_CONFIGURATION_PROFILE_SUFFIX
			CONFORMANCE_CONFIGURATION_REQUIRED_CONFIG
			CONFORMANCE_CONFIGURATION_FORBIDDEN_CONFIG
			CONFORMANCE_CONFIGURATION_REQUIRE_DMESG
			CONFORMANCE_CONFIGURATION_PERF_VALID
		)
		boolean_fields=(
			CONFORMANCE_CONFIGURATION_REQUIRE_DMESG
			CONFORMANCE_CONFIGURATION_PERF_VALID
		)
		;;
	esac

	for field in "${required_fields[@]}"; do
		if ! [[ -v $field ]]; then
			printf 'descriptor %s does not declare %s\n' \
				"$descriptor" "$field" >&2
			return 1
		fi
	done

	identity=${!identity_field}
	description=${!description_field}
	if [ "$identity" != "$expected" ]; then
		printf 'descriptor identity mismatch in %s: expected %s %s, got %s\n' \
			"$descriptor" "$kind" "$expected" "$identity" >&2
		return 1
	fi
	if [ -z "$description" ]; then
		printf 'descriptor %s has an empty %s description\n' \
			"$descriptor" "$kind" >&2
		return 1
	fi
	for field in "${boolean_fields[@]}"; do
		validate_boolean_field "$descriptor" "$field" "${!field}"
	done
)

validate_descriptor_sets()
{
	local descriptor expected

	for descriptor in "$TARGET_DIR"/*.env; do
		expected=${descriptor##*/}
		validate_descriptor_file "$descriptor" target "${expected%.env}"
	done
	for descriptor in "$CONFIGURATION_DIR"/*.env; do
		expected=${descriptor##*/}
		validate_descriptor_file "$descriptor" configuration "${expected%.env}"
	done
}

runner_now_ns()
{
	local now

	now=$(date +%s%N)
	case "$now" in
	*N*) printf '%s000000000\n' "$(date +%s)" ;;
	*) printf '%s\n' "$now" ;;
	esac
}

runner_elapsed_s()
{
	local start=$1 end=$2

	awk -v ns="$((end - start))" 'BEGIN {
		if (ns < 0)
			ns = 0;
		printf "%.3f", ns / 1000000000;
	}'
}

init_run_results()
{
	mkdir -p "$(dirname "$RUN_RESULTS")"
	printf 'stage\trequirement\tstatus\texit_code\telapsed_s\tdescription\n' \
		> "$RUN_RESULTS"
}

record_stage_result()
{
	local stage=$1 requirement=$2 status=$3 rc=$4 elapsed=$5 description=$6

	description=${description//$'\t'/ }
	description=${description//$'\n'/ }
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$stage" "$requirement" "$status" "$rc" "$elapsed" "$description" \
		>> "$RUN_RESULTS"
}

reown_run_outputs()
{
	local path

	if [ "$(id -u)" != 0 ] || [ -z "${SUDO_UID:-}" ]; then
		return 0
	fi
	for path in "$LOG_ROOT/$RUN_ID"-* "$RUN_RESULTS"; do
		[ -e "$path" ] || continue
		chown -R "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$path" ||
			printf 'warning: could not return %s to uid %s\n' \
				"$path" "$SUDO_UID" >&2
	done
	return 0
}

print_run_summary()
{
	printf '\nStage summary: %s\n' "$RUN_RESULTS"
	if command -v column >/dev/null 2>&1; then
		column -t -s $'\t' "$RUN_RESULTS" || cat "$RUN_RESULTS"
	else
		cat "$RUN_RESULTS"
	fi
}

finalize_run()
{
	local rc=$1 description=$2 status=pass end elapsed

	if [ "$RUN_FINALIZED" = 1 ]; then
		return 0
	fi
	RUN_FINALIZED=1
	if [ "$rc" -ne 0 ]; then
		status=fail
	fi
	end=$(runner_now_ns)
	elapsed=$(runner_elapsed_s "$RUN_STARTED_NS" "$end")
	record_stage_result overall run "$status" "$rc" "$elapsed" "$description"
	print_run_summary
	reown_run_outputs
}

step_failed()
{
	local stage=$1 name=$2 rc=$3

	printf 'RESULT [%s] FAIL exit=%s -- %s\n' "$stage" "$rc" "$name" >&2
	if [ "$RUN_CONTINUE_ON_FAIL" = "1" ]; then
		FAILED_STAGE_IDS+=("$stage")
		return 0
	fi
	finalize_run "$rc" "Stopped after $stage failed"
	exit "$rc"
}

run_step()
{
	local stage=$1 name=$2
	shift 2
	local rc start end elapsed

	printf '\nBEGIN  [%s] %s\n' "$stage" "$name"
	start=$(runner_now_ns)
	set +e
	"$@"
	rc=$?
	set -e
	end=$(runner_now_ns)
	elapsed=$(runner_elapsed_s "$start" "$end")

	if [ "$rc" -eq 0 ]; then
		record_stage_result "$stage" required pass 0 "$elapsed" "$name"
		printf 'RESULT [%s] PASS elapsed=%ss -- %s\n' \
			"$stage" "$elapsed" "$name"
	else
		record_stage_result "$stage" required fail "$rc" "$elapsed" "$name"
		step_failed "$stage" "$name" "$rc"
	fi
}

run_optional_step()
{
	local stage=$1 name=$2
	shift 2
	local rc start end elapsed

	printf '\nBEGIN  [%s] %s\n' "$stage" "$name"
	start=$(runner_now_ns)
	set +e
	"$@"
	rc=$?
	set -e
	end=$(runner_now_ns)
	elapsed=$(runner_elapsed_s "$start" "$end")

	case "$rc" in
	0)
		record_stage_result "$stage" optional pass 0 "$elapsed" "$name"
		printf 'RESULT [%s] PASS elapsed=%ss -- %s\n' \
			"$stage" "$elapsed" "$name"
		;;
	77)
		record_stage_result "$stage" optional skip 77 "$elapsed" "$name"
		printf 'RESULT [%s] SKIP exit=77 elapsed=%ss -- %s\n' \
			"$stage" "$elapsed" "$name"
		;;
	*)
		record_stage_result "$stage" optional fail "$rc" "$elapsed" "$name"
		step_failed "$stage" "$name" "$rc"
		;;
	esac
}
