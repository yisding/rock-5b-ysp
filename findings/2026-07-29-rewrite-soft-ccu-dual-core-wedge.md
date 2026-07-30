# Rewrite soft-CCU dual-core decode wedges the interconnect; arm/start split root-caused and fixed

> Scope: MPP rewrite driver (rkvdec2 soft-CCU path); rock-5b conformance mpp suite
> Source: rock-5b/kernel/linux @ rk3588-rewrite-mainline `7d92b06a4c5ba`
> (fix), parent `2e3916ef8011a`; cherry-pick `eb78ceed2fd67` on
> rk3588-rewrite-6.18; BSP contract from rockchip-kernel
> `mpp_rkvdec2_link.c` `rkvdec2_soft_ccu_enqueue()` (~:1976)
> Date: 2026-07-29
> Trust: MEASURED (wedge signature, case localization, single-core pass,
> lockdep/might_sleep splats) + SOURCE-INSPECTED (BSP comparison) +
> INFERRED (CCU clock-gating mechanism) + COMPILE-VERIFIED (fix; boot and
> dual-core re-run still pending) + ROOT-CAUSED

## Result

`mpi_dec_mt_h264` (multi-threaded decode, one session) hard-wedged the board
on every attempt on the rewrite kernels (#16, three wedges on 2026-07-29 at
20:59, 21:20, 22:37 PDT): instant full-system stall, no panic, no ramoops,
and — decisive — armed `hung_task_panic=1`/`softlockup_panic=1` never fired
over ~7 wedged minutes, so no CPU was executing at all: a bus-level stall,
not a software hang. `mpp_info_test` and single-threaded `mpi_dec_h264` pass
on the same boot; with rkvdec2 core 1 unbound, `mpi_dec_mt_h264` passes in
0.774 s. The wedge strictly requires both cores alive. No rewrite-profile
mpp suite had ever completed — the Jul 23 run predates the expanded case
matrix (info test only), Jul 26/27 runs died unrecognized at the same point
(empty summary / missing output dir; a hard reset discards the final ~5–30 s
of ext4 writes, so absence of artifacts localizes nothing). The forward-port
profile passes `mpi_dec_mt_h264` routinely, exonerating hardware and test.

## Root cause

The rewrite split the BSP's atomic soft-CCU arm→start sequence.
BSP (`rkvdec2_soft_ccu_enqueue`, all of it serialized by one taskqueue
worker): core into CCU work mode + `WORK_EN` + `WORK_MODE` + `CORE_WORK`,
then cache config + task registers, then `CORE_STA` written **immediately
before** `wmb()` + `START`. The rewrite wrote task registers first, then
armed everything **including `CORE_STA`** under `ccu->run_lock` in
`rk_mpp_rkvdec2_prepare_soft_ccu()`, dropped the lock, and wrote the START
doorbell outside it. On ccu-gated cores the coordinator owns core clock
gating: in the armed-but-not-started window a sibling-core completion (the
CCU observes its IRQ/status transition; per-core IRQ threads run
concurrently with the scheduler worker, an interleaving the BSP's single
worker never produces) can re-gate the armed core, and the eventual START
`writel` to the gated register file stalls the AXI/AHB transaction forever.
The CPU wedges mid-store; nothing — panic path, watchdog pet, printk — runs
afterward. Gating semantics are INFERRED from the BSP contract plus the
empirical dual-core requirement, not TRM-proven; the discriminating
prediction (single-core immunity) held.

Two adjacent driver bugs surfaced by the passing single-core run
(dmesg gate caught both):

- **Lockdep same-class recursion, then blindness.** The CCU coordinator is
  itself a `struct rk_mpp_hw`, so the legitimate core→coordinator
  `run_lock` nesting in `rk_mpp_rkvdec2_submit` reported "possible
  recursive locking" and lockdep disabled itself (`debug_locks=0`) — every
  dual-core run so far had zero lockdep coverage past the first submit,
  and the KUnit gate's `debug_locks` check fails for the rest of the boot.
- **Mutex in wait predicate.** `rk_mpp_session_done_or_empty()` /
  `rk_mpp_session_irq_poll_ready()` took `session->lock` (a mutex) inside
  `wait_event_interruptible` — `__might_sleep` splat from
  `rk_mpp_collect_msgs` ioctl path with the task already
  `TASK_INTERRUPTIBLE`; missed-wakeup/state-clobber risk.

## Fix

