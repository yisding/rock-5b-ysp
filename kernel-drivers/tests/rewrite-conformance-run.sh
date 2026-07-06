#!/usr/bin/env bash
# Run the expanded RK3588 rewrite/forward-port conformance bundle for one
# profile, and optionally compare the latest forward-port/rewrite summaries.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
PROFILE=${PROFILE:-${1:-rewrite}}
COMPARE_BASELINE=${COMPARE_BASELINE:-forward-port}
COMPARE_CANDIDATE=${COMPARE_CANDIDATE:-$PROFILE}

RUN_SYSTEM_INFO=${RUN_SYSTEM_INFO:-1}
RUN_ABI_REPLAY=${RUN_ABI_REPLAY:-1}
RUN_MPP_SUITE=${RUN_MPP_SUITE:-1}
RUN_LIBRGA_SUITE=${RUN_LIBRGA_SUITE:-1}
RUN_GSTREAMER_SUITE=${RUN_GSTREAMER_SUITE:-1}
RUN_FFMPEG_SUITE=${RUN_FFMPEG_SUITE:-1}
RUN_COMPARE=${RUN_COMPARE:-0}
RUN_COUNTER_CHECKS=${RUN_COUNTER_CHECKS:-0}
VALIDATE_ONLY=${VALIDATE_ONLY:-0}
REWRITE_COUNTER_DEFAULTS=${REWRITE_COUNTER_DEFAULTS:-1}
RUN_ID=${RUN_ID:-$(date +%Y%m%d-%H%M%S)}
LOG_ROOT=${LOG_ROOT:-"$CONFORMANCE_ROOT/logs/$PROFILE"}
MPP_SUITE_OUT=${MPP_SUITE_OUT:-"$LOG_ROOT/$RUN_ID-mpp-suite"}
LIBRGA_SUITE_OUT=${LIBRGA_SUITE_OUT:-"$LOG_ROOT/$RUN_ID-librga-suite"}
GSTREAMER_SUITE_OUT=${GSTREAMER_SUITE_OUT:-"$LOG_ROOT/$RUN_ID-gstreamer-suite"}
FFMPEG_SUITE_OUT=${FFMPEG_SUITE_OUT:-"$LOG_ROOT/$RUN_ID-ffmpeg-suite"}
MPP_REQUIRED_POSITIVE_COUNTERS=${MPP_REQUIRED_POSITIVE_COUNTERS:-}
LIBRGA_REQUIRED_POSITIVE_COUNTERS=${LIBRGA_REQUIRED_POSITIVE_COUNTERS:-}
GSTREAMER_REQUIRED_POSITIVE_COUNTERS=${GSTREAMER_REQUIRED_POSITIVE_COUNTERS:-}
FFMPEG_REQUIRED_POSITIVE_COUNTERS=${FFMPEG_REQUIRED_POSITIVE_COUNTERS:-}
MPP_REQUIRED_ZERO_AFTER_COUNTERS=${MPP_REQUIRED_ZERO_AFTER_COUNTERS:-}
LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS=${LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS:-}
GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS=${GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS:-}
FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS=${FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS:-}
REQUIRE_COUNTER_FILE_WAS_SET=${REQUIRE_COUNTER_FILE+x}
REQUIRE_COUNTER_FILE=${REQUIRE_COUNTER_FILE:-0}

case "$PROFILE" in
*rewrite*)
	if [ "$RUN_COUNTER_CHECKS" = "1" ] &&
		[ "$REWRITE_COUNTER_DEFAULTS" = "1" ]; then
		if [ -z "$REQUIRE_COUNTER_FILE_WAS_SET" ]; then
			REQUIRE_COUNTER_FILE=1
		fi
		if [ -z "$LIBRGA_REQUIRED_POSITIVE_COUNTERS" ]; then
			LIBRGA_REQUIRED_POSITIVE_COUNTERS="rga:started_job_count rga:hw_total_ns"
			if [ "${LIBRGA_FORCE_ROUTE_B:-0}" = "1" ]; then
				LIBRGA_REQUIRED_POSITIVE_COUNTERS="$LIBRGA_REQUIRED_POSITIVE_COUNTERS rga_route_b:attempt rga_route_b:ok"
			fi
		fi
		if [ "${LIBRGA_FORCE_ROUTE_B:-0}" = "1" ] &&
			[ -z "$LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS" ]; then
			LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS="rga_route_b:active"
		fi
		: "${GSTREAMER_REQUIRED_POSITIVE_COUNTERS:=mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns}"
		: "${FFMPEG_REQUIRED_POSITIVE_COUNTERS:=mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns}"
		if [ -n "${MPP_REQUIRED_CASES:-}" ]; then
			: "${MPP_REQUIRED_POSITIVE_COUNTERS:=mpp:started_job_count mpp:hw_total_ns}"
		fi
	fi
	;;
