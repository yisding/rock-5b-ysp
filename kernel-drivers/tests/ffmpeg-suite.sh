#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Yi Ding
# SPDX-License-Identifier: LGPL-2.1-or-later
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
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-ffmpeg-suite"}
STAGE=${STAGE:-"$ROCK5B_WORKSPACE/build/kernel/rock5b-kernel-build/ffmpeg-stack"}
FFMPEG_GENERATOR=${FFMPEG_GENERATOR:-ffmpeg}
FFMPEG_GENERATED_INPUT_CACHE=${FFMPEG_GENERATED_INPUT_CACHE:-"$CONFORMANCE_ROOT/assets/ffmpeg-generated"}
FFMPEG_GENERATE_INPUTS=${FFMPEG_GENERATE_INPUTS:-1}
FFMPEG_WIDTH=${FFMPEG_WIDTH:-1920}
FFMPEG_HEIGHT=${FFMPEG_HEIGHT:-1080}
FFMPEG_FPS=${FFMPEG_FPS:-30}
FFMPEG_DURATION=${FFMPEG_DURATION:-2}
FFMPEG_TIMEOUT=${FFMPEG_TIMEOUT:-180}
FFMPEG_VALIDATE_CASES=${FFMPEG_VALIDATE_CASES:-0}
FFMPEG_REQUIRE_AV1=${FFMPEG_REQUIRE_AV1:-0}
FFMPEG_RUN_4K=${FFMPEG_RUN_4K:-0}
FFMPEG_RUN_8K=${FFMPEG_RUN_8K:-0}
FFMPEG_RUN_STRESS=${FFMPEG_RUN_STRESS:-0}
FFMPEG_SOAK_SECONDS=${FFMPEG_SOAK_SECONDS:-1800}
FFMPEG_STRESS_LOOPS=${FFMPEG_STRESS_LOOPS:-100}
FFMPEG_PSNR_THRESHOLD=${FFMPEG_PSNR_THRESHOLD:-35}
# Installed MPP/librga are the conformance default. "auto" and "staged" remain
# available for an explicit comparison with STAGE/FFMPEG_STAGED_LD_LIBRARY_PATH.
FFMPEG_RUNTIME_MODES=${FFMPEG_RUNTIME_MODES:-system}
FFMPEG_REQUIRE_STAGED_RUNTIME=${FFMPEG_REQUIRE_STAGED_RUNTIME:-0}
FFMPEG_EXPECT_ENCODER_DEVICE_REGEX=${FFMPEG_EXPECT_ENCODER_DEVICE_REGEX:-RKVENC|VEPU|H265E|H264E|AVCENC|HEVCENC}
FFMPEG_STAGED_LD_LIBRARY_PATH=${FFMPEG_STAGED_LD_LIBRARY_PATH:-${FFMPEG_MPP_STAGED_LIB_PATH:-}}

if [ -z "${FFDIR:-}" ]; then
	if [ -x "$ROCK5B_WORKSPACE/ffmpeg/ffmpeg-rockchip-81/ffmpeg" ]; then
		FFDIR="$ROCK5B_WORKSPACE/ffmpeg/ffmpeg-rockchip-81"
	else
		FFDIR="$ROCK5B_WORKSPACE/ffmpeg/ffmpeg-rockchip"
	fi
fi

FF=${FF:-"$FFDIR/ffmpeg"}
PROBE=${PROBE:-"$FFDIR/ffprobe"}
BASE_LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}
CURRENT_CLASS=
CURRENT_RUNTIME=
CURRENT_LD_LIBRARY_PATH=
CURRENT_LOG=

required_cases_default="
ffmpeg_probe_rkmpp_rkrga
ffmpeg_decode_h264_extbuf_to_null
ffmpeg_decode_hevc_afbc_to_null
ffmpeg_decode_vp9_to_null
ffmpeg_psnr_h264_decode_inf
ffmpeg_psnr_hevc_decode_inf
ffmpeg_psnr_vp9_decode_inf
ffmpeg_encode_h264_options
ffmpeg_encode_hevc_options
ffmpeg_transcode_h264_to_hevc_rkrga
ffmpeg_transcode_hevc_to_h264_rkrga
ffmpeg_filter_scale_rkrga_core_async_afbc
ffmpeg_filter_vpp_rkrga_crop_transpose
ffmpeg_filter_overlay_rkrga_alpha
"

av1_cases_default="
ffmpeg_decode_av1_to_null
ffmpeg_psnr_av1_decode_inf
ffmpeg_transcode_av1_to_h264_rkrga
ffmpeg_transcode_av1_to_hevc_rkrga
ffmpeg_decode_av1_afbc_off
ffmpeg_decode_av1_afbc_on
ffmpeg_decode_av1_afbc_rga
"

diagnostic_cases_default="
ffmpeg_transcode_h264_afbc_rga_to_hevc
ffmpeg_hevc_main10_p010_rga
ffmpeg_decode_h264_resolution_change
"

if [ "$FFMPEG_REQUIRE_AV1" = "1" ]; then
	required_cases_default="$required_cases_default $av1_cases_default"
else
	diagnostic_cases_default="$diagnostic_cases_default $av1_cases_default"
fi
if [ "$FFMPEG_RUN_4K" = "1" ]; then
	diagnostic_cases_default="$diagnostic_cases_default ffmpeg_probe_4k_hevc_rga"
fi
if [ "$FFMPEG_RUN_8K" = "1" ]; then
	diagnostic_cases_default="$diagnostic_cases_default ffmpeg_probe_8k_hevc_rga"
fi
if [ "$FFMPEG_RUN_STRESS" = "1" ]; then
	required_cases_default="$required_cases_default
ffmpeg_stress_decode_loop
ffmpeg_stress_encode_loop
ffmpeg_stress_transcode_loop
ffmpeg_soak_av1_rga_h264
"
fi

required_cases=${FFMPEG_REQUIRED_CASES:-$required_cases_default}
diagnostic_cases=${FFMPEG_DIAGNOSTIC_CASES:-$diagnostic_cases_default}
failed=0
summary="$OUT/summary.tsv"
artifact_summary="$OUT/artifacts.tsv"

sanitize()
{
	printf "%s" "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

case_runtime_name()
{
	local case_name=$1
	local runtime

	if [ -z "${CURRENT_RUNTIME:-}" ]; then
		printf "%s\n" "$case_name"
		return
	fi

	runtime=$(sanitize "$CURRENT_RUNTIME")
	printf "%s_%s\n" "$runtime" "$case_name"
}

record_summary()
{
	local class=$1
	local case_name=$2
	local status=$3
	local elapsed=$4
	local result=$5
	local report_case

	report_case=$(case_runtime_name "$case_name")
	printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$PROFILE" "$class" "$report_case" "$status" "$elapsed" "$result" \
		>> "$summary"
}

record_artifact()
{
	local class=${CURRENT_CLASS:-$1}
	local case_name=$2
	local kind=$3
	local path=$4
	local bytes
	local sha
	local report_case
	local metadata

	if ! metadata=$(suite_artifact_metadata "$path"); then
		return 1
	fi
	IFS=$'\t' read -r bytes sha <<< "$metadata"
	report_case=$(case_runtime_name "$case_name")
	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$PROFILE" "$class" "$report_case" "$kind" "$bytes" "$sha" "$path" \
		>> "$artifact_summary"
}

runtime_file()
{
	local stem=$1
	local ext=$2
	local report_stem

	report_stem=$(case_runtime_name "$stem")
	printf "%s/%s.%s\n" "$OUT/artifacts" "$report_stem" "$ext"
}

generated_input_path()
{
	local codec=$1
	local ext=$2
	local width=${3:-$FFMPEG_WIDTH}
	local height=${4:-$FFMPEG_HEIGHT}
	local duration=${5:-$FFMPEG_DURATION}

	printf "%s/ffmpeg-%s-%sx%s-%sfps-%ss.%s" \
		"$FFMPEG_GENERATED_INPUT_CACHE" "$codec" "$width" \
		"$height" "$FFMPEG_FPS" "$duration" "$ext"
}

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

candidate_ffmpegs()
{
	local seen=
	local candidate
	local resolved

	for candidate in "$FFMPEG_GENERATOR" "$FF" ffmpeg; do
		if ! resolved=$(resolve_binary "$candidate"); then
			continue
		fi
		case " $seen " in
		*" $resolved "*)
			continue
			;;
		esac
		seen="$seen $resolved"
		printf "%s\n" "$resolved"
	done
}

