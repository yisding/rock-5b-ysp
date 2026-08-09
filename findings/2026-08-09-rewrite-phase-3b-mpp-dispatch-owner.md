# Rewrite Phase 3B binds RKVDEC dispatch to exact activation storage

> Scope: clean-room rewrite MPP activation ownership, Phase 3B checkpoint
> Source: `rk3588-rewrite-6.18@7b9a4fe4e3eb0bfcca3c0f35466ff4d0230d56f7`; `rk3588-rewrite-mainline@8439e3abc142e2c6265410a986ec2d94df961078`; `mpp_rewrite.c` session-dispatch lease and activation fixtures
> Date: 2026-08-09
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Phase 3B replaces the split `session->rkvdec_dispatch_active` and
`job->rkvdec_session_dispatch` booleans with one exact owner:

```c
struct rk_mpp_activation *rkvdec_dispatch_owner;
```

The session pointer is protected solely by `srv->sched_lock`. Acquire stores
`&job->activation`; active means non-NULL; owned means exact pointer equality;
and release clears only the exact owner, so a queued sibling cannot release the
running activation's lease. Existing scheduler, active-slot, and terminal-path
job references continue to retain the containing job. The owner pointer is
used only for identity comparison and is never dereferenced.

Final job release now checks the same identity under `srv->sched_lock`. If an
impossible missed-release path leaves the activation owned, release warns and
fails closed by retaining the job instead of freeing embedded storage and
leaving a dangling pointer or slab-reuse ABA in the session. Normal completion
and successful abort still release in their existing order. A failed abort
still retains dispatch because its existing `dispatch_retired` proof remains
false.

This is current-storage containment, not immutable attempt retention. HARD-CCU
retry still changes generation/deadline in the same embedded activation, so
the owner address intentionally remains stable. Duplicate acquire is likewise
unchanged: it warns and overwrites under the scheduler lock; the scheduler's
existing admission predicate makes that unreachable on the intended path.

Existing KUnit cases prove exact acquire identity, foreign-release isolation,
clear/reacquire order, successful session-abort cleanup, final-release guard
classification, and dispatch-address stability across in-place retry. The
manifest remains 102 MPP plus 152 RGA cases. There is not yet an injected
stop/reset-failure test that drives session abort and proves owner retention;
that belongs with the transition engine rather than this representation-only
checkpoint.

## Source and build evidence

- Both commits contain byte-identical MPP source with SHA-256
  `46132e1f26ef9606f9fa315376daff24739aabc24d2c01bde6a2f53806b909a2`.
- Each commit changes only `mpp_rewrite.c`: 56 insertions and 27 deletions.
  Strict checkpatch reports zero errors, warnings, or checks over the 226-line
  patch, and both maintained worktrees are clean.
- The source-pinned production audit reports 1221 signals per tree with zero
  new or absent entries: one exact session schema, five owner accesses, two
  owner writes, and sixteen activation accesses. Direct access/write outside
  the owner helpers, either obsolete boolean, schema move/duplication/type
  drift, and cross-tree baseline-output drift are hard failures that
  `--update-baseline` cannot bless.
- The KUnit-debt audit remains 306 signals per tree, the exact 102/152 manifest
  passes, and all eight focused ownership/KUnit source-audit unit tests pass.
- `rewrite-build-gate.sh all` passed warning-fatal `normal`, `test-disabled`,
  KASAN/fault-injection `memory`, and KCSAN/lockdep `race` profiles for both
  exact trees. Each profile built both rewrite drivers, both IOMMU providers,
  and the ROCK 5B DTB through the shared central ccache. Scratch trees were
  removed after each profile because the build filesystem was space-limited.

## Boundary and next gate

No full kernel or package was built, and nothing was installed or booted. No
KUnit case or hardware workload ran. The sanitizer profiles are compile
coverage, not runtime sanitizer evidence.

The active/timeout slots still hold retained job pointers. Selected hardware,
CCU/link/DCHS state, cluster/coordinator power, async snapshots, and final
result arbitration remain in their legacy owners. There is no retained
`RUNNING -> RETIRING -> RECLAIMABLE` attempt, reason merge, tombstone, or
activation-typed slot. The next source checkpoint should move one coherent
ownership group without changing slot or terminal behavior; retained attempt
closure must precede terminal-reason arbitration.

Runtime qualification still requires an exact package and boot, all 254 KUnit
cases with live lockdep, and the same-session decoder,
reset-contention/recovery, solo RGA3 vpp, and overlay-chain replays.
