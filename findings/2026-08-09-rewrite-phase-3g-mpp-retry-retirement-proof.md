# Rewrite Phase 3G retains MPP retry-predecessor retirement proof

> Scope: clean-room rewrite MPP activation ownership, Phase 3G hard-CCU retry closure checkpoint
> Source: `rk3588-rewrite-6.18@74c1b98def888`; `rk3588-rewrite-mainline@dd3a88cd5629`; `mpp_rewrite.c` activation closure and hard-CCU retry paths
> Date: 2026-08-09
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Phase 3G distinguishes Phase 3F's logical retry replacement from physical
retirement. A superseded hard-CCU activation now retains two typed recovery
records by value: the already completed group recovery that proves the old
shared descriptor chain and DMA view are quiesced, and the later per-core
recovery that decides whether the published successor is reusable.

Retry publication requires a successful, quiesced, reusable group result. It
copies that result before publishing `SUPERSEDED/RETRY_REPLACED` and
`PENDING`, then returns a stack-local token containing the predecessor pointer
and immutable generation. After per-core stop/recovery, the exact token records
the core result on success or failure and moves the predecessor to `RETIRED`.
Only the group proof establishes predecessor retirement; the core proof gates
successor restart. A quiesced but non-reusable core therefore retires the old
attempt while refusing reuse of the new one.

The token never escapes into persistent storage. Wrong activation or
generation, current/active identity, selected hardware, list membership,
state, reason, or group proof refuses closure without consuming the token.
Final activation-storage release now rejects a bare `SUPERSEDED` record and
accepts it only when the retained group/core evidence is complete.

## Preserved boundary

The checkpoint does not add general terminal arbitration or early activation
freeing. Active and timeout slots still retain the containing job, all attempt
storage remains job-owned until final release, and selected-hardware references
remain on every retained activation. `CLAIMED` still means a restorable active
slot transfer, not retirement. CCU link/list/descriptor state, cluster and
coordinator power, DCHS state, imports, public result ordering, quarantine, and
`RECLAIMABLE` remain later work.

Retry publication deliberately remains before timeout cancellation and
per-core stop/recovery, preserving Phase 3E/3F fault and fallback behavior.
`SUPERSEDED` is therefore only a pending logical handoff until its copied group
proof and the exact token close it.

## Mechanical guard

The production audit now hard-guards the exact closure, recovery-record, and
retry-token schemas; their access/write owners; recovery-result owners; token
stack locality and caller chain; closure initialization and pristine checks;
group-before-publication and core-before-retirement ordering; release
predicates; and the commit/stop/finish control path. Renamed or inferred token
aliases, closure/record pointer aliases, schema expansion, reordered proof
writes, unauthorized recovery writers, token escape, and early success paths
are rejected even with `--update-baseline`.

The checked inventory is 1,792 production signals per tree with zero new or
absent entries. The KUnit-debt inventory remains 306 signals. The exact runtime
manifest remains 102 MPP plus 152 RGA cases.

## Verification

- Final tips: 6.18 `74c1b98def888`; mainline `dd3a88cd5629`.
- The tracked MPP sources are byte-identical at SHA-256
  `0405fd4bb37ec9769423280a9b9cb5f2c790aaa1f04037fbc862cf2a25d5b83e`.
- Strict patch-input checkpatch reports zero errors, warnings, or checks over
  486 lines in each tree.
- Production ownership audit: 1,792 signals per tree, zero new/absent.
- KUnit source-debt audit: 306 signals per tree, zero new/absent.
- Exact manifest: 102 MPP plus 152 RGA.
- Warning-fatal clean-archive `normal`, `test-disabled`, `memory`, and `race`
  builds pass on both final trees.
- Repository consistency, source-audit adversarial tests, shell checks, links,
  and whitespace pass through `bash scripts/check-repo.sh`.

These are source and compile results. No Phase 2 or Phase 3 kernel has been
packaged, installed, booted, or exercised by runtime KUnit or hardware tests.

## Boundary and next gate

Phase 3G proves retirement only for hard-CCU retry predecessors. The next
source checkpoint should carry an exact closure token through ordinary IRQ,
timeout, fault, abort, remove, and shutdown cleanup, and move `CLAIMED` to
`RETIRED` only when a typed result proves quiescence. A real quarantine owner
must retain the containing job and resources when quiescence is unproved.
Only after callback/slot references, dispatch, selected hardware, CCU/link,
DCHS, power, and imports are visibly released can `RECLAIMABLE` become true.

Runtime qualification still requires an exact Phase 3G package/boot, all 254
KUnit cases with a fatal-free lockdep interval, same-session H.26x replay,
reset contention/recovery, solo RGA3 vpp, and the overlay chain.
