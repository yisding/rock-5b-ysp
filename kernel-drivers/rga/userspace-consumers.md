# RGA userspace consumers outside the current conformance set

Search note from 2026-07-06, with follow-up GitHub repository/code-search passes
the same day. This is a high-signal public-source scan for projects that use
Rockchip `librga` beyond the current YSP conformance bundle
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
The follow-up repository pass also found package-only stacks and an older
DRM-RGA userspace library; neither adds required `/dev/rga` ioctl coverage for
the rewrite. A later same-day code-search delta found OpenCV/RKAIQ capture,
HDMI-capture/RTSP conversion, Weston mirror-mode patches, GStreamer base
converter patches, and runtime-language wrappers; these strengthen the
camera/CV/display usage signal but still collapse onto fd/virtual import,
legacy blit/fill/flush, IM2D color-convert/resize, and scheduler-core control.

## Representative consumers

| Consumer family | Public source checked | RGA surface seen | Rewrite impact |
|-----------------|-----------------------|------------------|----------------|
| `rkmppenc` CLI encoder | `rigaya/rkmppenc` README/options and `mppcore/mpp_filter.cpp` at `a12c80e`; latest public release seen was 0.18 on 2026-03-15 | Public docs call out ROCK 5B transcoding, MPP encode/decode, `--check-mppinfo`, `--check-rgainfo`, `--output-res`, and `--vpp-resize rga_nearest/rga_bilinear/rga_bicubic`; source review shows MPP buffer fd -> `importbuffer_fd`, `wrapbuffer_handle(_t)`, `imcrop`, `imcvtcolor`, `imresize`, and fence fd plumbing | Best optional application-level target found outside the current bundle. The direct YSP smoke now covers a fd-backed RGB crop/CSC to NV12 followed by async NV12 resize, with the first release fence supplied as the second acquire fence; a full `rkmppenc` run would still test the separate MPP-frame producer, CLI option probing, and filter graph lifecycle. |
| Standalone GStreamer RGA plugins | `corenel/gstreamer-rga` changelog at `223ecb2`; `higithubhi/gstreamer-rgaconvert` `plugins/gstrgaconvert.c` at `6f9da70` | `rgavideoconvert` via `c_RkRgaBlit`, DMABuf fd when available, virtual fallback, common RGB/YUV conversions, runtime core-mask selection through `imconfig(IM_CONFIG_SCHEDULER_CORE, ...)` in `corenel/gstreamer-rga` | No new consumer-specific ABI beyond legacy blit/core-mask. The direct smoke now covers the thread-default core-mask primitive plus the adjacent `IM_CONFIG_PRIORITY` path; `gstreamer-suite.sh` now has opt-in `GST_ENABLE_RGACONVERT_CASES=1` pipelines for independent plugin lifecycle/caps coverage when the element is installed. |
| GStreamer `videoflip` RGA patch | `JeffyCN/meta-rockchip` patch at `c1eed72` | env-gated `GST_VIDEO_FLIP_USE_RGA=1`; virtual-buffer `c_RkRgaBlit`; rotations/flips; RGB/YUV and `NV12_10LE40` format mapping | Mostly covered by current rotation/format tests plus the direct YSP IM2D/legacy flip artifacts. A focused `videoflip` pipeline remains useful optional integration coverage for caps negotiation and compact-10-bit input. |
| Jellyfin/FFmpeg/Kodi/OpenWrt packaging | `SynoCommunity/spksrc` ffmpeg8 Rockchip patch at `34c6e71`; `armsurvivors/kodi-rockchip-deb` Dockerfile at `dd1e192`; `jjm2473/openwrt-rkmpp` package makefiles at `64c04f1`; `tsukumijima/librga-rockchip` package repo scan | `--enable-rkrga`/`--enable-librga`; `scale_rkrga`, `vpp_rkrga`, `overlay_rkrga`; RKMPP decode/encode; distribution packaging of `librga`, MPP, and `ffmpeg-rockchip` | Already represented by the YSP `ffmpeg-suite.sh`/Jellyfin-oriented filter coverage. Package repos prove distribution demand for the same stack, not a separate RGA ABI surface. |
| RKNN/Yolo preprocessing examples | `MontaukLaw/3568_rknn_rtmp` `rga_func.c` at `178599e`, Rockchip `rknn-toolkit2` bundled `RockchipRga.h` at `59a913d`, and `1125962926/YOLO_RKNN_Acceleration_Program` preprocessing at `7fdd2f1` | legacy `c_RkRgaBlit` for RGB resize; IM2D `wrapbuffer_virtualaddr`, `importbuffer_virtualaddr`, `wrapbuffer_fd`, `imresize`, and `imcvtcolor`; one older example writes to `dst.phyAddr` with `mmuFlag = 0` | The fd/virtual preprocessing shape is already mirrored by `librga-smoke.sh`. Direct physical-address submission is a compatibility risk, but not a current RK3588 requirement yet; keep it cleanly rejected until a target workload needs it. |
| Standalone RGA demo/sample repos | `sravansenthiln1/rga-demos` sample sources at `b36dff0`; `BedRockJie/rockchip-rga-sample` `src/rga_test.cpp` at `5286187` | `querystring(RGA_*)`, `importbuffer_fd`, `importbuffer_virtualaddr`, `wrapbuffer_handle`, copy/crop/resize/rotate/fill/draw/color-convert samples | Mostly duplicates official `librga` sample coverage already in the conformance bundle. Useful for developer sanity checks, but not evidence of a separate production ABI requirement. |
| UI/display/media-player stacks | SDL KMSDRM rotation patch in `knulli-linux` at `4cfc5d`; LVGL/RKADK sample at `6e1bb1`; `iambronze/mp4player` `media/rga_utils.cc` at `f7dfb8d` | GBM/dumb-buffer fds, virtual draw buffers, BGRA/XRGB `c_RkRgaBlit`, 90/270-degree rotation into scanout buffers, optional alpha/blend on virtual MPP frame copies | Not a media-server requirement, but common appliance-style usage. `LIBRGA_SMOKE_DISPLAY_TAIL=1` now covers fd-backed BGRA/XRGB rotation plus a deterministic BGRA partial-rectangle alpha blend artifact; it still is not a full GBM/DRM scanout test. |
| OpenCV/camera/RTSP capture helpers | `nihui/opencv-mobile` RKAIQ V4L2 capture source at `3151145`; `pablocpas/rockchip-hdmi-capture-rtsp` RGA converter at `2e10fb8` | V4L2 exported dma-buf or MPP buffer fds, dma-heap destination buffers, dynamic `librga.so` loading, `importbuffer_fd`, `wrapbuffer_handle(_t)`, `imcvtcolor(_t)`, YCrCb/NV12 or YUYV to BGR/NV12 conversion | Confirms camera/CV/streaming apps want the same fd-backed IM2D conversion path. The direct smoke covers the kernel-visible fd import and color-convert behavior; full camera/RTSP source lifecycle remains optional application coverage. |
| Weston and GStreamer base converter patches | Radxa Buildroot Weston mirror-mode patch at `05cd2d`; TinkerBoard2 GStreamer base `video-converter` RGA patch at `9055ab5`; similar Khadas/Vicharak/OpenBMC downstream copies | env-gated `WESTON_DRM_MIRROR` and `GST_VIDEO_CONVERT_USE_RGA=1`; DRM PRIME fds or contiguous virtual video frames; `c_RkRgaBlit`; RGB-family, NV12-family, and compact `NV12_10LE40` conversion/scale/rotate | Same legacy blit/format coverage as the GStreamer and display-tail smokes. Promote only if desktop/display conformance becomes a target; they do not justify Android HWC or old RGA2-Pro tail support. |
| Old DRM-RGA userspace | `zouxf1024/libdrm-rockchip` RGA helper/API at `5d82052` | Rockchip DRM/GEM RGA helper structs and DRM ioctl path, not the `/dev/rga` `librga` character device ABI | Different historical userspace interface. Do not pull it into the `/dev/rga` rewrite unless the project explicitly grows a DRM-RGA compatibility target. |
| Language wrappers | `varphone/rkrga` Rust wrapper at `057cc92` | thin wrapper over `c_RkRgaInit`, `c_RkRgaBlit`, `c_RkRgaColorFill`, rotate/scale/fill helpers | No new kernel behavior. Passing the C API surfaces is enough for wrappers; the direct smoke now covers fd-backed legacy `c_RkRgaColorFill()` as well as legacy blit. |
| Runtime wrappers and G2D shims | `w-0x1f/linux-media` C# wrapper at `439ac1`; `zczjx/posix-bsp-perf` RGA G2D shim at `e17acf` | P/Invoke wrappers for `c_RkRgaBlit`, `c_RkRgaColorFill`, and `c_RkRgaFlush`; C++ fd/virtual wrapping through `wrapbuffer_fd_t`/`wrapbuffer_virtualaddr_t`; `imresize`, `imcvtcolor`, `imrectangle`; thread-local `imconfig(IM_CONFIG_SCHEDULER_CORE, RGA3 core mask)` | No new ioctl surface, but it reinforces that scheduler-core control, legacy fill/flush, fd wrapping, and virtual-address wrapping are public app expectations rather than sample-only behavior. |

