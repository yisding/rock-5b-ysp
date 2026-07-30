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
| Current state | As of 2026-07-29, roadmap development is committed and pushed as `rockchip-vaapi` `main@5d558fa`. **H.264, VP9 Profile 0 and HEVC Main decode are the default capability set**; HEVC Main10, VP9 Profile 2, and H.264/HEVC encode remain opt-in experiments. HEVC/VP9 10-bit decode sustains more than 260 fps at 1080p through AFBC→P010; VLC presents Main10; linear two-object imports, equal-row multi-slice, same-process 2-decode/2-encode stress, native WebRTC peers, and the two-hour encode soak pass. Exact Published MPP/FFmpeg binaries pass the complete isolated HEVC sweep, normal plus ASan/UBSan shipping matrices, and a 7,200-second/216,005-frame 4K decode soak with no RSS or fd growth, but still await host installation. Final driver/config version `1.0.11+ysp6-0ubuntu1~rk1` passes exact-commit source/binary builds, Lintian error gates, and isolated package lifecycle; its source is signed but not uploaded, and the installed driver remains `1.0.11+ysp5`. Firefox/Panfrost Main10, patched-browser packaging, physical HDR/mpv, Chromium GL, and clean-image/release gates remain. |

For the end-to-end technical model, module map, decode/encode sequences,
DMA-BUF ownership rules, bridge renovation record, and remaining design
boundaries, read the
[architecture and bridge guide](docs/architecture.md).

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

| Path | Exposure | Evidence as of 2026-07-29 | Boundary |
|------|----------|---------------------------|----------|
| H.264 decode | Default | Conformance and sanitizer coverage; hardware-decoded on-device by stock FFmpeg, GStreamer `va`, VLC 3.0.23 and Firefox 153.0 | Chromium display gate remains; Firefox ran with its RDD sandbox disabled |
| VP9 Profile 0 decode | Default | Conformance and sanitizer coverage; byte-exact through the GStreamer `va` readback gate | Not exercised through the VLC/Firefox display gates |
| HEVC Main decode | **Default** | 8/8 pinned vectors byte-exact normally and under ASan/UBSan; the exact Published `mpp@3381fd2c`/FFmpeg `33a651a55b` package root produces **144 of 163** FATE HEVC Main candidates byte-exact, 17 classified skips, two size refusals, and zero backend/driver failures; hardware-decoded by VLC and Firefox | `PICSIZE_A/B_Bossen_1` exceed the advertised 7680x4320 constraint and fail closed; host installation of the exact package pair remains |
| HEVC Main10 decode | Experimental | 10 of 11 FATE Main10 vectors byte-exact as P010 through MPP AFBC V2, crop metadata, and RGA; `491533e` refuses 64×240 at context creation; 240 1080p frames complete at 261.38 fps; VLC presents all 120 generated frames | AFBC 10-bit widths below 68 have [no eligible RGA core](../../findings/2026-07-29-rga-no-core-match-narrow-afbc-10bit.md); Firefox/Panfrost rejects the GR1616 chroma EGL image; physical HDR passthrough remains unvalidated |
| VP9 Profile 2 decode | Experimental | P010 output is byte-exact through the same AFBC/RGA path; 240 visible/254 decoded 1080p outputs complete at 261.08 fps | Same kernel/librga pairing; browser/display qualification remains |
| H.264 Main/High encode | Experimental | FFmpeg CQP/CBR/VBR, GStreamer, planar upload, one-/two-object linear DMA-BUF import, equal-row multi-slice, same-process concurrency, sanitizer, RTP/WebRTC peers, and a 7,200-second soak pass | P010 input, B-frames, packed application headers, and tiled imports remain unsupported |
| HEVC Main encode | Experimental | FFmpeg/GStreamer output is parser-clean and software-decodable with the RK3588 CTU64 contract; equal-row multi-slice, same-process concurrency, sanitizer, and the two-hour dual-codec soak pass | Main profile/NV12 only; P010 backend support, B-frames, packed headers, and tiled imports remain |
| AV1 decode | Unadvertised design | The vendor AV1 endpoint is independently hardware-validated; source inspection now bounds a direct `/dev/mpp_service` backend that would translate parsed VA state into VDPU jobs and attach CDF/segmentation/MV state to explicit surfaces | No direct VA job or golden replay exists; hardware stream packing, state transitions, output layout, recovery, film grain, conformance, and app/sandbox gates remain |
| AV1 encode | Out of scope | None | No implementation plan or validation |

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

