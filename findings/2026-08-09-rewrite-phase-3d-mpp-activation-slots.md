# Rewrite Phase 3D stores MPP slots by activation identity

> Scope: clean-room rewrite MPP activation ownership, Phase 3D checkpoint
> Source: `rk3588-rewrite-6.18@e3a24baa7ee7c1a182b2ebb78669ca4e714f3880`; `rk3588-rewrite-mainline@738f910e645b62ef6ac1fd7c07fc4997598c2937`; `mpp_rewrite.c` active/watchdog slots and adapters
> Date: 2026-08-09
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Phase 3D replaces the hardware's retained `active_job` and `timeout_job`
pointers with exact embedded-activation identities:

```c
struct rk_mpp_activation *active_activation;
struct rk_mpp_activation *timeout_activation;
```

This is a representation and reference-owner checkpoint. Existing IRQ,
timeout, fault, abort, remove, and hard-CCU paths remain job-shaped through
small activation-to-parent adapters. No terminal winner, result precedence,
MMIO order, recovery decision, or cleanup order changes.

## Reference and lock contract

Each non-NULL slot still owns one reference to `activation->job`. When both
slots name the same embedded activation there are two independent containing-
job references:

- active install gets the job before publication;
- active take transfers that exact reference to the winner;
- reset-failure restore transfers it back without another get or put;
- timeout publication gets the new target before replacing the pointer and
  drops the old target after releasing `hw->lock`;
- timeout take transfers its independent reference to cancel or workqueue
  processing; and
- stale timeout, IRQ, and IOMMU-fault paths still reject a mismatched saved
  generation before claiming the active slot.

The two slots, activation generation/deadline, timeout/fault cookies, and IRQ
record remain protected by `hw->lock`. IRQ ordering remains
`regs_lock -> hw->lock`; process-context start and terminal work remain under
`run_lock`; hard-CCU recovery retains its coordinator recovery-lock ordering.

`timeout_generation` deliberately remains separate. Hard-CCU retry still
rewrites generation and deadline in the same embedded activation address, so
pointer equality alone cannot distinguish an old watchdog from the replacement
attempt. This checkpoint does not introduce a separately allocated or retained
activation.

## Mechanical guard

The production source audit now hard-enforces:

- exact unique activation parent, generation, deadline, validity,
  active-slot, timeout-slot, allocator, and timeout-cookie schemas;
- no member named `active_job` or `timeout_job` in `rk_mpp_hw`, regardless of
  type, array suffix, or attribute;
- raw active-slot writes only in install/take/restore and raw timeout-slot plus
  cookie writes only in timeout schedule/take;
- field-specific activation writer sets for parent, generation, deadline, and
  selected hardware; and
- whole-object, publisher, and memory writes through embedded objects, typed
  pointer aliases, pointer-const declarations, typedefs, explicit casts,
  parenthesized/indexed dereferences, and slot pointees cannot be blessed with
  `--update-baseline`.

The checked inventory is 1,451 signals per tree with zero new or absent
entries. It includes eight active-slot accesses/three writes, five timeout-slot
accesses/two writes, three allocator accesses/two writes, three timeout-cookie
accesses/two writes, 99 aggregate activation accesses, and 13 aggregate
activation writes. The KUnit-debt inventory remains 306 signals.

## Focused tests

Existing cases were adapted without changing the manifest. They continue to
cover active install/take/restore, generation wrap, exact IRQ lease, IOMMU-fault
generation matching, timeout replacement/cancel/re-arm and reference balance,
hard-CCU retry with the same activation address and a new generation,
coordinator-dependent abort, scheduler busy-slot behavior, hard-fault owner
selection, and reset-session active import cleanup.

The exact manifest remains 102 MPP plus 152 RGA cases. The source-audit host
tests additionally isolate each alias, memory-writer, schema, slot-pointee, and
legacy-name bypass and require a hard failure in both ordinary and baseline-
update modes.

## Verification

- Both commits contain byte-identical MPP source.
- Strict patch checkpatch reports zero errors, warnings, or checks on both
  849-line patches.
- Production ownership audit: 1,451 signals per tree, zero new/absent.
- KUnit source-debt audit: 306 signals per tree, zero new/absent.
- Exact manifest: 102 MPP plus 152 RGA.
- Warning-fatal clean-archive builds cover `normal`, `test-disabled`,
  KASAN/fault-injection `memory`, and KCSAN/lockdep `race` on both trees.
- Repository consistency, source-audit unit tests, shell checks, links, and
  whitespace pass through `bash scripts/check-repo.sh`.

These are source and compile results. No Phase 2 or Phase 3 kernel has been
packaged, installed, booted, or exercised by runtime KUnit/hardware tests.

## Boundary and next gate

The activation is still embedded current storage and hard-CCU retry still
overwrites it in place. The hardware slots no longer carry job pointers, but
their terminal callers immediately recover the parent job and independently
choose completion/recovery outcomes. There is no `RUNNING -> RETIRING ->
RECLAIMABLE` transition owner, retained predecessor, reason merge, tombstone,
or terminal arbitration.

CCU/link/descriptor state, coordinator and member-power leases, DCHS ownership,
and async reason snapshots also remain outside the activation. The next source
checkpoint must retain and close one retiring generation before merging
terminal reasons; it must not remove `timeout_generation` while retry reuses an
address.

Runtime qualification still requires an exact Phase 3D package/boot, all 254
KUnit cases with a fatal-free lockdep interval, same-session H.26x replay,
reset-contention/recovery, solo RGA3 vpp, and the overlay chain.