One commit, `7d92b06a4c5ba` (mainline branch) = `eb78ceed2fd67`
(rk3588-rewrite-6.18, the build lineage):

1. BSP-order restore: arm (mode/`WORK_EN`/`WORK_MODE`/`CORE_WORK`, no
   `CORE_STA`) moved before cache config and task registers; new
   `rk_mpp_rkvdec2_start_soft_ccu_job()` writes `CORE_STA` + `wmb()` +
   `START` adjacently under `ccu->run_lock` (the lock is the rewrite's
   substitute for the BSP's single-worker serialization).
2. Distinct lockdep classes for coordinator (`RK_MPP_DEVICE_BUTT`)
   `run_lock`/`lock`, assigned in `rk_mpp_hw_probe`.
3. Lockless poll wakeups: `atomic64_t poll_seq` in the session;
   `rk_mpp_session_poll_notify()` (inc then `wake_up_all`) at the three
   wake sites; poll loops snapshot the sequence before their locked
   re-check and sleep on it changing.

The soft-CCU KUnit case now asserts arming leaves `CORE_STA` clear and
covers the start helper. Adversarial subagent review (six attack surfaces:
missed-wakeup enumeration, error-path unwind, BSP line-by-line order,
whole-file lock-order audit, KUnit trace-through, cross-core register
safety) returned SHIP with four minors; three cosmetic ones are in the
commit, one deliberately deferred: a failed submit after arming leaves the
core registered in `CORE_WORK` with no `CORE_IDLE` deregistration — the
register state is bitwise identical to BSP's normal post-completion state
and no failure was constructible, but a hiword `CORE_IDLE` write on the
soft-path error unwind would restore BSP-provable state.

## Evidence and reproduction

- Wedge run artifacts (per-case `sync` in `mpp-suite.sh` makes these
  survive): `rock-5b/rockchip-conformance/logs/rewrite/20260729-223704-mpp-suite/`
  — `mpi_dec_mt_h264.cmd` present with no `.status` names the killer case;
  summary rows show info test + single-threaded h264 passing 0.4 s prior.
- Single-core pass + splats: `.../20260729-225730-mpp-suite/`
  (`dmesg-fatal.txt`, `dmesg-new.txt`; lockdep report names
  `rk_mpp_rkvdec2_submit+0x244/+0xa54`, might_sleep names
  `rk_mpp_session_poll_job+0x1c8`).
- Exact killer command: `mpi_dec_mt_test -i test_h264.h264 -t 7 -n 120 -v f`.
- Core-1 unbind discriminator:
  `echo fdc40100.video-codec > /sys/bus/platform/drivers/rk-mpp-rewrite-hw/unbind`.

## Boundary

The fixed kernel has not yet booted; the dual-core `mpi_dec_mt_h264` re-run
is the outstanding proof, and the full rewrite suite has still never
completed anywhere. The CCU gating mechanism is inferred (see Root cause).
The RGA rewrite's wait predicates take spinlocks, which is fine on this
PREEMPT (non-RT) config but would splat on RT. The rkvenc dchs dual-core
path was audited: register-image patching only, no cross-core MMIO, no
equivalent hazard.

## Follow-ups

- Build/verify: `build-kernel.sh` now stamps ` g<sha12>` of the
  `KERNEL_TREE` HEAD into the build timestamp (`uname -v`) via the
  always-on `ysp-build-stamp` extension, and the
  `rewrite-kunit-log-check.sh` identity gate (which insta-failed on every
  un-stamped boot, forcing the `RUN_KUNIT_CHECK=0` overrides during this
  hunt) now parses it from there. The release string cannot carry it:
  Armbian's deb packaging derives `${kernel_version_family}` independently
  (`kernel-debs.sh:52`) and hard-fails on `LOCALVERSION` divergence —
  measured on the first two build attempts (the first also caught a
  missing forward declaration the KUnit-off local object check masked).
- Next boot: KUnit gate green expected (89+148 cases, lockdep alive with
  the recursion gone — any *new* lockdep report is a real finding);
  re-run `MPP_REQUIRED_CASES="mpi_dec_mt_h264"` with both cores bound,
  then the full suite.
- Operational nets that made this debuggable, worth keeping while hunting:
  systemd `RuntimeWatchdogSec=60s` (auto-reset proved itself at 22:38),
  `PROGRESS` markers + per-case `sync` in `mpp-suite.sh`.
- Deferred: `CORE_IDLE` deregistration on the soft-path submit error
  unwind (see Fix).
