# Minimal hard-IRQ architecture plan (RT-nesting cleanup)

> Status: scoped, not started; supersedes the `PROVE_RAW_LOCK_NESTING`
> disable at its final phase
> Scope: clean-room MPP/RGA rewrite drivers' interrupt paths
> Source reviewed: `rk3588-rewrite-6.18@600d6e2fb6a49` (all five hard
> handlers, both thread dispatchers, poll/debug/fence/regs-live helpers)
> Pairs with: [`2026-07-30 soft-CCU finding`](../../findings/2026-07-30-rewrite-soft-ccu-split-critical-section-h265-wedge.md)
> Date: 2026-07-30

> **Current boundary (2026-08-04):** this remains a target architecture plan,
> not the as-built interrupt model. Its inventory is pinned to the source above;
> no phase is claimed complete at maintained tips `19634f4eebba` /
> `b296374b7520`. Read the
> [current architecture guide](rewrite-driver-architecture/README.md) before
> using this plan to interpret present source.

## Result

One architectural contract, stated in a sentence and enforced by lockdep:
**a hard IRQ handler may only claim, ack, and stage; every other action —
job attribution, slice reads, wakeups, fences, accounting — happens in
thread context.** When the plan completes, `PROVE_RAW_LOCK_NESTING`
returns to its (arm64-forced) enabled state and the existing KUnit boot
gate's live-lockdep requirement proves the property on every boot.

This is not for mainline submission. The motivations are reference
quality and defect surface:

- a context rule you can state beats 40 per-site arguments about what is
  safe where — exactly the "easily maintained" goal;
- less hard-context MMIO shrinks the gated-register-file wedge surface
  (the 2026-07-29/30 stall class was unserialized MMIO reaching gated
  registers; hard handlers are the one context no mutex can reach);
- the RT-nesting checker's one-shot report currently costs an entire
  boot's lockdep coverage — after this plan it becomes a free invariant
  check instead of a landmine; and
- shorter interrupts-off windows for everything else on the SoC.

## Current inventory (source-verified)

| Handler (hard context) | Work done today | Violations |
|---|---|---|
| `rk_mpp_rkvdec2_irq` | link/core `INT_STA` read+ack; OR into `hw->irq_status` under `hw->lock` | `hw->lock` (`spinlock_t`; the report that fired 2026-07-30) |
| `rk_mpp_av1_irq` | `INT_STA` read+ack; same OR | `hw->lock` |
| `rk_mpp_av1_afbc_irq` | pm-runtime guard; AFBC ack; debug-ring record | none under the current registration (plain `devm_request_irq`, force-threadable — see Phase 0 progress); `debug_lock` hardened to raw anyway as any-context contract (`aae815f145b27`) |
| `rk_mpp_rkvenc2_irq` | `INT_STA` read+ack; watchdog mask; `rk_mpp_hw_get_active_job` (**`hw->lock`**); `rk_mpp_rkvenc2_read_slice_len` slice-FIFO MMIO; `handle_bs_overflow`; `rk_mpp_session_poll_notify` (**`wake_up_all` on a waitqueue** — core-kernel `spinlock_t`, unconvertible); status OR under `hw->lock`. Slice-only IRQs complete **without waking the thread**. | `hw->lock` ×2, waitqueue lock, possibly `debug_lock` |
| `rk_rga_irq_handler` | under `hw->job_lock`: regs-live gate, status MMIO decode/ack (`rk_rga_hw_irq_status`), job attribution, spurious clear | `hw->job_lock` (`spinlock_t`); fence-signal reachability from the hard path to be pinned in Phase 0 |

Supporting facts: `rk_mpp_session_poll_notify()` is `atomic64_inc` +
`wake_up_all(&session->wait)`; `rk_mpp_hw_get_active_job()` takes
`hw->lock` and refs the job; RGA `regs_live_count` transitions are short
`job_lock` sections deliberately separated from the sleeping
`clk_bulk_prepare_enable` (the drain-then-gate contract documented at
`rk_rga_hw_power_off`).

## Phase 0 progress (2026-07-30, audited at `aae815f145b27`)

