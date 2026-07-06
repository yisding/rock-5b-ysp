# Clean-room rewrite drivers — `mpp-rewrite` & `rga-rewrite`

A second, independent implementation track: **public-API-only reimplementations
of the `/dev/mpp_service` and `/dev/rga` userspace ABIs**, written from the ABI
knowledge documented in [uAPI guide](./dev-uapis.md) rather than by carrying the
BSP code. This is the *opposite* strategy to the conservative forward-port
([forward-port guide](../../kernel-versions/docs/vendor-forward-port.md), which keeps ~98% of the vendor code
byte-identical, [vendor delta](./vendor-delta.md)): here the BSP `.c` files are
not used at all, and every kernel interface is a public one — devm-managed
MMIO/IRQ/clock/reset discovery, public `dma_buf_attach`/`map` for fd imports,
the public DMA API (`dmam_alloc_coherent`) for RCB scratch instead of the BSP's
fixed-IOVA SRAM reservation, runtime PM, and plain threaded IRQs.

> **Status: advanced bring-up, not yet the shipped replacement.** MPP now covers
> the observed RK3588 userspace ABI with no required command intentionally left
> unsupported. RGA has grown from the initial blit/fill subset into a broad
> practical `librga`/FFmpeg feature subset, including RK3588 AFBC16x16, 10-bit,
> alpha-overlay, color-key, OSD, palette, gauss, quantize, ROP, mosaic,
> rotate/translate/padding border copies, packed-YUV422/420 fill, Y4/Y8 compact/full-CSC dither
> output, BPP palette sources, AFBC-to-AFBC ffmpeg filter copies, mixed RGA2/RGA3 task batches, async
> acquire/release fences, OSD external colors, RGA2 pre-intr line interrupts,
> per-core scheduler counters, and aggregate/per-core hardware timing counters
> (`hw_total_ns*` / `hw_max_ns*`). MPP applies DT
> `rockchip,normal-rates` through the public clock framework for BSP-style
> fixed-rate performance setup without private devfreq. The remaining gap is hardware validation: no conformance
> record comparable to the forward-port's exists yet (§6). The support repo now
> has versioned wrappers for the official MPP test matrix, including generated
> VP9 IVF input for explicit VP9 decode cases, official librga sample suite,
> JeffyCN GStreamer plugin, and ffmpeg-rockchip CLI coverage, plus comparators that flag
> required forward-port passes missing from the rewrite and can enforce an
> elapsed-time slowdown ceiling with `PERF_MAX_RATIO`; `debugfs-counter-check.sh`
> can additionally require positive rewrite hardware-start/busy-time counter
> deltas and fail timeout/fault/error deltas, and the profile runner defaults
> those positive checks for rewrite hardware suites when
> `PROFILE=*rewrite* RUN_COUNTER_CHECKS=1`. The direct RGA smoke case
> is now part of the librga suite's required set and records deterministic
> destination-buffer byte counts/SHA-256s for maintained im2d,
> RKNN/RKNPU-style preprocessing including RGBA crop/letterbox, legacy
> GStreamer-shaped and display-shaped `c_RkRgaBlit()`,
> forced-core, pre-intr, AFBC16x16, tile8x8, Gaussian, and async fence paths. The broad official
> librga sample binaries remain primarily
> pass/fail/timing coverage until a current-userspace gap needs sample-specific
> output capture. The FFmpeg suite generates shared software H.264/H.265 inputs,
> probes current `ffmpeg-rockchip` decoder, encoder, and RGA filter options,
> runs decoder-option null-output cases, generated H.264/H.265 encoder-option
> encodes, H.264->RGA->HEVC and HEVC->RGA->H.264 hardware transcodes,
> required `scale_rkrga` forced-core/async/AFBC-output and `vpp_rkrga`
> crop/transpose coverage, and diagnostic decoder `afbc=rga` plus
> `overlay_rkrga` alpha composition. Encoded outputs record byte counts/SHA-256s
> for forward-port-vs-rewrite comparison. The default GStreamer
> suite now includes asset-free encoder, RGA-conversion, decoder roundtrip,
> generated elementary-stream H.264/H.265 decode/transcode, generated VP9 IVF
> decode, opt-in generated AV1 and legacy VP8/H.263/MPEG diagnostics,
> caps-renegotiation, explicit
> flush-event, force-key-unit, EOS-loop, state-loop, and parallel
> encode/decode/transcode pipelines so the
> next hardware pass exercises decoder-side buffer groups, short-timeout
> polling, info-change, parser-driven decoder caps changes, reset,
> media-file parser/decode, decoder-side RGA
> conversion, DMABuf caps/allocator handoff, in-pipeline drained encoder
> reset on caps changes, encoder/decoder flush reset with post-flush output,
> encoder force-key events that call `MPP_ENC_SET_IDR_FRAME`,
> explicit encoder control-property application through `MPP_ENC_SET_CFG`,
> including codec-specific QP controls and H.264 profile/level,
> common direct H.264/H.265 encoder input formats I420/YUY2/UYVY/RGB16/ARGB/ABGR/xRGB/xBGR,
> encoder max-pending and unaligned-vstride default handling,
> strict decoder property application through `MPP_DEC_SET_PARSER_FAST_MODE`,
> env-default decoder control, DMA-feature, output-format, and FBC/ARM-AFBC
> default-alias application,
> generated H.264 RGBA/BGRA/RGBx/BGRx decoder-side RGA output formats,
> MPP-only encode/decode with `GST_MPP_NO_RGA=1`,
> repeated encoder/decoder drain-to-EOS reuse,
> multi-session scheduling, generated H.264/H.265 AFBC/FBC decode output,
> generated H.264 crop-meta output, and decode->encode transcode before
> external media assets are staged. Its diagnostic set now also covers
> VP8/JPEG/VPx-alpha element visibility, the optional `vp8enc` alias from
> `GST_MPP_VP8ENC_FAKE_VP8ENC`, VP8/JPEG encoder property setters,
> JPEG decoder explicit/default output format selection, RFBC caps negotiation,
> generated VP9 transcode, opt-in generated AV1 and legacy decode/transcode probes,
> opt-in display/KMS env-default paths,
> the opt-in external `GST_VIDEO_FLIP_USE_RGA=1` `videoflip` RGA path, and
> the GStreamer-visible RGA format matrix for BGR16/RGB/BGR/BGRA/RGBx/NV16/NV61
> encoder preprocessing and
> BGR16/RGB/BGR/RGBA/BGRA/RGBx/BGRx/NV21/NV16/NV61/I420/YV12 decoder-side output
> conversion. The in-repo direct `librga` smoke
> covers virtual-address imports, dma-heap dma-buf allocation plus `importbuffer_fd`, sync
> copy/resize/fill, RKNN/RKNPU-style RGB/NV12/NV21 preprocessing plus
> RGBA crop/letterbox,
> legacy `c_RkRgaBlit()` conversions shaped like JeffyCN
> GStreamer (`BGRx` malloc source to NV12 dma-buf encoder preprocessing,
> rotated NV12 dma-buf to BGRx dma-buf decode conversion, and planar I420
> dma-buf to NV12 dma-buf fallback) plus a public display/compositor-shaped
> fd-backed BGRx 90-degree rotation path, no-submit physical-address import plus
> AFBC32x8/RFBC64x4 destination-mode probes, NV12
> raster-to-AFBC16x16-to-raster and raster-to-tile8x8-to-raster round-trips,
> forced RGA3 core-mask + priority submission, forced RGA2 `IM_PRE_INTR`, the official Gaussian matrix
> `IM_GAUSS` public sample shape, and an async acquire/release-fence chain, but
> these still need to be run on a booted rewrite kernel. When launched through
> `librga-suite.sh`, the smoke records deterministic destination artifacts for
> forward-port-vs-rewrite comparison. The rewrite now also carries the RGA3
> Route B userptr mapping slice: dma-buf imports remain fail-closed unless they
> map as one 32-bit-safe segment, while driver-owned pinned userptr sg-tables
> can be mapped through one contiguous IOMMU IOVA span for direct-librga/RKNN
> virtual-buffer compatibility. The shipped,
> hardware-validated stack is still the forward-port
> ([kernel status](./forward-port-status.md), [`status.md`](../../status.md)). Location + pin in
> §6.