## What this changes

Required rewrite coverage remains anchored to current Rock 5B media userspace:
`librockchip_mpp`, `librga`, JeffyCN GStreamer, `ffmpeg-rockchip`, and the
Jellyfin-style FFmpeg filter stack. The external scan suggests these additions
as useful but non-blocking conformance work:

- add an optional `rkmppenc` profile only if we want full application-level
  integration evidence; the direct `librga-smoke` now covers the kernel-visible
  fd-backed crop, CSC, resize, release-fence, and acquire-fence chain, but not
  `rkmppenc`'s `--check-mppinfo`/`--check-rgainfo` probes, `--output-res` CLI
  path, `--vpp-resize rga_*` selection, separate MPP-frame producer, or full
  filter graph. `rkmppenc-suite.sh` and `rkmppenc-suite-compare.sh` now make
  those app-level probes and short generated resize/encode/transcode cases
  executable as an opt-in forward-port-vs-rewrite YSP profile;
- keep standalone `gstreamer-rga` and `videoflip` RGA paths optional:
  `gstreamer-suite.sh` now has `GST_ENABLE_RGACONVERT_CASES=1` diagnostics for
  `GST_RGACONVERT_ELEMENT` plugin inspect plus BGRx/NV12 conversion/scale
  pipelines, and `GST_ENABLE_VIDEOFLIP_RGA_CASES=1` diagnostics for the
  Rockchip `GST_VIDEO_FLIP_USE_RGA=1` NV12/BGRx rotate/flip lifecycle. The
  direct smoke covers fd-backed IM2D flip, virtual legacy `c_RkRgaBlit()` flip
  primitives, the thread-default `imconfig(IM_CONFIG_SCHEDULER_CORE, ...)`
  core-mask call, and `IM_CONFIG_PRIORITY`;
