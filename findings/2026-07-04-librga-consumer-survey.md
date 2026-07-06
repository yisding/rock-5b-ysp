# Public librga consumer survey: RKNN is the main additional Linux signal

> Scope: RGA rewrite required-profile selection for `/dev/rga` on RK3588/Rock 5B
> Source: public GitHub source survey of `librga` consumers, including
> [airockchip/rknn_model_zoo](https://github.com/airockchip/rknn_model_zoo/blob/bad6c7334531becaf90a561988519b7bec34d0ab/utils/image_utils.c),
> [rockchip-linux/rknpu2](https://github.com/rockchip-linux/rknpu2/blob/5adf7c1bd17e169e9880ccdf3b49adde925ab7f9/examples/rknn_yolov5_demo/src/preprocess.cc),
> [rockchip-linux/rknpu2 RKNN memory demo](https://github.com/rockchip-linux/rknpu2/blob/5adf7c1bd17e169e9880ccdf3b49adde925ab7f9/examples/rknn_api_demo/src/rknn_create_mem_with_rga_demo.cpp),
> and [jellyfin/jellyfin-ffmpeg's Rockchip patch](https://github.com/jellyfin/jellyfin-ffmpeg/blob/172f1454c4bc4dd9a3754e9db024708ef7a83f0c/debian/patches/0042-add-full-hwa-pipeline-for-rockchip-rk3588-platform.patch),
> plus `gh search code` hits for `wrapbuffer_fd`, `importbuffer_fd`,
> `improcess`, and `c_RkRgaBlit` consumers such as RKNN preprocessors,
> Orbbec helpers, Weston, pixman/SDL/LVGL acceleration patches, Rust bindings,
> downstream Jellyfin packaging, and small RK3588 vision apps
> Date: 2026-07-04
> Trust: UNVERIFIED (public-source survey; no hardware conformance run yet)

## The fact

Outside the already-covered `ffmpeg-rockchip`, JeffyCN GStreamer, and official
`librga` sample paths, the strongest additional Linux signal is RKNN/RKNPU
preprocessing. Public examples use `librga` for RGB/RGBA/NV12/NV21 resize,
crop/letterbox, and color conversion through `imresize()`, `improcess()`,
`wrapbuffer_virtualaddr()`, `wrapbuffer_fd()`, fd handle imports, and older
`c_RkRgaBlit()` calls.

Some RKNN model-zoo utility code still carries physical-address import branches,
but the common examples are fd-backed or userspace-virtual buffers. For the
rewrite, physical-address import should stay recognized-but-unsupported unless a
real target workload proves it is mandatory.

Android camera/HAL/display/HWC users are real `librga` consumers, but they are
mostly a different compatibility target: Android allocator, GraphicBuffer, HWC,
and display stack behavior rather than the Linux Rock 5B media stack we are
currently gating.

The remaining public Linux users found in the survey cluster around the same
feature set we already consider required or near-required: legacy blit,
fd/virtual import, RGB/RGB565/RGBA/NV12-family scale/convert/rotate, and simple
allocator handoff. The survey did not find current Linux-media evidence that
RFBC64x4, AFBC32x8, per-channel rotation, tile alpha/pattern/color-key, or broad
RGA2-Pro modes should be promoted into the required RK3588 rewrite profile.

The 2026-07-06 Route B rewrite slice changes how to prioritize the virtual
buffer half of that finding. Public RKNN/RKNPU examples commonly use
`wrapbuffer_virtualaddr()` or handle imports around userspace-virtual image
buffers, and direct `librga` samples use the same shape. The rewrite now keeps
dma-buf imports fail-closed but maps driver-owned pinned userptr sg-tables
through one contiguous IOMMU IOVA span on RGA3. That is the right compatibility
target for current Linux direct-librga/RKNN-style virtual buffers; it is not a
reason to revive physical-address import or broad Android allocator/HWC API
surface.

Follow-up in this repo now makes the public display/compositor/game-UI signal
executable too: `librga-smoke.cpp` records a deterministic
`legacy_bgrx_display_rot90` artifact using fd-backed BGRx `c_RkRgaBlit()` 90
degree rotation, alongside the existing RKNN/RKNPU preprocessing and
GStreamer-shaped legacy conversion artifacts. A 2026-07-05 re-check also found
that Jellyfin's Rockchip FFmpeg patch is not a separate `/dev/rga` profile: it
uses `--enable-rkrga`, probes `rga/RgaApi.h`, `c_RkRgaBlit`, `rga/im2d.h`, and
`querystring`, and exposes the `scale_rkrga`, `vpp_rkrga`, and `overlay_rkrga`
filters. That keeps Jellyfin/SynoCommunity-style media-server usage inside the
existing `ffmpeg-suite.sh` coverage boundary.

## Representative public hits

This is not a complete dependency census. It is a source-shape check to decide
whether anything outside the current conformance set changes the rewrite's
required RGA profile.

| Consumer family | Example source | RGA shape visible in public code |
|---|---|---|
| RKNN/RKNPU preprocess | [`rknn_model_zoo` `image_utils.c`](https://github.com/airockchip/rknn_model_zoo/blob/bad6c7334531becaf90a561988519b7bec34d0ab/utils/image_utils.c), [`rknpu2` `preprocess.cc`](https://github.com/rockchip-linux/rknpu2/blob/5adf7c1bd17e169e9880ccdf3b49adde925ab7f9/examples/rknn_yolov5_demo/src/preprocess.cc), [`rknpu2` `rknn_create_mem_with_rga_demo.cpp`](https://github.com/rockchip-linux/rknpu2/blob/5adf7c1bd17e169e9880ccdf3b49adde925ab7f9/examples/rknn_api_demo/src/rknn_create_mem_with_rga_demo.cpp) | RGB/RGBA/NV12/NV21 resize, crop/letterbox, color conversion, `imfill()` background fill, `improcess()`, `imresize()`, fd/virtual buffers, handle imports, and RKNN tensor-memory fd handoff |
| Jellyfin / packaged FFmpeg RKRGA | [`jellyfin-ffmpeg` Rockchip patch](https://github.com/jellyfin/jellyfin-ffmpeg/blob/172f1454c4bc4dd9a3754e9db024708ef7a83f0c/debian/patches/0042-add-full-hwa-pipeline-for-rockchip-rk3588-platform.patch), mirrored in downstream package trees such as SynoCommunity/fnoscommunity | Same ffmpeg-rockchip RKRGA surface already targeted here: `c_RkRgaBlit()`, `querystring(RGA_VERSION)`, `scale_rkrga`, `vpp_rkrga`, `overlay_rkrga`, AFBC/RFBC option handling |
| RK3588 vision demos | [`XtERVG_RK3588_Demo` `mpp_rknn.cc`](https://github.com/steven-j-on-ai/XtERVG_RK3588_Demo/blob/HEAD/src/mpp_rknn.cc), [`gstreamer-rknn` `gstrknn.c`](https://github.com/haydenee/gstreamer-rknn/blob/HEAD/src/gstrknn.c) | MPP/GStreamer DMABuf fds into `wrapbuffer_fd()`/`wrapbuffer_fd_t()`, then RGA resize/convert for neural-network input |
| Camera / ROS helpers | [`OrbbecSDK_ROS2` `rk_mpp_decoder.cpp`](https://github.com/orbbec/OrbbecSDK_ROS2/blob/HEAD/orbbec_camera/src/rk_mpp_decoder.cpp) | Legacy `c_RkRgaBlit()` conversion after MPP decode |
| Display/compositor patches | [`JeffyCN/weston` `fb-convert.c`](https://github.com/JeffyCN/weston/blob/HEAD/libweston/backend-drm/fb-convert.c), [`EchoHeim/RK3399-linux` pixman patch](https://github.com/EchoHeim/RK3399-linux/blob/HEAD/buildroot/package/pixman/0005-pixman_image_composite32-Support-rockchip-RGA-2D-acc.patch) | Legacy blit acceleration for framebuffer/composite conversion |
| Game/UI/display stacks | [`RetroArch-ARM` `display.c`](https://github.com/basharast/RetroArch-ARM/blob/HEAD/src/deps/libgo2/src/display.c), [`EmuELEC` SDL patch](https://github.com/fengshenwk/EmuELEC/blob/HEAD/packages/multimedia/SDL2/patches/OdroidGoAdvance/0005-SDL-2.0.20.odroidgoa-support.patch) | Legacy RGB-family blit/rotate/display scaling |
| Language bindings | [`varphone/rkrga`](https://github.com/varphone/rkrga) | Rust exposure of the same C `librga` / legacy blit ABI, not a distinct kernel feature demand |

Several hits are older SoCs or downstream board SDKs rather than Rock 5B
targets. They still matter as public Linux `librga` usage signals, but they do
not by themselves justify importing every BSP RGA2-Pro or Android allocator path
into the RK3588 rewrite.

## Why it matters / follow-up

The rewrite should keep chasing current user-visible behavior, not every BSP
mode table entry. The practical follow-up is:

1. Keep RKNN-shaped preprocessing in required conformance: virtual RGB resize,
   fd-backed RGB/NV12/NV21 resize/convert, fd-backed RGBA crop/letterbox,
   handle import/release lifetime, RKNN tensor-memory fd handoff, and legacy RGB
   `c_RkRgaBlit()` resize.
2. Keep the public display/compositor/game-UI class covered by simple
   fd-backed RGB-family legacy blit/rotate artifacts, not by broad Android HWC
   or allocator compatibility.
3. Keep Jellyfin-style media-server usage under the FFmpeg conformance suite;
   it does not add a distinct direct-librga kernel profile beyond the RKRGA
   filters and legacy blit ABI.
4. Keep physical-address import as a clean negative ABI path for the rewrite
   unless a real workload needs it.
5. Keep source-only RGA2-Pro RFBC64x4/AFBC32x8 paths recognized but
   unsupported; the rewrite now rejects them with `-EOPNOTSUPP` instead of
   carrying an executable FBCIN path.
6. Do not prioritize per-channel rotation, tile alpha/pattern/color-key, or
   broad RGA2-Pro mode expansion ahead of booted forward-port-vs-rewrite
   conformance and performance runs.
