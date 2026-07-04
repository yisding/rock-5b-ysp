# MPP decoder fast mode (fast parse)

How `librockchip_mpp` overlaps CPU bitstream parsing with hardware decode inside a
single decoder instance. Fast mode is **on by default** and is the active
multi-instance throughput mechanism — it is what replaced the (dormant)
cross-session batch server documented in
[`mpp-ioctl-batch-mode.md`](mpp-ioctl-batch-mode.md).

Complements [`mpp-library-architecture.md`](mpp-library-architecture.md) (see its
"Decoder Internals" / "Task Queue Model" sections for the thread model this builds
on).

Sources studied:

| Source | Notes |
|--------|-------|
| `mpp-rockchip` at `1375813cbbae5ad6861b166475dd8fb672183220` | Current HEAD; all `(~:NNN)` anchors are against this tree. |
| `mpp/codec/mpp_dec.c` | Capability negotiation, task-count sizing (`mpp_dec_init`, `mpp_dec_update_cfg`). |
| `mpp/codec/mpp_dec_normal.c` | The two-thread decode loop and the fast-mode control-flow gates. |
| `mpp/base/mpp_dec_cfg.c`, `mpp/inc/mpp_dec_cfg.h`, `mpp/codec/inc/mpp_dec_impl.h` | Config plumbing and the default value. |
| `mpp/hal/rkdec/**`, `mpp/hal/rkdec/inc/vdpu_com.h` | Per-HAL capability flag and the register ring. |
| Commit `e66e69d3` (2022-05-12) | Added `support_fast_mode` plumbing and removed batch-mode wiring in the same change. |

> **Trust:** MEASURED-from-source at the pin above (code read directly, not run on
> hardware). No HYPOTHESIS content in this doc.

## One-liner

Fast mode pipelines a single decoder: while the hardware decodes frame N, the
parser thread already parses and submits frames N+1 (and N+2). It does this by
(1) deepening the in-flight task queue from 2 to 3, (2) giving the HAL a ring of 3
register/scratch buffer sets, and (3) removing the parser gate that otherwise
blocks until the previous frame's hardware finishes. It requires HAL support and
falls back silently to serialized decode when unavailable.

## The decode loop is already two threads

Classic MPP decode is a producer/consumer pair in `mpp/codec/mpp_dec_normal.c`,
linked by a `HalTaskGroup` of `hal_task_count` handles cycling through
`TASK_IDLE -> TASK_PROCESSING -> TASK_PROC_DONE`:

- **Parser thread** (`mpp_dec_parser_thread`, `~:685`) — per task: parse bitstream
  (`mpp_parser_parse`, `~:506`), generate registers (`mpp_hal_reg_gen`, `~:657`),
  **start** hardware (`mpp_hal_hw_start`, `~:662`, a non-blocking
  `MPP_DEV_CMD_SEND`), then hand off via `mpp_dec_put_task` -> `TASK_PROCESSING`
  (`~:231`).
- **Hal thread** (`mpp_dec_hal_thread`, `~:767`) — pull a `TASK_PROCESSING` handle,
  **wait** for completion (`mpp_hal_hw_wait`, `~:864`, `MPP_DEV_CMD_POLL`), output
  the frame, recycle the handle.

Hardware submit and wait are already split across the two threads. That split is
what *could* overlap — but in non-fast mode a gate re-serializes it.

## The three coupled changes

### 1. Remove the parser's "wait previous frame" gate

`mpp/codec/mpp_dec_normal.c:449`, sitting *before* the parse call:

```c
/* 7.1 if not fast mode wait previous task done here */
if (!dec->parser_fast_mode) {
    if (!task->status.prev_task_rdy) {
        hal_task_get_hnd(tasks, TASK_PROC_DONE, &task_prev);
        if (task_prev) { /* reclaim it */ }
        else { task->wait.prev_task = 1; return MPP_NOK; }   /* BLOCK the parser */
    }
}
```

Non-fast: the parser cannot begin frame N+1 until the previous frame has finished
hardware decode and reached `TASK_PROC_DONE`. Fast: the block is skipped — the
parser runs ahead.

### 2. Change how the hal thread retires a finished task

`mpp/codec/mpp_dec_normal.c:878`:

```c
hal_task_hnd_set_status(task, (dec->parser_fast_mode != 0) ? TASK_IDLE : TASK_PROC_DONE);
if (dec->parser_fast_mode) notify_flag |= MPP_DEC_NOTIFY_TASK_HND_VALID;
else                       notify_flag |= MPP_DEC_NOTIFY_TASK_PREV_DONE;
```

Fast frees the handle straight to `TASK_IDLE`. Non-fast parks it in
`TASK_PROC_DONE` *so the parser gate above can reclaim it* — that is the
back-pressure loop that serializes the pipeline.

### 3. Deepen the pipeline

`mpp/codec/mpp_dec.c:650` (inside `mpp_dec_init`):

```c
if (dec_cfg->base.fast_parse && support_fast_mode)
    hal_task_count = (status->hal_task_count != 0) ? status->hal_task_count : 3;  /* fast: 3 */
else { dec_cfg->base.fast_parse = 0; p->parser_fast_mode = 0; }                   /* non-fast: 2 */
```

`hal_task_count` (default **2**, fast **3**) sizes the task-handle group
(`hal_task_group_init`), the packet slots (`mpp_buf_slot_setup`), and matches the
HAL's register-ring depth.

## Timeline: serialized vs pipelined

- **Non-fast:** `parse(N) -> submit(N) -> [parser blocks] -> HW(N) done -> parse(N+1)…`
  CPU idle during decode, VPU idle during parse. Throughput ~ 1/(parse+decode).
