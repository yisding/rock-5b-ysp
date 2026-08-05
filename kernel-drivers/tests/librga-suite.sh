#!/usr/bin/env bash
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
BIN_DIR=${RGA_BIN_DIR:-"$CONFORMANCE_ROOT/out/librga-samples/bin"}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-librga-suite"}
# Empty means use the installed librga through the system dynamic loader. Set
# LIBRGA_LIBDIR only for an explicit staged or legacy-library comparison.
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-}
RGA_CAPTURE_ARTIFACTS=${RGA_CAPTURE_ARTIFACTS:-1}
RGA_ENABLE_YSP_SMOKE=${RGA_ENABLE_YSP_SMOKE:-1}
RGA_REQUIRE_YSP_SMOKE=${RGA_REQUIRE_YSP_SMOKE:-1}
LIBRGA_FORCE_RGA_USERPTR_IOMMU=${LIBRGA_FORCE_RGA_USERPTR_IOMMU:-${LIBRGA_FORCE_ROUTE_B:-0}}
LIBRGA_ENABLE_VENDOR_HEAP_CASES=${LIBRGA_ENABLE_VENDOR_HEAP_CASES:-0}
LIBRGA_SUITE_VALIDATE_LOG_PARSER=${LIBRGA_SUITE_VALIDATE_LOG_PARSER:-0}
LIBRGA_SUITE_VALIDATE_CASES=${LIBRGA_SUITE_VALIDATE_CASES:-0}
rga_userptr_iommu_force_path=
rga_userptr_iommu_force_prev=

case "$PROFILE" in
*rewrite*)
	: "${LIBRGA_SMOKE_ENABLE_PHYSICAL_PROBE:=1}"
	: "${LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT:=1}"
	: "${LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT:=1}"
	export LIBRGA_SMOKE_ENABLE_PHYSICAL_PROBE
	export LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT
	export LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT
	;;
esac

librga_sample_log_failed()
{
	# Several official samples return the failed IM_STATUS value (zero) from
	# main(), so their process status alone cannot distinguish success.
	grep -aiEq -- \
		'running failed|Fatal error:|check error!|ioctl err|(^|[^[:alpha:]])fail(ed|ure)?([^[:alpha:]]|$)' \
		"${1:--}"
}

librga_sample_log_succeeded()
{
	# The official demos use IM_STATUS_SUCCESS (numeric value 1) as main()'s
	# return value. Require their explicit terminal success message before
	# translating that nonzero shell status into success.
	grep -aiEq -- 'running success!' "${1:--}"
}

classify_librga_sample_status()
{
	local status=$1
	local log=$2

	# A fatal diagnostic wins even when the demo returned zero or printed an
	# earlier success line. Conversely, normalize status 1 only when the demo
	# explicitly reports that its operation completed successfully.
	if librga_sample_log_failed "$log"; then
		printf '%s\n' log-fail
	elif [ "$status" = "1" ] && librga_sample_log_succeeded "$log"; then
		printf '%s\n' 0
	else
		printf '%s\n' "$status"
	fi
}

validate_librga_sample_log_parser()
{
	local classified
	local line

	while IFS= read -r line; do
		if ! printf '%s\n' "$line" | librga_sample_log_failed; then
			printf 'FAIL: librga log parser missed fatal line: %s\n' "$line" >&2
			return 1
		fi
	done <<'EOF'
rga_copy_demo running failed, Fatal error: Failed to call RockChipRga interface
90, check error! Unsupported function
update palette table mode ioctl err
failed to get phy address: Invalid argument
EOF

	while IFS= read -r line; do
		if printf '%s\n' "$line" | librga_sample_log_failed; then
			printf 'FAIL: librga log parser rejected benign line: %s\n' "$line" >&2
			return 1
		fi
	done <<'EOF'
rga_copy_demo running success!
Could not open /usr/data/src/1280x720.rgb
src image read err
EOF

	librga_parser_tmp_log=$(mktemp "${TMPDIR:-/tmp}/librga-status.XXXXXX")
	trap 'rm -f "$librga_parser_tmp_log"' EXIT
	printf '%s\n' 'rga_copy_demo running success!' \
		> "$librga_parser_tmp_log"
	classified=$(classify_librga_sample_status 1 \
		"$librga_parser_tmp_log")
	if [ "$classified" != "0" ]; then
		printf 'FAIL: librga status classifier did not normalize explicit success: %s\n' \
			"$classified" >&2
		return 1
	fi

	printf '%s\n' \
		'rga_copy_demo running success!' \
		'rga_copy_demo running failed, Fatal error: submit failed' \
		> "$librga_parser_tmp_log"
	classified=$(classify_librga_sample_status 1 \
		"$librga_parser_tmp_log")
	if [ "$classified" != "log-fail" ]; then
		printf 'FAIL: librga status classifier let success hide a fatal line: %s\n' \
			"$classified" >&2
		return 1
	fi

	printf '%s\n' 'Could not open /data/input.bin' \
		> "$librga_parser_tmp_log"
	classified=$(classify_librga_sample_status 1 \
		"$librga_parser_tmp_log")
	if [ "$classified" != "1" ]; then
		printf 'FAIL: librga status classifier normalized status without explicit success: %s\n' \
			"$classified" >&2
		return 1
	fi

	echo "PASS: librga sample log parser"
}

