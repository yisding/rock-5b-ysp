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
GST_PREFIX=${GST_PREFIX:-"$CONFORMANCE_ROOT/out/gstreamer-rockchip"}
GST_PLUGIN_DIR=${GST_PLUGIN_DIR:-"$GST_PREFIX/lib/gstreamer-1.0"}
GST_EVENT_HARNESS=${GST_EVENT_HARNESS:-"$GST_PREFIX/bin/gstreamer-event-harness"}
MPP_LIBDIR=${MPP_LIBDIR:-"$CONFORMANCE_ROOT/out/mpp/lib"}
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-"$CONFORMANCE_ROOT/sources/airockchip-librga/libs/Linux/gcc-aarch64"}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-gstreamer-suite"}
GST_GENERATED_INPUT_CACHE=${GST_GENERATED_INPUT_CACHE:-"$CONFORMANCE_ROOT/assets/gstreamer-generated"}
GST_CAPTURE_ARTIFACTS=${GST_CAPTURE_ARTIFACTS:-1}
GST_TIMEOUT=${GST_TIMEOUT:-120}
GST_NUM_BUFFERS=${GST_NUM_BUFFERS:-60}
GST_STATE_LOOPS=${GST_STATE_LOOPS:-4}
GST_STATE_LOOP_BUFFERS=${GST_STATE_LOOP_BUFFERS:-8}
GST_EOS_LOOPS=${GST_EOS_LOOPS:-4}
GST_EVENT_TRIGGER_BUFFERS=${GST_EVENT_TRIGGER_BUFFERS:-1}
GST_EVENT_POST_BUFFERS=${GST_EVENT_POST_BUFFERS:-1}
GST_EVENT_TIMEOUT_MS=${GST_EVENT_TIMEOUT_MS:-30000}
GST_EVENT_SLEEP_US=${GST_EVENT_SLEEP_US:-20000}
GST_CAPS_RENEGOTIATE_BUFFERS=${GST_CAPS_RENEGOTIATE_BUFFERS:-8}
GST_FORMAT_MATRIX_BUFFERS=${GST_FORMAT_MATRIX_BUFFERS:-16}
GST_GENERATED_INPUT_BUFFERS=${GST_GENERATED_INPUT_BUFFERS:-30}
GST_WIDTH=${GST_WIDTH:-320}
GST_HEIGHT=${GST_HEIGHT:-240}
GST_SCALE_WIDTH=${GST_SCALE_WIDTH:-256}
GST_SCALE_HEIGHT=${GST_SCALE_HEIGHT:-144}
GST_FRAMERATE=${GST_FRAMERATE:-30/1}
GST_ENABLE_DISPLAY_CASES=${GST_ENABLE_DISPLAY_CASES:-0}
GST_REQUIRE_DISPLAY_CASES=${GST_REQUIRE_DISPLAY_CASES:-0}
GST_ENABLE_VP9_CASES=${GST_ENABLE_VP9_CASES:-1}
GST_REQUIRE_VP9_CASES=${GST_REQUIRE_VP9_CASES:-1}
GST_ENABLE_PARALLEL_CASES=${GST_ENABLE_PARALLEL_CASES:-1}
GST_REQUIRE_PARALLEL_CASES=${GST_REQUIRE_PARALLEL_CASES:-1}
GST_DISPLAY_SINK=${GST_DISPLAY_SINK:-rkximagesink}
GST_DISPLAY_SINK_ARGS=${GST_DISPLAY_SINK_ARGS:-}

required_cases_default="
gst_inspect_rockchipmpp
gst_inspect_mppvideodec
gst_inspect_mpph264enc
gst_inspect_mpph265enc
enc_h264_nv12
enc_h265_nv12
enc_h264_control_props
enc_h265_control_props
enc_h264_qp_profile_props
enc_h265_qp_props
enc_h264_bgrx_rga_rotate
enc_h265_rgba_rga_scale
roundtrip_h264_nv12
roundtrip_h265_nv12
roundtrip_h264_rga_rotate
generated_dec_h264_fakesink
generated_dec_h265_fakesink
generated_dec_h264_dmabuf
generated_dec_h264_env_dmabuf
generated_dec_h265_dmabuf
generated_dec_h264_strict_props
generated_dec_h265_strict_props
generated_dec_h264_env_strict_props
generated_dec_h264_env_format_nv21
generated_dec_h264_renegotiate
generated_dec_h265_renegotiate
generated_dec_h264_rga_rotate
generated_dec_h265_rga_scale
generated_transcode_h264_to_h265
generated_transcode_h265_to_h264
generated_transcode_h264_rga_to_h265
generated_transcode_h264_dmabuf_to_h265
caps_renegotiate_h264_nv12
caps_renegotiate_h265_nv12
event_flush_enc_h264
event_flush_enc_h265
event_force_key_enc_h264
event_force_key_enc_h265
event_flush_dec_h264
event_flush_dec_h265
eos_loop_enc_h264
eos_loop_enc_h265
eos_loop_dec_h264
eos_loop_dec_h265
state_loop_h264_nv12
state_loop_roundtrip_h264
"

vp9_cases_default="
generated_dec_vp9_fakesink
generated_dec_vp9_dmabuf
"

vp9_diagnostic_cases_default="
generated_dec_vp9_rga_scale
generated_transcode_vp9_to_h264
"

parallel_cases_default="
parallel_enc_h264
parallel_roundtrip_h264
parallel_dec_h264
parallel_dec_h265
parallel_dec_mixed_h264_h265
parallel_transcode_mixed_h264_h265
"

diagnostic_cases_default="
gst_inspect_mppvp8enc
gst_inspect_mppjpegenc
gst_inspect_mppjpegdec
event_seek_enc_h264
event_seek_enc_h265
event_seek_dec_h264
event_seek_dec_h265
generated_dec_h264_afbc_fakesink
generated_dec_h265_afbc_fakesink
generated_dec_h264_env_fbc
generated_dec_h264_crop_meta
enc_vp8_nv12
enc_jpeg_nv12
roundtrip_jpeg_nv12
enc_h264_bgr16_rga_scale
enc_h264_rgb_rga_scale
enc_h264_bgr_rga_scale
enc_h264_bgra_rga_scale
enc_h264_rgbx_rga_scale
enc_h264_nv16_rga_scale
enc_h264_nv61_rga_scale
roundtrip_h264_rga_bgr16
roundtrip_h264_rga_rgb
roundtrip_h264_rga_bgr
roundtrip_h264_rga_nv21
roundtrip_h264_rga_nv16
roundtrip_h264_rga_nv61
roundtrip_h264_rga_i420
roundtrip_h264_rga_yv12
"