| | Forward-port (`mpp/`, `rga3/`) | Rewrite (`mpp-rewrite/`, `rga-rewrite/`) |
|---|---|---|
| Code origin | Rockchip 6.1 BSP, ~98% unchanged | written from scratch against the documented ABI |
| Kernel APIs | BSP-isms shimmed via `compat/` (vendor-forward-port.md §A) | public APIs only, no shims |
| Kernel target | pinned to 6.18 API surface (resyncing.md hazards) | built on 6.18; being brought up on current mainline master too (§5) |
| Userspace ABI | full BSP surface | the documented subset current `mpp-rockchip`/`librga`/`ffmpeg-rockchip` actually use |
| Audit posture | 89 verified findings latent ([BSP audit](./bsp-audit.md)) | small, reviewable, refcount-disciplined by construction |
| Size (observed 2026-07-06) | MPP ~15,822 lines + RGA3 ~19,171 lines (vendor-delta.md method) | MPP rewrite ~9,211 lines + RGA rewrite ~18,024 lines |

Kconfig makes the two tracks **mutually exclusive per device node**:
`ROCKCHIP_MPP_REWRITE` depends on `!ROCKCHIP_MPP_SERVICE` and registers
`/dev/mpp_service` in its place; `ROCKCHIP_RGA_REWRITE` depends on
`!ROCKCHIP_MULTI_RGA && !VIDEO_ROCKCHIP_RGA` and registers `/dev/rga`
(`mpp-rewrite/Kconfig`, `rga-rewrite/Kconfig`). The rewrite binds the *same DT
nodes* as the forward-port: `rockchip,rkv-encoder-v2-core`,
`rockchip,rkv-decoder-v2`, both CCU compatibles (`mpp_rewrite.c:526-530`) and
the RGA2/RGA3 compatibles incl. the mainline `rockchip,rk3588-rga`
(`rga_rewrite.c:16336-16344`).

Important codec boundary: neither the forward-port nor the MPP rewrite currently
exposes RK3588 AV1 through `/dev/mpp_service`. AV1 lives on a separate
Verisilicon/VPU981 hardware block, with a separate BSP `mpp_av1dec.c` backend and
a dedicated AV1 IOMMU. The newer upstream-style `../kernel/linux` tree has a clean
`vsi-iommu` provider and Hantro/V4L2 stateless AV1 support, but that is not the
same userspace ABI as RKMPP. See [RK3588 AV1 decode, IOMMU, and userspace
paths](../av1/docs/av1-rk3588.md).

The codec line is intentionally narrower than the names that FFmpeg and
GStreamer can advertise. `ffmpeg-rockchip` registers AV1, H.263, H.264, HEVC,
MJPEG, MPEG-1, MPEG-2, MPEG-4, VP8, and VP9 RKMPP decoders, upstream FFmpeg
8.1.2 registers H.264, HEVC, VP8, and VP9 RKMPP decoders, JeffyCN
`mppvideodec` exposes similarly broad caps, and the same GStreamer plugin
registers VP8/JPEG encoder or decoder elements when userspace probing succeeds.
It may also register a conditional VPx-alpha decodebin when built against a new
enough GStreamer for the alpha demux/combine helpers.
That is userspace discovery, not proof that every codec maps to the RK3588
rewrite's hardware nodes. The current rewrite target binds only RKVDEC2/RKVENC2
plus their CCUs, matching the Rock 5B DT; it does not bind the legacy VDPU/VPU
or JPEG nodes that libmpp uses for older formats.

| Userspace-visible codec path | Rewrite classification | Why |
|------------------------------|------------------------|-----|
| H.264 decode, H.265 decode | required | libmpp uses the RKVDEC/VDPU383 path; these are the validated forward-port decoder paths. |
| H.264 encode, H.265 encode | required | libmpp and FFmpeg use RKVENC2/VEPU580, the encoder core pair this rewrite implements. |
| VP9 decode | required for current decoder parity, still hardware-unvalidated | libmpp's decoder HAL chooses `VPU_CLIENT_RKVDEC` for VP9, and the VDPU383 HAL has a VP9 backend. The YSP conformance wrappers now generate VP9 IVF inputs for GStreamer and direct MPP tests; KUnit covers the VP9 RKVDEC fd-to-IOVA register-translation/validation path; hardware logs are still pending. |
| VP8, MPEG-1/2/4, H.263 decode | recognized current-userspace names, outside the RK3588 rewrite profile | libmpp routes these through VDPU1/VDPU2-era clients, not the RKVDEC2 nodes the rewrite binds. Adding them would mean importing legacy VPU blocks, contrary to the no-cruft objective unless a current RK3588 workload proves the need. The GStreamer suite has opt-in generated VP8/H.263/MPEG diagnostics so this boundary is executable instead of implicit. |
| MJPEG decode/encode | recognized current-userspace names, outside the RK3588 rewrite profile | RK3588 has separate JPEG decoder/encoder hardware and BSP drivers, but this rewrite does not bind those nodes; the project status keeps JPEG as a skipped/non-goal path. |
| AV1 via RKMPP | recognized current-userspace name, outside this RKMPP rewrite | The RK3588 AV1 block has separate hardware/IOMMU/backend plumbing; the maintained path for this project is V4L2 stateless AV1, not `/dev/mpp_service`. The GStreamer suite has opt-in generated AV1 diagnostics so this remains executable evidence instead of an undocumented omission. |

Each driver carries an in-tree **`ABI.rst`** — a precise
implemented / recognized-but-unsupported / out-of-scope ledger of the BSP ioctl
surface. Those files are the authority; §2/§3 below transcribe the durable
knowledge. The current source pins are in §6 and
[source-tree pins](../../docs/source-trees.md) §8. The detailed line-number
anchors in the older ledger sections can drift as the rewrite grows; the
in-tree `ABI.rst` files at the §6 pins are the authority for the current
implemented / unsupported / outside-slice boundary.

---

## 1. Size, shape, and upstream-RGA comparison

The RGA rewrite being larger than the MPP rewrite is expected. The codec side of
`/dev/mpp_service` is mostly a register-job conveyor: userspace MPP/HAL code
builds codec-specific register images, while the kernel validates the message
stream, translates fd references to IOVAs, writes registers, handles IRQs and
timeouts, and copies readback registers to userspace. The kernel does not encode
H.264/H.265 policy or build codec recipes.

The `/dev/rga` ABI is more semantic. Userspace asks for blit/fill/scale/
color-convert/rotate/alpha operations with real image formats, strides, planes,
rectangles, fences, compression modes, and core masks. The kernel must normalize
those requests, choose an RGA2/RGA3-capable core, map buffers against that core's
DMA device, and emit the command words itself. That format and feature matrix is
why both the vendor RGA3 driver and the rewrite are bigger than their MPP peers.

That also changes the line-count expectation. The MPP rewrite still looks
structurally much smaller than the BSP forward-port because it mostly transports
userspace-built register jobs and keeps the codec recipe policy in MPP userspace.
The RGA rewrite has already grown substantially as parity moved from
copy/resize/fill into real `librga` and FFmpeg profiles: every extra RGA feature
adds validation, format/layout math, command emission, lifetime handling, and
tests. It remains smaller than the vendor RGA3 directory today, but it should no
longer be expected to stay tiny if feature parity remains the goal.

