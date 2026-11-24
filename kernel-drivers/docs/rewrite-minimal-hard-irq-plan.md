# Minimal hard-IRQ architecture plan (RT-nesting cleanup)

> Status: plan revised against current source on 2026-11-24. No phase is
> complete. The encoder work of the original Phase 2 is already in the source;
> the MPP lock nesting has changed shape; RGA is as it was.
> Scope: clean-room MPP/RGA rewrite drivers' interrupt paths
> Source reviewed: `rk3588-rewrite-6.18@94b3d97d6a12` (byte-identical drivers
> at `rk3588-rewrite-mainline@1bcfb8514376`): both IRQ dispatchers, the four
> backend hard handlers, the RGA handler, every `regs_lock` section, and the
> registrations. The first version of this plan reviewed `600d6e2fb6a49` on
> 2026-07-30.
> Pairs with: [`2026-07-30 soft-CCU finding`](../../findings/2026-07-30-rewrite-soft-ccu-split-critical-section-h265-wedge.md)
> and the
> [2026-11-23 first-execution finding](../../findings/2026-11-23-rewrite-kunit-first-execution-fixture-repair-and-case-audit.md),
> which observed the current reports
> Date: 2026-07-30, revised 2026-11-24

> **Boundary.** This is a target plan, not the as-built interrupt model. The
> inventory below was read at the source named above and was not run on
> hardware. Read the
> [current architecture guide](rewrite-driver-architecture/README.md) to
> interpret present source.

## Result

One architectural contract, stated in a sentence and enforced by lockdep:
**a hard IRQ handler may only claim, ack, and stage, under raw locks; every
other action — job attribution, slice reads, wakeups, fences, accounting —
happens in thread context.** When the plan completes,
`PROVE_RAW_LOCK_NESTING` returns to its (arm64-forced) enabled state and the
existing KUnit boot gate's live-lockdep requirement proves the property on
every boot.

Until then the debug kernel keeps that checker off
([`ysp-debug-instrumentation.conf.sh`](../scripts/debug-kernel/ysp-debug-instrumentation.conf.sh)
with the locknest prompt patch), so this cleanup does not block the board
gate. It is not for mainline submission. The motivations are reference quality
and defect surface:

- a context rule you can state beats per-site arguments about what is safe
  where;
- less hard-context work shrinks the gated-register-file wedge surface (the
  2026-07-29/30 stall class was unserialized MMIO reaching gated registers;
  hard handlers are the one context no mutex can reach);
- the checker's one-shot report costs all lockdep coverage after it. That is
  why the debug kernel disables it, and it is also why an unfiltered
  [`rewrite-kunit-qemu.sh`](../tests/rewrite-kunit-qemu.sh) run currently has
  no lockdep verdict past MPP case 58; and
- shorter interrupts-off windows for everything else on the SoC.

## Which handlers are true hard-IRQ

The first version of this plan said an explicit `request_threaded_irq`
primary is what stays in hard context on every kernel. That is not the rule.
The rule is **`IRQF_ONESHOT`** (with `IRQF_NO_THREAD` and `IRQF_PERCPU`):

- `irq_setup_forced_threading()` (kernel/irq/manage.c) returns early for those
  three flags. For any other action with both a primary and a thread function
  it creates a secondary action and threads the primary too.
- `__handle_irq_event_percpu()` (kernel/irq/handle.c) calls
  `lockdep_hardirq_threaded()` under exactly the same condition, which is what
  lets lockdep accept a `spinlock_t` in a force-threadable primary.

Applied to the registrations at the reviewed source:

| Registration | Flags | Context under the model |
| --- | --- | --- |
| MPP core IRQ: `rk_mpp_hw_irq` + `rk_mpp_hw_irq_thread` | `IRQF_ONESHOT` | **true hard-IRQ**: raw locks only |
| MPP AV1 AFBC aux IRQ: `rk_mpp_hw_aux_irq` | none | force-threadable: `spinlock_t` legal in this context |
| RGA2 core: `rk_rga_irq_handler` + thread | `IRQF_ONESHOT` | **true hard-IRQ** |
| RGA3 cores: same handler, shared with their IOMMU | `IRQF_SHARED` | force-threadable |

Two consequences. The RGA handler is one function with two registrations, so
it has to be clean for the strict one. And context is not the only source of a
report: a `spinlock_t` taken while **any** raw lock is held is the same
violation in every context, which is how the current MPP reports arise in
thread context and under KUnit.

## Current inventory (read at `94b3d97d6a12`)

