# Rewrite Phase 2 makes the hard-CCU pulse one cluster-validated reset epoch

> Scope: clean-room rewrite MPP reset ownership, Phase 2 checkpoint 3
> Source: `rk3588-rewrite-6.18@e41bdb50a9ab76c81de55df734ee96c78923c632`; `rk3588-rewrite-mainline@1c91ffc853f7aa80fbbfc63d1b7d2b1942449cba`; `mpp_rewrite.c` hard-CCU force-stop reset transaction
> Date: 2026-08-08
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

The third Phase 2 checkpoint moves the hard-RKVDEC-CCU physical reset pulse
behind one cluster-validated reset-domain transaction. It deliberately retains
the existing job/power-derived participant collection, hardware references,
core-work/covered-mask checks, IRQ quiescence, coordinator WORK/CORE polling,
and terminal-isolation policy. The cluster does not discover or broaden the
participant set.

Before the first reset write, the domain owner validates that the current
coordinator and every already-pinned core have the expected cluster backpointer
and one common reset-domain membership. A mismatch returns `-EXDEV`, increments
the domain refusal count, leaves the epoch unchanged, and touches no reset
control. An admitted transaction increments one nonzero epoch and one pulse
count, then performs the preserved physical order:

1. assert each selected core in the retained order;
2. assert the coordinator;
3. wait one 10 microsecond pulse;
4. deassert each successfully asserted core in the same order; and
5. deassert the successfully asserted coordinator.

The reset-domain mutex spans only membership/state checks, reset backend calls,
and the bounded pulse. It is still the innermost sleepable leaf: failure
publication, logging, IOMMU isolation, PM, and every other lock stay outside.
Consequently, a single-target power deassert on any member cannot land inside
the hard-CCU pulse. The existing coordinator `ccu_recovery_lock` remains the
logical hard-chain transition lock.

Failure callbacks now run after the complete physical group pulse and after the
domain mutex is released. This is the intentional narrow ordering change needed
to keep callbacks that take service locks out of the reset leaf; reset-line
order, per-line results, terminal poisoning, isolation, and the unusual
successful-isolation return contract remain unchanged.

The reset backend now has a private injectable dispatch. One heap-backed KUnit
case proves the exact six-line success trace for two cores plus coordinator,
one epoch per pulse, balanced pulse flags, continued coordinator handling after
a core-assert failure, selective deassert of successful lines, and rejection of
a mismatched member before any backend call. The exact manifest is now 99 MPP
plus 152 RGA cases.

## Source and build evidence

- The committed MPP source is byte-identical between the two trees, with
  SHA-256 `bb4ec4529fa169c7b4defefce288b8eec163d184c5b7b2146e5d9ca1e127f618`.
- Strict checkpatch reports zero errors, warnings, or checks over the 758-line
  commit diff in each tree; both worktrees are clean.
- The source-pinned production ownership inventory reports 766 signals per
  tree with zero new or absent entries. It includes three cluster-reset owner
  entries, three reset-backend accesses, 15 reset-domain operation entries,
  two raw reset-control backend calls, and the existing topology/state seams.
- The KUnit fixture-debt inventory remains 306 signals per tree with zero new
  or absent entries.
- Warning-fatal KUnit-enabled MPP object builds pass for both exact sources with
  `CONFIG_FRAME_WARN=2048`, using the shared `~/Code/.ccache` store and the
  disposable `~/Code/rock-5b/build/rewrite-phase2-cluster-wip/` archives.

This checkpoint has focused object compile evidence only. The complete
eight-profile build matrix was last run for the reset-domain checkpoint; no
current-tip test-disabled, KASAN, KCSAN, DTB, package, boot, or runtime KUnit
result exists.

## Boundary

The cluster now owns topology validation for the hard-CCU reset pulse, but it
does not own group power, descriptor admission, link/job-list lifetime, IOMMU
refresh/isolation policy, quarantine, or an activation generation. Existing
selection and readiness list walks remain unchanged. The job still carries the
coordinator and powered-core array, so group-power ownership is the next
altitude mismatch.

The reset epoch is diagnostic transaction state only. IRQ, restart, and
re-admission do not consume a reset effect/epoch result yet, and terminal
quarantine remains the later recovery-result checkpoint. The operator explicitly
authorized source-only Phase 2 work without waiting for installation or boot
qualification; that changes sequencing, not evidence strength.

## Verification gate

Before calling Phase 2 qualified, build and inspect an exact 6.18 package, boot
it with recovery retained, require all 251 KUnit cases and a fatal-free lockdep
interval, then repeat same-session H.26x, dual-core reset contention/recovery,
timeout/IOMMU-fault, suspend, unbind/rebind, solo RGA3 vpp, and overlay-chain
gates. The next source checkpoint may replace the job-owned hard-CCU powered
core array/flag with one cluster power lease, but must not fold admission or the
full reset/IOMMU recovery result into that mechanical ownership migration.
