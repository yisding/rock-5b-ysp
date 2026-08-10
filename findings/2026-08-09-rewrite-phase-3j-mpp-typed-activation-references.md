# Rewrite Phase 3J types external MPP activation references

> Scope: clean-room rewrite MPP activation ownership, Phase 3J external-reference checkpoint
> Source: `rk3588-rewrite-6.18@7481df21ca2b1481a3c4b4d222e3ebed28692544`; `rk3588-rewrite-mainline@4a632e00c4cd729cb7aa473686bed3ccd2bb271c`; `mpp_rewrite.c` activation-reference, active/timeout/claim/retry/quarantine, and teardown paths
> Date: 2026-08-09
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Phase 3J replaces the external job-pointer adapters around an activation with
one typed identity reference: `{ activation, generation }`. Each activation
now has a base reference bias owned by its retained job storage. Every external
owner that can dereference the activation carries a paired activation reference
and containing-job reference:

- hardware active and timeout slots;
- the detached active-claim token;
- the hard-CCU retry handoff token; and
- each service quarantine retention count/list entry.

Cloning a typed reference acquires both references, moving one transfers both
without a count change, and putting one releases both. The timeout generation
is no longer a parallel scalar, and the claim token no longer needs a boolean
that says whether it owns the job reference. Identity checks use the wrapper's
pointer and generation together.

The base bias does not own a job reference. It keeps retained activation
storage valid while the job owns its activation list, and final teardown
requires each activation to be back at that base-only count. This checkpoint
does not release the base bias early or free an individual retired record.

## Retry and quarantine transfer

Hard-CCU retry commit acquires the successor's active external pair and moves
the predecessor's prior active pair into the retry token only when A→B
publication succeeds. A preflight/commit refusal leaves the predecessor active
and puts the unpublished successor pair. After successful publication, retry
finish puts the predecessor pair only after typed closure completes; a
retry-finish refusal moves that same predecessor pair into quarantine. Neither
case manufactures a second owner or drops the only dereference-capable
reference.

The quarantine sink therefore retains the exact activation identity and job
lifetime it received. Restore-refusal and impossible-finisher behavior remain
reboot-bound. There is still no production drain that can turn a quarantine
record into reusable storage.

## Preserved borrowed and backend ownership

The job's current-activation pointer, session dispatch-owner pointer, and
activation-list membership remain borrowed identities protected by their
existing locks or by the job-owned base storage. Selected hardware remains a
per-activation retained reference, but CCU/link/DCHS state, coordinator/member
power, imports, register state, and the remaining backend cleanup receipts are
still job-shaped.

Phase 3I's terminal observations are unchanged: exact `NOT_PUBLISHED`,
`IRQ_ACCEPTED`, or `CCU_DONE_ACCEPTED` evidence makes a clean claim immutable
`RETIRED`; RKVDEC `BUS_IDLE` remains advisory rather than quiescence or reuse
authority; recovered-terminal proof remains separate; and AV1 untrusted-stop
failure retains `SLOTTED` active ownership for remove/shutdown retry.

## Verification

- Final tips: 6.18 `7481df21ca2b1481a3c4b4d222e3ebed28692544`;
  mainline `4a632e00c4cd729cb7aa473686bed3ccd2bb271c`.
- The tracked MPP source is byte-identical at SHA-256
  `815ccaf6daa20a88592f1b9ba4860a29aeb35e2a26cae7554ade714420e29ee4`.
- Strict checkpatch reports zero errors, warnings, or checks over the exact
  1,976-line Phase 3J range on each tree.
- The amended heads add the KUnit-only `noinline_for_stack` correction exposed
  by the memory-profile compile; it does not alter the production-shape owner
  model described above.
- The final-source 6.18 KUnit-enabled MPP object is 6,559,584 bytes at SHA-256
  `8bd96a7ccb3fa60cfa23203055a0404b3f26d4dbd3e93a0b28224748cb7e337d`.
- The final-source 6.18 test-disabled MPP object is 2,287,288 bytes at SHA-256
  `4c7d90ba06743683c5b291e9b8d0dbfc910673cbf4c2a371f251de9c0ce98286`.
- The exact source manifest is 105 MPP plus 152 RGA cases, 257 total.
- The production ownership audit passes at 2,251 signals per tree and the
  KUnit fixture-debt audit passes at 306 signals per tree.
- All eight warning-fatal final-head profiles pass: `normal`, `test-disabled`,
  `memory` (KASAN/fault-injection), and `race` (KCSAN/lockdep) on both kernel
  lines, including both IOMMU providers, both rewrite objects, and the Rock 5B
  DTB.
- The dedicated test-disabled policy/ABI gate passes on both heads: both
  rewrite KUnit options resolve disabled, both providers/rewrite objects and
  the Rock 5B DTB compile warning-fatally, and the deliberate MPP ABI mutation
  fails at compile time.

`bash scripts/check-repo.sh` passes against this exact evidence state. Phase 3I's
2,180-signal audit and build results remain historical evidence for that exact
older source; they are not substituted for the Phase 3J results above.

These are source and compile results only. No package, boot, runtime KUnit, decoder,
reset/recovery, RGA, AV1/VSI, performance, fuzz, or soak result exists for the
Phase 3J tips.

## Boundary and next gate

Phase 3J makes external activation lifetime explicit. It does not add a
resource-drain receipt, `RECLAIMABLE`, early activation-storage release,
terminal reason merging, or final public outcome arbitration. Dispatch/current
and list identities remain borrowed, and backend resources remain job-shaped.

The next ownership checkpoint must move a coherent resource-owner set behind
activation-aware drain or handoff receipts. Only after every external typed
reference and every backend resource receipt is gone may an immutable
`RETIRED` activation become `RECLAIMABLE`; the base bias must not be released
before that proof exists. Qualification still requires an exact package/boot,
all 257 KUnit cases with a
fatal-free lockdep interval, and the existing decoder/recovery/RGA hardware
matrix.