plain_has_encoder()
{
	local bin=$1
	local enc=$2

	"$bin" -hide_banner -encoders 2>/dev/null |
		awk 'NF >= 2 { print $2 }' |
		grep -Fxq "$enc"
}

find_encoder_bin()
{
	local enc=$1
	local candidate

	while IFS= read -r candidate; do
		if plain_has_encoder "$candidate" "$enc"; then
			printf "%s\n" "$candidate"
			return 0
		fi
	done < <(candidate_ffmpegs)
	return 1
}

run_generator()
{
	local label=$1
	local bin=$2
	local log="$OUT/generate-$label.log"
	shift 2

	timeout "$FFMPEG_TIMEOUT" "$bin" -hide_banner -y -loglevel warning "$@" \
		> "$log" 2>&1
}

generate_input()
{
	local codec=$1
	local path=$2
	local tmp="$path.tmp"
	local part_a
	local part_b
	local bin

	mkdir -p "$(dirname "$path")" "$OUT"
	rm -f "$tmp"

	case "$codec" in
	h264)
		bin=$(find_encoder_bin libx264) ||
			{ echo "cannot generate H.264 input: libx264 missing; set FFMPEG_H264_INPUT" >&2; return 1; }
		run_generator "$codec" "$bin" \
			-f lavfi \
			-i "testsrc2=size=${FFMPEG_WIDTH}x${FFMPEG_HEIGHT}:rate=${FFMPEG_FPS}:duration=${FFMPEG_DURATION}" \
			-an -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -f h264 "$tmp"
		;;
	hevc)
		bin=$(find_encoder_bin libx265) ||
			{ echo "cannot generate H.265 input: libx265 missing; set FFMPEG_HEVC_INPUT" >&2; return 1; }
		run_generator "$codec" "$bin" \
			-f lavfi \
			-i "testsrc2=size=${FFMPEG_WIDTH}x${FFMPEG_HEIGHT}:rate=${FFMPEG_FPS}:duration=${FFMPEG_DURATION}" \
			-an -c:v libx265 -preset veryfast -crf 20 -pix_fmt yuv420p \
			-x265-params log-level=error -f hevc "$tmp"
		;;
	vp9)
		bin=$(find_encoder_bin libvpx-vp9) ||
			{ echo "cannot generate VP9 input: libvpx-vp9 missing; set FFMPEG_VP9_INPUT" >&2; return 1; }
		run_generator "$codec" "$bin" \
			-f lavfi \
			-i "testsrc2=size=${FFMPEG_WIDTH}x${FFMPEG_HEIGHT}:rate=${FFMPEG_FPS}:duration=${FFMPEG_DURATION}" \
			-an -c:v libvpx-vp9 -deadline good -cpu-used 6 -row-mt 1 \
			-b:v 0 -crf 31 -pix_fmt yuv420p -f ivf "$tmp"
		;;
	av1)
		if bin=$(find_encoder_bin libsvtav1); then
			run_generator "$codec" "$bin" \
				-f lavfi \
				-i "testsrc2=size=${FFMPEG_WIDTH}x${FFMPEG_HEIGHT}:rate=${FFMPEG_FPS}:duration=${FFMPEG_DURATION}" \
				-an -c:v libsvtav1 -preset 10 -crf 35 -pix_fmt yuv420p -f ivf "$tmp"
		elif bin=$(find_encoder_bin libaom-av1); then
			run_generator "$codec" "$bin" \
				-f lavfi \
				-i "testsrc2=size=${FFMPEG_WIDTH}x${FFMPEG_HEIGHT}:rate=${FFMPEG_FPS}:duration=${FFMPEG_DURATION}" \
				-an -c:v libaom-av1 -cpu-used 8 -b:v 0 -crf 35 -pix_fmt yuv420p -f ivf "$tmp"
		else
			echo "cannot generate AV1 input: libsvtav1/libaom-av1 missing; set FFMPEG_AV1_INPUT" >&2
			return 1
		fi
		;;
	hevc_main10)
		bin=$(find_encoder_bin libx265) ||
			{ echo "cannot generate H.265 Main10 input: libx265 missing; set FFMPEG_HEVC_MAIN10_INPUT" >&2; return 1; }
		run_generator "$codec" "$bin" \
			-f lavfi \
			-i "testsrc2=size=${FFMPEG_WIDTH}x${FFMPEG_HEIGHT}:rate=${FFMPEG_FPS}:duration=${FFMPEG_DURATION}" \
			-an -vf format=yuv420p10le -c:v libx265 -preset veryfast -crf 22 \
			-x265-params profile=main10:log-level=error -f hevc "$tmp"
		;;
	reschange_h264)
		bin=$(find_encoder_bin libx264) ||
			{ echo "cannot generate resolution-change H.264 input: libx264 missing; set FFMPEG_RESCHANGE_H264_INPUT" >&2; return 1; }
		part_a="$path.1280x720.tmp"
		part_b="$path.640x360.tmp"
		run_generator reschange_h264_720 "$bin" \
			-f lavfi -i "testsrc2=size=1280x720:rate=${FFMPEG_FPS}:duration=1" \
			-an -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
			-x264-params keyint=30:min-keyint=30:scenecut=0 -f h264 "$part_a"
		run_generator reschange_h264_360 "$bin" \
			-f lavfi -i "testsrc2=size=640x360:rate=${FFMPEG_FPS}:duration=1" \
			-an -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
			-x264-params keyint=30:min-keyint=30:scenecut=0 -f h264 "$part_b"
		cat "$part_a" "$part_b" > "$tmp"
		rm -f "$part_a" "$part_b"
		;;
	hevc_4k)
		bin=$(find_encoder_bin libx265) ||
			{ echo "cannot generate 4K H.265 input: libx265 missing; set FFMPEG_HEVC_4K_INPUT" >&2; return 1; }
		run_generator "$codec" "$bin" \
			-f lavfi -i "testsrc2=size=3840x2160:rate=${FFMPEG_FPS}:duration=1" \
			-an -c:v libx265 -preset ultrafast -crf 28 -pix_fmt yuv420p \
			-x265-params log-level=error -f hevc "$tmp"
		;;
	hevc_8k)
		bin=$(find_encoder_bin libx265) ||
			{ echo "cannot generate 8K H.265 input: libx265 missing; set FFMPEG_HEVC_8K_INPUT" >&2; return 1; }
		run_generator "$codec" "$bin" \
			-f lavfi -i "testsrc2=size=7680x4320:rate=${FFMPEG_FPS}:duration=1" \
			-an -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p \
			-x265-params log-level=error -f hevc "$tmp"
		;;
	*)
		echo "unknown generated input codec: $codec" >&2
		return 1
		;;
	esac

	mv "$tmp" "$path"
}

