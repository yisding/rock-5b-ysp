#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: GPL-2.0-only
# Optional application-level rkmppenc conformance wrapper.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
# shellcheck source=debugfs-counters.sh disable=SC1091
source "$TEST_DIR/debugfs-counters.sh"

ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/build/rockchip-conformance"}
PROFILE=${PROFILE:-${1:-rewrite}}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-rkmppenc-suite"}
RKMPPENC=${RKMPPENC:-rkmppenc}
RKMPPENC_GENERATOR=${RKMPPENC_GENERATOR:-ffmpeg}
RKMPPENC_GENERATED_INPUT_CACHE=${RKMPPENC_GENERATED_INPUT_CACHE:-"$CONFORMANCE_ROOT/assets/rkmppenc-generated"}
RKMPPENC_GENERATE_INPUTS=${RKMPPENC_GENERATE_INPUTS:-1}
RKMPPENC_WIDTH=${RKMPPENC_WIDTH:-320}
RKMPPENC_HEIGHT=${RKMPPENC_HEIGHT:-180}
RKMPPENC_OUTPUT_WIDTH=${RKMPPENC_OUTPUT_WIDTH:-256}
RKMPPENC_OUTPUT_HEIGHT=${RKMPPENC_OUTPUT_HEIGHT:-144}
RKMPPENC_FPS=${RKMPPENC_FPS:-30}
RKMPPENC_FRAMES=${RKMPPENC_FRAMES:-30}
RKMPPENC_TIMEOUT=${RKMPPENC_TIMEOUT:-180}
RKMPPENC_VALIDATE_CASES=${RKMPPENC_VALIDATE_CASES:-0}
RKMPPENC_LD_LIBRARY_PATH=${RKMPPENC_LD_LIBRARY_PATH:-}

required_cases_default="
rkmppenc_check_mppinfo
rkmppenc_check_rgainfo
rkmppenc_y4m_h264_rga_resize
rkmppenc_y4m_hevc_rga_resize
rkmppenc_raw_h264_rga_resize
"

diagnostic_cases_default="
rkmppenc_avhw_h264_to_hevc_rga_resize
"

required_cases=${RKMPPENC_REQUIRED_CASES:-$required_cases_default}
diagnostic_cases=${RKMPPENC_DIAGNOSTIC_CASES:-$diagnostic_cases_default}
failed=0
summary="$OUT/summary.tsv"
artifact_summary="$OUT/artifacts.tsv"
CMD=()
CASE_ARTIFACT=
CASE_ARTIFACT_KIND=

resolve_binary()
{
	local candidate=$1
	local resolved

	if [ -z "$candidate" ]; then
		return 1
	fi
	if [ -x "$candidate" ]; then
		printf "%s\n" "$candidate"
		return 0
	fi
	resolved=$(command -v "$candidate" 2>/dev/null || true)
	if [ -n "$resolved" ] && [ -x "$resolved" ]; then
		printf "%s\n" "$resolved"
		return 0
	fi
	return 1
}