The exact design review, AV1 packet-reconstruction boundary, direct vendor
backend, and mainline alternative are preserved in:

- [driver renovation review](../../findings/2026-07-21-rockchip-vaapi-driver-review.md);
- [bitstream reconstruction and AV1 boundary](../../findings/2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md);
- [direct AV1 `/dev/mpp_service` backend design](docs/av1-direct-mpp-service-backend.md);
- [mainline V4L2 versus VA-API browser landscape](../../findings/2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md); and
- [Main10/VP9 Profile 2 runtime validation](../../findings/2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md).

The direct design bypasses userspace libmpp, not the kernel MPP service. It
would replace the AV1 parser/HAL/allocator slice with a checked, version-pinned
VDPU job compiler and a small ioctl transport. This is a proposed implementation
boundary, not evidence that AV1 VA-API works.

## Encode surface contract

The opt-in encoders deliberately accept a narrow, checked surface model:

- VA-created NV12 plus checked I420/YV12 image uploads;
- one-layer linear PRIME 2 imports, with one canonical object or separate
  zero-offset luma/chroma objects;
- canonical one-object NV12 offsets/pitches for direct MPP submission;
- separately validated two-object NV12/P010 normalized privately under
  DMA-BUF CPU synchronization; or
- zero-offset packed RGBA/RGBX/BGRA/BGRX with an aligned pitch, converted to
  native NV12 through RGA.

The driver duplicates imported fds and owns the duplicates for the surface
lifetime. Every pitch, offset, visible row width, row count, and backing size
is checked before CPU conversion or hardware submission. Tiled/modifier-bearing
imports remain rejected rather than silently reinterpreted. P010 import and
readback are valid surface contracts, but P010 encode remains unadvertised
because the MPP `vepu5xx` backend rejects its compact input format.

The measured encode evidence is split by the boundary it closes:

| Evidence | What it proves |
|----------|----------------|
| [H.264 VA encode](../../findings/2026-07-26-rockchip-vaapi-h264-va-encode-validation.md) | FFmpeg/GStreamer interoperability, RC modes, sanitizer, and concurrent decode |
| [HEVC VA encode](../../findings/2026-07-26-rockchip-vaapi-hevc-va-encode-validation.md) | Native CTU64 contract and parser/software-decode interoperability |
| [Planar upload](../../findings/2026-07-26-rockchip-vaapi-planar-encode-upload-validation.md) | Checked I420/YV12 ↔ native-NV12 normalization |
| [PRIME RGB import](../../findings/2026-07-26-rockchip-vaapi-drm-prime-rgb-encode-validation.md) | Owned linear DMA-BUF imports and exact RGA conversion |
| [RTP boundary](../../findings/2026-07-26-rockchip-vaapi-webrtc-rtp-validation.md) | H.264 survives a WebRTC-shaped 1,200-byte-MTU RTP payload/depay path |
| [Dual-codec soak smoke](../../findings/2026-07-26-rockchip-vaapi-dual-encode-soak-smoke.md) | Paced H.264+HEVC resource stability over the measured 60-second smoke window |
| [Roadmap qualification closure](../../findings/2026-07-29-rockchip-vaapi-roadmap-phase2-phase4-closure.md) | Two-object import, multi-slice, 2-decode/2-encode concurrency, WebRTC peers, and the full 7,200-second soak |

## Packaging and browser sandbox boundary

Version `1.0.11+ysp5` is installed and its driver payload matched the built
deb in the dated validation. Final roadmap package
`1.0.11+ysp6-0ubuntu1~rk1` builds exactly from `main@5d558fa` and passes
source/binary Lintian error gates plus the isolated clean
install/upgrade/purge lifecycle. Its source is signed but not yet uploaded,
and the binaries are not installed; genuinely clean-image hardware decode
remains unproven. Package state belongs in the
[packaging hub](../../packaging/README.md); the fork branch is the source of
truth for the driver and its build/gate targets.

Firefox's RDD process has two independent controls:

