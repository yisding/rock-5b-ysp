#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
# shellcheck source=debugfs-counters.sh disable=SC1091
source "$TEST_DIR/debugfs-counters.sh"
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
PROFILE=${PROFILE:-${1:-rewrite}}
MPP_BIN_DIR=${MPP_BIN_DIR:-"$CONFORMANCE_ROOT/out/mpp/bin"}
MPP_LIBDIR=${MPP_LIBDIR:-"$CONFORMANCE_ROOT/out/mpp/lib"}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-mpp-suite"}
MPP_GENERATED_INPUT_CACHE=${MPP_GENERATED_INPUT_CACHE:-"$CONFORMANCE_ROOT/assets/mpp-generated"}
MPP_TIMEOUT=${MPP_TIMEOUT:-180}
MPP_DEC_FRAMES=${MPP_DEC_FRAMES:-120}
MPP_ENC_FRAMES=${MPP_ENC_FRAMES:-120}
MPP_INSTANCES=${MPP_INSTANCES:-4}
MPP_DUMP_OUTPUTS=${MPP_DUMP_OUTPUTS:-0}
MPP_CAPTURE_ARTIFACTS=${MPP_CAPTURE_ARTIFACTS:-1}
MPP_ENC_FORMAT=${MPP_ENC_FORMAT:-${MPP_NV12_FORMAT:-0}}
MPP_GENERATE_VP9_INPUT=${MPP_GENERATE_VP9_INPUT:-1}
MPP_VP9_GENERATED_WIDTH=${MPP_VP9_GENERATED_WIDTH:-320}
MPP_VP9_GENERATED_HEIGHT=${MPP_VP9_GENERATED_HEIGHT:-240}
MPP_VP9_GENERATED_FPS=${MPP_VP9_GENERATED_FPS:-30}
MPP_VALIDATE_CASES=${MPP_VALIDATE_CASES:-0}

MPP_CODING_AVC=7
MPP_CODING_VP9=10
MPP_CODING_HEVC=16777220

required_cases_default="mpp_info_test"
if [ -z "${MPP_REQUIRED_CASES+x}" ]; then
	if [ -n "${MPP_DEC_INPUT:-}" ]; then
		required_cases_default="$required_cases_default mpi_dec_custom"
	fi
	if [ -n "${MPP_ENC_INPUT:-${MPP_NV12_INPUT:-}}" ]; then
		required_cases_default="$required_cases_default mpi_enc_custom"
	fi
fi

required_cases=${MPP_REQUIRED_CASES:-$required_cases_default}
diagnostic_cases=${MPP_DIAGNOSTIC_CASES:-}
failed=0

summary="$OUT/summary.tsv"
artifact_summary="$OUT/artifacts.tsv"
CMD=()
BUILD_ERROR=
CURRENT_CLASS=
CURRENT_CASE=
CASE_ARTIFACT_KINDS=()
CASE_ARTIFACT_PATHS=()

get_var()
{
	local name=$1
	printf "%s" "${!name:-}"
}

missing_var()
{
	local name=$1

	BUILD_ERROR="missing required env var $name"
	return 3
}

require_var()
{
	local name=$1
	local value

	value=$(get_var "$name")
	if [ -z "$value" ]; then
		missing_var "$name"
		return 3
	fi

	printf "%s" "$value"
}

