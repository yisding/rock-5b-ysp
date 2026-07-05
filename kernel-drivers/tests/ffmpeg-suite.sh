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
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-ffmpeg-suite"}
STAGE=${STAGE:-"$REPO_ROOT/../kernel/rock5b-kernel-build/ffmpeg-stack"}
FFMPEG_GENERATOR=${FFMPEG_GENERATOR:-ffmpeg}
FFMPEG_GENERATED_INPUT_CACHE=${FFMPEG_GENERATED_INPUT_CACHE:-"$CONFORMANCE_ROOT/assets/ffmpeg-generated"}
FFMPEG_GENERATE_INPUTS=${FFMPEG_GENERATE_INPUTS:-1}
FFMPEG_WIDTH=${FFMPEG_WIDTH:-1920}
FFMPEG_HEIGHT=${FFMPEG_HEIGHT:-1080}
FFMPEG_FPS=${FFMPEG_FPS:-30}
FFMPEG_DURATION=${FFMPEG_DURATION:-2}
FFMPEG_TIMEOUT=${FFMPEG_TIMEOUT:-180}
FFMPEG_VALIDATE_CASES=${FFMPEG_VALIDATE_CASES:-0}

if [ -z "${FFDIR:-}" ]; then
	if [ -x "$REPO_ROOT/../ffmpeg/ffmpeg-rockchip-81/ffmpeg" ]; then
		FFDIR="$REPO_ROOT/../ffmpeg/ffmpeg-rockchip-81"
	else
		FFDIR="$REPO_ROOT/../ffmpeg/ffmpeg-rockchip"
	fi
fi

FF=${FF:-"$FFDIR/ffmpeg"}
PROBE=${PROBE:-"$FFDIR/ffprobe"}

required_cases_default="
ffmpeg_probe_rkmpp_rkrga
ffmpeg_decode_h264_extbuf_to_null
ffmpeg_decode_hevc_afbc_to_null
ffmpeg_encode_h264_options
ffmpeg_encode_hevc_options
ffmpeg_transcode_h264_to_hevc_rkrga
ffmpeg_transcode_hevc_to_h264_rkrga
ffmpeg_filter_scale_rkrga_core_async_afbc
ffmpeg_filter_vpp_rkrga_crop_transpose
"

diagnostic_cases_default="
ffmpeg_transcode_h264_afbc_rga_to_hevc
ffmpeg_filter_overlay_rkrga_alpha
"

required_cases=${FFMPEG_REQUIRED_CASES:-$required_cases_default}
diagnostic_cases=${FFMPEG_DIAGNOSTIC_CASES:-$diagnostic_cases_default}
failed=0
summary="$OUT/summary.tsv"
artifact_summary="$OUT/artifacts.tsv"

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

record_artifact()
{
	local class=${CURRENT_CLASS:-$1}
	local case_name=$2
	local kind=$3
	local path=$4
	local bytes
	local sha

	[ -f "$path" ] || return 1
	bytes=$(stat -c%s "$path")
	sha=$(sha256sum "$path" | awk '{ print $1 }')
	printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
		"$PROFILE" "$class" "$case_name" "$kind" "$bytes" "$sha" "$path" \
		>> "$artifact_summary"
}

generated_input_path()
{
	local codec=$1
	local ext=$2

	printf "%s/ffmpeg-%s-%sx%s-%sfps-%ss.%s" \
		"$FFMPEG_GENERATED_INPUT_CACHE" "$codec" "$FFMPEG_WIDTH" \
		"$FFMPEG_HEIGHT" "$FFMPEG_FPS" "$FFMPEG_DURATION" "$ext"
}

generate_input()
{
	local codec=$1
	local path=$2
	local tmp="$path.tmp"
	local encoder
	local format

	case "$codec" in
	h264)
		encoder=libx264
		format=h264
		;;
	hevc)
		encoder=libx265
		format=hevc
		;;
	*)
		echo "unknown generated input codec: $codec" >&2
		return 1
		;;
	esac

	rm -f "$tmp"
	timeout "$FFMPEG_TIMEOUT" "$FFMPEG_GENERATOR" -hide_banner -y -loglevel error \
		-f lavfi \
		-i "testsrc2=size=${FFMPEG_WIDTH}x${FFMPEG_HEIGHT}:rate=${FFMPEG_FPS}:duration=${FFMPEG_DURATION}" \
		-c:v "$encoder" -pix_fmt yuv420p -an -f "$format" "$tmp"
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

	path=$(generated_input_path "$codec" "$ext")
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