if [ "$GST_ENABLE_VP9_CASES" = "1" ]; then
	diagnostic_cases_default="$diagnostic_cases_default
$vp9_diagnostic_cases_default"
	if [ "$GST_REQUIRE_VP9_CASES" = "1" ]; then
		required_cases_default="$required_cases_default
$vp9_cases_default"
	else
		diagnostic_cases_default="$diagnostic_cases_default
$vp9_cases_default"
	fi
fi

if [ "$GST_ENABLE_PARALLEL_CASES" = "1" ] ||
	[ "$GST_REQUIRE_PARALLEL_CASES" = "1" ]; then
	if [ "$GST_REQUIRE_PARALLEL_CASES" = "1" ]; then
		required_cases_default="$required_cases_default
$parallel_cases_default"
	else
		diagnostic_cases_default="$diagnostic_cases_default
$parallel_cases_default"
	fi
fi

display_cases_default="
gst_inspect_display_sink
generated_dec_h264_display_dmabuf
generated_dec_h265_display_dmabuf
generated_dec_h264_display_afbc
generated_dec_h265_display_afbc
"

if [ "$GST_ENABLE_DISPLAY_CASES" = "1" ] ||
	[ "$GST_REQUIRE_DISPLAY_CASES" = "1" ]; then
	if [ "$GST_REQUIRE_DISPLAY_CASES" = "1" ]; then
		required_cases_default="$required_cases_default
$display_cases_default"
	else
		diagnostic_cases_default="$diagnostic_cases_default
$display_cases_default"
	fi
fi

if [ -n "${GST_H264_INPUT:-}" ]; then
	required_cases_default="$required_cases_default
dec_h264_fakesink
dec_h264_rga_rotate
transcode_h264_to_h265
transcode_h264_rga_to_h265
"
	diagnostic_cases_default="$diagnostic_cases_default
dec_h264_afbc_fakesink
"
fi

if [ -n "${GST_H265_INPUT:-}" ]; then
	required_cases_default="$required_cases_default
dec_h265_fakesink
dec_h265_rga_scale
transcode_h265_to_h264
"
	diagnostic_cases_default="$diagnostic_cases_default
dec_h265_afbc_fakesink
"
fi

required_cases=${GST_REQUIRED_CASES:-$required_cases_default}
diagnostic_cases=${GST_DIAGNOSTIC_CASES:-$diagnostic_cases_default}
failed=0

if [ ! -e /dev/mpp_service ]; then
	echo "SKIP: /dev/mpp_service is absent on this boot"
	exit 77
fi

if [ ! -e /dev/rga ]; then
	echo "SKIP: /dev/rga is absent on this boot"
	exit 77
fi

if ! command -v gst-launch-1.0 >/dev/null 2>&1; then
	echo "Missing gst-launch-1.0. Install GStreamer runtime tools first." >&2
	exit 2
fi

if ! command -v gst-inspect-1.0 >/dev/null 2>&1; then
	echo "Missing gst-inspect-1.0. Install GStreamer runtime tools first." >&2
	exit 2
fi

if [ ! -d "$GST_PLUGIN_DIR" ]; then
	echo "Missing $GST_PLUGIN_DIR. Run ../rockchip-conformance/scripts/build-gstreamer-rockchip.sh first." >&2
	exit 2
fi

mkdir -p "$OUT"
summary="$OUT/summary.tsv"
artifact_dir="$OUT/artifacts"
artifact_summary="$OUT/artifacts.tsv"
printf "profile\tclass\tcase\tstatus\telapsed_s\tresult\n" > "$summary"
printf "profile\tclass\tcase\tkind\tbytes\tsha256\tpath\n" > "$artifact_summary"
mkdir -p "$artifact_dir"
if [ -n "$GST_GENERATED_INPUT_CACHE" ]; then
	mkdir -p "$GST_GENERATED_INPUT_CACHE"
fi

export GST_PLUGIN_PATH="$GST_PLUGIN_DIR:${GST_PLUGIN_PATH:-}"
export GST_REGISTRY="${GST_REGISTRY:-"$OUT/gstreamer-registry.bin"}"
export LD_LIBRARY_PATH="$MPP_LIBDIR:$LIBRGA_LIBDIR:${LD_LIBRARY_PATH:-}"

CMD=()
BUILD_ERROR=
CURRENT_CLASS=
CURRENT_CASE=
CASE_ARTIFACT_KINDS=()
CASE_ARTIFACT_PATHS=()
GENERATED_INPUT_PATH=
GENERATED_ENCODER=
GENERATED_ENCODER_ARGS=()
GENERATED_MUXER=
GENERATED_PARSER=
GENERATED_SUFFIX=

safe_token()
{
	printf "%s" "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

generated_cache_path()
{
	local kind=$1
	local codec=$2
	local ext=$3
	local framerate
	local name

	framerate=$(safe_token "$GST_FRAMERATE")
	name="$kind-$codec-${GST_WIDTH}x${GST_HEIGHT}-${framerate}-${GST_GENERATED_INPUT_BUFFERS}"
	if [ "$kind" = "generated-renegotiate" ]; then
		name="$name-to-${GST_SCALE_WIDTH}x${GST_SCALE_HEIGHT}-${GST_CAPS_RENEGOTIATE_BUFFERS}"
	fi
	name="$name.$ext"

	if [ -n "$GST_GENERATED_INPUT_CACHE" ]; then
		printf "%s/%s" "$GST_GENERATED_INPUT_CACHE" "$name"
	else
		printf "%s/%s" "$OUT" "$name"
	fi
}

artifact_capture_enabled()
{
	[ "$GST_CAPTURE_ARTIFACTS" = "1" ] && [ -n "$CURRENT_CASE" ]
}

register_artifact()
{
	local kind=$1
	local path=$2

	CASE_ARTIFACT_KINDS+=("$kind")
	CASE_ARTIFACT_PATHS+=("$path")
}

append_artifact_or_fake_sink()
{
	local kind=$1
	local ext=$2
	local path

	if artifact_capture_enabled; then
		path="$artifact_dir/$(safe_token "$CURRENT_CASE").$(safe_token "$kind").$ext"
		CMD+=("!" filesink "location=$path")
		register_artifact "$kind" "$path"
	else
		CMD+=("!" fakesink sync=false)
	fi
}

get_var()
{
	local name=$1
	printf "%s" "${!name:-}"
}

require_var()
{
	local name=$1
	local value

	value=$(get_var "$name")
	if [ -z "$value" ]; then
		BUILD_ERROR="missing required env var $name"
		return 3
	fi

	printf "%s" "$value"
}

encoded_artifact_ext()
{
	case "$1" in
	mpph264enc)
		printf "h264"
		;;
	mpph265enc)
		printf "h265"
		;;
	*)
		printf "bin"
		;;
	esac
}