ensure_input()
{
	local codec=$1
	local var_name
	local ext
	local explicit
	local path

	case "$codec" in
	h264)
		var_name=FFMPEG_H264_INPUT
		ext=h264
		;;
	hevc)
		var_name=FFMPEG_HEVC_INPUT
		ext=h265
		;;
	vp9)
		var_name=FFMPEG_VP9_INPUT
		ext=ivf
		;;
	av1)
		var_name=FFMPEG_AV1_INPUT
		ext=ivf
		;;
	hevc_main10)
		var_name=FFMPEG_HEVC_MAIN10_INPUT
		ext=h265
		;;
	reschange_h264)
		var_name=FFMPEG_RESCHANGE_H264_INPUT
		ext=h264
		;;
	hevc_4k)
		var_name=FFMPEG_HEVC_4K_INPUT
		ext=h265
		;;
	hevc_8k)
		var_name=FFMPEG_HEVC_8K_INPUT
		ext=h265
		;;
	*)
		echo "unknown input codec: $codec" >&2
		return 1
		;;
	esac

	explicit=${!var_name:-}
	if [ -n "$explicit" ]; then
		if [ ! -f "$explicit" ]; then
			echo "$var_name points to missing file: $explicit" >&2
			return 1
		fi
		printf "%s\n" "$explicit"
		return 0
	fi

	if [ "$FFMPEG_GENERATE_INPUTS" != "1" ]; then
		echo "missing required env var $var_name" >&2
		return 1
	fi

	case "$codec" in
	hevc_4k)
		path=$(generated_input_path "$codec" "$ext" 3840 2160 1)
		;;
	hevc_8k)
		path=$(generated_input_path "$codec" "$ext" 7680 4320 1)
		;;
	reschange_h264)
		path=$(generated_input_path "$codec" "$ext" 1280 720 2)
		;;
	*)
		path=$(generated_input_path "$codec" "$ext")
		;;
	esac
	if [ ! -s "$path" ]; then
		generate_input "$codec" "$path"
	fi
	printf "%s\n" "$path"
}

snapshot_debugfs()
{
	local label=$1
	local target="$OUT/debugfs-$label.txt"
	local path

	: > "$target"
	for path in /sys/kernel/debug/rk_mpp_rewrite /sys/kernel/debug/rk_rga_rewrite \
		/sys/kernel/debug/rkrga /proc/mpp_service; do
		if [ -d "$path" ]; then
			{
				printf "== %s ==\n" "$path"
				find "$path" -maxdepth 2 -type f -print | sort |
					while IFS= read -r file; do
						printf "-- %s --\n" "$file"
						cat "$file" 2>/dev/null || true
					done
			} >> "$target" 2>/dev/null || true
		fi
	done
}

scan_fault_log()
{
	local file=$1

	[ -f "$file" ] || return 0
	if grep -Eiq '(iommu[^[:alnum:]]*(fault|panic|oops)|rga[^[:alnum:]]*(fault|panic|iommu)|mpp[^[:alnum:]]*(fault|panic|iommu))' "$file"; then
		printf "MPP/RGA/IOMMU fault pattern detected in %s\n" "$file" >&2
		return 1
	fi
}

run_runtime()
{
	if [ -n "${CURRENT_LD_LIBRARY_PATH:-}" ]; then
		env LD_LIBRARY_PATH="$CURRENT_LD_LIBRARY_PATH" "$@"
	else
		"$@"
	fi
}

run_timeout()
{
	local limit=${1:-$FFMPEG_TIMEOUT}
	shift

	# -k: escalate to SIGKILL if the child ignores SIGTERM. An ffmpeg-rockchip
	# rkmpp/rkrga pipeline can deadlock in userspace (all threads on a futex; see
	# status.md W21 — the FFmpeg-6.1 base), and its SIGTERM handler deadlocks on
	# the same lock, so without -k `timeout` would wait forever and hang the suite.
	run_runtime timeout -k "${FFMPEG_TIMEOUT_KILL:-15}" "$limit" "$@"
}

run_ffmpeg()
{
	run_timeout "$FFMPEG_TIMEOUT" "$FF" -hide_banner -nostdin -y -loglevel info "$@"
}

run_ffmpeg_sw_reference()
{
	# The suite FFmpeg build has no software AV1 decoder (its native av1
	# decoder is a hwaccel-only wrapper without libdav1d/libaom), so
	# software reference legs that need one use the generator FFmpeg.
	run_timeout "$FFMPEG_TIMEOUT" "$FFMPEG_GENERATOR" -hide_banner -nostdin -y -loglevel info "$@"
}

run_ffprobe()
{
	run_runtime "$PROBE" "$@"
}

require_pattern()
{
	local file=$1
	local pattern=$2
	local label=$3

	if grep -Eq "$pattern" "$file"; then
		printf "  OK   %s\n" "$label"
	else
		printf "  MISS %s\n" "$label"
		return 1
	fi
}

require_absent_pattern()
{
	local file=$1
	local pattern=$2
	local label=$3

	if grep -Eq "$pattern" "$file"; then
		printf "  NOTE %s unexpectedly present\n" "$label"
	else
		printf "  OK   %s absent as expected\n" "$label"
	fi
}