The RGA rewrite is not a fundamentally different hardware model from the vendor
RGA3 driver: the ABI and silicon force the same broad stages (copy request,
resolve buffers, pick a core, emit commands, wait for an IRQ). The difference is
in ownership and maintenance shape. The vendor driver is a broad BSP subsystem
with global `rga_drvdata`, scheduler policy, `rga_mm`, debug/procfs machinery,
legacy SoC compatibility, KERNEL_VERSION gates, and page-table walking. The
rewrite keeps the `/dev/rga` ABI but uses session-owned ids, refcounted imports
and jobs, job-owned per-core mappings, public dma-buf/DMA APIs, and explicit
`-EOPNOTSUPP` boundaries for profiles it does not yet emit. If it ends up near
the vendor size, the win is still clearer ownership, less BSP baggage, and an
auditable public-API driver. If it drifts into copied vendor tables and quirks,
that advantage shrinks.

### Upstream-style V4L2 RGA3 in `../kernel/linux`

The separate upstream-oriented RGA support compared on 2026-07-02 was the sibling
`../kernel/linux` checkout on branch `rk3588-rewrite-mainline` at commit
`180ee72a9a80`, now reachable in the public `linux-rock5b/rk3588-rewrite-mainline`
history. The relevant tree is `drivers/media/platform/rockchip/rga/`, about
3,168 lines.

That driver is **not** a smaller `/dev/rga` replacement. It is a mainline-style
V4L2 mem2mem driver (`/dev/videoX`) with `V4L2_CAP_VIDEO_M2M_MPLANE |
V4L2_CAP_STREAMING`, `VB2_MMAP | VB2_DMABUF` queues, and RK3588 binding through
`rockchip,rk3588-rga3` -> `rga3_hw`. For RGA3, the command path programs one
source window (`WIN0`) to the writeback path (`WR`): scale, format/stride/CSC,
addresses, command buffer, master-mode start, and frame-done IRQ. It deliberately
exposes only the first RGA3 core until multicore scheduling lands.

Besides multicore, the current RGA3 V4L2 path is missing these vendor/librga
capabilities:

- No `/dev/rga` ABI or `librga` compatibility: no Rockchip buffer handles,
  request create/config/submit ioctls, core masks, multi-task requests, or
  explicit `sync_file` ioctl surface.
- No RGA3 rotate/flip/background-color controls. The generic V4L2 controls exist
  only behind feature flags, and `rga3_hw.features = 0`.
- No second input (`WIN1`), pattern/overlay composition, or Porter-Duff alpha
  blend surface. The RGA3 command code explicitly uses only `WIN0` because two
  inputs are not supported there yet.
- No RGA3 color fill, pattern fill, ROP, color key, OSD, mosaic, dither, or
  neural-network/quantize helpers from the vendor/librga feature surface.
- No compressed or tiled layouts: no AFBC/RFBC/FBC/tile decode or encode.
- Narrower format coverage: no 10-bit YUV, no YUV444, no planar YUV on RGA3,
  and several RGB formats are input-only.
- Incomplete crop/compose semantics for RGA3. The V4L2 selection API stores crop
  and compose rectangles, but the RGA3 command generator currently uses only the
  source crop width/height and full output size; it does not program source
  offsets or arbitrary destination placement.
- Thin error and recovery handling: the RGA3 IRQ path clears interrupts and
  returns frame-done status, but does not yet provide vendor-style error-bit
  diagnosis, timeout recovery, or reset policy.

So the upstream V4L2 driver is small because its current contract is narrow:
one-source scale/convert/blit through V4L2. It is the right mainline direction,
but it is not close to the vendor `/dev/rga`/`librga` feature surface yet.

## 2. MPP ABI ledger (`mpp-rewrite/ABI.rst`)

### Implemented

| Area | What the rewrite does | Anchor |
|------|----------------------|--------|
| `MPP_IOC_CFG_V1` message parsing | incl. **multi-message batches**; userspace message order preserved; write-like payloads copied before the ioctl returns; staged jobs in one batch are submitted before poll requests are processed in message order, matching the forward-port trigger-then-wait ordering | `mpp_rewrite.c:2346` (`cmd != MPP_IOC_CFG_V1` reject) |
| `MPP_CMD_SET_SESSION_FD` | session switching, restricted to fds that are themselves `/dev/mpp_service` files; switching closes the current staged job and starts a distinct job for subsequent messages; bad-fd slots report `-EBADF` through `mpp_bat_msg.ret`, and `MPP_BAT_MSG_DONE` slots skip the following task group without touching the previous session; the dormant libmpp batch-server wait-array shape is recognized and rejected with `-EOPNOTSUPP` instead of adding multi-`LAST_MSG` continuation semantics | `:2371` |
| Platform binding | RK3588 BSP-style RKVENC2/RKVDEC2 core + CCU nodes; devm MMIO/IRQ/clock/reset; DT `rockchip,normal-rates` applied through the public clock framework before clocks are enabled | `:274-277` |
| `QUERY_HW_SUPPORT` / `QUERY_HW_ID` / `QUERY_CMD_SUPPORT` | from bound cores; `QUERY_HW_ID` returns the register-0 hardware id captured at probe — preserving the forward-port's userspace-visible **HAL-selection contract** (how-the-drivers-work.md §9, dev-uapis.md) | `:473` |
| procfs discovery markers | minimal `/proc/mpp_service/supports-cmd` + `support_cmd` (read-only compatibility markers so current `mpp-rockchip` enables command probing — *not* the BSP debug/control procfs) | `:592-595` |
| `INIT_CLIENT_TYPE`, `INIT_DRIVER_DATA` (no-op), `RESET_SESSION`, `SEND_CODEC_INFO` | validated per-session state | |
| `MPP_CMD_INIT_TRANS_TABLE` | BSP-compatible **`u16` table element width** (`u16 trans_table[]`, `:169`) with KUnit coverage for successful load, oversize rejection, copy-fault return, and zero-size count reset — an ABI fact not obvious from the header | |
| `TRANS_FD_TO_IOVA` / `RELEASE_FD` | public dma-buf attach/map/unmap against a bound client hw device; explicit translation maps on the default matching core for compatibility, while the session cache is keyed by fd + DMA device and `RELEASE_FD` drops all cached mappings for that fd; KUnit covers the all-DMA-device sweep for one fd while preserving other fd imports | |
| `MPP_CMD_SET_ERR_REF_HACK` | validated **copy-in/discard** — issued by current `mpp-rockchip` for VDPU382 H.264 capability probing and must be *accepted*, not rejected (§4); KUnit now covers the initialized-session gate plus zero-size, stack-buffer, heap-buffer, oversize, and copy-fault outcomes | |
| Register jobs | flat register-image materialization (`SET_REG_WRITE`), bounded readback retention (`SET_REG_READ`), validated offset tuples (`SET_REG_ADDR_OFFSET`) with KUnit coverage for staging, duplicate-index additive apply, malformed sizes, zero-size no-op, and cap handling; fd→IOVA translation via the session table or built-in per-client default tables (`rk_mpp_rkvdec_h264d_regs[]` etc., `:325-380`), with translated dma-bufs mapped against the selected core's DMA device; VP9 RKVDEC coverage now asserts the VP9 table translates only VP9-owned fd registers and rejects unknown RKVDEC formats | |
| Job/import lifetime | translated jobs hold references on every imported dma-buf mapping (so `RELEASE_FD`/`RESET_SESSION`/close can't tear a prepared job's mappings down); **refcounted batch/session/hw job ownership** so poll vs reset vs close vs IRQ can't free a live job; `SET_SESSION_FD` batch switching splits staged jobs correctly without carrying dormant batch-server status writeback | |
| Execution slice | queued, least-loaded dispatch across bound RK3588 encoder/decoder cores; runtime-PM resume, bulk clock enable, range-checked MMIO writes from the original `SET_REG_WRITE` spans, start-register deferral, **IRQ-driven completion**, retained `SET_REG_READ` readback, BSP-style irq-status override, decoder RLC decoded-length adjustment; contended submits queue internally instead of returning `-EBUSY` | |
| RKVDEC2 CCU modes / link tables | DT `rockchip,ccu-mode` is honored with BSP-style SOFT as the default/invalid fallback; SOFT programs the CCU coordination registers and starts the selected core directly, while HARD remains opt-in and keeps the VDPU383/RKVDEC2 link-MMIO start, link-table allocation/materialization/readback, running-list/add-mode handling, fixed-RCB link-latch setup, peer-core power ownership transfer, table-complete scanning, error containment, timeout recovery, unfinished-chain relink, and resend using public DMA/IOMMU APIs | |
| Fault/recovery | per-core timeout completion, public IOMMU fault callbacks, post-reset IOMMU refresh, and `-EIO` completion on matched active faults are implemented without private Rockchip IOMMU page-table walking | |
| `MPP_CMD_POLL_HW_FINISH` / `MPP_CMD_POLL_HW_IRQ` | nonblocking `POLL_HW_FINISH` on a pending job returns `-EAGAIN` without consuming the session-visible active job; poll results are returned through the ioctl result like the reachable direct libmpp path, not per-slot dormant batch-server status writeback; RKVENC2 slice result streaming advertises `POLL_BUTT`, detects split mode from the submitted register image (`slen_fifo` + slice split), stores IRQ slice-length words in a job-owned FIFO, copies up to userspace `count_max`, and falls through to normal completion/readback on the final slice; non-split IRQ polls use the full-frame finish path | |
| `MPP_CMD_SET_RCB_INFO` | BSP-compatible `(register index, size)` descriptors per session; per-core **coherent scratch via the public DMA API** sized from DT `rockchip,rcb-iova`; decoder gate on `rockchip,rcb-min-width` using retained `SEND_CODEC_INFO` width — no fixed-IOVA SRAM | `:2483-2492` |
| KUnit coverage | optional `ROCKCHIP_MPP_REWRITE_KUNIT_TEST` for ABI parser and staging helpers, including command range classification, command group boundary queries, payload-copy classification, `SET_ERR_REF_HACK` copy/discard behavior, translation-table storage, release-fd import sweeping, public `RESET_SESSION`/file-close import and queued/active job cleanup, hardware-active reset cleanup with retained active-job import mappings, register-offset staging/apply, register-span overflow checks, nonblocking pending-poll retention, `SET_SESSION_FD` invalid-fd/done-marker behavior, dormant batch-server wait-array recognition plus collector-level `-EOPNOTSUPP` rejection without status-slot writeback, `POLL_HW_IRQ` flexible-buffer sizing, VP9 RKVDEC fd-to-IOVA translation/validation, and RKVENC2 slice-mode detection | |