build_videotest_encode()
{
	local encoder=$1
	local format=$2
	local buffers=$3
	shift 3

	CMD=(
		gst-launch-1.0 -q
		videotestsrc "num-buffers=$buffers" is-live=false pattern=smpte
		"!" "video/x-raw,format=$format,width=$GST_WIDTH,height=$GST_HEIGHT,framerate=$GST_FRAMERATE"
		"!" "$encoder"
	)

	while [ "$#" -gt 0 ]; do
		CMD+=("$1")
		shift
	done

	CMD+=("!" fakesink sync=false)
}

build_videotest_roundtrip()
{
	local encoder=$1
	local parser=$2
	local buffers=$3
	shift 3

	CMD=(
		gst-launch-1.0 -q
		videotestsrc "num-buffers=$buffers" is-live=false pattern=smpte
		"!" "video/x-raw,format=NV12,width=$GST_WIDTH,height=$GST_HEIGHT,framerate=$GST_FRAMERATE"
		"!" "$encoder" zero-copy-pkt=true
		"!" "$parser"
		"!" mppvideodec
	)

	while [ "$#" -gt 0 ]; do
		CMD+=("$1")
		shift
	done

	CMD+=("!" fakesink sync=false)
}

build_videotest_jpeg_roundtrip()
{
	CMD=(
		gst-launch-1.0 -q
		videotestsrc "num-buffers=$GST_FORMAT_MATRIX_BUFFERS" is-live=false pattern=smpte
		"!" "video/x-raw,format=NV12,width=$GST_WIDTH,height=$GST_HEIGHT,framerate=$GST_FRAMERATE"
		"!" mppjpegenc
		"!" jpegparse
		"!" mppjpegdec
		"!" fakesink sync=false
	)
}

build_decode()
{
	local input_var=$1
	local parser=$2
	local input
	shift 2

	input=$(require_var "$input_var") || return $?
	CMD=(gst-launch-1.0 -q filesrc "location=$input" "!" "$parser" "!" mppvideodec)

	while [ "$#" -gt 0 ]; do
		CMD+=("$1")
		shift
	done

	append_artifact_or_fake_sink decoded raw
}

build_transcode()
{
	local input_var=$1
	local parser=$2
	local encoder=$3
	local ext
	local input
	shift 3

	input=$(require_var "$input_var") || return $?
	CMD=(gst-launch-1.0 -q filesrc "location=$input" "!" "$parser" "!" mppvideodec)

	while [ "$#" -gt 0 ]; do
		CMD+=("$1")
		shift
	done

	ext=$(encoded_artifact_ext "$encoder")
	CMD+=("!" "$encoder" zero-copy-pkt=true)
	append_artifact_or_fake_sink encoded "$ext"
}

select_generated_codec()
{
	local codec=$1

	case "$codec" in
	h264)
		GENERATED_ENCODER=mpph264enc
		GENERATED_ENCODER_ARGS=(zero-copy-pkt=true)
		GENERATED_MUXER=
		GENERATED_PARSER=h264parse
		GENERATED_SUFFIX=h264
		;;
	h265)
		GENERATED_ENCODER=mpph265enc
		GENERATED_ENCODER_ARGS=(zero-copy-pkt=true)
		GENERATED_MUXER=
		GENERATED_PARSER=h265parse
		GENERATED_SUFFIX=h265
		;;
	vp9)
		GENERATED_ENCODER=vp9enc
		GENERATED_ENCODER_ARGS=()
		GENERATED_MUXER=ivfmux
		GENERATED_PARSER=ivfparse
		GENERATED_SUFFIX=ivf
		;;
	*)
		printf "unknown generated codec: %s\n" "$codec" >&2
		return 4
		;;
	esac
}

ensure_generated_input()
{
	local codec=$1

	select_generated_codec "$codec" || return $?
	GENERATED_INPUT_PATH=$(generated_cache_path generated-input "$codec" "$GENERATED_SUFFIX")
	if [ -s "$GENERATED_INPUT_PATH" ]; then
		return 0
	fi

	CMD=(
		gst-launch-1.0 -q
		videotestsrc "num-buffers=$GST_GENERATED_INPUT_BUFFERS" is-live=false pattern=smpte
		"!" "video/x-raw,format=NV12,width=$GST_WIDTH,height=$GST_HEIGHT,framerate=$GST_FRAMERATE"
		"!" "$GENERATED_ENCODER" "${GENERATED_ENCODER_ARGS[@]}"
	)
	if [ -n "$GENERATED_MUXER" ]; then
		CMD+=("!" "$GENERATED_MUXER")
	else
		CMD+=("!" "$GENERATED_PARSER")
	fi
	CMD+=("!" filesink "location=$GENERATED_INPUT_PATH")
	printf "generating %s input: " "$codec"
	print_current_command
	run_current_command || return $?
	if [ ! -s "$GENERATED_INPUT_PATH" ]; then
		printf "generated %s input is empty: %s\n" "$codec" \
			"$GENERATED_INPUT_PATH" >&2
		return 1
	fi
}

generate_encoded_segment()
{
	local codec=$1
	local path=$2
	local width=$3
	local height=$4
	local pattern=$5
	local buffers=$6

	select_generated_codec "$codec" || return $?
	CMD=(
		gst-launch-1.0 -q
		videotestsrc "num-buffers=$buffers" is-live=false "pattern=$pattern"
		"!" "video/x-raw,format=NV12,width=$width,height=$height,framerate=$GST_FRAMERATE"
		"!" "$GENERATED_ENCODER" "${GENERATED_ENCODER_ARGS[@]}"
	)
	if [ -n "$GENERATED_MUXER" ]; then
		CMD+=("!" "$GENERATED_MUXER")
	else
		CMD+=("!" "$GENERATED_PARSER")
	fi
	CMD+=("!" filesink "location=$path")
	printf "generating %s segment %s: " "$codec" "$path"
	print_current_command
	run_current_command || return $?
	if [ ! -s "$path" ]; then
		printf "generated %s segment is empty: %s\n" "$codec" "$path" >&2
		return 1
	fi
}

