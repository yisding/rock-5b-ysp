# RGA userspace consumers outside the current conformance set

Search note from 2026-07-06. This is a high-signal public-source scan for
projects that use Rockchip `librga` beyond the current YSP conformance bundle
(`librockchip_mpp`, official `librga` samples, JeffyCN GStreamer, and
`ffmpeg-rockchip`/Jellyfin paths). It is not an exhaustive GitHub index, and it
does not make every stale BSP demo part of the RK3588 rewrite contract.

## Bottom line

The scan did not find another maintained media-server framework that adds a new
kernel ABI family beyond `/dev/rga` through `librga`. The extra public consumers
mostly reuse the same two surfaces we already target:

- modern IM2D handle/fd paths: `importbuffer_fd`, `wrapbuffer_handle(_t)`,
  `imcrop`, `imcvtcolor`, `imresize`, and optional fence fd output;
- legacy `c_RkRgaBlit()` paths over fd-backed or virtual buffers for
  scale/convert/rotate/copy into display, camera, or ML preprocessing buffers.

That supports the current priority order: keep the rewrite strict around current
`librga`/FFmpeg/GStreamer behavior, add optional conformance for representative
external apps, and keep old raw/physical-address and RGA2-Pro/FBC tail behavior
recognized-but-unsupported unless a current RK3588 workload proves otherwise.

## Representative consumers

| Consumer family | Public source checked | RGA surface seen | Rewrite impact |
|-----------------|-----------------------|------------------|----------------|
| `rkmppenc` CLI encoder | `rigaya/rkmppenc` README and `mppcore/mpp_filter.cpp` at `a12c80e` | MPP buffer fd -> `importbuffer_fd`; `wrapbuffer_handle(_t)`; `imcrop`, `imcvtcolor`, `imresize`; fence fd plumbing | Good optional integration target. The direct YSP smoke now covers fd-backed IM2D crop, `imcvtcolor`, and async `imresize` with release-fence wait; a full `rkmppenc` run would still test a separate MPP-frame producer and filter graph. |
| Standalone `gstreamer-rga` plugin | `corenel/gstreamer-rga` changelog at `223ecb2` | `rgavideoconvert` via `c_RkRgaBlit`, DMABuf support, common RGB/YUV conversions, runtime core-mask selection through `imconfig(IM_CONFIG_SCHEDULER_CORE, ...)` | No new consumer-specific ABI beyond legacy blit/core-mask. The direct smoke now covers the thread-default core-mask primitive plus the adjacent `IM_CONFIG_PRIORITY` path; a full plugin run remains useful optional coverage if we want an independent GStreamer RGA converter in addition to JeffyCN's plugin. |
| GStreamer `videoflip` RGA patch | `JeffyCN/meta-rockchip` patch at `c1eed72` | env-gated `GST_VIDEO_FLIP_USE_RGA=1`; virtual-buffer `c_RkRgaBlit`; rotations/flips; RGB/YUV and `NV12_10LE40` format mapping | Mostly covered by current rotation/format tests plus the direct YSP IM2D/legacy flip artifacts. A focused `videoflip` pipeline remains useful optional integration coverage for caps negotiation and compact-10-bit input. |
| Jellyfin/FFmpeg packaging | `SynoCommunity/spksrc` ffmpeg8 Rockchip patch at `34c6e71` | `--enable-rkrga`; `scale_rkrga`, `vpp_rkrga`, `overlay_rkrga`; RKMPP decode/encode | Already represented by the YSP `ffmpeg-suite.sh`/Jellyfin-oriented filter coverage. No separate RGA ABI surface found. |
| RKNN/Yolo preprocessing examples | `MontaukLaw/3568_rknn_rtmp` `rga_func.c` at `178599e` and Rockchip `rknn-toolkit2` bundled `RockchipRga.h` at `59a913d` | legacy `c_RkRgaBlit` for RGB resize; virtual sources; one older example writes to `dst.phyAddr` with `mmuFlag = 0` | The fd/virtual preprocessing shape is already mirrored by `librga-smoke.sh`. Direct physical-address submission is a compatibility risk, but not a current RK3588 requirement yet; keep it cleanly rejected until a target workload needs it. |
| UI/display stacks | SDL KMSDRM rotation patch in `knulli-linux` at `4cfc5d`; LVGL/RKADK sample at `6e1bb1` | GBM/dumb-buffer fds, virtual draw buffers, BGRA/XRGB `c_RkRgaBlit`, 90/270-degree rotation into scanout buffers | Not a media-server requirement, but common appliance-style usage. Optional display smoke would cover fd-backed BGRA/XRGB rotation and partial updates. |
| Language wrappers | `varphone/rkrga` Rust wrapper at `057cc92` | thin wrapper over `c_RkRgaInit`, `c_RkRgaBlit`, `c_RkRgaColorFill`, rotate/scale/fill helpers | No new kernel behavior. Passing the C API surfaces is enough for wrappers. |