esac

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
		printf "%s FAILED with exit code %s\n" "$name" "$rc" >&2
		exit "$rc"
	fi
}

run_system_info()
{
	local collector="$CONFORMANCE_ROOT/scripts/collect-system-info.sh"

	if [ ! -x "$collector" ]; then
		printf "Missing system-info collector: %s\n" "$collector" >&2
		return 2
	fi

	(
		cd "$CONFORMANCE_ROOT"
		PROFILE="$PROFILE" ./scripts/collect-system-info.sh
	)
}

run_counter_check()
{
	local label=$1
	local summary=$2
	local required=$3
	local required_zero_after=$4

	if [ "$RUN_COUNTER_CHECKS" != "1" ]; then
		return
	fi

	run_step "$label: check rewrite debugfs counters" \
		env SUMMARY="$summary" \
		REQUIRED_POSITIVE_COUNTERS="$required" \
		REQUIRED_ZERO_AFTER_COUNTERS="$required_zero_after" \
		FORBID_POSITIVE_COUNTERS="${FORBID_POSITIVE_COUNTERS:-}" \
		REQUIRE_COUNTER_FILE="$REQUIRE_COUNTER_FILE" \
		bash "$TEST_DIR/debugfs-counter-check.sh"
}

validate_counter_defaults()
{
	case "$PROFILE" in
	*rewrite*)
		;;
	*)
		printf "counter defaults skipped for profile '%s'\n" "$PROFILE"
		return 0
		;;
	esac

	if [ "$RUN_COUNTER_CHECKS" != "1" ]; then
		printf "counter defaults skipped because RUN_COUNTER_CHECKS=%s\n" \
			"$RUN_COUNTER_CHECKS"
		return 0
	fi

	if [ "$REWRITE_COUNTER_DEFAULTS" != "1" ]; then
		printf "counter defaults skipped because REWRITE_COUNTER_DEFAULTS=%s\n" \
			"$REWRITE_COUNTER_DEFAULTS"
		return 0
	fi

	if [ "$REQUIRE_COUNTER_FILE" != "1" ]; then
		printf "rewrite counter defaults did not require counter files\n" >&2
		return 1
	fi

	if [ -z "$LIBRGA_REQUIRED_POSITIVE_COUNTERS" ]; then
		printf "rewrite counter defaults did not require librga counters\n" >&2
		return 1
	fi
	if [ "${LIBRGA_FORCE_ROUTE_B:-0}" = "1" ]; then
		case " $LIBRGA_REQUIRED_POSITIVE_COUNTERS " in
		*" rga_route_b:attempt "*)
			;;
		*)
			printf "rewrite Route B forced mode did not require route_b attempts\n" >&2
			return 1
			;;
		esac
		case " $LIBRGA_REQUIRED_POSITIVE_COUNTERS " in
		*" rga_route_b:ok "*)
			;;
		*)
			printf "rewrite Route B forced mode did not require route_b successes\n" >&2
			return 1
			;;
		esac
		case " $LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS " in
		*" rga_route_b:active "*)
			;;
		*)
			printf "rewrite Route B forced mode did not require active gauge to return to zero\n" >&2
			return 1
			;;
		esac
	fi
	if [ -z "$GSTREAMER_REQUIRED_POSITIVE_COUNTERS" ]; then
		printf "rewrite counter defaults did not require GStreamer counters\n" >&2
		return 1
	fi
	if [ -z "$FFMPEG_REQUIRED_POSITIVE_COUNTERS" ]; then
		printf "rewrite counter defaults did not require FFmpeg counters\n" >&2
		return 1
	fi
	if [ -n "${MPP_REQUIRED_CASES:-}" ] &&
		[ -z "$MPP_REQUIRED_POSITIVE_COUNTERS" ]; then
		printf "rewrite counter defaults did not require MPP counters for explicit MPP cases\n" >&2
		return 1
	fi

	printf "rewrite counter defaults validated\n"
}