ensure_generated_renegotiate_input()
{
	local codec=$1
	local first_path
	local second_path

	select_generated_codec "$codec" || return $?
	GENERATED_INPUT_PATH=$(generated_cache_path generated-renegotiate "$codec" "$GENERATED_SUFFIX")
	first_path="$OUT/generated-renegotiate-a.$GENERATED_SUFFIX"
	second_path="$OUT/generated-renegotiate-b.$GENERATED_SUFFIX"
	if [ -s "$GENERATED_INPUT_PATH" ]; then
		return 0
	fi

	generate_encoded_segment "$codec" "$first_path" "$GST_WIDTH" "$GST_HEIGHT" \
		smpte "$GST_CAPS_RENEGOTIATE_BUFFERS" || return $?
	generate_encoded_segment "$codec" "$second_path" "$GST_SCALE_WIDTH" \
		"$GST_SCALE_HEIGHT" ball "$GST_CAPS_RENEGOTIATE_BUFFERS" || return $?
	cat "$first_path" "$second_path" > "$GENERATED_INPUT_PATH"
	if [ ! -s "$GENERATED_INPUT_PATH" ]; then
		printf "generated %s renegotiation input is empty: %s\n" "$codec" \
			"$GENERATED_INPUT_PATH" >&2
		return 1
	fi
}

run_generated_decode()
{
	local codec=$1
	shift

	ensure_generated_input "$codec" || return $?
	CMD=(gst-launch-1.0 -q filesrc "location=$GENERATED_INPUT_PATH" "!" "$GENERATED_PARSER" "!" mppvideodec)

	while [ "$#" -gt 0 ]; do
		CMD+=("$1")
		shift
	done

	append_artifact_or_fake_sink decoded raw
	printf "decoding generated %s input: " "$codec"
	print_current_command
	run_current_command
}

run_generated_decode_env_strict()
{
	local codec=$1

	ensure_generated_input "$codec" || return $?
	CMD=(
		env
		GST_MPP_DEC_DEFAULT_IGNORE_ERROR=0
		GST_MPP_DEC_DEFAULT_FAST_MODE=0
		gst-launch-1.0 -q
		filesrc "location=$GENERATED_INPUT_PATH"
		"!" "$GENERATED_PARSER"
		"!" mppvideodec
	)
	append_artifact_or_fake_sink decoded raw
	printf "decoding generated %s input with strict env defaults: " "$codec"
	print_current_command
	run_current_command
}

run_generated_decode_env_dmabuf()
{
	local codec=$1

	ensure_generated_input "$codec" || return $?
	CMD=(
		env
		GST_MPP_DEC_DMA_FEATURE=1
		gst-launch-1.0 -q
		filesrc "location=$GENERATED_INPUT_PATH"
		"!" "$GENERATED_PARSER"
		"!" mppvideodec
	)
	append_artifact_or_fake_sink decoded raw
	printf "decoding generated %s input with DMA env default: " "$codec"
	print_current_command
	run_current_command
}

run_generated_decode_env_format()
{
	local codec=$1
	local format=$2

	ensure_generated_input "$codec" || return $?
	CMD=(
		env
		"GST_MPP_VIDEODEC_DEFAULT_FORMAT=$format"
		gst-launch-1.0 -q
		filesrc "location=$GENERATED_INPUT_PATH"
		"!" "$GENERATED_PARSER"
		"!" mppvideodec
	)
	append_artifact_or_fake_sink decoded raw
	printf "decoding generated %s input with %s env default format: " \
		"$codec" "$format"
	print_current_command
	run_current_command
}

run_generated_decode_env_fbc()
{
	local codec=$1

	ensure_generated_input "$codec" || return $?
	CMD=(
		env
		GST_MPP_VIDEODEC_DEFAULT_FBC=1
		gst-launch-1.0 -q
		filesrc "location=$GENERATED_INPUT_PATH"
		"!" "$GENERATED_PARSER"
		"!" mppvideodec
	)
	append_artifact_or_fake_sink decoded raw
	printf "decoding generated %s input with FBC env default: " "$codec"
	print_current_command
	run_current_command
}

run_generated_renegotiate_decode()
{
	local codec=$1
	shift

	ensure_generated_renegotiate_input "$codec" || return $?
	CMD=(gst-launch-1.0 -q filesrc "location=$GENERATED_INPUT_PATH" "!" "$GENERATED_PARSER" "!" mppvideodec)

	while [ "$#" -gt 0 ]; do
		CMD+=("$1")
		shift
	done

	append_artifact_or_fake_sink decoded-renegotiate raw
	printf "decoding generated renegotiating %s input: " "$codec"
	print_current_command
	run_current_command
}

run_event_generated_decode()
{
	local codec=$1
	local action=$2

	ensure_generated_input "$codec" || return $?
	build_event_generated_decode "$action"
	printf "event-driving generated %s decode (%s): " "$codec" "$action"
	print_current_command
	run_current_command
}

run_generated_transcode()
{
	local codec=$1
	local encoder=$2
	local ext
	shift 2

	ensure_generated_input "$codec" || return $?
	CMD=(gst-launch-1.0 -q filesrc "location=$GENERATED_INPUT_PATH" "!" "$GENERATED_PARSER" "!" mppvideodec)

	while [ "$#" -gt 0 ]; do
		CMD+=("$1")
		shift
	done

	ext=$(encoded_artifact_ext "$encoder")
	CMD+=("!" "$encoder" zero-copy-pkt=true)
	append_artifact_or_fake_sink encoded "$ext"
	printf "transcoding generated %s input: " "$codec"
	print_current_command
	run_current_command
}

append_display_sink()
{
	local -a sink_args=()

	CMD+=("!" "$GST_DISPLAY_SINK")
	if [ -n "$GST_DISPLAY_SINK_ARGS" ]; then
		read -r -a sink_args <<< "$GST_DISPLAY_SINK_ARGS"
		CMD+=("${sink_args[@]}")
	fi
	CMD+=(sync=false)
}

run_generated_display_decode()
{
	local codec=$1
	local mode=$2

	ensure_generated_input "$codec" || return $?
	CMD=(
		gst-launch-1.0 -q
		filesrc "location=$GENERATED_INPUT_PATH"
		"!" "$GENERATED_PARSER"
		"!" mppvideodec dma-feature=true
	)
	if [ "$mode" = "afbc" ]; then
		CMD+=(fbc=true)
	fi
	append_display_sink
	printf "displaying generated %s %s input through %s: " \
		"$codec" "$mode" "$GST_DISPLAY_SINK"
	print_current_command
	run_current_command
}

run_generated_parallel_decode()
{
	local first_codec=$1
	local second_codec=$2
	local first_path
	local first_parser
	local second_path
	local second_parser

	ensure_generated_input "$first_codec" || return $?
	first_path=$GENERATED_INPUT_PATH
	first_parser=$GENERATED_PARSER
	ensure_generated_input "$second_codec" || return $?
	second_path=$GENERATED_INPUT_PATH
	second_parser=$GENERATED_PARSER

	CMD=(
		gst-launch-1.0 -q
		filesrc "location=$first_path" "!" "$first_parser" "!" mppvideodec "!" fakesink sync=false
		filesrc "location=$second_path" "!" "$second_parser" "!" mppvideodec "!" fakesink sync=false
	)
	printf "parallel decoding generated %s/%s inputs: " \
		"$first_codec" "$second_codec"
	print_current_command
	run_current_command
}

