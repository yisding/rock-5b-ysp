# Rewrite-driver review round 2: 12 confirmed defects fixed, 4 items ledgered

> Scope: kernel-drivers — `mpp-rewrite` + `rga-rewrite` clean-room drivers
> Source: `~/Code/kernel/linux-6.18-rkvenc` @ `51ea9d1ca537` (branch
> `rk3588-rewrite-6.18`); fixes land as `cd71f985a784c`, mirrored byte-identically
> to `~/Code/kernel/linux` @ `7dcb4c3b5a981` (`rk3588-rewrite-mainline`).
> Oracles: BSP `~/Code/kernel/rockchip-kernel` `drivers/video/rockchip/rga3/`,
> `~/Code/rockchip-userspace/librga-fork` (`core/NormalRga.cpp`), the in-tree
> `ABI.rst` ledgers, and the drivers' own KUnit expectations.
> Date: 2026-07-29
> Trust: CODE-INSPECTED, COMPILE-VERIFIED — no booted kernel, no hardware run

## Result

A 13-slice full-file review (five MPP slices, eight RGA slices, every line of
both drivers including the embedded KUnit suites) on the post-fixture-isolation
tips produced 21 candidate findings. Twelve were confirmed against an oracle
and fixed in one commit per tree; four are ledgered as open items; the rest
were refuted during verification or are pre-existing entries in the
fixture-debt baseline. Nine of the thirteen slices returned no surviving
findings at all — the July hardening held up well; most of what this round
caught is either new since the fixture isolation or sits on the opt-in and
legacy edges.

## The headline: legacy rot90/270 was rejected wholesale

`c_RkRgaBlit()`/im2d submit 90°/270° rotations with the destination window
**pre-swapped** — `dstActW = rect.height`, `dstActH = rect.width`
(`NormalRga.cpp:1052-1054`) — while `vir_w`/`vir_h` stay in canvas
orientation. The vendor driver un-swaps before checking and additionally
exempts `rotate_mode == 1` from the `vir_w < act_w` rejection
(`rga2_reg_info.c:2461-2463`, `:2780-2795`). The rewrite's validators checked
the raw wire form, so `x_offset + act_w > vir_w` failed **every genuine
portrait rotate** on both backends with `-EINVAL` — every GStreamer/FFmpeg
90°/270° conversion through the legacy path.

The rewrite's *emitters* were already wire-form correct (they re-swap
internally, `rk_rga3_emit_read_window()` pairing src/dst act exactly like the
vendor formulas), and `rk_rga3_check_scale()`'s double swap is also correct
under wire input. The bug was masked because the rotate KUnit profiles fed
*unswapped canvas geometry* — a shape shipping librga never submits — which
the validators accepted and the emitters turned into transposed windows the
tests never inspected beyond ctrl bits. One test proved the intended
convention: `rk_rga3_librga_center_rotate_emit_kunit` (the RKNN letterbox
shape) already used faithful wire geometry and pinned a correct
canvas-oriented write window.

Fix: validate the destination rectangle in canvas orientation (RGA2 validates
the existing `rk_rga2_normalized_dst()`; RGA3 swaps a local copy for the
rectangle/tile/semiplanar-alignment checks only, scoped to non-pattern
tasks), and rewrite the rotate tests — gstreamer profile + matrix, ffmpeg
RGA3 profile, rotation extrema 270°, both librga rotate emit tests, the
no-pattern alpha-rotate sub-case, and the RGA2 XRGB 270° display case — to
faithful pre-swapped inputs pinning canvas-oriented `DST_SIZE`/corner values
(e.g. the XRGB 270° corner moves from the transposed `31*128` to the correct
bottom-left `63*128`).

## Other confirmed fixes

**MPP hard-CCU link-chain dual writer (major, opt-in path).** The per-core
link-table relink (`hw->lock`) and the coordinator-chain relink (`ccu->lock`)
both wrote the same `table[next_word]` DMA words with different successor
chains. Only hard-CCU jobs ever populate the per-core list, and the hardware
follows the coordinator chain (single `CFG_ADDR` + `ADD_MODE` + completion
scan), so a poll-time release of a finished job could rewrite a *running*
cross-core chain to point at an unused node, silently dropping the jobs
behind it. The per-core relink, list, and fields are gone; staging prelinks
each new table to an unused node (never an active sibling); the ownership
KUnit case now pins that release/stage do not rewrite sibling tables.

**MPP abort never kicked the scheduler (major).** `rk_mpp_hw_abort_job()`
idles a core without `schedule_work(&srv->sched_work)`; only
`rk_mpp_job_complete()` kicks. Another session's queued job waited until
unrelated service activity — indefinitely for a lone client. The abort path
now kicks when queued work exists.

**MPP global-singleton leakage into shared paths (major for tests, latent in
production).** `rk_mpp_hw_abort_queued_matching()` swept `&rk_mpp_srv`'s
queue instead of `target->srv` — the local-service
`rk_mpp_hw_abort_ccu_dependents_kunit` fixture provably failed. The same
class (`handle_reset_failure`, rkvdec2 IRQ-thread CCU lookup, IRQ/reset
counters, `debug_record_active`, IOMMU fault-handler registration) now
derives the service from the bound core.

