# Rewrite Phase 3I retains exact clean MPP terminal observations

> Scope: clean-room rewrite MPP activation ownership, Phase 3I clean-terminal observation checkpoint
> Source: `rk3588-rewrite-6.18@395644689db8f`; `rk3588-rewrite-mainline@38768c5cff419`; `mpp_rewrite.c` start rollback, clean IRQ/CCU completion, claim, closure, and BUS_IDLE paths
> Date: 2026-08-09
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Phase 3I removes the last release rule that treated a clean-terminal
`CLAIMED` activation as if its terminal identity were already immutable. A
pre-doorbell start rollback, accepted clean IRQ, or accepted hard-CCU
descriptor completion now stores a typed observation in the exact claimed
activation and moves that activation to `RETIRED` before its active-slot job
reference can be released.

The immutable observation distinguishes:

- `NOT_PUBLISHED` for the audited `START_FAILURE` paths that cannot return an
  error after their START/`CFG_DONE` doorbell;
- `IRQ_ACCEPTED` with the accepted hardware status for clean RKVENC, direct
  RKVDEC, and AV1 threaded completion; and
- `CCU_DONE_ACCEPTED` with the exact completed descriptor status for clean
  hard-CCU completion.

The finisher checks the nonempty claim token's activation pointer, generation,
reason, containing job, selected hardware, list membership, current-attempt
identity, `CLAIMED` state, pristine closure, and empty active slot while the
hardware run lock and slot lock are held. `CCU_DONE_ACCEPTED` additionally
checks the job's owned coordinator and common cluster while the coordinator
recovery lock is held. A mismatch does not fall through to legacy cleanup: it
transfers the exact claim reference to the existing service quarantine owner.

Every production `START_FAILURE` site is before its doorbell. HARD-CCU
publication has no fallible operation after `CFG_DONE`; the other publish
funnels likewise return errors only before START. AV1's deliberately
conservative AFBC/untrusted start-failure branch remains separate: successful
stop/recovery stores the existing recovered-terminal proof, while stop failure
keeps the activation `SLOTTED` and active so remove or shutdown can retry
containment without freeing potentially reachable state.

## Observation is not quiescence

The new clean-terminal record fixes the attempt's accepted terminal identity
and policy decision. It is not a reset, translation-isolation,
DMA-quiescence, or reuse proof. Recovered direct-core and hard-CCU group/core
results remain separate typed closure records.

RKVDEC's BUS_IDLE poll now returns and stores both whether the register was
checked and its exact status. Success, timeout, and unavailable evidence
therefore remain distinguishable per activation. The existing timeout remains
advisory and does not change the userspace result in this checkpoint; in
particular, `-ETIMEDOUT` must not become evidence for future reclaimability.
Hard-CCU `CCU_DONE_ACCEPTED` is a per-descriptor terminal observation, not
proof that the coordinator or every participating core is quiescent.

## Preserved lifetime and behavior

The claim token retains the active-slot job reference through typed retirement
and the existing backend cleanup order. Clean IRQ and CCU completion still
cancel the exact watchdog, perform readback, power/resource cleanup, publish
the unchanged job result, release dispatch/selected-hardware ownership, and
only then drop the claim reference. Pre-doorbell submit rollback retires the
claim before returning its unchanged error to the scheduler; the scheduler's
existing job reference carries the job through ordinary completion cleanup.

If the active slot itself cannot be claimed during an impossible start
rollback, the driver poisons admission and retains the active owner. If the
typed finisher refuses a nonempty claim, that claim moves to quarantine before
normal terminal cleanup. Neither case converts an ownership inconsistency into
a releasable job.

## Verification

- Final tips: 6.18 `395644689db8f`; mainline `38768c5cff419`.
- The tracked MPP source is byte-identical at SHA-256
  `95816d9033e76c86638e13b5ed3a0399b4a30e9d26b338579a624548fcecaada`.
- Strict checkpatch reports zero errors, warnings, or checks over the exact
  1,076-line Phase 3I range on each tree.
- Focused KUnit-enabled MPP object compiles pass on both kernel lines.
- The exact source manifest is 104 MPP plus 152 RGA cases, 256 total.
- The production ownership audit passes at 2,180 signals per tree and the
  KUnit fixture-debt audit passes at 306 signals per tree, both with zero
  new or absent entries.
- All eight warning-fatal clean-archive profiles pass: `normal`,
  `test-disabled`, `memory` (KASAN/fault-injection), and `race`
  (KCSAN/lockdep) on both kernel lines.
- The KUnit opt-in-default check remains off under `KUNIT_ALL_TESTS`, and a
  deliberate MPP message-size ABI mutation fails the compile-time static
  assertion on both lines.

`bash scripts/check-repo.sh` passes, including 109 repository-check regression
tests. None of the Phase 3H counts or repository/build-matrix results are
carried across this source boundary.

These are source and focused-compile results only. No package, boot, runtime
KUnit, decoder, reset/recovery, RGA, AV1/VSI, performance, fuzz, or soak result
exists for these tips.

## Boundary and next gate

Phase 3I adds typed clean retirement, not `RECLAIMABLE`. CCU/link/DCHS,
coordinator and cluster power, imports, dispatch release, selected-hardware
release, timeout references, and retained retry handoff remain job-shaped or
outside a per-attempt resource-drain receipt. The checkpoint also does not add
reason merging or final outcome arbitration.

The next ownership checkpoint must define a positive, activation-aware drain
or handoff receipt before any retired storage can become `RECLAIMABLE` or be
reused. An advisory BUS_IDLE timeout cannot satisfy that receipt without later
reset or isolation proof. Qualification still requires an exact Phase 3I
package and boot, all 256 KUnit cases with a fatal-free lockdep interval, clean
start/IRQ/CCU observations, forced impossible-finisher quarantine, AV1
untrusted-start retention, same-session H.26x, dual-core recovery, and the
existing RGA hardware gates.
