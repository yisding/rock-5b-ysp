# RKVENC DCHS producer retirement raced a dependent consumer's START; lifecycle serialization applied

> Scope: MPP rewrite driver, RKVENC2 dual-core DCHS path
> Source: `linux-6.18-rkvenc@600d6e2fb6a49` and `linux@451634b8c5a22`; `mpp_rewrite.c` `rk_mpp_rkvenc2_dchs_patch()`, `rk_mpp_rkvenc2_submit()`, `rk_mpp_rkvenc2_thread()`, and common abort/recovery
> Date: 2026-07-30
> Trust: SOURCE-INSPECTED + SOURCE-CONFIRMED + COMPILE-VERIFIED + FIX-COMPILE-VERIFIED + INFERRED + PARTIAL

## Result

The rewrite had a cross-core DCHS lifetime race analogous to the decoder
soft-CCU power/registration bug. A consumer copied a live producer's remapped
TX id under `service.rkvenc_dchs_lock`, released that spinlock, and only then
programmed its registers and rang START. The producer's threaded completion
could concurrently power its core off and clear its DCHS table entry. This
allowed the consumer to start with RXE referring to a producer that software
had already retired.

The software ordering defect is source-confirmed. Its hardware consequence is
still inferred: no public VEPU580 description checked here establishes whether
the producer's TX event remains latched after producer clocks gate. The unsafe
ordering could therefore manifest as a consumer watchdog/timeout, but no board
failure has yet been attributed to it.

The vendor driver does not permit this sequence. Both RKVENC cores share one
`mpp_taskqueue` kthread worker. Producer completion clears DCHS in
`rkvenc2_update_dchs()` before `mpp_task_finish()` powers the core off, while a
consumer's patch-through-START sequence runs on that same worker. If completion
wins, the later consumer sees no producer and drops RXE; if submission wins,
the consumer reaches START before software can retire the producer.

## Fix

The 6.18 and mainline rewrite worktrees now carry the same source patch:

- `service.rkvenc_dchs_lifecycle_lock` is a sleepable cluster-wide mutex with
  lock order `core run_lock -> DCHS lifecycle mutex -> DCHS table spinlock`;
- RKVENC submit holds it continuously from DCHS patching through the START
  doorbell;
- normal threaded completion, timeout/IOMMU recovery, active abort, and
  per-job abort hold it across producer reset, power-off, and DCHS release;
- DCHS patch/release assert that the lifecycle mutex is held, and the existing
  DCHS KUnit cases now exercise those helpers under the new contract; and
- per-job abort clears DCHS only after a successful stop, so a failed stop that
  restores the active job no longer republishes hardware with its software
  DCHS ownership already discarded.

This closes both valid orderings:

1. consumer owns the mutex → consumer STARTs → producer retires; or
2. producer owns the mutex → producer retires and clears its entry → consumer
   patches without RXE.

The existing IRQ-safe spinlock remains the narrow ownership-table guard. The
new mutex owns the larger hardware lifecycle interval and is never taken from
the hard IRQ handler.

## Verification

Both focused translation-unit builds completed with exit status 0:

```text
PATH=/usr/sbin:/usr/bin:/sbin:/bin make -j4 \
  drivers/video/rockchip/mpp-rewrite/mpp_rewrite.o
```

- 6.18 used its KUnit-enabled rewrite configuration, compiling the updated
  DCHS cases. It retained the pre-existing
  `rk_mpp_rkvdec2_soft_ccu_program_kunit` frame-size warning.
- mainline used its existing in-tree configuration and compiled the production
  driver paths. A fresh `O=` directory was deliberately not forced after
  Kbuild rejected the source tree's pre-existing in-tree generated files.
- `git diff --check` passed in both source trees, and both changes have the
  same 105 insertions / 12 deletions.

## Remaining audit finding

The hard-CCU IOMMU fault callback remains a lower-confidence clock-lifetime
gap. `rk_mpp_iommu_fault_handler()` runs from the Rockchip IOMMU hard IRQ and
reads the source decoder's link descriptor register without a guard shared
with the last chain job's group-core power release. Ordinary faults occur while
the chain holds all core power references, but a late/in-flight provider
callback can still race final completion or abort. This is source-inspected,
not reproduced. The next source fix should use an explicit clock-live/MMIO
guard like RGA's `regs_live_count`, followed by a fault-versus-final-completion
hardware discriminator.

The same audit cleared the closest lookalikes: decoder hard-CCU power ownership
transfers with its chain, the repaired soft-CCU path holds every coordinator
core, RGA gates shared-IRQ MMIO on `regs_live_count`, AV1 quiesces and
synchronizes its shared AFBC IRQ before clocks gate, and the main MPP IRQs are
dedicated `IRQF_ONESHOT`.

The ordinary-spinlock hard-IRQ `CONFIG_PROVE_RAW_LOCK_NESTING` report is a
separate PREEMPT_RT/debug-checker boundary already recorded in
[`2026-07-30-rewrite-soft-ccu-split-critical-section-h265-wedge.md`](2026-07-30-rewrite-soft-ccu-split-critical-section-h265-wedge.md).

## Boundary and next gate

No kernel containing this fix has booted, and no encoder workload has exercised
it. The smallest hardware gate is a same-session dual-core RKVENC run that
forces producer completion into the interval after consumer DCHS matching and
before consumer START, then checks:

- both jobs complete without watchdog/reset;
- the consumer retains RXE only when it started before producer retirement;
- all DCHS slots return to idle after completion, timeout, reset, close, and
  remove; and
- the next encode succeeds with clean kernel logs.

Until that gate passes, the fix is compile-verified rather than runtime-verified.
