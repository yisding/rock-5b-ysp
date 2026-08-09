# Rewrite Phase 2 constructs stable reset domains without claiming group recovery

> Scope: clean-room rewrite MPP reset ownership, Phase 2 checkpoint 1
> Source: `rk3588-rewrite-6.18@53a7fa1acbc00b5263b20b02e9b0947a4def5f9d`; `rk3588-rewrite-mainline@ba8e11de18a8e25bd9e160371972c158d419eef6`; `mpp_rewrite.c` reset-domain registry and single-target operations
> Date: 2026-08-08
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

The first Phase 2 checkpoint replaces the old reset-domain mutex pointer with a
stable service-owned reset-domain object. Each object owns an immutable OF-node
identity reference, member list, operation mutex, single-target state, reset
epoch, responsible hardware pointer, and diagnostic counters. Probe binds every
reset-capable MPP hardware object by `ccu_node ?: dev->of_node` before its first
power/read-ID operation and fails closed if the fixed registry is exhausted.
The devm member action detaches the hardware after normal remove has stopped
admission and drained work, while module teardown releases the retained node
references only after the platform driver is unregistered.

Single-target power deassert and recovery pulse now run as complete domain
methods. A blocked operation revalidates membership after acquiring the domain
mutex, so unregister cannot leave a stale waiter able to touch reset hardware.
State and the nonzero reset epoch are updated under the same mutex as the reset
backend and bounded 10 microsecond pulse. Failure callbacks, PM operations, and
service topology locking remain outside that innermost reset lock. A failed
operation records `FAILED` but remains retryable; `QUARANTINED` is represented
but is not yet published by this checkpoint.

Two heap-backed KUnit cases cover registry deduplication, capacity exhaustion,
detach/rebind, member invariants, state transitions, retry after failure, and
epoch advancement. The exact manifest is now 96 MPP plus 152 RGA cases.

## Source and build evidence

- The MPP source is byte-identical between the two commits.
- Strict checkpatch reports zero errors, warnings, or checks over the 721-line
  patch in each tree.
- The source-pinned ownership inventory reports 564 signals per tree with zero
  new or absent entries. The added categories freeze 20 binding accesses, seven
  registry-identity/member-head accesses, eight membership/lifecycle entries,
  13 domain-operation entries, four pending-operation accesses, and 28 state writes; the
  two raw `reset_control_*` calls remain confined to the backend leaves.
- The existing KUnit fixture-debt inventory remains 306 signals per tree with
  zero new or absent entries.
- Warning-fatal clean-archive `normal`, `test-disabled`, KASAN/fault-injection
  `memory` with `FRAME_WARN=2048`, and KCSAN/lockdep `race` profiles passed on
  both exact commits. Every profile built the Rockchip and VSI IOMMU providers,
  MPP and RGA rewrite objects, and Rock 5B DTB. The test-disabled objects prove
  production compilation without either embedded suite.

The build gate used the shared `~/Code/.ccache` store and retained disposable
archives under `~/Code/rock-5b/build/rewrite-phase2-reset-domain-gate/`:

| Tree/profile | Retained directory | `build.log` SHA-256 |
|---|---|---|
| 6.18 normal | `rkcompat-rewrite-build.6.18.normal.Z5YTvu` | `418eb4cfab902f5b2b0f0688a6baa2faefee51970b0e1473059ac357388468d6` |
| 6.18 test-disabled | `rkcompat-rewrite-build.6.18.test-disabled.vxpoMY` | `e8929bdcaaf40fd74d5c053ebcc9511dd1a34761cba1e66681b6ff885173903c` |
| 6.18 memory | `rkcompat-rewrite-build.6.18.memory.s8iRjE` | `638b8f1e9c39b55c85606c55e72fc04cecb8be5a70b86a37208e10abd603bc40` |
| 6.18 race | `rkcompat-rewrite-build.6.18.race.mMq4cc` | `f67eec41d4708bde43ab8026b5e322b7ed6305015d990610f18fb88471d9acec` |
| mainline normal | `rkcompat-rewrite-build.mainline.normal.ueg9Yo` | `8c6402be84ebacd96de1c6561985d897ed00de42a4a78148761a4808267079b0` |
| mainline test-disabled | `rkcompat-rewrite-build.mainline.test-disabled.QtOxV5` | `bf1309a28ac1ace1245c6099f28512440c18d6d135eceacfd895e82fadc7c2f0` |
| mainline memory | `rkcompat-rewrite-build.mainline.memory.3hizaT` | `35a0b399377f4cd94738c08fca6247096c534e7b3e97dcb084dc47deaecce77c` |
| mainline race | `rkcompat-rewrite-build.mainline.race.xuq8Dc` | `2fa45b9195913067d3aa2e3b7edb43a12a3a573f9386a1802e007f463a696964` |

All eight logs contain no `warning:`, `error:`, fatal, failed-target, or
undefined-reference diagnostic. The final shared-cache observation was 1,982
hits and 548 misses among 2,530 cacheable calls.

The operator explicitly authorized this source-only Phase 2 work on 2026-08-08
without waiting for installation or boot qualification of the predecessor
Phase 1 package. That authorization changes sequencing, not the evidence level.

## Boundary

This is deliberately not complete reset or cluster ownership. The hard-CCU
`rk_mpp_rkvdec2_force_stop_ccu()` path still performs its existing multi-core
assert-all, delay, and deassert-all sequence through the low-level domain
leaves. It does not yet publish domain state or one shared epoch. Locking each
line separately would permit an unrelated power deassert inside the group
pulse, so that migration is deferred until `rk_mpp_cluster` pins and validates
the exact coordinator/member set and owns one group transaction.

The provisional domain key preserves the existing CCU serialization set; it
does not prove that reset, DMA/IOMMU, genpd, and CCU topology identities are the
same physical authority. No reset epoch is consumed by IRQ, recovery admission,
or debug ABI yet. No package, boot, runtime KUnit, decoder, reset-contention,
fault-injection, suspend, or unbind/rebind hardware result exists for these
commits.

## Verification gate

Before calling Phase 2 qualified, build and inspect the exact 6.18 package,
boot it with recovery retained, require all 248 KUnit cases and a fatal-free
lockdep interval, then repeat the same-session H.26x, dual-core reset
contention, timeout/IOMMU-fault, suspend, unbind/rebind, solo RGA3 vpp, and
overlay-chain gates. The next source checkpoint may construct a read-only MPP
cluster and migrate the hard-CCU group pulse, but must keep the absence of
runtime evidence explicit.
