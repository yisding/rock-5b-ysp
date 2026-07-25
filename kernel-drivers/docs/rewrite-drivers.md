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

> **Status: advanced bring-up, not yet the validated replacement.** MPP now covers
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
> opt-in display-tail BGRA/XRGB/RGB565 rotation plus BGRA partial alpha blend,
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
> the opt-in standalone `GST_RGACONVERT_ELEMENT` converter path, and
> the GStreamer-visible RGA format matrix for BGR16/RGB/BGR/BGRA/RGBx/NV16/NV61
> encoder preprocessing and
> BGR16/RGB/BGR/RGBA/BGRA/RGBx/BGRx/NV21/NV16/NV61/I420/YV12 decoder-side output
> conversion. The in-repo direct `librga` smoke
> covers virtual-address imports, dma-heap dma-buf allocation plus `importbuffer_fd`, sync
> copy/resize/fill/rectangle, RKNN/RKNPU-style RGB/NV12/NV21 preprocessing plus
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
> RGA userptr-IOMMU fallback userptr mapping slice: dma-buf imports remain fail-closed unless they
> map as one 32-bit-safe segment, while driver-owned pinned userptr sg-tables
> can be mapped through one contiguous IOMMU IOVA span for direct-librga/RKNN
> virtual-buffer compatibility. RGA fault recovery now uses only the
> provider-local callback, requires an exact physical source match in a shared
> domain, clears each core independently, and synchronizes in-flight provider
> IRQ callbacks during unregister; attached-domain probe fails if the provider
> hook is unavailable. The hardware-validated stack is still the forward-port
> ([kernel status](./forward-port-status.md), [`status.md`](../../status.md)). Location + pin in
> §6.

| | Forward-port (`mpp/`, `rga3/`) | Rewrite (`mpp-rewrite/`, `rga-rewrite/`) |
|---|---|---|
| Code origin | Rockchip 6.1 BSP, ~98% unchanged | written from scratch against the documented ABI |
| Kernel APIs | BSP-isms shimmed via `compat/` (vendor-forward-port.md §A) | public APIs only, no shims |
| Kernel target | pinned to 6.18 API surface (resyncing.md hazards) | built on 6.18; being brought up on current mainline master too (§5) |
| Userspace ABI | full BSP surface | the documented subset current `mpp-rockchip`/`librga`/`ffmpeg-rockchip` actually use |
| Audit posture | 89 verified findings latent ([BSP audit](./bsp-audit.md)) | ownership-explicit and refcount-disciplined, with 85 MPP + 147 RGA KUnit cases |
| Size snapshot | MPP ~15,822 lines; RGA3 19,173 code/build lines at the current forward oracle (`15,796` C + `3,305` headers + `72` Kconfig/Makefile) | at the 2026-07-23 recovery-hardening tip: `mpp_rewrite.c` 13,927 C lines, `rga_rewrite.c` 23,479 C lines (the sub-tables below are as of the superseded `8469183` pin and predate this ~9k-line churn) |

Kconfig makes the two tracks **mutually exclusive per device node**:
`ROCKCHIP_MPP_REWRITE` depends on `!ROCKCHIP_MPP_SERVICE` and registers
`/dev/mpp_service` in its place; `ROCKCHIP_RGA_REWRITE` depends on
`!ROCKCHIP_MULTI_RGA && !VIDEO_ROCKCHIP_RGA` and registers `/dev/rga`
(`mpp-rewrite/Kconfig`, `rga-rewrite/Kconfig`). The rewrite binds the *same DT
nodes* as the forward-port: `rockchip,rkv-encoder-v2-core`,
`rockchip,rkv-decoder-v2`, both CCU compatibles (`mpp_rewrite.c:526-530`) and
the RGA2/RGA3 compatibles incl. the mainline `rockchip,rk3588-rga`
(`rga_rewrite.c:16336-16344`).

Important codec boundary: the MPP rewrite and the shipped base forward-port do
not expose RK3588 AV1 through `/dev/mpp_service`. AV1 lives on a separate
Verisilicon/VPU981 hardware block, with a separate BSP `mpp_av1dec.c` backend and
a dedicated AV1 IOMMU. The AV1-capable `rkvenc-fwport-6.18` variant now carries
that RKMPP backend on top of a clean `vsi-iommu` provider and has decoded AV1
bit-exact on hardware; the rewrite still does not bind this block. The separate
Hantro/V4L2 stateless AV1 path is not the same userspace ABI as RKMPP. See
[RK3588 AV1 decode, IOMMU, and userspace paths](../av1/docs/av1-rk3588.md).
The scoped
[AV1 rewrite assessment](../av1/docs/av1-rewrite-assessment.md) records the
estimated effort, the class-aware register and translation-capacity refactors,
the VSI fault-hook work, and the hardware gates required to add that backend
without weakening the rewrite's current lifetime and address-provenance rules.

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
tests. Its raw checked-in source is now slightly larger than the vendor RGA3
directory, but that comparison is dominated by the rewrite's embedded KUnit
suite. The non-KUnit rewrite driver remains about 43% smaller; the exact
accounting is below.

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

### Exact RGA size accounting

The source-size comparison uses the 6.18 forward-port oracle
`e059aad8d68b` and rewrite pin `0d71ded1690c` from
[source-tree pins](../../docs/source-trees.md) §8. The earlier rounded
`~19,171` forward figure was an older two-line-different snapshot. At the
current oracle, a like-for-like count is:

| Content | Forward-port `rga3/` | Rewrite `rga-rewrite/` |
|---------|---------------------:|-----------------------:|
| Non-test C | 15,796 | 11,309 |
| Headers | 3,305 | 0 |
| Embedded KUnit | 0 | 8,885 |
| Kconfig + Makefile | 72 | 25 |
| **Driver code/build files** | **19,173** | **20,219** |
| ABI documentation | — | 625 |
| **Everything in the driver directory** | **19,173** | **20,844** |

Therefore the checked-in rewrite is 1,046 code/build lines (5.5%) larger when
KUnit is counted, or 1,671 lines larger when its `ABI.rst` is counted too. With
`ROCKCHIP_RGA_REWRITE_KUNIT_TEST` disabled, the rewrite has 11,334 code/build
lines — 7,839 lines (40.9%) fewer than the forward port. This is a
source accounting, not an object-size measurement.

> **Note (2026-07-23):** the line ranges and byte counts in this subsection are
> measured at the superseded `8469183da227` pin (`rga_rewrite.c` = 20,194 lines,
> 122 KUnit cases). The current `1fe46df86f1ca` recovery-hardening tip is 23,479
> lines with 147 RGA cases; these sub-ranges have not been recomputed at the new
> tip.

The KUnit body occupies `rga_rewrite.c:6386-15266` (8,881 lines). Its
conditional include at `:34-37` brings the total test-only source to 8,885
lines, 44.0% of the C file. At the `8469183` pin the file is physically laid out
at a high level as follows:

| `rga_rewrite.c` range | Lines | Main responsibility |
|-----------------------|------:|---------------------|
| 1-6385 | 6,385 | Registers, driver objects, sessions, DMA/userptr mapping and shadows, fences, recovery helpers, and first-stage validation |
| 6386-15266 | 8,881 | KUnit implementation and 122 registered cases |
| 15267-20194 | 4,928 | RGA2/RGA3 profile validation and emission, scheduling/IRQ/recovery, ioctls, probe/remove, and session teardown |