**MPP KUnit double free (critical, test-only).**
`rk_mpp_session_abort_hw_active_kunit` kunit-allocated the job whose refs the
exercised abort path drops to zero; `rk_mpp_job_release()` `kfree()`s it and
KUnit teardown freed it again — every run, on the next boot's suite. Plain
`kzalloc` now, matching the sibling test; the audit baseline records the two
new deliberate signals (325 → 327).

**RGA fence contract violations (major).** All release fences shared one
service-wide `dma_fence` context with submit-order seqnos, but jobs complete
per-core in any order: out-of-order signaling on one timeline, and
`dma-fence-unwrap` dedups same-context fences to the highest seqno, so a
merged sync_file could signal while the slower job was still writing. Every
fence now carries its own context (matching the KUnit fake's convention; the
BSP's single context has the same flaw — deliberate divergence). Exported
sync_file fds also pin only the built-in sync core, not this module; each
live fence now holds a module reference so `rmmod` fails with `-EBUSY`
instead of leaving `fence->ops`/the fence lock in freed module memory.

**RGA shared-IRQ unpowered MMIO (major).** The RGA3 level IRQ is shared with
the Rockchip IOMMU and registered without `IRQF_ONESHOT`; a peer refire after
the completion thread gated the clocks (or an interrupt in the probe window)
made the hard handler read `INT_RAW` on a clockless core — bus stall. A
`job_lock`-held regs-live count now gates all hard-handler MMIO; power-off
drops it under the same lock before disabling clocks.

**RGA timeout done-salvage (minor).** Recovery read back the interrupt status
but failed the job with `-EBUSY` even when the readback showed the blit
finished (completion latched while the watchdog held the line masked). The
job now completes with the interrupt-derived result; the recovery reset still
clears the latch.

**RGA gauss alpha default (minor).** Gauss without `global_alpha_en`
programmed source global alpha 0 where the BSP forces `0xff`
(`rga2_reg_info.c:2648-2655`) — fully transparent blurred output for direct
ioctl callers. Now defaults opaque.

**RGA legacy FBC/tile userptr sizing (minor).** `rk_rga_resolve_direct_img()`
dropped `rd_mode` when synthesizing the import, sizing AFBC via the raster
fallback, so materialization rejected the pinned range as too small. The
synthesized import is now sized from the image's own layout.

**RGA sync-wait KUnit teardown UAF (major, test-only).** The sync-blit test's
completion waits were non-aborting EXPECTs; on a stalled workqueue it tore
down the on-stack session and kunit-freed objects while the worker could
still reach them, then removed the cleanup action. The timeout path now
force-drains the worker (`removing` + abort + `cancel_work_sync`) before any
teardown.

**Housekeeping.** Both KUnit Kconfig help texts still described the retired
unbind/singleton fixture design (suites are now plain case tables over local
services); rewritten. An unreachable duplicate return in
`rk_rga2_fill_format_info()` is gone.

## Refuted or downgraded during verification

- MPP compat ioctl, IRQ/probe/remove ordering, slice-FIFO terminal handling,
  hard-CCU publication barriers, timeout-generation machinery, the dma-buf
  import cache, and the RGA acquire-fence arming/abort protocol were each
  chased to ground and held (three slices returned NO FINDINGS on exactly the
  areas the July hardening touched).
- The RGA case table cross-checks 148/148 with no orphaned or duplicate
  tests; the MPP suite is a plain case table with no lifecycle hooks.

## Ledgered, not fixed

1. **ABC pattern-blend + rotate wire form.** The pattern path keeps its
   historical canvas-form model; faithful wire-swapped pat/dst inputs remain
   rejected, and the vendor's exact ABC-rotate semantics (including its
   `WIN0_ACT_OFF` fold, `rga3_reg_info.c:1566-1577`, which the rewrite does
   not reproduce for non-zero pattern origins) are unresolved. Stated in
   `ABI.rst`; needs a vendor-behavior study before code changes.
2. **Tautological KUnit goldens.** The RGA2 alpha-bitmap/OSD/quantize emit
   tests compute expectations by calling the same production helpers the
   emitter calls, so a wrong encoding passes both sides. The colorkey test's
   independent `FIELD_PREP` style is the model to convert them to.
3. **Assert-path leaks.** The fatal-before-cleanup-action debt (327 baseline
   signals) still describes real leak-on-failing-assert paths in both suites;
   they only fire on failing runs and stay ledgered.
4. **Stale acquire-fd close action** in the request-config acquire test:
   harmless today, recycles an fd number if the test ever opens another fd
   before cleanup.

## Validation state

Both trees compile their KUnit-enabled objects warning-free in-tree
(6.18 and v7.2-rc5 bases); the clean-archive `normal` gate for both trees and
the source audit (327 known signals, 0 new, 0 absent) pass on the new tips.
The rot90 fix is a **userspace-visible behavior change**: legacy 90°/270°
rotations that previously failed `-EINVAL` now execute. No booted-kernel run
yet — the 232-case boot with lockdep/kmemleak, plus GStreamer/FFmpeg rotation
conformance on hardware (which would have caught the rot90 rejection), remain
the next gates before ABI or media qualification.
