# Rewrite Phase 2 types single-core reset and DMA recovery

> Scope: clean-room rewrite MPP recovery ownership, Phase 2 checkpoint 6A
> Source: `rk3588-rewrite-6.18@e99b3da2f3318d1396527bf74b4e229158845ce6`; `rk3588-rewrite-mainline@63bbb63bec44d36616512f4cdcceb5b2c25c1bcf`; `mpp_rewrite.c` single-core reset, soft-CCU, timeout, abort, IRQ-error, AV1, and IOMMU-fault paths
> Date: 2026-08-08
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

The sixth Phase 2 source checkpoint introduces
`rk_mpp_cluster_recovery_result` and separates two facts that the old integer
return conflated:

- `quiesced` means the current activation can be retired safely; and
- `reusable` means a later activation may be admitted on that hardware.

A successful reset records `RK_MPP_RESET_TRANSLATIONS_LOST` and the exact
reset-domain epoch. The shared completion leaf then refreshes VSI or flushes
the IOTLB before setting `reusable`. A refresh failure publishes recovery
failure, attempts permanent DMA-group isolation, and leaves `reusable` false.
A successful physical reset still permits retirement even if that final
isolation attempt fails, because the reset already stopped current DMA; the
failed hardware remains barred from admission.

Terminal isolation remains a successful retirement proof but now reports
`RK_MPP_RESET_TERMINALLY_ISOLATED` with `reusable == false`. This matters for
soft CCU: the driver no longer writes `CORE_ERR`/`CORE_IDLE` to reconnect a
core after terminal isolation. It reconnects only after reset and translation
recovery both succeed.

All single-core stop callers now use the typed path: explicit abort, dependent
abort, timeout, IOMMU fault, encoder/decoder/AV1 IRQ error, AV1 start unwind,
hard-CCU done draining, and hard-CCU retry preparation. The idle IOMMU-fault
case also uses the same completion leaf, and retry/resend proceeds only when
the result says the core is reusable. Production raw translation refresh is
therefore confined to that one internal completion leaf.

The focused KUnit case proves the two key outcomes: reset epoch 1 plus
translation-ready reuse, and terminal retirement without reuse. The existing
soft-CCU case now proves the terminal path leaves the reconnect error register
untouched.

## Source and build evidence

- Both maintained commits contain byte-identical MPP source with SHA-256
  `a8091b12b329a1a93b6ed07f8858e8c3701b31191f89dac9fe9cfa8b208317eb`.
- Strict checkpatch reports zero errors, warnings, or checks over the 588-line
  patch in both trees; both maintained worktrees are clean.
- Warning-fatal KUnit-enabled MPP object builds pass from clean archives for
  both exact sources with `CONFIG_FRAME_WARN=2048` and the shared ccache store.
  Outputs are retained under
  `~/Code/rock-5b/build/rewrite-phase2-recovery/`.
- The source-pinned production inventory reports 992 signals per tree with
  zero new or absent entries. It includes 27 recovery entries, 25 result-field
  accesses, and 16 result-field writes. The KUnit-debt audit remains 306
  signals, and the exact manifest is 100 MPP plus 152 RGA cases.

No KUnit case was executed and no full kernel, package, boot, or hardware test
was performed.

## Boundary and next gate

This checkpoint deliberately does not convert
`rk_mpp_rkvdec2_force_stop_ccu()`. That path resets a reference-pinned set of
member cores plus the coordinator under one recovery lock and one reset epoch;
it needs a multi-member DMA-group result rather than repeated single-core
refresh calls. Until that follow-up lands, hard-CCU group reset can still
return quiesced without itself recording whether every affected translation
domain is reusable or terminally isolated.

The next source checkpoint should extend the typed result across hard-CCU
group reset, deduplicate the pinned participants' DMA groups, and prevent
resend/admission unless every affected group is refreshed or terminally
isolated. IRQ-safe reset/register leases, activation lifetime, and terminal
reason arbitration remain later and separate.

Runtime qualification remains deferred under the operator's explicit
source-only override. Before calling Phase 2 qualified, build and inspect an
exact 6.18 package, boot it with recovery retained, require all 252 KUnit cases
and a fatal-free lockdep interval, then repeat same-session H.26x, multi-job
soft and hard CCU, dual-core reset contention/recovery, timeout/IOMMU-fault,
suspend, unbind/rebind, solo RGA3 vpp, and overlay-chain gates.