### Recognized but unsupported

- Dormant libmpp batch-server wait arrays are recognized as repeated
  `SET_SESSION_FD` + `POLL_HW_FINISH|POLL_NON_BLOCK|LAST_MSG` pairs and return
  `-EOPNOTSUPP`.  Current libmpp has no wired callers for `MPP_DEV_BATCH_ON`,
  and the BSP collector stops at the first `LAST_MSG` for normal submissions.

### Outside this slice

Board-level stress validation of hard-CCU timeout/error recovery under real
IOMMU faults, runtime suspend, and decoder reset races; MPP fence export/import
semantics if current userspace evidence appears; and `MPP_IOC_CFG_V2` (which
the BSP-derived 6.18 driver also rejects in the observed path).

---

## 3. RGA ABI ledger (`rga-rewrite/ABI.rst`)

The hard-won **librga ABI facts** — what the rewrite's ABI.rst records that
real `librga`/`ffmpeg-rockchip` consumers require of a `/dev/rga`
implementation (cross-reference:
[userspace library guide](../../vendor-libraries/docs/how-the-userspace-libs-work.md) Part B):

- **Version tuples are capability keys.** `librga` capability-probing expects
  the RK3588 hardware-version tuples **RGA2E `3.2.63318`** and **RGA3
  `3.0.76831`** from `RGA_IOC_GET_HW_VERSION`
  (`rga_rewrite.c:15694-15707` — `{3, 2, 0x63318}` / `{3, 0, 0x76831}`,
  rendered `"%x.%01x.%05x"` at `:1302`, hence the hex-looking revision). Report
  the wrong tuple and librga silently selects the wrong per-core capability
  profile.
- **Both ioctl generations must exist**: legacy `RGA_GET_VERSION` /
  `RGA2_GET_VERSION` *and* modern `RGA_IOC_GET_HW_VERSION` /
  `RGA_IOC_GET_DRVIER_VERSION` (sic — the BSP typo is ABI, dev-uapis.md; `:745`).
  `RGA2_GET_VERSION` returning `true` after copying the version string is
  intentional BSP/librga ABI behaviour, not a bug.
- **Legacy `RGA_CACHE_FLUSH`, `RGA_FLUSH`, `RGA_GET_RESULT`, and
  `RGA2_GET_RESULT` are safe as BSP-compatible no-ops** (`:15658-15663`) —
  userspace does not depend on their side effects.
- **Buffer import**: `RGA_IOC_IMPORT_BUFFER`/`RELEASE_BUFFER` for dma-buf fds
  *and* user virtual addresses — VA imports pin user pages, build sg_tables via
  `sg_alloc_table_from_pages()` (`:15050`), try normal public DMA mapping first,
  validate the resulting span, and for RGA3 scattered userptr fall back to a
  driver-owned contiguous IOMMU IOVA mapping. DMA-buf imports stay fail-closed
  unless they resolve to one 32-bit-safe DMA segment. Legacy
  no-handle `wrapbuffer_fd()`/`wrapbuffer_virtualaddr()` blits are converted to
  job-owned temporary imports; **direct physical-address channels remain
  unsupported**.
- **Modern request config is staging, not submit.** `RGA_IOC_REQUEST_CONFIG`
  copies the userspace task array into the session request, resolves
  imported-buffer handles to mapped IOVAs, keeps the request id live, and does
  not submit hardware or export a release fence by itself. `RGA_IOC_REQUEST_SUBMIT`
  is the terminal submit path. KUnit covers the handle-backed staging path and
  the submit-side clone shape, the public CONFIG ioctl staging path with
  kernel-owned acquire-fd close and no release-fence export, plus an async
  acquire-fence submit ioctl that returns a release-fence fd before deferred
  dispatch and signals it with the eventual backend result. KUnit also covers
  public CANCEL and file-close cleanup of configured request imports and
  acquire-fence references.
