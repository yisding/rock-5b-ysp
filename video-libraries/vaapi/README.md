# rockchip-vaapi — VA-API over Rockchip MPP

This project records the maintained `rockchip-vaapi` fork: a libva backend that
translates desktop VA-API decode and encode requests into Rockchip MPP/RGA
operations on the RK3588. It is the shared hardware-video layer for browsers,
VLC, GStreamer's VA elements, stock FFmpeg VAAPI codecs, and other applications
that cannot select the Rockchip-specific libavcodec wrappers directly.

## Project brief

| Field | Contents |
|-------|----------|
| Purpose | Make the vendor `/dev/mpp_service` codec stack reachable through the standard Linux VA-API plugin boundary without patching each desktop application into the RKMPP wrapper codecs. |
| Developer focus | VA object lifetimes, reconstructed decode bitstreams, MPP external-buffer ownership, AFBC/NV15-to-P010 conversion, VA encode parameter translation, imported-surface validation, browser sandbox policy, and application interoperability. |
| Owns | The durable capability/boundary summary and evidence map for `yisding/rockchip-vaapi`; dated measurements remain under [`../../findings/`](../../findings/README.md), app-specific integration stays in [`../../docs/app-enablement.md`](../../docs/app-enablement.md), and package publication stays under [`../../packaging/`](../../packaging/README.md). |
| Depends on | The RK3588 MPP/RGA kernel path, current `librockchip_mpp`, the kernel-paired `librga` 10-bit contract, libva, and an application/display sandbox that can open the required device nodes and ioctls. |
| Current state | As of 2026-07-28, development is `yisding/rockchip-vaapi` `main@5a7b305`. **H.264, VP9 Profile 0 and HEVC Main decode are the default capability set**; HEVC Main10, VP9 Profile 2, and H.264/HEVC encode remain opt-in experiments. Every gate is now measured on the production-shaped `6.18.40-ysp-rockchip64` kernel with the post-fix MPP. Stock VLC and Firefox hardware-decode in a real display session; what remains is installing the built package, the Firefox sandbox proof, and 10-bit promotion. |

## Where it sits

`rockchip-vaapi` is a userspace driver, not a kernel driver and not an
application patch:

```text
Firefox / Chromium / VLC / GStreamer / FFmpeg
  -> libva
  -> rockchip_drv_video.so
  -> librockchip_mpp + librga
  -> /dev/mpp_service + /dev/rga + /dev/dma_heap/*
  -> RK3588 codec and RGA hardware
```

That placement is why this project lives under `video-libraries/`. The
[application enablement map](../../docs/app-enablement.md) decides which apps
can use the layer and what each integration still needs; this page owns what
the layer itself can honestly claim.

## Capability matrix

Experimental means hidden unless its documented environment opt-in is set. It
does not mean the measured gates are hypothetical.

> **Kernel precondition, resolved 2026-07-28.** This driver calls
> `DMA_BUF_IOCTL_SYNC` directly (`src/surface.c`, `src/buffer.c`) — the ioctl
> that reaches `system_heap_dma_buf_end_cpu_access()`, where a
> `DMABUF_DEBUG=y` kernel
> [oopses deterministically](../../findings/2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md).
> Gates through 2026-07-27 carried that as an *unstated* precondition, having
> all run on `6.18.40-video-port-kasan-rockchip-rk3588`. The
> [2026-07-28 re-run](../../findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md)
> moved every gate onto `6.18.40-ysp-rockchip64`
> (`6.18.40+rk3588av1fwport20260725-0ubuntu1~rk2`), which sets neither
> `CONFIG_KASAN` nor `CONFIG_DMABUF_DEBUG`, with the **installed** post-fix
> `mpp 1.5.0+git20260727.d8c6b88a` and `librga 2.2.0`. The precondition is now
> satisfied by the production kernel rather than assumed. Running this driver on
> `~rk1` would still be expected to fault.

