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
| Current state | As of 2026-08-05, the published baseline remains `1.0.11+ysp12-0ubuntu1~rk1`, built from clean release source and verified 17/17 bit-exact on kernel `6.18.42`; the host now has locally built **`1.0.11+ysp13-0ubuntu1~rk1` installed**. Its installed driver matches the deb payload at SHA-256 `ed578a241803f35f51ccc6afe38b1d132539ae48ca691b5a3180e37565fe56c0`, but its source is still dirty, uncommitted, changelog-`UNRELEASED`, and unpublished. **H.264, VP9 Profile 0 and HEVC Main decode remain the default capability set**; HEVC Main10, VP9 Profile 2, and encode remain opt-in. Ysp13 preserves pre-decode NV12/P010 export identity and passes the exact 24-frame retained-export gate, focused lifecycle/sanitizers, all 17 conformance cases, and the complementary 1,440-frame zero-copy audit. Google Chrome 151 now renders H.264 correctly instead of green through installed ysp13 and selects `VaapiVideoDecoder` for 640x480 VP9 Profile 0; its 384x240 `VpxVideoDecoder` choice matches Chromium's intentional below-360p software priority ([finding](../../findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md)). The stock Google deb uses no sandbox-disabling flags, but `chrome://gpu` and a live `/proc` probe show an unsandboxed GPU process with `Seccomp: 0`; the multiple-thread sandbox-init warning is not yet attributed. XtraDeb Chromium 151 still omits libva and exposes Hantro V4L2 VP8. The broader installed-package campaign belongs to ysp12 and was not repeated wholesale on ysp13. Sandbox-enabled Firefox, physical HDR, automated Google Chrome replay/GPU sandbox, HEVC-in-Chrome, XtraDeb Chromium packaging, clean-image install, 512 MiB CMA, ysp13 commit/publication, and release remain. |

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

## Consumer strategy

The durable consumer is often a standard media framework, not one named
application. `rockchip-vaapi` currently serves three useful classes:

1. **Firefox's direct VA-API decoder**, its only native Rockchip hardware path
   on this BSP-style stack;
2. **GStreamer's standard `va` plugin**, already measured through decode,
   encode and a complete H.264 WebRTC peer path; and
3. **libavcodec's generic VA-API codecs**, already measured through FFmpeg,
   VLC and mpv and used by current Sunshine and OBS integrations.

GNOME Remote Desktop is an incompatible direct client, not evidence that the
encoder lacks consumers: its native backend requires application-authored
packed slice headers that MPP cannot accept. The best next source-contract
matches are Sunshine H.264 SDR and OBS H.264; neither is yet runtime-proven.
RustDesk is a lower-confidence follow-up. XtraDeb Chromium 151's Panfrost/ANGLE
GPU process works and Hantro V4L2 VP8 enumerates, but that binary omits libva.
Google Chrome 151 does load this driver and selects `VaapiVideoDecoder`; its
green-frame retained-export failure is fixed in installed ysp13, H.264 now
presents correctly, and 640x480 VP9 selects VA-API. Automated replay and
sandbox qualification remain open; the stock launch has no disabling flags but
the live GPU process has no seccomp filter. WayVNC
currently requires both H.264
Constrained Baseline and `VAEntrypointVideoProc`, neither of which this driver
advertises. Keep the detailed ranking, source pins and non-priorities in the
[consumer assessment](../../findings/2026-08-04-rockchip-vaapi-consumer-assessment.md)
and the live per-app state in the
[application map](../../docs/app-enablement.md).

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