run_probe_components()
{
	local prefix
	local decoders
	local encoders
	local filters
	local version
	local ldd_log
	local h264_decoder_help
	local av1_decoder_help
	local h264_encoder_help
	local hevc_encoder_help
	local scale_help
	local vpp_help
	local overlay_help

	prefix="$OUT/$(case_runtime_name ffmpeg)"
	decoders="$prefix-decoders.txt"
	encoders="$prefix-encoders.txt"
	filters="$prefix-filters.txt"
	version="$prefix-version.txt"
	ldd_log="$prefix-ldd.txt"
	h264_decoder_help="$prefix-h264-rkmpp-decoder-help.txt"
	av1_decoder_help="$prefix-av1-rkmpp-decoder-help.txt"
	h264_encoder_help="$prefix-h264-rkmpp-encoder-help.txt"
	hevc_encoder_help="$prefix-hevc-rkmpp-encoder-help.txt"
	scale_help="$prefix-scale-rkrga-help.txt"
	vpp_help="$prefix-vpp-rkrga-help.txt"
	overlay_help="$prefix-overlay-rkrga-help.txt"

	uname -a > "$prefix-uname.txt" 2>&1
	run_runtime "$FF" -hide_banner -version > "$version" 2>&1
	run_runtime ldd "$FF" > "$ldd_log" 2>&1
	run_runtime "$FF" -hide_banner -decoders > "$decoders" 2>&1
	run_runtime "$FF" -hide_banner -encoders > "$encoders" 2>&1
	run_runtime "$FF" -hide_banner -filters > "$filters" 2>&1
	run_runtime "$FF" -hide_banner -h decoder=h264_rkmpp > "$h264_decoder_help" 2>&1
	run_runtime "$FF" -hide_banner -h decoder=av1_rkmpp > "$av1_decoder_help" 2>&1 || true
	run_runtime "$FF" -hide_banner -h encoder=h264_rkmpp > "$h264_encoder_help" 2>&1
	run_runtime "$FF" -hide_banner -h encoder=hevc_rkmpp > "$hevc_encoder_help" 2>&1
	run_runtime "$FF" -hide_banner -h filter=scale_rkrga > "$scale_help" 2>&1
	run_runtime "$FF" -hide_banner -h filter=vpp_rkrga > "$vpp_help" 2>&1
	run_runtime "$FF" -hide_banner -h filter=overlay_rkrga > "$overlay_help" 2>&1

	head -1 "$version"
	require_pattern "$decoders" '[[:space:]]h264_rkmpp[[:space:]]' "h264_rkmpp decoder"
	require_pattern "$decoders" '[[:space:]]hevc_rkmpp[[:space:]]' "hevc_rkmpp decoder"
	require_pattern "$decoders" '[[:space:]]vp9_rkmpp[[:space:]]' "vp9_rkmpp decoder"
	if [ "$FFMPEG_REQUIRE_AV1" = "1" ]; then
		require_pattern "$decoders" '[[:space:]]av1_rkmpp[[:space:]]' "av1_rkmpp decoder"
	elif grep -Eq '[[:space:]]av1_rkmpp[[:space:]]' "$decoders"; then
		printf "  NOTE av1_rkmpp decoder present; AV1 cases remain diagnostic unless FFMPEG_REQUIRE_AV1=1\n"
	else
		printf "  NOTE av1_rkmpp decoder absent; AV1 diagnostics will record this runtime gap\n"
	fi
	require_pattern "$encoders" '[[:space:]]h264_rkmpp[[:space:]]' "h264_rkmpp encoder"
	require_pattern "$encoders" '[[:space:]]hevc_rkmpp[[:space:]]' "hevc_rkmpp encoder"
	require_absent_pattern "$encoders" '[[:space:]]av1_rkmpp[[:space:]]' "av1_rkmpp encoder"
	require_pattern "$filters" '[[:space:]]scale_rkrga[[:space:]]' "scale_rkrga filter"
	require_pattern "$filters" '[[:space:]]vpp_rkrga[[:space:]]' "vpp_rkrga filter"
	require_pattern "$filters" '[[:space:]]overlay_rkrga[[:space:]]' "overlay_rkrga filter"
	require_pattern "$h264_decoder_help" 'afbc' "rkmpp decoder afbc option"
	require_pattern "$h264_decoder_help" 'buf_mode' "rkmpp decoder buf_mode option"
	require_pattern "$h264_decoder_help" 'fast_parse' "rkmpp decoder fast_parse option"
	if [ "$FFMPEG_REQUIRE_AV1" = "1" ]; then
		require_pattern "$av1_decoder_help" 'afbc' "av1_rkmpp decoder afbc option"
		require_pattern "$av1_decoder_help" 'rga' "av1_rkmpp decoder afbc=rga mode"
	fi
	require_pattern "$h264_encoder_help" 'rc_mode' "h264_rkmpp encoder rc_mode option"
	require_pattern "$h264_encoder_help" 'qp_init' "h264_rkmpp encoder qp_init option"
	require_pattern "$h264_encoder_help" 'qp_max' "h264_rkmpp encoder qp_max option"
	require_pattern "$h264_encoder_help" 'qp_min' "h264_rkmpp encoder qp_min option"
	require_pattern "$h264_encoder_help" 'profile' "h264_rkmpp encoder profile option"
	require_pattern "$h264_encoder_help" 'level' "h264_rkmpp encoder level option"
	require_pattern "$h264_encoder_help" 'coder' "h264_rkmpp encoder coder option"
	require_pattern "$h264_encoder_help" '8x8dct' "h264_rkmpp encoder 8x8dct option"
	require_pattern "$h264_encoder_help" 'prefix_mode' "h264_rkmpp encoder prefix_mode option"
	require_pattern "$hevc_encoder_help" 'rc_mode' "hevc_rkmpp encoder rc_mode option"
	require_pattern "$hevc_encoder_help" 'qp_init' "hevc_rkmpp encoder qp_init option"
	require_pattern "$hevc_encoder_help" 'qp_max' "hevc_rkmpp encoder qp_max option"
	require_pattern "$hevc_encoder_help" 'qp_min' "hevc_rkmpp encoder qp_min option"
	require_pattern "$hevc_encoder_help" 'profile' "hevc_rkmpp encoder profile option"
	require_pattern "$hevc_encoder_help" 'tier' "hevc_rkmpp encoder tier option"
	require_pattern "$hevc_encoder_help" 'level' "hevc_rkmpp encoder level option"
	require_pattern "$scale_help" 'force_original_aspect_ratio' "scale_rkrga aspect-ratio option"
	require_pattern "$scale_help" 'force_yuv' "scale_rkrga force_yuv option"
	require_pattern "$scale_help" 'force_chroma' "scale_rkrga force_chroma option"
	require_pattern "$scale_help" 'async_depth' "scale_rkrga async_depth option"
	require_pattern "$scale_help" 'core' "scale_rkrga core option"
	require_pattern "$scale_help" 'afbc' "scale_rkrga afbc option"
	require_pattern "$vpp_help" 'transpose' "vpp_rkrga transpose option"
	require_pattern "$vpp_help" 'cw' "vpp_rkrga crop-width option"
	require_pattern "$vpp_help" 'async_depth' "vpp_rkrga async_depth option"
	require_pattern "$overlay_help" 'alpha_format' "overlay_rkrga alpha_format option"
	require_pattern "$overlay_help" 'async_depth' "overlay_rkrga async_depth option"
	require_pattern "$overlay_help" 'afbc' "overlay_rkrga afbc option"
}

probe_check()
{
	local path=$1
	local codec=$2
	local width=$3
	local height=$4
	local info
	local got_codec
	local got_width
	local got_height
	local got_packets

	info=$(run_ffprobe -hide_banner -v error -select_streams v:0 \
		-show_entries stream=codec_name,width,height,nb_read_packets \
		-count_packets -of default=noprint_wrappers=1 "$path")
	printf "%s\n" "$info"

	got_codec=$(sed -n 's/^codec_name=//p' <<< "$info")
	got_width=$(sed -n 's/^width=//p' <<< "$info")
	got_height=$(sed -n 's/^height=//p' <<< "$info")
	got_packets=$(sed -n 's/^nb_read_packets=//p' <<< "$info")

	[ -s "$path" ] &&
		[ "$got_codec" = "$codec" ] &&
		[ "$got_width" = "$width" ] &&
		[ "$got_height" = "$height" ] &&
		[ "${got_packets:-0}" -gt 0 ]
}

probe_size()
{
	local path=$1
	local size

	size=$(run_ffprobe -v error -select_streams v:0 \
		-show_entries stream=width,height -of csv=s=x:p=0 "$path" |
		awk 'NR == 1 { print }')
	if [ -z "$size" ]; then
		echo "could not probe video size for $path" >&2
		return 1
	fi
	printf "%s\n" "$size"
}

psnr_average_from_log()
{
	local log=$1

	grep -Eo 'average:([0-9.]+|inf)' "$log" | tail -n 1 | cut -d: -f2
}

assert_psnr_inf()
{
	local log=$1
	local avg

	avg=$(psnr_average_from_log "$log")
	if [ "$avg" != "inf" ]; then
		echo "expected PSNR average:inf, got '${avg:-missing}'" >&2
		return 1
	fi
}

assert_psnr_threshold()
{
	local log=$1
	local threshold=$2
	local avg

	avg=$(psnr_average_from_log "$log")
	if [ -z "$avg" ]; then
		echo "missing PSNR average in $log" >&2
		return 1
	fi
	if [ "$avg" = "inf" ]; then
		return 0
	fi
	awk -v avg="$avg" -v threshold="$threshold" \
		'BEGIN { exit !(avg + 0 >= threshold + 0) }'
}

