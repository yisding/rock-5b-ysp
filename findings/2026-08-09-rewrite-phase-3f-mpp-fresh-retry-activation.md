# Rewrite Phase 3F retains fresh MPP hard-CCU retry activations

> Scope: clean-room rewrite MPP activation ownership, Phase 3F retry-storage checkpoint
> Source: `rk3588-rewrite-6.18@3e6d682519a02`; `rk3588-rewrite-mainline@e72aaf3244fbf`; `mpp_rewrite.c` activation storage and hard-CCU retry paths
> Date: 2026-08-09
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Phase 3F stops reusing the first embedded activation record when hard-CCU work
is retried. Each job starts with one embedded record and owns a list of all its
activation storage. Every committed retry allocates and links a distinct
successor, freezes the predecessor as `SUPERSEDED/RETRY_REPLACED`, and retains
both records until final job release.

The retry publication transaction runs under the existing coordinator
recovery and core run locks, then takes `session->lock`, `srv->sched_lock`, and
`hw->lock` in the already established order. It atomically changes the current
activation, exact session-dispatch owner, and hardware active slot from the old
record to the successor. There is no empty active-slot or dispatch interval,
and the active slot's existing containing-job reference transfers without a
get/put pair.

This closes the same-address retry ABA. A timeout worker that already took the
old activation keeps its independent containing-job reference, so the old
address remains valid; its pointer/generation claim cannot detach the fresh
successor. `timeout_generation` remains present as a defensive saved cookie.

## Storage and selected-hardware ownership

The job has one `activation_storage`, one `current_activation`, and one list of
all retained attempts. The embedded first record and every dynamic successor
have an immutable parent-job pointer and their own selected-hardware reference.
Successful successor publication acquires exactly one additional hardware
reference. Completion or final destruction walks all retained records, clears
each selected-hardware pointer under the session lock, and performs one put for
each cleared reference.

Only unpublished successor storage may be freed early. Published successors
remain linked until final job release, while release fails closed if dispatch,
hardware, current-storage, or activation-state invariants say any retained
record is still live. Job-shaped callers use `current_activation`; exact
terminal restore paths retain the claimed activation so a superseded record
cannot be republished.

## Preserved behavior

The checkpoint preserves the Phase 3E retry timing and result policy:

- retry publication still occurs before timeout cancel and per-core
  stop/recovery;
- already recorded IRQ and IOMMU-fault snapshots are cleared by successful
  retry publication, while a provider fault arriving afterward is attributed
  to the successor generation;
- a stop/recovery failure after publication leaves the fresh successor current
  for the existing group force-stop and abort fallback;
- partial multi-job preparation frees only successors that were never
  published; and
- session abort still publishes `DONE/-ECANCELED` before hardware retirement.

`SUPERSEDED` therefore means logically replaced and retained. It does not prove
that the predecessor's hardware is quiesced, make the record `RETIRED` or
`RECLAIMABLE`, rank competing terminal reasons, or transfer resources into a
quarantine/tombstone owner.

## Mechanical guard

The source audit hard-requires the exact job/activation storage schemas,
current-pointer and list/link access/write owners, allocation/free owners,
state/reason enums, field-specific activation writers, and retry publication
call graph. It rejects old embedded-storage reintroduction, schema relocation
or drift, hostile current-pointer publication, unowned list operations,
activation allocation/free outside the storage helpers, and alias/cast/memory
writer forms even when `--update-baseline` is requested.

The checked inventory is 1,688 production signals per tree with zero new or
absent entries. The KUnit-debt inventory remains 306 signals. The exact runtime
manifest remains 102 MPP plus 152 RGA cases.

## Verification

- Final 6.18 commits: `e919f19e2d26b` plus the frame-bound follow-up
  `3e6d682519a02`.
- Final mainline commits: `612b5cb2cc146` plus the byte-identical frame-bound
  follow-up `e72aaf3244fbf`.
- Both final MPP sources are byte-identical at SHA-256
  `0231564b846ce3920d96bc884ec8833440d911825b1b2e6ba326850440d672d7`.
- Strict patch-input checkpatch reports zero errors, warnings, or checks for
  both implementation patches and both follow-ups.
- Production ownership audit: 1,688 signals per tree, zero new/absent.
- KUnit source-debt audit: 306 signals per tree, zero new/absent.
- Exact manifest: 102 MPP plus 152 RGA.
- Warning-fatal clean-archive `normal`, `test-disabled`, `memory`, and `race`
  builds pass on both final trees.
- Repository consistency, source-audit adversarial tests, shell checks, links,
  and whitespace pass through `bash scripts/check-repo.sh`.

The first Phase 3F matrix exposed a 2,176-byte RCB KUnit frame under the
2,048-byte memory-profile policy. The follow-up moves that test's hardware
fixture to managed heap storage; the complete matrix was rerun from fresh
archives at the final tips rather than treating the partial first run as the
gate.

These are source and compile results. No Phase 2 or Phase 3 kernel has been
packaged, installed, booted, or exercised by runtime KUnit or hardware tests.

## Boundary and next gate

Fresh storage now makes immutable predecessor identity possible, but Phase 3F
does not yet retain a complete retirement result or own every activation
resource. CCU link/list/descriptor state, coordinator and cluster power leases,
DCHS state, imports, and public job outcome remain job-owned. The active and
timeout slots still pin the containing job rather than a separately refcounted
activation.

The next source checkpoint should distinguish logical replacement from proven
quiescence, retain one typed closure result for the old attempt, and make final
retirement or quarantine the prerequisite for resource release. Only then can
terminal paths merge reasons, rank outcomes, consolidate cleanup, or define a
real `RETIRED -> RECLAIMABLE` transition. Runtime qualification still requires
an exact Phase 3F package/boot, all 254 KUnit cases with a fatal-free lockdep
interval, same-session H.26x replay, reset contention/recovery, solo RGA3 vpp,
and the overlay chain.
