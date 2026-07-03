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
MPP_LIBDIR=${MPP_LIBDIR:-"$CONFORMANCE_ROOT/out/mpp/lib"}
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-"$CONFORMANCE_ROOT/sources/airockchip-librga/libs/Linux/gcc-aarch64"}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-gstreamer-suite"}
GST_TIMEOUT=${GST_TIMEOUT:-120}
GST_NUM_BUFFERS=${GST_NUM_BUFFERS:-60}
GST_STATE_LOOPS=${GST_STATE_LOOPS:-4}
GST_STATE_LOOP_BUFFERS=${GST_STATE_LOOP_BUFFERS:-8}
GST_FORMAT_MATRIX_BUFFERS=${GST_FORMAT_MATRIX_BUFFERS:-16}
GST_WIDTH=${GST_WIDTH:-320}
GST_HEIGHT=${GST_HEIGHT:-240}
GST_SCALE_WIDTH=${GST_SCALE_WIDTH:-256}
GST_SCALE_HEIGHT=${GST_SCALE_HEIGHT:-144}
GST_FRAMERATE=${GST_FRAMERATE:-30/1}

required_cases_default="
gst_inspect_rockchipmpp
gst_inspect_mppvideodec
gst_inspect_mpph264enc
gst_inspect_mpph265enc
enc_h264_nv12
enc_h265_nv12
enc_h264_bgrx_rga_rotate
enc_h265_rgba_rga_scale
roundtrip_h264_nv12
roundtrip_h265_nv12
roundtrip_h264_rga_rotate
state_loop_h264_nv12
state_loop_roundtrip_h264
"

diagnostic_cases_default="
parallel_enc_h264
parallel_roundtrip_h264
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
printf "profile\tclass\tcase\tstatus\telapsed_s\tresult\n" > "$summary"

export GST_PLUGIN_PATH="$GST_PLUGIN_DIR:${GST_PLUGIN_PATH:-}"
export GST_REGISTRY="${GST_REGISTRY:-"$OUT/gstreamer-registry.bin"}"
export LD_LIBRARY_PATH="$MPP_LIBDIR:$LIBRGA_LIBDIR:${LD_LIBRARY_PATH:-}"

CMD=()
BUILD_ERROR=

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

	CMD+=("!" fakesink sync=false)
}

build_transcode()
{
	local input_var=$1
	local parser=$2
	local encoder=$3
	local input
	shift 3

	input=$(require_var "$input_var") || return $?
	CMD=(gst-launch-1.0 -q filesrc "location=$input" "!" "$parser" "!" mppvideodec)

	while [ "$#" -gt 0 ]; do
		CMD+=("$1")
		shift
	done

	CMD+=("!" "$encoder" zero-copy-pkt=true "!" fakesink sync=false)
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
	enc_h264_nv12)
		build_videotest_encode mpph264enc NV12 "$GST_NUM_BUFFERS" zero-copy-pkt=true
		;;
	enc_h265_nv12)
		build_videotest_encode mpph265enc NV12 "$GST_NUM_BUFFERS" zero-copy-pkt=true
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
	*)
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