| Path | Exposure | Evidence as of 2026-07-28 | Boundary |
|------|----------|---------------------------|----------|
| H.264 decode | Default | Conformance and sanitizer coverage; hardware-decoded on-device by stock FFmpeg, GStreamer `va`, VLC 3.0.23 and Firefox 153.0 | Chromium display gate remains; Firefox ran with its RDD sandbox disabled |
| VP9 Profile 0 decode | Default | Conformance and sanitizer coverage; byte-exact through the GStreamer `va` readback gate | Not exercised through the VLC/Firefox display gates |
| HEVC Main decode | **Default** | 8/8 pinned vectors byte-exact normally and under ASan/UBSan with the installed `mpp@d8c6b88a`, plus **142 of 163** FATE HEVC Main candidates byte-exact with zero driver failures; hardware-decoded by VLC and Firefox | `NUT_A_ericsson_4/5` are undecodable by MPP itself and `PICSIZE_A/B_Bossen_1` exceed the advertised 7680x4320 constraint; all four fail closed |
| HEVC Main10 decode | Experimental | 10 of 11 FATE Main10 vectors byte-exact as P010 through MPP AFBC V2, crop metadata, and RGA | An AFBC 10-bit frame narrower than 68 luma pixels has [no RGA core that can take it](../../findings/2026-07-29-rga-no-core-match-narrow-afbc-10bit.md), and the driver discovers that mid-decode rather than refusing up front; 10-bit throughput unmeasured and HDR presentation unvalidated |
| VP9 Profile 2 decode | Experimental | P010 output is byte-exact through the same AFBC/RGA path | Same kernel/librga pairing and app gate |
| H.264 Main/High encode | Experimental | FFmpeg CQP/CBR/VBR, GStreamer, planar upload, linear DMA-BUF import, concurrency, sanitizer, RTP, and paced soak smoke pass | One full-frame slice; P010 input, multi-object/tiled import, full WebRTC peer negotiation, and long qualification remain |
| HEVC Main encode | Experimental | FFmpeg/GStreamer output is parser-clean and software-decodable with the RK3588 CTU64 contract; concurrency, sanitizer, and soak smoke pass | Main profile/NV12 only; same imported-surface and qualification gaps |
| AV1 decode/encode | Out of scope | None | RK3588 AV1 uses a separate backend and the required VA-to-MPP reconstruction is not implemented |

## Decode architecture and boundaries

VA applications submit parsed codec parameter/slice buffers, while MPP expects
compressed packets and performs its own parsing. The driver therefore
reconstructs a legal bitstream from VA state and feeds it to MPP. That design
is proven for the supported H.264, HEVC, and VP9 subset, but it creates a
strict validation boundary: ignored syntax or an underspecified reconstructed
header can produce a stream that parses while decoding the wrong picture.

The renovated path replaces the original proof-of-concept's per-frame
CPU-copy/polling model with explicit object generations, retained external
buffer ownership, worker/fence synchronization, and sanitizer/conformance
gates. Ten-bit decode uses MPP AFBC V2 output plus crop metadata, then RGA
converts the native compact layout to application-visible P010. Kernel and
librga must be treated as a pair: an older stride/UV-offset contract can make a
correct VA request produce bad chroma below the driver.

The exact design review, AV1 exclusion, and mainline alternative are preserved
in:

- [driver renovation review](../../findings/2026-07-21-rockchip-vaapi-driver-review.md);
- [bitstream reconstruction and AV1 boundary](../../findings/2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md);
- [mainline V4L2 versus VA-API browser landscape](../../findings/2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md); and
- [Main10/VP9 Profile 2 runtime validation](../../findings/2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md).

## Encode surface contract

The opt-in encoders deliberately accept a narrow, checked surface model:

- VA-created NV12 plus checked I420/YV12 image uploads;
- one-object, one-layer, linear PRIME 2 imports;
- canonical NV12 offsets/pitches for direct MPP submission; or
- zero-offset packed RGBA/RGBX/BGRA/BGRX with an aligned pitch, converted to
  native NV12 through RGA.

The driver duplicates imported fds and owns the duplicates for the surface
lifetime. Every pitch, offset, visible row width, row count, and backing size
is checked before CPU conversion or hardware submission. Multi-object,
tiled/modifier-bearing, and 10-bit encode imports remain rejected rather than
silently reinterpreted.

The measured encode evidence is split by the boundary it closes:

| Evidence | What it proves |
|----------|----------------|
| [H.264 VA encode](../../findings/2026-07-26-rockchip-vaapi-h264-va-encode-validation.md) | FFmpeg/GStreamer interoperability, RC modes, sanitizer, and concurrent decode |
| [HEVC VA encode](../../findings/2026-07-26-rockchip-vaapi-hevc-va-encode-validation.md) | Native CTU64 contract and parser/software-decode interoperability |
| [Planar upload](../../findings/2026-07-26-rockchip-vaapi-planar-encode-upload-validation.md) | Checked I420/YV12 ↔ native-NV12 normalization |
| [PRIME RGB import](../../findings/2026-07-26-rockchip-vaapi-drm-prime-rgb-encode-validation.md) | Owned linear DMA-BUF imports and exact RGA conversion |
| [RTP boundary](../../findings/2026-07-26-rockchip-vaapi-webrtc-rtp-validation.md) | H.264 survives a WebRTC-shaped 1,200-byte-MTU RTP payload/depay path |
| [Dual-codec soak smoke](../../findings/2026-07-26-rockchip-vaapi-dual-encode-soak-smoke.md) | Paced H.264+HEVC resource stability over the measured 60-second smoke window |