run_generated_parallel_transcode()
{
	local first_codec=$1
	local first_encoder=$2
	local second_codec=$3
	local second_encoder=$4
	local first_path
	local first_parser
	local second_path
	local second_parser

	ensure_generated_input "$first_codec" || return $?
	first_path=$GENERATED_INPUT_PATH
	first_parser=$GENERATED_PARSER
	ensure_generated_input "$second_codec" || return $?
	second_path=$GENERATED_INPUT_PATH
	second_parser=$GENERATED_PARSER

	CMD=(
		gst-launch-1.0 -q
		filesrc "location=$first_path" "!" "$first_parser" "!" mppvideodec "!" "$first_encoder" zero-copy-pkt=true "!" fakesink sync=false
		filesrc "location=$second_path" "!" "$second_parser" "!" mppvideodec "!" "$second_encoder" zero-copy-pkt=true "!" fakesink sync=false
	)
	printf "parallel transcoding generated %s/%s inputs: " \
		"$first_codec" "$second_codec"
	print_current_command
	run_current_command
}

build_parallel_encode()
{
	CMD=(
		gst-launch-1.0 -q
		videotestsrc "num-buffers=$GST_NUM_BUFFERS" is-live=false pattern=ball
		"!" "video/x-raw,format=NV12,width=$GST_WIDTH,height=$GST_HEIGHT,framerate=$GST_FRAMERATE"
		"!" tee name=t
		t. "!" queue "!" mpph264enc zero-copy-pkt=true "!" fakesink sync=false
		t. "!" queue "!" mpph264enc zero-copy-pkt=true "!" fakesink sync=false
	)
}

build_parallel_roundtrip()
{
	CMD=(
		gst-launch-1.0 -q
		videotestsrc "num-buffers=$GST_NUM_BUFFERS" is-live=false pattern=ball
		"!" "video/x-raw,format=NV12,width=$GST_WIDTH,height=$GST_HEIGHT,framerate=$GST_FRAMERATE"
		"!" tee name=t
		t. "!" queue "!" mpph264enc zero-copy-pkt=true "!" h264parse "!" mppvideodec "!" fakesink sync=false
		t. "!" queue "!" mpph264enc zero-copy-pkt=true "!" h264parse "!" mppvideodec "!" fakesink sync=false
	)
}

build_caps_renegotiate_encode()
{
	local encoder=$1

	CMD=(
		gst-launch-1.0 -q
		concat name=c
		"!" "$encoder" zero-copy-pkt=true
		"!" fakesink sync=false
		videotestsrc "num-buffers=$GST_CAPS_RENEGOTIATE_BUFFERS" is-live=false pattern=smpte
		"!" "video/x-raw,format=NV12,width=$GST_WIDTH,height=$GST_HEIGHT,framerate=$GST_FRAMERATE"
		"!" queue
		"!" c.
		videotestsrc "num-buffers=$GST_CAPS_RENEGOTIATE_BUFFERS" is-live=false pattern=ball
		"!" "video/x-raw,format=NV12,width=$GST_SCALE_WIDTH,height=$GST_SCALE_HEIGHT,framerate=$GST_FRAMERATE"
		"!" queue
		"!" c.
	)
}

build_event_harness()
{
	local action=$1
	local target=$2
	local pipeline=$3

	CMD=(
		"$GST_EVENT_HARNESS"
		"--action=$action"
		"--target=$target"
		"--trigger-buffers=$GST_EVENT_TRIGGER_BUFFERS"
		"--post-buffers=$GST_EVENT_POST_BUFFERS"
		"--timeout-ms=$GST_EVENT_TIMEOUT_MS"
		"--pipeline=$pipeline"
	)
}

build_eos_loop_harness()
{
	local pipeline=$1

	CMD=(
		"$GST_EVENT_HARNESS"
		"--action=eos-loop"
		"--loops=$GST_EOS_LOOPS"
		"--timeout-ms=$GST_EVENT_TIMEOUT_MS"
		"--pipeline=$pipeline"
	)
}

build_event_encode()
{
	local action=$1
	local encoder=$2
	local pipeline

	pipeline="videotestsrc num-buffers=$GST_NUM_BUFFERS is-live=false pattern=smpte "
	pipeline+="! video/x-raw,format=NV12,width=$GST_WIDTH,height=$GST_HEIGHT,framerate=$GST_FRAMERATE "
	pipeline+="! identity sleep-time=$GST_EVENT_SLEEP_US "
	pipeline+="! $encoder name=target zero-copy-pkt=true "
	pipeline+="! fakesink sync=false"
	build_event_harness "$action" target "$pipeline"
}

build_event_generated_decode()
{
	local action=$1
	local pipeline

	pipeline="filesrc location=$GENERATED_INPUT_PATH "
	pipeline+="! $GENERATED_PARSER "
	pipeline+="! identity sleep-time=$GST_EVENT_SLEEP_US "
	pipeline+="! mppvideodec name=target "
	pipeline+="! fakesink sync=false"
	build_event_harness "$action" target "$pipeline"
}

build_eos_loop_encode()
{
	local encoder=$1
	local pipeline

	pipeline="videotestsrc num-buffers=$GST_STATE_LOOP_BUFFERS is-live=false pattern=smpte "
	pipeline+="! video/x-raw,format=NV12,width=$GST_WIDTH,height=$GST_HEIGHT,framerate=$GST_FRAMERATE "
	pipeline+="! $encoder zero-copy-pkt=true "
	pipeline+="! fakesink sync=false"
	build_eos_loop_harness "$pipeline"
}

build_eos_loop_generated_decode()
{
	local pipeline

	pipeline="filesrc location=$GENERATED_INPUT_PATH "
	pipeline+="! $GENERATED_PARSER "
	pipeline+="! mppvideodec "
	pipeline+="! fakesink sync=false"
	build_eos_loop_harness "$pipeline"
}