- **The registration distinction that scopes the whole plan:** lockdep's
  wait-context model (`task_wait_context()`, kernel/locking/lockdep.c)
  relaxes hardirq context to `LD_WAIT_CONFIG` for handlers that
  force-threading would move to a thread on PREEMPT_RT — i.e.
  `spinlock_t` is *permitted* in a plain `devm_request_irq` handler
  without `IRQF_NO_THREAD` (on RT it runs threaded). Only **explicit
  `request_threaded_irq` primaries** stay true-hardirq on every kernel
  and are held to `LD_WAIT_SPIN`. Consequences: the AFBC aux handler
  (`devm_request_irq`, `IRQF_SHARED`) is *not* a violation site — its
  `pm_runtime_get_if_in_use()` (`dev->power.lock`) and debug-ring calls
  are legal under the model — and the complete violation inventory is
  exactly the five explicit primaries in the table above. It also means
  Phases 1–3 must not "fix" a handler by silently converting an
  explicit primary to a plain handler: that changes RT execution
  semantics, not just lint.
- **Negative findings (audited clean):**
  `rk_mpp_rkvenc2_read_slice_len()` and `handle_bs_overflow()` are pure
  MMIO + job-field writes, no locks — so Phase 2's only dirty items are
  `get_active_job`, the status OR, and `poll_notify`; the slice FIFO
  reads themselves are context-legal and *may* stay in the hard handler
  with staged lengths if the benchmark argues for it (decide in
  implementation). `rk_rga_hw_irq_status()`/`clear_spurious()` are pure
  MMIO + atomics; fence signalling is not reachable from the RGA hard
  path — the Phase 3 raw island is exactly as scoped.
  `rk_mpp_job_put()` from hard context is safe even on final reference
  (`rk_mpp_job_release` is kfree-only; heavyweight teardown lives on
  explicit completion paths). Lock-order check of the 2026-07-30
  group-power fix: `srv->hw_lock` is a leaf (no section takes a
  run/recovery/session lock inside), so `hw->run_lock → srv->hw_lock`
  introduces no inversion.
- **Landed early:** the debug-ring conversion (Phase 1's `debug_lock`
  item) is committed as 6.18 `aae815f145b27` — reframed as contract
  hardening, not a violation fix, per the registration distinction
  above (true-hardirq recording from the explicit primaries is the
  instrumentation the wedge hunts want, and it becomes legal by
  construction). Mainline replay pending (that worktree carries
  in-flight DCHS lifecycle work).

## Phase 0 — measure and audit (no behavior change)

1. **Slice-latency baseline.** Add a debug-event pair timestamping
   slice-IRQ → poll-wake (existing `rk_mpp_debug_record_*` ring + one new
   event type), and a harness reader that reports p50/p99 for the
   `mpi_enc_h264_slice` / `mpi_enc_h265_slice` cases. Record the baseline
   on the current kernel. Phase 2's budget is set from this number, not
   guessed.
2. **Hard-context callee audit.** Extend the source-audit tooling (or a
   one-shot script) to enumerate every callee reachable from the five
   hard handlers and classify each lock it takes. Deliverable: the
   violation table above completed with file:line, including the
   `debug_lock` record sites and whether `rk_rga_fence_signal` is
   reachable from `rk_rga_hw_irq_status`.
3. The qualification checker-disable stays in place until Phase 4; dev
   iterations may re-enable `PROVE_RAW_LOCK_NESTING` locally, but the
   audit script is the enumeration tool (each boot only surfaces one
   report).

Exit gate: baseline recorded in the evidence tree; violation inventory
complete.

## Phase 1 — decoder staging (rkvdec2 + av1 + afbc fully clean)

- `struct rk_mpp_hw` gains `atomic_t staged_irq_status`.
- `rk_mpp_rkvdec2_irq` (both branches) and `rk_mpp_av1_irq` replace
  lock+OR with `atomic_or(status, &hw->staged_irq_status)`.
- `rk_mpp_hw_irq_thread()` (the single dispatcher) folds
  `atomic_xchg(&hw->staged_irq_status, 0)` into `hw->irq_status` under
  `hw->lock` before `ops->thread` dispatch. Semantics note for the
  commit: status bits become lock-visible at thread entry rather than at
  hard-IRQ time; a bit staged after a consumer's clear resurfaces at the
  next fold and routes through the existing spurious/late accounting —
  observably equivalent to today's post-clear OR.
