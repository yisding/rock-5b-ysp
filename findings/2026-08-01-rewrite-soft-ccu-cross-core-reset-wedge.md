# Soft-CCU bus-stall wedge returns on the error-reset path; needs two cores of one group resetting

> Scope: MPP rewrite driver (rkvdec2 soft-CCU recovery path); harness
> `kernel-drivers/tests/rewrite-reset-contention.sh` on ROCK 5B
> Source: booted kernel `6.18.41-video-rewrite-kasan-rockchip64` `#26`
> `g7e4cbb95f897` (`rk3588-rewrite-6.18`, the deassert-counter commit) —
> `mpp_rewrite.c` `rk_mpp_rkvdec2_reset_soft_ccu_job()` (~:11649),
> `rk_mpp_hw_reset_active()` (~:11575), `rk_mpp_rkvdec2_acquire_soft_ccu()`
> (~:11231), `rk_mpp_rkvdec2_thread()` (~:14362)
> Date: 2026-08-01
> Trust: MEASURED (two wedges, two clean runs, per-core counters, armed
> panic sysctls silent) + SOURCE-INSPECTED (what the CCU lock does and does
> not cover) + **MECHANISM OPEN** — unlike
> [2026-07-29](2026-07-29-rewrite-soft-ccu-dual-core-wedge.md) and
> [2026-07-30](2026-07-30-rewrite-soft-ccu-split-critical-section-h265-wedge.md)
> there is no root cause here yet, only a discriminator

## Result

Driving the rkvdec2 soft-CCU error-reset path hard wedges the board, with the
same silent bus-stall signature as the two 2026-07-29/30 wedges — on a kernel
that carries **all** of their fixes (`eb78ceed2fd67`, `be14140d6edcb` and
`600d6e2fb6a49` are all ancestors of the booted `7e4cbb95f897`).

Signature, identical to the earlier two: full-system stall, no panic, no
oops, no KASAN report, no stall report, journal stops mid-flush, recovery only
by the 89 s Synopsys DesignWare hardware watchdog. `/sys/fs/pstore/` was empty
after the first wedge. Decisively, the second wedge ran with
`hung_task_panic=1`, `hung_task_timeout_secs=30`, `softlockup_panic=1` and
`panic_on_rcu_stall=1` armed 48 s beforehand, and **none of them fired** — no
CPU was executing, so this is a bus-level stall rather than a software hang.

Four runs on the same boot image separate the trigger:

| Time | Config | Resets (core0/core1) | Outcome |
|---|---|---|---|
| 11:12:36 | 2 err, 2 surv, kill=1, 60 s | 5092 (2548/2544) | completed |
| 11:20:57 | 2 err, 2 surv, kill=1, 300 s | — | **WEDGED** |
| 11:31:55 | 2 err, 0 surv, kill=0, 60 s | — | **WEDGED** |
| 13:28:36 | 1 err, 0 surv, kill=0, 60 s | 936 (936/0) | completed |
| 14:30:58 | 2 err, 2 surv, kill=1, 60 s | 4312 (2139/2173) | completed |
| 14:33:12 | 2 err, 2 surv, kill=1, 60 s | 4267 (2143/2124) | completed |

Two ingredients are excluded outright. The 11:31 wedge ran with
`RESET_SURVIVORS=0 RESET_KILL=0`, so neither the clean-stream sibling submits
nor the session-abort/kill path is required — corrupt streams driving error
IRQs are sufficient on their own.

The discriminator is sharper than "two cores active". The single-error-stream
run still dispatched to **both** cores of the group —
`dispatched_rkvdec_core0_count` 1877 against `core1` 1876 — but every one of
its 936 resets landed on core0 and `reset_rkvdec_core1_count` stayed at **0**.
It did not wedge. Both wedging configurations had both cores resetting
concurrently (2548 and 2544 in the comparable completed run). The variable that
tracks the wedge is therefore **concurrent resets on two cores of one soft-CCU
group**, not merely two cores being in use.

