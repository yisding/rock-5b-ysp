# Rewrite Phase 2 replaces the hard-CCU powered-core array with a cluster lease

> Scope: clean-room rewrite MPP shared-power ownership, Phase 2 checkpoint 4
> Source: `rk3588-rewrite-6.18@129a49a2bec9670619d7adf3ea08a1cb654462f6`; `rk3588-rewrite-mainline@f03e5cd9f44d32b50edf68ec3d33ee5b533d6372`; `mpp_rewrite.c` RKVDEC CCU core-power lifetime
> Date: 2026-08-08
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

The fourth Phase 2 checkpoint removes the fixed
`job->rkvdec_ccu_powered_cores[]` array and count. A refcounted
`rk_mpp_cluster_power_lease` now records the validated cluster, the exact
member-core set, and the hardware references whose runtime-PM/clock holds must
survive for the shared RKVDEC CCU chain.

The physical and ownership sequence is unchanged:

1. the existing service-list selection retains each eligible core reference;
2. the lease validates that the coordinator, submitting core, and every
   selected member share the constructed cluster;
3. member power references are acquired in the existing order;
4. the first chain job owns the lease;
5. when that job leaves a nonempty coordinator list, the same lease reference
   moves to the next listed job without cycling any hardware power; and
6. the last owner releases member power before the corresponding hardware
   reference, in the existing order.

The lease publishes to a job only after every selected core powers on. An
allocation, topology, or power failure unwinds the exact retained references
without leaving a partially published lease. Final release atomically claims
the job pointer, so repeated cleanup cannot retire the same lease twice.

The coordinator power hold deliberately remains separate and per-job. Every
descriptor publisher continues to own and release its own coordinator
runtime-PM reference; the new lease covers only the member-core holds that
must follow the shared chain. Descriptor admission, coordinator job/list
ownership, reset/IOMMU recovery, quarantine, and active-generation semantics
are unchanged.

The two existing CCU power-transfer KUnit cases now construct heap-backed
leases and prove identity-preserving handoff, a stable refcount, refusal to
replace a destination that already owns a lease, unchanged member hardware and
power reference counts, and the common link-release transfer path. The exact
manifest remains 99 MPP plus 152 RGA cases.

## Source and build evidence

- The committed MPP source is byte-identical between the two trees, with
  SHA-256 `360b1f408bdc72e4d222c038a792b0bb1d77c7be95709ac5bd1193d9fcdd1a37`.
- Strict checkpatch reports zero errors, warnings, or checks over the 492-line
  commit patch in each tree; both worktrees are clean.
- The source-pinned production ownership inventory reports 821 signals per
  tree with zero new or absent entries. The new lease categories contain 13
  typed entry calls and 27 lease-field accesses; the broader power-field
  inventory contains 31 signals.
- The KUnit fixture-debt inventory remains 306 signals per tree with zero new
  or absent entries, and the exact manifest remains 99/152.
- Warning-fatal KUnit-enabled MPP object builds pass for both exact sources
  with `CONFIG_FRAME_WARN=2048`, using the shared `~/Code/.ccache` store and
  disposable `~/Code/rock-5b/build/rewrite-phase2-cluster-wip/` archives.

This checkpoint has focused object compile evidence only. The complete
eight-profile build matrix was last run for the reset-domain checkpoint; no
current-tip package, boot, runtime KUnit, or hardware result exists.

## Boundary

The lease is a cluster-validated resource object but remains temporarily
attached to one legacy job at a time because the driver still lacks the
generation-tagged activation object that will own all runtime resources. It
does not make the cluster the descriptor admission or coordinator job-list
authority, and it does not merge the separate reset-domain and DMA-group
effects.

The allocation performed on first chain acquisition is a new fail-closed
`-ENOMEM` point. It occurs under the existing sleepable admission locks and
before publication or a hardware START. The operator explicitly authorized
source-only Phase 2 work without waiting for installation or boot
qualification; that changes sequencing, not evidence strength.

## Verification gate

Before calling Phase 2 qualified, build and inspect an exact 6.18 package,
boot it with recovery retained, require all 251 KUnit cases and a fatal-free
lockdep interval, then repeat same-session H.26x, multi-job soft and hard CCU,
dual-core reset contention/recovery, timeout/IOMMU-fault, suspend,
unbind/rebind, solo RGA3 vpp, and overlay-chain gates.

The next source checkpoint may move CCU arm/start and coordinator job/list
ownership behind cluster methods while preserving the current lock and MMIO
order. It must not combine that mechanical funnel with the later typed
reset/IOMMU recovery result, admission quarantine, or activation migration.