safe_token()
{
	printf "%s" "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

generated_input_path()
{
	local kind=$1
	local ext=$2

	printf "%s/rkmppenc-%s-%sx%s-%sframes-%sfps.%s" \
		"$RKMPPENC_GENERATED_INPUT_CACHE" "$kind" \
		"$RKMPPENC_WIDTH" "$RKMPPENC_HEIGHT" \
		"$RKMPPENC_FRAMES" "$(safe_token "$RKMPPENC_FPS")" "$ext"
}

run_generator()
{
	local label=$1
	local log="$OUT/generate-$label.log"
	shift

	timeout "$RKMPPENC_TIMEOUT" "$RKMPPENC_GENERATOR" -hide_banner -y \
		-loglevel warning "$@" > "$log" 2>&1
}

ensure_generated_y4m()
{
	local path

	path=$(generated_input_path y4m y4m)
	if [ "$RKMPPENC_GENERATE_INPUTS" != "1" ]; then
		printf "missing RKMPPENC_Y4M_INPUT and RKMPPENC_GENERATE_INPUTS=0\n" >&2
		return 3
	fi
	if ! resolve_binary "$RKMPPENC_GENERATOR" >/dev/null; then
		printf "missing generator binary: %s\n" "$RKMPPENC_GENERATOR" >&2
		return 3
	fi

	mkdir -p "$RKMPPENC_GENERATED_INPUT_CACHE"
	if [ ! -s "$path" ]; then
		run_generator y4m \
			-f lavfi \
			-i "testsrc2=size=${RKMPPENC_WIDTH}x${RKMPPENC_HEIGHT}:rate=${RKMPPENC_FPS}" \
			-frames:v "$RKMPPENC_FRAMES" \
			-pix_fmt yuv420p \
			-f yuv4mpegpipe \
			"$path"
	fi
	if [ ! -s "$path" ]; then
		printf "generated Y4M input is empty: %s\n" "$path" >&2
		return 3
	fi

	printf "%s" "$path"
}

ensure_generated_raw_nv12()
{
	local path

	path=$(generated_input_path nv12 nv12)
	if [ "$RKMPPENC_GENERATE_INPUTS" != "1" ]; then
		printf "missing RKMPPENC_RAW_NV12_INPUT and RKMPPENC_GENERATE_INPUTS=0\n" >&2
		return 3
	fi
	if ! resolve_binary "$RKMPPENC_GENERATOR" >/dev/null; then
		printf "missing generator binary: %s\n" "$RKMPPENC_GENERATOR" >&2
		return 3
	fi

	mkdir -p "$RKMPPENC_GENERATED_INPUT_CACHE"
	if [ ! -s "$path" ]; then
		run_generator raw-nv12 \
			-f lavfi \
			-i "testsrc2=size=${RKMPPENC_WIDTH}x${RKMPPENC_HEIGHT}:rate=${RKMPPENC_FPS}" \
			-frames:v "$RKMPPENC_FRAMES" \
			-pix_fmt nv12 \
			-f rawvideo \
			"$path"
	fi
	if [ ! -s "$path" ]; then
		printf "generated raw NV12 input is empty: %s\n" "$path" >&2
		return 3
	fi

	printf "%s" "$path"
}

ensure_generated_h264_mp4()
{
	local path

	path=$(generated_input_path h264 mp4)
	if [ "$RKMPPENC_GENERATE_INPUTS" != "1" ]; then
		printf "missing RKMPPENC_H264_INPUT and RKMPPENC_GENERATE_INPUTS=0\n" >&2
		return 3
	fi
	if ! resolve_binary "$RKMPPENC_GENERATOR" >/dev/null; then
		printf "missing generator binary: %s\n" "$RKMPPENC_GENERATOR" >&2
		return 3
	fi

	mkdir -p "$RKMPPENC_GENERATED_INPUT_CACHE"
	if [ ! -s "$path" ]; then
		run_generator h264-mp4 \
			-f lavfi \
			-i "testsrc2=size=${RKMPPENC_WIDTH}x${RKMPPENC_HEIGHT}:rate=${RKMPPENC_FPS}" \
			-frames:v "$RKMPPENC_FRAMES" \
			-c:v libx264 \
			-pix_fmt yuv420p \
			-movflags +faststart \
			-an \
			"$path"
	fi
	if [ ! -s "$path" ]; then
		printf "generated H.264 input is empty: %s\n" "$path" >&2
		return 3
	fi

	printf "%s" "$path"
}

case_output()
{
	local case_name=$1
	local ext=$2
	printf "%s/artifacts/%s.%s\n" "$OUT" "$case_name" "$ext"
}

build_resize_args()
{
	CMD+=(--frames "$RKMPPENC_FRAMES")
	CMD+=(--output-res "${RKMPPENC_OUTPUT_WIDTH}x${RKMPPENC_OUTPUT_HEIGHT}")
	CMD+=(--vpp-resize rga_bilinear)
}

build_y4m_case()
{
	local codec=$1
	local ext=$2
	local input
	local output

	input=${RKMPPENC_Y4M_INPUT:-}
	if [ -z "$input" ]; then
		input=$(ensure_generated_y4m) || return $?
	fi
	output=$(case_output "rkmppenc_y4m_${codec}_rga_resize" "$ext")
	CMD=("$RKMPPENC_BIN" --y4m -i "$input" --codec "$codec")
	build_resize_args
	CMD+=(--output "$output")
	CASE_ARTIFACT=$output
	CASE_ARTIFACT_KIND=encoded
}

build_raw_case()
{
	local input
	local output

	input=${RKMPPENC_RAW_NV12_INPUT:-}
	if [ -z "$input" ]; then
		input=$(ensure_generated_raw_nv12) || return $?
	fi
	output=$(case_output rkmppenc_raw_h264_rga_resize h264)
	CMD=("$RKMPPENC_BIN" --raw -i "$input" --codec h264)
	CMD+=(--input-res "${RKMPPENC_WIDTH}x${RKMPPENC_HEIGHT}")
	CMD+=(--fps "$RKMPPENC_FPS" --input-csp nv12)
	build_resize_args
	CMD+=(--output "$output")
	CASE_ARTIFACT=$output
	CASE_ARTIFACT_KIND=encoded
}

build_avhw_case()
{
	local input
	local output

	input=${RKMPPENC_H264_INPUT:-}
	if [ -z "$input" ]; then
		input=$(ensure_generated_h264_mp4) || return $?
	fi
	output=$(case_output rkmppenc_avhw_h264_to_hevc_rga_resize h265)
	CMD=("$RKMPPENC_BIN" --avhw -i "$input" --codec hevc)
	build_resize_args
	CMD+=(--output "$output")
	CASE_ARTIFACT=$output
	CASE_ARTIFACT_KIND=encoded
}

build_case()
{
	local case_name=$1

	CMD=()
	CASE_ARTIFACT=
	CASE_ARTIFACT_KIND=

	case "$case_name" in
	rkmppenc_check_mppinfo)
		CMD=("$RKMPPENC_BIN" --check-mppinfo)
		;;
	rkmppenc_check_rgainfo)
		CMD=("$RKMPPENC_BIN" --check-rgainfo)
		;;
	rkmppenc_y4m_h264_rga_resize)
		build_y4m_case h264 h264
		;;
	rkmppenc_y4m_hevc_rga_resize)
		build_y4m_case hevc h265
		;;
	rkmppenc_raw_h264_rga_resize)
		build_raw_case
		;;
	rkmppenc_avhw_h264_to_hevc_rga_resize)
		build_avhw_case
		;;
	*)
		printf "unknown rkmppenc case: %s\n" "$case_name" >&2
		return 3
		;;
	esac
}