- **Fast:** `parse(N)->submit(N)`, immediately `parse(N+1)->submit(N+1)`,
  `parse(N+2)…` up to 3 in flight, hal thread draining completions in parallel.
  CPU parse overlaps VPU decode. Throughput ~ 1/max(parse,decode). Biggest win on
  many-small-frame streams where per-frame parse/setup is significant.

## Why HAL support is mandatory — the register ring

If the parser programs frame N+1's registers while the hardware is still consuming
frame N's, a single register/scratch buffer would be corrupted. Fast-capable HALs
keep a ring of register + auxiliary buffer sets, one per in-flight task. From
`mpp/hal/rkdec/vp9d/hal_vp9d_vdpu34x.c`:

```c
Vp9dRegBuf g_buf[VDPU_FAST_REG_SET_CNT];        /* VDPU_FAST_REG_SET_CNT == 3  (vdpu_com.h:13) */
if (p_hal->fast_mode)
    for (i=0;i<VDPU_FAST_REG_SET_CNT;i++) g_buf[i].hw_regs = calloc(...);  /* 3 sets + probe/rcb each */
else
    hw_ctx->hw_regs = calloc(...);              /* ONE set */
```

Each task claims a free ring slot and records its index (`~:437`):

```c
for (i=0;i<VDPU_FAST_REG_SET_CNT;i++)
    if (!g_buf[i].use_flag) { task->dec.reg_index = i; g_buf[i].use_flag = 1; break; }
```

All later register/rcb/probe access indexes by `task->dec.reg_index` (e.g.
`g_buf[task->dec.reg_index].rcb_buf`, `~:840`); the slot's `use_flag` clears when
the hardware completes. `hal_h264d_vdpu382.c:519` states it directly:
`max_cnt = fast_mode ? VDPU_FAST_REG_SET_CNT : 1`. Ring depth (3) == `hal_task_count`
(3) — the same pipeline depth expressed in the HAL and codec layers.

## Enabling and capability negotiation — default ON

- **Default:** `mpp_dec_cfg_set_default` sets `cfg->base.fast_parse = 1`
  (`mpp/base/mpp_dec_cfg.c:73`). Fast mode is therefore the default decode path;
  the serialized 2-deep path is the *fallback*, not the baseline.
- **App override:** `MPP_DEC_CFG` `"base:fast_parse"` (`mpp/codec/mpp_dec.c:995`).
  To *disable*, an app must explicitly set it to 0.
- **HAL advertises:** each HAL sets `cfg->support_fast_mode` at init;
  `mpp_dec_init` reads it back (`mpp_dec.c:648`).
- **Negotiation is an AND:** fast mode engages only if
  `fast_parse && support_fast_mode`; otherwise `fast_parse` is force-cleared, with
  a guard in `mpp_dec_update_cfg` (`~:57`): *"can not enable fast parse while hal
  not support."*

## Support matrix

Advertised (`support_fast_mode = 1`) by the modern RKVDEC HALs — the RK3588 /
Rock 5B decode path:

| Codec | Backends that support fast mode |
|-------|---------------------------------|
| H.264 | `rkv`, `vdpu34x`, `vdpu382`, `vdpu383`, `vdpu384a`, `vdpu384b` |
| H.265 | `rkv`, `vdpu34x`, `vdpu382`, `vdpu383`, `vdpu384a`, `vdpu384b` |
| VP9   | `vdpu34x`, `vdpu382`, `vdpu383`, `vdpu384b` |
| AVS2  | `rkv`, `vdpu382`, `vdpu383`, `vdpu384b` |
| AV1   | `vdpu383`, `vdpu384b` |

Falls back to serialized 2-deep (leaves `support_fast_mode = 0`):

- Classic **VPU1 / VPU2** H.264 backends (`hal_h264d_vdpu1.c`, `hal_h264d_vdpu2.c`).
- **VP9 on `rkv`** specifically (`hal_vp9d_rkv.c:200` sets it to 0) — note this is a
  per-codec exception: H.264/H.265/AVS2 on `rkv` opt *in*, VP9 on `rkv` opts *out*.
- MJPEG and other legacy paths.

When unsupported the negotiation silently clears `fast_parse` and decode still
works, just without overlap.

## Caveats

- **Error handling is harder.** H.265 tracks `fast_mode_err_found`
  (`hal_h265d_rkv.c:~1019`): with references still in flight, error concealment
  cannot assume the previous frame is fully retired.
- **Partial barriers remain.** VP9 sets `wait.dec_all_done` in fast mode
  (`mpp_dec_normal.c:671`) and drains all `TASK_PROCESSING` (`~:468`) for cases like
  superframe / probability-context updates — so even fast mode occasionally
  serializes.
- **Memory cost:** 3x register/rcb/probe buffers, deeper packet slots, and more
  simultaneously-held DPB frames. This is why it is negotiated, not unconditional.

## Relationship to batch mode

Complementary, not alternatives:

- **Fast mode** — *intra-instance* pipelining (parse vs decode overlap within one
  decoder). Default-on, active.
- **Batch mode** — *cross-instance* syscall coalescing (many decoders' tasks in one
  ioctl). Dormant; see [`mpp-ioctl-batch-mode.md`](mpp-ioctl-batch-mode.md).

The same commit that removed batch mode's decoder wiring — `e66e69d3`
(2022-05-12, *"Diable fast mode when hal not support"*) — is the one that added the
`support_fast_mode` HAL plumbing. Rockchip pivoted the multi-instance throughput
effort from "one big syscall for many instances" to "keep each instance's hardware
continuously fed," and made the latter the default.