- keep UI/display smoke optional unless display-appliance use becomes part of
  the target profile; `LIBRGA_SMOKE_DISPLAY_TAIL=1` now makes the fd-backed
  BGRA/XRGB legacy display-rotation primitive and a BGRA partial-rectangle
  alpha-blend artifact executable, though it still is not a full GBM/DRM
  scanout lifecycle test;
- keep OpenCV/RKAIQ capture, HDMI-capture/RTSP, Weston mirror, and
  `GST_VIDEO_CONVERT_USE_RGA=1` base-converter paths as optional app-level
  diagnostics for now. Their kernel-visible pieces are fd import, virtual
  import, IM2D color conversion/resize, legacy blit, and scheduler-core
  selection, all already inside the rewrite's required or near-required RGA
  surface;
- keep direct physical-address RGA submission as recognized-but-unsupported
  unless a current RK3588 RKNPU/RKADK app cannot be moved to fd or virtual
  buffers.
- do not add old DRM-RGA ioctls to this rewrite: the current contract is the
  `/dev/rga` character-device ABI used by `librga`, not the abandoned
  `libdrm-rockchip` RGA helper path.

The scan does not justify reviving RGA2-Pro source FBC paths, dormant BSP
debug/procfs controls, raw physical-address submit, or old Android gralloc
compatibility as required Linux/Rock 5B behavior.

## Sources