case_known()
{
	case "$1" in
	rkmppenc_check_mppinfo | \
	rkmppenc_check_rgainfo | \
	rkmppenc_y4m_h264_rga_resize | \
	rkmppenc_y4m_hevc_rga_resize | \
	rkmppenc_raw_h264_rga_resize | \
	rkmppenc_avhw_h264_to_hevc_rga_resize)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

validate_case_names()
{
	local class=$1
	local case_name=$2

	if [ -z "$case_name" ]; then
		return 0
	fi
	if case_known "$case_name"; then
		printf "valid\t%s\t%s\n" "$class" "$case_name"
		return 0
	fi

	printf "invalid\t%s\t%s\n" "$class" "$case_name" >&2
	return 1
}

validate_cases()
{
	local case_name
	local total=0
	local validation_failed=0

	for case_name in $required_cases; do
		total=$((total + 1))
		if ! validate_case_names required "$case_name"; then
			validation_failed=1
		fi
	done

	for case_name in $diagnostic_cases; do
		total=$((total + 1))
		if ! validate_case_names diagnostic "$case_name"; then
			validation_failed=1
		fi
	done

	if [ "$validation_failed" -ne 0 ]; then
		return 1
	fi

	printf "validated %s rkmppenc cases\n" "$total"
}

record_artifact()
{
	local class=$1
	local case_name=$2
	local kind=$3
	local path=$4
	local bytes
	local sha

	[ -f "$path" ] || return 1
	bytes=$(stat -c%s "$path")
	[ "$bytes" -gt 0 ] || return 1
	sha=$(sha256sum "$path" | awk '{ print $1 }')
	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$PROFILE" "$class" "$case_name" "$kind" "$bytes" "$sha" "$path" \
		>> "$artifact_summary"
}

