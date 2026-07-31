# Soft-CCU wedge survived the arm/start fix: the critical section was still split; whole-sequence lock applied

> Scope: MPP rewrite driver (rkvdec2 soft-CCU path); rock-5b conformance mpp
> suite run `20260730-072143`
> Source: fix `be14140d6edcb` on rk3588-rewrite-6.18 (parent `eb78ceed2fd67`,
> the booted kernel); cherry-pick `7ff26097022ae` on rk3588-rewrite-mainline
> Date: 2026-07-30
> Trust: MEASURED (wedge signature, case localization, watchdog resets) +
> SOURCE-INSPECTED (residual unlocked window) + INFERRED (re-gate mechanism,
> inherited from the 2026-07-29 model) + BOOT-VERIFIED (package
> `P0d67-Cad24`, 6.18.41 `#19`, run `20260730-092824`) + **PARTIAL /
> FALSIFIED-AS-SOLE-CAUSE** — the whole-sequence lock did not cure the
> `mpi_dec_h265` wedge (see Boot result below)

## Result

The [2026-07-29 arm/start fix](2026-07-29-rewrite-soft-ccu-dual-core-wedge.md)
held for its own case — `mpi_dec_mt_h264` passed for the first time ever
(0.3 s, board #18, kernel `eb78ceed2fd67`) — and the silent full-system
wedge moved exactly one case forward: single-threaded `mpi_dec_h265` killed
the board at its first submit (07:22:04–05; `mpi_dec_h265.cmd` persisted
with no `.log`/`.status`, journal stops mid-flush of mt_h264's final lines,
zero kernel output — the same bus-stall class). The armed
`RuntimeWatchdogSec=60s` then auto-reset the board, and the next **two
boots died mid-early-boot** (journal cut at ~15–25 s uptime, no shutdown
records) before the third boot survived — consistent with a warm reset not
fully clearing the stalled video-codec domain, though manual resets in that
window are not excluded.

## Root cause (refined)

The 07-29 fix serialized coordinator arming (in `prepare_soft_ccu`) and the
`CORE_STA`+START pair (in `start_soft_ccu_job`) under `ccu->run_lock` — but
as **two separate lock sections**. The core-side MMIO between them —
`rk_mpp_rkvdec2_configure_cache()` and the task-register writes of
`rk_mpp_job_write_regs()` — ran with the lock dropped. Under the inherited
gating model, a sibling completion or the previous session's teardown
(mt_h264's close/abort/reset traffic was still draining when h265's first
job armed) re-gates the armed core in that window, and the next write to
the gated register file stalls the interconnect. The BSP's
`rkvdec2_soft_ccu_enqueue` runs the *entire* arm → cache → task-registers →
`CORE_STA` → START sequence on one taskqueue worker; the rewrite had only
serialized its ends.

## Fix

`be14140d6edcb` (6.18) = `7ff26097022ae` (mainline):

- The submit path holds `ccu->run_lock` continuously from coordinator
  arming through cache config, task-register writes, `CORE_STA`, and the
  START doorbell.
- `rk_mpp_rkvdec2_prepare_soft_ccu()` becomes
  `rk_mpp_rkvdec2_acquire_soft_ccu()` (CCU lookup + power only);
  `rk_mpp_rkvdec2_program_soft_ccu()` and
  `rk_mpp_rkvdec2_start_soft_ccu_job()` now `lockdep_assert_held` the
  caller's lock instead of taking it.
- The soft-path error unwind after a successful arm deregisters the core
  via `CORE_IDLE` — the hardening item the 07-29 adversarial review
  deferred.
- The soft-CCU KUnit case takes the lock around the arm/start helpers;
  case names and count are unchanged (the 89+148 manifest is unaffected).

Lock-order note: the enlarged hold adds no new nesting pair — the
core→coordinator `run_lock` order and the 07-29 distinct coordinator
lockdep class are unchanged; teardown/reset paths already take
`ccu->run_lock` and are now excluded from the whole window rather than
only its edges.

## Boot result (2026-07-30 09:28, package `P0d67-Cad24`)

The rebuilt kernel booted with the fix (`uname -v` carries
`gbe14140d6edc`, Armbian base moved to 6.18.41). The repaired KUnit gate
went green on first try — 89/89 + 148/148, manifest hashes matched,
identity bound. `mpp_info_test`, `mpi_dec_h264`, and `mpi_dec_mt_h264`
passed again — and `mpi_dec_h265` **wedged the board at first submit
with the identical silent signature**. The split critical section was
therefore not the (sole) h265 trigger; the whole-sequence lock remains
correct BSP-equivalent serialization but the wedge mechanism must
involve a path it cannot reach — the leading candidate is the hard-IRQ
side, which performs core MMIO (`INT_STA` read + ack write) outside any
CCU serialization by construction.

The run also surfaced a lockdep report during `mpi_dec_mt_h264`:
`BUG: Invalid wait context` at `rk_mpp_rkvdec2_irq+0x260` — the hard
handler takes `spinlock_t hw->lock` in hardirq context, flagged by
`CONFIG_PROVE_RAW_LOCK_NESTING`. **The checker is not new**: arm64
selects `ARCH_SUPPORTS_RT`, which hides the option's prompt and forces
`default y` whenever `PROVE_LOCKING=y` — it was equally active on every
6.18.40 debug boot (nothing relevant changed in the 3-commit
6.18.40→6.18.41 delta). It never *appeared* before because lockdep
reports once and disables itself: on pre-`eb78ceed` boots the soft-CCU
submit recursion always killed lockdep first, and once that was fixed,
the first decode IRQ's wait-context report became the boot's first (and
only) report — the 6.18.40 `#18` wedge boot logged the identical splat
at 07:22:04, hidden until now because the board wedged seconds later
and no scan ran. The same pattern exists in `rk_mpp_rkvenc2_irq`,
`rk_mpp_av1_irq` (both `hw->lock`), and `rk_rga_irq_handler`
(`hw->job_lock`); every conformance run trips the dmesg fatal gate on
the first report — and loses lockdep for the rest of the boot — until
this is resolved.

## Discriminator result (09:41 run `20260730-094129`): sequence-dependent, not h265-specific

`MPP_REQUIRED_CASES="mpi_dec_h265"` on a fresh boot of the same kernel
**passed in 0.340 s** — the identical command that wedges the board when
`mpi_dec_h264` + `mpi_dec_mt_h264` run first. (The suite still reported
red, but only because the per-suite dmesg gate correctly caught the
invalid-wait-context splat from the first rkvdec2 IRQ of the boot.) The
wedge therefore needs the preceding session sequence, and the mechanism
hypothesis moves to the power/registration lifecycle:

- The BSP runs *every* CCU/core power transition on the same single
  taskqueue worker that arms and starts (`rkvdec2_ccu_power_off` fires
  only with running+pending empty, disables core clocks synchronously
  in-worker, and `ccu_core_work_mode` is saved/restored across the power
  cycle) — power-off can never interleave with an arm/start.
- The rewrite powers cores off with `pm_runtime_put_autosuspend`
  (200 ms delay) from arbitrary contexts, outside `ccu->run_lock`, and
  nothing deregisters a still-`CORE_WORK`-registered core before its
  clocks gate. After `mpi_dec_mt_h264` both cores are registered; their
  autosuspends expire ~200 ms after the session closes — inside the
  next session's first-frame window. A coordinator poke at the
  just-gated sibling stalls the bus; the solo run has no such stale
  registration and survives.

Confirming prediction — **held** (10:56 run `20260730-095634`,
`RUN_KUNIT_CHECK=0`): the two-case pair `mpi_dec_mt_h264 mpi_dec_h265`
wedged at h265's first submit with mt passing 0.327 s earlier, on the
same boot image whose solo h265 runs pass. The minimal reproducer is
two cases.

## Second fix: BSP-style group core power (2026-07-30)

`600d6e2fb6a49` (6.18) = `451634b8c5a22` (mainline): soft-CCU
acquisition now powers **every** usable core of the coordinator for the
job's lifetime, reusing the job-owned `rkvdec_ccu_powered_cores`
mechanism the hard-CCU path already uses (`power_on_ccu_cores` gained a
core-mask parameter so soft jobs stay out of the hard-owned
`rkvdec_ccu_core_work`). Release rides the existing unconditional
`power_off_ccu_cores` in the common CCU-release path. With the group
hold, a `CORE_WORK`-registered sibling can no longer autosuspend while
any job is in flight — the BSP equivalence the single-worker model
provides for free.

Separately, the debug flavor now disables `PROVE_RAW_LOCK_NESTING`. A
plain config disable is impossible on arm64 (`ARCH_SUPPORTS_RT` hides
the prompt and forces `default y` under `PROVE_LOCKING`), so the debug
staging gains `zz-rock5b-debug-locknest-prompt.patch`
(`kernel-drivers/patches/debug-kernel/0002-…`), a one-line Kconfig
change making the prompt unconditional, paired with the `opts_n` entry
in `ysp-debug-instrumentation.conf.sh`. Rationale: the checker models
PREEMPT_RT wait-type nesting the rewrite deliberately does not target
yet (hardirq slice reads and poll wakeups in rkvenc2, the shared-line
RGA hard handler — a code fix is a redesign, not four lock swaps), and
its first report disables lockdep for the rest of the boot, which is
the deadlock coverage this build exists to provide. Debug flavors only;
production builds never stage the patch. The RT-nesting cleanup is a
tracked follow-up, not part of this qualification.

## Boundary and discriminators still open

The mechanism remains INFERRED (no TRM proof of the gating), and the fixed
kernel has not booted. If the rebuilt kernel wedges again on
`mpi_dec_h265`, the discriminators are: run `mpi_dec_h265` alone on a
fresh boot (no preceding mt session → cross-session teardown overlap
ruled in/out), and repeat with rkvdec2 core 1 unbound
(`echo fdc40100.video-codec > /sys/bus/platform/drivers/rk-mpp-rewrite-hw/unbind`)
for the single-core immunity check. A pre-existing cross-tree divergence
was found while replaying: `eb78ceed2fd67` (6.18) carries amend-era fixlets
(KUnit `active->imports` allocation, an `if (srv)` iommu-refresh guard, a
comment) that `7d92b06a4c5ba` (mainline) never received — the
`check_cross_tree_identity` gate will flag it until the fixlets are
replayed to mainline.
