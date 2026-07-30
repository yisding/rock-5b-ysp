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
RUN_RKMPPENC_SUITE=${RUN_RKMPPENC_SUITE:-0}
RUN_COMPARE=${RUN_COMPARE:-0}
RUN_COUNTER_CHECKS=${RUN_COUNTER_CHECKS:-0}
RUN_KUNIT_CHECK=${RUN_KUNIT_CHECK:-}
VALIDATE_ONLY=${VALIDATE_ONLY:-0}
REWRITE_COUNTER_DEFAULTS=${REWRITE_COUNTER_DEFAULTS:-1}
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

if [ -z "$RUN_KUNIT_CHECK" ]; then
	case "$PROFILE" in
	*rewrite*) RUN_KUNIT_CHECK=1 ;;
	*) RUN_KUNIT_CHECK=0 ;;
	esac
fi

case "$PROFILE" in
*rewrite*)
	if [ -z "$SUITE_REQUIRE_DMESG_WAS_SET" ]; then
		SUITE_REQUIRE_DMESG=1
	fi
	if [ "$RUN_COUNTER_CHECKS" = "1" ] &&
		[ "$REWRITE_COUNTER_DEFAULTS" = "1" ]; then
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
		if [ "$RUN_RKMPPENC_SUITE" = "1" ]; then
			: "${RKMPPENC_REQUIRED_POSITIVE_COUNTERS:=mpp:started_job_count rga:started_job_count mpp:hw_total_ns rga:hw_total_ns}"
			: "${RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS:=mpp:import_count mpp:queued_job_count rga:import_count rga:shadow_head_active_count rga:shadow_tail_active_count}"
		fi
		if [ -n "${MPP_REQUIRED_CASES:-}" ]; then
			: "${MPP_REQUIRED_POSITIVE_COUNTERS:=mpp:started_job_count mpp:hw_total_ns}"
		fi
	fi
	;;
esac

export SUITE_DMESG_SCAN SUITE_REQUIRE_DMESG

