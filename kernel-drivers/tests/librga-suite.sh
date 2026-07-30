#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
# shellcheck source=suite-common.sh disable=SC1091
source "$TEST_DIR/suite-common.sh"
# shellcheck source=debugfs-counters.sh disable=SC1091
source "$TEST_DIR/debugfs-counters.sh"
ROCK5B_WORKSPACE=${ROCK5B_WORKSPACE:-"$REPO_ROOT/../rock-5b"}
CONFORMANCE_ROOT=${CONFORMANCE_ROOT:-"$ROCK5B_WORKSPACE/rockchip-conformance"}
PROFILE=${PROFILE:-${1:-rewrite}}
BIN_DIR=${RGA_BIN_DIR:-"$CONFORMANCE_ROOT/out/librga-samples/bin"}
OUT=${OUT:-"$CONFORMANCE_ROOT/logs/$PROFILE/$(date +%Y%m%d-%H%M%S)-librga-suite"}
LIBRGA_LIBDIR=${LIBRGA_LIBDIR:-"$CONFORMANCE_ROOT/sources/airockchip-librga/libs/Linux/gcc-aarch64"}
RGA_CAPTURE_ARTIFACTS=${RGA_CAPTURE_ARTIFACTS:-1}
RGA_ENABLE_YSP_SMOKE=${RGA_ENABLE_YSP_SMOKE:-1}
RGA_REQUIRE_YSP_SMOKE=${RGA_REQUIRE_YSP_SMOKE:-1}
LIBRGA_FORCE_RGA_USERPTR_IOMMU=${LIBRGA_FORCE_RGA_USERPTR_IOMMU:-${LIBRGA_FORCE_ROUTE_B:-0}}
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
	echo "Missing $BIN_DIR. Run ../rock-5b/rockchip-conformance/scripts/build-librga-samples.sh first." >&2
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

	printf "%s\n" "$status" > "$status_file"
	if [ "$status" -eq 0 ]; then
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