safe_token()
{
	printf "%s" "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

register_artifact()
{
	local kind=$1
	local path=$2

	if [ "$MPP_CAPTURE_ARTIFACTS" != "1" ] || [ -z "$path" ]; then
		return
	fi

	CASE_ARTIFACT_KINDS+=("$kind")
	CASE_ARTIFACT_PATHS+=("$path")
}

generated_vp9_input_path()
{
	local frames=$1
	local fps

	fps=$(safe_token "$MPP_VP9_GENERATED_FPS")
	printf "%s/vp9-%sx%s-%sframes-%sfps.ivf" \
		"$MPP_GENERATED_INPUT_CACHE" \
		"$MPP_VP9_GENERATED_WIDTH" "$MPP_VP9_GENERATED_HEIGHT" \
		"$frames" "$fps"
}

ensure_generated_vp9_input()
{
	local path
	local frames=$MPP_DEC_FRAMES

	if [ "$MPP_GENERATE_VP9_INPUT" != "1" ]; then
		missing_var MPP_VP9_INPUT
		return 3
	fi

	if ! command -v ffmpeg >/dev/null 2>&1; then
		BUILD_ERROR="missing ffmpeg to generate MPP_VP9_INPUT"
		return 3
	fi

	mkdir -p "$MPP_GENERATED_INPUT_CACHE"
	path=$(generated_vp9_input_path "$frames")
	if [ ! -s "$path" ]; then
		if ! ffmpeg -hide_banner -loglevel error \
			-f lavfi \
			-i "testsrc2=size=${MPP_VP9_GENERATED_WIDTH}x${MPP_VP9_GENERATED_HEIGHT}:rate=${MPP_VP9_GENERATED_FPS}" \
			-frames:v "$frames" \
			-c:v libvpx-vp9 \
			-pix_fmt yuv420p \
			-f ivf \
			"$path"; then
			BUILD_ERROR="failed to generate MPP_VP9_INPUT at $path"
			return 3
		fi
	fi
	if [ ! -s "$path" ]; then
		BUILD_ERROR="generated MPP_VP9_INPUT is empty at $path"
		return 3
	fi

	printf "%s" "$path"
}

resolve_dec_input()
{
	local name=$1
	local value

	value=$(get_var "$name")
	if [ -n "$value" ]; then
		printf "%s" "$value"
		return 0
	fi

	if [ "$name" = "MPP_VP9_INPUT" ]; then
		ensure_generated_vp9_input
		return $?
	fi

	missing_var "$name"
	return 3
}

require_first_var()
{
	local first=$1
	local second=$2
	local value

	value=$(get_var "$first")
	if [ -n "$value" ]; then
		printf "%s" "$value"
		return 0
	fi

	value=$(get_var "$second")
	if [ -n "$value" ]; then
		printf "%s" "$value"
		return 0
	fi

	BUILD_ERROR="missing required env var $first or $second"
	return 3
}

append_if_var_set()
{
	local flag=$1
	local name=$2
	local value

	value=$(get_var "$name")
	if [ -n "$value" ]; then
		CMD+=("$flag" "$value")
	fi
}

maybe_dec_output()
{
	local case_name=$1
	local explicit=$2
	local output=

	if [ -n "$explicit" ]; then
		output=$explicit
	elif [ "$MPP_DUMP_OUTPUTS" = "1" ]; then
		output="$OUT/$case_name.yuv"
	fi

	if [ -n "$output" ]; then
		CMD+=(-o "$output")
		register_artifact decoded "$output"
	fi
}

build_dec_case()
{
	local exe=$1
	local case_name=$2
	local input_var=$3
	local type=$4
	local width_var=$5
	local height_var=$6
	local generated_vp9=0
	local input
	local output

	if [ "$input_var" = "MPP_VP9_INPUT" ] &&
		[ -z "$(get_var "$input_var")" ] &&
		[ "$MPP_GENERATE_VP9_INPUT" = "1" ]; then
		generated_vp9=1
	fi

	input=$(resolve_dec_input "$input_var") || return $?
	output=$(get_var "${case_name}_OUTPUT")

	CMD=("$MPP_BIN_DIR/$exe" -i "$input" -t "$type" -n "$MPP_DEC_FRAMES" -v f)
	if [ "$generated_vp9" = "1" ]; then
		CMD+=(-w "$MPP_VP9_GENERATED_WIDTH" -h "$MPP_VP9_GENERATED_HEIGHT")
	else
		append_if_var_set -w "$width_var"
		append_if_var_set -h "$height_var"
	fi
	append_if_var_set -f MPP_DEC_FORMAT
	if [ "$exe" = "mpi_dec_multi_test" ]; then
		CMD+=(-s "$MPP_INSTANCES")
	fi
	maybe_dec_output "$case_name" "$output"
}

build_dec_custom_case()
{
	local exe=$1
	local case_name=$2
	local input
	local type

	input=$(require_var MPP_DEC_INPUT) || return $?
	type=$(require_var MPP_DEC_TYPE) || return $?

	CMD=("$MPP_BIN_DIR/$exe" -i "$input" -t "$type" -n "$MPP_DEC_FRAMES" -v f)
	append_if_var_set -w MPP_DEC_WIDTH
	append_if_var_set -h MPP_DEC_HEIGHT
	append_if_var_set -f MPP_DEC_FORMAT
	if [ "$exe" = "mpi_dec_multi_test" ]; then
		CMD+=(-s "$MPP_INSTANCES")
	fi
	maybe_dec_output "$case_name" "${MPP_DEC_OUTPUT:-}"
}

build_enc_case()
{
	local exe=$1
	local case_name=$2
	local type=$3
	local suffix=$4
	local input
	local width
	local height
	local output

	input=$(require_first_var MPP_ENC_INPUT MPP_NV12_INPUT) || return $?
	width=$(require_first_var MPP_ENC_WIDTH MPP_NV12_WIDTH) || return $?
	height=$(require_first_var MPP_ENC_HEIGHT MPP_NV12_HEIGHT) || return $?
	output=$(get_var "${case_name}_OUTPUT")
	if [ -z "$output" ]; then
		output="$OUT/$case_name.$suffix"
	fi

	CMD=(
		"$MPP_BIN_DIR/$exe"
		-i "$input"
		-w "$width"
		-h "$height"
		-f "$MPP_ENC_FORMAT"
		-t "$type"
		-n "$MPP_ENC_FRAMES"
		-v f
		-o "$output"
	)
	register_artifact encoded "$output"
	if [ "$exe" = "mpi_enc_mt_test" ]; then
		CMD+=(-s "$MPP_INSTANCES")
	fi
	append_if_var_set -hstride MPP_ENC_HSTRIDE
	append_if_var_set -vstride MPP_ENC_VSTRIDE
	append_if_var_set -rc MPP_ENC_RC_MODE
	append_if_var_set -bps MPP_ENC_BPS
	append_if_var_set -fps MPP_ENC_FPS
}

build_enc_custom_case()
{
	local exe=$1
	local case_name=$2
	local input
	local width
	local height
	local type
	local output

	input=$(require_first_var MPP_ENC_INPUT MPP_NV12_INPUT) || return $?
	width=$(require_first_var MPP_ENC_WIDTH MPP_NV12_WIDTH) || return $?
	height=$(require_first_var MPP_ENC_HEIGHT MPP_NV12_HEIGHT) || return $?
	type=$(require_var MPP_ENC_TYPE) || return $?
	output=${MPP_ENC_OUTPUT:-"$OUT/$case_name.bin"}

	CMD=(
		"$MPP_BIN_DIR/$exe"
		-i "$input"
		-w "$width"
		-h "$height"
		-f "$MPP_ENC_FORMAT"
		-t "$type"
		-n "$MPP_ENC_FRAMES"
		-v f
		-o "$output"
	)
	register_artifact encoded "$output"
	if [ "$exe" = "mpi_enc_mt_test" ]; then
		CMD+=(-s "$MPP_INSTANCES")
	fi
	append_if_var_set -hstride MPP_ENC_HSTRIDE
	append_if_var_set -vstride MPP_ENC_VSTRIDE
	append_if_var_set -rc MPP_ENC_RC_MODE
	append_if_var_set -bps MPP_ENC_BPS
	append_if_var_set -fps MPP_ENC_FPS
}

build_rc2_case()
{
	local case_name=$1
	local input_var=$2
	local type=$3
	local suffix=$4
	local input

	input=$(require_var "$input_var") || return $?
	CMD=(
		"$MPP_BIN_DIR/mpi_rc2_test"
		-i "$input"
		-tsrc "$type"
		-t "$type"
		-n "$MPP_ENC_FRAMES"
		-v f
		-o "$OUT/$case_name.$suffix"
	)
	register_artifact encoded "$OUT/$case_name.$suffix"
	append_if_var_set -rc MPP_ENC_RC_MODE
	append_if_var_set -bps MPP_ENC_BPS
	append_if_var_set -fps MPP_ENC_FPS
}

build_rc2_custom_case()
{
	local type

	require_var MPP_DEC_INPUT >/dev/null || return $?
	type=$(require_var MPP_DEC_TYPE) || return $?
	CMD=(
		"$MPP_BIN_DIR/mpi_rc2_test"
		-i "$MPP_DEC_INPUT"
		-tsrc "$type"
		-t "$type"
		-n "$MPP_ENC_FRAMES"
		-v f
		-o "$OUT/mpi_rc2_custom.bin"
	)
	register_artifact encoded "$OUT/mpi_rc2_custom.bin"
	append_if_var_set -rc MPP_ENC_RC_MODE
	append_if_var_set -bps MPP_ENC_BPS
	append_if_var_set -fps MPP_ENC_FPS
}

build_vpu_api_dec_case()
{
	local case_name=$1
	local input_var=$2
	local coding=$3
	local input
	local output

	input=$(require_var "$input_var") || return $?
	output=$(get_var "${case_name}_OUTPUT")
	if [ -z "$output" ]; then
		output="$OUT/$case_name.yuv"
	fi

	CMD=(
		"$MPP_BIN_DIR/vpu_api_test"
		-i "$input"
		-o "$output"
		-t 0
		-coding "$coding"
		-vframes "$MPP_DEC_FRAMES"
	)
	register_artifact decoded "$output"
}

build_vpu_api_dec_custom_case()
{
	local type

	require_var MPP_DEC_INPUT >/dev/null || return $?
	type=$(require_var MPP_DEC_TYPE) || return $?
	CMD=(
		"$MPP_BIN_DIR/vpu_api_test"
		-i "$MPP_DEC_INPUT"
		-o "${MPP_DEC_OUTPUT:-"$OUT/vpu_api_dec_custom.yuv"}"
		-t 0
		-coding "$type"
		-vframes "$MPP_DEC_FRAMES"
	)
	register_artifact decoded "${MPP_DEC_OUTPUT:-"$OUT/vpu_api_dec_custom.yuv"}"
}

build_case_command()
{
	local case_name=$1

	BUILD_ERROR=
	CMD=()

	case "$case_name" in
	mpp_info_test)
		CMD=("$MPP_BIN_DIR/mpp_info_test")
		;;
	mpi_dec_h264)
		build_dec_case mpi_dec_test "$case_name" MPP_H264_INPUT "$MPP_CODING_AVC" MPP_H264_WIDTH MPP_H264_HEIGHT
		;;
	mpi_dec_h265)
		build_dec_case mpi_dec_test "$case_name" MPP_H265_INPUT "$MPP_CODING_HEVC" MPP_H265_WIDTH MPP_H265_HEIGHT
		;;
	mpi_dec_vp9)
		build_dec_case mpi_dec_test "$case_name" MPP_VP9_INPUT "$MPP_CODING_VP9" MPP_VP9_WIDTH MPP_VP9_HEIGHT
		;;
	mpi_dec_custom)
		build_dec_custom_case mpi_dec_test "$case_name"
		;;
	mpi_dec_mt_h264)
		build_dec_case mpi_dec_mt_test "$case_name" MPP_H264_INPUT "$MPP_CODING_AVC" MPP_H264_WIDTH MPP_H264_HEIGHT
		;;
	mpi_dec_mt_h265)
		build_dec_case mpi_dec_mt_test "$case_name" MPP_H265_INPUT "$MPP_CODING_HEVC" MPP_H265_WIDTH MPP_H265_HEIGHT
		;;
	mpi_dec_mt_vp9)
		build_dec_case mpi_dec_mt_test "$case_name" MPP_VP9_INPUT "$MPP_CODING_VP9" MPP_VP9_WIDTH MPP_VP9_HEIGHT
		;;
	mpi_dec_mt_custom)
		build_dec_custom_case mpi_dec_mt_test "$case_name"
		;;
	mpi_dec_multi_h264)
		build_dec_case mpi_dec_multi_test "$case_name" MPP_H264_INPUT "$MPP_CODING_AVC" MPP_H264_WIDTH MPP_H264_HEIGHT
		;;
	mpi_dec_multi_h265)
		build_dec_case mpi_dec_multi_test "$case_name" MPP_H265_INPUT "$MPP_CODING_HEVC" MPP_H265_WIDTH MPP_H265_HEIGHT
		;;
	mpi_dec_multi_vp9)
		build_dec_case mpi_dec_multi_test "$case_name" MPP_VP9_INPUT "$MPP_CODING_VP9" MPP_VP9_WIDTH MPP_VP9_HEIGHT
		;;
	mpi_dec_multi_custom)
		build_dec_custom_case mpi_dec_multi_test "$case_name"
		;;
	mpi_enc_h264)
		build_enc_case mpi_enc_test "$case_name" "$MPP_CODING_AVC" h264
		;;
	mpi_enc_h265)
		build_enc_case mpi_enc_test "$case_name" "$MPP_CODING_HEVC" h265
		;;
	mpi_enc_custom)
		build_enc_custom_case mpi_enc_test "$case_name"
		;;
	mpi_enc_mt_h264)
		build_enc_case mpi_enc_mt_test "$case_name" "$MPP_CODING_AVC" h264
		;;
	mpi_enc_mt_h265)
		build_enc_case mpi_enc_mt_test "$case_name" "$MPP_CODING_HEVC" h265
		;;
	mpi_enc_mt_custom)
		build_enc_custom_case mpi_enc_mt_test "$case_name"
		;;
	mpi_rc2_h264)
		build_rc2_case "$case_name" MPP_H264_INPUT "$MPP_CODING_AVC" h264
		;;
	mpi_rc2_h265)
		build_rc2_case "$case_name" MPP_H265_INPUT "$MPP_CODING_HEVC" h265
		;;
	mpi_rc2_custom)
		build_rc2_custom_case
		;;
	vpu_api_dec_h264)
		build_vpu_api_dec_case "$case_name" MPP_H264_INPUT "$MPP_CODING_AVC"
		;;
	vpu_api_dec_h265)
		build_vpu_api_dec_case "$case_name" MPP_H265_INPUT "$MPP_CODING_HEVC"
		;;
	vpu_api_dec_custom)
		build_vpu_api_dec_custom_case
		;;
	*)
		BUILD_ERROR="unknown case $case_name"
		return 4
		;;
	esac
}

