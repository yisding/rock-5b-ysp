# Rewrite Phase 3H retains recovered MPP terminal claims and quarantine ownership

> Scope: clean-room rewrite MPP activation ownership, Phase 3H recovered-terminal and restore-refusal checkpoint
> Source: `rk3588-rewrite-6.18@1784358650e3c41abbd5154cbd1737da07d968de`; `rk3588-rewrite-mainline@e71d368cc48374638eafbfdf1e9c6864cabbd118`; `mpp_rewrite.c` claim, recovered-terminal, quarantine, remove, and shutdown paths
> Date: 2026-08-09
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Phase 3H makes the active-slot claim token an exact reference owner. A nonempty
`rk_mpp_activation_claim_token` owns the containing-job reference transferred
out of `hw->active_activation`, together with the claimed activation pointer,
nonzero generation, and transition reason. That reference can take only one of
three paths: exact restore to the active slot, release after a proved terminal
cleanup, or transfer into the service quarantine tombstone.

Recovered error-IRQ, timeout, IOMMU-fault, session abort/close,
remove/shutdown, reset-error, and hard-CCU dependent paths now finish the
claimed activation only when typed evidence proves the required hardware scope
quiesced. A direct-core
terminal stores its core recovery by value. A hard-CCU group terminal stores
the coordinator/group recovery and the selected-core recovery separately; the
group proof must be successful and quiesced, while the core record remains
distinct. Successful proof moves `CLAIMED` to `RETIRED` before the token drops
its one job reference.

If exact restore refuses the token, Phase 3H does not lose that reference or
coerce the activation into a releasable state. It transfers the job reference
to a service-owned quarantine list, records the token's exact generation,
marks the activation `QUARANTINED`, and retains the activation/job/session,
selected-hardware references, imports, CCU/link/DCHS state, power ownership,
and RKVDEC dispatch lease. The transfer keeps three failure dimensions
separate: the diagnostic quarantine error drives reset-failure reporting and
admission closure, while the activation retains the per-core recovery
status/result and, when applicable, the group recovery status/result. A
quarantine closes admission on the selected core and its owned CCU;
coordinator failure also closes dependent-core admission.

Removal treats any service quarantine as a retained DMA owner and refuses to
unregister provider callbacks or release device-managed state. Shutdown does
not wait forever for a proof that cannot arrive: it closes admission, disables
the IRQ, and deliberately leaves the tombstone and its resources alive until
reboot.

## Preserved boundary

This checkpoint covers **recovered terminal paths only**. It does not convert
clean IRQ completion, clean `CCU_DONE`, or pre-doorbell `START_FAILURE` into
typed retirement; those paths retain the Phase 3G legacy `CLAIMED` release
boundary. Phase 3H also does not add `RECLAIMABLE`, a general clean-retirement
engine, or final outcome arbitration across IRQ, timeout, fault, abort, remove,
and shutdown evidence.

The job still owns CCU/link/DCHS and power fields, all activation storage stays
job-owned until final release, and the service quarantine is intentionally a
reboot-only owner rather than a recovery/reclamation mechanism. No package,
boot, runtime KUnit, hardware recovery, or consumer result exists for these
tips.

## Mechanical guard

The source audit now freezes the claim-token schema and its active-slot
reference transfer, typed terminal proof, exact restore, quarantine generation
and diagnostic/core/group evidence, service tombstone ownership, admission
closure, dispatch retention, hard-CCU retry refusal after terminal-proof
failure, and remove/shutdown gates. The exact production ownership inventory is
2,068 signals per tree with zero new or absent entries. The KUnit-debt inventory
remains 306 signals. The exact runtime manifest is now 103 MPP plus 152 RGA
cases, 255 total.

## Verification

- Final tips: 6.18 `1784358650e3c41abbd5154cbd1737da07d968de`;
  mainline `e71d368cc48374638eafbfdf1e9c6864cabbd118`.
- The tracked MPP sources are byte-identical at SHA-256
  `24bad07edc62ffb4672ce2a11f8266587bef468987705d65cc16415010d82f17`;
  the tracked rewrite sources, Kconfig, ABI ledgers, and UAPI are byte-identical
  between those tips.
- Strict full-series checkpatch reports zero errors, warnings, or checks over
  1,977 lines on each tree.
- Production ownership audit: 2,068 signals per tree, zero new/absent.
- KUnit source-debt audit: 306 signals per tree, zero new/absent.
- Exact manifest: 103 MPP plus 152 RGA, 255 total.
- The warning-fatal clean-archive matrix passes `normal`, `test-disabled`,
  `memory`, and `race` on both kernel lines, including both IOMMU providers,
  both rewrite objects, and the Rock 5B DTB.
- `bash scripts/check-repo.sh` passes all 408 Markdown files, 3,617 local
  links, 513 local anchors, and 108 repository-check regression tests.

These source and compile results are not boot or runtime evidence; the memory
and race profiles prove only that the instrumented configurations compile.

## Boundary and next gate

The next source checkpoint must not infer general retirement from Phase 3H.
Clean IRQ/`CCU_DONE` and pre-doorbell `START_FAILURE` still need typed closure,
and terminal triggers still need one final outcome-arbitration owner with the
documented precedence. `RECLAIMABLE` may become true only after callback/slot
references and all dispatch, selected-hardware, CCU/link/DCHS, power, import,
and quarantine ownership are visibly released by proof.

Qualification next requires an exact Phase 3H package and boot, all 255 KUnit
cases with a fatal-free
lockdep interval, forced restore-refusal/quarantine checks, same-session H.26x,
dual-core reset contention/recovery, solo RGA3 vpp, and the overlay chain.
