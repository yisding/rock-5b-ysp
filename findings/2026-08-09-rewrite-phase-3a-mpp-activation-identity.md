# Rewrite Phase 3A embeds MPP current-attempt identity

> Scope: clean-room rewrite MPP activation ownership, Phase 3A checkpoint
> Source: `rk3588-rewrite-6.18@7548afe6a8b1b671f5092a798a94ff695cf0b0eca`; `rk3588-rewrite-mainline@af89363ffa5ede087af31045934d54389b548fbd`; `mpp_rewrite.c` `rk_mpp_activation`, active-slot, watchdog, IRQ, fault, and hard-CCU retry paths
> Date: 2026-08-09
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Phase 3A embeds an `rk_mpp_activation` current-attempt record in every MPP job.
The record owns the parent-job identity, current nonzero hardware generation,
absolute watchdog deadline, and deadline-valid bit. The hardware retains only
the monotonic generation allocator; the old `active_generation`,
`timeout_deadline_generation`, and `timeout_deadline` mirrors are gone.

`rk_mpp_hw_install_active_locked()` allocates and installs the generation while
holding `hw->lock`. `rk_mpp_hw_schedule_timeout()` records the first absolute
deadline in the activation, so canceling and re-arming the same attempt cannot
extend its watchdog. IRQ leases, timeout cookies, and IOMMU-fault cookies now
compare against the embedded generation. The activation install leaf also
asserts the hardware lock and live active-slot identity.

This checkpoint deliberately preserves the existing hard-CCU retry semantics:
`rk_mpp_hw_prepare_active_retry()` advances and overwrites the embedded current
record before recovery, just as it previously advanced the hardware generation.
It does not temporarily publish generation zero or change which concurrent
fault owns recovery. A fresh retained successor attempt belongs to the later
transition-engine checkpoint.

Existing KUnit cases now cover the parent backpointer, generation wrap to one,
install-time deadline reset, retry generation replacement, same-attempt
deadline preservation, and stale IRQ, timeout, and IOMMU cookies. The exact
manifest remains 102 MPP plus 152 RGA cases.

## Source and build evidence

- Both commits contain byte-identical MPP source with SHA-256
  `014cfa0fd9cd365d19974fc38caec418899ebf32739b1d474f74ea237616116b`.
- Each commit changes only `mpp_rewrite.c`: 121 insertions and 38 deletions.
  Strict checkpatch reports zero errors, warnings, or checks over the 316-line
  patch, and both maintained worktrees are clean.
- The source-pinned production audit reports 1220 signals per tree with zero
  new or absent entries. It freezes the activation schema, helper entries,
  nested and whole-object accesses, nine raw writes, the generation allocator,
  and field-specific writer allowlists. A wrong field written from an otherwise
  approved helper is rejected. The KUnit-debt audit remains 306 signals per
  tree, and the exact 102/152 manifest passes.
- `rewrite-build-gate.sh all` passed warning-fatal `normal`, `test-disabled`,
  KASAN/fault-injection `memory`, and KCSAN/lockdep `race` profiles for both
  exact trees. Each profile built both rewrite drivers, both IOMMU providers,
  and the ROCK 5B DTB with the shared central ccache.
- Retained clean-archive sources, outputs, and logs live under
  `~/Code/rock-5b/build/rewrite-phase3-activation-owner/`.

  | Tree/profile | Build-log SHA-256 |
  |--------------|------------------|
  | 6.18 normal | `86c2535cad83285b8ae1fe14197439ac389945dfd3e256e311dfbac258c2568c` |
  | 6.18 test-disabled | `dfa81ffb2d44381e09cf7bf909d79d92beceb7e13ebc9043ee04315f18f5ec87` |
  | 6.18 memory | `f7ae5b1d3103d36460771525c31a42f4d92ec0405724d025764d362836643134` |
  | 6.18 race | `107ed656a6d5a000a8cbd05e3178f992c90c090cdfc149e0b5378934dd1f36f0` |
  | mainline normal | `03f7541ee2c26606624409f8f6365cb3d9f1d7dffd237278f5e090ee2412d18e` |
  | mainline test-disabled | `41c70f5ca7565cdd8382b8a661569819b77343c8367f03000a6adb6c92b273b0` |
  | mainline memory | `89b2bd650cde4518b26b125d4d97a49f656c74928d3b159f2811dca7777f2582` |
  | mainline race | `58e466dd1a07d724656ed9e9f099a81312b9ae9d3bbe2e6fc549f68bf5f21359` |

## Boundary and next gate

No full kernel or package was built, and nothing was installed or booted. No
KUnit case or hardware workload ran. The sanitizer profiles are compile
coverage, not runtime sanitizer evidence.

This is an embedded current-attempt representation, not yet a retained
activation or authoritative state machine. The active and timeout slots still
hold retained job pointers. Hard-CCU retry still overwrites the same embedded
record. Selected hardware, CCU/link/DCHS ownership, cluster power and session
dispatch leases, IRQ/fault snapshots, and final result arbitration remain in
their legacy owners. There is no `RUNNING -> RETIRING -> RECLAIMABLE` boundary,
reason merge, tombstone, or activation-typed slot yet.

The next source checkpoint should move the coherent selected-hardware,
CCU/link/DCHS, power, and dispatch ownership into the embedded activation
without changing slot or terminal behavior. The later slot and transition
checkpoint must then retain the active attempt through reason collection and
hardware quiescence before it permits embedded reuse. Runtime qualification
still requires an exact package and boot, all 254 KUnit cases with live lockdep,
and the same-session decoder, reset-contention/recovery, solo RGA3 vpp, and
overlay-chain replays.