run_case()
{
	local class=$1
	local case_name=$2
	local log="$OUT/$case_name.log"
	local status_file="$OUT/$case_name.status"
	local start
	local end
	local elapsed
	local status
	local result

	[ -n "$case_name" ] || return

	if ! build_case "$case_name"; then
		printf "build-failed\n" > "$status_file"
		printf "%s\t%s\t%s\t3\t0\tbuild-failed\n" \
			"$PROFILE" "$class" "$case_name" >> "$summary"
		[ "$class" = "required" ] && failed=1
		return
	fi

	printf "command:" > "$log"
	printf " %q" "${CMD[@]}" >> "$log"
	printf "\n\n" >> "$log"

	start=$(suite_now_ns)
	set +e
	if [ -n "$RKMPPENC_LD_LIBRARY_PATH" ]; then
		LD_LIBRARY_PATH="$RKMPPENC_LD_LIBRARY_PATH:${LD_LIBRARY_PATH:-}" \
			timeout "$RKMPPENC_TIMEOUT" "${CMD[@]}" >> "$log" 2>&1
	else
		timeout "$RKMPPENC_TIMEOUT" "${CMD[@]}" >> "$log" 2>&1
	fi
	status=$?
	set -e
	end=$(suite_now_ns)
	elapsed=$(suite_elapsed_s "$start" "$end")

	printf "%s\n" "$status" > "$status_file"
	if [ "$status" -eq 0 ]; then
		if [ -n "$CASE_ARTIFACT" ]; then
			if ! record_artifact "$class" "$case_name" \
				"$CASE_ARTIFACT_KIND" "$CASE_ARTIFACT"; then
				printf "artifact missing or empty: %s\n" "$CASE_ARTIFACT" >> "$log"
				if [ "$class" = "required" ]; then
					result=fail
					failed=1
				else
					result=diagnostic-fail
				fi
			else
				result=pass
			fi
		else
			result=pass
		fi
	elif [ "$class" = "diagnostic" ]; then
		result=diagnostic-fail
	else
		result=fail
		failed=1
	fi

	printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$PROFILE" "$class" "$case_name" "$status" "$elapsed" "$result" \
		>> "$summary"
}

if [ "$RKMPPENC_VALIDATE_CASES" = "1" ]; then
	validate_cases
	exit $?
fi

if [ ! -e /dev/mpp_service ] || [ ! -e /dev/rga ]; then
	echo "SKIP: /dev/mpp_service and /dev/rga are required on this boot"
	exit 77
fi

if ! RKMPPENC_BIN=$(resolve_binary "$RKMPPENC"); then
	printf "Missing rkmppenc binary: %s\n" "$RKMPPENC" >&2
	exit 2
fi
export RKMPPENC_BIN

mkdir -p "$OUT/artifacts" "$RKMPPENC_GENERATED_INPUT_CACHE"
printf "profile\tclass\tcase\tstatus\telapsed_s\tresult\n" > "$summary"
printf "profile\tclass\tcase\tkind\tbytes\tsha256\tpath\n" > "$artifact_summary"

if ! suite_dmesg_start "$OUT"; then
	echo "FAIL: dmesg is required but unreadable" >&2
	exit 1
fi

debugfs_counter_snapshot "$OUT/debugfs-counters-before.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite

for case_name in $required_cases; do
	run_case required "$case_name"
done

for case_name in $diagnostic_cases; do
	run_case diagnostic "$case_name"
done

debugfs_counter_snapshot "$OUT/debugfs-counters-after.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite
debugfs_counter_delta "$OUT/debugfs-counters-before.tsv" \
	"$OUT/debugfs-counters-after.tsv" \
	"$OUT/debugfs-counters-delta.tsv"
if ! suite_dmesg_finish "$OUT"; then
	echo "FAIL: new fatal kernel-log signature or unavailable required dmesg; see $OUT/dmesg-scan.tsv" >&2
	failed=1
fi
tail -n 500 "$OUT/dmesg-after.txt" > "$OUT/dmesg-tail.txt" 2>/dev/null || true
suite_reown_to_invoking_user "$OUT" "$RKMPPENC_GENERATED_INPUT_CACHE"

echo "$OUT"

if [ "$failed" -ne 0 ]; then
	echo "FAIL: one or more required rkmppenc cases failed; see $summary" >&2
	exit 1
fi

exit 0
