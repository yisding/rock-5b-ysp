# FFmpeg implementation comparison

This compares the two local source trees used while working on this repo:

| Tree | Checked-out point | Role in this repo |
|------|-------------------|-------------------|
| `../FFmpeg` | `n8.2-dev-2058-g87bd15dc3c` (`87bd15dc3c21`, 2026-06-28) | Mainline FFmpeg's upstream rkmpp implementation. The packaged GRD stack uses the same mainline encoder shape, though pinned to FFmpeg 8.1.2. |
| `../ffmpeg-rockchip` | `40c412daccf0` (`40c412d`, 2026-04-23) | NyanMisaka's Rockchip-focused fork: full MPP + RGA pipeline for CLI transcoding. |

Both trees were clean when inspected. This is a source-code comparison, not a new
runtime benchmark.

## Executive summary

Mainline FFmpeg has a small, upstreamable rkmpp codec bridge. It exposes MPP
decode/encode through generic DRM PRIME frames, covers the common H.264/HEVC
encoder path plus H.264/HEVC/VP8/VP9 decode, and intentionally leaves most
Rockchip-specific pipeline features out.

`ffmpeg-rockchip` is a platform integration fork. It adds an RKMPP hardware
device/context, broader codec coverage, many more MPP encoder controls, and RGA
filters (`scale_rkrga`, `vpp_rkrga`, `overlay_rkrga`) so decode -> RGA ->
encode can stay inside dma-buf hardware frames.

The practical rule for this repo:

- Use `ffmpeg-rockchip` for CLI validation and hardware transcode tests that need
  `scale_rkrga` or fixed-QP quality.
- Use mainline FFmpeg when ABI compatibility with the distro matters, as in the
  GNOME Remote Desktop package. Then compensate for its thinner encoder glue in
  the application: set `rc_max_rate`/`rc_min_rate`, do not rely on QP/profile
  options, and recreate the encoder when a fresh first-frame IDR is required.

## Build integration

| Area | Mainline `../FFmpeg` | `../ffmpeg-rockchip` |
|------|----------------------|----------------------|
| Configure switches | `--enable-rkmpp` only. Requires `--enable-libdrm`. | `--enable-rkmpp` plus `--enable-rkrga`; `rkrga` requires `rkmpp`. |
| MPP dependency | `rockchip_mpp >= 1.3.8`, headers `rockchip/rk_mpi.h` and `rockchip/mpp_buffer.h`, symbols including `mpp_create` and `mpp_buffer_sync_begin_f`. | `rockchip_mpp >= 1.3.9`, `rockchip/rk_mpi.h`, `mpp_create`. |
| RGA dependency | None. | `librga`, requiring `rga/RgaApi.h` (`c_RkRgaBlit`) and `rga/im2d.h` (`querystring`). |
| New libavutil hwcontext | None. Uses existing DRM hwcontext. | Adds `libavutil/hwcontext_rkmpp.c` and `AV_HWDEVICE_TYPE_RKMPP`. |
| New filters | None. | Adds `rkrga_common.c`, `vf_vpp_rkrga.c`, and `vf_overlay_rkrga.c`. |

## Hardware-frame model

Mainline has no `AV_HWDEVICE_TYPE_RKMPP`. Its decoder declares
`HW_CONFIG_INTERNAL(DRM_PRIME)` and sets `avctx->pix_fmt = AV_PIX_FMT_DRM_PRIME`.
Its encoder accepts `HW_CONFIG_ENCODER_FRAMES(DRM_PRIME, DRM)`. In practice,
rkmpp frames are generic DRM PRIME descriptors and the encoder imports their fds
with `mpp_buffer_import()`.

The fork adds a real RKMPP hwdevice:

- `AV_HWDEVICE_TYPE_RKMPP` is registered under the name `rkmpp`.
- `AVRKMPPFramesContext` owns an MPP buffer group and optional preallocated frame
  descriptors.
- `AVRKMPPDRMFrameDescriptor` embeds an `AVDRMFrameDescriptor` plus the
  `MppBuffer` references that keep the MPP allocations alive.