if [ "$LIBRGA_SUITE_VALIDATE_LOG_PARSER" = "1" ]; then
	validate_librga_sample_log_parser
	exit
fi

required_cases_default="
ysp_librga_smoke
rga_copy_demo
rga_copy_drm_fourcc_demo
rga_copy_fbc_demo
rga_copy_tile_demo
rga_copy_splice_demo
rga_copy_splice_c_demo
rga_copy_splice_task_demo
rga_crop_demo
rga_crop_rect_demo
rga_resize_demo
rga_resize_rect_demo
rga_resize_config_interpolation_demo
rga_cvtcolor_demo
rga_cvtcolor_gray256_demo
rga_alpha_demo
rga_alpha_3channel_demo
rga_alpha_yuv_demo
rga_alpha_colorkey_demo
rga_alpha_rgba5551_demo
rga_alpha_global_alpha_demo
rga_transform_rotate_demo
rga_transform_flip_demo
rga_transform_rotate_flip_demo
rga_transform_center_rotate_demo
rga_async_demo
rga_config_single_core_demo
rga_config_thread_core_demo
rga_allocator_malloc_demo
rga_allocator_dma_cache_demo
rga_allocator_drm_demo
rga_mosaic_demo
rga_rop_demo
rga_palette_demo
"

# These official samples hard-code vendor-only heap nodes that are absent on
# the upstream-style RK3588 kernel. Keep them available for a matching BSP
# environment without making missing allocator types fail the default suite.
vendor_heap_cases_default="
rga_resize_uv_downsampling_demo
rga_cvtcolor_csc_demo
rga_fill_demo
rga_fill_rectangle_demo
rga_fill_rectangle_array_demo
rga_fill_rectangle_task_demo
rga_fill_rectangle_task_array_demo
rga_alpha_osd_demo
rga_allocator_dma_demo
rga_allocator_dma32_demo
rga_padding_demo
rga_gauss_demo
rga_gauss_matrix_demo
"

diagnostic_cases_default="
rga_allocator_drm_phy_demo
rga_allocator_graphicbuffer_demo
rga_allocator_1106_cma_demo
rga_cfa_demo
rga_cfa_a2_demo
rga_cfa_bcsh_demo
"

if [ "$LIBRGA_ENABLE_VENDOR_HEAP_CASES" = "1" ]; then
	required_cases_default="$required_cases_default
$vendor_heap_cases_default"
fi

if [ "$RGA_ENABLE_YSP_SMOKE" != "1" ] &&
	[ "$RGA_REQUIRE_YSP_SMOKE" != "1" ]; then
	required_cases_default=$(printf "%s\n" "$required_cases_default" |
		awk '$1 != "ysp_librga_smoke"')
elif [ "$RGA_REQUIRE_YSP_SMOKE" != "1" ]; then
	required_cases_default=$(printf "%s\n" "$required_cases_default" |
		awk '$1 != "ysp_librga_smoke"')
	diagnostic_cases_default="$diagnostic_cases_default
ysp_librga_smoke"
fi

required_cases=${RGA_REQUIRED_CASES:-$required_cases_default}
diagnostic_cases=${RGA_DIAGNOSTIC_CASES:-$diagnostic_cases_default}
failed=0

