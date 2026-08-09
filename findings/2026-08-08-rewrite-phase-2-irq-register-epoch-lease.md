# Rewrite Phase 2 leases hard IRQ status to the live register epoch

> Scope: clean-room rewrite MPP IRQ and register-lifetime ownership, Phase 2 checkpoint 6C
> Source: `rk3588-rewrite-6.18@ab9f6e2d2023fcf2ab07f63c91f65efffac72b76`; `rk3588-rewrite-mainline@5890133da0c46c0fab217f882503ed15e5cb709f`; `mpp_rewrite.c` register-lease publication, reset invalidation, and IRQ paths
> Date: 2026-08-08
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

The eighth Phase 2 source checkpoint gives every MPP START a bounded
IRQ-visible register lease. The lease records the current reset epoch and,
for directly owned core work, the active generation. It is published
immediately before the START doorbell and invalidated before a physical reset
or the final register-power release. Hard IRQ handlers may snapshot and
acknowledge status only while that lease is live; threaded handlers accept the
record only when its epoch and generation still match the current lease.

This closes the delayed-thread case in which old IRQ status could otherwise
claim a later activation after the hardware slot had been reused. A consumed
or absent record is rejected rather than inferred from a new active job.
Direct RKVENC/RKVDEC/AV1 work carries its nonzero activation generation. Hard
CCU physical members deliberately publish generation zero because the
coordinator chain, not an individual member slot, owns those descriptors; the
completed reset epoch still prevents pre-reset status from crossing the
recovery boundary.

The lease and IRQ record are owned by `hw->regs_lock`. AV1's main and AFBC IRQ
paths use the fixed `regs_lock -> aux_lock` order, and reset invalidation is the
one bounded raw-spinlock operation allowed beneath the reset-domain mutex so
hard IRQ loses register authority before the first reset write. Slow work,
including RKVENC slice FIFO publication and wakeups, now runs in the threaded
handler after the lease check rather than in hard-IRQ context.

`rk_mpp_irq_register_lease_kunit` covers a live generation, record
consumption, no-record rejection, reset-epoch invalidation, generation
mismatch, and the generation-zero hard-CCU form. It was compiled in every
KUnit-enabled profile but was not executed.

## Source and build evidence

- Both commits contain byte-identical MPP source with SHA-256
  `ac8fbf9aff5c61153f5283334693092401dde9a980a0621f440259f0041cf404`.
- The patch is 430 insertions and 88 deletions in each tree. Strict checkpatch
  reports zero errors, warnings, or checks over the 915-line patch; both
  maintained worktrees are clean.
- The source-pinned production audit reports 1186 signals per tree with zero
  new or absent entries. New categories freeze 37 register-lease helper
  entries, 46 field accesses, and 25 writes. The KUnit-debt audit remains 306
  signals per tree, and the exact manifest is 102 MPP plus 152 RGA cases.
- `rewrite-build-gate.sh all` passed warning-fatal `normal`, `test-disabled`,
  KASAN/fault-injection `memory`, and KCSAN/lockdep `race` profiles for both
  exact trees. Each profile built both rewrite drivers, both IOMMU providers,
  and the ROCK 5B DTB with the shared central ccache.
- Retained build logs live under
  `~/Code/rock-5b/build/rewrite-phase2-irq-lease-gate/`. Their SHA-256 values
  are:

  | Tree/profile | Build-log SHA-256 |
  |--------------|------------------|
  | 6.18 normal | `2a56c019bfce4f18c7a555095e21b97fd07c962239b68385650292f44ba142ad` |
  | 6.18 test-disabled | `758b034d19186f10dad5d04ca2e36b7cd4770c94c99367242e71b06510a13037` |
  | 6.18 memory | `0db346c78acff8a751cdbcd1f76d68c68e8d97053cc17fffc9e68e8779f071e7` |
  | 6.18 race | `6ae6dab3583bdee88478eadfee0de8464b5b2f1e1683ef5bda9f23c6e0a56a91` |
  | mainline normal | `ae7ae6734135ab296e61fe215f753b5af48eb4327a53c4334e7cd80905c756fd` |
  | mainline test-disabled | `7b8197adbc23a91d80f9bddf1a16b53d764503de14b676c76296c58366e29dc0` |
  | mainline memory | `693efdd75b919727a45ef5f54ff9111017110c5c222101e21e3c8d58ce8c1907` |
  | mainline race | `34957db878c0d4f07c67cf653fe9a72ca8ee0274d735cce6d881e67ea1c24233` |

## Boundary and next gate

No full kernel or package was built, and nothing was installed or booted.
Neither the new KUnit case nor any hardware workload ran. The build matrix
therefore proves source integration under the four configured compile
profiles, not IRQ timing, reset contention, decoder correctness, RGA behavior,
or silicon recovery.

The register lease is intentionally not a retained activation. It does not
arbitrate terminal reasons, retain a retiring snapshot, make retry allocate a
fresh attempt object, or change descriptor admission. Those belong to the
generation-tagged `rk_mpp_activation` migration rather than another wrapper
around the reusable job.

Before calling Phase 2 qualified, build and inspect an exact 6.18 package,
boot it with recovery retained, require all 254 KUnit cases and a fatal-free
lockdep interval, then repeat same-session H.26x, multi-job soft and hard CCU,
dual-core reset contention/recovery, timeout/IOMMU-fault, suspend,
unbind/rebind, solo RGA3 vpp, and overlay-chain gates.