build_case_command()
{
	local case_name=$1

	BUILD_ERROR=
	CMD=()

	case "$case_name" in
	gst_inspect_rockchipmpp)
		CMD=(gst-inspect-1.0 rockchipmpp)
		;;
	gst_inspect_mppvideodec)
		CMD=(gst-inspect-1.0 mppvideodec)
		;;
	gst_inspect_mpph264enc)
		CMD=(gst-inspect-1.0 mpph264enc)
		;;
	gst_inspect_mpph265enc)
		CMD=(gst-inspect-1.0 mpph265enc)
		;;
	gst_inspect_mppvp8enc)
		CMD=(gst-inspect-1.0 mppvp8enc)
		;;
	gst_inspect_mppjpegenc)
		CMD=(gst-inspect-1.0 mppjpegenc)
		;;
	gst_inspect_mppjpegdec)
		CMD=(gst-inspect-1.0 mppjpegdec)
		;;
	gst_inspect_display_sink)
		CMD=(gst-inspect-1.0 "$GST_DISPLAY_SINK")
		;;
	enc_h264_nv12)
		build_videotest_encode mpph264enc NV12 "$GST_NUM_BUFFERS" zero-copy-pkt=true
		;;
	enc_h265_nv12)
		build_videotest_encode mpph265enc NV12 "$GST_NUM_BUFFERS" zero-copy-pkt=true
		;;
	enc_h264_control_props)
		build_videotest_encode mpph264enc NV12 "$GST_FORMAT_MATRIX_BUFFERS" \
			header-mode=each-idr sei-mode=one-frame rc-mode=vbr \
			gop=12 max-reenc=2 bps=250000 bps-min=100000 bps-max=500000 \
			max-pending=2 zero-copy-pkt=false
		;;
	enc_h265_control_props)
		build_videotest_encode mpph265enc NV12 "$GST_FORMAT_MATRIX_BUFFERS" \
			header-mode=each-idr sei-mode=one-frame rc-mode=vbr \
			gop=12 max-reenc=2 bps=250000 bps-min=100000 bps-max=500000 \
			max-pending=2 zero-copy-pkt=false
		;;
	enc_h264_qp_profile_props)
		build_videotest_encode mpph264enc NV12 "$GST_FORMAT_MATRIX_BUFFERS" \
			profile=main level=4.1 rc-mode=vbr qp-init=28 \
			qp-min=18 qp-max=42 qp-min-i=18 qp-max-i=38 \
			qp-delta-ip=3 zero-copy-pkt=true
		;;
	enc_h265_qp_props)
		build_videotest_encode mpph265enc NV12 "$GST_FORMAT_MATRIX_BUFFERS" \
			rc-mode=vbr qp-init=28 qp-min=18 qp-max=42 \
			qp-min-i=18 qp-max-i=38 qp-delta-ip=3 \
			zero-copy-pkt=true
		;;
	enc_vp8_nv12)
		build_videotest_encode mppvp8enc NV12 "$GST_FORMAT_MATRIX_BUFFERS"
		;;
	enc_jpeg_nv12)
		build_videotest_encode mppjpegenc NV12 "$GST_FORMAT_MATRIX_BUFFERS"
		;;
	enc_h264_bgrx_rga_rotate)
		build_videotest_encode mpph264enc BGRx "$GST_NUM_BUFFERS" \
			rotation=90 "width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" \
			zero-copy-pkt=true
		;;
	enc_h265_rgba_rga_scale)
		build_videotest_encode mpph265enc RGBA "$GST_NUM_BUFFERS" \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" \
			zero-copy-pkt=true
		;;
	enc_h264_bgr16_rga_scale)
		build_videotest_encode mpph264enc BGR16 "$GST_FORMAT_MATRIX_BUFFERS" \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" \
			zero-copy-pkt=true
		;;
	enc_h264_rgb_rga_scale)
		build_videotest_encode mpph264enc RGB "$GST_FORMAT_MATRIX_BUFFERS" \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" \
			zero-copy-pkt=true
		;;
	enc_h264_bgr_rga_scale)
		build_videotest_encode mpph264enc BGR "$GST_FORMAT_MATRIX_BUFFERS" \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" \
			zero-copy-pkt=true
		;;
	enc_h264_bgra_rga_scale)
		build_videotest_encode mpph264enc BGRA "$GST_FORMAT_MATRIX_BUFFERS" \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" \
			zero-copy-pkt=true
		;;
	enc_h264_rgbx_rga_scale)
		build_videotest_encode mpph264enc RGBx "$GST_FORMAT_MATRIX_BUFFERS" \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" \
			zero-copy-pkt=true
		;;
	enc_h264_nv16_rga_scale)
		build_videotest_encode mpph264enc NV16 "$GST_FORMAT_MATRIX_BUFFERS" \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" \
			zero-copy-pkt=true
		;;
	enc_h264_nv61_rga_scale)
		build_videotest_encode mpph264enc NV61 "$GST_FORMAT_MATRIX_BUFFERS" \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" \
			zero-copy-pkt=true
		;;
	roundtrip_h264_nv12)
		build_videotest_roundtrip mpph264enc h264parse "$GST_NUM_BUFFERS"
		;;
	roundtrip_h265_nv12)
		build_videotest_roundtrip mpph265enc h265parse "$GST_NUM_BUFFERS"
		;;
	roundtrip_h264_rga_rotate)
		build_videotest_roundtrip mpph264enc h264parse "$GST_NUM_BUFFERS" \
			rotation=90 "width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" format=BGRx
		;;
	roundtrip_jpeg_nv12)
		build_videotest_jpeg_roundtrip
		;;
	generated_dec_h264_fakesink)
		CMD=(__builtin_generated_decode h264)
		;;
	generated_dec_h265_fakesink)
		CMD=(__builtin_generated_decode h265)
		;;
	generated_dec_h264_dmabuf)
		CMD=(__builtin_generated_decode h264 dma-feature=true)
		;;
	generated_dec_h264_env_dmabuf)
		CMD=(__builtin_generated_decode_env_dmabuf h264)
		;;
	generated_dec_h265_dmabuf)
		CMD=(__builtin_generated_decode h265 dma-feature=true)
		;;
	generated_dec_h264_strict_props)
		CMD=(__builtin_generated_decode h264 fast-mode=false ignore-error=false)
		;;
	generated_dec_h265_strict_props)
		CMD=(__builtin_generated_decode h265 fast-mode=false ignore-error=false)
		;;
	generated_dec_h264_env_strict_props)
		CMD=(__builtin_generated_decode_env_strict h264)
		;;
	generated_dec_h264_env_format_nv21)
		CMD=(__builtin_generated_decode_env_format h264 NV21)
		;;
	generated_dec_vp9_fakesink)
		CMD=(__builtin_generated_decode vp9)
		;;
	generated_dec_vp9_dmabuf)
		CMD=(__builtin_generated_decode vp9 dma-feature=true)
		;;
	generated_dec_h264_renegotiate)
		CMD=(__builtin_generated_renegotiate_decode h264)
		;;
	generated_dec_h265_renegotiate)
		CMD=(__builtin_generated_renegotiate_decode h265)
		;;
	generated_dec_h264_rga_rotate)
		CMD=(__builtin_generated_decode h264 \
			rotation=90 "width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" format=BGRx)
		;;
	generated_dec_h265_rga_scale)
		CMD=(__builtin_generated_decode h265 \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" format=NV21)
		;;
	generated_dec_vp9_rga_scale)
		CMD=(__builtin_generated_decode vp9 \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" format=NV12)
		;;
	generated_transcode_h264_to_h265)
		CMD=(__builtin_generated_transcode h264 mpph265enc)
		;;
	generated_transcode_h265_to_h264)
		CMD=(__builtin_generated_transcode h265 mpph264enc)
		;;
	generated_transcode_vp9_to_h264)
		CMD=(__builtin_generated_transcode vp9 mpph264enc)
		;;
	generated_transcode_h264_rga_to_h265)
		CMD=(__builtin_generated_transcode h264 mpph265enc \
			rotation=90 "width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" format=NV12)
		;;
	generated_transcode_h264_dmabuf_to_h265)
		CMD=(__builtin_generated_transcode h264 mpph265enc dma-feature=true)
		;;
	generated_dec_h264_display_dmabuf)
		CMD=(__builtin_generated_display_decode h264 dmabuf)
		;;
	generated_dec_h265_display_dmabuf)
		CMD=(__builtin_generated_display_decode h265 dmabuf)
		;;
	generated_dec_h264_display_afbc)
		CMD=(__builtin_generated_display_decode h264 afbc)
		;;
	generated_dec_h265_display_afbc)
		CMD=(__builtin_generated_display_decode h265 afbc)
		;;
	caps_renegotiate_h264_nv12)
		build_caps_renegotiate_encode mpph264enc
		;;
	caps_renegotiate_h265_nv12)
		build_caps_renegotiate_encode mpph265enc
		;;
	event_flush_enc_h264)
		build_event_encode flush mpph264enc
		;;
	event_flush_enc_h265)
		build_event_encode flush mpph265enc
		;;
	event_force_key_enc_h264)
		build_event_encode force-key-unit mpph264enc
		;;
	event_force_key_enc_h265)
		build_event_encode force-key-unit mpph265enc
		;;
	event_flush_dec_h264)
		CMD=(__builtin_event_generated_decode h264 flush)
		;;
	event_flush_dec_h265)
		CMD=(__builtin_event_generated_decode h265 flush)
		;;
	eos_loop_enc_h264)
		build_eos_loop_encode mpph264enc
		;;
	eos_loop_enc_h265)
		build_eos_loop_encode mpph265enc
		;;
	eos_loop_dec_h264)
		CMD=(__builtin_eos_loop_generated_decode h264)
		;;
	eos_loop_dec_h265)
		CMD=(__builtin_eos_loop_generated_decode h265)
		;;
	event_seek_enc_h264)
		build_event_encode seek mpph264enc
		;;
	event_seek_enc_h265)
		build_event_encode seek mpph265enc
		;;
	event_seek_dec_h264)
		CMD=(__builtin_event_generated_decode h264 seek)
		;;
	event_seek_dec_h265)
		CMD=(__builtin_event_generated_decode h265 seek)
		;;
	generated_dec_h264_afbc_fakesink)
		CMD=(__builtin_generated_decode h264 fbc=true)
		;;
	generated_dec_h265_afbc_fakesink)
		CMD=(__builtin_generated_decode h265 fbc=true)
		;;
	generated_dec_h264_env_fbc)
		CMD=(__builtin_generated_decode_env_fbc h264)
		;;
	generated_dec_h264_crop_meta)
		CMD=(__builtin_generated_decode h264 "crop-rectangle=<16,16,160,120>")
		;;
	roundtrip_h264_rga_bgr16)
		build_videotest_roundtrip mpph264enc h264parse \
			"$GST_FORMAT_MATRIX_BUFFERS" format=BGR16
		;;
	roundtrip_h264_rga_rgb)
		build_videotest_roundtrip mpph264enc h264parse \
			"$GST_FORMAT_MATRIX_BUFFERS" format=RGB
		;;
	roundtrip_h264_rga_bgr)
		build_videotest_roundtrip mpph264enc h264parse \
			"$GST_FORMAT_MATRIX_BUFFERS" format=BGR
		;;
	roundtrip_h264_rga_nv21)
		build_videotest_roundtrip mpph264enc h264parse \
			"$GST_FORMAT_MATRIX_BUFFERS" format=NV21
		;;
	roundtrip_h264_rga_nv16)
		build_videotest_roundtrip mpph264enc h264parse \
			"$GST_FORMAT_MATRIX_BUFFERS" format=NV16
		;;
	roundtrip_h264_rga_nv61)
		build_videotest_roundtrip mpph264enc h264parse \
			"$GST_FORMAT_MATRIX_BUFFERS" format=NV61
		;;
	roundtrip_h264_rga_i420)
		build_videotest_roundtrip mpph264enc h264parse \
			"$GST_FORMAT_MATRIX_BUFFERS" format=I420
		;;
	roundtrip_h264_rga_yv12)
		build_videotest_roundtrip mpph264enc h264parse \
			"$GST_FORMAT_MATRIX_BUFFERS" format=YV12
		;;
	state_loop_h264_nv12)
		CMD=(__builtin_state_loop enc_h264_nv12 "loops=$GST_STATE_LOOPS")
		;;
	state_loop_roundtrip_h264)
		CMD=(__builtin_state_loop roundtrip_h264_nv12 "loops=$GST_STATE_LOOPS")
		;;
	parallel_enc_h264)
		build_parallel_encode
		;;
	parallel_roundtrip_h264)
		build_parallel_roundtrip
		;;
	parallel_dec_h264)
		CMD=(__builtin_generated_parallel_decode h264 h264)
		;;
	parallel_dec_h265)
		CMD=(__builtin_generated_parallel_decode h265 h265)
		;;
	parallel_dec_mixed_h264_h265)
		CMD=(__builtin_generated_parallel_decode h264 h265)
		;;
	parallel_transcode_mixed_h264_h265)
		CMD=(__builtin_generated_parallel_transcode h264 mpph265enc h265 mpph264enc)
		;;
	dec_h264_fakesink)
		build_decode GST_H264_INPUT h264parse
		;;
	dec_h265_fakesink)
		build_decode GST_H265_INPUT h265parse
		;;
	dec_h264_rga_rotate)
		build_decode GST_H264_INPUT h264parse \
			rotation=90 "width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" format=BGRx
		;;
	dec_h265_rga_scale)
		build_decode GST_H265_INPUT h265parse \
			"width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" format=NV21
		;;
	dec_h264_afbc_fakesink)
		build_decode GST_H264_INPUT h264parse fbc=true
		;;
	dec_h265_afbc_fakesink)
		build_decode GST_H265_INPUT h265parse fbc=true
		;;
	transcode_h264_to_h265)
		build_transcode GST_H264_INPUT h264parse mpph265enc
		;;
	transcode_h265_to_h264)
		build_transcode GST_H265_INPUT h265parse mpph264enc
		;;
	transcode_h264_rga_to_h265)
		build_transcode GST_H264_INPUT h264parse mpph265enc \
			rotation=90 "width=$GST_SCALE_WIDTH" "height=$GST_SCALE_HEIGHT" format=NV12
		;;
	*)
		BUILD_ERROR="unknown case $case_name"
		return 4
		;;
	esac
}