snapshot_mpp_state()
{
	local label=$1
	local target="$OUT/mpp-state-$label.txt"
	local path

	: > "$target"
	for path in /proc/mpp_service /sys/kernel/debug/rk_mpp_rewrite /sys/kernel/debug/mpp_service; do
		if [ -f "$path" ]; then
			{
				printf "== %s ==\n" "$path"
				cat "$path" 2>/dev/null || true
			} >> "$target" 2>/dev/null || true
		elif [ -d "$path" ]; then
			{
				printf "== %s ==\n" "$path"
				find "$path" -maxdepth 2 -type f -print | sort |
					while IFS= read -r file; do
						printf -- "-- %s --\n" "$file"
						cat "$file" 2>/dev/null || true
					done
			} >> "$target" 2>/dev/null || true
		fi
	done
}

record_summary()
{
	local class=$1
	local case_name=$2
	local status=$3
	local elapsed=$4
	local result=$5

	printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$PROFILE" "$class" "$case_name" "$status" "$elapsed" "$result" \
		>> "$summary"
}

record_case_artifacts()
{
	local idx
	local kind
	local path
	local bytes
	local sha

	for idx in "${!CASE_ARTIFACT_PATHS[@]}"; do
		kind=${CASE_ARTIFACT_KINDS[$idx]}
		path=${CASE_ARTIFACT_PATHS[$idx]}
		if [ -f "$path" ]; then
			bytes=$(wc -c < "$path" | tr -d '[:space:]')
			sha=$(sha256sum "$path" | awk '{ print $1 }')
		else
			bytes=missing
			sha=missing
		fi

		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"$PROFILE" "$CURRENT_CLASS" "$CURRENT_CASE" "$kind" \
			"$bytes" "$sha" "$path" >> "$artifact_summary"
	done
}

