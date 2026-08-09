# Rewrite Phase 3E owns MPP active-slot claims by reason

> Scope: clean-room rewrite MPP activation ownership, Phase 3E prerequisite checkpoint
> Source: `rk3588-rewrite-6.18@969b91ce7d4b0`; `rk3588-rewrite-mainline@8f67fb6fc7d97`; `mpp_rewrite.c` activation claim/install/restore paths
> Date: 2026-08-09
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Phase 3E adds a provisional state and trigger reason to the current embedded
activation:

```text
UNINSTALLED -> SLOTTED -> CLAIMED
                    ^        |
                    +--------+ reset/stop failure restore
```

One `hw->lock`-protected claim helper is now the only production operation that
detaches `active_activation`. It validates optional pointer and generation
identity, records the initiating reason only after every predicate succeeds,
and transfers the existing active-slot job reference exactly as before.
Restore republishes the exact activation and changes `CLAIMED/reason` back to
`SLOTTED/NONE` without changing its reference, generation, or watchdog
deadline.

This is a claim-owner prerequisite, not retained retirement. `CLAIMED` means a
terminal path currently owns the active reference; it is not `RETIRED` or
`RECLAIMABLE`, and a failed reset may restore it.

## Preserved arbitration

The checkpoint encodes current behavior rather than inventing a final errno or
reason hierarchy:

- a pending IOMMU fault reserves the generation against IRQ, hard-CCU done, and
  timeout claims;
- start failure, IOMMU recovery, session reset/close, remove, shutdown, and
  coordinator-dependent abort keep their existing ability to win the slot;
- stale pointer or generation claims record no reason;
- reset/stop failure restores the same generation and clears the provisional
  reason only after an empty-slot check; and
- hard-CCU retry remains `SLOTTED/NONE` while it overwrites generation and
  deadline in the same embedded address.

Session reset and close still publish `DONE/-ECANCELED` under the session lock
before hardware retirement. Phase 3E does not rank competing results or make
the recorded trigger the final job outcome.

## Fail-closed construction and release

Initial installation and in-place retry share one validating installer. Invalid
parent, selected-hardware, state, reason, or slot identity refuses before slot
publication, generation allocation, deadline mutation, or reference
acquisition. Final job release accepts only `UNINSTALLED/NONE` storage or
`CLAIMED` storage with a valid non-sentinel reason; every other combination
warns and leaks rather than freeing storage still represented as active.

Existing KUnit cases now cover the exact three-reason IOMMU reservation set,
all permitted teardown reasons, NONE/COUNT refusal, stale pointer/generation,
claim/restore collision, transactional initial-install refusal, retry staying
`SLOTTED/NONE`, IOMMU claim/restore, stale timeout generations, and truthful
scheduler/timeout fixture states. The manifest remains 102 MPP plus 152 RGA.

## Mechanical guard

The source audit hard-requires the exact state/reason enums and activation
members, field-specific access/write owners, the single claim helper and its
callers, fixed IRQ/CCU-done/timeout/IOMMU reasons, the exact three-reason fault
priority set, and the absence of the removed raw take helper. Alias, cast,
publisher, memory-writer, schema-drift, wrong-caller, and wrong-reason cases
cannot be accepted with `--update-baseline`.

The checked inventory is 1,535 production signals per tree with zero new or
absent entries. It includes 10 state accesses/four writes, nine reason
accesses/four writes, 14 typed transition-helper calls, and the exact fault
priority schema. The KUnit-debt inventory remains 306 signals.

## Verification

- Both commits contain byte-identical MPP source.
- Strict full-patch checkpatch reports zero errors, warnings, or checks on both
  962-line patches.
- Focused MPP objects compile without diagnostics in both maintained trees.
- Production ownership audit: 1,535 signals per tree, zero new/absent.
- KUnit source-debt audit: 306 signals per tree, zero new/absent.
- Exact manifest: 102 MPP plus 152 RGA.
- Warning-fatal clean-archive `normal`, `test-disabled`, `memory`, and `race`
  builds pass on both trees.
- Repository consistency, source-audit adversarial tests, shell checks, links,
  and whitespace pass through `bash scripts/check-repo.sh`.

These are source and compile results. No Phase 2 or Phase 3 kernel has been
packaged, installed, booted, or exercised by runtime KUnit or hardware tests.

## Boundary and next gate

The activation is still one embedded mutable address. Hard-CCU retry must next
gain an immutable old `{activation, generation}` closure barrier and then fresh
successor storage before any honest `RETIRING -> RETIRED -> RECLAIMABLE`
lifecycle can exist. `timeout_generation` remains mandatory while old timeout
work can name the same address after a generation replacement.

Only after old-attempt closure/fresh retry exists may terminal paths merge
reasons, rank outcomes, consolidate cleanup, or transfer failed retirement into
a tombstone/quarantine owner. Runtime qualification still requires an exact
Phase 3E package/boot, all 254 KUnit cases with a fatal-free lockdep interval,
same-session H.26x replay, reset contention/recovery, solo RGA3 vpp, and the
overlay chain.