The growth history makes the source crossover equally explicit:

| Pin | Total C | Test-only | Non-test C | Meaning |
|-----|--------:|----------:|-----------:|---------|
| `fb1fba22d0c5` (initial rewrite) | 7,067 | 350 | 6,717 | Initial ABI and execution slice |
| `d1d15a3d052a` (pre-hardening parent) | 18,321 | 8,111 | 10,210 | Feature-parity and lifetime coverage before the final hardening pass |
| `563f329dd8c4` | 19,485 | 8,653 | 10,832 | Topology, DMA/IOMMU, fence, queue/removal, and recovery hardening |
| `0d71ded1690c` | 20,048 | 8,797 | 11,251 | RK3588 RGA quirks, config-error IRQs, cache-line shadows, CSC compatibility, and tests |
| `8469183da227` | 20,194 | 8,885 | 11,309 | Ported forward-port RGA bugfixes (10-bit plane offsets, max-seg-size, import double-put, acquire-abort race, job_put NULL guard) and two KUnit cases |
| `1fe46df86f1ca` (current pin) | 23,479 | — | — | 2026-07-23 `harden rewrite driver recovery`: ~9k insert/~4.9k delete restructuring import/extent bookkeeping and recovery; RGA KUnit 122 → 147. (test/non-test split not recomputed at this tip) |

Of the 13,127 C lines added since the initial rewrite, 8,535 (65%) are tests
and 4,592 (35%) are runtime implementation. The rewrite crossed the forward
port's raw source count in the hardening commit. The 5.10 reconciliation
moved it from 19,485 to 20,048 lines: 144 test-only and 419 runtime lines for
the RK3588 quirks, config-error path, per-mapping cache-line shadows, and narrow
CSC compatibility rule. The 2026-07-22 forward-port bugfix pin `8469183` added
a further 146 lines: 88 test-only across two new cases and 58 runtime lines for
the five ported fixes.

For comparison, the forward port's production size is spread across real BSP
subsystems rather than tests: 3,391 C lines of RGA2 register generation, 2,306
of RGA3 register generation, 2,556 in `rga_mm.c`, 1,724 in `rga_drv.c`, 1,555
in `rga_job.c`, 1,004 in the debugger, 965 in common code, and 3,305 lines of
headers. It has no comparable in-tree KUnit block.

### RGA architecture: forward port vs rewrite

Both drivers own `/dev/rga`, consume the same request shapes, bind the same
RK3588 RGA2/RGA3 nodes, and ultimately perform the same silicon-mandated stages:
copy and normalize a request, resolve buffers, choose a core, emit a command
buffer, start hardware, and wait for an interrupt. The redesign is in how state
and lifetime flow through those stages.

The forward port is a **global BSP subsystem with pluggable backends**:

```text
open
  -> lightweight session identity
  -> request in the global pending-request manager
  -> request expanded into N independent jobs
  -> global policy chooses a scheduler/core for each job
  -> global rga_mm resolves buffers
  -> backend-ops table generates RGA2/RGA3 registers
  -> per-core todo_list + running_job
  -> IRQ looks the request up by id and updates completion counters
```

The rewrite is a **session/job/core ownership model**:

```text
open
  -> owning session {request IDR, import IDR, submitted-job list}
  -> configured request owns copied tasks/imports/fences
  -> submit clones an immutable job snapshot
  -> job selects and retains an eligible hardware core
  -> job creates mappings and a command buffer for that core
  -> per-core queue + active_job
  -> IRQ/timeout/fault completes that exact job
  -> session releases it only after every owner drains
```

The corresponding objects differ like this:

| Object | Forward port | Rewrite |
|--------|--------------|---------|
| Global state | `rga_drvdata` owns schedulers, the memory manager, pending-request manager, session manager, fence context, and debugger | Global `rk_rga` is primarily a registry for hardware, sessions, counters, and the fence context |
| Session | Mostly identity/process metadata plus a refcount | Owns import IDs, request IDs, submitted jobs, and close/dispatch state |
| Request | Stored in a global pending-request IDR | Stored in the opening session's request IDR and owns copied tasks/import/fence references |
| Imports | Stored in global `rga_mm`, tagged with a session, and associated with a mapping scheduler | Stored in the session and retained directly by configured requests and submitted jobs |
| Job | Refers back to a request by numeric ID and obtains resources through global managers | Owns its task snapshot, import references, per-core mappings, fences, command buffer, session link, and hardware reference |
| Hardware | Entry in the global scheduler array, with a backend-ops vtable, `todo_list`, and `running_job` | Refcounted object with its own queue, `active_job`, start/recovery lock, timeout/fault work, power state, and quarantine state |

The rewrite still has global state; it deliberately moves user-resource
ownership out of it. The service is a registry and coordination root, while the
session and job own the resources whose teardown races with ioctls, fence
callbacks, IRQs, timeouts, and platform removal.

#### Multi-task request model

The forward port's `rga_request_commit()` loops over the task array and creates
one independently scheduled `rga_job` per task. Eligible tasks can land on
different cores and run concurrently; the request completes when its
finished-plus-failed count reaches the task count.

The rewrite keeps `tasks[]` and `current_task` in one job. Completion advances
the index and requeues that same job, optionally selecting a different RGA2 or
RGA3 core for the next task. Tasks in one request therefore run serially under
one completion/release fence. This makes ordering and lifetime explicit, at the
cost of less cross-core parallelism for independent tasks packed into one
request.

This is **per-request serialization**, not global RGA serialization. Three
levels that userspace and the two drivers all call a "job" are worth separating:

- an **operation/task** is one `struct rga_req` (for example one resize);
- a userspace **request/job** is one `imbeginJob()` ... `imendJob()` container,
  potentially holding several tasks;
- a hardware **job** is the unit occupying one RGA core until an interrupt.

For two independent tasks in one userspace request, the execution shapes are:

```text
Forward port                         Rewrite

request {A, B}                       request {A, B}
  A -> RGA3 core 0 ----+               A -> best core -> IRQ
  B -> RGA3 core 1 ----+-> fence             |
                                             +-> B -> best core -> IRQ -> fence
```

The rewrite can move task B to a different core after A finishes, but core
mobility is not overlap. While A is active, however, a task from an unrelated
request can run on another core:

```text
request 10, task A -> RGA3 core 0
request 11, task X -> RGA3 core 1       (concurrent under either driver)
request 10, task B -> selected only after A completes
```

The observable difference therefore depends on the userspace calling shape:

| Calling shape | Forward port | Rewrite | Lost parallelism? |
|---------------|--------------|---------|-------------------|
| One task in one request | one hardware job | one hardware job | No |
| Several separate async one-task requests | requests can occupy different cores | requests can occupy different cores | No |
| Independent tasks packed into one request | one schedulable job per task | one task at a time from the parent job | Yes |
| Dependent tasks packed into one request | can overlap in the 6.18 oracle | execute in array order | Rewrite ordering is desirable |
| Tasks all forced to one core, or eligible on only one core | serialize at that core | serialize in the parent job | Usually no |

#### Does the serialization match current userspace?