## What this changes

Required rewrite coverage remains anchored to current Rock 5B media userspace:
`librockchip_mpp`, `librga`, JeffyCN GStreamer, `ffmpeg-rockchip`, and the
Jellyfin-style FFmpeg filter stack. The external scan suggests these additions
as useful but non-blocking conformance work:

- add an optional `rkmppenc` profile, because it chains MPP buffer fds through
  IM2D crop, CSC, resize, and fence plumbing in a different userspace codebase;
  the direct `librga-smoke` now covers the fd-backed crop, `imcvtcolor`, and
  async `imresize` release-fence primitives, but not the full `rkmppenc`
  pipeline;
- add one standalone `gstreamer-rga` or `videoflip` RGA pipeline if we want an
  independent GStreamer converter outside JeffyCN's plugin; the direct smoke
  now covers fd-backed IM2D flip, virtual legacy `c_RkRgaBlit()` flip
  primitives, the thread-default `imconfig(IM_CONFIG_SCHEDULER_CORE, ...)`
  core-mask call, and `IM_CONFIG_PRIORITY`, but not the full GStreamer element
  lifecycle;
- add one UI/display smoke for fd-backed BGRA/XRGB rotation into a GBM or dumb
  scanout buffer if display-appliance use becomes part of the target profile;
- keep direct physical-address RGA submission as recognized-but-unsupported
  unless a current RK3588 RKNPU/RKADK app cannot be moved to fd or virtual
  buffers.

The scan does not justify reviving RGA2-Pro source FBC paths, dormant BSP
debug/procfs controls, raw physical-address submit, or old Android gralloc
compatibility as required Linux/Rock 5B behavior.

## Sources

- `rkmppenc`: https://github.com/rigaya/rkmppenc/blob/a12c80e41a421d9b23ac87d6594a8f22b327322d/mppcore/mpp_filter.cpp
- `gstreamer-rga`: https://github.com/corenel/gstreamer-rga/blob/223ecb27d423220d205660352649aaf774303ee0/docs/changelog.md
- Jellyfin/FFmpeg Rockchip patch: https://github.com/SynoCommunity/spksrc/blob/34c6e71dfc7d7e9cb736bb59718a22da43384d31/cross/ffmpeg8/patches/1042-jellyfin-0042-add-full-hwa-pipeline-for-rockchip-rk3588-platform.patch
- GStreamer `videoflip` RGA patch: https://github.com/JeffyCN/meta-rockchip/blob/c1eed72f57f51e7e1c0e3be44ad0a5ce304ede42/recipes-multimedia/gstreamer/gstreamer1.0-plugins-good_1.28.2/0004-video-flip-Support-rockchip-RGA-2D-accel.patch
- RKNN/Yolo RGA helper: https://github.com/MontaukLaw/3568_rknn_rtmp/blob/178599e5ec5759d9d5ce63872fa28d5953d4749c/rknn_yolov5/src/rga_func.c
- Rockchip RKNN bundled legacy RGA wrapper: https://github.com/airockchip/rknn-toolkit2/blob/59a913d172e7f5ff03c9076e2ec7b1b1288ffd08/rknpu2/examples/rknn_yolov5_android_apk_demo/app/src/main/cpp/rga/RockchipRga.h
- SDL KMSDRM RGA rotation patch: https://github.com/knulli-cfw/knulli-linux/blob/4cfc5dde832dcb110338db287ded96619f690331/board/rockchip/rk3566/patches/sdl2/0003-Implement-librga-framebuffer-rotation.patch
- LVGL/RKADK display sample: https://github.com/ZyoungInc/LVGL_RK_RGA/blob/6e1bb1a81d7470efc34d018a0265ba2a744ff00e/lv_drivers-8.3.0/rkadk/rkadk.c
- Rust wrapper: https://github.com/varphone/rkrga/blob/057cc92f258adc2852915f20040a514bb447cf09/src/lib.rs