### MPP

Both dispatchers hold the raw `hw->regs_lock` across the whole backend handler,
so that `rk_mpp_hw_power_off()` can exclude a handler that is mid-MMIO. Every
`spinlock_t` taken inside that window is a violation.

| Site | What it does | Violation |
| --- | --- | --- |
| `rk_mpp_hw_irq_register_lease_snapshot_locked()`, called by both dispatchers under `regs_lock` | reads the lease, then takes `hw->lock` to check that the leased generation is still the active one | `hw->lock` inside raw `regs_lock`, on every interrupt, in true hard-IRQ context for the core line |
| `rk_mpp_hw_record_irq_status()`, called by `rk_mpp_rkvdec2_irq` (both branches), `rk_mpp_av1_irq` and `rk_mpp_rkvenc2_irq` | takes `hw->lock` to fold the status and its lease tag into `hw->irq_status` | same |
| `rk_mpp_debug_record_active()`, called by `rk_mpp_av1_afbc_irq` | takes `hw->lock` to name the active job for the debug ring | `hw->lock` inside `regs_lock`; the context alone would allow it |
| `rk_mpp_hw_take_irq_status()`, `rk_mpp_hw_take_irq_job()`, `rk_mpp_hw_peek_irq_job()` | thread side: take `regs_lock`, then `hw->lock`, to read the record against the lease and claim the slot | `hw->lock` inside raw `regs_lock` in thread context. These are the two reports the 2026-11-23 QEMU run printed |

Clean at this source:

- `rk_mpp_rkvenc2_irq` is now read status, ack, mask the watchdog, record.
  The active-job lookup, `rk_mpp_rkvenc2_read_slice_len()`,
  `rk_mpp_rkvenc2_handle_bs_overflow()` and `rk_mpp_session_poll_notify()` run
  in `rk_mpp_rkvenc2_thread` under `run_lock`, and every nonzero status wakes
  the thread. This is the original Phase 2, already in the source.
- `hw->aux_lock` and `srv->debug_lock` are raw, and `aux_lock` nests inside
  `regs_lock`. The AV1 start path holds both across a
  `readl_poll_timeout_atomic()` bounded at 100 µs.
- The other `regs_lock` sections (power on and off, lease publish and
  invalidate, the hard-CCU fault-descriptor read) take no other lock.

So the whole remaining MPP problem is the IRQ record and the lease's
"still active" check, both of which reach for `hw->lock`.

### RGA

`rk_rga_irq_handler` runs entirely under `hw->job_lock`, a `spinlock_t`: the
regs-live gate, `rk_rga_hw_active_exec_locked()`, status decode and ack in
`rk_rga_hw_irq_status()` or `rk_rga_hw_clear_spurious_irq()`, and a clone of
the active reference into `hw->irq_ref` when it wakes the thread. On the RGA2
registration that is a `spinlock_t` in true hard-IRQ context. On the RGA3
registration the model allows it. The driver has no raw lock except
`debug_lock`; `regs_live_count` is owned by `job_lock`.

Unchanged supporting facts from the 2026-07-30 audit, not re-derived here:
`rk_rga_hw_irq_status()` and the spurious clear are MMIO and atomics, and
fence signalling is not reachable from the hard path.

## Alternatives considered and rejected

- **Make `regs_lock` a `spinlock_t`.** The nesting under it would become legal
  only in thread context. The core line is `IRQF_ONESHOT`, so its primary
  stays in hard-IRQ context and `hw->lock` there is still a report.
- **Make `hw->lock` a raw lock.** It has well over a hundred acquisition
  sites. Every section would have to be bounded and free of `spinlock_t`
  callees, which is the opposite of taking `hw->lock` out of the hard path.
- **Drop `IRQF_ONESHOT`** so the primaries become force-threadable and the
  checker goes quiet. That changes execution semantics rather than lock
  discipline. The MPP poll path relies on the line staying masked so the
  handler cannot run alongside the thread that completes the job, and the
  first version of this plan already ruled out "fixing" a handler by changing
  its registration.

## Phase 0 — measure and audit (no behavior change)

1. **Hard-context callee audit.** The inventory above was done by reading.
   Turn it into a check: enumerate every callee reachable from the two
   dispatchers and the RGA handler and classify each lock it takes. The
   [writer inventory](../tests/rewrite-writer-inventory.py) and
   [ownership audit](../tests/rewrite-ownership-source-audit.py) already pin
   the IRQ-snapshot and active-slot writers; extend them rather than adding a
   new tool.