write_command_file()
{
	local target=$1
	local arg

	: > "$target"
	for arg in "${CMD[@]}"; do
		printf "%q " "$arg" >> "$target"
	done
	printf "\n" >> "$target"
}

run_case()
{
	local class=$1
	local case_name=$2
	local log="$OUT/$case_name.log"
	local status_file="$OUT/$case_name.status"
	local command_file="$OUT/$case_name.cmd"
	local start
	local end
	local elapsed
	local status
	local result
	local build_status

	CURRENT_CLASS=$class
	CURRENT_CASE=$case_name
	CASE_ARTIFACT_KINDS=()
	CASE_ARTIFACT_PATHS=()

	if [ -z "$case_name" ]; then
		return
	fi

	set +e
	build_case_command "$case_name"
	build_status=$?
	set -e
	if [ "$build_status" -ne 0 ]; then
		printf "%s\n" "$BUILD_ERROR" > "$log"
		printf "%s\n" "$BUILD_ERROR" > "$status_file"
		if [ "$build_status" -eq 3 ]; then
			status=missing-env
			result=missing-env
		else
			status=unknown
			result=unknown
		fi
		record_summary "$class" "$case_name" "$status" 0 "$result"
		if [ "$class" = "required" ]; then
			failed=1
		fi
		return
	fi

	if [ ! -x "${CMD[0]}" ]; then
		printf "missing\n" > "$status_file"
		printf "missing executable: %s\n" "${CMD[0]}" > "$log"
		record_summary "$class" "$case_name" missing 0 missing
		if [ "$class" = "required" ]; then
			failed=1
		fi
		return
	fi

	write_command_file "$command_file"
	start=$(suite_now_ns)
	set +e
	if [ "$MPP_TIMEOUT" = "0" ]; then
		"${CMD[@]}" > "$log" 2>&1
	else
		timeout "$MPP_TIMEOUT" "${CMD[@]}" > "$log" 2>&1
	fi
	status=$?
	set -e
	end=$(suite_now_ns)
	elapsed=$(suite_elapsed_s "$start" "$end")

	printf "%s\n" "$status" > "$status_file"
	if [ "$status" -eq 0 ]; then
		result=pass
		record_case_artifacts
	elif [ "$status" -eq 124 ]; then
		result=timeout
		if [ "$class" = "required" ]; then
			failed=1
		fi
	elif [ "$class" = "diagnostic" ]; then
		result=diagnostic-fail
	else
		result=fail
		failed=1
	fi

	record_summary "$class" "$case_name" "$status" "$elapsed" "$result"
}