- The hwcontext implements frame allocation, transfer-to/from, and mapping with
  `DMA_BUF_IOCTL_SYNC`. CPU mapping is limited to linear frames.

That is why the fork can build hardware-frame pools for decode, RGA, and encode,
while mainline treats rkmpp primarily as a codec wrapper over generic DRM PRIME.

## Decoder comparison

| Capability | Mainline `../FFmpeg` | `../ffmpeg-rockchip` |
|------------|----------------------|----------------------|
| Source files | One file: `libavcodec/rkmppdec.c` (582 lines). | `rkmppdec.c` plus `rkmppdec.h` (1418 lines total). |
| Registered decoders | `h264_rkmpp`, `hevc_rkmpp`, `vp8_rkmpp`, `vp9_rkmpp`. | `av1_rkmpp`, `h263_rkmpp`, `h264_rkmpp`, `hevc_rkmpp`, `mjpeg_rkmpp`, `mpeg1_rkmpp`, `mpeg2_rkmpp`, `mpeg4_rkmpp`, `vp8_rkmpp`, `vp9_rkmpp`. |
| Output model | Always DRM PRIME. The frame context advertises NV12 when the MPP format maps to DRM `NV12`; otherwise the software format may be unknown. | Offers software-format negotiation for `NV12`, `NV16`, `NV15`, `NV20`, or DRM PRIME. Stores the selected format in `avctx->sw_pix_fmt` when returning DRM PRIME. |
| Decoder options | None in the class. | `deint`, `afbc=off/on/rga`, `fast_parse`, and `buf_mode=half/ext`. |
| Compressed modifiers | Minimal DRM-format mapping. | Explicit AFBC/RFBC helpers and modifier-aware DRM descriptors. |
| Buffer modes | Internal decoder-owned flow. | Half-internal or pure-external MPP buffer mode, backed by the RKMPP hwcontext. |

The fork's codec list is broader than this repo's validated hardware goal. This
repo validated H.264/H.265 decode and encode plus RGA on RK3588. Other advertised
fork codecs still depend on matching MPP support and kernel/device-tree wiring.

## Encoder comparison

| Capability | Mainline `../FFmpeg` | `../ffmpeg-rockchip` |
|------------|----------------------|----------------------|
| Source files | One file: `libavcodec/rkmppenc.c` (584 lines). | `rkmppenc.c` plus `rkmppenc.h` (1632 lines total). |
| Registered encoders | `h264_rkmpp`, `hevc_rkmpp`. | `h264_rkmpp`, `hevc_rkmpp`, `mjpeg_rkmpp`. |
| Accepted H.26x input formats | `DRM_PRIME`, `NV12`, `YUV420P`. | Many YUV, semi-planar, packed YUV, RGB/BGR, and `DRM_PRIME` formats. |
| Rate-control option | `-rc vbr|cbr|avbr`, default `vbr`. | `-rc_mode VBR|CBR|CQP|AVBR`, default auto (`MPP_ENC_RC_MODE_BUTT`). |
| Fixed QP | Not exposed. No `rc:qp_*` values are set. | `qp_init >= 0` selects fixed-QP mode in auto RC; `CQP` is explicit too. Wires `rc:qp_init`, `qp_min/max`, and I-frame QP bounds. |
| H.264 profile/level/coder | Not exposed; MPP defaults apply. On RK3588 this yields constrained-baseline behavior in the GRD case. | Exposes H.264 profile, level, CABAC/CAVLC, 8x8 transform, user-data SEI, and prefix mode. Default profile is High. |
| HEVC profile/tier/level | Not exposed. | Exposes HEVC profile, tier, and level. |
| Forced IDR | Ignores `frame->pict_type`. | If an H.264/HEVC input frame has `pict_type == I`, calls `MPP_ENC_SET_IDR_FRAME` before submit. |
| Bitrate bounds | Sets `rc:bps_target` only when `bit_rate > 0`; sets `rc:bps_max` only from `avctx->rc_max_rate`; sets `rc:bps_min` only from `avctx->rc_min_rate`. If max is unset, MPP's own ceiling can remain in effect. | Always computes and sets target/min/max for bitrate modes. VBR/AVBR use wide bounds; CBR uses narrow bounds. Fixed-QP mode skips bitrate setup. |
| Stride/config update | Starts with 16-byte alignment; DRM PRIME input can update MPP stride from the descriptor. | Starts with 64-byte alignment, can defer final prep config until the first DRM frame, and validates linear/AFBC modifiers. |
| Async behavior | Simple receive loop around `ff_encode_get_frame()` and MPP put/get. | Tracks submitted frames, uses nonblocking output for H.26x/MJPEG unless low-delay is requested, and records average QP side data from `KEY_ENC_AVERAGE_QP`. |
| Flush | Implements FFmpeg encoder flush by `mpi->reset()` and `eof_sent = true`. | Uses the older encode callback style and explicit close/reset cleanup. |

