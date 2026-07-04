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
STAGE=${STAGE:-/home/yi/Code/rock5b-kernel-debug/ffmpeg-stack}
FFMPEG_GENERATOR=${FFMPEG_GENERATOR:-ffmpeg}
FFMPEG_GENERATED_INPUT_CACHE=${FFMPEG_GENERATED_INPUT_CACHE:-"$CONFORMANCE_ROOT/assets/ffmpeg-generated"}
FFMPEG_GENERATE_INPUTS=${FFMPEG_GENERATE_INPUTS:-1}
FFMPEG_WIDTH=${FFMPEG_WIDTH:-1920}
FFMPEG_HEIGHT=${FFMPEG_HEIGHT:-1080}
FFMPEG_FPS=${FFMPEG_FPS:-30}
FFMPEG_DURATION=${FFMPEG_DURATION:-2}
FFMPEG_TIMEOUT=${FFMPEG_TIMEOUT:-180}

if [ -z "${FFDIR:-}" ]; then
	if [ -x "$REPO_ROOT/../ffmpeg-rockchip-81/ffmpeg" ]; then
		FFDIR="$REPO_ROOT/../ffmpeg-rockchip-81"
	else
		FFDIR="$REPO_ROOT/../ffmpeg-rockchip"
	fi
fi

FF=${FF:-"$FFDIR/ffmpeg"}
PROBE=${PROBE:-"$FFDIR/ffprobe"}

required_cases_default="
ffmpeg_probe_rkmpp_rkrga
ffmpeg_transcode_h264_to_hevc_rkrga
ffmpeg_transcode_hevc_to_h264_rkrga
"

diagnostic_cases_default="
"

required_cases=${FFMPEG_REQUIRED_CASES:-$required_cases_default}
diagnostic_cases=${FFMPEG_DIAGNOSTIC_CASES:-$diagnostic_cases_default}
failed=0

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
summary="$OUT/summary.tsv"
artifact_summary="$OUT/artifacts.tsv"
printf "profile\tclass\tcase\tstatus\telapsed_s\tresult\n" > "$summary"
printf "profile\tclass\tcase\tkind\tbytes\tsha256\tpath\n" > "$artifact_summary"

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

	"$FF" -hide_banner -version > "$version" 2>&1
	"$FF" -hide_banner -decoders > "$decoders" 2>&1
	"$FF" -hide_banner -encoders > "$encoders" 2>&1
	"$FF" -hide_banner -filters > "$filters" 2>&1

	head -1 "$version"
	require_pattern "$decoders" '[[:space:]]h264_rkmpp[[:space:]]' "h264_rkmpp decoder"
	require_pattern "$decoders" '[[:space:]]hevc_rkmpp[[:space:]]' "hevc_rkmpp decoder"
	require_pattern "$encoders" '[[:space:]]h264_rkmpp[[:space:]]' "h264_rkmpp encoder"
	require_pattern "$encoders" '[[:space:]]hevc_rkmpp[[:space:]]' "hevc_rkmpp encoder"
	require_pattern "$filters" '[[:space:]]scale_rkrga[[:space:]]' "scale_rkrga filter"
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

run_case_payload()
{
	local case_name=$1

	case "$case_name" in
	ffmpeg_probe_rkmpp_rkrga)
		run_probe_components
		;;
	ffmpeg_transcode_h264_to_hevc_rkrga)
		run_transcode "$case_name" h264 hevc hevc_rkmpp hevc 1280 720 4M
		;;
	ffmpeg_transcode_hevc_to_h264_rkrga)
		run_transcode "$case_name" hevc h264 h264_rkmpp h264 640 480 2M
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