run_probe_components()
{
	local decoders="$OUT/ffmpeg-decoders.txt"
	local encoders="$OUT/ffmpeg-encoders.txt"
	local filters="$OUT/ffmpeg-filters.txt"
	local version="$OUT/ffmpeg-version.txt"
	local h264_decoder_help="$OUT/ffmpeg-h264-rkmpp-decoder-help.txt"
	local h264_encoder_help="$OUT/ffmpeg-h264-rkmpp-encoder-help.txt"
	local hevc_encoder_help="$OUT/ffmpeg-hevc-rkmpp-encoder-help.txt"
	local scale_help="$OUT/ffmpeg-scale-rkrga-help.txt"
	local vpp_help="$OUT/ffmpeg-vpp-rkrga-help.txt"
	local overlay_help="$OUT/ffmpeg-overlay-rkrga-help.txt"

	"$FF" -hide_banner -version > "$version" 2>&1
	"$FF" -hide_banner -decoders > "$decoders" 2>&1
	"$FF" -hide_banner -encoders > "$encoders" 2>&1
	"$FF" -hide_banner -filters > "$filters" 2>&1
	"$FF" -hide_banner -h decoder=h264_rkmpp > "$h264_decoder_help" 2>&1
	"$FF" -hide_banner -h encoder=h264_rkmpp > "$h264_encoder_help" 2>&1
	"$FF" -hide_banner -h encoder=hevc_rkmpp > "$hevc_encoder_help" 2>&1
	"$FF" -hide_banner -h filter=scale_rkrga > "$scale_help" 2>&1
	"$FF" -hide_banner -h filter=vpp_rkrga > "$vpp_help" 2>&1
	"$FF" -hide_banner -h filter=overlay_rkrga > "$overlay_help" 2>&1

	head -1 "$version"
	require_pattern "$decoders" '[[:space:]]h264_rkmpp[[:space:]]' "h264_rkmpp decoder"
	require_pattern "$decoders" '[[:space:]]hevc_rkmpp[[:space:]]' "hevc_rkmpp decoder"
	require_pattern "$encoders" '[[:space:]]h264_rkmpp[[:space:]]' "h264_rkmpp encoder"
	require_pattern "$encoders" '[[:space:]]hevc_rkmpp[[:space:]]' "hevc_rkmpp encoder"
	require_pattern "$filters" '[[:space:]]scale_rkrga[[:space:]]' "scale_rkrga filter"
	require_pattern "$filters" '[[:space:]]vpp_rkrga[[:space:]]' "vpp_rkrga filter"
	require_pattern "$filters" '[[:space:]]overlay_rkrga[[:space:]]' "overlay_rkrga filter"
	require_pattern "$h264_decoder_help" 'afbc' "rkmpp decoder afbc option"
	require_pattern "$h264_decoder_help" 'buf_mode' "rkmpp decoder buf_mode option"
	require_pattern "$h264_decoder_help" 'fast_parse' "rkmpp decoder fast_parse option"
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

	info=$("$PROBE" -hide_banner -v error -select_streams v:0 \
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
	local output="$OUT/artifacts/$case_name.$output_format"

	input=$(ensure_input "$input_codec")
	rm -f "$output"
	timeout "$FFMPEG_TIMEOUT" "$FF" -hide_banner -y -loglevel info \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-i "$input" \
		-vf "scale_rkrga=w=${output_width}:h=${output_height}:format=nv12:force_original_aspect_ratio=disable" \
		-c:v "$output_encoder" -b:v "$bitrate" -f "$output_format" "$output"

	probe_check "$output" "$output_codec" "$output_width" "$output_height"
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
	local output="$OUT/artifacts/$case_name.$output_format"

	rm -f "$output"
	timeout "$FFMPEG_TIMEOUT" "$FF" -hide_banner -y -loglevel info \
		-f lavfi \
		-i "testsrc2=size=${output_width}x${output_height}:rate=${FFMPEG_FPS}:duration=${FFMPEG_DURATION}" \
		-pix_fmt nv12 \
		-c:v "$output_encoder" "$@" -b:v "$bitrate" -f "$output_format" "$output"

	probe_check "$output" "$output_codec" "$output_width" "$output_height"
	record_artifact required "$case_name" "encoded-$output_codec" "$output"
}

run_decode_null()
{
	local case_name=$1
	local input_codec=$2
	local decoder=$3
	shift 3
	local input

	input=$(ensure_input "$input_codec")
	timeout "$FFMPEG_TIMEOUT" "$FF" -hide_banner -y -loglevel info \
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
	local output="$OUT/artifacts/$case_name.$output_format"

	input=$(ensure_input "$input_codec")
	rm -f "$output"
	timeout "$FFMPEG_TIMEOUT" "$FF" -hide_banner -y -loglevel info \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v "$input_decoder" \
		-i "$input" \
		-vf "$filter" \
		-c:v "$output_encoder" -b:v "$bitrate" -f "$output_format" "$output"

	probe_check "$output" "$output_codec" "$output_width" "$output_height"
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
	local output="$OUT/artifacts/$case_name.$output_format"

	input=$(ensure_input "$input_codec")
	rm -f "$output"
	timeout "$FFMPEG_TIMEOUT" "$FF" -hide_banner -y -loglevel info \
		-hwaccel rkmpp -hwaccel_output_format drm_prime \
		-c:v "$input_decoder" "$@" \
		-i "$input" \
		-vf "$filter" \
		-c:v "$output_encoder" -b:v "$bitrate" -f "$output_format" "$output"

	probe_check "$output" "$output_codec" "$output_width" "$output_height"
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
	local output="$OUT/artifacts/$case_name.$output_format"

	input=$(ensure_input "$input_codec")
	rm -f "$output"
	timeout "$FFMPEG_TIMEOUT" "$FF" -hide_banner -y -loglevel info \
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
	record_artifact diagnostic "$case_name" "encoded-$output_codec" "$output"
}

case_known()
{
	case "$1" in
	ffmpeg_probe_rkmpp_rkrga | \
	ffmpeg_decode_h264_extbuf_to_null | \
	ffmpeg_decode_hevc_afbc_to_null | \
	ffmpeg_encode_h264_options | \
	ffmpeg_encode_hevc_options | \
	ffmpeg_transcode_h264_to_hevc_rkrga | \
	ffmpeg_transcode_hevc_to_h264_rkrga | \
	ffmpeg_filter_scale_rkrga_core_async_afbc | \
	ffmpeg_filter_vpp_rkrga_crop_transpose | \
	ffmpeg_transcode_h264_afbc_rga_to_hevc | \
	ffmpeg_filter_overlay_rkrga_alpha)
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
		run_decode_null "$case_name" h264 h264_rkmpp \
			-deint 0 -fast_parse 0 -buf_mode ext -afbc off
		;;
	ffmpeg_decode_hevc_afbc_to_null)
		run_decode_null "$case_name" hevc hevc_rkmpp \
			-deint 0 -fast_parse 1 -buf_mode half -afbc on
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
	ffmpeg_transcode_h264_afbc_rga_to_hevc)
		run_filter_transcode_with_decoder_opts "$case_name" h264 h264_rkmpp hevc hevc_rkmpp hevc \
			1280 720 4M \
			"scale_rkrga=w=1280:h=720:format=nv12:force_original_aspect_ratio=disable:async_depth=2" \
			-afbc rga -buf_mode half
		;;
	ffmpeg_filter_overlay_rkrga_alpha)
		run_overlay_transcode "$case_name" h264 h264_rkmpp hevc hevc_rkmpp hevc \
			1920 1080 4M \
			"[0:v][1:v]overlay_rkrga=x=64:y=32:alpha=192:alpha_format=straight:format=nv12:core=rga3_core0:async_depth=0[out]"
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
	local log="$OUT/$case_name.log"
	local status_file="$OUT/$case_name.status"
	local start
	local end
	local elapsed
	local status
	local result

	if [ -z "$case_name" ]; then
		return
	fi

	start=$(suite_now_ns)
	CURRENT_CLASS=$class
	set +e
	run_case_payload "$case_name" > "$log" 2>&1
	status=$?
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