- Debug ring: convert `srv->debug_lock` to `raw_spinlock_t` — the
  critical section is a bounded ring-slot struct copy, one of the few
  legitimate raw uses — so `rk_mpp_debug_record_*` stays callable from
  every context including the AFBC hard handler.
- KUnit: a staging-fold case (manifest regenerates per the Phase-6
  rationalization contract, now routine).

Exit gate: audit reports zero `spinlock_t` acquisitions reachable from
the rkvdec2/av1/afbc hard handlers; decode conformance and the KUnit
gate green.

## Phase 2 — rkvenc2 slice work to thread (the deliberate trade)

- Hard handler keeps: reg-validity checks, `INT_STA` read, `INT_CLR`
  ack, the watchdog mask write (pure MMIO), `atomic_or` staging. It
  returns `IRQ_WAKE_THREAD` for **any** nonzero status — slice-only
  interrupts, which today complete entirely in hard context, newly wake
  the thread.
- Moves to the thread's front half: `get_active_job`, the
  `read_slice_len` loop, `handle_bs_overflow`, `poll_notify`.
- Risk analysis to carry in the commit: slice FIFO tolerance vs. thread
  latency (IRQ threads run `SCHED_FIFO`; slice spacing at conformance
  rates is ~ms against µs-scale thread wake), with the existing
  `INT_BS_OVERFLOW` path as the measured backstop.
- Gate on the Phase 0 metric: proposed budget p99 slice-ready→wake delta
  under the agreed threshold (set from baseline) and zero
  overflow-count regression across the slice suites.

Exit gate: rkvenc2 hard path lock-free; slice benchmark within budget;
encoder conformance including slice and watchdog cases green.

## Phase 3 — RGA claim/ack raw island (the careful one)

- `struct rk_rga_hw` gains `raw_spinlock_t irq_lock` and a staged status
  word; `regs_live_count` moves under `irq_lock` (the power paths swap
  lock type for just the count transitions — the sleeping clk prepare
  already sits outside the locked section, so the drain-then-gate
  contract transfers unchanged).
- Hard handler becomes: `raw_spin_lock`; regs-live check; status MMIO
  read; claim decision **from MMIO status alone** (required on the level
  line shared with the RGA3 IOMMU — `IRQF_ONESHOT` would mask the peer);
  ack; stage; unlock; `IRQ_WAKE_THREAD` when claimed.
- Job attribution, spurious accounting, and all completion/fence work
  move to `rk_rga_irq_thread` under `job_lock`, guided by the Phase 0
  split of `rk_rga_hw_irq_status`.
- Requires an adversarial review pass on: peer IRQ while gated,
  ack-vs-clock-gate ordering, claim-vs-teardown, and spurious storms —
  the same review shape the soft-CCU fix used.

Exit gate: no `spinlock_t` reachable from the RGA hard handler; librga
suite, demo matrix, and the shared-IRQ cases green.

## Phase 4 — enforce and retire the stopgap

- Revert `zz-rock5b-debug-locknest-prompt.patch` and the fragment's
  `PROVE_RAW_LOCK_NESTING` `opts_n` entry; the checker returns to its
  arm64-forced enabled state.
- The existing KUnit boot gate (`debug_locks == 1` from
  `/proc/lockdep_stats`, plus the fatal-signature interval scan) is now
  the per-boot proof that the contract holds — a checker report would
  fail the gate immediately instead of silently blinding lockdep.
- Full conformance matrix + soak on a checker-enabled boot; slice
  numbers recorded beside the baseline.

Exit gate: green full matrix with lockdep alive end-to-end on a
checker-enabled kernel.

## Order rationale and commit strategy

Phase 1 before 2 because the staging pattern and fold semantics get
proven on handlers whose hard bodies are trivially relocatable; 2 before
3 because the benchmark machinery and the "move work to thread" review
shape get exercised on a single-driver change before the shared-line
driver where claim/ack correctness is safety-critical. Enforcement last,
so the checker lands on a driver already believed clean rather than as a
bisect hazard.

Repo rules apply throughout: every commit replayed byte-identical to
both maintained branches, phases separately attributable and bisectable,
KUnit/manifest updates ride the phase that changes behavior, and each
phase closes with its own conformance evidence before the next starts.
