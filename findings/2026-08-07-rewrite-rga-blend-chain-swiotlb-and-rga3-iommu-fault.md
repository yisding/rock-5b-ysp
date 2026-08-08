# Rewrite RGA cannot run a valid overlay blend chain: RGA2 SWIOTLB segment limit and a deterministic RGA3 IOMMU fault

> Scope: rewrite RGA driver (`rk_rga_rewrite`) blend/composite chains, exercised through ffmpeg-rockchip `overlay_rkrga`
> Source: runtime on `6.18.43-video-rewrite-kasan-rockchip64` `#8 gf37186832202`; ffmpeg-rockchip-81 `git-2026-07-11`; librga `26a50ef`; repro logs `~/Code/tmp/ffmpeg-rkrga-regression/ovl-rga*.log`
> Date: 2026-08-07
> Trust: MEASURED, PARTIAL

## Result

Fixing the ffmpeg conformance overlay case to a *valid* pipeline (RGB overlay
pad, consistent BT.601 color-space legs — see
[the latent-defects finding](./2026-08-07-ffmpeg-rkrga-failures-are-latent-pts-and-checker-defects.md))
exposed two rewrite-driver gaps that block every strategy the filter can
choose. The conformance case is therefore opt-in
(`FFMPEG_RUN_OVERLAY_BLEND=1`) until this driver work lands, and must be
promoted back to required afterwards.

1. **Direct NV12-domain blend → RGA2 → SWIOTLB segment limit.** With inputs
   tagged BT.709 the filter blends the RGBA foreground straight onto the
   NV12 background subrect. That job routes to RGA2 (`fdb80000.rga2`), whose
   bounce path then logs `swiotlb buffer is full (sz: 1048576 bytes), total
   32768 (slots), used 4 (slots)` and fails the dma map: a 1 MiB contiguous
   segment exceeds SWIOTLB's 256 KiB maximum single mapping
   (`IO_TLB_SEGSIZE`), so this fails regardless of pool occupancy. Same
   family as the 2026-08-05 SWIOTLB finding for librga sample buffers.
2. **RGBA-intermediate chain → deterministic RGA3 IOMMU fault.** With inputs
   tagged BT.601 (or untagged) the filter converts the background to a
   full-size RGBA intermediate, blends on RGA3, and converts back. The chain
   deterministically faults the RGA3 core-0 IOMMU:
   `rockchip-rga-rewrite fdb60000.rga: IOMMU fault iova 0x1e100 status 0x0`
   — same iova on every reproduction (3/3 runs, e.g. 22:37:12 and two at
   22:41:47 on 2026-08-07). The job fails back to userspace
   (`RGA IM2D process failed`), no crash. iova `0x1e100` (~123 KiB) lies
   *inside* the 480x270 RGBA foreground buffer's extent (~983 KiB), so a
   mapping that should cover it does not — an import/mapping-range gap, not
   a wild pointer.

Also fixed en route in the filter-facing layer (userspace, ffmpeg-rockchip):
the original conformance case fed NV12 to the overlay pad, which
`supported_formats_overlay[]` (RGB only) has never accepted, and an
untagged-1080p graph mixes `IM_YUV_TO_RGB_BT601_LIMIT` legs with an
`IM_RGB_TO_YUV_BT709_LIMIT` writeback that librga rejects
(`im2d_rga_csc: Unsupported CSC mode`). Neither is a driver defect.

## Evidence and reproduction

- **Exercise:** `FFMPEG_RUN_OVERLAY_BLEND=1 FFMPEG_DIAGNOSTIC_CASES=ffmpeg_filter_overlay_rkrga_alpha bash kernel-drivers/tests/ffmpeg-suite.sh`, or directly:
  `ffmpeg -hwaccel rkmpp -hwaccel_output_format drm_prime -c:v h264_rkmpp -i <clip> -hwaccel rkmpp -hwaccel_output_format drm_prime -c:v h264_rkmpp -i <clip> -filter_complex "[0:v]setparams=colorspace=bt470bg[bg];[1:v]setparams=colorspace=bt470bg,scale_rkrga=w=480:h=270:format=rgba[ovl];[bg][ovl]overlay_rkrga=x=64:y=32:alpha=192:alpha_format=straight:format=nv12:async_depth=0[out]" -map "[out]" -c:v hevc_rkmpp -b:v 4M -fps_mode passthrough -f hevc out.hevc`
  (BT.709 tags instead reproduce the RGA2/SWIOTLB leg.)
- **Pass/fail signal:** kernel log IOMMU-fault/SWIOTLB lines above; ffmpeg exits nonzero with `RGA IM2D process failed`. `ROCKCHIP_RGA_LOG=1 ROCKCHIP_RGA_LOG_LEVEL=5` shows the failing job's channel table.
- The blend jobs themselves are fine on RGA3 until the fault: the 480x270 RGBA scale and the RGBA-onto-RGBA blend complete before the failing job in each run.

## Boundary

Neither gap is root-caused in driver source yet. Whether the RGA3 fault is a
multi-plane/offset import gap, a stale mapping, or an active-rect
stride issue is undetermined; the RGA debugfs `iommu_fault_count` delta was
not captured. Vendor-kernel behavior on the identical chain has not been
compared, so "hardware cannot do this" is not excluded for the RGA2 leg,
though the SWIOTLB segment failure is a software addressing/bounce policy
issue independent of RGA capability. The conformance overlay case's software
composite reference and threshold have not been runtime-validated because no
strategy currently completes.