This is the source of the GRD mainline workarounds:

- `qp_init=22` is meaningful on the fork, but ignored by mainline because the
  option does not exist there.
- `frame->pict_type = I` forces an IDR on the fork, but not on mainline.
- On mainline, setting only `bit_rate` is not enough for quality; applications
  should set `rc_max_rate` and usually `rc_min_rate` too.

## RGA filters

Mainline FFmpeg has no Rockchip RGA filters. Any scale, crop, colorspace, or
overlay operation in a mainline-only CLI pipeline must use software, another
hardware API, or application-side work such as GRD's Vulkan RGB -> NV12 pass.

The fork adds three filters, all requiring DRM PRIME hardware frames:

| Filter | Purpose | Key options |
|--------|---------|-------------|
| `scale_rkrga` | Resize and pixel-format conversion. | `w`, `h`, `format`, `force_original_aspect_ratio` (default `decrease`), `force_divisible_by` (default `2`), common RGA options. |
| `vpp_rkrga` | Scale, crop, and transpose. | `w`, `h`, `cw`, `ch`, `cx`, `cy`, `format`, `transpose`, common RGA options. |
| `overlay_rkrga` | Two-input compositor. | `x`, `y`, `alpha`, `alpha_format`, `format`, framesync EOF options, common RGA options. |

Common RGA options include `force_yuv`, `force_chroma`, `core`, `async_depth`
(default `2`), and `afbc`.

`rkrga_common.c` is not a thin wrapper. It maps FFmpeg pixel formats to librga
formats, checks RGA2/RGA3 feature constraints, handles AFBC/RFBC modifiers,
allocates output hardware frames, submits async blits, and synchronizes returned
fences. The fork also queries `librga` via `querystring(RGA_VERSION)` to decide
which RGA cores and feature subsets are actually present.

One gotcha from the source matters in this repo's tests: `scale_rkrga` defaults
`force_original_aspect_ratio=decrease`, so exact dimensions require
`force_original_aspect_ratio=disable`.

## Pipeline consequences

For this repo's full transcode smoke test, the fork is the natural tool:

```bash
ffmpeg -hwaccel rkmpp -hwaccel_output_format drm_prime -i in.h264 \
  -vf scale_rkrga=w=1280:h=720:format=nv12 \
  -c:v hevc_rkmpp -b:v 4M out.mp4
```

That path is decode -> DRM PRIME -> RGA -> DRM PRIME -> encode, with no software
scale/CSC stage.

Mainline can still be a good application dependency when the application already
has a hardware frame producer or transform stage. GRD is exactly that case:
Vulkan/panvk produces a linear NV12 dma-buf, then mainline `h264_rkmpp` imports it.
The cost is that GRD must work around mainline's missing fixed-QP, missing forced
IDR, and missing profile knobs in application code.

## Keep in mind when resyncing

- The two implementations use the same public codec names (`h264_rkmpp`,
  `hevc_rkmpp`) for different control surfaces. Check the binary's source or
  `ffmpeg -h encoder=h264_rkmpp` before assuming an option exists.
- Mainline's `rkmppenc.c` has been moving quickly; refresh the comparison against
  `../FFmpeg` before changing GRD workarounds.
- The fork's RGA path depends on `librga` and `/dev/rga`; mainline rkmpp does not.
- Codec names advertised by FFmpeg are necessary but not sufficient. MPP library
  support, kernel device nodes, and DT wiring decide what works on the ROCK 5B.