1. a broker policy must allow `/dev/mpp_service`, `/dev/rga`, and the DMA-heap
   paths; and
2. seccomp must allow only the measured MPP/RGA ioctl requests in addition to
   the existing DRM/DMA-BUF families.

Source-hash-pinned Firefox 152.0.6 and 153.0 patches implement that narrow
policy without setting `MOZ_DISABLE_RDD_SANDBOX`. Companion patches handle a
separate Panfrost P010 boundary: after standards-correct GR1616 EGL import
fails with `EGL_BAD_MATCH`, they retry Firefox's existing RG/GR alternative
once. Both exact-source patch contracts pass and the 152.0.6 affected release
object compiles. The exact signed 153.0 package is quilt-patched as local
`~mt1+ysp1` and building natively on arm64; no completed binary or
sandbox-enabled runtime gate exists.
See the
[RDD policy](../../findings/2026-07-26-firefox-rdd-rockchip-vaapi-policy.md)
and [package checkpoint](../../findings/2026-07-26-firefox-rdd-package-build-checkpoint.md).

Chromium, VLC, mpv, and GStreamer have different device/display integration
boundaries. Do not infer their success from the driver gates; use the
[per-app map](../../docs/app-enablement.md). In particular, VLC's headless
dummy video output never supplies a VA decoder device, so a clean headless
fallback is not hardware evidence.

## Next gate

The exact Published MPP `3381fd2c` and FFmpeg `33a651a55b` package root already
passes the complete 163-vector HEVC sweep, normal plus ASan/UBSan shipping
matrices, and a 7,200-second/216,005-frame 4K decode soak with no RSS or fd
growth. Install those versions through APT and confirm installed
payload/runtime identity.
Then finish the pinned Firefox 153.0 arm64 package, inspect the produced
binaries, install it on the ROCK 5B, and prove live H.264/HEVC Main/Main10
hardware decode with:

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
| AV1 direct vendor-backend design | [`docs/av1-direct-mpp-service-backend.md`](docs/av1-direct-mpp-service-backend.md), with [dated design tombstone](../../findings/2026-07-29-rockchip-vaapi-direct-av1-mpp-service-design.md) |
| HEVC/Main10/VP9 Profile 2 | [`2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md`](../../findings/2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md) |
| Narrow AFBC 10-bit refusal and fallback | [`2026-07-29-rga-no-core-match-narrow-afbc-10bit.md`](../../findings/2026-07-29-rga-no-core-match-narrow-afbc-10bit.md), with the remediation plan in [`docs/narrow-10bit-closure-plan.md`](docs/narrow-10bit-closure-plan.md) |
| HEVC TILES same-ID PPS regression | [`2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md`](../../findings/2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md) |
| Intermediate HEVC boundary (superseded) | [`2026-07-26-rockchip-vaapi-hevc-rps-and-p010-boundary.md`](../../findings/2026-07-26-rockchip-vaapi-hevc-rps-and-p010-boundary.md) |
| H.264 and HEVC encode | [H.264](../../findings/2026-07-26-rockchip-vaapi-h264-va-encode-validation.md), [HEVC](../../findings/2026-07-26-rockchip-vaapi-hevc-va-encode-validation.md) |
| Surface uploads/imports | [planar](../../findings/2026-07-26-rockchip-vaapi-planar-encode-upload-validation.md), [PRIME RGB](../../findings/2026-07-26-rockchip-vaapi-drm-prime-rgb-encode-validation.md) |
| RTP and soak | [RTP](../../findings/2026-07-26-rockchip-vaapi-webrtc-rtp-validation.md), [soak smoke](../../findings/2026-07-26-rockchip-vaapi-dual-encode-soak-smoke.md), [full roadmap qualification](../../findings/2026-07-29-rockchip-vaapi-roadmap-phase2-phase4-closure.md) |
| Firefox policy/package | [RDD policy](../../findings/2026-07-26-firefox-rdd-rockchip-vaapi-policy.md), [package checkpoint](../../findings/2026-07-26-firefox-rdd-package-build-checkpoint.md) |
| VLC display-device boundary | [`2026-07-26-vlc-headless-vaapi-device-boundary.md`](../../findings/2026-07-26-vlc-headless-vaapi-device-boundary.md) |
