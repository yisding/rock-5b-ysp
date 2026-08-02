# Three of the seven mainline codec-fix patches are defective

> Scope: this project's own `kernel-drivers/patches/mainline-codec-fixes/`
> series, reviewed against the mainline it targets
> Source: `~/Code/rock-5b/kernel/linux-mainline-codec-fixes` branch
> `mainline-rkvdec-hantro-fixes-ready` @ `c28b6586f74f7`, base
> `3708dd9488440` (Torvalds master, v7.2-rc6 era, 2026-07-30);
> `drivers/media/platform/verisilicon/hantro_drv.c`,
> `drivers/media/platform/rockchip/rkvdec/rkvdec.c`,
> `drivers/media/v4l2-core/v4l2-mem2mem.c`, `drivers/base/platform.c`,
> `drivers/of/device.c`
> Date: 2026-08-02
> Trust: SOURCE-INSPECTED, CONFIRMED

## Result

The seven patches produced from the [2026-07-30 mainline codec
audit](../kernel-drivers/docs/driver-architecture-comparison.md#12-current-mainline-and-maxline-rockchip-codec-audit-2026-07-30)
are checkpatch-clean, apply cleanly, and compile. That was the whole of their
recorded validation, and it hid three defects **introduced by the patches
themselves**. Each was confirmed by reading the mainline source the series
targets, not inferred from the patch text.

| Patch | Verdict |
|-------|---------|
| `0001` rkvdec `TRY_FMT` colmv offset | Correct as written |
| `0002` rkvdec unrepresentable capture sizes | **Defective** — rejects advertised geometry |
| `0003` rkvdec clock enables to runtime PM | Correct as written |
| `0004` hantro failed-run unwind | **Defective** — self-deadlock and sleep-in-atomic |
| `0005` rkvdec streaming DMA mask | **No-op** — mask is already 32-bit |
| `0006` hantro streaming DMA mask | **No-op** — mask is already 32-bit |
| `0007` rkvdec borrowed SRAM pool | Correct as written |

The audit's *analysis* survives review in all seven cases. What failed is the
step from a correct diagnosis to a correct patch, in three of seven attempts.

### `0004` deadlocks against the watchdog it cancels

The patch adds `hantro_abort_prepare_run()`, whose first statement is
`cancel_delayed_work_sync(&ctx->dev->watchdog_work)` (`hantro_drv.c` ~:178).
It is reached from the `err_abort_run` label of `device_run()` (~:213), on any
synchronous backend `run()` failure.

`watchdog_work`'s own callback is `hantro_watchdog()` (~:118), and that
callback re-enters `device_run()` through the mem2mem core:

```text
hantro_watchdog()                       ← running as watchdog_work
  hantro_job_finish()                                       (~:130)
    hantro_job_finish_no_pm()
      v4l2_m2m_buf_done_and_job_finish()
        v4l2_m2m_schedule_next_job()    v4l2-mem2mem.c      (~:540)
          device_run()                  ← next job
            ctx->codec_ops->run() fails
              hantro_abort_prepare_run()
                cancel_delayed_work_sync(&...->watchdog_work)
```

The final call waits for `watchdog_work`'s callback to finish, and that
callback is the caller. It never returns.

The same path is reachable from hard IRQ. `hantro_irq_done()` (~:100) runs from
a handler registered with plain `devm_request_irq()` (~:1208) — not threaded —
and chains into the next `device_run()` identically, so
`cancel_delayed_work_sync()` also `might_sleep()` in atomic context. No hantro
or rkvdec path calls `pm_runtime_irq_safe()`.

Mainline's existing non-sync cancel is deliberate, and carries a comment saying
so (~:106-111):

```c
	/*
	 * If cancel_delayed_work returns false
	 * the timeout expired. The watchdog is running,
	 * and will take care of finishing the job.
	 */
	if (cancel_delayed_work(&vpu->watchdog_work)) {
```

That return value *is* the handoff protocol between the interrupt and the
watchdog for who owns job completion. The patch replaces it on the error path
with a blocking wait, which is exactly the operation the protocol exists to
avoid.

The rest of `0004` — tracking `ctrls_setup` so request controls are completed
exactly once, balancing clocks and runtime PM by last successful acquisition,
and removing the VPU981 AV1 backend's double completion — is sound. Only the
watchdog cancel is wrong, and the non-sync form is not a drop-in replacement
here because `device_run()` cannot then know whether the watchdog already owns
the job.

### `0002` rejects geometry the same driver advertises

The patch makes `rkvdec_fill_decoded_pixfmt()` return `-EINVAL` for a format
whose true byte span will not fit `sizeimage`, and propagates that out through
`rkvdec_adjust_capture_fmt()` to both `VIDIOC_TRY_FMT` and `VIDIOC_S_FMT`.

Those dimensions are published by the same driver. `rkvdec_enum_framesizes()`
(~:695) reports `desc->frmsize.max_width` / `max_height` verbatim (~:710,
~:713), and the coded-format descriptors carry 65520×65520 for VDPU381 H.264
(~:601) and 65472×65472 for the HEVC and VDPU383 entries (~:585, ~:620, ~:636).
The overflow case the patch is built around, NV12 at 46400×46400, is far inside
that advertised range.

V4L2 requires `TRY_FMT` and `S_FMT` to **adjust** a format the driver cannot
accept and return success, not to fail. A driver that enumerates a size and
then refuses it is inconsistent on its own interface, and `v4l2-compliance`
tests this. The correction is to clamp the geometry down to the largest
representable size for the requested pixel format — which also makes
`enum_framesizes` honest — rather than to reject.

A second, softer problem sits in the same patch. `rkvdec_decoded_image_size()`
hand-rolls a numerator/denominator table for NV12, NV15, NV16 and NV20, then
calls `v4l2_fill_pixfmt_mp()` anyway and overwrites the `sizeimage` the core
helper produced. That duplicates the V4L2 core's format table inside the driver
where the two can drift apart. Checking the core helper's own output for
overflow keeps one source of truth.

### `0005` and `0006` change nothing

Both patches replace `dma_set_coherent_mask(dev, DMA_BIT_MASK(32))` with
`dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32))`, on the premise that the
streaming mask is otherwise unconstrained. For these platform devices it
already is constrained, by two mechanisms that both run before probe:

- `setup_pdev_dma_masks()` (`drivers/base/platform.c` ~:571) gives every
  platform device `coherent_dma_mask = DMA_BIT_MASK(32)` and points
  `dma_mask` at a `platform_dma_mask` also initialized to `DMA_BIT_MASK(32)`,
  whenever the device does not already carry its own.
- `of_dma_configure_id()` (`drivers/of/device.c` ~:139-140) then only ever
  narrows what it found:

  ```c
  dev->coherent_dma_mask &= mask;
  *dev->dma_mask &= mask;
  ```

So `dev->dma_mask` is at most 32 bits by the time either driver probes, and the
call the patches add cannot widen or narrow it. The audit's underlying point —
that vb2 maps imported DMABUFs through the streaming API and `dev->dma_mask`,
so a coherent-only mask would not establish the invariant the Hantro comment
claims — is correct as a statement about the API. It just does not describe a
live defect on this device class.

Each patch nonetheless carries a `Fixes:` tag (`cd33c830448b` and
`775fec69008d`), which asserts a regression that does not exist.

### The four remaining defects are real, and the patches address them correctly

Re-confirmed against the same source:

- **`0001`** — `rkvdec_fill_decoded_pixfmt()` stores the derived offset into
  `ctx->colmv_offset` while being reachable from `TRY_FMT`, so a speculative
  query moves the colocated motion-vector offset a later decode programs.
  `colmv_offset` was introduced by `e5aa698ea6591`, so the patch's `Fixes:` tag
  is accurate.
- **`0003`** — probe used `devm_clk_bulk_get_all_enabled()`, which enables until
  devres teardown, while `rkvdec_runtime_resume()` (~:1969) separately calls
  `clk_bulk_prepare_enable()` and `rkvdec_runtime_suspend()` (~:1976) calls
  `clk_bulk_disable_unprepare()`. Suspend therefore drops only the second
  reference and autosuspend never gates the clocks.
- **`0007`** — `rkvdec->sram_pool` comes from `of_gen_pool_get()` (~:1923),
  which borrows the SRAM provider's pool rather than transferring it, so the
  probe error path's `gen_pool_destroy()` destroyed an object it did not own.

All four `Fixes:` targets named in the series resolve in the tree:
`e5aa698ea6591`, `6a846f7d72c7b`, `cd33c830448ba`, `e5640dbb991c4`.

## Boundary

Everything here is source inspection against one pinned tree. Specifically:

- The `0004` deadlock is derived from the call graph, not observed. A
  `DEBUG_ATOMIC_SLEEP` build plus fault injection at
  `ctx->codec_ops->run()` would convert it to a measured result, and is the
  same run that would have caught it before the patch was written.
- The `0005`/`0006` no-op conclusion holds for platform devices reaching probe
  through the normal OF path. It does not cover a device whose `dma_mask` was
  widened by something between `setup_pdev_dma_masks()` and probe; no such path
  was found for these two drivers, but none was searched for exhaustively.
- None of the seven patches has been run on hardware. That was true when they
  were written and is still true; the `0003` clock behavior in particular is
  cheap to check by reading the relevant counts in
  `/sys/kernel/debug/clk/clk_summary` before decode, during, and after the
  autosuspend interval.
- The verdicts above are about correctness, not about whether a maintainer
  accepts the patches. `0002`'s clamp-versus-reject question is a genuine
  interface decision for the rkvdec maintainers, not something this review
  settles.

## Why it matters

The series carried exactly the validation that cannot see any of these three
defects. `checkpatch --strict`, a clean `git am`, and a `W=1` compile all pass
on a patch that deadlocks, on a patch that violates the V4L2 interface
contract, and on two patches that do nothing. Compile-clean is a shape check;
none of these are shape problems.

This is the second consecutive adversarial pass over this project's own
prepared upstream material to find claims that were wrong in our own favour; an
earlier pass over a different prepared report, recorded in the private
`rock-5b-security` repository, was the first. Two independent reviews each
finding real defects is evidence about the review process rather than about
either artifact: prepared upstream material needs a hostile read against the
target's source before it goes, and the read has to be done by someone trying
to break it.

The narrower lesson is about where the defects clustered. `0001`, `0003` and
`0007` are each small, local, and expressed as a deletion or a one-word change,
and all three are correct. `0002` and `0004` are the two patches that added new
control flow, and both are wrong. `0005`/`0006` are the two written from an API
generalization rather than from a specific traced path, and both are empty.
Patch size and mechanism predicted correctness here better than the strength of
the underlying analysis did.