# RUN_CONTINUE_ON_FAIL=1 records a suite failure and moves on to the
# remaining suites instead of aborting the whole run at the first failure
# (2026-07-24 harness-gap fix: a red librga demo matrix or GStreamer suite
# used to block the FFmpeg suite entirely).  The runner still exits
# non-zero at the end when any suite failed.
RUN_CONTINUE_ON_FAIL=${RUN_CONTINUE_ON_FAIL:-0}
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
	if [ "$REQUIRE_FORBIDDEN_COUNTERS" != "1" ]; then
		printf "rewrite counter defaults did not require safety-counter presence\n" >&2
		return 1
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
	if ! counter_list_has "$MPP_REQUIRED_ZERO_AFTER_COUNTERS" \
		"mpp:import_count"; then
		printf "rewrite counter defaults did not require the MPP import gauge to return to zero\n" >&2
		return 1
	fi
	if ! counter_list_has "$MPP_REQUIRED_ZERO_AFTER_COUNTERS" \
		"mpp:queued_job_count"; then
		printf "rewrite counter defaults did not require the MPP queue gauge to return to zero\n" >&2
		return 1
	fi
	if ! counter_list_has "$LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS" \
		"rga:import_count"; then
		printf "rewrite counter defaults did not require the RGA import gauge to return to zero\n" >&2
		return 1
	fi
	for counter in rga:shadow_head_active_count rga:shadow_tail_active_count '*:active'; do
		if ! counter_list_has "$LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS" "$counter"; then
			printf "rewrite counter defaults did not require librga idle gauge %s to return to zero\n" "$counter" >&2
			return 1
		fi
	done
	if [ "$LIBRGA_FORCE_RGA_USERPTR_IOMMU" = "1" ]; then
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
	if [ -z "$GSTREAMER_REQUIRED_POSITIVE_COUNTERS" ]; then
		printf "rewrite counter defaults did not require GStreamer counters\n" >&2
		return 1
	fi
	if ! counter_list_has "$GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS" \
		"mpp:import_count" ||
		! counter_list_has "$GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS" \
		"mpp:queued_job_count" ||
		! counter_list_has "$GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS" \
		"rga:import_count" ||
		! counter_list_has "$GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS" \
		"rga:shadow_head_active_count" ||
		! counter_list_has "$GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS" \
		"rga:shadow_tail_active_count"; then
		printf "rewrite counter defaults did not require GStreamer idle gauges to return to zero\n" >&2
		return 1
	fi
	if [ -z "$FFMPEG_REQUIRED_POSITIVE_COUNTERS" ]; then
		printf "rewrite counter defaults did not require FFmpeg counters\n" >&2
		return 1
	fi
	if ! counter_list_has "$FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS" \
		"mpp:import_count" ||
		! counter_list_has "$FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS" \
		"mpp:queued_job_count" ||
		! counter_list_has "$FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS" \
		"rga:import_count" ||
		! counter_list_has "$FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS" \
		"rga:shadow_head_active_count" ||
		! counter_list_has "$FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS" \
		"rga:shadow_tail_active_count"; then
		printf "rewrite counter defaults did not require FFmpeg idle gauges to return to zero\n" >&2
		return 1
	fi
	if [ "$RUN_RKMPPENC_SUITE" = "1" ] &&
		[ -z "$RKMPPENC_REQUIRED_POSITIVE_COUNTERS" ]; then
		printf "rewrite counter defaults did not require rkmppenc counters\n" >&2
		return 1
	fi
	if [ "$RUN_RKMPPENC_SUITE" = "1" ] &&
		{ ! counter_list_has "$RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS" \
			"mpp:import_count" ||
		  ! counter_list_has "$RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS" \
			"mpp:queued_job_count" ||
		  ! counter_list_has "$RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS" \
			"rga:import_count" ||
		  ! counter_list_has "$RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS" \
			"rga:shadow_head_active_count" ||
		  ! counter_list_has "$RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS" \
			"rga:shadow_tail_active_count"; }; then
		printf "rewrite counter defaults did not require rkmppenc idle gauges to return to zero\n" >&2
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
	if [ "$RUN_KUNIT_CHECK" = "1" ]; then
		run_step "kunit: require booted rewrite suites green" \
			env KUNIT_REPORT="$LOG_ROOT/$RUN_ID-kunit.tsv" \
			bash "$TEST_DIR/rewrite-kunit-log-check.sh"
	fi

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
			"$MPP_REQUIRED_POSITIVE_COUNTER_PREFIXES" \
			"$MPP_REQUIRED_ZERO_AFTER_COUNTERS"
	fi

	if [ "$RUN_LIBRGA_SUITE" = "1" ]; then
		run_step "rga: official librga suite" \
			env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			OUT="$LIBRGA_SUITE_OUT" \
			bash "$TEST_DIR/librga-suite.sh"
		run_counter_check "rga" "$LIBRGA_SUITE_OUT/summary.tsv" \
			"$LIBRGA_REQUIRED_POSITIVE_COUNTERS" \
			"$LIBRGA_REQUIRED_POSITIVE_COUNTER_PREFIXES" \
			"$LIBRGA_REQUIRED_ZERO_AFTER_COUNTERS"
	fi

	if [ "$RUN_GSTREAMER_SUITE" = "1" ]; then
		run_step "gstreamer: JeffyCN plugin suite" \
			env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			OUT="$GSTREAMER_SUITE_OUT" \
			bash "$TEST_DIR/gstreamer-suite.sh"
		run_counter_check "gstreamer" "$GSTREAMER_SUITE_OUT/summary.tsv" \
			"$GSTREAMER_REQUIRED_POSITIVE_COUNTERS" \
			"$GSTREAMER_REQUIRED_POSITIVE_COUNTER_PREFIXES" \
			"$GSTREAMER_REQUIRED_ZERO_AFTER_COUNTERS"
	fi

	if [ "$RUN_FFMPEG_SUITE" = "1" ]; then
		run_step "ffmpeg: rkmpp/rkrga CLI suite" \
			env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			OUT="$FFMPEG_SUITE_OUT" \
			bash "$TEST_DIR/ffmpeg-suite.sh"
		run_counter_check "ffmpeg" "$FFMPEG_SUITE_OUT/summary.tsv" \
			"$FFMPEG_REQUIRED_POSITIVE_COUNTERS" \
			"$FFMPEG_REQUIRED_POSITIVE_COUNTER_PREFIXES" \
			"$FFMPEG_REQUIRED_ZERO_AFTER_COUNTERS"
	fi

	if [ "$RUN_RKMPPENC_SUITE" = "1" ]; then
		run_step "rkmppenc: optional app-level MPP/RGA suite" \
			env PROFILE="$PROFILE" CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			OUT="$RKMPPENC_SUITE_OUT" \
			bash "$TEST_DIR/rkmppenc-suite.sh"
		run_counter_check "rkmppenc" "$RKMPPENC_SUITE_OUT/summary.tsv" \
			"$RKMPPENC_REQUIRED_POSITIVE_COUNTERS" \
			"$RKMPPENC_REQUIRED_POSITIVE_COUNTER_PREFIXES" \
			"$RKMPPENC_REQUIRED_ZERO_AFTER_COUNTERS"
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

	if [ "$RUN_RKMPPENC_SUITE" = "1" ]; then
		run_step "rkmppenc: compare latest suite summaries" \
			env BASELINE="$baseline" CANDIDATE="$candidate" \
			CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
			bash "$TEST_DIR/rkmppenc-suite-compare.sh"
	fi
}

run_validation()
{
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
		bash "$TEST_DIR/ioctl-fuzz-smoke.sh"

	run_step "rga: validate direct librga smoke build" \
		env LIBRGA_SMOKE_VALIDATE_BUILD=1 \
		bash "$TEST_DIR/librga-smoke.sh"

	run_optional_step "gstreamer: validate event harness build" \
		env GST_EVENT_HARNESS_VALIDATE_BUILD=1 \
		bash "$TEST_DIR/build-gstreamer-rockchip.sh"

	run_step "iommu: validate RGA scatter fuzzer build" \
		env IOMMU_FUZZ_VALIDATE_BUILD=1 \
		bash "$TEST_DIR/iommu-machinery-fuzz.sh"

	run_step "recovery: validate stress harness config" \
		env RECOVERY_VALIDATE_ONLY=1 \
		bash "$TEST_DIR/rewrite-recovery-stress.sh"

	if [ "$RUN_MPP_SUITE" = "1" ]; then
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
	fi

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

if [ "$VALIDATE_ONLY" = "1" ]; then
	run_validation
	printf "Conformance runner validation passed\n"
	exit 0
fi

run_profile_suites

if [ "$RUN_COMPARE" = "1" ]; then
	run_comparators
fi

if [ -n "$FAILED_STEPS" ]; then
	printf "Conformance profile '%s' completed with FAILED suites:%s\n" \
		"$PROFILE" "$FAILED_STEPS" >&2
	exit 1
fi

printf "Conformance profile '%s' completed\n" "$PROFILE"
