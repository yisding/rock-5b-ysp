# Rewrite Phase 2 makes the cluster the CCU list and publication owner

> Scope: clean-room rewrite MPP coordinator ownership, Phase 2 checkpoint 5
> Source: `rk3588-rewrite-6.18@805a216a1e8d14e67efdc17621d840ad0b28ce92`; `rk3588-rewrite-mainline@4cb7913f8466918c6202d5caffff2406270ec381`; `mpp_rewrite.c` RKVDEC CCU running-list, chain-link, arm, and START paths
> Date: 2026-08-08
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

The fifth Phase 2 checkpoint makes the constructed `rk_mpp_cluster` the typed
owner for coordinator runtime work that previously operated directly on an
`rk_mpp_hw`:

- coordinator and member-core relationships are validated before publication;
- every running-list add/remove, done scan, unfinished-job snapshot, resend
  relink, and reset-participant collection runs through a cluster method;
- the soft-CCU arm and `CORE_STA`/core-`START` publication run through cluster
  methods; and
- the hard-CCU start method validates the topology before power acquisition,
  coordinator setup, list publication, watchdog stamping, or `CFG_DONE`.

The physical sequences and locks are unchanged. Hard publication remains
running-list add, timeout-generation stamp, `rkvdec_ccu_started = true`,
`wmb()`, then `CFG_DONE`, while holding the core and coordinator run locks and
the existing coordinator recovery lock. Soft publication retains one
continuous coordinator run-lock interval across link/coordinator arm, cache
setup, IOTLB flush, task registers, `CORE_STA`, timeout-generation stamp,
`wmb()`, and core `START`.

Removal remains fail-safe. A topology mismatch warns, but an already-published
node is still removed and the remaining chain is relinked so cleanup cannot
strand a descriptor or cycle member power early. New publication instead
fails with `-EXDEV` before it mutates the list or rings a doorbell. The focused
running-list KUnit case proves that refusal and then exercises the normal
two-job add, relink, done-scan, remove, and empty-list sequence.

This is an ownership funnel, not a new scheduler or admission policy. Existing
service-list CCU selection, hard-DMA readiness, add-mode choice, member-power
selection, reset result handling, IOMMU recovery, terminal isolation, and
active-generation behavior are unchanged.

## Source and build evidence

- The committed MPP source is byte-identical between the two trees, with
  SHA-256 `aa255df003307d8068b58b21ca1a6b0f4b7096e2fad8618afdeed26d7614504a`.
- Strict checkpatch reports zero errors, warnings, or checks over the 769-line
  commit patch in each tree; both maintained worktrees are clean.
- The source-pinned production inventory reports 919 signals per tree with
  zero new or absent entries. New focused categories contain 34 cluster
  runtime entries, 6 publication entries, 21 running-list accesses, 4 chain
  link writes, and 18 coordinator-control writes.
- The KUnit fixture-debt inventory remains 306 signals per tree with zero new
  or absent entries, and the exact manifest remains 99 MPP plus 152 RGA cases.
- Warning-fatal KUnit-enabled MPP object builds pass for both exact sources
  with `CONFIG_FRAME_WARN=2048`, using the shared `~/Code/.ccache` store and
  disposable `~/Code/rock-5b/build/rewrite-phase2-cluster-owner/` output.

This checkpoint has focused object compile evidence only. The complete
eight-profile build matrix was last run for the reset-domain checkpoint; no
current-tip package, boot, runtime KUnit, or hardware result exists.

## Boundary and next gate

The cluster now owns coordinator list and publication mechanics, but it does
not yet return a typed recovery result or decide whether reset effects plus
DMA refresh/isolation permit re-admission. The power lease and coordinator
power reference also remain attached to legacy jobs until a generation-tagged
activation object exists.

The next source checkpoint may introduce the typed cluster recovery result and
require its reset and DMA effects before re-admission. It must preserve current
failure precedence and terminal-isolation behavior, and it must not combine
that change with IRQ epoch migration, activation lifetime, or RGA task-exec
work.

Before calling Phase 2 qualified, build and inspect an exact 6.18 package,
boot it with recovery retained, require all 251 KUnit cases and a fatal-free
lockdep interval, then repeat same-session H.26x, multi-job soft and hard CCU,
dual-core reset contention/recovery, timeout/IOMMU-fault, suspend,
unbind/rebind, solo RGA3 vpp, and overlay-chain gates.