if [ "$FFMPEG_VALIDATE_CASES" = "1" ]; then
	validate_cases
	exit $?
fi

if [ ! -e /dev/mpp_service ]; then
	echo "SKIP: /dev/mpp_service is absent on this boot"
	exit 77
fi
if [ ! -e /dev/rga ]; then
	echo "SKIP: /dev/rga is absent on this boot"
	exit 77
fi

if [ ! -x "$FF" ]; then
	echo "Missing ffmpeg binary: $FF" >&2
	exit 2
fi
if [ ! -x "$PROBE" ]; then
	echo "Missing ffprobe binary: $PROBE" >&2
	exit 2
fi

if [ -d "$STAGE/lib" ]; then
	export LD_LIBRARY_PATH="$STAGE/lib:${LD_LIBRARY_PATH:-}"
fi

mkdir -p "$OUT/artifacts" "$FFMPEG_GENERATED_INPUT_CACHE"
printf "profile\tclass\tcase\tstatus\telapsed_s\tresult\n" > "$summary"
printf "profile\tclass\tcase\tkind\tbytes\tsha256\tpath\n" > "$artifact_summary"

snapshot_debugfs before
debugfs_counter_snapshot "$OUT/debugfs-counters-before.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite

for case_name in $required_cases; do
	run_case required "$case_name"
done

for case_name in $diagnostic_cases; do
	run_case diagnostic "$case_name"
done

snapshot_debugfs after
debugfs_counter_snapshot "$OUT/debugfs-counters-after.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite
debugfs_counter_delta "$OUT/debugfs-counters-before.tsv" \
	"$OUT/debugfs-counters-after.tsv" \
	"$OUT/debugfs-counters-delta.tsv"
dmesg | tail -n 500 > "$OUT/dmesg-tail.txt" 2>/dev/null || true

echo "$OUT"

if [ "$failed" -ne 0 ]; then
	echo "FAIL: one or more required ffmpeg-rockchip cases failed; see $summary" >&2
	exit 1
fi

exit 0