For the current YSP media stack, mostly yes. The fixed librga tree
`a6322179c944` uses `rga_single_task_submit()` for the ordinary `imresize`,
`imcrop`, `imcvtcolor`, `improcess`, copy, rotate, blend, fill, mosaic, and
related single-operation APIs (`im2d_api/src/im2d.cpp:935-1503,1553-1573`).
With no positive job handle, `rga_task_submit()` issues one legacy sync/async
ioctl; only the explicit Task API appends the generated `rga_req` to
`job->req[]` and later sends `job->task_count` through
`RGA_IOC_REQUEST_SUBMIT` (`im2d_api/src/im2d_impl.cpp:3028-3049,3192-3253`).

The main current consumers have the same one-task-per-request shape:

| Consumer | Kernel-visible submission shape | Where its parallelism comes from |
|----------|---------------------------------|----------------------------------|
| ffmpeg-rockchip `scale_rkrga`, `vpp_rkrga`, `overlay_rkrga` | one `c_RkRgaBlit()` per frame operation (`libavfilter/rkrga_common.c:1266-1300`) | separate async frame requests; default `async_depth=2`, configurable through 4 (`vf_vpp_rkrga.c:481`) |
| JeffyCN GStreamer MPP conversion | one synchronous `c_RkRgaBlit()` per conversion (`gst/rockchipmpp/gstmpp.c:254`) | separate pipeline threads/instances, not a multi-task RGA request |
| Ordinary IM2D applications and the surveyed RKNN/camera/display helpers | individual resize/convert/crop/blit calls | separate calls, threads, frames, or explicit async fences |
| YSP's maintained multi-task smoke cases | rectangle-array and copy-chain jobs explicitly set `IM_JOB_FLAGS_EXEC_SEQUENTIAL` | serialization is requested; the copy chain is genuinely dependent and the rectangle case exercises the flag |

FFmpeg is the most important practical example. It submits asynchronous frame
operations and keeps a FIFO of release fences. At the default depth, frame N
and frame N+1 are separate kernel jobs and remain eligible for the two RGA3
cores concurrently under the rewrite. An overlay pre-processing blit is
explicitly synchronous before the final asynchronous composite because those
operations are dependent. The rewrite does not turn this into a globally
single-job pipeline.

The current source survey found no production Linux-media consumer that makes
multi-operation Task-API batches its normal throughput path. The exceptions in
the library and sample surface are narrower:

- `imcfa()` may submit a LUT update followed by CFA processing and explicitly
  creates the request with `IM_JOB_FLAGS_EXEC_SEQUENTIAL`; the dependency needs
  the rewrite's ordering.
- `immakeBorder()` uses ordinary, non-sequential Task-API jobs for up to four
  constant fills, or for top/bottom and then left/right copy pairs. Tasks within
  each phase normally touch independent regions and are a real, though
  specialized, opportunity for the forward port to overlap work.
- `imfillTaskArray()`, `imrectangleTaskArray()`, and `immosaicTaskArray()` can
  pack many independent regions into one request, as can an application's own
  `imbeginJob()`/`*Task()`/`imendJob()` sequence. Official librga drawing and
  splice samples exercise these shapes even though the main FFmpeg/GStreamer
  paths do not.
- A custom ML preprocessor that batches independent images or crops into one
  Task-API job would expose the difference directly. The public RKNN/RKNPU
  examples surveyed for this project instead use individual resize/convert
  calls.

#### Sequential flag mismatch

Current librga defines `IM_JOB_FLAGS_EXEC_SEQUENTIAL` as bit 6. Its 2.2.10
developer guide tells applications with task-to-task dependencies to pass that
flag to `imbeginJob()` so the tasks execute in order. That implies the default
job may contain independent tasks that are safe to overlap.

The original 6.1 and 6.6 BSP drivers do not implement the bit either. Rockchip
added the first implementation found in this audit later on `develop-5.10`, in
`02e0554b1e66` (`video: rockchip: rga3: support hardware batching`). That
implementation defines kernel-side `RGA_REQUEST_FLAGS_EXEC_SEQUENTIAL` as the
same bit 6, submits the flagged task array as one ordered hardware command
batch, and leaves unflagged tasks independently schedulable. Its follow-up
`0c1499fbace4` fixes slave-mode execution after master mode.

At the published pins, neither 6.18 implementation exactly matches that
contract; the later local reconciliation branch does:

| Driver | Default job | `IM_JOB_FLAGS_EXEC_SEQUENTIAL` job |
|--------|-------------|------------------------------------|
| BSP 6.1 `b4ef083dc0c3` / BSP 6.6 `1ba51b059f25` | fans every task out as an independent `rga_job` | still fans out; the bit is stored but never interpreted |
| Rockchip 5.10 `bfa51d2ab081` | fans unflagged tasks out independently | one ordered hardware command batch |
| Forward-port `18fae9957686` | fans every task out as an independent `rga_job` | still fans out; its header does not define bit 6 and regular request commit never interprets it |
| Reconciled local forward port `8d78edbe910c` | fans unflagged tasks out independently | one ordered hardware command batch, including the required master/slave follow-up |
| Rewrite `0d71ded1690c` | executes tasks serially through `current_task` | also executes serially, so dependency ordering happens to be correct |

