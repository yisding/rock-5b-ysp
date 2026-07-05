# Public librga consumer survey: RKNN is the main additional Linux signal

> Scope: RGA rewrite required-profile selection for `/dev/rga` on RK3588/Rock 5B
> Source: public GitHub source survey of `librga` consumers, including
> [airockchip/rknn_model_zoo](https://github.com/airockchip/rknn_model_zoo/blob/main/utils/image_utils.c),
> [airockchip/rknn-toolkit2](https://github.com/airockchip/rknn-toolkit2/blob/master/rknpu2/examples/rknn_yolov5_demo/src/preprocess.cc),
> [rockchip-linux/rknpu](https://github.com/rockchip-linux/rknpu/blob/master/rknn/rknn_api/examples/rknn_yolov5_demo/src/rga_func.c),
> Android camera/HWC users, FlyCV, Rust `rkrga`, `libv4l-rkmpp`,
> RetroArch OGA, LVGL/SDL RGA patches, Orbbec helpers, RKMedia demos, and
> small Qt/DRM camera apps
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

## Why it matters / follow-up

The rewrite should keep chasing current user-visible behavior, not every BSP
mode table entry. The practical follow-up is:

1. Keep RKNN-shaped preprocessing in required conformance: virtual RGB resize,
   fd-backed RGB/NV12/NV21 resize/convert, and legacy RGB `c_RkRgaBlit()`
   resize.
2. Keep physical-address import as a clean negative ABI path for the rewrite
   unless a real workload needs it.
3. Treat source-only RGA2-Pro RFBC64x4/AFBC32x8 paths as deprecated historical
   compatibility, not RK3588 required ABI.
4. Do not prioritize per-channel rotation, tile alpha/pattern/color-key, or
   broad RGA2-Pro mode expansion ahead of booted forward-port-vs-rewrite
   conformance and performance runs.
