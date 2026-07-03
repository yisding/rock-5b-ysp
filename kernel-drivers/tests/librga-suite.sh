#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$REPO_ROOT/../rockchip-conformance"}
PROFILE=${PROFILE:-${1:-rewrite}}
BIN_DIR=${RGA_BIN_DIR:-"$CONFORMANCE_ROOT/out/librga-samples/bin"}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-librga-suite"}
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-"$CONFORMANCE_ROOT/sources/airockchip-librga/libs/Linux/gcc-aarch64"}

required_cases_default="
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
rga_resize_uv_downsampling_demo
rga_cvtcolor_demo
rga_cvtcolor_csc_demo
rga_cvtcolor_gray256_demo
rga_fill_demo
rga_fill_rectangle_demo
rga_fill_rectangle_array_demo
rga_fill_rectangle_task_demo
rga_fill_rectangle_task_array_demo
rga_alpha_demo
rga_alpha_3channel_demo
rga_alpha_yuv_demo
rga_alpha_colorkey_demo
rga_alpha_osd_demo
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
rga_allocator_dma_demo
rga_allocator_dma_cache_demo
rga_allocator_dma32_demo
rga_allocator_drm_demo
rga_mosaic_demo
rga_rop_demo
rga_padding_demo
rga_palette_demo
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

required_cases=${RGA_REQUIRED_CASES:-$required_cases_default}
diagnostic_cases=${RGA_DIAGNOSTIC_CASES:-$diagnostic_cases_default}
failed=0

if [ ! -e /dev/rga ]; then
	echo "SKIP: /dev/rga is absent on this boot"
	exit 77
fi

if [ ! -d "$BIN_DIR" ]; then
	echo "Missing $BIN_DIR. Run ../rockchip-conformance/scripts/build-librga-samples.sh first." >&2
	exit 2
fi

mkdir -p "$OUT"
summary="$OUT/summary.tsv"
printf "profile\tclass\tcase\tstatus\telapsed_s\tresult\n" > "$summary"

export LD_LIBRARY_PATH="$LIBRGA_LIBDIR:${LD_LIBRARY_PATH:-}"

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

run_case()
{
	local class=$1
	local case_name=$2
	local exe="$BIN_DIR/$case_name"
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

	if [ ! -x "$exe" ]; then
		printf "missing\n" > "$status_file"
		printf "%s\t%s\t%s\tmissing\t0\tmissing\n" \
			"$PROFILE" "$class" "$case_name" >> "$summary"
		if [ "$class" = "required" ]; then
			failed=1
		fi
		return
	fi

	start=$(date +%s)
	set +e
	"$exe" > "$log" 2>&1
	status=$?
	set -e
	end=$(date +%s)
	elapsed=$((end - start))

	printf "%s\n" "$status" > "$status_file"
	if [ "$status" -eq 0 ]; then
		result=pass
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

snapshot_debugfs before

for case_name in $required_cases; do
	run_case required "$case_name"
done

for case_name in $diagnostic_cases; do
	run_case diagnostic "$case_name"
done

snapshot_debugfs after
dmesg | tail -n 500 > "$OUT/dmesg-tail.txt" 2>/dev/null || true

echo "$OUT"

if [ "$failed" -ne 0 ]; then
	echo "FAIL: one or more required librga samples failed; see $summary" >&2
	exit 1
fi

exit 0