run_profile_suites()
{
	if [ "$RUN_SYSTEM_INFO" = "1" ]; then
		run_step "system: collect profile state" run_system_info
	fi

	if [ "$RUN_ABI_REPLAY" = "1" ]; then
		run_step "abi: replay normalized ioctl contract" \
			env PROFILE="$PROFILE" bash "$TEST_DIR/abi-replay.sh"
	fi

	if [ "$RUN_MPP_SUITE" = "1" ]; then
		run_step "mpp: official test suite" \
			env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			OUT="$MPP_SUITE_OUT" \
			bash "$TEST_DIR/mpp-suite.sh"
		run_counter_check "mpp" "$MPP_SUITE_OUT/summary.tsv" \
			"$MPP_REQUIRED_POSITIVE_COUNTERS" \
			"$MPP_REQUIRED_ZERO_AFTER_COUNTERS"
	fi

	if [ "$RUN_LIBRGA_SUITE" = "1" ]; then
		run_step "rga: official librga suite" \
			env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			OUT="$LIBRGA_SUITE_OUT" \
			bash "$TEST_DIR/librga-suite.sh"
		run_counter_check "rga" "$LIBRGA_SUITE_OUT/summary.tsv" \
			"$LIBRGA_REQUIRED_POSITIVE_COUNTERS" \
			"$LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS"
	fi

	if [ "$RUN_GSTREAMER_SUITE" = "1" ]; then
		run_step "gstreamer: JeffyCN plugin suite" \
			env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			OUT="$GSTREAMER_SUITE_OUT" \
			bash "$TEST_DIR/gstreamer-suite.sh"
		run_counter_check "gstreamer" "$GSTREAMER_SUITE_OUT/summary.tsv" \
			"$GSTREAMER_REQUIRED_POSITIVE_COUNTERS" \
			"$GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS"
	fi

	if [ "$RUN_FFMPEG_SUITE" = "1" ]; then
		run_step "ffmpeg: rkmpp/rkrga CLI suite" \
			env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			OUT="$FFMPEG_SUITE_OUT" \
			bash "$TEST_DIR/ffmpeg-suite.sh"
		run_counter_check "ffmpeg" "$FFMPEG_SUITE_OUT/summary.tsv" \
			"$FFMPEG_REQUIRED_POSITIVE_COUNTERS" \
			"$FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS"
	fi
}

run_comparators()
{
	local baseline=$COMPARE_BASELINE
	local candidate=$COMPARE_CANDIDATE

	if [ "$RUN_ABI_REPLAY" = "1" ]; then
		run_step "abi: compare normalized ioctl contract" \
			env PROFILE="$candidate" BASELINE="$baseline" \
			bash "$TEST_DIR/abi-replay.sh"
	fi

	if [ "$RUN_MPP_SUITE" = "1" ]; then
		run_step "mpp: compare latest suite summaries" \
			env BASELINE="$baseline" CANDIDATE="$candidate" \
			CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			bash "$TEST_DIR/mpp-suite-compare.sh"
	fi

	if [ "$RUN_LIBRGA_SUITE" = "1" ]; then
		run_step "rga: compare latest suite summaries" \
			env BASELINE="$baseline" CANDIDATE="$candidate" \
			CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			bash "$TEST_DIR/librga-suite-compare.sh"
	fi

	if [ "$RUN_GSTREAMER_SUITE" = "1" ]; then
		run_step "gstreamer: compare latest suite summaries" \
			env BASELINE="$baseline" CANDIDATE="$candidate" \
			CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			bash "$TEST_DIR/gstreamer-suite-compare.sh"
	fi

	if [ "$RUN_FFMPEG_SUITE" = "1" ]; then
		run_step "ffmpeg: compare latest suite summaries" \
			env BASELINE="$baseline" CANDIDATE="$candidate" \
			CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			bash "$TEST_DIR/ffmpeg-suite-compare.sh"
	fi
}

run_validation()
{
	run_step "counter defaults: validate wiring" validate_counter_defaults

	run_step "fuzzing: validate syzlang ABI constants" \
		bash "$TEST_DIR/syzkaller/check-rockchip-syzlang.sh"

	if [ "$RUN_GSTREAMER_SUITE" = "1" ]; then
		run_step "gstreamer: validate case builders" \
			env GST_VALIDATE_CASES=1 PROFILE="$PROFILE" \
			CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			bash "$TEST_DIR/gstreamer-suite.sh"
	fi

	if [ "$RUN_FFMPEG_SUITE" = "1" ]; then
		run_step "ffmpeg: validate case list" \
			env FFMPEG_VALIDATE_CASES=1 PROFILE="$PROFILE" \
			CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			bash "$TEST_DIR/ffmpeg-suite.sh"
	fi

	run_step "comparators: regression selftest" \
		bash "$TEST_DIR/suite-compare-selftest.sh"
}

if [ "$VALIDATE_ONLY" = "1" ]; then
	run_validation
	printf "Conformance runner validation passed\n"
	exit 0
fi

run_profile_suites

if [ "$RUN_COMPARE" = "1" ]; then
	run_comparators
fi

printf "Conformance profile '%s' completed\n" "$PROFILE"