decode_psnr_inf()
{
	local case_name=$1
	local input_codec=$2
	local input
	local size
	local safe_case
	local sw_yuv
	local hw_yuv
	local stats_file

	input=$(ensure_input "$input_codec")
	size=$(probe_size "$input")
	safe_case=$(sanitize "$(case_runtime_name "$case_name")")
	sw_yuv="$OUT/artifacts/$safe_case-sw.yuv"
	hw_yuv="$OUT/artifacts/$safe_case-hw.yuv"
	stats_file="$OUT/artifacts/$safe_case-psnr.stats"

	rm -f "$sw_yuv" "$hw_yuv" "$stats_file"
	# Elementary H.264/H.265 streams can advertise a nominal frame rate that
	# differs from their generated timestamps. Disable output vsync so FFmpeg
	# does not independently duplicate/drop the SW and RKMPP decode frames
	# before the byte-for-byte PSNR comparison.
	if [ "$input_codec" = av1 ]; then
		run_ffmpeg_sw_reference -i "$input" -map 0:v:0 -an -pix_fmt yuv420p \
			-fps_mode passthrough -f rawvideo "$sw_yuv"
	else
		run_ffmpeg -i "$input" -map 0:v:0 -an -pix_fmt yuv420p \
			-fps_mode passthrough -f rawvideo "$sw_yuv"
	fi
	run_ffmpeg \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v "${input_codec}_rkmpp" -i "$input" \
		-map 0:v:0 -an \
		-vf "hwdownload,format=nv12,format=yuv420p" \
		-fps_mode passthrough -f rawvideo "$hw_yuv"
	run_ffmpeg \
		-f rawvideo -pix_fmt yuv420p -s:v "$size" -r "$FFMPEG_FPS" -i "$sw_yuv" \
		-f rawvideo -pix_fmt yuv420p -s:v "$size" -r "$FFMPEG_FPS" -i "$hw_yuv" \
		-lavfi "psnr=stats_file=${stats_file}" -f null -
	assert_psnr_inf "$CURRENT_LOG"
}

encoded_psnr_against_testsrc()
{
	local output=$1
	local threshold=$2
	local size
	local stats_file

	[ -s "$output" ] || return 1
	size=$(probe_size "$output")
	stats_file="$OUT/artifacts/$(sanitize "$(case_runtime_name "$CURRENT_CASE")")-encoded-psnr.stats"
	run_ffmpeg \
		-f lavfi -i "testsrc2=size=${size}:rate=${FFMPEG_FPS}:duration=${FFMPEG_DURATION}" \
		-i "$output" \
		-filter_complex "[0:v]setpts=PTS-STARTPTS,format=yuv420p[ref];[1:v]setpts=PTS-STARTPTS,format=yuv420p[test];[ref][test]psnr=stats_file=${stats_file}" \
		-f null -
	assert_psnr_threshold "$CURRENT_LOG" "$threshold"
}

encoded_psnr_against_input()
{
	local input=$1
	local output=$2
	local threshold=$3
	local size
	local scale_size
	local stats_file

	[ -s "$input" ] || return 1
	[ -s "$output" ] || return 1
	size=$(probe_size "$output")
	scale_size=${size/x/:}
	stats_file="$OUT/artifacts/$(sanitize "$(case_runtime_name "$CURRENT_CASE")")-encoded-psnr.stats"
	run_ffmpeg \
		-i "$input" -i "$output" \
		-filter_complex "[0:v]setpts=PTS-STARTPTS,scale=${scale_size}:flags=bicubic,format=yuv420p[ref];[1:v]setpts=PTS-STARTPTS,format=yuv420p[test];[ref][test]psnr=stats_file=${stats_file}" \
		-f null -
	assert_psnr_threshold "$CURRENT_LOG" "$threshold"
}

run_transcode()
{
	local case_name=$1
	local input_codec=$2
	local output_codec=$3
	local output_encoder=$4
	local output_format=$5
	local output_width=$6
	local output_height=$7
	local bitrate=$8
	local input
	local output

	input=$(ensure_input "$input_codec")
	output=$(runtime_file "$case_name" "$output_format")
	rm -f "$output"
	run_ffmpeg \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v "${input_codec}_rkmpp" \
		-i "$input" \
		-vf "scale_rkrga=w=${output_width}:h=${output_height}:format=nv12:force_original_aspect_ratio=disable" \
		-c:v "$output_encoder" -b:v "$bitrate" -f "$output_format" "$output"

	probe_check "$output" "$output_codec" "$output_width" "$output_height"
	encoded_psnr_against_input "$input" "$output" "$FFMPEG_PSNR_THRESHOLD"
	record_artifact required "$case_name" "encoded-$output_codec" "$output"
}

run_encode_generated()
{
	local case_name=$1
	local output_codec=$2
	local output_encoder=$3
	local output_format=$4
	local output_width=$5
	local output_height=$6
	local bitrate=$7
	shift 7
	local output

	output=$(runtime_file "$case_name" "$output_format")
	rm -f "$output"
	run_ffmpeg \
		-f lavfi \
		-i "testsrc2=size=${output_width}x${output_height}:rate=${FFMPEG_FPS}:duration=${FFMPEG_DURATION}" \
		-pix_fmt nv12 \
		-c:v "$output_encoder" "$@" -b:v "$bitrate" -f "$output_format" "$output"

	probe_check "$output" "$output_codec" "$output_width" "$output_height"
	encoded_psnr_against_testsrc "$output" "$FFMPEG_PSNR_THRESHOLD"
	record_artifact required "$case_name" "encoded-$output_codec" "$output"
}

run_decode_null()
{
	local input_codec=$1
	local decoder=$2
	shift 2
	local input

	input=$(ensure_input "$input_codec")
	run_ffmpeg \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v "$decoder" "$@" \
		-i "$input" \
		-an -f null -
}

run_filter_transcode()
{
	local case_name=$1
	local input_codec=$2
	local input_decoder=$3
	local output_codec=$4
	local output_encoder=$5
	local output_format=$6
	local output_width=$7
	local output_height=$8
	local bitrate=$9
	local filter=${10}
	local input
	local output

	input=$(ensure_input "$input_codec")
	output=$(runtime_file "$case_name" "$output_format")
	rm -f "$output"
	run_ffmpeg \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v "$input_decoder" \
		-i "$input" \
		-vf "$filter" \
		-c:v "$output_encoder" -b:v "$bitrate" -f "$output_format" "$output"

	probe_check "$output" "$output_codec" "$output_width" "$output_height"
	encoded_psnr_against_input "$input" "$output" "$FFMPEG_PSNR_THRESHOLD"
	record_artifact required "$case_name" "encoded-$output_codec" "$output"
}

run_filter_transcode_with_decoder_opts()
{
	local case_name=$1
	local input_codec=$2
	local input_decoder=$3
	local output_codec=$4
	local output_encoder=$5
	local output_format=$6
	local output_width=$7
	local output_height=$8
	local bitrate=$9
	local filter=${10}
	shift 10
	local input
	local output

	input=$(ensure_input "$input_codec")
	output=$(runtime_file "$case_name" "$output_format")
	rm -f "$output"
	run_ffmpeg \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v "$input_decoder" "$@" \
		-i "$input" \
		-vf "$filter" \
		-c:v "$output_encoder" -b:v "$bitrate" -f "$output_format" "$output"

	probe_check "$output" "$output_codec" "$output_width" "$output_height"
	encoded_psnr_against_input "$input" "$output" "$FFMPEG_PSNR_THRESHOLD"
	record_artifact diagnostic "$case_name" "encoded-$output_codec" "$output"
}