validate_librga_case_lists()
{
	local case_name
	local found

	for case_name in $vendor_heap_cases_default; do
		found=0
		if printf '%s\n' "$required_cases_default" |
			grep -qx -- "$case_name"; then
			found=1
		fi
		if [ "$LIBRGA_ENABLE_VENDOR_HEAP_CASES" = "1" ] &&
			[ "$found" != "1" ]; then
			printf 'FAIL: opt-in vendor heap case is absent: %s\n' \
				"$case_name" >&2
			return 1
		fi
		if [ "$LIBRGA_ENABLE_VENDOR_HEAP_CASES" != "1" ] &&
			[ "$found" = "1" ]; then
			printf 'FAIL: vendor heap case leaked into defaults: %s\n' \
				"$case_name" >&2
			return 1
		fi
	done

	printf 'PASS: librga default cases (vendor heaps %s)\n' \
		"$LIBRGA_ENABLE_VENDOR_HEAP_CASES"
}

if [ "$LIBRGA_SUITE_VALIDATE_CASES" = "1" ]; then
	validate_librga_case_lists
	exit
fi

# shellcheck disable=SC2329 # Invoked through the EXIT trap below.
restore_rga_userptr_iommu_force()
{
	if [ -n "$rga_userptr_iommu_force_path" ] &&
		[ -n "$rga_userptr_iommu_force_prev" ] &&
		[ -e "$rga_userptr_iommu_force_path" ]; then
		printf "%s\n" "$rga_userptr_iommu_force_prev" \
			> "$rga_userptr_iommu_force_path" 2>/dev/null || true
	fi
}

setup_rga_userptr_iommu_force()
{
	local path

	if [ "$LIBRGA_FORCE_RGA_USERPTR_IOMMU" != "1" ]; then
		return
	fi

	for path in \
		/sys/kernel/debug/rk_rga_rewrite/userptr_iommu/force_remap \
		/sys/kernel/debug/rkrga/userptr_iommu/force_remap \
		/sys/kernel/debug/rk_rga_rewrite/route_b/force_remap \
		/sys/kernel/debug/rkrga/route_b/force_remap; do
		if [ -e "$path" ]; then
			rga_userptr_iommu_force_path=$path
			break
		fi
	done

	if [ -z "$rga_userptr_iommu_force_path" ]; then
		echo "LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 but no RGA userptr-IOMMU force_remap debugfs knob is present" >&2
		exit 2
	fi

	rga_userptr_iommu_force_prev=$(cat "$rga_userptr_iommu_force_path" 2>/dev/null || true)
	case "$rga_userptr_iommu_force_prev" in
	0|1) ;;
	*) rga_userptr_iommu_force_prev=0 ;;
	esac

	printf "1\n" > "$rga_userptr_iommu_force_path"
}

trap restore_rga_userptr_iommu_force EXIT

if [ ! -e /dev/rga ]; then
	echo "SKIP: /dev/rga is absent on this boot"
	exit 77
fi

if [ ! -d "$BIN_DIR" ]; then
	echo "Missing $BIN_DIR. Run ../rock-5b/build/rockchip-conformance/scripts/build-librga-samples.sh first." >&2
	exit 2
fi

mkdir -p "$OUT"
summary="$OUT/summary.tsv"
artifact_dir="$OUT/artifacts"
artifact_summary="$OUT/artifacts.tsv"
printf "profile\tclass\tcase\tstatus\telapsed_s\tresult\n" > "$summary"
printf "profile\tclass\tcase\tkind\tbytes\tsha256\tpath\n" > "$artifact_summary"

if ! suite_dmesg_start "$OUT"; then
	echo "FAIL: dmesg is required but unreadable" >&2
	exit 1
fi
mkdir -p "$artifact_dir"

if [ -n "$LIBRGA_LIBDIR" ]; then
	export LD_LIBRARY_PATH="$LIBRGA_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

