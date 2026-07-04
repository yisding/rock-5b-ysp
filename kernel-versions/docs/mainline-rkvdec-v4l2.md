# The mainline V4L2 stateless decoder (rkvdec rewrite)

A tour of the **mainline** V4L2 `rkvdec` decoder — the *other* decode stack, the
one this port deliberately does **not** ship (the shipped path is the vendor MPP
stack in [how-the-drivers-work.md](../../kernel-drivers/docs/how-the-drivers-work.md)). This doc exists
because the upstream `rkvdec` rewrite is where RK3588 decode is heading in
mainline, and understanding it is what makes the multi-core design work in
[multicore-scheduling.md](../../kernel-drivers/mpp/docs/multicore-scheduling.md) legible. Each concept opens
**In plain terms**, then **Under the hood**.

> **Anchors — different tree from the rest of this repo.** The `file:line`
> references here resolve against the **mainline kernel tree** on the
> `rk3588-rewrite-mainline` branch (local checkout `/home/yi/Code/kernel/linux`,
> `v6.18`-based), i.e. `drivers/media/platform/rockchip/rkvdec/` and
> `drivers/media/v4l2-core/`. This is **not** the forward-port MPP tree that
> [how-the-drivers-work.md](../../kernel-drivers/docs/how-the-drivers-work.md) and
> [source-trees.md](../../docs/source-trees.md) pin. Two different drivers for the
> same silicon — see § 1.

---

## 1. Two stacks, one chip

**In plain terms.** The RK3588 decoder silicon (VDPU381 cores + a CCU) can be
driven two completely different ways:

| | Vendor MPP (shipped here) | Mainline V4L2 `rkvdec` (this doc) |
|---|---|---|
| Userspace door | `/dev/mpp_service` (custom ioctls) | `/dev/videoN` + `/dev/mediaN` (V4L2 + Media Request API) |
| Who parses the bitstream | the driver / firmware helpers | **userspace** (GStreamer `v4l2codecs`, FFmpeg, Chromium) |
| Kernel framework | Rockchip MPP service core | V4L2 **mem2mem** + **Request API** |
| Codec state (DPB, reorder) | driver-side | **userspace-side** |
| Source | `mpp/mpp_rkvdec2.c` (+ `_link.c`) | `media/platform/rockchip/rkvdec/rkvdec.c` |

Same cores, same CCU, same IOMMUs — a different contract with userspace. The
vendor stack is what gives full H.264/H.265/VP9 decode today; the mainline stack
is the upstream trajectory (H.264 + HEVC + VP9 landed for VDPU381/VDPU383 in the
7.0 cycle). The glossary's [V4L2 entry](../../glossary.md) captures why the port
ships vendor MPP instead.

**Under the hood.** The mainline driver is a **stateless, mem2mem** decoder built
on three cooperating uAPIs: mem2mem (job scheduling), the extended controls
(per-frame metadata), and the **Media Request API** (atomic per-frame submission).
The whole design rests on one decision: **move bitstream parsing and DPB
management out of the kernel and into userspace**, because the silicon is a
fixed-function per-frame accelerator with no memory of previous frames — exactly
what the stateless API models.

---

## 2. Stateless vs stateful — who owns the codec state machine

**In plain terms.** A *stateful* decoder swallows a raw bitstream and hands back
frames; the kernel/firmware parses headers and tracks references. A *stateless*
decoder is dumber and faster: userspace parses the headers itself and hands the
hardware a fully-described job — "here is this frame's compressed bytes, here are
its exact SPS/PPS/slice params, here are its reference frames." The kernel holds
essentially **no** codec state between jobs.

**Under the hood.** This matches the VDPU381 silicon: a per-frame accelerator, not
a smart firmware decoder. So userspace owns:
- bitstream parsing (SPS/PPS/slice headers),
- the **DPB** (Decoded Picture Buffer — the set of frames kept as references; see
  [glossary](../../glossary.md)),
- output reordering (decode order ≠ display order).

and re-sends all of it, per frame, as controls. The kernel just resolves
references and refcounts buffers.