The published forward-port pin favors the performance semantics of an
independent batch but can violate the new dependency flag; the reconciled local
branch fixes that mismatch. The rewrite favors safe ordering but does not honor
the performance distinction for an unflagged independent batch. Storing the
request flags without using bit 6 is not full ABI behavior in either direction.
This is a BSP-carried compatibility bug rather than a regression introduced by
the forward port. See
[the three-branch BSP comparison](./bsp-6.1-6.6-comparison.md#why-rockchip-510-is-the-newest-rga-donor)
for the larger set of 5.10-only RGA changes and the recommended port order.

#### When the difference can matter

For two large independent tasks eligible on the two RGA3 cores, the idealized
batch latency changes from roughly `max(time(A), time(B))` in the forward port
to `time(A) + time(B)` plus an IRQ/requeue boundary in the rewrite. A compatible
mix of RGA2 and RGA3 work can expose another overlap opportunity. Real scaling
will be lower than the core count when both operations compete for DDR
bandwidth. For very small rectangles, command preparation, mapping, power, IRQ,
and requeue overhead may dominate, although the absolute delay may still be
small.

The loss is therefore most credible for large independent images, many
independent drawing regions, or explicit batched preprocessing. It should not
affect ordinary single-operation calls, dependency chains, work forced to one
core, or FFmpeg-style concurrency made from separate asynchronous requests.
There is no paired forward-port/rewrite hardware timing in this repository yet,
so this is a source-level conclusion rather than a measured claim.

Userspace can retain parallelism today by submitting independent operations as
separate `IM_ASYNC` one-task requests and waiting on their separate fences. The
complete kernel-side design would preserve the rewrite's parent ownership and
aggregate release fence while:

1. keeping the current `current_task` progression when request bit 6 is set;
2. creating independently schedulable child jobs for an unflagged request;
3. completing the parent only after every child succeeds or fails; and
4. draining all children through the same close, timeout, fault, and removal
   ownership rules.

That would restore current librga's ordering/performance distinction, but it
also reintroduces the multi-child completion and teardown state that the
rewrite's serial parent deliberately avoided.

#### Scheduling and backend abstraction

The forward port has a traditional BSP framework split:

- `rga_policy.c` decides which scheduler satisfies the request's formats,
  transforms, features, and forced core mask.
- Each `rga_scheduler_t` owns a priority-ordered `todo_list` and one
  `running_job`.
- `struct rga_backend_ops` supplies `init_reg`, `set_reg`, `soft_reset`,
  readback, status, IRQ, and threaded-ISR operations.
- `rga2_reg_info.c`, `rga3_reg_info.c`, and `rga_hw_config.c` carry the broad
  multi-generation command and capability implementation.

The rewrite validates the current task against explicit RGA2 and RGA3 profiles,
then chooses the least-loaded eligible online core while honoring the public
core mask and rotating equal-load choices. There is no generic backend vtable:
the selected hardware type dispatches to a named RGA2/RGA3 validator and
emitter, and an unmatched profile returns `-EOPNOTSUPP`. This is narrower and
less reusable across SoCs, but prevents a generic capability table from
advertising a path the RK3588-specific emitter does not implement.

#### Mapping and command-buffer ownership

The forward port's global `rga_mm` supports dma-buf handles, virtual addresses,
physical addresses, fake/internal buffers, BSP page tables, and several MMU
modes. It selects a scheduler before mapping, allocates a command buffer from
that scheduler's persistent pool, powers the core for mapping/register
initialization, and then enqueues the prepared job.

The rewrite deliberately rejects physical-address imports. dma-bufs use public
attach/map APIs; userptr imports pin pages and build owned sg-tables, with the
contiguous-IOMMU fallback documented in [RGA userptr/IOMMU](../rga/userptr-iommu.md).
The session owns the import, while each submitted job owns the mapping for the
core that will execute it. At backend start the rewrite rebases images to that
core's DMA device, synchronizes userptr memory, powers the core, allocates a
job-owned coherent command buffer, emits commands, and starts hardware. A
handle can therefore outlive one mapping without allowing release to invalidate
an in-flight job.

#### Fences, close, and removal

The forward request owns its release fence; an acquire callback commits the
request, and each completed job finds the request in the global manager to
increment its completion counters. The rewrite job directly owns its acquire
references/callbacks, release fence and pending fd reservation, session-list
membership, and hardware reference.

That ownership makes rewrite close deterministic: mark the session closing,
reject new tracking, cancel jobs waiting on acquire fences, remove its queued
jobs, reset its active jobs, wait for its job list and dispatch handoffs to
drain, then release configured requests and imports. Release-fence publication
also reserves and creates the sync file, copies the descriptor number to
userspace, and installs it only after copyout succeeds, so rollback cannot close
an unrelated descriptor reused by another thread.

#### Completion and fail-closed recovery

The forward port preserves the BSP state-bit, `running_job`, backend soft-reset,
request-lookup, and diagnostic machinery. The rewrite serializes hardware
start, IRQ completion, timeout, recovery, and removal with each core's run lock.
Every activation has a generation, and timeout/fault work retains or rechecks
the exact target before claiming the active slot. A stale worker therefore
cannot reset a replacement job.

After an error, timeout, or IOMMU fault, the rewrite resets the selected core,
refreshes the attached IOMMU domain, completes the exact job and resumes its
queue. If reset or domain recovery fails, the core is quarantined: routing skips
it, queued work fails, and its IRQ remains disabled so powered-off MMIO cannot
be touched. Loss of the last usable core also fails async jobs still waiting on
acquire fences.

The architectural trade is therefore:

| Forward-port strength/cost | Rewrite strength/cost |
|----------------------------|-----------------------|
| Broad multi-generation BSP compatibility and proven hardware behavior | RK3588-specific profiles and no booted hardware proof yet |
| Conventional subsystem files and backend vtables | One large translation unit, though logical ownership is stricter |
| Independent jobs allow batch tasks to run across cores | Serial per-request task progression simplifies ordering/fences |
| Global managers make cross-subsystem lookup convenient | Session/job ownership makes close, reset, IRQ, and removal locally auditable |
| Physical/virtual/dma-buf and BSP MMU modes | Public dma-buf/userptr paths; physical addresses fail closed |
| Existing BSP recovery and debugger surface | Exact-job recovery, quarantine, focused counters, and embedded KUnit |

The later Rockchip `develop-5.10` RGA work is a separate reconciliation input,
not code ancestry for the rewrite. The detailed assessment in
[`../rga/rewrite-5.10-reconciliation.md`](../rga/rewrite-5.10-reconciliation.md)
records the five adaptations implemented on 2026-07-17: RK3588 RGA3
logic-clock and RGA2 auto-reset quirks, RGA2 config/parse-error IRQ handling,
per-mapping cache-line boundary shadows for userptr DMA, and the narrow RGA3
R2Y BT.709-limited `full_csc` compatibility exception. It also records which
5.10 fixes the rewrite's ownership, fence, IOVA, scale, and serial-task designs
already cover. Both rewrite kernel lines pass normal, memory, and race
clean-source build profiles with the adaptation; booted RK3588 conformance is
the remaining gate.

MPP follows the same ownership direction but has a different size/complexity
profile: the forward port has a shared BSP MPP service plus pluggable encoder and
decoder block drivers, while `mpp-rewrite` uses explicit session/job/hardware
owners for the fixed RK3588 RKVENC2/RKVDEC2 profile. MPP remains mostly a
register-job conveyor because userspace builds codec register recipes; RGA must
interpret image operations and generate those recipes in the kernel.

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
| `MPP_IOC_CFG_V1` message parsing | incl. **multi-message batches**; userspace message order preserved; write-like payloads copied before the ioctl returns; staged jobs snapshot client type, translation table, codec info, inherited RCB descriptors, and the reset epoch, so a later state-control message cannot retroactively alter an earlier job; successful state controls split subsequent messages into a new staged job. Staged jobs in one batch are submitted before poll requests are processed in message order, matching the forward-port trigger-then-wait ordering; both request-bearing and session-switch-only arrays are capped at 64 total messages. Every message is checked against the known transport/job/poll flag set before payload or session-switch processing: unknown and out-of-class flags return `-EINVAL`, while unsupported `SECURE_MODE` returns `-EOPNOTSUPP` instead of silently running an ordinary-DMA job. | `mpp_rewrite.c:2346` (`cmd != MPP_IOC_CFG_V1` reject) |
| `MPP_CMD_SET_SESSION_FD` | session switching, restricted to fds that are themselves `/dev/mpp_service` files; switching closes the current staged job and starts a distinct job for subsequent messages; bad-fd slots report `-EBADF` through `mpp_bat_msg.ret`, and `MPP_BAT_MSG_DONE` slots skip the following task group without touching the previous session; the dormant libmpp batch-server wait-array shape is recognized and rejected with `-EOPNOTSUPP` instead of adding multi-`LAST_MSG` continuation semantics | `:2371` |
| Platform binding | RK3588 BSP-style RKVENC2/RKVDEC2 core + CCU nodes; devm MMIO/IRQ/clock/reset; DT `rockchip,normal-rates` applied through the public clock framework before clocks are enabled. Hardware-backed core and decoder-CCU matches fail probe on an empty clock list or a missing/truncated primary MMIO window; the required RK3588 sizes are RKVENC2 `0x6000`, RKVDEC2 `0x5a0`, and decoder CCU `0x100`. Rock 5B exposes a `0x600` RKVDEC2 function aperture, including the VDPU381 cache/max-read registers through `0x59c` and ending immediately before the MMU at function offset `0x600`. Powered cores must also report the libmpp register-0 identity for the selected backend (`0x50603312` VEPU58x or `0x53813f05` VDPU38x); a zero or mismatched ID fails with `-ENODEV` before IRQ/fault registration, preventing generic compatibles from inheriting the RK3588 VEPU580/VDPU381 register profiles on another revision. Encoder/decoder cores require an available, type-correct `rockchip,ccu` phandle. Decoder cores require a nonoverlapping mirrored one-hot `rockchip,core-mask` (`0x00010001` or `0x00020002`), matching the RK3588 CCU's two low/high core fields; zero, multi-core, unmirrored, or out-of-field masks fail probe before MMIO. Core IDs use the first vacant bounded slot on alias-less probe; duplicate/out-of-range aliases and exhausted identity space fail closed, preserving scheduler/DCHS identity across hot reprobe. Probe failure and unbind drain pending autosuspend and synchronously suspend idle MPP devices before disabling runtime PM, preventing the hardware-ID read or last job from leaving its generic power domain active. The zero-clock, zero-MMIO virtual encoder CCU remains valid. On Rock 5B, `vdec1_mmu` names `vdec0_mmu` through `rockchip,shared-domain-owner`, so IOMMU core places both decoder masters in one ordinary DMA group/domain while unrelated providers keep singleton groups. | `:274-277` |
| `QUERY_HW_SUPPORT` / `QUERY_HW_ID` / `QUERY_CMD_SUPPORT` | from bound cores; `QUERY_HW_ID` returns the validated register-0 hardware id captured at probe — preserving the forward-port's userspace-visible **HAL-selection contract** (how-the-drivers-work.md §9, dev-uapis.md) | `:473` |
| procfs discovery markers | minimal `/proc/mpp_service/supports-cmd` + `support_cmd` when `CONFIG_PROC_FS=y` (read-only compatibility markers so current `mpp-rockchip` enables command probing — *not* the BSP debug/control procfs); procfs-disabled kernels still load the driver | `:592-595` |
| `INIT_CLIENT_TYPE`, `INIT_DRIVER_DATA` (no-op), `RESET_SESSION`, `SEND_CODEC_INFO` | validated per-session state. Client binding is one-way: repeating the selected type succeeds, while changing an initialized session between encoder and decoder returns `-EBUSY`. Reset advances a session epoch, removes earlier staged jobs for that session from the current ioctl, aborts queued/active work, then releases imports; racing stale jobs fail with `-ECANCELED` before submission. | |
| `MPP_CMD_INIT_TRANS_TABLE` | BSP-compatible **`u16` table element width** (`u16 trans_table[]`, `:169`); updates and immutable per-job snapshots are serialized on the session lock, odd byte counts are rejected, and KUnit covers successful load, oversize/odd-size rejection, copy-fault return, zero-size count reset, and pre/post-control snapshot separation. On these fixed RK3588 backends, custom entries augment rather than replace the built-in VEPU580/VDPU381 DMA-register tables, so omission cannot create an unchecked literal address — ABI and safety facts not obvious from the header. | |
| `TRANS_FD_TO_IOVA` / `RELEASE_FD` | public dma-buf attach/map/unmap against a bound client hw device; explicit translation maps on the default matching core for compatibility. Every MPP hardware node uses 32-bit streaming/coherent DMA masks because codec registers carry 32-bit IOVAs. The session cache is keyed by fd + DMA device + resolved dma-buf identity, so closing a buffer and reusing its integer fd cannot return the old mapping; stale cache owners are removed without disturbing in-flight job references. `RELEASE_FD` still drops all cached mappings for that fd. Import proves the mapped SG table covers the full dma-buf as one byte-contiguous 32-bit DMA span; fragmented, truncated, zero-length, and overflowing mappings fail before submission. `REG_FD_NO_TRANS` requires a prior explicit affinity, validates every known nonzero address inside this session's mapping on that device, and pins each mapping until job completion; unproven literal IOVAs fail before scheduling. KUnit covers identity/reuse, span/offset boundaries, explicit-I/O range and lifetime validation, and the all-DMA-device release sweep while preserving other fd imports. | |
| `MPP_CMD_SET_ERR_REF_HACK` | validated **copy-in/discard** — issued by current `mpp-rockchip` for VDPU382 H.264 capability probing and must be *accepted*, not rejected (§4); KUnit now covers the initialized-session gate plus zero-size, stack-buffer, heap-buffer, oversize, and copy-fault outcomes | |
| Register jobs | flat register-image materialization (`SET_REG_WRITE`), bounded readback retention (`SET_REG_READ`), and validated offset tuples (`SET_REG_ADDR_OFFSET`). Translated registers retain dma-buf provenance, so embedded and separate offsets are accumulated with checked arithmetic and must stay inside the allocation and 32-bit IOVA aperture; literal non-fd registers keep BSP-style additive offsets but reject cumulative 32-bit wrap. KUnit covers staging, duplicate-index additive apply, literal wrap rejection, cumulative dma-buf/32-bit bounds, malformed sizes, zero-size no-op, and cap handling. fd→IOVA translation always applies the built-in per-client tables (`rk_mpp_rkvdec_h264d_regs[]` etc., `:325-380`) plus any session entries, with translated dma-bufs mapped against the selected core's DMA device; VP9 RKVDEC coverage asserts the VP9 table translates only VP9-owned fd registers and rejects unknown RKVDEC formats. | |
| Job/import lifetime | translated and validated explicit-IOVA jobs hold references on every imported dma-buf mapping (so `RELEASE_FD`/`RESET_SESSION`/close can't tear a prepared job's mappings down); import lookup/insertion and explicit IOVA copyout verify the job/session epoch, so pre-reset work cannot repopulate the cleared cache or return already-invalidated IOVAs. **Refcounted batch/session/hw job ownership** prevents poll vs reset vs close vs IRQ from freeing a live job. Completion detaches `job->hw` under the session lock, and abort pins its own hardware reference under that same lock before touching timeout/run state, so concurrent platform removal cannot free the devm hardware object between abort's pointer load and use. Active-list and scheduler-queue publication is atomic against reset, while queue admission remains atomic with core/CCU removal, so neither reset nor removal can miss the admission window. Removing a CCU member quiesces HARD decoder work and aborts queued/active jobs across the coordinator group so no peer retains an obsolete decoder mask or vanished encoder DCHS partner; both SOFT and HARD starts recheck CCU/core/cancellation state while holding the coordinator run lock, so a quiesce that lands after admission cannot race the final MMIO start; `SET_SESSION_FD` batch switching splits staged jobs correctly without carrying dormant batch-server status writeback | |
| Execution slice | queued, least-loaded dispatch across bound RK3588 encoder/decoder cores; runtime-PM resume, bulk clock enable, range-checked MMIO writes from the original `SET_REG_WRITE` spans, start-register deferral, **IRQ-driven completion**, retained `SET_REG_READ` readback, BSP-style irq-status override, decoder RLC decoded-length adjustment with defined unsigned 32-bit wrap/shift semantics; RKVDEC2 CCU watchdog sizing uses checked width/height/bitdepth arithmetic and falls back to the longest threshold on overflow. VEPU580 hardware-watchdog sizing follows the BSP 50/100/200/400/800 ms resolution table at the applied `clk_core` rate, preserves the submodule byte, and bounds the 24-bit frame threshold before start. RKVENC2 DCHS allocation failure rejects submission before hardware start, VEPU580 bitstream-overflow IRQs advance/wrap the circular write pointer and the retained overflow status triggers the BSP `0x03f0` reset policy at terminal completion, encoder/direct-decoder error IRQs reset the reporting core before runtime-PM release, and SOFT-CCU decoder error/timeout/fault recovery force-idles, resets, clears the CCU error latch, and reconnects that reporting core without disturbing a healthy peer. Reset assertion/deassertion failures are ratelimited, prevent SOFT-CCU reconnect, and surface on an otherwise successful error-IRQ completion instead of being discarded. A failed reset permanently quarantines the core until reprobe, including a deassertion failure during runtime power-up, masks its IRQ, removes it from selection/admission/dispatch, and drains its queued jobs with `-EIO`; a failed coordinator reset quarantines every dependent decoder core. Contended submits queue internally instead of returning `-EBUSY` | |
| RKVDEC2 CCU modes / link tables | DT `rockchip,ccu-mode` is honored with BSP-style SOFT as the default/invalid fallback; SOFT programs the RK3588 VDPU381 link work-mode register at `0x00`, programs the CCU coordination registers, and starts/completes through the selected core directly. HARD remains opt-in and uses the vendor RK3588 218-word/six-write-part VDPU381 table layout, raw link IRQ, allocation/materialization/readback, running-list/add-mode handling, fixed-RCB link-latch setup, all-work-mask-core chain power ownership transfer, coordinator-wide DMA-ordered done-table scanning (rather than assuming the interrupting core owns the completed table), error containment, timeout recovery, unfinished-chain relink, and resend using public DMA/IOMMU APIs. One node in every per-core link pool remains unused as the BSP next-table sentinel; pools smaller than two nodes fail probe, and admission returns `-ENOSPC` instead of consuming the sentinel and emitting a zero DMA tail. HARD task registers are staged only into the coherent table, and add-mode submission does not write task/cache/link state directly into the software owner because that physical core may be executing a peer-owned descriptor; link/RCB setup runs only when the coordinator is idle. An idle start validates and applies the fixed BSP cache-size, cache-clear, and max-read setup on every powered work-mask core before the coordinator doorbell, because any peer may execute the first descriptor. The initial chain owner holds a separate power reference on its selected core as well as every peer, so completion can drop its per-job reference without powering off a core that remains eligible for later descriptors; all chain references transfer together until the running list drains. Table materialization validates both the register-image write sources and the full BSP readback destinations, so a truncated image fails with `-EINVAL` before the CCU start doorbell instead of failing only after hardware completion. Completion pins the software-owner hardware and waits for its serialized submit/abort section before rechecking and claiming the exact slot, so an IRQ racing the start doorbell cannot be acknowledged and lost until a false timeout, and removal cannot free the owner during handoff. The full coherent link-table DMA span must fit the 32-bit descriptor registers; a high allocation fails probe instead of being truncated. Because HARD can execute a selected core's table/import IOVAs on any peer, every online core behind that coordinator must report the same DMA/IOMMU domain (or all have no IOMMU); mixed domains disable advertised decoder support and make descriptor preparation fail with `-EXDEV`, while peer power-up is constrained to the validated mask/domain. Rock 5B now supplies that topology through the opt-in Rockchip IOMMU shared-domain-owner binding: the IOMMU core owns one normal default DMA domain and attaches both decoder IOMMUs to it. The runtime identity gate remains fail-closed for other or malformed DTs, and default SOFT remains unaffected. Missing HARD link MMIO, descriptor staging failure, cache-register coverage, or an untracked busy HARD CCU fails instead of starting through an unsafe or incompatible path. | |
| Fault/recovery | per-core timeout completion, public IOMMU fault callbacks, post-reset IOMMU refresh, and `-EIO` completion on matched active faults are implemented without private Rockchip IOMMU page-table walking. Provider callbacks are registered and cleared per physical IOMMU rather than per shared domain, and the reported controller/master must first match its exact physical core. HARD-CCU may execute a descriptor on a peer whose software `active_job` slot is empty, so recovery reads that source core's BSP link `CFG_ADDR`, matches the descriptor IOVA to its software owner, and schedules the existing coordinator-wide fail-closed recovery there; software ownership is published and ordered before the `CFG_DONE` start doorbell so an immediate descriptor fault cannot miss it. An unreadable or unmatched descriptor falls back to any active job in the same HARD coordinator rather than silently scheduling the empty peer. After the coordinator is force-stopped, a peer whose run lock is contended gets an immediate deferred abort holding the exact active-job and hardware references. The target is pinned before the lock attempt, queued only while it still owns the slot, and rechecked after acquiring the lock; its timeout is canceled only after that exact claim, so containment neither waits for the ordinary 500 ms timeout, resets a replacement job, nor removes the replacement's watchdog. HARD-CCU resend requires successful coordinator and dependent-core resets; both the reset-preparation and restart passes pin each collected job's hardware under the session lock before touching IRQ/run state, so concurrent completion/removal cannot detach and free that core behind a retained job reference. Any reset failure aborts the affected queue, sets a visible `recovery_failed` quarantine, increments `recovery_failure_count`, and prevents reuse until reprobe. A coordinator failure applies that policy to every dependent core. A core with an attached IOMMU domain fails probe if the provider hook is unavailable instead of running without the intended recovery path; no-IOMMU operation remains allowed. | |
| `MPP_CMD_POLL_HW_FINISH` / `MPP_CMD_POLL_HW_IRQ` | nonblocking `POLL_HW_FINISH` on a pending job returns `-EAGAIN` without consuming the session-visible active job; poll results are returned through the ioctl result like the reachable direct libmpp path, not per-slot dormant batch-server status writeback; RKVENC2 slice result streaming advertises `POLL_BUTT`, detects split mode from the submitted register image (`slen_fifo` + slice split), stores IRQ slice-length words in a job-owned FIFO, copies up to userspace `count_max`, and falls through to normal completion/readback on the final slice. Non-split IRQ polls use the full-frame finish path without parsing a slice-only buffer, and an empty session returns `-EIO` before touching it. Slice-FIFO overflow reports `-EOVERFLOW` once, clears the latch, and permits later polls to drain retained entries and consume the completed head job. | |
| `MPP_CMD_SET_RCB_INFO` | BSP-compatible `(register index, size)` descriptors per session; per-core **coherent scratch via the public DMA API** sized from DT `rockchip,rcb-iova`, including valid DMA address zero and fail-closed full-span validation against the 32-bit codec aperture; decoder gate on `rockchip,rcb-min-width` using retained `SEND_CODEC_INFO` width — no fixed-IOVA SRAM | `:2483-2492` |
| KUnit coverage | optional `ROCKCHIP_MPP_REWRITE_KUNIT_TEST` for ABI parser and staging helpers, including command range and per-message flag classification, command group boundary queries, payload-copy classification, `SET_ERR_REF_HACK` copy/discard behavior, locked translation-table storage, immutable staged-job state snapshots, idempotent client init/rebind rejection, reset-time staged cancellation, stale-epoch admission, atomic active/queue publication, reset/completion-safe hardware pin/detach lifetime, dma-buf identity/fd-reuse plus contiguous-span/32-bit/coherent-span/combined-offset validation, mandatory built-in address-table union and explicit-IOVA range/lifetime validation, release-fd import sweeping, public `RESET_SESSION`/file-close import and queued/active job cleanup, hardware-active reset cleanup with retained active-job import mappings, register-offset staging/apply plus literal-wrap rejection, register-span overflow checks, exact VEPU58x/VDPU38x hardware-ID gating, core/CCU removal admission checks, recovery-failed core/CCU admission plus dispatcher rejection, nonblocking pending-poll retention, non-slice IRQ-poll payload bypass, recoverable slice-FIFO overflow, `SET_SESSION_FD` invalid-fd/done-marker behavior, total-message cap enforcement, dormant batch-server wait-array recognition plus collector-level `-EOPNOTSUPP` rejection without status-slot writeback, RK3588 VDPU381 link table/IRQ and fail-closed cache/max-read programming, overflow-safe CCU and VEPU580 watchdog thresholds, SOFT-CCU error-latch recovery, HARD-CCU shared-domain gating, exact shared-domain IOMMU-fault source routing plus descriptor-owner/fail-closed recovery selection and pre-doorbell owner publication, exact-job deferred peer-abort target replacement/result/refcount lifetime and replacement-watchdog preservation, and out-of-order table-done behavior, `POLL_HW_IRQ` flexible-buffer sizing, VP9 RKVDEC fd-to-IOVA translation/validation, RKVENC2 DCHS admission/remapping, VEPU580 overflow pointer wrapping plus terminal reset classification, and slice-mode detection | |

### Recognized but unsupported

- Dormant libmpp batch-server wait arrays are recognized as repeated
  `SET_SESSION_FD` + `POLL_HW_FINISH|POLL_NON_BLOCK|LAST_MSG` pairs and return
  `-EOPNOTSUPP`.  Current libmpp has no wired callers for `MPP_DEV_BATCH_ON`,
  and the BSP collector stops at the first `LAST_MSG` for normal submissions.
- `MPP_FLAGS_SECURE_MODE` returns `-EOPNOTSUPP` before payload or job
  processing. The fixed RK3588 rewrite has no protected dma-buf attachment,
  protected IOMMU domain, or secure-monitor submission path; current checked
  libmpp defines but does not send the flag.

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
  profile. The rewrite now reads and decodes the powered hardware version
  register at probe (RGA2 `0x28`, RGA3 `0x18`), accepts only those two exact
  implemented tuples, and backs the version ioctls with that validated value.
  This keeps the generic/core BSP compatibles usable on RK3588 while preventing
  them from silently advertising the RK3588 command/capability profile for a
  different RGA revision.
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
  unless the 64-bit ABI value is a lossless nonnegative `int` fd and resolves
  to one 32-bit-safe DMA segment; upper-bit fd aliases are rejected rather than
  truncated. Legacy
  no-handle `wrapbuffer_fd()`/`wrapbuffer_virtualaddr()` blits are converted to
  job-owned temporary imports; **direct physical-address channels remain
  unsupported**.
- **DMA aperture**: matching the BSP, RGA2 uses 32-bit streaming/coherent DMA
  masks and RGA3 uses 40-bit streaming plus 32-bit coherent DMA. The complete
  per-job command-buffer span is checked before its 32-bit hardware base is
  programmed, so a high address cannot alias a low command buffer.
- **Probe prerequisites**: every executable RGA2/RGA3 match requires an IRQ and
  a nonempty clock list. Probe propagates a missing-IRQ error and returns
  `-EINVAL` when bulk clock discovery returns zero, matching the BSP
  fail-closed behavior instead of registering a core that can only time out or
  permitting unclocked MMIO. The primary register resource must also cover all
  fixed backend accesses: at least `0x90` bytes for RGA2's full-CSC window and
  `0x44` bytes for RGA3's command-state register (the RK3588 BSP nodes expose
  `0x1000`); missing or truncated MMIO fails probe. With runtime PM and clocks
  enabled, probe also validates the actual version register before registering
  the IOMMU fault handler or public core; unsupported revisions fail with
  `-ENODEV` rather than inheriting a fixed match-table version claim. Optional
  reset arrays are explicitly assert/delay/deassert-pulsed first, matching the
  working Rockchip reset-controller API and preventing bootloader reset state
  from contaminating that read. Recovery uses the same pulse after a failed
  register-level soft reset; `reset_control_reset()` is not used because the
  Rockchip provider has no one-shot `.reset` operation. A reset is considered
  successful only when the register-level reset or that controller fallback
  succeeds; IOMMU refresh and redispatch no longer follow a failed reset.
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
  or deferred acquire work. Acquire callbacks and teardown atomically claim
  each waiter; callbacks use the lock-held fence-status helper, and abort only
  queues completion after the pending-callback count, including the callback-
  arming sentinel, reaches zero. This prevents both recursive fence-lock
  deadlock and last-core removal releasing the shared work reference while the
  submit path is still registering callbacks. Release-fence export keeps the
  descriptor reserved but uninstalled until its number has been copied to
  userspace; a copy fault drops that private reservation, so rollback cannot
  close an unrelated fd that another thread reused.
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
- **RGA error recovery is fail-closed.** RGA2/RGA3 error IRQs reset the core
  before clocks/runtime PM are released, and ERROR wins if hardware reports
  DONE and ERROR together. If both soft reset and the optional reset-controller
  fallback fail, that core is quarantined until reprobe: import-device choice
  and scheduler routing skip it, a selected-core admission race completes with
  `-EIO`, pre-existing queued jobs and their fences are drained with `-EIO`,
  and loss of the last usable core aborts pending acquire-fence work. Debugfs
  records first-time quarantines in `recovery_failure_count`; the quarantined
  core's IRQ stays disabled so a stuck line cannot touch powered-off MMIO.
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
  on 2026-07-04 and refreshed on 2026-07-05/06 by GitHub code search, excluding
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
  import, RGB/RGB565/RGBA/NV12-family scale/convert/rotate feature set.  The
  2026-07-06 delta added OpenCV/RKAIQ capture, HDMI-capture/RTSP conversion,
  Weston mirror-mode patches, GStreamer base `video-converter` RGA patches,
  runtime wrappers, and a G2D shim that forces RGA3 cores through
  `imconfig(IM_CONFIG_SCHEDULER_CORE, ...)`; these reinforce fd/virtual import,
  IM2D color conversion/resize, legacy blit/fill/flush, and scheduler-core
  control without adding a new ioctl family.  This
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
- **Unsupported profiles fail *late* by design**: legacy blit/backend helpers
  return `-EOPNOTSUPP` only after
  copy/validate/prepare/queue/dispatch/import-resolve/power-sequence reach the
  backend boundary, so the scheduler/lifetime path is exercised even for
  profiles the command generator can't emit yet.  The modern
  `RGA_IOC_REQUEST_CONFIG` / `RGA_IOC_REQUEST_SUBMIT` wrapper is different
  BSP ABI: after `rga_request_check()` succeeds, request-configuration or
  submit failures are surfaced to userspace as `-EFAULT`.  ABI replay now
  records that wrapper behavior with an unsupported handle-backed request
  config case.
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
  It also has opt-in standalone `gstreamer-rga`/`rgavideoconvert`
  diagnostics, covering plugin inspection plus BGRx->NV12, NV12->BGRx, and
  BGRx scale pipelines through `GST_RGACONVERT_ELEMENT`; keep these diagnostic
  unless that external plugin is deliberately installed and hardware counters
  prove `/dev/rga` submission.
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
  180/270-degree GStreamer rotation values, display-shaped BGRx rot90, the
  opt-in display-tail BGRA/XRGB/RGB565 rotation plus BGRA partial alpha-blend smoke, and the current
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
  cleanup, acquire-callback lock context and abort-during-arming lifetime, MPP CCU
  coordinator dependent queued/active abort coverage,
  exact shared-domain RGA IOMMU fault-source matching,
  RGA DONE+ERROR result precedence, recovery-failed admission rejection and
  pre-existing queue draining,
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
  zero-count import/release buffer-pool behavior, display-tail partial
  alpha-blend command emission, invalid public scheduler-core mask rejection,
  and ffmpeg-facing profile helpers via
  `ROCKCHIP_RGA_REWRITE_KUNIT_TEST`.

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