2. **Slice-latency baseline.** Still wanted, for a different reason than
   before. The encoder slice work has already moved to the thread, and no
   slice-IRQ to poll-wake latency was recorded before or after. Add the
   debug-event pair and record p50/p99 for `mpi_enc_h264_slice` and
   `mpi_enc_h265_slice`, so the as-built trade has a number and later phases
   have a regression baseline.
3. The debug kernel's checker-disable stays until Phase 4. QEMU is the
   iteration tool: a stock `kunit.py` kernel has the checker on, one run takes
   about a minute warm, and each run still surfaces only the first report.

Exit gate: violation inventory reproduced by tooling; slice baseline recorded.

### Phase 0 progress recorded 2026-07-30 (audited at `aae815f145b27`)

Kept as dated record. The registration rule it stated is corrected in
[Which handlers are true hard-IRQ](#which-handlers-are-true-hard-irq).

- **Negative findings (audited clean then):** `rk_mpp_rkvenc2_read_slice_len()`
  and `handle_bs_overflow()` are MMIO plus job-field writes with no locks.
  `rk_rga_hw_irq_status()` and `clear_spurious()` are MMIO plus atomics; fence
  signalling is not reachable from the RGA hard path. `rk_mpp_job_put()` from
  hard context is safe even on the final reference. `srv->hw_lock` is a leaf,
  so `hw->run_lock → srv->hw_lock` introduces no inversion.
- **Landed early:** the debug-ring lock became raw in 6.18 `aae815f145b27`, as
  an any-context contract rather than a violation fix.

## Phase 1 — MPP: `regs_lock` owns everything the hard path reads

The original Phase 1 staged status in an `atomic_t` and folded it under
`hw->lock` at thread entry. The source has since tagged the recorded status
with a register lease (reset epoch and activation generation) so a status
recorded before a reset or for a retired activation is discarded. An atomic
word cannot carry that tag, so the design changes: keep the record, change
its owner.

1. **IRQ record.** `irq_status`, `irq_lease_recorded`, `irq_reset_epoch` and
   `irq_generation` are already read with `regs_lock` held at every site in
   the inventory. Make `regs_lock` their only owner:
   `rk_mpp_hw_record_irq_status()` stops taking `hw->lock`, and
   `rk_mpp_hw_clear_irq_record_locked()` asserts `regs_lock` instead.
2. **Lease "still active" check.** The snapshot takes `hw->lock` only to
   compare the leased generation with the active slot. Mirror that fact under
   `regs_lock`: each writer of `hw->active_ref` updates a `regs_lock`-owned
   copy of the active generation, or revokes the lease, while it holds
   `hw->lock`. There are four writers, all already under `hw->lock`:
   `rk_mpp_hw_install_active_locked()`, `rk_mpp_hw_claim_active_locked()`,
   `rk_mpp_hw_restore_active_locked()` and `rk_mpp_hw_commit_active_retry()`.
   The snapshot then reads only `regs_lock` state.
3. **Lock order becomes `hw->lock` → `regs_lock`.** A raw lock inside a
   `spinlock_t` is legal. The three thread-side takers swap their acquisition
   order, and the four writers above take `regs_lock` inside `hw->lock`.
   Nothing may keep the old order, or lockdep reports an inversion instead.
   A scan of the reviewed source found no function that takes `regs_lock`
   while it holds `hw->lock` today; cross-function nesting was not traced, so
   lockdep under QEMU is the check.
4. **AFBC debug record.** `rk_mpp_debug_record_active()` needs the active
   job's identity. Either record from the mirrored generation without the
   job and session ids, or move the record after the dispatcher drops
   `regs_lock`. Decide in implementation; the event is diagnostic.

Semantics to state in the commit: `irq_generation` is compared against the
mirror, not the live slot, so the mirror must be updated in the same
`hw->lock` section as the slot. A status recorded between a claim and the
mirror update must be discarded exactly as it is today.

KUnit, which is the proof for this phase:

- `rk_mpp_irq_register_lease_kunit` and `rk_mpp_iommu_fault_generation_kunit`
  already drive the snapshot and the IRQ claim; they are where the current
  reports fire.
- Add a case that calls `rk_mpp_hw_irq()` and `rk_mpp_hw_aux_irq()` on a
  fixture with fake MMIO. The dispatchers hold `regs_lock` themselves, so the
  checker sees the same wait-type limit a real interrupt imposes.
- Add a case for the mirror: a status recorded for a generation that was then
  claimed, restored, or replaced by a retry successor is not delivered.

Exit gate: an unfiltered `rewrite-kunit-qemu.sh` run exits 0 for the MPP suite
on both lines, with lockdep still enabled at the end; the manifest and both
source audits are regenerated in the same change; decode conformance on the
board is unchanged.

## Phase 2 — rkvenc2 slice work to thread (in the source, not yet qualified)

The move this phase described is present at the reviewed source: the hard
handler keeps status read, ack, the watchdog mask write and the record, and
returns `IRQ_WAKE_THREAD` for any nonzero status; the thread does the
active-job lookup, the slice-length reads, overflow handling and the poll
wakeup.

What is still owed is evidence, on the board:

- the Phase 0 slice-latency number, with zero overflow-count regression across
  the slice suites (the `INT_BS_OVERFLOW` path is the measured backstop); and
- encoder conformance including the slice and watchdog cases.

The record half of the encoder handler is covered by Phase 1.

Exit gate: slice benchmark recorded and within the agreed budget; encoder
conformance green on a kernel that carries Phase 1.

## Phase 3 — RGA claim/ack raw island (the careful one)

- `struct rk_rga_hw` gains `raw_spinlock_t irq_lock` and a staged status
  word; `regs_live_count` moves under `irq_lock`. The power paths swap lock
  type for the count transitions only. The sleeping clock prepare already sits
  outside the locked section, so the drain-then-gate contract documented at
  `rk_rga_hw_power_off` transfers unchanged.
- Hard handler becomes: `raw_spin_lock`; regs-live check; status MMIO read;
  claim decision **from MMIO status alone**; ack; stage; unlock;
  `IRQ_WAKE_THREAD` when claimed. Deciding from status alone is required on
  the RGA3 lines, which are shared with the RGA3 IOMMU and cannot be
  `IRQF_ONESHOT` without masking the peer.
- Everything that needs `job_lock` moves to `rk_rga_irq_thread`: active-exec
  attribution, the `hw->irq_ref` clone, spurious accounting, completion and
  fence work. The line-only RGA2 acknowledge added on 2026-11-22
  (`rk_rga2_line_irq_ack()`) stays in the hard handler; it is MMIO.
- The handler is shared by both registrations, so it is written for the
  strict one. Do not split it per core type.
- Requires an adversarial review pass on: peer IRQ while gated,
  ack-versus-clock-gate ordering, claim-versus-teardown, and spurious storms —
  the review shape the soft-CCU fix used.

KUnit proof: the RGA handler holds no raw lock of its own before this phase,
so a fixture cannot show the violation by calling it. Call it with a
test-local raw spinlock held, which imposes the hard-context wait-type limit;
the case reports before the phase and passes after.

Exit gate: no `spinlock_t` reachable from the RGA hard handler; an unfiltered
`rewrite-kunit-qemu.sh` run exits 0 for both suites; librga suite, demo
matrix, and the shared-IRQ cases green on the board.

## Phase 4 — enforce and retire the stopgap

- Revert `zz-rock5b-debug-locknest-prompt.patch` and the fragment's
  `PROVE_RAW_LOCK_NESTING` `opts_n` entry; the checker returns to its
  arm64-forced enabled state.
- The existing KUnit boot gate (`debug_locks == 1` from
  `/proc/lockdep_stats`, plus the fatal-signature interval scan) is then the
  per-boot proof that the contract holds. A checker report fails the gate
  immediately instead of silently blinding lockdep.
- Full conformance matrix and soak on a checker-enabled boot; slice numbers
  recorded beside the baseline. Real interrupts are the part QEMU cannot
  exercise, so this boot is the only proof of the true hard-IRQ paths.

Exit gate: green full matrix with lockdep alive end-to-end on a
checker-enabled kernel.

## Order rationale and commit strategy

Phase 1 first because it is confined to MPP, changes ownership of state the
code already guards twice, and is fully checkable under QEMU before any board
time is spent. Phase 2 is evidence only and rides the first board boot that
carries Phase 1. Phase 3 last among the code changes because claim and ack
correctness on a shared level line is safety-critical and gets the review
shape proven on Phase 1. Enforcement last, so the checker lands on drivers
already believed clean rather than as a bisect hazard.

Repo rules apply throughout: every commit replayed byte-identical to both
maintained branches, phases separately attributable and bisectable,
KUnit/manifest updates ride the phase that changes behavior, and each phase
closes with its own evidence before the next starts.