- `rkmppenc` README: https://github.com/rigaya/rkmppenc
- `rkmppenc` options: https://raw.githubusercontent.com/rigaya/rkmppenc/master/rkmppenc_Options.en.md
- `rkmppenc` filter source: https://github.com/rigaya/rkmppenc/blob/a12c80e41a421d9b23ac87d6594a8f22b327322d/mppcore/mpp_filter.cpp
- `gstreamer-rga`: https://github.com/corenel/gstreamer-rga/blob/223ecb27d423220d205660352649aaf774303ee0/docs/changelog.md
- `gstreamer-rgaconvert`: https://github.com/higithubhi/gstreamer-rgaconvert/blob/6f9da709181ae5d331be3ca131cc99ab9c747e7a/plugins/gstrgaconvert.c
- Jellyfin/FFmpeg Rockchip patch: https://github.com/SynoCommunity/spksrc/blob/34c6e71dfc7d7e9cb736bb59718a22da43384d31/cross/ffmpeg8/patches/1042-jellyfin-0042-add-full-hwa-pipeline-for-rockchip-rk3588-platform.patch
- Kodi Rockchip package: https://github.com/armsurvivors/kodi-rockchip-deb/blob/dd1e192ce8b71ed8705009f93adae6bbda17815f/Dockerfile
- OpenWrt RKMPP/RGA packages: https://github.com/jjm2473/openwrt-rkmpp/blob/64c04f1184ee23a2079ddccb7d287925bdf006a8/multimedia/ffmpeg-mpp/Makefile
- OpenWrt `rkrga` package: https://github.com/jjm2473/openwrt-rkmpp/blob/64c04f1184ee23a2079ddccb7d287925bdf006a8/multimedia/rkrga/Makefile
- Debian `librga-rockchip` package mirror: https://github.com/tsukumijima/librga-rockchip
- GStreamer `videoflip` RGA patch: https://github.com/JeffyCN/meta-rockchip/blob/c1eed72f57f51e7e1c0e3be44ad0a5ce304ede42/recipes-multimedia/gstreamer/gstreamer1.0-plugins-good_1.28.2/0004-video-flip-Support-rockchip-RGA-2D-accel.patch
- RKNN/Yolo RGA helper: https://github.com/MontaukLaw/3568_rknn_rtmp/blob/178599e5ec5759d9d5ce63872fa28d5953d4749c/rknn_yolov5/src/rga_func.c
- Rockchip RKNN bundled legacy RGA wrapper: https://github.com/airockchip/rknn-toolkit2/blob/59a913d172e7f5ff03c9076e2ec7b1b1288ffd08/rknpu2/examples/rknn_yolov5_android_apk_demo/app/src/main/cpp/rga/RockchipRga.h
- YOLO RKNN acceleration preprocessing: https://github.com/1125962926/YOLO_RKNN_Acceleration_Program/blob/7fdd2f13ee7e730285ffb510aebb5d091367ee2c/src/preprocess.cpp
- RGA demo repo: https://github.com/sravansenthiln1/rga-demos/blob/b36dff03bcf8bba91aa4e28287daaa5c57fe8784/src/rga-cvt/main.cpp
- RGA sample repo: https://github.com/BedRockJie/rockchip-rga-sample/blob/5286187cd99ee6e26818f110348132b643e87557/src/rga_test.cpp
- SDL KMSDRM RGA rotation patch: https://github.com/knulli-cfw/knulli-linux/blob/4cfc5dde832dcb110338db287ded96619f690331/board/rockchip/rk3566/patches/sdl2/0003-Implement-librga-framebuffer-rotation.patch
- LVGL/RKADK display sample: https://github.com/ZyoungInc/LVGL_RK_RGA/blob/6e1bb1a81d7470efc34d018a0265ba2a744ff00e/lv_drivers-8.3.0/rkadk/rkadk.c
- `mp4player` RGA helper: https://github.com/iambronze/mp4player/blob/f7dfb8d4a0452be22614a8f4594691072b11bdd1/media/rga_utils.cc
- OpenCV-mobile RKAIQ/V4L2 capture: https://github.com/nihui/opencv-mobile/blob/3151145cbfe44b1802004d4fe532cf307594b477/highgui/src/capture_v4l2_rk_aiq.cpp
- HDMI capture/RTSP RGA converter: https://github.com/pablocpas/rockchip-hdmi-capture-rtsp/blob/2e10fb8cdde9224c901ce4aed304c436d01835a6/src/rga_converter.cpp
- Weston mirror-mode RGA patch: https://github.com/radxa/buildroot/blob/05cd2d7b3d322adca4da4af412660a78e6bf30f4/package/weston/0023-backend-drm-Support-mirror-mode.patch
- GStreamer base video-converter RGA patch: https://github.com/TinkerBoard2/buildroot/blob/9055ab5f2394d9c649b29ef6e736869c0c76687b/package/gstreamer1/gst1-plugins-base/1.18.5/0010-video-converter-Support-rockchip-RGA-2D-accel.patch
- C# `librga` wrapper: https://github.com/w-0x1f/linux-media/blob/439ac160af49987a928368ff48e8ca77ea8ae994/linux-media-rockchip-rga/RGA.cs
- RGA G2D scheduler-core shim: https://github.com/zczjx/posix-bsp-perf/blob/e17acf4670c3cd6f722d083b2695b2e3b37cdd45/bsp/bsp_g2d/impl/rk_rga/rkrga.cpp
- old `libdrm-rockchip` RGA helper: https://github.com/zouxf1024/libdrm-rockchip/blob/5d82052f2d62f2c167142af93905d63a7fa5ba77/rga_api_helper.md
- Rust wrapper: https://github.com/varphone/rkrga/blob/057cc92f258adc2852915f20040a514bb447cf09/src/lib.rs
