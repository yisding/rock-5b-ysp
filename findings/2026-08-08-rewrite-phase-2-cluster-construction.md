# Rewrite Phase 2 constructs a shadow CCU cluster without changing admission

> Scope: clean-room rewrite MPP topology ownership, Phase 2 checkpoint 2
> Source: `rk3588-rewrite-6.18@e854cacd64c21d043658e67a665bc779c95252f3`; `rk3588-rewrite-mainline@130fb983eeaf3d5d7557fea6835b408e6d2fe047`; `mpp_rewrite.c` cluster registry, membership, diagnostics, and KUnit coverage
> Date: 2026-08-08
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

The second Phase 2 checkpoint constructs a service-owned `rk_mpp_cluster` for
each explicit CCU identity without changing hardware selection or execution.
The fixed cluster registry retains OF-node identities, while each cluster owns
an unbounded member list, a borrowed coordinator pointer, member/core counts,
the learned core type, and one construction-time reset-domain relationship.
Per-member DMA-group and IOMMU relationships remain on `rk_mpp_hw`; debugfs
derives the number of distinct DMA groups while holding the existing service
topology lock instead of caching a second ownership view.

Probe attaches a hardware object only after reset-domain registration,
DMA-group registration, and existing core-ID/core-mask validation, immediately
before publishing it online. Remove retains membership through admission stop,
force-stop, reference drain, work/IRQ teardown, then detaches it before the DMA
group can be unregistered. The cluster stores borrowed hardware pointers and
takes no permanent hardware reference, avoiding a remove-time reference-cycle
deadlock. Module teardown releases retained cluster node references only after
the platform driver is unregistered.

The overlap rules preserve the existing drain/reprobe behavior. Membership is
not capped, because a valid replacement can coexist briefly with an old object
that has left the public hardware list but is still draining. A replacement
coordinator is rejected while the old coordinator is online or published; it
is accepted after both conditions clear, and later detaching the old object
does not overwrite the replacement.

Two heap-backed KUnit cases cover registry deduplication/capacity, core-first
and coordinator-first construction, reset/type mismatch, distinct DMA-group
counting, live duplicate refusal, draining coordinator replacement, old-member
detach, and stable empty-slot rebuilding. The exact manifest is now 98 MPP
plus 152 RGA cases.

## Source and build evidence

- The committed MPP source is byte-identical between the two trees, with
  SHA-256 `cd836b96dc28f30a4aeee3f06114c8e5721021c16867ed404fefcd08852b9be2`.
- Strict checkpatch reports zero errors, warnings, or checks over the 607-line
  commit diff in each tree; both kernel worktrees are clean.
- The source-pinned production ownership inventory reports 744 signals per
  tree with zero new or absent entries. Cluster-specific categories freeze 26
  binding accesses, seven lifecycle entries, 32 registry accesses, 23 state
  writes, four topology-owner entries, and 81 topology-input accesses.
- The existing KUnit fixture-debt inventory remains 306 signals per tree with
  zero new or absent entries.
- Warning-fatal KUnit-enabled MPP object builds passed from clean archived
  copies of both exact tips using the shared `~/Code/.ccache` store. The
  retained disposable directories are
  `~/Code/rock-5b/build/rewrite-phase2-cluster-wip/{src-6.18,6.18,src-mainline,mainline}`.

The complete eight-profile build matrix was last run for the immediately
preceding reset-domain checkpoint. This cluster checkpoint has focused object
compile evidence only: it has no current-tip test-disabled, KASAN, KCSAN, DTB,
package, boot, or runtime KUnit result.

## Boundary

This is a shadow construction checkpoint, not an admission or recovery
migration. Every current production CCU selection, online/readiness check,
core-mask aggregation, participant collection, power transition, abort, reset,
and recovery walk still uses the pre-existing service/hardware view. The new
cluster list is not traversed outside topology ownership and diagnostics.

The honest implemented claim is therefore **member topology plus one
construction-time reset authority and a derived DMA-relationship count**. The
cluster does not yet own group power, admission, IOMMU recovery, quarantine, or
an activation generation. Multiple/NULL per-member DMA groups remain valid,
and cluster identity must never be treated as proof that reset, DMA/IOMMU,
genpd, and CCU relationships are physically identical.

The hard-CCU force-stop path still uses the legacy participant set and physical
assert-all, one-delay, deassert-all sequence. Its next migration must validate
the already reference-pinned coordinator and targets through their cluster and
common reset-domain backpointers; it must not discover reset participants by
walking the mutable topology list under recovery locks.

The operator explicitly authorized source-only Phase 2 work without waiting
for installation or boot qualification. That changes sequencing, not the
evidence level.

## Verification gate

Before calling Phase 2 qualified, build and inspect an exact 6.18 package, boot
it with recovery retained, require all 250 KUnit cases and a fatal-free lockdep
interval, then repeat the same-session H.26x, dual-core reset-contention,
timeout/IOMMU-fault, suspend, unbind/rebind, solo RGA3 vpp, and overlay-chain
gates. The next source checkpoint may migrate the existing hard-CCU participant
pulse into one cluster-validated, non-interleavable reset transaction; group
power and admission migration remain later steps.