| Path | Exposure | Evidence as of 2026-08-05 | Boundary |
|------|----------|---------------------------|----------|
| H.264 decode | Default | Conformance and sanitizer history; installed ysp8 is bit-exact and hardware-presents through GStreamer `va`, VLC 3.0.23, mpv 0.41.0, and Firefox 153.0.1; installed ysp13 fixes Google Chrome 151's green frame and the operator reports correct presentation | Google Chrome automation/GPU sandbox and Firefox's RDD sandbox remain; XtraDeb Chromium omits libva |
| VP9 Profile 0 decode | Default | Installed ysp8 is bit-exact through GStreamer and hardware-presents through VLC, mpv, and Firefox; Google Chrome with installed ysp13 selects `VaapiVideoDecoder` at 640x480, while 384x240 intentionally selects software below Chromium's 360p cutoff | Pixel-checked VP9 browser automation/GPU sandbox, XtraDeb Chromium packaging, and Firefox sandbox remain |
| HEVC Main decode | **Default** | The exact Published package root previously produced **144 of 163** FATE candidates byte-exact, 17 classified skips, two size refusals, and zero backend/driver failures; installed ysp8 hardware-presents through VLC, mpv, and Firefox | `PICSIZE_A/B_Bossen_1` each carry an 8440 dimension, so both still exceed the advertised 8192x8192 constraint and fail closed; full sweep was not repeated on ysp8 |
| HEVC Main10 decode | Experimental | Installed ysp8 is P010 bit-exact at 320x240 and 416x240, preserves BT.2020/PQ input metadata, refuses 64-pixel input before RGA, runs 1080p at 110.40 fps, and presents through VLC, mpv, and Firefox/Panfrost; the production forward-port RGA3 path passes 90 repeated runs and 4,320 exact frames at each small geometry, including both cores | Widths below 68 are [permanently unsupported](#declined-narrow-afbc-10-bit-below-68-pixels) as of 2026-08-04; the [dropped write remains rewrite-driver-specific](../../findings/2026-08-02-rga3-forward-port-small-geometry-discriminator.md); no physical HDR or sandbox-enabled Firefox proof |
| VP9 Profile 2 decode | Experimental | Installed ysp8 is P010 bit-exact, runs 1080p at 187.30 fps, and presents through VLC, mpv, and Firefox/Panfrost | Same kernel/librga pairing; one risky pinned vector remains fingerprint-quarantined; Firefox sandbox and physical-output qualification remain |
| H.264 Main/High encode | Experimental | FFmpeg CQP/CBR/VBR, GStreamer, planar upload, one-/two-object linear DMA-BUF import, equal-row multi-slice, same-process concurrency, sanitizer, RTP/WebRTC peers, and a 7,200-second soak pass | P010 input, B-frames and [packed headers](../../findings/2026-08-04-grd-vaapi-encode-blocked-by-packed-slice-headers.md) are permanent MPP/silicon walls, not open work; tiled imports remain an open driver-side gap |
| HEVC Main encode | Experimental | FFmpeg/GStreamer output is parser-clean and software-decodable with the RK3588 CTU64 contract; equal-row multi-slice, same-process concurrency, sanitizer, and the two-hour dual-codec soak pass | Main profile/NV12 only; P010 input, B-frames and [packed headers](../../findings/2026-08-04-grd-vaapi-encode-blocked-by-packed-slice-headers.md) are permanent MPP/silicon walls, not open work; tiled imports remain an open driver-side gap |
| AV1 decode | Unadvertised design | The vendor AV1 endpoint is independently hardware-validated; source inspection now bounds a direct `/dev/mpp_service` backend that would translate parsed VA state into VDPU jobs and attach CDF/segmentation/MV state to explicit surfaces | No direct VA job or golden replay exists; hardware stream packing, state transitions, output layout, recovery, film grain, conformance, and app/sandbox gates remain |
| AV1 encode | Out of scope | None | No implementation plan or validation |
| Deinterlacing | **Not supported** | None — the driver advertises only `VAEntrypointVLD` and `VAEntrypointEncSlice`, so a client cannot request it. MPP's decoder-internal deinterlacer is deliberately disabled: it is 1:N with synthesized timestamps and is incompatible with VA-API decode's 1:1 surface contract | The RK3588 IEP2 block works and is [confirmed standalone on the production kernel](../../findings/2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md); the gap is the missing `VAEntrypointVideoProc`, planned as fork roadmap Phase 6. Interlaced content decodes correctly as coded frames; deinterlacing is the application's job in software |

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

### Declined: narrow AFBC 10-bit below 68 pixels

**Decided 2026-08-04: 10-bit decode at a visible width below 68 will not be
supported.** The driver refuses these contexts up front
(`RK_RGA3_MIN_ACTIVE_WIDTH 68`, `src/convert.h`), and that refusal is now the
intended permanent behavior rather than a gap awaiting closure.

The blocker is the *combination* of the frame's layout and each core's
envelope, not a single missing capability:

| Core | Reads AFBC? | 10-bit raster? | Width floor |
|------|-------------|----------------|-------------|
| RGA3 | yes (`RGA_FBC_MODE` in `rga3_win_data`) | yes | **68** — `input_range` minimum |
| RGA2 | **no** (`.rd_mode = RGA_RASTER_MODE` only) | yes, in and out (`rga2e_input_raster_format[]` / `rga2e_output_raster_format[]` list `RGA_FORMAT_YCbCr_420_SP_10B`) | 2 |

MPP hands 10-bit decode output as AFBC-compressed NV15, so the only core that
can read the frame at all cannot accept its width, and the core that could
accept the width cannot read the format. No core matches. Note the precise
shape: RGA2 is not missing 10-bit support — it is missing AFBC support.

Two paths could still have closed it, and both are declined rather than
disproved. An RGA2 raster path would need MPP to emit *linear* NV15 at these
widths, which was never probed. A CPU NV15-to-P010 repack needs no RGA at all
and would always work. Both were specced in
[`docs/narrow-10bit-closure-plan.md`](docs/narrow-10bit-closure-plan.md); the
cost is not justified by the case, which is one FATE vector
(`WPP_D_ericsson_MAIN10_2.bit` at 64x240) and no real content — no camera,
stream, or container produces 10-bit video narrower than 68 pixels. Failing
closed with a real `VAStatus` is the correct outcome, and applications software-
decode it.

That plan's workstream A — making librga's `imcheck()` honest per core — keeps
its standalone value for every librga consumer and is unaffected by this
decision.

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

**P010 encode is a hardware wall, not pending work.** MPP's shared encoder
format table maps every 10-bit input to the `VEPU5xx_FMT_BUTT` sentinel rather
than a register code — `YUV420SP_10BIT`, `YUV422SP_10BIT`, and each 10-bit
variant below them — and `vepu5xx_set_fmt()` turns that sentinel into
`mpp_err_f("unsupport frame format")` plus `MPP_NOK`
(`mpp/hal/rkenc/common/vepu5xx_common.c` `vepu5xx_yuv_cfg[]` ~:208-245,
`vepu5xx_set_fmt()` ~:569). There is no 10-bit encoder input path to enable, on
either codec: the table is shared by the H.264 and HEVC `vepu580` HALs RK3588
selects. The only way to feed a P010 surface to this encoder is to down-convert
to NV12 first, which discards the precision that motivated the request. Treat
this as a capability statement rather than an open item; `make
probe-mpp-main10-encode` re-demonstrates it. The same applies to **B-frames** —
both MPP encoders assign `is_idr ? I : P` and nothing ever assigns a B slice
type, so `VAConfigAttribEncMaxRefFrames = 1` is honest rather than conservative.
Details and anchors in the
[capability-gap triage](../../findings/2026-08-04-rockchip-vaapi-capability-gap-triage.md).

**Packed headers are a wall too, and the consumer is real.** An earlier
assessment on 2026-08-04 called them "implementable, no current consumer"; both
halves were wrong. GNOME Remote Desktop's native VA-API encoder requires
`SEQUENCE`, `PICTURE`, `SLICE` and `RAW_DATA` **together** and refuses the
device outright without them — which is the previously unrecorded reason the
GRD hardware path goes through FFmpeg. They are nonetheless not implementable
over MPP: GRD authors its own slice headers, while MPP emits a complete slice
NAL as one inseparable unit and exposes no command accepting an external
header. Splicing would need bit-level re-alignment of the entropy-coded payload
and would yield slice headers that misdescribe the encode. Advertising a subset
is not an option either — GRD's probe checks all four bits together, so partial
support would attach and then silently discard slice headers, which the
no-silent-failure rule forbids. Details in the
[GRD VA-API finding](../../findings/2026-08-04-grd-vaapi-encode-blocked-by-packed-slice-headers.md).

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

Driver and config `1.0.11+ysp8-0ubuntu1~rk1` are installed, `dpkg -V` clean,
and the installed driver's SHA-256 exactly matches the file extracted from its
deb. The config package supplies the libva/GStreamer environment contract.
This closes installed-artifact identity and broad in-place runtime validation,
but not source reproducibility: ysp8 was built from a modified worktree over
`main@aee5926`, rather than a clean commit. Genuinely clean-image installation
also remains unproven. Exact hashes, modifications, and gates are in the
[installed ysp8 finding](../../findings/2026-08-02-rockchip-vaapi-ysp8-installed-runtime-validation.md).
Package publication state belongs in the
[packaging hub](../../packaging/README.md); the fork branch is the source of
truth for the driver and its build/gate targets.

Firefox's RDD process has two independent controls:

1. a broker policy must allow `/dev/mpp_service`, `/dev/rga`, and the DMA-heap
   paths; and
2. seccomp must allow only the measured MPP/RGA ioctl requests in addition to
   the existing DRM/DMA-BUF families.

Source-hash-pinned Firefox 152.0.6 and 153.0 patches implement that narrow
policy without setting `MOZ_DISABLE_RDD_SANDBOX`. They are now the only Firefox
patches. The companion chroma-retry pair was deleted on 2026-07-30 (`df14bb6`)
because the P010 boundary it worked around was ours: split chroma was exported
as `0x36315247`, the VA-style `GR16` literal, where `DRM_FORMAT_GR1616` is
`0x32335247`. Mesa's `EGL_BAD_MATCH` was correct and the import never reached
Panfrost. ysp8 exports the real fourcc, and installed Firefox 153.0.1 imported
HEVC Main10 and VP9 Profile 2 through both planes in the isolated virtual
display. Both exact-source sandbox-patch contracts pass and the 152.0.6
affected release object compiles, but the ysp8 display run disabled the RDD
sandbox; no sandbox-enabled runtime result exists.
See the
[RDD policy](../../findings/2026-07-26-firefox-rdd-rockchip-vaapi-policy.md)
and [package checkpoint](../../findings/2026-07-26-firefox-rdd-package-build-checkpoint.md).

Chromium, VLC, mpv, and GStreamer have different device/display integration
boundaries. Do not infer their success from the driver gates; use the
[per-app map](../../docs/app-enablement.md). In particular, VLC's headless
dummy video output never supplies a VA decoder device, so a clean headless
fallback is not hardware evidence.

## Next gate

The next shipping-decode application gate is Firefox with its RDD sandbox
enabled against the installed package. Prove live H.264/HEVC
Main/Main10/VP9 Profile 2 hardware decode with:

- the RDD sandbox still enabled;
- driver frame/audit markers showing `rockchip-vaapi` actually loaded;
- MPP/RGA device access limited to the pinned broker/ioctl policy;
- a physical Wayland/X11/DRM display path, with HDR link metadata tested
  separately; and
- software fallback tested separately rather than counted as a pass.

Keep the risky VP9 vector behind its exact kernel fingerprint. The production
forward-port small-geometry RGA boundary is closed by repeated evidence; boot
validation of the corrected rewrite driver remains a separate rewrite-track
gate.

The next experimental-encode application gate is Sunshine H.264 High SDR/NV12
CBR, followed by OBS H.264. For each, require hardware markers, the exported
R8/GR88 GPU-texture path, force-IDR connection/reconnect behavior, live bitrate
changes, client decode and a soak. Only then try HEVC Main SDR. Do not count
Main10/HDR encode, packed slice headers, B-frames or VA video processing as open
qualification items: they are outside the current backend contract.

The Google Chrome gate no longer waits on a custom browser build or a first
functional replay. Installed ysp13 already presents H.264 correctly and selects
`VaapiVideoDecoder` for 640x480 VP9. Turn those manual observations into an
automated H.264/VP9 gate requiring stable-export copy markers, checked visible
output and no fallback/display errors; add HEVC, then qualify the currently-
disabled GPU sandbox for the MPP, RGA and DMA-heap device/ioctl surface.
First attribute the stock launch's multiple-thread `InitializeSandbox()`
warning and require a live GPU process that reports sandboxed with an active
seccomp filter. Rebuilding XtraDeb
Chromium with both `use_vaapi=true` and `use_v4l2_codec=true` remains a separate
distribution-parity gate, with Hantro VP8 retained as its A/B control.

## Evidence map

The dated findings are measurements and review snapshots; this README is the
maintained capability/boundary summary.

| Topic | Evidence |
|-------|----------|
| Google Chrome VA-API enumeration, retained-export green frame, installed H.264 fix, and VP9 selection | [`2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md`](../../findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md) |
| Chromium 151 GPU recovery, V4L2-only package, and mixed-backend gate | [`2026-08-04-chromium-151-gpu-working-v4l2-only.md`](../../findings/2026-08-04-chromium-151-gpu-working-v4l2-only.md) |
| Consumer model and next application encode targets | [`2026-08-04-rockchip-vaapi-consumer-assessment.md`](../../findings/2026-08-04-rockchip-vaapi-consumer-assessment.md) |
| Installed ysp8 package/runtime and application matrix | [`2026-08-02-rockchip-vaapi-ysp8-installed-runtime-validation.md`](../../findings/2026-08-02-rockchip-vaapi-ysp8-installed-runtime-validation.md) |
| Forward-port RGA3 repeated small-geometry discriminator | [`2026-08-02-rga3-forward-port-small-geometry-discriminator.md`](../../findings/2026-08-02-rga3-forward-port-small-geometry-discriminator.md) |
| Original code review and renovation decision | [`2026-07-21-rockchip-vaapi-driver-review.md`](../../findings/2026-07-21-rockchip-vaapi-driver-review.md) |
| Browser API alternatives | [`2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md`](../../findings/2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md) |
| AV1 reconstruction boundary | [`2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md`](../../findings/2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md) |
| AV1 direct vendor-backend design | [`docs/av1-direct-mpp-service-backend.md`](docs/av1-direct-mpp-service-backend.md), with [dated design tombstone](../../findings/2026-07-29-rockchip-vaapi-direct-av1-mpp-service-design.md) |
| HEVC/Main10/VP9 Profile 2 | [`2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md`](../../findings/2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md) |
| Narrow AFBC 10-bit refusal (**declined 2026-08-04**) | [`2026-07-29-rga-no-core-match-narrow-afbc-10bit.md`](../../findings/2026-07-29-rga-no-core-match-narrow-afbc-10bit.md), with the declined remediation plan in [`docs/narrow-10bit-closure-plan.md`](docs/narrow-10bit-closure-plan.md) |
| HEVC TILES same-ID PPS regression | [`2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md`](../../findings/2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md) |
| Intermediate HEVC boundary (superseded) | [`2026-07-26-rockchip-vaapi-hevc-rps-and-p010-boundary.md`](../../findings/2026-07-26-rockchip-vaapi-hevc-rps-and-p010-boundary.md) |
| H.264 and HEVC encode | [H.264](../../findings/2026-07-26-rockchip-vaapi-h264-va-encode-validation.md), [HEVC](../../findings/2026-07-26-rockchip-vaapi-hevc-va-encode-validation.md) |
| Surface uploads/imports | [planar](../../findings/2026-07-26-rockchip-vaapi-planar-encode-upload-validation.md), [PRIME RGB](../../findings/2026-07-26-rockchip-vaapi-drm-prime-rgb-encode-validation.md) |
| RTP and soak | [RTP](../../findings/2026-07-26-rockchip-vaapi-webrtc-rtp-validation.md), [soak smoke](../../findings/2026-07-26-rockchip-vaapi-dual-encode-soak-smoke.md), [full roadmap qualification](../../findings/2026-07-29-rockchip-vaapi-roadmap-phase2-phase4-closure.md) |
| Firefox policy/package | [RDD policy](../../findings/2026-07-26-firefox-rdd-rockchip-vaapi-policy.md), [package checkpoint](../../findings/2026-07-26-firefox-rdd-package-build-checkpoint.md) |
| VLC display-device boundary | [`2026-07-26-vlc-headless-vaapi-device-boundary.md`](../../findings/2026-07-26-vlc-headless-vaapi-device-boundary.md) |