<a id="6-status--citable-location"></a>

## 6. Status & citable location

| Item | State (2026-07-23) |
|------|--------------------|
| Code | `drivers/video/rockchip/mpp-rewrite/` (`mpp_rewrite.c` 14,061 lines; +`ABI.rst`, `Kconfig`, `Makefile`) + `drivers/video/rockchip/rga-rewrite/` (`rga_rewrite.c` 23,865 lines; +`ABI.rst`, `Kconfig`, `Makefile`). The trees contain 85 MPP and 147 RGA KUnit cases (232 total). |
| 6.18 state | committed branch `rk3588-rewrite-6.18` at **`d3a4d4812e9ed`** ("media: rockchip: mpp-rewrite: apply the VEPU580 H.264 slice-flush fixup"), the tip of a **12-commit defect-audit series** (`c540d63a8a9be..d3a4d4812e9ed`, split by defect class, each commit individually compile-verified so the series is bisectable) that fixes 17 confirmed defects across both drivers — three wake-after-unlock use-after-frees, a stale-timeout-generation reset, a route-B SWIOTLB regression from `0d71ded1690c9`, an MPP abort-sweep list overload (UAF + counter skew), a global-lock `copy_to_user()` DoS, compact-10-bit `x_offset` byte conversion on both cores, the RGA2 color-key enable, and the RGA3 scale/window capability gates. **Behaviour change:** the new RGA3 68x2 minimum moves small blits to RGA2, matching the vendor table. See [audit finding](../../findings/2026-07-24-rewrite-driver-multi-agent-defect-audit.md). The series sits atop **`185d4dcec110`** ("media: rockchip: rga-rewrite: honor the legacy byte-stride ABI for 10-bit rasters") in `/home/yi/Code/kernel/linux-6.18-rkvenc`, which in turn is atop `1fe46df86f1ca` ("harden rewrite driver recovery") and parent `8469183da227` ("port forward-port RGA bugfixes"). Over the July 15 MPP/RGA hardening it layers the July 17 RGA low-voltage quirks/config-error IRQ/cache-line shadows/CSC rule, the ported forward-port RGA bugfixes (10-bit plane offsets, max-seg-size, import double-put, acquire-abort race, job_put NULL guard), the 2026-07-23 recovery-hardening churn (~9k insert/~4.9k delete; RGA KUnit 122 → 147, MPP 86 → 85), and the 2026-07-24 **raster 10-bit byte-stride ABI alignment** (layout/validators/RGA3 write-offset path now match the byte-literal register writers; pairs with fwport `0072` and the librga-fork im2d conversion; [stride finding](../../findings/2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md)). **The `normal`/`memory`/`race` clean-source build gates were last re-run green at the 2026-07-23 tip; the byte-stride commit is compile-verified.** A **KASAN+lockdep debug Armbian kernel of this tip is built** — `P4052-C40aa` (build `H7883`; `CONFIG_KASAN=y`, MPP+RGA rewrite drivers + KUnit suites, vendor RGA disabled; debs under the external Armbian workspace). This rebuild adds the extended default debug instrumentation (UBSAN bounds/shift/div-zero in report mode, DEBUG_OBJECTS work/timer/RCU, DEBUG_SHIRQ, kmemleak, IOMMU_DEBUGFS, DEBUG_VM, stack-end canary — all verified present in the built config). Install with `RECOVERY_READY=1 PHASH='P4052-C40aa' bash kernel-drivers/scripts/debug-kernel/install-debug-kernel.sh` (the superseded pre-instrumentation `H959e` debs were removed so this resolves unambiguously) to run the booted 232-case KUnit + hardware gates (not yet executed). |
| Mainline state | committed branch `rk3588-rewrite-mainline` at **`fc329e693da0c`**, carrying the same 12-commit defect-audit series cherry-picked as `7afd5ec514f0b..fc329e693da0c` (rewrite sources verified byte-identical to the 6.18 tip afterwards), atop **`d5165caeddb7`** (cherry-pick of the byte-stride ABI commit) in `/home/yi/Code/kernel/linux`, itself atop `ec9a4a06ecf12` and parent `9ff18809b5e0`, based on the tree rebased to official kernel.org `v7.2-rc2`. Rewrite sources are byte-identical to the 6.18 tip; it carries the mainline DT/wiring and provider integration; the pre-rebase tip remains preserved as `ysp-backup/rk3588-rewrite-mainline-before-7.2-rc2`. Its three clean-source gates were re-run green 2026-07-23 at the pre-byte-stride tip; the new commit is compile-verified only. |
| Package composites | `rk3588-rewrite-armbian-6.18.38` at **`8daf5e9513b8`** layers the rewrite after the exact Armbian current/forward-port Linux 6.18.38 source snapshot. `rk3588-rewrite-armbian-7.2-rc3` at **`24f7424fb958`** layers it after official `v7.2-rc3` plus Armbian `rockchip64-bleedingedge`. The latter's Armbian snapshot is `2657f01c9b9a`, produced from build checkout `5cbc1c59c`. These composites predate the 2026-07-23 tips and pick up the churn only on their next rebuild from tip. |
| Validation | On 2026-07-24, the `normal`, `memory`, and `race` profiles completed warning-free at the defect-audit tip, building the Rockchip IOMMU provider, both KUnit-enabled rewrite objects, and `rockchip/rk3588-rock-5b.dtb`; mainline built clean in `normal` with rewrite KUnit enabled. **That run used a `git ls-files` copy of the worktree rather than a `git archive` of HEAD (the fixes were uncommitted at the time), so the packaged gate still needs re-running from the committed tip.** Note that an in-tree `mpp_rewrite.o` build proves nothing about the MPP KUnit block: the tree `.config` has `ROCKCHIP_MPP_SERVICE=y` and no `ROCKCHIP_MPP_REWRITE`, which silently skips ~4.5k lines of test code — a real build break surfaced only under the KUnit-enabled profile. Separately, three KUnit fixtures were found to `wake_up()` an uninitialised waitqueue (an oops), which suggests the 232-case suite has never actually been executed here; the repaired fixtures are the discriminating test. Earlier: on 2026-07-23 the same three profiles completed warning-free at `1fe46df`/`ec9a4a06` from a clean `git archive`. (The earlier 2026-07-17 run covered the pre-bugfix parents.) Device-free conformance validation passed in baseline, rewrite-counter, and forced-RGA-userptr-IOMMU modes. A KASAN rewrite image at this tip was also built the same day — Armbian debug build `P3695-C9fc5` (`CONFIG_KASAN=y`, `ROCKCHIP_MPP_REWRITE`/`RGA_REWRITE=y`, vendor drivers off), verified to include the `0239` recovery-hardening commit via `System.map` symbols new in `1fe46df`. **UNVERIFIED in this repo:** that image has not been installed, booted, or run on the ROCK 5B — no captured booted-KUnit report or hardware evidence exists, so the recovery/fault paths (including the large 2026-07-23 recovery churn) still lack sanitizer-backed hardware evidence. |

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
