# ROCK 5B debug-kernel boot hang is a device-probe soft-hang, not the network-wait-online timeout

> Scope: ROCK 5B dev board, running debug (lockdep-enabled) `6.18.38-current-rockchip64` while hunting Rockchip video-codec (rkvdec2/rkvenc/mpp) driver bugs
> Source: on-board `journalctl` of boot `-1` (hung) vs boot `0` (healthy), captured 2026-07-22; kernel `Linux version 6.18.38-current-rockchip64 #6 SMP PREEMPT Sat Jul 4 11:44:22 UTC 2026`, cmdline `console=ttyS2,1500000 ... pstore.backend=ramoops panic=10`
> Date: 2026-07-22
> Trust: MEASURED for the boot outcomes and log diff; INFERRED for the hang location; HYPOTHESIS for the exact driver at fault

## Result

A reboot that "didn't come up" was **not** a network problem. The loud
`systemd-networkd-wait-online.service: Timeout ... Failed` line that shows up in
the failed boot's log is a **chronic, non-fatal** warning that appears on *every*
boot of this box — including the healthy boot that came up right after. It never
blocks the boot; the good boot logs the identical timeout and still reaches
`graphical.target`. Blaming "the network issue" is a misdiagnosis: that FAILED
line is just the loudest red text in the log, not the cause.

What actually happened on the failed boot (`-1`):

- The kernel **soft-hung during device probe**. The boot got through basic system
  init but **never reached `multi-user.target` / `graphical.target`** and never
  started the display manager. There is **no clean shutdown** in its journal —
  the last persisted line is the networkd-wait-online failure, then silence.
- It was a **hang, not a crash**: `/sys/fs/pstore` is empty and the cmdline has
  `panic=10`, so a real panic would have auto-rebooted in 10 s and left a ramoops
  dump. Instead the board sat idle for **~6 minutes** (21:32 → 21:38:48) until a
  **manual hard power-cycle** into the healthy boot.
- The **last kernel activity before silence** was the Rockchip video codecs:
  `rockchip-pm-domain fd8d8000...: sync_state() pending due to
  fdba4000/fdba8000/fdbac000.video-codec`. Leading suspect is a probe/sync_state
  stall in one of the **rkvdec2/rkvenc/mpp** drivers this box is actively fuzzing.

## Evidence and reproduction

- **Identity:** ROCK 5B, debug kernel `6.18.38-current-rockchip64 #6`
  (lockdep/`PROVE_LOCKING` on — see splat below), ramoops+`panic=10` cmdline.
- **Detection — the discriminating diff:** boot `-1` vs boot `0` both log the
  *same* `systemd-networkd-wait-online` timeout **and** the *same* 3 lockdep
  deadlock warnings. Boot `0` came up fine with both present → neither is causal.
  ```
  # journalctl -b -1 ... | grep 'Reached target ... Multi-User|Graphical'   → (nothing)
  # journalctl -b  0 ... | grep 'Reached target ... Graphical'              → graphical-session.target
  ```
- **Exercise:** `journalctl --list-boots` (6-min gap before the next boot);
  `journalctl -b -1 -o short-precise | tail` (last line = networkd failure, no
  shutdown); `journalctl -b -1 | grep -iE 'hung task|rcu.*stall|Oops|kernel BUG'`
  → none logged; `ls /sys/fs/pstore` → empty.
- **Pass/fail signal:** hung boot never reaches `multi-user.target`; ~6-min dead
  gap; no clean-shutdown records; pstore empty (no panic). Healthy boot reaches
  `graphical-session.target`.
- **Recurring lockdep splat (present every boot, non-fatal here):**
  ```
  WARNING: possible recursive locking detected   *** DEADLOCK ***
  print_deadlock_bug ... down_read ... blocking_notifier_call_chain ...
  dwc_pcie_pmu_notifier → dwc_pcie_register_dev → platform_device_add →
  device_add → bus_notify → blocking_notifier_call_chain (re-entrant rwsem)
  ... rockchip_pcie_probe → dw_pcie_host_init (deferred_probe_work_func)
  ```
  A re-entrant `blocking_notifier` rwsem in the Rockchip PCIe PMU-notifier probe
  path. It didn't hang *this* twin boot, so it's a secondary candidate, not a
  proven cause.
- **Artifacts:** none committed (raw machine capture); reproduce from the
  on-board journal with the commands above.

## Boundary

The hang left **no** `hung_task`/RCU-stall/oops in the journal — nothing was
flushed after the freeze — so the exact faulting driver is **not proven** from
logs alone. "video-codec probe" is inferred from the last-logged kernel activity;
the PCIe PMU-notifier lockdep path is a separate, unproven candidate. Frequency
is **intermittent**: boot `-2` ran cleanly 17:21 → the 21:32 reboot, and the
current boot is healthy. This finding does not establish which codec/PoC state
(if any) preceded the reboot, nor whether the earlier boot the user also blamed
on "the network" was the same probe hang.

## Why it matters / follow-up

Stops the network red herring from recurring and points the next debug pass at
device probe.

**The detectors are already armed; the output has nowhere to land.**
`kernel.hung_task_timeout_secs=60` and `workqueue.watchdog_thresh=30` are on, and
deferred probe runs on a workqueue, so a stuck probe *does* print `BUG: workqueue
lockup` (~30 s) and a hung-task backtrace (~60 s) — but into a ring buffer with no
console attached, journald unable to flush a frozen boot, and ramoops empty
(RK3588 does not preserve ramoops across a **warm** reset,
[finding](./2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md)). The
soft/hardlockup and NMI watchdogs do not fire on a *sleeping* hang. Current
`kernel.sysrq=176` also lacks the debug-dump bit, so `SysRq-w/t/d/l` are disabled.

Triage options next time it hangs — full playbook in
[`kernel-versions/bsp/troubleshooting.md` → "Silent probe/boot hang"](../kernel-versions/bsp/troubleshooting.md#silent-probeboot-hang-making-it-self-report):

- **netconsole** (no-cable alternative to serial) to receive the already-armed
  hung-task/workqueue-watchdog dumps live; or the ttyS2 **serial console**.
- `kernel.hung_task_panic=1` (+ existing `panic=10`) to force a fast reboot and a
  ramoops-able panic dump instead of a ~6-min manual wait.
- `kernel.sysrq=1` then `SysRq-w/t/d/l` while hung (`-d` held-locks works because
  lockdep is on).
- `initcall_debug ignore_loglevel` — last `calling <driver>` with no `returned`
  names the stuck driver directly.
- Bisect: blacklist the `fdba*.video-codec` codec probes vs. the
  `dwc_pcie_pmu` notifier path separately to convert the suspect into evidence.
- Automated reboot-loop harness + RK3588 hardware watchdog for unattended
  reproduction of this intermittent hang.

Tracked as status.md watchlist [`W20`](../status.md#watch-w20).
