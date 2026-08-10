# Rewrite Phase 3 completes MPP activation retirement

> Scope: clean-room rewrite MPP activation ownership, final Phase 3 checkpoint
> Source: `rk3588-rewrite-6.18@77b60c9250ccccd8aa77c4b4426b7921e870a03d`; `rk3588-rewrite-mainline@0a645ea1df04225661e9611174abe3ca1451b07f`; `mpp_rewrite.c` activation resource, outcome, completion, retry, reclaim, and backend-dispatch paths
> Date: 2026-08-09
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Phase 3 is source-complete. `rk_mpp_activation` is now the structural owner of
one admitted hardware attempt from selection through terminal drain and
reclamation. The final checkpoint adds four connected pieces:

- `rk_mpp_activation_resources` owns the attempt's CCU, link-table, DCHS,
  cluster-power, and timing state. Hard-CCU retry transfers this whole record
  while the coordinator and selected-core locks exclude partial observation;
  the predecessor records `HANDED_OFF`, the successor `OWNED`.
- Each terminal reason records its result in an activation-local set. A stable
  priority selects the final result independently of reason arrival order.
- One successful completion path finalizes that result, drains activation
  resources, releases the exact selected-core and session-dispatch identities,
  publishes `DONE`, updates statistics, wakes userspace, and attempts reclaim.
  The former independent terminal tails no longer publish successful outcomes.
- A retired predecessor becomes `RECLAIMABLE` only when its resources are
  drained or handed off and it has no external activation reference, selected
  core, or dispatch identity. Reclaim takes the session lock before the
  scheduler lock, removes list/base ownership, and frees dynamically allocated
  retry storage. Embedded first-activation storage remains part of the job.

Quarantine is deliberately different: its activation and resource states stay
`QUARANTINED`, its typed references remain owned, and teardown/reuse stays
blocked rather than manufacturing a leak-free completion.

## Why the final refactor was large

This was a lifetime-boundary change, not a local cleanup. Before Phase 3, the
logical job was the convenient meeting point for resources and results even
though IRQ, timeout, IOMMU fault, close/abort, remove/shutdown, start failure,
hard-CCU retry, and quarantine could all end one hardware attempt. Moving the
owner therefore required changing every producer and every terminal consumer
together.

Three cross-cutting migrations account for most of the size:

1. CCU/link/DCHS/power/timing fields moved physically from the logical job into
   the activation. Every backend helper and KUnit fixture that touched those
   fields had to follow the new owner.
2. Final outcomes changed from first-tail publication to reason accumulation
   and priority arbitration. Every terminal path had to report a reason and
   converge on the same completion tail without changing quarantine behavior.
3. Early reclaim made previously harmless borrowed pointers dangerous. The
   scheduler and each backend start path now pin the selected hardware and
   revalidate the exact activation under its run lock before dereferencing
   backend operations; selected-core, dispatch, list, base, and external
   activation references must drain in a provable lock order.

The breadth is therefore evidence of the old concern being distributed across
all asynchronous exits. A smaller patch could have renamed the owner while
leaving lifetime decisions duplicated; it would not have completed Phase 3.

## Verification

- Final tips: 6.18 `77b60c9250ccccd8aa77c4b4426b7921e870a03d`;
  mainline `0a645ea1df04225661e9611174abe3ca1451b07f`.
- The tracked sources, Kconfig, ABI ledgers, and UAPI are byte-identical between
  the two branches. The MPP source SHA-256 is
  `33a0374b2009cb70a688cd02bfbc501b93fedb68a90d52db4ec654f82dc94f4e`.
- Strict checkpatch reports zero errors, warnings, or checks over the 3,253-line
  Phase 3 completion patch on each tree.
- The exact source manifest is 108 MPP plus 152 RGA cases, 260 total. New MPP
  coverage checks pairwise reason arbitration in both arrival orders,
  reclaimability, exact selected-core release, coherent retry resource
  handoff, and early predecessor reclaim.
- The production ownership audit passes at 2,314 signals per tree and the KUnit
  fixture-debt audit passes at 306 signals per tree. A hard completion contract
  rejects field-owner drift, arbitration-policy drift, incomplete resource
  drain/handoff, unsafe reclaim order, duplicate `DONE` publishers, and
  unpinned scheduler/backend dispatch.
- The focused final-source 6.18 KUnit-enabled MPP object is 6,886,200 bytes at
  SHA-256 `c88e58387dd0bd5eb109f441b31346f46cf32f206449639ba7dc6837aed70023`.
- All eight warning-fatal profiles pass: `normal`, `test-disabled`, `memory`
  (KASAN/fault injection), and `race` (KCSAN/lockdep) on both kernel lines,
  including both IOMMU providers, both rewrite objects, and the Rock 5B DTB.
- The dedicated test-disabled ABI gate passes on both heads: both rewrite KUnit
  options resolve disabled, the providers/rewrite objects/DTB compile, and the
  deliberate MPP ABI mutation fails at compile time.
- The repository handoff gate, `bash scripts/check-repo.sh`, passes with the
  completed audit policy, synthetic-fixture regression coverage, documentation,
  generated finding index, and tracked evidence state.

## Boundary and next gate

“Phase 3 complete” is a source-architecture statement. Neither tip has been
packaged or booted, so no current-tip runtime KUnit, lockdep, KASAN/KCSAN,
decoder, encoder, reset/recovery, RGA, AV1/VSI, performance, fuzz, or soak claim
follows from these results.

The next gate is to package, install, and boot the exact 6.18 tip; require the
full 108+152 KUnit manifest and a fatal-free live-lockdep interval; then exercise
reason-order races, hard-CCU resource handoff/reclaim, quarantine retention,
same-session H.26x, dual-core reset contention and recovery, solo RGA3 vpp, and
the overlay chain. Phase 4 remains the separate RGA task-execution ownership
refactor.
