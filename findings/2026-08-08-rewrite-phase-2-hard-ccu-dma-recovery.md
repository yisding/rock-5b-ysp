# Rewrite Phase 2 types hard-CCU DMA-group recovery

> Scope: clean-room rewrite MPP recovery ownership, Phase 2 checkpoint 6B
> Source: `rk3588-rewrite-6.18@43fca8a3d80cf3b0f506acb7ac5bc9e916582b2e`; `rk3588-rewrite-mainline@91bac563e4a5d120a1f6f20adcf75afaefa06d31`; `mpp_rewrite.c` hard-CCU force-stop, DMA refresh, resend, and recovery paths
> Date: 2026-08-08
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

The seventh Phase 2 source checkpoint extends
`rk_mpp_cluster_recovery_result` across hard-CCU group reset. The physical
pulse still uses the existing reference-pinned coordinator and member-core
participants and preserves their reset order. After a successful reset, the
driver now constructs a bounded, deduplicated view of those participants' DMA
groups, validates each live group/domain relationship, and refreshes every
distinct group exactly once before setting `reusable`.

The typed result records how many DMA groups were affected, refreshed, or
terminally isolated. Topology mismatch, reset failure, or any failed refresh
keeps `reusable` false and enters the existing terminal-isolation cleanup. A
successful isolation can prove safe retirement but never re-admission. Both
hard-CCU resend sites now require the group result to be reusable as well as
each selected core's result, so reset success alone no longer authorizes
descriptor restart against stale translations.

The raw VSI/generic IOMMU refresh remains in one internal leaf. Group refresh
serializes against terminal domain attachment with the existing DMA-group
lock, while the coordinator recovery and run locks keep the participant set
stable. The checkpoint does not change descriptor admission, select new reset
participants, or infer recovery scope by walking the unpinned cluster member
list.

`rk_mpp_cluster_dma_recovery_kunit` covers two cores sharing one DMA group plus
a third core in another group. Its success arm requires two refreshes, and its
failure arm proves that an isolated second group bars reuse and attributes the
failed participant. The test was compiled into both focused MPP objects but
was not executed.

## Source and build evidence

- Both maintained commits contain byte-identical MPP source with SHA-256
  `2eccc3e905e45ad1cdb212c655fc5a34910fb797d05391ffc901fd2876fb152c`.
- Strict checkpatch reports zero errors, warnings, or checks over the 693-line
  patch in both trees; both maintained worktrees are clean.
- Warning-fatal KUnit-enabled MPP object builds pass from clean archives for
  both exact sources, using the shared ccache store. Outputs are retained under
  `~/Code/rock-5b/build/rewrite-phase2-recovery/`.
- `kernel-drivers/tests/rewrite-build-gate.sh audit` reports 1086 production
  ownership signals per tree with zero new or absent entries. The inventory
  includes 45 recovery entries, 53 recovery-result accesses, 41 result writes,
  five semantic IOMMU transitions, five raw IOMMU backend operations, and 40
  terminal entries.
- The KUnit-debt audit remains 306 signals per tree with zero new or absent
  entries. The exact ordered manifest is 101 MPP plus 152 RGA cases.

No KUnit case was executed and no full kernel, package, boot, or hardware test
was performed.

## Boundary and next gate

This checkpoint closes the typed hard-CCU reset/DMA result but does not make
the result a retained activation identity. Descriptor admission is unchanged,
and hard IRQ still lacks an IRQ-safe reset/register lease tied to the completed
reset epoch. Terminal reason arbitration must not be layered onto the reusable
job object before a generation-tagged activation exists.

The next source checkpoint is Phase 2 item 6: publish and check the bounded
IRQ-safe reset/register epoch lease so hard IRQ acknowledges only a live
generation and leaves reset-dependent work to the thread. Keep that change
separate from Phase 3 activation lifetime and terminal-reason merging.

Runtime qualification remains deferred under the operator's explicit
source-only override. Before calling Phase 2 qualified, build and inspect an
exact 6.18 package, boot it with recovery retained, require all 253 KUnit cases
and a fatal-free lockdep interval, then repeat same-session H.26x, multi-job
soft and hard CCU, dual-core reset contention/recovery, timeout/IOMMU-fault,
suspend, unbind/rebind, solo RGA3 vpp, and overlay-chain gates.