validate_case_build()
{
	local class=$1
	local case_name=$2
	local build_status
	local command

	if [ -z "$case_name" ]; then
		return 0
	fi

	CURRENT_CLASS=$class
	CURRENT_CASE=$case_name
	CASE_ARTIFACT_KINDS=()
	CASE_ARTIFACT_PATHS=()

	set +e
	build_case_command "$case_name"
	build_status=$?
	set -e
	if [ "$build_status" -ne 0 ]; then
		printf "invalid\t%s\t%s\t%s\n" \
			"$class" "$case_name" "${BUILD_ERROR:-build failed}" >&2
		return 1
	fi

	command=${CMD[0]:-}
	command=${command##*/}
	printf "valid\t%s\t%s\t%s\n" "$class" "$case_name" "$command"
}

validate_case_builders()
{
	local case_name
	local total=0
	local errors=0

	for case_name in $required_cases; do
		if ! validate_case_build required "$case_name"; then
			errors=$((errors + 1))
		fi
		total=$((total + 1))
	done

	for case_name in $diagnostic_cases; do
		if ! validate_case_build diagnostic "$case_name"; then
			errors=$((errors + 1))
		fi
		total=$((total + 1))
	done

	if [ "$errors" -ne 0 ]; then
		printf "FAIL: %s MPP case builder(s) failed validation\n" "$errors" >&2
		return 1
	fi

	printf "validated %s MPP case builders\n" "$total"
}

if [ "$MPP_VALIDATE_CASES" = "1" ]; then
	validate_case_builders
	exit $?
fi

if [ ! -e /dev/mpp_service ]; then
	echo "SKIP: /dev/mpp_service is absent on this boot"
	exit 77
fi

if [ ! -d "$MPP_BIN_DIR" ]; then
	echo "Missing $MPP_BIN_DIR. Run ../rockchip-conformance/scripts/build-mpp.sh first." >&2
	exit 2
fi

mkdir -p "$OUT"
printf "profile\tclass\tcase\tstatus\telapsed_s\tresult\n" > "$summary"
printf "profile\tclass\tcase\tkind\tbytes\tsha256\tpath\n" > "$artifact_summary"

export LD_LIBRARY_PATH="$MPP_LIBDIR:${LD_LIBRARY_PATH:-}"

snapshot_mpp_state before
debugfs_counter_snapshot "$OUT/debugfs-counters-before.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite

for case_name in $required_cases; do
	run_case required "$case_name"
done

for case_name in $diagnostic_cases; do
	run_case diagnostic "$case_name"
done

snapshot_mpp_state after
debugfs_counter_snapshot "$OUT/debugfs-counters-after.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite
debugfs_counter_delta "$OUT/debugfs-counters-before.tsv" \
	"$OUT/debugfs-counters-after.tsv" \
	"$OUT/debugfs-counters-delta.tsv"
dmesg | tail -n 500 > "$OUT/dmesg-tail.txt" 2>/dev/null || true

echo "$OUT"

if [ "$failed" -ne 0 ]; then
	echo "FAIL: one or more required MPP cases failed; see $summary" >&2
	exit 1
fi

exit 0