snapshot_debugfs()
{
	local label=$1
	local target="$OUT/debugfs-$label.txt"
	local path

	: > "$target"
	for path in /sys/kernel/debug/rk_rga_rewrite /sys/kernel/debug/rkrga; do
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

record_case_artifacts()
{
	local class=$1
	local case_name=$2
	local dir=$3
	local file
	local kind
	local bytes
	local sha

	if [ "$RGA_CAPTURE_ARTIFACTS" != "1" ] || [ ! -d "$dir" ]; then
		return
	fi

	while IFS= read -r file; do
		kind=$(basename "$file")
		kind=${kind%.bin}
		bytes=$(wc -c < "$file" | tr -d '[:space:]')
		sha=$(sha256sum "$file" | awk '{ print $1 }')
		printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
			"$PROFILE" "$class" "$case_name" "$kind" \
			"$bytes" "$sha" "$file" >> "$artifact_summary"
	done < <(find "$dir" -maxdepth 1 -type f -name '*.bin' | sort)
}

run_case()
{
	local class=$1
	local case_name=$2
	local exe="$BIN_DIR/$case_name"
	local case_artifact_dir="$artifact_dir/$case_name"
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

	if [ "$case_name" = "ysp_librga_smoke" ]; then
		exe="$TEST_DIR/librga-smoke.sh"
	fi

	if [ ! -x "$exe" ]; then
		printf "missing\n" > "$status_file"
		printf "%s\t%s\t%s\tmissing\t0\tmissing\n" \
			"$PROFILE" "$class" "$case_name" >> "$summary"
		if [ "$class" = "required" ]; then
			failed=1
		fi
		return
	fi

	rm -rf "$case_artifact_dir"
	mkdir -p "$case_artifact_dir"
	start=$(suite_now_ns)
	set +e
	if [ "$case_name" = "ysp_librga_smoke" ]; then
		CONFORMANCE_ROOT="$CONFORMANCE_ROOT" \
		LIBRGA_LIBDIR="$LIBRGA_LIBDIR" \
		LIBRGA_SMOKE_ARTIFACT_DIR="$case_artifact_dir" \
			"$exe" > "$log" 2>&1
	else
		"$exe" > "$log" 2>&1
	fi
	status=$?
	set -e
	end=$(suite_now_ns)
	elapsed=$(suite_elapsed_s "$start" "$end")

	if [ "$case_name" != "ysp_librga_smoke" ]; then
		status=$(classify_librga_sample_status "$status" "$log")
	fi
	printf "%s\n" "$status" > "$status_file"
	if [ "$status" = "0" ]; then
		result=pass
		record_case_artifacts "$class" "$case_name" "$case_artifact_dir"
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

setup_rga_userptr_iommu_force

snapshot_debugfs before
debugfs_counter_snapshot "$OUT/debugfs-counters-before.tsv" \
	rga /sys/kernel/debug/rk_rga_rewrite \
	rga_userptr_iommu /sys/kernel/debug/rk_rga_rewrite/userptr_iommu \
	rga_userptr_iommu_legacy /sys/kernel/debug/rk_rga_rewrite/route_b \
	rkrga_userptr_iommu /sys/kernel/debug/rkrga/userptr_iommu \
	rkrga_userptr_iommu_legacy /sys/kernel/debug/rkrga/route_b

for case_name in $required_cases; do
	run_case required "$case_name"
done

for case_name in $diagnostic_cases; do
	run_case diagnostic "$case_name"
done

snapshot_debugfs after
debugfs_counter_snapshot "$OUT/debugfs-counters-after.tsv" \
	rga /sys/kernel/debug/rk_rga_rewrite \
	rga_userptr_iommu /sys/kernel/debug/rk_rga_rewrite/userptr_iommu \
	rga_userptr_iommu_legacy /sys/kernel/debug/rk_rga_rewrite/route_b \
	rkrga_userptr_iommu /sys/kernel/debug/rkrga/userptr_iommu \
	rkrga_userptr_iommu_legacy /sys/kernel/debug/rkrga/route_b
debugfs_counter_delta "$OUT/debugfs-counters-before.tsv" \
	"$OUT/debugfs-counters-after.tsv" \
	"$OUT/debugfs-counters-delta.tsv"
if ! suite_dmesg_finish "$OUT"; then
	echo "FAIL: new fatal kernel-log signature or unavailable required dmesg; see $OUT/dmesg-scan.tsv" >&2
	failed=1
fi
tail -n 500 "$OUT/dmesg-after.txt" > "$OUT/dmesg-tail.txt" 2>/dev/null || true

echo "$OUT"

if [ "$failed" -ne 0 ]; then
	echo "FAIL: one or more required librga samples failed; see $summary" >&2
	exit 1
fi

exit 0