---

## 3. The uAPI

### 3a. The Request API is the linchpin

Because the hardware is stateless, every job needs its metadata delivered
atomically with its bitstream buffer. You can't set controls globally — slice N
and slice N+1 differ and may be in flight together. A **request** is a container
binding **one OUTPUT buffer + its codec controls** into one atomic unit.

Per-frame lifecycle userspace runs:

1. `MEDIA_IOC_REQUEST_ALLOC` → a request fd (one per OUTPUT buffer, recycled).
2. `VIDIOC_S_EXT_CTRLS` with `which = V4L2_CTRL_WHICH_REQUEST_VAL` + `request_fd`
   → stash SPS/PPS/slice/decode-params **into the request**, not the device.
3. `VIDIOC_QBUF` of the OUTPUT (bitstream) buffer with `V4L2_BUF_FLAG_REQUEST_FD`
   → bind the buffer to the request.
4. `MEDIA_REQUEST_IOC_QUEUE` on the request fd → submit. Missing buffer or missing
   required controls → `-ENOENT`.
5. CAPTURE buffers are queued **separately, never in the request** (stateless
   rule — the output frame is a shared resource, not part of one job's state).
6. Poll the request fd; `MEDIA_REQUEST_IOC_REINIT` to recycle.

The driver advertises this by making the OUTPUT queue `supports_requests` **and**
`requires_requests` (`rkvdec.c:1211-1212`) — you cannot queue a bitstream buffer
outside a request.

### 3b. Stateless-specific behaviors

- **A frame may take several requests.** Multi-slice H.264/HEVC frames decode
  into *one* CAPTURE buffer, signalled by `V4L2_BUF_FLAG_M2M_HOLD_CAPTURE_BUF` —
  the CAPTURE buffer is held (not returned) until the last slice lands. rkvdec
  enables this per-codec via `subsystem_flags`
  (`VB2_V4L2_FL_SUPPORTS_M2M_HOLD_CAPTURE_BUF`, e.g. `rkvdec.c:476`).
- **References are addressed by timestamp.** DPB entries name other frames by the
  `struct timespec` timestamp of their OUTPUT buffer; the driver resolves that to
  a CAPTURE vb2 buffer with `vb2_find_buffer()`. This is the join key of the whole
  model — see § 6c.
- **CAPTURE format is derived from the SPS**, not chosen freely: bit depth /
  chroma sampling come from the SPS control, so `rkvdec_s_ctrl()` watches the SPS
  and resets the decoded format when it changes (`rkvdec.c:149-182`).
- **Decode/start-code modes.** Per codec: FRAME_BASED vs SLICE_BASED, plus a
  START_CODE control (Annex-B or not). rkvdec clamps H.264/HEVC to **FRAME_BASED**
  (`rkvdec.c:321-324`), so the hardware parses slice headers itself.

### 3c. The control families

All in `include/uapi/linux/v4l2-controls.h`; these structs *are* the codec state
machine, serialized per frame:

| Codec | Key per-job controls |
|---|---|
| H.264 | `_h264_sps` / `_pps` / `_scaling_matrix` / `_decode_params` (+ `_slice_params`/`_pred_weights` for slice mode) |
| HEVC | `_hevc_sps` / `_pps` / `_slice_params` / `_decode_params` / `_scaling_matrix` (+ ext RPS) |
| VP9 | `v4l2_ctrl_vp9_frame` / `_compressed_hdr` |

rkvdec registers the union of all codecs' controls at open
(`rkvdec_init_ctrls`, `rkvdec.c:1250`); note vdpu381/vdpu383 add the HEVC
extension RPS controls (`V4L2_CID_STATELESS_HEVC_EXT_SPS_ST_RPS`/`LT_RPS`) that
the legacy control set lacks.

---

## 4. The in-kernel framework (three layers)

rkvdec is thin because the framework carries the weight.

**Layer 1 — Media Request core** (`drivers/media/mc/mc-request.c`). A
`media_request` holds a list of `objects` and `num_incomplete_objects`; states
`IDLE → VALIDATING → QUEUED → COMPLETE`. A vb2 buffer is one object; a per-request
control handler is another. Binding orders **controls before buffers**, so
controls apply first. Completion is refcounted: the request goes COMPLETE only
when **both** its buffer and its control handler complete.

**Layer 2 — v4l2-mem2mem** (`drivers/media/v4l2-core/v4l2-mem2mem.c`). Schedules
jobs across open contexts; one required driver op, `device_run`. In request mode,
`buf_queue` just appends to a ready list, and `req_queue = v4l2_m2m_request_queue`
walks the request's objects (controls first, buffer last) and calls
`v4l2_m2m_try_schedule()` once. On completion, stateless decoders call
`v4l2_m2m_buf_done_and_job_finish()`, which returns the **CAPTURE buffer before
the OUTPUT buffer** (`v4l2-mem2mem.c:520-534`) — returning the OUTPUT buffer
signals the request fd, which must not fire before the frame is done.

**Layer 3 — per-request controls** (`drivers/media/v4l2-core/v4l2-ctrls-request.c`).
Each request carries a cloned control handler; `S_EXT_CTRLS ...REQUEST_VAL` writes
into the clone. The driver brackets `device_run` with:
- `v4l2_ctrl_request_setup()` — copy this request's controls into the live
  controls (make the request's SPS/PPS/slice-params active);
- `v4l2_ctrl_request_complete()` — snapshot volatiles back and complete the
  control object (the second completion that drives the request COMPLETE).

---

## 5. The rkvdec object & ops model

Three runtime structs (`rkvdec.h`):
- **`rkvdec_dev`** — per hardware instance: v4l2/media/video devices, `m2m_dev`,
  MMIO (`regs`, plus `link` for vdpu383), clocks, IOMMU domains, SRAM pool,
  watchdog, and the selected **`variant`** (`rkvdec.h:128-145`).
- **`rkvdec_ctx`** — per open fd: coded+decoded formats, control handler, current
  `coded_fmt_desc`, `image_fmt`, RCB config (`rkvdec.h:147-160`).
- **`rkvdec_run`** — scratch for one job (src/dst buffers), extended per codec.

Two ops tables give a **double dispatch** — this is the whole abstraction:
- **`rkvdec_variant` / `rkvdec_variant_ops`** — per *hardware generation*:
  `irq_handler`, `colmv_size`, `flatten_matrices` (`rkvdec.h:74-89`). Chosen by OF
  `compatible` at probe (`rk3399` / `vdpu381` = RK3588 / `vdpu383` = RK3576,
  `rkvdec.c:1742-1764`).
- **`rkvdec_coded_fmt_ops`** — per *codec × generation*: `adjust_fmt`, `start`,
  `stop`, **`run`**, `done`, `try_ctrl`, `get_image_fmt` (`rkvdec.h:91-103`).
  Chosen by the OUTPUT format userspace sets.

The codec-agnostic core (`rkvdec.c`) never contains codec logic — it only calls
`ctx->coded_fmt_desc->ops->run(ctx)` and friends. The `extern` ops tables at
`rkvdec.h:187-197` are the seams.

---

## 6. The runtime job flow — one decoded frame

```
MEDIA_REQUEST_IOC_QUEUE (userspace)
 └─ req_validate → rkvdec_request_validate   (exactly 1 buffer/request, rkvdec.c:1059)
    req_queue    → v4l2_m2m_request_queue     (controls first, buffer last)
       └─ v4l2_m2m_try_schedule → rkvdec_device_run   (rkvdec.c:1161)
```

**`rkvdec_device_run`** (`rkvdec.c:1161`): `pm_runtime_resume_and_get`, then
`desc->ops->run(ctx)`; error → `rkvdec_job_finish(ERROR)`.

**The codec `run`** is always the same skeleton (H.264 shown;
`rkvdec-h264.c` + `rkvdec-h264-common.c`):

1. **`run_preamble`** — gather controls (`v4l2_ctrl_find` for
   SPS/PPS/DECODE_PARAMS/SCALING_MATRIX), then `rkvdec_run_preamble`
   (`rkvdec.c:1101`) grabs next src/dst buffers, calls **`v4l2_ctrl_request_setup`**,
   copies buffer metadata (incl. timestamp).
2. **Build ref lists** via the generic `v4l2_h264_*` helper library.
3. **Scaling lists** — memcpy from control into the priv table.
4. **Assemble HW param packet** — pack SPS+PPS into `priv_tbl->param_set[pps_id]`.
5. **Resolve references by timestamp** — `lookup_ref_buf_idx`
   (`rkvdec-h264-common.c:24`): for each active DPB entry,
   `vb2_find_buffer(cap_q, dpb[i].reference_ts)` (`:37`). **This line is the
   stateless idea in code.**
6. **Assemble RPS** — bit-pack frame_nums + P/B0/B1 ref indices
   (`assemble_hw_rps`, `:47`); inactive DPB slots get an invalid pic_num.
7. **`config_registers`** — strides, stream base = `vb2_dma_contig_plane_dma_addr(src)`,
   output base = dst, CABAC/scaling/pps/rps bases, reference addresses. If a
   reference resolved NULL, **the current dst address is substituted** to avoid a
   bogus DMA/IOMMU access.

Then **`run_postamble`** (`rkvdec.c:1118`) calls `v4l2_ctrl_request_complete`,
schedules the watchdog, and the backend triggers the hardware.

**Completion is IRQ-driven.** `rkvdec_irq_handler` (`rkvdec.c:1518`) dispatches to
`variant->ops->irq_handler`; each generation reads+clears status, decides
DONE/ERROR, does `cancel_delayed_work(&watchdog)` and only then
`rkvdec_job_finish` — the `cancel_delayed_work` return value is the one-winner
race guard between IRQ and watchdog. `rkvdec_job_finish` (`rkvdec.c:1092`):
`pm_runtime_put_autosuspend`, optional codec `->done` (VP9 only), then
`v4l2_m2m_buf_done_and_job_finish`.

### 6a. rkvdec-specific mechanisms

- **RCB — "Rows and Columns Buffers"** (`rkvdec-rcb.c`). Per-picture-scaled scratch
  (intra/deblock/SAO/filter). `rkvdec_allocate_rcb` (`:82`) sizes each region from
  a per-variant table and **tries on-chip SRAM first** (IOMMU-mapped), falling
  back to DRAM. SRAM is the real perf/power win. Same concept as the vendor
  stack's RCB ([glossary](../../glossary.md)), independently implemented.
- **colmv** — collocated motion vectors, tucked in the tail of each CAPTURE buffer
  at `ctx->colmv_offset`, sized by `variant->ops->colmv_size` (`rkvdec.c:101-111`).
- **IOMMU error recovery** — `rkvdec_iommu_restore` (`rkvdec.c:1422`) attaches then
  immediately detaches a pre-allocated **empty domain** to flush a bad page-table
  state after a decode error, from IRQ context.
- **Watchdog** (`rkvdec.c:1599`) — armed at 2× the HW timeout (AXI-clock scaled);
  forces an ERROR finish if the IRQ never comes.

### 6b. The multi-core stub (why this doc feeds the next one)

`rkvdec_disable_multicore()` (`rkvdec.c:1623`) probes **only the first** VDPU381
core and returns `-ENODEV` for the rest, to avoid exposing per-core `/dev/videoN`
nodes as ABI before an in-kernel scheduler exists. The comment notes the
"cluster all cores together" future. That gap is the entire subject of
[multicore-scheduling.md](../../kernel-drivers/mpp/docs/multicore-scheduling.md).

### 6c. Why the data path is already multi-core-friendly

References resolve by timestamp against the **shared** CAPTURE queue
(`vb2_find_buffer`), and CAPTURE buffers are device-global DMABUFs. So a frame
decoded on core 1 can reference a frame decoded on core 0 with **no** change to
the lookup path. The blocker to concurrency is *scheduling* + *per-core
resources*, not data sharing — see the next doc.

---

## 7. Codec backends

**H.264** — frame-based only; reads SPS/PPS/DECODE_PARAMS/SCALING_MATRIX (no
`slice_params`/`pred_weights`). References by timestamp, RPS bit-packed. CABAC
contexts seeded from a static `4×464×2` init table (`rkvdec-cabac.c`) copied into
the priv table at `start` and pointed at by a base register.

**HEVC** — three backends sharing `rkvdec-hevc-common.c`. The architectural split
is reference-set handling: **legacy** derives ref lists from `slice_params`
(`assemble_sw_rps`); **vdpu381/383** use the newer **extension RPS controls** via
the shared `rkvdec_hevc_assemble_hw_rps`, implementing the spec's short/long-term
RPS prediction in-kernel. Missing ext-RPS: vdpu381 *warns and decodes*, vdpu383
*hard-fails* (`-EINVAL`) because it causes IOMMU faults. Scaling-list flatten
differs per generation (`variant->ops->flatten_matrices`).

**VP9** — the odd one out, and the only codec with a **`.done`** callback. It
carries adaptive entropy state across frames: four saved `frame_context[]`
probability sets, forward-updated before decode (`init_probs`), with the hardware
writing symbol **counts** into a DMA `count_tbl`. After each frame,
`rkvdec_vp9_done` runs the spec's `refresh_probs()`
(`v4l2_vp9_adapt_coef_probs` / `_noncoef_probs`) and saves the adapted context.
It also carries `last`/`cur` frame info (segmentation, loop-filter deltas,
ping-pong segmentation maps) and programs reference scale factors for VP9's
inter-frame resizing. No SPS/PPS — just `VP9_FRAME` + `VP9_COMPRESSED_HDR`.

---

## 8. Generation differences (rk3399 / vdpu381 / vdpu383)

| | rk3399-class | vdpu381 (RK3588) | vdpu383 (RK3576) |
|---|---|---|---|
| Register model | one window, flat struct, single memcpy | one window, 5 banks at fixed offsets | **two windows** (`function`+`link`), 4 banks |
| Param packing | bit-writer, small packets | **C bitfield structs** | bit-writer, large layout (POC/ref flags packed *into* param buf) |
| HEVC ref sets | slice-derived (`assemble_sw_rps`) | ext-RPS controls (warn if absent) | ext-RPS controls (**error** if absent) |
| Decode trigger | prefetch + `RKVDEC_REG_INTERRUPT` DEC_E | `writel(DEC_E, VDPU381_REG_DEC_E)` | link engine: timeout + IP-enable + `LINK_DEC_ENABLE` |
| `colmv_size` | `128·⌈w/16⌉·⌈h/16⌉` | same | `ALIGN(w,64)·ALIGN(h,16)` |
| IRQ status reg | `RKVDEC_REG_INTERRUPT` | `VDPU381_REG_STA_INT` | `link + VDPU383_LINK_STA_INT` |

The vdpu383 is a **link/command-buffer** engine (separate MMIO region, more state
packed into DMA buffers than registers); vdpu381 and the legacy parts are
direct-register-programmed. The core hides all of this behind the
`variant_ops` + `coded_fmt_ops` double dispatch, so the scheduling/request/PM/
watchdog machinery is written once.

---

## See also

- [multicore-scheduling.md](../../kernel-drivers/mpp/docs/multicore-scheduling.md) — the mem2mem scheduler,
  the multi-core design space, the Collabora multicore series, and the CCU
  hard/soft analysis. This doc is its prerequisite.
- [how-the-drivers-work.md](../../kernel-drivers/docs/how-the-drivers-work.md) — the **vendor MPP** decode
  stack (the shipped path), incl. the vendor CCU/soft-hard treatment (§ 7a) and
  RCB/link mode (§ 8).
- [vanilla-kernel.md](./vanilla-kernel.md) — the vendor decoder DT; § "If your
  kernel already has the V4L2 rkvdec driver" is the stack-choice note.
- [glossary](../../glossary.md) — DPB, mem2mem, Request API, RCB, CCU, IOMMU.