snapshot_state()
{
	local label=$1
	local target="$OUT/driver-state-$label.txt"
	local path

	: > "$target"
	for path in /proc/mpp_service /sys/kernel/debug/rk_mpp_rewrite \
		/sys/kernel/debug/rk_rga_rewrite /sys/kernel/debug/rkrga \
		/sys/kernel/debug/mpp_service; do
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

print_current_command()
{
	local arg

	for arg in "${CMD[@]}"; do
		printf "%q " "$arg"
	done
	printf "\n"
}

run_current_command()
{
	if [ "$GST_TIMEOUT" = "0" ]; then
		"${CMD[@]}"
	else
		timeout "$GST_TIMEOUT" "${CMD[@]}"
	fi
}

run_case_payload()
{
	local case_name=$1
	local i

	case "$case_name" in
	state_loop_h264_nv12)
		for i in $(seq 1 "$GST_STATE_LOOPS"); do
			printf "state-loop iteration %s/%s\n" "$i" "$GST_STATE_LOOPS"
			build_videotest_encode mpph264enc NV12 "$GST_STATE_LOOP_BUFFERS" zero-copy-pkt=true
			run_current_command || return $?
		done
		;;
	state_loop_roundtrip_h264)
		for i in $(seq 1 "$GST_STATE_LOOPS"); do
			printf "roundtrip state-loop iteration %s/%s\n" "$i" "$GST_STATE_LOOPS"
			build_videotest_roundtrip mpph264enc h264parse "$GST_STATE_LOOP_BUFFERS"
			run_current_command || return $?
		done
		;;
	generated_dec_h264_env_strict_props)
		run_generated_decode_env_strict "${CMD[1]}"
		;;
	generated_dec_h264_env_dmabuf)
		run_generated_decode_env_dmabuf "${CMD[1]}"
		;;
	generated_dec_h264_env_format_nv21)
		run_generated_decode_env_format "${CMD[1]}" "${CMD[2]}"
		;;
	generated_dec_h264_env_fbc)
		run_generated_decode_env_fbc "${CMD[1]}"
		;;
	generated_dec_h264_fakesink | generated_dec_h265_fakesink | \
	generated_dec_h264_dmabuf | generated_dec_h265_dmabuf | \
	generated_dec_h264_strict_props | generated_dec_h265_strict_props | \
	generated_dec_vp9_fakesink | generated_dec_vp9_dmabuf | \
	generated_dec_h264_rga_rotate | generated_dec_h265_rga_scale | \
	generated_dec_vp9_rga_scale | \
	generated_dec_h264_afbc_fakesink | generated_dec_h265_afbc_fakesink | \
	generated_dec_h264_crop_meta)
		run_generated_decode "${CMD[1]}" "${CMD[@]:2}"
		;;
	generated_dec_h264_renegotiate | generated_dec_h265_renegotiate)
		run_generated_renegotiate_decode "${CMD[1]}" "${CMD[@]:2}"
		;;
	event_flush_dec_h264 | event_flush_dec_h265 | \
	event_seek_dec_h264 | event_seek_dec_h265)
		run_event_generated_decode "${CMD[1]}" "${CMD[2]}"
		;;
	eos_loop_dec_h264 | eos_loop_dec_h265)
		ensure_generated_input "${CMD[1]}" || return $?
		build_eos_loop_generated_decode
		run_current_command
		;;
	generated_transcode_h264_to_h265 | generated_transcode_h265_to_h264 | \
	generated_transcode_h264_rga_to_h265 | \
	generated_transcode_h264_dmabuf_to_h265 | generated_transcode_vp9_to_h264)
		run_generated_transcode "${CMD[1]}" "${CMD[2]}" "${CMD[@]:3}"
		;;
	generated_dec_h264_display_dmabuf | generated_dec_h265_display_dmabuf | \
	generated_dec_h264_display_afbc | generated_dec_h265_display_afbc)
		run_generated_display_decode "${CMD[1]}" "${CMD[2]}"
		;;
	parallel_dec_h264 | parallel_dec_h265 | parallel_dec_mixed_h264_h265)
		run_generated_parallel_decode "${CMD[1]}" "${CMD[2]}"
		;;
	parallel_transcode_mixed_h264_h265)
		run_generated_parallel_transcode "${CMD[1]}" "${CMD[2]}" \
			"${CMD[3]}" "${CMD[4]}"
		;;
	*)
		case "${CMD[0]:-}" in
		__builtin_*)
			printf "internal error: unhandled builtin case %s (%s)\n" \
				"$case_name" "${CMD[0]}" >&2
			return 4
			;;
		esac
		run_current_command
		;;
	esac
}