run_overlay_transcode()
{
	local case_name=$1
	local input_codec=$2
	local input_decoder=$3
	local output_codec=$4
	local output_encoder=$5
	local output_format=$6
	local output_width=$7
	local output_height=$8
	local bitrate=$9
	local filter=${10}
	local input
	local output

	input=$(ensure_input "$input_codec")
	output=$(runtime_file "$case_name" "$output_format")
	rm -f "$output"
	run_ffmpeg \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v "$input_decoder" \
		-i "$input" \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v "$input_decoder" \
		-i "$input" \
		-filter_complex "$filter" \
		-map "[out]" \
		-c:v "$output_encoder" -b:v "$bitrate" -f "$output_format" "$output"

	probe_check "$output" "$output_codec" "$output_width" "$output_height"
	record_artifact required "$case_name" "encoded-$output_codec" "$output"
}

run_hevc_main10_p010_rga()
{
	local input
	local size
	local safe_case
	local sw_yuv
	local hw_yuv
	local stats_file

	input=$(ensure_input hevc_main10)
	size=$(probe_size "$input")
	safe_case=$(sanitize "$(case_runtime_name "$CURRENT_CASE")")
	sw_yuv="$OUT/artifacts/$safe_case-sw.yuv"
	hw_yuv="$OUT/artifacts/$safe_case-hw.yuv"
	stats_file="$OUT/artifacts/$safe_case-psnr.stats"

	rm -f "$sw_yuv" "$hw_yuv" "$stats_file"
	# Linear NV15 decoder output is not RGA-expressible at this width: MPP
	# pads hor_stride to a byte count that is not a whole number of packed
	# 10-bit pixels, so the RGA input must come from the AFBC decoder path.
	# The same-size NV15->P010 conversion is a pure 10-bit repack and must
	# be bit-exact against the software decode. This exact RGA3 incompact-P010
	# diagnostic remains red, but its cause is not isolated: the checked BSP
	# kernel already uses the correct byte-unit stride/offset contract, and
	# Jellyfin's targeted NV15-first workaround does not prove the same root
	# cause. Keep it diagnostic rather than assigning a kernel defect here.
	run_ffmpeg -i "$input" -map 0:v:0 -an -pix_fmt p010le \
		-fps_mode passthrough -f rawvideo "$sw_yuv"
	run_ffmpeg \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-afbc rga -c:v hevc_rkmpp -i "$input" \
		-map 0:v:0 -an \
		-vf "scale_rkrga=w=${size%x*}:h=${size#*x}:format=p010le,hwdownload,format=p010le" \
		-fps_mode passthrough -f rawvideo "$hw_yuv"
	run_ffmpeg \
		-f rawvideo -pix_fmt p010le -s:v "$size" -r "$FFMPEG_FPS" -i "$sw_yuv" \
		-f rawvideo -pix_fmt p010le -s:v "$size" -r "$FFMPEG_FPS" -i "$hw_yuv" \
		-lavfi "psnr=stats_file=${stats_file}" -f null -
	assert_psnr_inf "$CURRENT_LOG"
}

run_reschange_decode()
{
	local input

	input=$(ensure_input reschange_h264)
	run_ffmpeg \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-f h264 -c:v h264_rkmpp -i "$input" \
		-map 0:v:0 -an -f null -
}

run_hevc_probe()
{
	local input_codec=$1
	local output_width=$2
	local output_height=$3
	local input

	input=$(ensure_input "$input_codec")
	run_ffmpeg \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v hevc_rkmpp -i "$input" \
		-map 0:v:0 -an \
		-vf "scale_rkrga=w=${output_width}:h=${output_height}:format=nv12,hwdownload,format=nv12" \
		-f null -
}

run_stress_decode_loop()
{
	local input
	local i

	input=$(ensure_input av1)
	for ((i = 1; i <= FFMPEG_STRESS_LOOPS; i++)); do
		run_ffmpeg \
			-hwaccel rkmpp -hwaccel_output_format drm_prime \
			-c:v av1_rkmpp -i "$input" \
			-map 0:v:0 -an -frames:v 12 -f null -
	done
}

run_stress_encode_loop()
{
	local i
	local output

	for ((i = 1; i <= FFMPEG_STRESS_LOOPS; i++)); do
		output="$OUT/artifacts/$(sanitize "$(case_runtime_name "$CURRENT_CASE")")-$i.h264"
		rm -f "$output"
		run_ffmpeg \
			-f lavfi -i "testsrc2=size=320x180:rate=${FFMPEG_FPS}:duration=1" \
			-an -vf format=nv12 -c:v h264_rkmpp -b:v 1M -g 30 \
			-f h264 "$output"
		[ -s "$output" ] || return 1
	done
}

run_stress_transcode_loop()
{
	local input
	local i

	input=$(ensure_input h264)
	for ((i = 1; i <= FFMPEG_STRESS_LOOPS; i++)); do
		run_ffmpeg \
			-hwaccel rkmpp -hwaccel_output_format drm_prime \
			-c:v h264_rkmpp -i "$input" \
			-map 0:v:0 -an -frames:v 12 \
			-vf "scale_rkrga=w=320:h=180:format=nv12" \
			-c:v hevc_rkmpp -b:v 1M -g 30 -f null -
	done
}

run_soak_av1_rga_h264()
{
	local input
	local timeout_limit=$FFMPEG_TIMEOUT

	input=$(ensure_input av1)
	if [[ "$FFMPEG_SOAK_SECONDS" =~ ^[0-9]+$ ]] &&
		[ "$timeout_limit" -lt $((FFMPEG_SOAK_SECONDS + 120)) ]; then
		timeout_limit=$((FFMPEG_SOAK_SECONDS + 120))
	fi
	run_timeout "$timeout_limit" "$FF" -hide_banner -nostdin -y -loglevel info \
		-stream_loop -1 -t "$FFMPEG_SOAK_SECONDS" \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v av1_rkmpp -afbc rga -i "$input" \
		-map 0:v:0 -an \
		-vf "scale_rkrga=w=1920:h=1080:format=nv12" \
		-c:v h264_rkmpp -b:v 8M -g 60 -f null -
}

case_known()
{
	case "$1" in
	ffmpeg_probe_rkmpp_rkrga | \
	ffmpeg_decode_h264_extbuf_to_null | \
	ffmpeg_decode_hevc_afbc_to_null | \
	ffmpeg_decode_vp9_to_null | \
	ffmpeg_decode_av1_to_null | \
	ffmpeg_psnr_h264_decode_inf | \
	ffmpeg_psnr_hevc_decode_inf | \
	ffmpeg_psnr_vp9_decode_inf | \
	ffmpeg_psnr_av1_decode_inf | \
	ffmpeg_encode_h264_options | \
	ffmpeg_encode_hevc_options | \
	ffmpeg_transcode_h264_to_hevc_rkrga | \
	ffmpeg_transcode_hevc_to_h264_rkrga | \
	ffmpeg_transcode_av1_to_h264_rkrga | \
	ffmpeg_transcode_av1_to_hevc_rkrga | \
	ffmpeg_filter_scale_rkrga_core_async_afbc | \
	ffmpeg_filter_vpp_rkrga_crop_transpose | \
	ffmpeg_filter_overlay_rkrga_alpha | \
	ffmpeg_transcode_h264_afbc_rga_to_hevc | \
	ffmpeg_decode_av1_afbc_off | \
	ffmpeg_decode_av1_afbc_on | \
	ffmpeg_decode_av1_afbc_rga | \
	ffmpeg_hevc_main10_p010_rga | \
	ffmpeg_decode_h264_resolution_change | \
	ffmpeg_probe_4k_hevc_rga | \
	ffmpeg_probe_8k_hevc_rga | \
	ffmpeg_stress_decode_loop | \
	ffmpeg_stress_encode_loop | \
	ffmpeg_stress_transcode_loop | \
	ffmpeg_soak_av1_rga_h264)
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