That is the same precondition as the
[sibling reset-deassert race](2026-07-31-rkvdec-sibling-reset-deassert-race.md),
which makes the pending reset-domain lock a candidate cure for both — see
Prediction.

## What is and is not serialized

`rk_mpp_rkvdec2_reset_soft_ccu_job()` takes `ccu->run_lock` and holds it across
the coordinator `CORE_IDLE`/`CORE_ERR` writes *and* the
`rk_mpp_hw_stop_active()` → `rk_mpp_hw_reset_active()` pulse
(assert / `udelay(10)` / deassert). So two cores' recovery resets are already
serialized against each other, and against the submit path's programming
window, which the 07-30 fix made a single continuous `ccu->run_lock` hold.

`rk_mpp_rkvdec2_acquire_soft_ccu()` is **not** under that lock. It performs the
CCU lookup and `rk_mpp_rkvdec2_power_on_ccu_cores()` — the group-wide power-on
whose per-core `reset_control_deassert()` is the second writer of the reset
lines — before the coordinator lock is ever taken. The hard IRQ handler
`rk_mpp_rkvdec2_irq()` also reads `INT_STA` and writes its ack under only the
per-core `spinlock_t hw->lock`, outside any CCU serialization by construction;
the 07-30 finding already named that as the leading residual candidate after
the whole-sequence lock failed to cure the h265 wedge.

Both remain live candidates. The measurement does not yet distinguish them, and
no MMIO-to-a-block-in-reset has been caught in the act.

## Evidence and reproduction

- Wedge artifacts (`counters-before.tsv` present, no `counters-after.tsv`):
  `rock-5b/rockchip-conformance/logs/rewrite/20260801-112057-reset-contention/`
  and `.../20260801-113155-reset-contention/`.
- Clean comparators with full per-core counters:
  `.../20260801-111236-reset-contention/` and
  `.../20260801-132836-reset-contention/`.
- Exact wedging command (second wedge, from the sudo audit trail):
  `sudo RESET_DURATION_S=60 RESET_ERROR_STREAMS=2 RESET_SURVIVORS=0 RESET_KILL=0 bash kernel-drivers/tests/rewrite-reset-contention.sh`
  (`RESET_ERROR_STREAMS` defaults to 2, so it was omitted on the day).
- Clean single-core-reset comparator: the same line with
  `RESET_ERROR_STREAMS=1`.
- Time to wedge is short and probabilistic: ~10–20 s into the 300 s run,
  somewhere inside the 60 s provocation of the 11:31 run. One
  two-error-stream run of 60 s completed, so it is not deterministic.

## Boundary

**The clean single-stream run is n=1 and under-exposed.** It produced 936
resets against the comparable two-stream run's 5092 — 5.4× less exposure — so a
purely per-reset hazard with no cross-core component is not yet excluded by it.
Equalizing exposure (`RESET_ERROR_STREAMS=1` for ~330 s, or several repeats)
is the missing control, and until it is run the discriminator is suggestive
rather than established.

Mechanism is unproven. Nothing here identifies which MMIO stalls, and the
gating model is inherited from the 07-29 finding where it was already marked
INFERRED rather than TRM-proven.

Says nothing about hard-CCU mode (`ccu-mode 1` selects soft CCU on this board),
about rkvenc2, or about whether any of this is reachable under normal decode —
the harness deliberately feeds corrupt streams to make error resets thousands
of times more frequent than they would otherwise be.

The forward-port driver is unaffected by construction: this is rewrite-only
code, and the forward-port profile has never shown this signature.

Across the five two-error-stream runs on record, two wedged and three
completed, so the wedge rate is roughly one in three rather than anything
approaching certain. That is why a single clean run proves little, and why the
13:28 single-stream comparator needs repeating before it can carry weight.

## Post-lock result (2026-08-01, `#27` `gb37f6e9825b1`) — suggestive, not settled

Five consecutive runs of the two-stream provocation on the reset-domain-lock
kernel **all completed**: `155544`, `155714`, `155842`, `160011`, `160140`,
plus the 5 s sample at `155410`. No wedge, no watchdog reset.