command_exists()
{
	local exe=$1

	case "$exe" in
	__builtin_*)
		return 0
		;;
	*/*)
		[ -x "$exe" ]
		;;
	*)
		command -v "$exe" >/dev/null 2>&1
		;;
	esac
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

	if ! command_exists "${CMD[0]}"; then
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
	run_case_payload "$case_name" > "$log" 2>&1
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

snapshot_state before
debugfs_counter_snapshot "$OUT/debugfs-counters-before.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite

for case_name in $required_cases; do
	run_case required "$case_name"
done

for case_name in $diagnostic_cases; do
	run_case diagnostic "$case_name"
done

snapshot_state after
debugfs_counter_snapshot "$OUT/debugfs-counters-after.tsv" \
	mpp /sys/kernel/debug/rk_mpp_rewrite \
	rga /sys/kernel/debug/rk_rga_rewrite
debugfs_counter_delta "$OUT/debugfs-counters-before.tsv" \
	"$OUT/debugfs-counters-after.tsv" \
	"$OUT/debugfs-counters-delta.tsv"
dmesg | tail -n 500 > "$OUT/dmesg-tail.txt" 2>/dev/null || true

echo "$OUT"

if [ "$failed" -ne 0 ]; then
	echo "FAIL: one or more required GStreamer cases failed; see $summary" >&2
	exit 1
fi

exit 0