- **Acquire-fence ownership**: when a submitted task clears
  `feature.user_close_fence` (`:811`, `:2661-2674`), the *kernel* closes the
  imported acquire-fence fd after taking its own `dma_fence` reference
  (matching the forward-port's compatibility path for older userspace); when
  set, userspace keeps fd-close ownership. Async jobs own an internal release
  fence, export its fd, and complete via IRQ thread / per-core timeout worker
  KUnit now covers the current `librga`/GStreamer legacy `RGA_BLIT_SYNC`
  default path waiting for queued completion without copying an output fence or
  translated addresses back to userspace, the legacy `RGA_BLIT_ASYNC` copy-out
  path (`rga_req.out_fence_fd`), and the modern request-submit
  `release_fence_fd` path for jobs deferred behind an acquire fence, and
  direct dispatch coverage for legacy flush/result no-op ioctls used by
  librga's post-blit compatibility path, plus
  file-close cleanup of async jobs still pending on unsignaled acquire fences
  and jobs already queued on hardware, and last-hardware removal cleanup of
  async jobs still pending on acquire fences.
- **BSP `rga_req.core` scheduler masks are honored**: RGA3 bits `0x1`/`0x2`,
  RGA2 bits `0x4`/`0x8`; imported images are **rebound to the selected core's
  DMA device at dispatch**, so a forced-core `wrapbuffer_fd()` submission works.
  A mask that names only an absent core is rejected instead of being rerouted to
  a different present core; masks that include a present compatible core still
  schedule normally.
- **Per-core profile coverage** (what real librga/ffmpeg consumers need):
  - **RGA3**: raster, AFBC16x16, and tile8x8 bitblits, including simple
    raster-to-tile, tile-to-raster, and tile-to-tile semiplanar-YUV paths;
    RGB/YUV plus compact and unpacked 10-bit semiplanar YUV paths used by
    current `librga` and `ffmpeg-rockchip`; source crop and destination
    offsets; resize interpolation selectors; rotate/flip/mirror, including
    centered rotate and padding border commands for reflect/wrap; RGB color-key for
    normal/inverted-selector `imcolorkey`;
    Porter-Duff A+B alpha blend for public `librga` modes including CLEAR but
    not unlisted modes, including mixed-depth no-pattern semiplanar 8/10-bit
    YUV source/destination conversions; current RK3588 `im2d_slt` three-channel
    RGB/RGBA foreground plus RGB/RGBA background scale-up into a semiplanar YUV
    destination with pattern/background rectangle offsets; mixed-depth
    pattern-backed ffmpeg/RKMPP overlay paths; AFBC writeback with BSP-style
    overlap-offset programming for supported alpha-overlay/copy profiles; and
    overlay pre-processing copies into offset pattern images.
  - **RGA2**: solid fill, YUV fill including packed YUV422 destination
    formats, rectangle/fill arrays, raster bitblit for fallback formats RGA3
    does not cover, planar/semiplanar YUV,
    YCbCr400/gray, NV24/NV42, RGB555-family, ARGB/ABGR output, compact 10-bit
    source, recognized-but-unsupported RGA2-Pro RFBC64x4/AFBC32x8 source
    modes rejected with `-EOPNOTSUPP`,
    full-CSC RGB→YUV, gray256 conversion, Y400 UV downsample,
    Y4/Y8 compact/full-CSC dither output for current `librga` paths,
    rotate/mirror, in-place RGB mosaic, ROP, gaussian blur, NN quantize, RGB
    alpha-bitmap, RGBA color-key for current forced-core `imcolorkey`
    normal/inverted modes, OSD alpha overlay, and color palette/update-palette
    commands including BPP1/2/4/8 sources, plus `IM_PRE_INTR` read/write line
    interrupt programming for already-supported RGA2 bitblit/fill profiles.
  - Multi-task requests run serially under one completion/fence when every task
    matches a supported profile. Mixed RGA2/RGA3 batches now validate the whole
    request up front and select an eligible backend per task; current `librga`
    copy-splice and fill/mosaic task-array shapes are covered.
  - Minimal debugfs counters now report scheduled, dispatched, and
    hardware-started work per public RGA core bit (`rga3_core0`, `rga3_core1`,
    `rga2_core0`, `rga2_core1`) so board validation can confirm forced-core and
    load-balancing behaviour, including same-class equal-load tie rotation,
    without the BSP debug ABI.
- **Remaining recognized RGA gaps** are now comparatively specific: physical
  address imports; full general RGA2/RGA3 policy and command-register
  generation; RGA3 pattern modes outside the supported alpha-overlay profile;
  RGA3 color-key outside the implemented RGB/RGBA `imcolorkey` shapes;
  Y4/Y8 full-CSC output outside the current RGB-to-YUV `librga` path;
  per-channel rotation; RFBC/AFBC32x8 source and destination modes; tile
  alpha/pattern/color-key or other
  non-simple bitblit variants; and non-bitblit operation modes outside the
  implemented RGA2 subsets.
- **Public `librga` users outside the current conformance set** were surveyed
  on 2026-07-04 and refreshed on 2026-07-05 by GitHub code search, excluding
  the already-covered ffmpeg-rockchip, JeffyCN GStreamer, and official librga
  sample paths.  The
  raw survey note is
  [`findings/2026-07-04-librga-consumer-survey.md`](../../findings/2026-07-04-librga-consumer-survey.md).
  The
  strongest additional Linux signal is RKNN/RKNPU preprocessing:
  [airockchip/rknn_model_zoo](https://github.com/airockchip/rknn_model_zoo/blob/bad6c7334531becaf90a561988519b7bec34d0ab/utils/image_utils.c),
  [rockchip-linux/rknpu2](https://github.com/rockchip-linux/rknpu2/blob/5adf7c1bd17e169e9880ccdf3b49adde925ab7f9/examples/rknn_yolov5_demo/src/preprocess.cc),
  and
  [rockchip-linux/rknpu2's RKNN memory handoff demo](https://github.com/rockchip-linux/rknpu2/blob/5adf7c1bd17e169e9880ccdf3b49adde925ab7f9/examples/rknn_api_demo/src/rknn_create_mem_with_rga_demo.cpp)
  exercise RGB/RGBA/NV12/NV21 resize, crop/letterbox, and color conversion
  through `imresize()`, `improcess()`, direct `wrapbuffer_virtualaddr()` /
  `wrapbuffer_fd()` / `wrapbuffer_fd_t()` paths, handle imports, and RKNN
  tensor-memory fd handoff.  Jellyfin and downstream NAS packaging use the
  same ffmpeg-rockchip RKRGA filters and `c_RkRgaBlit()` ABI already covered by
  `ffmpeg-suite.sh`, not a separate direct-librga kernel profile.  Some
  model-zoo utility code carries physical-address import branches, but the
  common example paths are fd or virtual-address buffers; physical import stays
  recognized-but-unsupported unless a target workload proves it is mandatory.
  Android camera/HAL and display users
  ([hardware-rockchip-camera](https://github.com/ruihe-rockchip/hardware-rockchip-camera),
  [hardware-rockchip-hwcomposer](https://github.com/rockchip-android/hardware-rockchip-hwcomposer),
  [frameworks-native](https://github.com/aosp-rockchip/android_frameworks_native))
  are broad real consumers, but they mainly validate an Android allocator /
  GraphicBuffer / HWC compatibility goal, not the current Linux Rock 5B target.
  Other public Linux users such as
  [PaddlePaddle/FlyCV](https://github.com/PaddlePaddle/FlyCV/blob/develop/modules/img_transform/crop/src/crop_rv1109.cpp),
  [varphone/rkrga](https://github.com/varphone/rkrga),
  [libv4l-rkmpp](https://github.com/sz-jack-01/libv4l-rkmpp),
  [RetroArch OGA](https://github.com/libretro/RetroArch/blob/master/gfx/drivers/oga_gfx.c),
  LVGL/SDL Rockchip RGA patches, Orbbec ROS decoder helpers, RKMedia demos, and
  small Qt/DRM camera apps cluster around the same legacy blit, fd/virtual
  import, RGB/RGB565/RGBA/NV12-family scale/convert/rotate feature set.  This
  survey found no current Linux-media evidence that RFBC64x4/AFBC32x8,
  per-channel rotation, tile alpha/pattern/color-key, or broad RGA2-Pro modes
  should move into the required rewrite profile.  The in-repo
  `ysp_librga_smoke` now covers the highest-value RKNN-shaped paths: virtual
  RGB888 `imresize()`, fd-backed RGB/NV12/NV21 `improcess()` resize/convert,
  fd-backed RGBA source-crop into an RGB letterbox rectangle, legacy RGB
  `c_RkRgaBlit()` resize, a no-submit physical-address import probe that
  can be made a rewrite-only expected reject with
  `LIBRGA_SMOKE_EXPECT_PHYSICAL_REJECT=1`, and public-API
  raster-to-AFBC32x8/RFBC64x4 destination-mode probes that become rewrite-only
  expected rejects with `LIBRGA_SMOKE_EXPECT_FBC_TAIL_REJECT=1`.  It also
  records public-API NV12 raster-to-AFBC16x16-to-raster and
  raster-to-tile8x8-to-raster artifacts for the supported RGA3 compressed/tile
  subset.  The
  `librga-suite.sh` wrapper enables both negative assertions by default for
  `PROFILE=*rewrite*` runs while leaving forward-port runs observational.
  It also turns the display/compositor/game-UI survey signal into an executable
  fd-backed BGRx `c_RkRgaBlit()` 90-degree rotation artifact, without promoting
  Android-only allocator/HWC paths into the Linux RK3588 required profile.
- **Unsupported profiles fail *late* by design**: `-EOPNOTSUPP` is returned
  only after copy/validate/prepare/queue/dispatch/import-resolve/power-sequence
  reach the backend boundary — so the scheduler/lifetime path is exercised even
  for profiles the command generator can't emit yet.
- **Userspace-visible priorities after the GStreamer legacy sync-blit/no-op ioctl KUnit slices** are
  driven by `../rockchip-conformance`, especially JeffyCN's
  `gstreamer-rockchip` branch at `dcbcd6454ef8`.  There are no paired
  forward-port/rewrite conformance logs yet, so the immediate missing artifact
  is a booted hardware run, not another BSP feature.  The support repo now has
  `tests/gstreamer-suite.sh` and `tests/gstreamer-suite-compare.sh`; its default
  required set covers element inspection, raw NV12 encode, encoder-side legacy
  RGA conversion, asset-free H.264/H.265 encode->parse->decode roundtrips,
  generated elementary-stream H.264/H.265 `filesrc` decode, generated VP9 IVF
  `filesrc` decode, opt-in generated AV1 IVF `filesrc` decode diagnostics,
  opt-in generated VP8/H.263/MPEG `filesrc` decode diagnostics for advertised
  legacy caps,
  H.264/H.265 decode->encode transcode including an RGA rotate/scale path,
  generated `mppvideodec dma-feature=true` DMABuf decode, the matching
  `GST_MPP_DEC_DMA_FEATURE=1` environment-default DMABuf path, and
  DMABuf-to-encoder handoff, generated H.264/H.265 strict decoder property cases for
  `fast-mode=false`/`ignore-error=false`, the matching H.264 strict decoder
  environment-default path, the H.264 `GST_MPP_VIDEODEC_DEFAULT_FORMAT=NV21`
  output-format default path, required generated H.264
  RGBA/BGRA/RGBx/BGRx decoder-side RGA output formats, required generated H.265 Main10
  decode/RGA/fallback coverage for `GST_MPP_DEC_DISABLE_NV12_10`, optional
  generated H.265 4:2:2 10-bit coverage for `GST_MPP_DEC_DISABLE_NV16_10`,
  opt-in external-media H.265 10-bit decode/fallback coverage, generated
  H.264/H.265 decoder caps-renegotiation through
  concatenated elementary streams with different dimensions, decoder-side RGA
  90/180/270-degree rotate/format-convert, encoder-side RGA 90/180/270-degree
  rotate/scale, in-pipeline H.264/H.265 encoder caps-renegotiation
  through two differently sized raw NV12 segments, explicit H.264/H.265
  encoder control-property cases for header/SEI/rate-control/GOP/re-encode
  config plus packet copy-out, encoded H.264/H.265 CBR/FIXQP rate-control
  artifacts, codec-specific H.264/H.265 QP controls,
  common direct H.264/H.265 encoder input formats
  I420/YUY2/UYVY/RGB16/ARGB/ABGR/xRGB/xBGR,
  H.264 `GST_MPP_NO_RGA=1` MPP-only encode/decode,
  H.264 `GST_MPP_ENC_MAX_PENDING` outstanding-frame default handling,
  H.264 `GST_MPP_ENC_UNALIGNED_VSTRIDE=1` prep-stride programming,
  and H.264 profile/level controls,
  encoder and decoder `FLUSH_START`/`FLUSH_STOP` event handling with required
  post-flush output, encoder `GstForceKeyUnit` events that drive
  `MPP_ENC_SET_IDR_FRAME`, repeated encoder/decoder drain-to-EOS reuse in one
  process, repeated state-loop reset, parallel H.264 encode,
  parallel H.264 encode->decode roundtrip, generated same-codec/mixed-codec
  parallel decode, and mixed H.264/H.265 decode->encode transcode
  pipelines for multi-session scheduling evidence, generated H.264/H.265 AFBC/FBC decode
  output, and the matching H.264 `GST_MPP_VIDEODEC_DEFAULT_FBC=1` /
  `GST_MPP_VIDEODEC_DEFAULT_ARM_AFBC=1` default paths, plus generated
  decode-AFBC-to-encode-AFBC transcodes that exercise explicit
  `arm-afbc=true` and `GST_MPP_ENC_DEFAULT_ARM_AFBC=1` encoder input paths with
  encoded artifacts, plus generated H.264 crop-meta output from
  `crop-rectangle`; its
  diagnostic set also includes seek-event probes through the same
  `gstreamer-event-harness`,
  VP8/JPEG/VPx-alpha element visibility, the optional `vp8enc` alias from
  `GST_MPP_VP8ENC_FAKE_VP8ENC`, VP8 QP and JPEG quality-factor property
  setters, JPEG decoder explicit/default BGRx output selection,
  `GST_MPP_DEC_FBC_IS_RFBC=1` RFBC caps negotiation, generated VP9-to-H.264
  transcode, opt-in generated AV1 and legacy VP8/H.263/MPEG decode/transcode
  diagnostics, and
  a diagnostic GStreamer-visible encoder-format matrix covering chip-dependent
  direct H.264/H.265 MPP input formats NV24/Y444 plus RGA-forced encoder-side
  NV21/I420/YV12/BGR16/RGB/BGR/BGRA/RGBx/NV16/NV61
  scale paths plus remaining decoder-side
  BGR16/RGB/BGR/NV21/NV16/NV61/I420/YV12 output-format paths.  The runner now
  has opt-in external `videoflip` diagnostics for the Rockchip
  `GST_VIDEO_FLIP_USE_RGA=1` path, covering NV12/BGRx clockwise rotation and
  BGRx horizontal flip; keep these cases diagnostic unless the runtime is known to
  carry the patched element and rewrite counters prove `/dev/rga` submission.
  It also has opt-in display/DMABuf sink cases for JeffyCN's `rkximagesink`, including
  linear DMABuf, AFBC decode output, `KMSSINK_DISABLE_VSYNC=1`, and
  `GST_RKXIMAGE_USE_COLORKEY=1`, and opt-in `kmssrc` KMS-capture cases
  that feed DRM framebuffer-exported DMABufs into `mpph264enc`, including the
  `GST_KMSSRC_DMA_FEATURE=1` env-default path, and loop them through the display
  sink.  The remaining media-backed GStreamer evidence is
  still a booted display/KMS-plane run plus forward-port vs rewrite timing data.
  Source review of the plugin
  shows the
  highest-value RGA paths are legacy `c_RkRgaBlit()` submissions from fd-backed
  MPP frames or Gst DMABuf memory into MPP-owned destination buffers:
  NV12/NV21/I420/YV12/NV16/NV61 plus RGB/RGBA/BGRx/RGBx families, scale,
  color-convert, and 0/90/180/270-degree rotation.  Recent kernel slices add
  named and matrix RGA KUnit coverage for RGB-family/NV16/NV61-to-NV12 encoder
  preprocessing, NV12/NV21/NV16/NV61 plus compact 10-bit decoder output to
  RGB-family formats, compact NV12_10LE40/NV16_10LE40 decoder output to scaled
  8-bit NV12/NV16, planar I420/YV12-style RGA2 fallback, the remaining
  180/270-degree GStreamer rotation values, display-shaped BGRx rot90, and the current
  `librga`/GStreamer direct-buffer fd-vs-virtual-address classification; the
  direct `librga` smoke mirrors the highest-value JeffyCN legacy-convert shapes
  through public `c_RkRgaBlit()`.  The missing evidence is still the
  booted plugin run, including the newly generated VP9 IVF decode cases that
  match JeffyCN's advertised `video/x-vp9` sink caps.  The
  highest-value MPP
  behaviours are `reset()` under flush/state changes, external MPP buffer-group
  handoff, nonblocking input/output timeouts, zero-copy encoded packets, and
  optional AFBC decode/encode negotiation.  Lower-priority diagnostic profiles
  are physical-address imports, Android GraphicBuffer/CMA allocators, CFA, and
  hand-built feature combinations not emitted by current Linux userspace.
- Optional **KUnit coverage** exists on both rewrite drivers: MPP parser helpers
  plus `SET_ERR_REF_HACK`, hard-CCU/link-table, DCHS, IOMMU-fault, `POLL_HW_IRQ`,
  `SET_SESSION_FD`, dormant batch-server wait-array collector rejection, and public reset/file-close cleanup helpers via
  `ROCKCHIP_MPP_REWRITE_KUNIT_TEST`; and RGA
  ABI-normalization, request create/config/cancel lifecycle, handle-backed
  request staging, request reconfiguration resource/acquire-fence/gauss
  replacement and job cloning, request-config ioctl staging/acquire-fd
  ownership, configured request cancel/file-close cleanup, mixed-task
  RGA3-to-RGA2 core handoff/requeue selection, file-close cleanup of async
  pending-acquire and hardware-queued jobs, last-hardware pending-acquire
  cleanup, MPP CCU coordinator dependent queued/active abort coverage,
  RGA3 pattern-channel rotate rejection,
  legacy flush/result no-op ioctl dispatch, legacy sync blit, legacy async
  blit, and modern async request-submit
  acquire/release-fence ioctls,
  import/release-buffer lifecycle, scheduler, fence,
  packed-YUV422/420 fill, Y4/Y8 compact/full-CSC dither output, BPP palette sources,
  RGA2 pre-intr register packing,
  AFBC/tile including AFBC-to-AFBC ffmpeg filter copies,
  RGA2-Pro RFBC64x4/AFBC32x8 source rejection coverage plus public-API
  AFBC32x8/RFBC64x4 destination negative probes,
  crop/destination-offset, blend-mode, SLT alpha-blend,
  OSD/palette/gauss/quantize/ROP/mosaic, JeffyCN GStreamer legacy conversion
  profile and format-matrix helpers, direct-buffer fd/userptr classification,
  direct physical-address submit rejection after temporary import rollback,
  RKNN RGBA crop/letterbox profile command emission,
  zero-count import/release buffer-pool behavior, and ffmpeg-facing profile
  helpers via `ROCKCHIP_RGA_REWRITE_KUNIT_TEST`.

---

## 4. New uAPI facts (cross-folded into dev-uapis.md)

Three BSP ABI facts were learned during the rewrite and encoded in the
`include/uapi/linux/rk-mpp.h` extension (part of the §6 commit — **not** in
`patches/rk3588-rkvenc2-01…`, see [source-tree pins](../../docs/source-trees.md) §7):

| Name | Value | Fact |
|------|-------|------|
| `MPP_CMD_SET_ERR_REF_HACK` | `MPP_CMD_CONTROL_BASE + 4` | issued by current `mpp-rockchip` userspace for **VDPU382 H.264 capability probing**; a compatible kernel must accept it as **copy-in/discard** (rejecting it breaks probing) |
| `MPP_FLAGS_REG_OFFSET_ALONE` | `0x00000010` | the **true BSP name** for the flag dev-uapis.md knew as `REG_NO_OFFSET` (kept as an alias) — it marks the split between plain fd register values and separate offset records |
| `MPP_FLAGS_POLL_NON_BLOCK` | `0x00000020` | non-blocking poll request flag, previously undocumented in this repo |

[uAPI guide](./dev-uapis.md)'s CONTROL-command table and `MPP_FLAGS_*` list
carry these with back-pointers here.

---

## 5. Mainline-master bring-up DT (post-6.18)

The rewrite is also being brought up against **current mainline master**
(v7.2-rc1 era — the dev checkout sits at `665159e24674`), which is where it
differs most interestingly from the 6.18 DT story
([device-tree guide](./device-tree.md)): mainline now ships its own
`vdec0`/`vdec1` `video-codec@fdc38000`/`@fdc40000` nodes (V4L2
`rockchip,rk3588-vdec`), so the decoder can be **converted in place** exactly
like Armbian's `media-0001` path (armbian-packaging.md) — no inline decoder nodes needed.
The local mainline rewrite branch's DT diff: +105 lines `rk3588-base.dtsi`,
+107 lines `rk3588-rock-5b.dtsi`:

- **Encoder + CCUs inline in `rk3588-base.dtsi`** (as in patch 02): `mpp_srv`,
  virtual `rkvenc_ccu`, `rkvenc0/1` @ `fdbd0000`/`fdbe0000` (SPI 101/104,
  MMUs SPI 99+100 / 102+103), MMIO `rkvdec_ccu@fdc30000`, all
  `status = "disabled"`; board dtsi enables them.
- **`rkvenc0`/`rkvenc1` aliases in `base.dtsi`**, commented *"The MPP
  compatibility driver derives core ids from these aliases"* — same
  `of_alias_get_id` contract as the forward-port (device-tree.md §Aliases are
  mandatory).
- **Decoder via `&vdec0`/`&vdec1` overrides in the board dtsi**: retype
  `compatible` to `rockchip,rkv-decoder-v2`, replace `reg` with the vendor
  `regs`/`link` split (`fdc38100`+`fdc38000`, `fdc40100`+`fdc40000`), add the
  vendor properties (`core-mask`, `taskqueue-node = <9>`,
  `task-capacity = <16>`, `rcb-*`, `rockchip,sram = <&vdecN_sram>`), alias
  `rkvdec0 = &vdec0` / `rkvdec1 = &vdec1`, and inherit `interrupts`,
  `iommus`, `power-domains`, and the SRAM pools from mainline's own nodes —
  the post-6.18 variant of device-tree.md's convert-in-place.
- Wiring: `drivers/video/{Kconfig,Makefile}` gain a `rockchip/` subdir that
  contains **only** the two rewrite drivers (no BSP port on master).

**Interrupt reconciliation (board-verified 2026-07-01).** Mainline master pins
`vdec0` = `GIC_SPI 95`, `vdec0_mmu` = 96, `vdec1` = 97, `vdec1_mmu` = 98
(`rk3588-base.dtsi:1400-1457` at the master pin). On the running board (kernel
`6.18.37-current-rockchip64` #7, combined forward-port kernel,
convert-in-place DT), `/proc/interrupts` shows — recalling GIC_SPI *n* = hwirq
*n*+32:

```
GICv3 127 Level fdc38100.video-codec            → GIC_SPI 95  (rkvdec core 0) ✓
GICv3 129 Level fdc40100.video-codec            → GIC_SPI 97  (rkvdec core 1) ✓
GICv3 128 Level fdc38700.iommu, fdc40700.iommu  → GIC_SPI 96  (SHARED by both decoder MMUs)
```

The core IRQs confirm vanilla-kernel.md's previously-UNVERIFIED SPI 95/97. The MMU
observation is the surprise: the running (media-0001-derived) DT has **both**
decoder MMUs on SPI 96 as a shared line, whereas current mainline master gives
`vdec1_mmu` its own SPI 98. Both apparently work (the rockchip-iommu handler
reads per-instance status), but which is TRM-correct is **UNVERIFIED** —
confirm against the TRM before treating either as canonical.

---

## 6. Status & citable location

| Item | State (2026-07-06) |
|------|--------------------|
| Code | `drivers/video/rockchip/mpp-rewrite/` (`mpp_rewrite.c` 9,211 lines; 9,554 total incl. `ABI.rst`, `Kconfig`, `Makefile`) + `drivers/video/rockchip/rga-rewrite/` (`rga_rewrite.c` 18,024 lines; 18,550 total incl. `ABI.rst`, `Kconfig`, `Makefile`) |
| 6.18 state | committed local branch `rk3588-rewrite-6.18` at **`309548773814`** ("media: rockchip: mpp-rewrite: cover batch-server rejection"), committed in dev worktree `/home/yi/Code/kernel/linux-6.18-rkvenc` and replayed on the current `rkvenc-fwport-6.18` forward-port tip **`e059aad8d68b`** from `/home/yi/Code/kernel/linux-6.18-rkvenc-av1-fwport`. It includes the broad RGA/MPP ABI and performance-path work described in §2/§3, the Rock 5B DT self-containment commit for disabled decoder nodes/IOMMUs/SRAM pools, the BSP-derived forward-port recovery cleanup, Rockchip IOMMU `map_pages`/`unmap_pages` count handling for large dma-buf mappings, rewrite MPP/RGA fault-handler registration through the Rockchip provider-local public hook before generic fallback, explicit KUnit coverage for GStreamer decoder-side 8-bit RGBA/BGRA/RGBx/BGRx RGA output conversions, compact NV12_10LE40/NV16_10LE40 decoder-output scaling to 8-bit NV12/NV16, the remaining 180/270-degree GStreamer public rotation values, display-shaped BGRx 90-degree blits, RKNN/RKNPU RGB888/NV12/NV21 preprocessing plus RGBA crop/letterbox command profiles, zero-count RGA import/release buffer-pool behavior, direct physical-address submit rejection after temporary import rollback, VP9 RKVDEC fd-to-IOVA register translation/validation, direct legacy `RGA_BLIT_SYNC` wait/no-fence ioctl behaviour used by the default `c_RkRgaBlit()` path, legacy RGA flush/result no-op ioctl dispatch used by librga's post-blit compatibility path, `SET_ERR_REF_HACK` copy/discard control handling used by current libmpp probing, dormant batch-server wait-array collector rejection with `-EOPNOTSUPP`, RGA2-Pro RFBC64x4/AFBC32x8 source profiles rejected with `-EOPNOTSUPP` instead of carrying an executable FBCIN path, RGA3 Route B userptr IOMMU mapping with fail-closed dma-buf span validation, and `rk_rga_rewrite/route_b/{attempt,ok,active,force_remap}` debugfs counters/knob for development-only fallback attribution. |
| Mainline-master state | committed local branch `rk3588-rewrite-mainline` at **`49913db297cb`** ("media: rockchip: mpp-rewrite: cover batch-server rejection"), committed in sibling worktree `/home/yi/Code/kernel/linux`. It carries the same rewrite drivers and userspace-facing ABI coverage, the mainline DT/wiring work, the Rockchip IOMMU map-count fix, the minimal public `include/soc/rockchip/rockchip_iommu.h` provider fault hook used by the rewrites, and the same GStreamer decoder 8-bit RGB, compact 10-bit YUV-output, 180/270-degree rotation, display-shaped BGRx rot90, RKNN preprocessing plus RGBA crop/letterbox, zero-count RGA import/release buffer-pool behavior, direct physical-address submit rejection after temporary import rollback, VP9 RKVDEC translation, legacy sync-blit ioctl, legacy RGA no-op ioctl, MPP err-ref control, dormant batch-server wait-array collector rejection, RGA2-Pro FBC source rejection coverage, Route B userptr IOMMU mapping, and the same Route B debugfs counters/force knob. |
| Validation | Focused compile gates pass at the committed tips available so far. On 2026-07-06, `kernel-drivers/tests/rewrite-build-gate.sh all` built from `git archive` copies and completed warning-free for `../kernel/linux-6.18-rkvenc` at `309548773814` and `../kernel/linux` at `49913db297cb`, producing the KUnit-enabled `drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o` and `drivers/video/rockchip/rga-rewrite/rga_rewrite.o` targets for both kernels after the MPP batch-server collector-rejection KUnit coverage was added. On the same date, `REWRITE_BUILD_PROFILES="memory race" kernel-drivers/tests/rewrite-build-gate.sh all` also passed warning-free on both trees, proving compile-only coverage for KASAN/fault-injection and KCSAN/lockdep profile configs. Those sanitizer profiles raise `FRAME_WARN` for instrumentation-inflated KUnit stack frames, while the default `normal` profile remains the strict warning gate. The Route B debugfs counter patch also passed strict checkpatch and pre-commit clean-archive focused `rga_rewrite.o` builds on both trees. The updated direct `librga-smoke.cpp` also compiles against the staged aarch64 `librga` and now includes the `rkmppenc`-shaped fd-backed crop/CSC/resize fence chain; runtime remains skipped here because `/dev/rga` is absent. `VALIDATE_ONLY=1 kernel-drivers/tests/rewrite-conformance-run.sh`, `VALIDATE_ONLY=1 PROFILE=rewrite RUN_COUNTER_CHECKS=1 kernel-drivers/tests/rewrite-conformance-run.sh`, and the same counter-enabled validation with `LIBRGA_FORCE_ROUTE_B=1` also passed device-free syzlang ABI-marker, ioctl mutator build, direct `librga` smoke build, RGA IOMMU scatter-fuzzer build, recovery stress harness config validation, MPP/GStreamer case-builder, FFmpeg case-list, and comparator validation, including 26 Rockchip syzlang ABI markers, 1 default MPP case builder, 143 GStreamer case builders, the rewrite counter-default wiring check, the forced Route B counter-default wiring check, and the synthetic multicore prefix-counter selftest, on 2026-07-06. The same validate-only flow now attempts a GStreamer event-harness build and records a skip on hosts without GStreamer development pkg-config files. This is still code/ABI-ledger progress rather than proof from a booted rewrite kernel. The broader conformance plan remains the staged `../rockchip-conformance` forward-port-vs-rewrite workflow for MPP, librga, JeffyCN GStreamer, and ffmpeg-rockchip; booted MPP official-test artifact/timing runs, direct virtual-address Route B RGA3 runs with `route_b/attempt` and `route_b/ok` evidence, kill/reset/unbind recovery stress logs, GStreamer state/allocator/RGA-conversion/P010-P210/VP9/display/KMS-capture results, and expanded FFmpeg decoder/RGA-filter artifact/timing results are still missing before lower-priority diagnostic BSP profiles. **UNVERIFIED in this repo**: the workload gate and expanded conformance bundle have not yet passed on hardware through the rewrite; no validation record equivalent to status.md exists yet. |

GStreamer, FFmpeg, and MPP differential testing are now stronger than the table
row's historical summary: generated H.264/H.265 inputs, generated VP9 IVF
input, opt-in generated AV1 IVF input, and opt-in generated legacy
VP8/H.263/MPEG inputs are cached under the shared
conformance assets directory; generated plus
optional external-media GStreamer decode/transcode outputs, FFmpeg encoded
bitstreams from transcode, forced-core/AFBC, VPP, and diagnostic overlay paths,
and MPP official-test media outputs are recorded in `artifacts.tsv`
with byte counts and SHA-256s. GStreamer/FFmpeg comparators require those
manifests by default; the MPP comparator compares manifests when present and can
enforce them with `REQUIRE_ARTIFACTS=1` for full media gates.
The non-submit ioctl mutator also has an opt-in `IOCTL_FUZZ_FAIL_NTH_MAX`
mode for debug kernels, which ties `/proc/self/fail-nth` allocation/usercopy
failures to individual MPP/RGA ioctls, with optional `IOCTL_FUZZ_OUT` plus
dmesg before/after snapshots for KASAN/Oops/lockdep evidence. No booted rewrite
fail-nth log is recorded yet.

## 7. Path to production readiness

The §6 validation row is a *code/ABI-ledger* record, not proof from a booted
rewrite kernel. [`rewrite-validation-plan.md`](./rewrite-validation-plan.md) is
the risk-ordered plan to close that gap: the instrumented kernels (including a
net-new KCSAN build), the forward-port oracle plus **byte-exact** differential
comparison, the fault-injection & recovery matrix, syzkaller/structure-aware
fuzzing, a rewrite-specific security/ABI audit, and the production-readiness
gate that must pass before the rewrite can replace the forward-port. It builds
on the existing [`kernel-drivers/tests/README.md`](../tests/README.md) harness rather than duplicating
it.

Cross-references: [uAPI guide](./dev-uapis.md) (uAPI surface),
[userspace library guide](../../vendor-libraries/docs/how-the-userspace-libs-work.md) (the librga behaviours §3
encodes), [device-tree guide](./device-tree.md) (6.18 DT), [kernel status](./forward-port-status.md) /
[`status.md`](../../status.md) (project status rows),
[source-tree pins](../../docs/source-trees.md) (local rewrite/upstream-RGA pins),
[validation & fuzzing plan](./rewrite-validation-plan.md) (path to production readiness).