validate_runtime_modes()
{
	local mode

	for mode in $(runtime_modes); do
		case "$mode" in
		system | staged)
			printf "valid\truntime\t%s\n" "$mode"
			;;
		*)
			printf "invalid\truntime\t%s\n" "$mode" >&2
			return 1
			;;
		esac
	done
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

	if ! validate_runtime_modes; then
		validation_failed=1
	fi

	if [ "$validation_failed" -ne 0 ]; then
		return 1
	fi

	printf "validated %s ffmpeg-rockchip cases\n" "$total"
}

run_case_payload()
{
	local case_name=$1

	case "$case_name" in
	ffmpeg_probe_rkmpp_rkrga)
		run_probe_components
		;;
	ffmpeg_decode_h264_extbuf_to_null)
		run_decode_null h264 h264_rkmpp \
			-deint 0 -fast_parse 0 -buf_mode ext -afbc off
		;;
	ffmpeg_decode_hevc_afbc_to_null)
		run_decode_null hevc hevc_rkmpp \
			-deint 0 -fast_parse 1 -buf_mode half -afbc on
		;;
	ffmpeg_decode_vp9_to_null)
		run_decode_null vp9 vp9_rkmpp
		;;
	ffmpeg_decode_av1_to_null)
		run_decode_null av1 av1_rkmpp
		;;
	ffmpeg_psnr_h264_decode_inf)
		decode_psnr_inf "$case_name" h264
		;;
	ffmpeg_psnr_hevc_decode_inf)
		decode_psnr_inf "$case_name" hevc
		;;
	ffmpeg_psnr_vp9_decode_inf)
		decode_psnr_inf "$case_name" vp9
		;;
	ffmpeg_psnr_av1_decode_inf)
		decode_psnr_inf "$case_name" av1
		;;
	ffmpeg_encode_h264_options)
		run_encode_generated "$case_name" h264 h264_rkmpp h264 640 360 2M \
			-rc_mode CBR -qp_init 26 -qp_min 20 -qp_max 36 \
			-qp_min_i 18 -qp_max_i 34 \
			-profile:v high -level:v 4.1 -coder cabac -8x8dct 1 \
			-prefix_mode 1
		;;
	ffmpeg_encode_hevc_options)
		run_encode_generated "$case_name" hevc hevc_rkmpp hevc 640 360 2M \
			-rc_mode CBR -qp_init 28 -qp_min 22 -qp_max 38 \
			-qp_min_i 20 -qp_max_i 36 \
			-profile:v main -tier high -level:v 4.1
		;;
	ffmpeg_transcode_h264_to_hevc_rkrga)
		run_transcode "$case_name" h264 hevc hevc_rkmpp hevc 1280 720 4M
		;;
	ffmpeg_transcode_hevc_to_h264_rkrga)
		run_transcode "$case_name" hevc h264 h264_rkmpp h264 640 480 2M
		;;
	ffmpeg_transcode_av1_to_h264_rkrga)
		run_transcode "$case_name" av1 h264 h264_rkmpp h264 1280 720 4M
		;;
	ffmpeg_transcode_av1_to_hevc_rkrga)
		run_transcode "$case_name" av1 hevc hevc_rkmpp hevc 1280 720 4M
		;;
	ffmpeg_filter_scale_rkrga_core_async_afbc)
		run_filter_transcode "$case_name" hevc hevc_rkmpp h264 h264_rkmpp h264 \
			960 540 3M \
			"scale_rkrga=w=960:h=540:format=nv12:force_original_aspect_ratio=disable:force_yuv=8bit:force_chroma=420sp:core=rga3_core1:async_depth=4:afbc=1"
		;;
	ffmpeg_filter_vpp_rkrga_crop_transpose)
		run_filter_transcode "$case_name" h264 h264_rkmpp hevc hevc_rkmpp hevc \
			360 640 3M \
			"vpp_rkrga=cw=960:ch=540:cx=160:cy=90:w=640:h=360:format=nv12:transpose=clock:core=rga3_core0:async_depth=2"
		;;
	ffmpeg_filter_overlay_rkrga_alpha)
		run_overlay_transcode "$case_name" h264 h264_rkmpp hevc hevc_rkmpp hevc \
			1920 1080 4M \
			"[0:v][1:v]overlay_rkrga=x=64:y=32:alpha=192:alpha_format=straight:format=nv12:core=rga3_core0:async_depth=0[out]"
		;;
	ffmpeg_transcode_h264_afbc_rga_to_hevc)
		run_filter_transcode_with_decoder_opts "$case_name" h264 h264_rkmpp hevc hevc_rkmpp hevc \
			1280 720 4M \
			"scale_rkrga=w=1280:h=720:format=nv12:force_original_aspect_ratio=disable:async_depth=2" \
			-afbc rga -buf_mode half
		;;
	ffmpeg_decode_av1_afbc_off)
		run_decode_null av1 av1_rkmpp -afbc off
		;;
	ffmpeg_decode_av1_afbc_on)
		run_decode_null av1 av1_rkmpp -afbc on
		;;
	ffmpeg_decode_av1_afbc_rga)
		run_filter_transcode_with_decoder_opts "$case_name" av1 av1_rkmpp h264 h264_rkmpp h264 \
			640 360 2M \
			"scale_rkrga=w=640:h=360:format=nv12:force_original_aspect_ratio=disable:async_depth=2" \
			-afbc rga
		;;
	ffmpeg_hevc_main10_p010_rga)
		run_hevc_main10_p010_rga
		;;
	ffmpeg_decode_h264_resolution_change)
		run_reschange_decode
		;;
	ffmpeg_probe_4k_hevc_rga)
		run_hevc_probe hevc_4k 1920 1080
		;;
	ffmpeg_probe_8k_hevc_rga)
		run_hevc_probe hevc_8k 3840 2160
		;;
	ffmpeg_stress_decode_loop)
		run_stress_decode_loop
		;;
	ffmpeg_stress_encode_loop)
		run_stress_encode_loop
		;;
	ffmpeg_stress_transcode_loop)
		run_stress_transcode_loop
		;;
	ffmpeg_soak_av1_rga_h264)
		run_soak_av1_rga_h264
		;;
	*)
		echo "unknown case $case_name" >&2
		return 2
		;;
	esac
}

run_case()
{
	local class=$1
	local case_name=$2
	local report_case
	local log
	local status_file
	local start
	local end
	local elapsed
	local status
	local result

	if [ -z "$case_name" ]; then
		return
	fi

	report_case=$(case_runtime_name "$case_name")
	log="$OUT/$report_case.log"
	status_file="$OUT/$report_case.status"
	CURRENT_LOG=$log
	CURRENT_CASE=$case_name
	start=$(suite_now_ns)
	CURRENT_CLASS=$class
	set +e
	suite_run_strict "$log" run_case_payload "$case_name"
	status=$?
	if [ "$status" -eq 0 ]; then
		scan_fault_log "$log"
		status=$?
	fi
	set -e
	unset CURRENT_CLASS
	end=$(suite_now_ns)
	elapsed=$(suite_elapsed_s "$start" "$end")

	printf "%s\n" "$status" > "$status_file"
	if [ "$status" -eq 0 ]; then
		result=pass
	elif [ "$class" = "diagnostic" ]; then
		result=diagnostic-fail
	else
		result=fail
		failed=1
	fi

	record_summary "$class" "$case_name" "$status" "$elapsed" "$result"
}