## Packaging and browser sandbox boundary

Version `1.0.11+ysp3` produced lintian-clean split driver/config packages in
the dated validation, but publication and clean-image installation are not
proven. Package state belongs in the
[packaging hub](../../packaging/README.md); the fork branch is the source of
truth for the driver and its build/gate targets.

Firefox's RDD process has two independent controls:

1. a broker policy must allow `/dev/mpp_service`, `/dev/rga`, and the DMA-heap
   paths; and
2. seccomp must allow only the measured MPP/RGA ioctl requests in addition to
   the existing DRM/DMA-BUF families.

The source-hash-pinned Firefox 152.0.6 patch implements that narrow policy
without setting `MOZ_DISABLE_RDD_SANDBOX`. Its Ubuntu package configured and
compiled partway before being deliberately stopped; no binary or live runtime
gate exists. See the
[RDD policy](../../findings/2026-07-26-firefox-rdd-rockchip-vaapi-policy.md)
and [package checkpoint](../../findings/2026-07-26-firefox-rdd-package-build-checkpoint.md).

Chromium, VLC, mpv, and GStreamer have different device/display integration
boundaries. Do not infer their success from the driver gates; use the
[per-app map](../../docs/app-enablement.md). In particular, VLC's headless
dummy video output never supplies a VA decoder device, so a clean headless
fallback is not hardware evidence.

## Next gate

Finish the pinned Firefox 152.0.6 arm64 package, inspect the produced binaries,
install it on the ROCK 5B, and prove live H.264/VP9 hardware decode with:

- the RDD sandbox still enabled;
- driver frame/audit markers showing `rockchip-vaapi` actually loaded;
- MPP/RGA device access limited to the pinned broker/ioctl policy;
- a real Wayland/X11/DRM-capable display path; and
- software fallback tested separately rather than counted as a pass.

Keep experimental 10-bit and encode qualification separate from this shipping
decode gate.

## Evidence map

The dated findings are measurements and review snapshots; this README is the
maintained capability/boundary summary.

| Topic | Evidence |
|-------|----------|
| Original code review and renovation decision | [`2026-07-21-rockchip-vaapi-driver-review.md`](../../findings/2026-07-21-rockchip-vaapi-driver-review.md) |
| Browser API alternatives | [`2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md`](../../findings/2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md) |
| AV1 reconstruction boundary | [`2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md`](../../findings/2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md) |
| HEVC/Main10/VP9 Profile 2 | [`2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md`](../../findings/2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md) |
| HEVC TILES same-ID PPS regression | [`2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md`](../../findings/2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md) |
| Intermediate HEVC boundary (superseded) | [`2026-07-26-rockchip-vaapi-hevc-rps-and-p010-boundary.md`](../../findings/2026-07-26-rockchip-vaapi-hevc-rps-and-p010-boundary.md) |
| H.264 and HEVC encode | [H.264](../../findings/2026-07-26-rockchip-vaapi-h264-va-encode-validation.md), [HEVC](../../findings/2026-07-26-rockchip-vaapi-hevc-va-encode-validation.md) |
| Surface uploads/imports | [planar](../../findings/2026-07-26-rockchip-vaapi-planar-encode-upload-validation.md), [PRIME RGB](../../findings/2026-07-26-rockchip-vaapi-drm-prime-rgb-encode-validation.md) |
| RTP and soak | [RTP](../../findings/2026-07-26-rockchip-vaapi-webrtc-rtp-validation.md), [soak](../../findings/2026-07-26-rockchip-vaapi-dual-encode-soak-smoke.md) |
| Firefox policy/package | [RDD policy](../../findings/2026-07-26-firefox-rdd-rockchip-vaapi-policy.md), [package checkpoint](../../findings/2026-07-26-firefox-rdd-package-build-checkpoint.md) |
| VLC display-device boundary | [`2026-07-26-vlc-headless-vaapi-device-boundary.md`](../../findings/2026-07-26-vlc-headless-vaapi-device-boundary.md) |