That is encouraging and it is **not proof**. Against the pre-lock rate of two
wedges in five runs, five consecutive survivals would happen by chance with
probability 0.6⁵ ≈ **0.08** (or 0.13 if the true rate is 1 in 3). Suggestive at
best; the honest reading is "consistent with the lock having fixed it, and also
consistent with a run of luck".

If it holds up it is the more important half of the story, because it would
mean the wedge *was* the sibling power-on deassert overlapping a reset pulse —
the first candidate below — and the hard-IRQ MMIO candidate is not needed to
explain anything. Ten to fifteen more clean runs would take this from
suggestive to convincing; `WEDGE_RUNS=12` on the gate is the way to get them.

## Prediction (partially borne out)

If the wedge is the reset pulse overlapping a sibling's unserialized
`power_on()` deassert, then `b37f6e9825b1` — the per-reset-domain lock, written
but **not yet booted** — cures it, because that lock is exactly what closes the
`acquire_soft_ccu()` power-on against `reset_active()`. If the wedge is instead
the hard-IRQ `INT_STA` access to a core in reset, the lock changes nothing,
because the hard handler takes no domain lock and cannot (it is not sleepable).

The rates are compatible, which is weak support for the first candidate. The
overlap is now measured at ~2 per 60 s run of exactly this workload, and ~1 run
in 3 wedges; if roughly one contended overlap in six escalated to a stalled
transaction, the two figures would match. That is arithmetic consistency and
not evidence of a causal link — the second candidate has no measured rate at
all to compare against — but it does mean the first candidate is not too rare
to account for the wedge, which was the obvious objection to it.

Booting `b37f6e9825b1` and re-running the two-error-stream configuration is
therefore a single experiment that discriminates the two candidates *and*
serves as step 2 of the deassert race's verification gate. It should be run
after the reachability measurement, not before, since the pre-fix contention
rate is unrecoverable once the lock is in.

## Harness correction shipped alongside

`rewrite-reset-contention.sh` now counts only **cross-core** deasserts when
estimating expected contention hits. `rk_mpp_rkvdec2_submit()` holds the
submitting core's `run_lock` across both its own `rk_mpp_hw_power_on()` and the
group power-on, and that core's reset runs in its IRQ thread under the same
lock, so a core's own submits can never contend with its own reset. Counting
all deasserts overstated the expectation by 3× on a two-core group — the
2026-07-31 run reported ~12.7 expected against zero observed, which reads as a
decisive negative (p ≈ 3e-6) but was really ~4.2, where a zero is a 1.5%
outcome and proves nothing. The `EXPECT=contended` failure text now says so.

## Follow-ups

- **Operational, before any further wedge hunting.** journald syncs every
  5 minutes by default, which cost ~13 minutes of tail on the first wedge;
  drop it to 1 s (`/etc/systemd/journald.conf.d/99-sync.conf`,
  `SyncIntervalSec=1s`). Serial console on `ttyS2` at 1500000 is the only
  instrument that can see a bus stall at all — journald, pstore and the panic
  sysctls all need a CPU that still runs — so a UART capture with the console
  loglevel raised is worth the setup before the next attempt.
- Run the exposure-matched single-stream control (above).
- Boot `b37f6e9825b1` and re-run the two-stream configuration (Prediction).
- ~~The reachability measurement is blocked behind this.~~ **Closed the same
  day.** It never needed λ ≥ 15 or the 300 s run: two ordinary 60 s runs of the
  default config each landed 2 hits against ~3.0 expected, so the race is
  [observed](2026-07-31-rkvdec-sibling-reset-deassert-race.md) and the lock is
  justified and building. Expected hits accumulate across runs, so a wedge
  costs a reboot rather than the measurement.
- Counter polling has landed in the harness (`RESET_POLL_S`, default 1 s): a
  snapshot is fdatasynced and renamed into `counters-poll-latest.tsv` every
  interval, so a wedged run can still be differenced against
  `counters-before.tsv` instead of yielding nothing, and the wedge is dated to
  within a second rather than the minute the journal manages. Both 2026-08-01
  wedges predate it and remain total losses.
