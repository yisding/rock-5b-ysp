# rkvdec soft-CCU sibling power-on can cancel a peer core's recovery reset

> Scope: kernel-drivers/mpp — clean-room rewrite MPP driver, rkvdec2 soft-CCU
> reset/recovery path on RK3588 (ROCK 5B)
> Source: `linux-6.18-rkvenc` @ `rk3588-rewrite-6.18` d9992e32dc17 —
> `mpp_rewrite.c` `rk_mpp_hw_power_on()` (~:11388), `rk_mpp_hw_reset_active()`
> (~:11556), `rk_mpp_rkvdec2_power_on_ccu_cores()` (~:3096),
> `rk_mpp_rkvdec2_acquire_soft_ccu()` (~:11214); DT `rk3588-base.dtsi`
> Date: 2026-07-31
> Trust: **OBSERVED** (2026-08-01, two independent runs) + DESIGN,
> CODE-INSPECTED, CONFIG-INSPECTED for the mechanism. The race executes on this
> board: `reset_deassert_contended_count` moved by 2 in each of two 60 s runs on
> the counter kernel (`7e4cbb95f897`, booted as `#26`), against a measured
> expectation of ~3.0 per run. **The fix (`b37f6e9825b1`) is booted and
> verified** — 26,438 resets across six post-lock runs against a cumulative
> expectation of 19.19 produced zero contention, p ≈ 4.6e-9. Both steps of the
> verification gate are closed.

## Result

`rk_mpp_hw_power_on()` deasserts the target core's reset unconditionally:

    mpp_rewrite.c:11388   ret = reset_control_deassert(hw->resets);

It runs on **every** call, not only on a 0 → 1 power transition — `power_count`
is incremented afterwards at ~:11397 and never consulted first — and the
controls are `devm_reset_control_array_get_optional_exclusive()` (~:16699). For
*exclusive* controls `reset_control_deassert()` always drives the hardware;
there is no shared refcount to defer it.

`rk_mpp_hw_reset_active()` pulses the same line:

    mpp_rewrite.c:11556   reset_control_assert() / udelay(10) / reset_control_deassert()

`rk_mpp_rkvdec2_acquire_soft_ccu()` reaches `power_on()` for **sibling** cores
via `rk_mpp_rkvdec2_power_on_ccu_cores()` (call at ~:11270), holding only the
*submitting* core's `run_lock`; `srv->hw_lock` is dropped before the power loop
at ~:3116. A sibling's own reset pulse runs under that sibling's `run_lock`. No
lock is common to the two paths, so they can overlap:

    core0: submit -> acquire_soft_ccu -> power_on(core1) -> deassert(core1)
    core1: timeout/error -> reset_active(core1) -> assert .. udelay(10) .. deassert

core0 can end core1's pulse a couple of microseconds into the intended ten.
core1's own deassert then no-ops, `reset_active()` returns 0, `stop_active()`
returns 0, and the job is completed as recovered — with the core never having
been reset. Latched error and DMA state survives into the next job on that core:
corrupt output, or no completion interrupt and a watchdog timeout per frame.

Reachable on this board, not merely in the abstract:

- `rkvdec-ccu@fdc30000` has `rockchip,ccu-mode = <1>` in the live device tree,
  and `RK_MPP_RKVDEC_CCU_MODE_SOFT` is `1` (`mpp_rewrite.c:98`). The soft-CCU
  path is the one in use.
- The sibling power-on at ~:11270 is on that soft path, despite the
  "HARD-CCU chain" wording in the comment at ~:3118, which describes the
  *other* caller (~:12242).
- Reset controls are per-core and distinct: `video-codec@fdc38000` takes
  `SRST_A_RKVDEC0`/`SRST_H_RKVDEC0` and `video-codec@fdc40000` takes
  `SRST_A_RKVDEC1`/`SRST_H_RKVDEC1`. So the only cross-core writer of a core's
  reset line is this sibling power-on path, and keying any serialisation on the
  CCU node is correct.

`power_off()` never asserts (~:11406), so the pulse is the only thing this can
corrupt.

## Observed (2026-08-01)

Two independent 60 s runs on the counter kernel, same default workload:

| Run | Resets | Deasserts | Expected | **Contended** |
|---|---|---|---|---|
| `20260801-143058` | 4312 | 34824 | 3.020 | **2** |
| `20260801-143312` | 4267 | 34337 | 2.939 | **2** |

Four hits against a combined expectation of 5.96 — under Poisson an
unremarkable outcome (P(X=4 | λ=5.96) ≈ 0.14), so the measurement agrees with
the model rather than merely clearing zero.

A hit cannot be a same-core artifact. The counter increments only when
`power_on()` deasserts a core whose `reset_pulse_active` is set, and a core's
own submit path holds its `run_lock` across both of its power-on calls while
its reset runs in its IRQ thread under that same lock. Every hit is therefore a
sibling core ending a peer's recovery pulse early — the sequence sketched
above. The pulse flag is still outside the domain lock on this kernel, so this
is a true pre-fix signal and not the stale post-fix one deviation 3 guards
against.

## Boundary

Frequency is low and workload-specific: ~2 hits per ~4300 resets, and those
resets exist only because the harness feeds deliberately corrupt streams. No
field failure has been attributed to this, and no decode corruption observed to
date has been traced to it.

The two measurement attempts on 2026-07-31, kept because they explain why the
first runs read as negatives when the race was in fact reachable:

1. **The first run measured nothing.** `EXPECT=contended` reported a zero delta
   and the harness read that as "the race may not be reachable in this
   configuration". It was not: `reset_count` moved by **0** over the whole run.
   No core was reset, so the contention counter had nothing to contend with.
   The kill-based provocation was ~3 orders of magnitude too weak — 40 kill
   cycles produced 1 abort, because a victim spends ~12 ms of its ~300 ms life
   on hardware and only an in-flight job reaches the abort reset path.
2. **The second run measured the wrong side.** After the harness was rebuilt to
   drive resets from the decode error path (below), the same workload produced
   **3923 resets in 60 s** against 7944 submits — and still a zero contention
   delta. That is *not* evidence against the mechanism. The run's expected-hit
   figure of ~5 uses the submit rate as a stand-in for the rate at which a
   sibling deasserts a given core, and that stand-in is an upper bound:
   `rk_mpp_rkvdec2_acquire_soft_ccu()` calls `power_on_ccu_cores()` only when
   the job has no power hold yet, and
   `rk_mpp_rkvdec2_transfer_powered_ccu_cores()` (~:3479) hands an existing hold
   to the next queued job on the coordinator. Pipelined jobs therefore power the
   group up once and inherit it, and the true deassert rate is lower by a factor
   nobody has measured. With that factor unknown the expected hits are unknown,
   and a zero is unremarkable.

The counter on the deassert side is what closed it — but only after a third
correction on 2026-08-01, because the estimator was also counting a core's own
deasserts, which cannot contend, and so overstated the expectation by 3x. With
the counter booted and the estimator narrowed, the very next run produced a
non-zero. Both earlier zeros were under-powered measurements reported as
results, which is the failure this harness exists to prevent.

One fact the second run did establish: the practical reset source on this path
is not the abort or the watchdog but the **decode error interrupt**. The soft-CCU
IRQ thread resets the core whenever `irq_status & err_mask` (~:14386, mask
`0xf0` at ~:1540), and a stream with damaged slice payloads reaches it a few
times per decode — enough for thousands of resets a minute where killing
decoders produced none.

Says nothing about the encoder (rkvenc2 has its own CCU and was not analysed
for this), about hard-CCU mode, or about single-core configurations. Does not
establish that any observed decode corruption to date was caused by this; no
field failure has been attributed to it.

## Root cause

A core's reset line is a shared resource with two independent writers and no
serialisation between them. The driver treats "deassert" as an idempotent
part of powering a block up, which is true in isolation but false while a peer
is mid-pulse.

## Fix

Implemented on `rk3588-rewrite-6.18` as three commits, and mirrored to
`rk3588-rewrite-mainline` because the driver is kept byte-identical across both
trees:

- **`3b7082bf3547` / `b868f5449748`** — test prep, no driver change. Two KUnit
  tests held both a `struct rk_mpp_service` and a `struct rk_mpp_hw` on the
  stack, close enough to the 2048-byte `-Wframe-larger-than=` limit that adding
  96 bytes of counters to the service tripped it. They now `kunit_kzalloc()` the
  service like they already do the session and device. This has to come *first*,
  because the counter commit is booted on its own and must build clean alone.
- **`7e4cbb95f897` / `b127a72c9be8`** — instrumentation only, the step-0 counter
  below. `reset_deassert_count` and `reset_deassert_core_count` record the
  deasserts `power_on()` issues, and `reset_core_count` splits the existing
  `reset_count` the same way, so both terms of the expected-overlap product can
  be read per core instead of one being guessed from the submit rate.
- **`b37f6e9825b1` / `a54ac6cb0c71`** — the per-reset-domain lock described
  below.

Three deviations from the shape sketched here, all deliberate:

1. The domain lock lives in a small keyed table in `struct rk_mpp_service`, not
   as a pointer resolved at CCU attach into the coordinator's `struct
   rk_mpp_hw`. Cores find their coordinator by walking the service list, and
   `rk_mpp_hw_remove()` can take it away while cores still reference it, so a
   mutex embedded in the coordinator is a use-after-free waiting for a CCU
   unbind. Device nodes outlive the domains, so a table that only ever grows is
   enough. It is resolved in probe, before `rk_mpp_hw_read_id()` first powers
   the core on and before the core joins the service list.
2. No `reset_domain_lock_self`. `struct rk_mpp_hw` gains only the pointer, and a
   core outside a CCU group is left unbound rather than given a private mutex:
   `rk_mpp_rkvdec2_power_on_ccu_cores()` selects on `ccu_node` and so never
   reaches such a core, leaving its own submit and recovery paths as the only
   writers of its reset line — and those already serialize on its `run_lock`. An
   embedded mutex would also have grown every `struct rk_mpp_hw` a KUnit test
   builds on the stack by ~200 bytes, which is what pushed two of them over the
   frame limit before this was changed.
3. `reset_pulse_active` moved *inside* the lock, and `power_on()` reads it while
   holding the same lock. Without that, a pulse merely queued behind the lock
   would still be visible to the reader and counted as interference, so
   `reset_deassert_contended_count` would keep incrementing after the race was
   fixed and step 2 below could never pass. With it, the counter is a true
   regression signal: any non-zero afterwards means the serialization broke.

**Not covered.** `rk_mpp_rkvdec2_force_stop_ccu()` (~:12975) asserts and
deasserts every core in the group directly rather than through
`rk_mpp_hw_reset_active()`, so the hard-CCU recovery path keeps its own
unserialized writer of the same lines. That path is not in use on this board —
`ccu-mode 1` selects soft CCU — and covering it means holding the domain lock
across a group-wide pulse whose loop calls `handle_reset_failure()` and
`terminal_isolate()`, a different critical section that belongs in its own
change.

The original proposal follows, unchanged, as the rationale: a per-reset-domain
mutex — the domain being a CCU group — taken as an **innermost leaf** around
reset-control operations only:

- `rk_mpp_hw_reset_active()`: lock → assert → udelay → deassert → unlock.
- `rk_mpp_hw_power_on()`: lock → deassert → unlock, around the deassert alone,
  not around `pm_runtime_resume_and_get()` or `clk_bulk_prepare_enable()`.

Deadlock-free by construction: both critical sections touch nothing but the
reset controller and take no further locks. A concurrent `power_on` then lands
either wholly before the pulse (which re-asserts afterwards) or wholly after it
(a redundant deassert of an already-deasserted line). Both are correct.

All callers are sleepable — threaded IRQ handlers, work items, ioctl paths; no
hardirq caller exists — so a `struct mutex` is viable, and `udelay(10)` under it
is what the code already does under `run_lock`.

Scope the lock to cores with a CCU group (`hw->ccu_node != NULL`). A core with
no group has no second writer, and `power_on()` is on the per-submit path, so a
single global reset mutex would add contention across encoder, decoder and AV1
for no benefit.

Implementation shape:

1. `struct rk_mpp_hw` gains `struct mutex reset_domain_lock_self` plus a
   `struct mutex *reset_domain_lock` pointing at the domain's shared lock, or at
   its own when there is no group.
2. Resolve the pointer at CCU attach, which already handles probe ordering with
   `-EPROBE_DEFER`.
3. Route both sites through small helpers so no call site open-codes the
   pairing. Keep `handle_reset_failure()` outside the lock — it takes
   `srv->hw_lock` and must not nest under a leaf.
4. Optional, separately reviewable: make `power_on()` skip the deassert when it
   did not perform the 0 → 1 transition. That removes a pointless MMIO write per
   submit and shrinks the window independently, but it is a behaviour change on
   the sibling path and belongs in its own commit so it can be reverted alone.

## Verification gate

Ordered, because a passing functional test after a timing fix proves nothing on
its own:

0. **Instrument the deassert side.** Done — `7e4cbb95f897`. Counts the
   deasserts `power_on()` issues on a core, so the harness can compute expected
   hits from two measured rates instead of standing the submit rate in for one
   of them. Without it a zero in step 1 cannot be told apart from a run that
   never had the power to produce a non-zero — which is exactly what happened on
   2026-07-31, twice, for two different reasons. Instrumentation only, so it
   lands on its own.

   **Boot this commit alone first.** It is the last point at which the
   before-measurement can be taken; once `b37f6e9825b1` is in, the pre-fix
   deassert and contention rates are gone for good and step 2 can never be more
   than a guess.
1. **Reachability, before any behaviour change. Done — 2026-08-01**, two runs,
   2 hits each against ~3.0 expected (see Observed above). `sudo EXPECT=contended
   bash kernel-drivers/tests/rewrite-reset-contention.sh` must show a non-zero
   `mpp:reset_deassert_contended_count` delta on a kernel carrying d9992e32dc17.
   The harness drives resets from the decode error path and reports
   `reset_count`, the submit rate, and the expected hits alongside the
   contention count; it exits `78` INCONCLUSIVE when no reset happened or the
   expectation is too low, because a zero is evidence only if the run could have
   produced a non-zero. If it stays zero against an expectation built on step
   0's *measured* deassert rate, the fix is not justified and the reachability
   claim above is wrong.
2. **Regression, after the lock** (`b37f6e9825b1`). **Done — 2026-08-01**, on
   `#27 … gb37f6e9825b1`, driven by
   `kernel-drivers/tests/rewrite-reset-lock-gate.sh`. Six runs of the same
   workload that produced step 1's hits:

   | Run | Resets | Expected | Contended |
   |---|---:|---:|---:|
   | `155410` (5 s sample) | 426 | 0.316 | 0 |
   | `155544` (`EXPECT=clean`) | 4907 | 3.987 | 0 |
   | `155714` | 5060 | 4.020 | 0 |
   | `155842` | 5251 | 3.830 | 0 |
   | `160011` | 5402 | 3.525 | 0 |
   | `160140` | 5392 | 3.512 | 0 |
   | **total** | **26,438** | **19.19** | **0** |

   P(0 | λ=19.19) ≈ **4.6e-9**. Against 4 hits at λ=5.96 before the lock, the
   serialization does what it was written to do. The counter is a true signal
   here rather than a stale one only because the pulse flag moved inside the
   lock; see deviation 2 above.

   Aggregating across runs is what made this decisive — no single run has the
   power, and each run is an independent Poisson trial on the same workload.
3. **No perturbation.** `mpp-suite.sh` plus the encode/decode/transcode tests on
   the KASAN kernel, watching decoder `hw_total_ns`/`hw_max_ns` — a leaf lock on
   the submit path should not move them measurably. If it does, the domain
   scoping is wrong.

## Why it matters / follow-up

The failure mode is the bad kind: recovery reports success while leaving the
core unrecovered, so the damage surfaces later as corrupt output or a stalled
core with nothing in the log tying it back. It also undermines every other
recovery path, since they all funnel through `rk_mpp_hw_stop_active()`.

Sequence after the current kernel is validated; this touches the reset path
recovery depends on and should land on a known-good baseline with step 1's
evidence in hand.