runtime_modes()
{
	local staged_ld=${FFMPEG_STAGED_LD_LIBRARY_PATH:-}

	if [ -z "$staged_ld" ] && [ -d "$STAGE/lib" ]; then
		staged_ld="$STAGE/lib"
	fi

	if [ "$FFMPEG_RUNTIME_MODES" != "auto" ]; then
		printf "%s\n" "$FFMPEG_RUNTIME_MODES"
		return
	fi

	printf "system"
	if [ -n "$staged_ld" ] && [ -d "$staged_ld" ]; then
		printf " staged"
	fi
	printf "\n"
}

set_runtime()
{
	local mode=$1
	local staged_ld=${FFMPEG_STAGED_LD_LIBRARY_PATH:-}

	CURRENT_RUNTIME=$mode
	CURRENT_LD_LIBRARY_PATH=
	if [ "$mode" = "staged" ]; then
		if [ -z "$staged_ld" ] && [ -d "$STAGE/lib" ]; then
			staged_ld="$STAGE/lib"
		fi
		if [ -z "$staged_ld" ] || [ ! -d "$staged_ld" ]; then
			echo "staged runtime requested but no staged lib directory was found; set FFMPEG_STAGED_LD_LIBRARY_PATH or STAGE" >&2
			return 1
		fi
		CURRENT_LD_LIBRARY_PATH=$staged_ld
		if [ -n "$BASE_LD_LIBRARY_PATH" ]; then
			CURRENT_LD_LIBRARY_PATH="$CURRENT_LD_LIBRARY_PATH:$BASE_LD_LIBRARY_PATH"
		fi
	fi
}

preflight_devices()
{
	local support_file=/proc/mpp_service/supports-device
	local path
	local found_dma_heap=0
	local found_render=0

	if [ ! -e /dev/mpp_service ]; then
		echo "SKIP: /dev/mpp_service is absent on this boot"
		exit 77
	fi
	if [ ! -e /dev/rga ]; then
		echo "SKIP: /dev/rga is absent on this boot"
		exit 77
	fi

	for path in /dev/mpp_service /dev/rga; do
		if [ ! -r "$path" ] || [ ! -w "$path" ]; then
			echo "current user lacks read/write permission on $path" >&2
			return 1
		fi
	done

	for path in /dev/dma_heap/*; do
		if [ -e "$path" ]; then
			found_dma_heap=1
			if [ ! -r "$path" ] || [ ! -w "$path" ]; then
				echo "current user lacks read/write permission on $path" >&2
				return 1
			fi
		fi
	done
	if [ "$found_dma_heap" -ne 1 ]; then
		echo "missing DMA heap nodes under /dev/dma_heap" >&2
		return 1
	fi

	for path in /dev/dri/renderD*; do
		if [ -e "$path" ]; then
			found_render=1
			if [ ! -r "$path" ] || [ ! -w "$path" ]; then
				echo "current user lacks read/write permission on $path" >&2
				return 1
			fi
		fi
	done
	if [ "$found_render" -ne 1 ]; then
		echo "missing DRM render node under /dev/dri/renderD*" >&2
		return 1
	fi

	if [ ! -r "$support_file" ]; then
		echo "missing readable $support_file" >&2
		return 1
	fi
	cp "$support_file" "$OUT/supports-device.txt"
	grep -q 'RKVDEC' "$support_file" ||
		{ echo "$support_file does not list RKVDEC" >&2; return 1; }
	grep -Eq "$FFMPEG_EXPECT_ENCODER_DEVICE_REGEX" "$support_file" ||
		{ echo "$support_file does not list expected encoder device regex: $FFMPEG_EXPECT_ENCODER_DEVICE_REGEX" >&2; return 1; }
	if [ "$FFMPEG_REQUIRE_AV1" = "1" ]; then
		grep -q 'AV1DEC' "$support_file" ||
			{ echo "$support_file does not list AV1DEC" >&2; return 1; }
	elif grep -q 'AV1DEC' "$support_file"; then
		echo "NOTE: $support_file lists AV1DEC; AV1 FFmpeg cases are diagnostic unless FFMPEG_REQUIRE_AV1=1"
	else
		echo "NOTE: $support_file does not list AV1DEC; AV1 FFmpeg diagnostics may fail on this boot"
	fi
}

run_runtime_cases()
{
	local runtime=$1
	local case_name

	set_runtime "$runtime"
	echo "running ffmpeg-rockchip suite with $runtime runtime"
	if [ -n "$CURRENT_LD_LIBRARY_PATH" ]; then
		echo "LD_LIBRARY_PATH=$CURRENT_LD_LIBRARY_PATH"
	fi

	# Known-issue advisory (status.md W21): ffmpeg-rockchip builds that lack the
	# rkmpp input-backpressure fix (`da5befc806`, on our 8.0 line) can deadlock the
	# h264->hevc and hevc_main10->p010 transcodes (all threads on a futex). Observed
	# on the FFmpeg-master build (libavcodec 63) the harness defaults FF to; the
	# shipping /usr/bin/ffmpeg 8.0.3~rk1 (libavcodec 62, carries da5befc806) is
	# clean. It is a userspace bug, not the kernel. We keep the case in the matrix;
	# a deadlock is reaped by the run_timeout SIGKILL fallback and scored as a real
	# failure. Report the runtime libavcodec so a failure here is easy to attribute.
	local lavc_ver
	lavc_ver=$("$FF" -hide_banner -version 2>/dev/null |
		sed -n 's/^libavcodec[[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -1)
	[ -n "$lavc_ver" ] && echo "FF=$FF libavcodec=$lavc_ver (W21: transcode deadlocks unless this build carries da5befc806)"

	for case_name in $required_cases; do
		run_case required "$case_name"
	done

	for case_name in $diagnostic_cases; do
		run_case diagnostic "$case_name"
	done
}

if [ "$FFMPEG_VALIDATE_CASES" = "1" ]; then
	validate_cases
	exit $?
fi

if [ ! -x "$FF" ]; then
	echo "Missing ffmpeg binary: $FF" >&2
	exit 2
fi
if [ ! -x "$PROBE" ]; then
	echo "Missing ffprobe binary: $PROBE" >&2
	exit 2
fi
if [ "$FFMPEG_REQUIRE_STAGED_RUNTIME" = "1" ] &&
	! runtime_modes | grep -Eq '(^|[[:space:]])staged($|[[:space:]])'; then
	echo "staged runtime is required but not available; set STAGE or FFMPEG_STAGED_LD_LIBRARY_PATH" >&2
	exit 2
fi

mkdir -p "$OUT/artifacts" "$FFMPEG_GENERATED_INPUT_CACHE"
printf "profile\tclass\tcase\tstatus\telapsed_s\tresult\n" > "$summary"
printf "profile\tclass\tcase\tkind\tbytes\tsha256\tpath\n" > "$artifact_summary"

if ! suite_dmesg_start "$OUT"; then
	echo "FAIL: dmesg is required but unreadable" >&2
	exit 1
fi

preflight_devices
snapshot_debugfs before
debugfs_counter_snapshot "$OUT/debugfs-counters-before.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite

for runtime in $(runtime_modes); do
	run_runtime_cases "$runtime"
done

snapshot_debugfs after
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
suite_reown_to_invoking_user "$OUT" "$FFMPEG_GENERATED_INPUT_CACHE"

echo "$OUT"

if [ "$failed" -ne 0 ]; then
	echo "FAIL: one or more required ffmpeg-rockchip cases failed; see $summary" >&2
	exit 1
fi

exit 0
