# MPP job-ISR IOMMU fault-handler clear takes sleeping locks and panicked the idle task

> Scope: ROCK 5B production kernel (installed `linux-image-ysp-rockchip64`
> `6.18.40+rk3588av1fwport20260725-0ubuntu1~rk2`) and the rewrite-branch
> Rockchip IOMMU provider combined with the vendor MPP driver.
> Source: ramoops panic record `dmesg-ramoops-0` (archived
> `/var/lib/systemd/pstore/`, working copy `~/Code/tmp/reset-2026-07-29/`);
> installed `/boot/System.map-6.18.40-ysp-rockchip64`; packaged source
> `linux-rockchip64-ysp_6.18.40+rk3588av1fwport20260725.orig.tar.gz`;
> pre-fix source `linux-6.18-rkvenc @ cd71f985a784c`
> (`rockchip_iommu_set_fault_handler()`, `mpp_iommu_dev_deactivate()`,
> `mpp_dev_irq()`); fix commits `35eb735d21dd8` (`rk3588-rewrite-6.18`) and
> `2cf0126529c1c` (`rk3588-rewrite-mainline`).
> Date: 2026-07-29
> Trust: **MEASURED** / **BINARY-INSPECTED** / **SOURCE-INSPECTED** /
> **COMPILE-VERIFIED** (fix) / **INFERRED** (contention source)

## Result

The 2026-07-29 08:01:41 PDT reset (uptime 27441.855 s on the boot started
00:24) was a kernel panic, fully recorded by ramoops as `Panic#2 Part1`
(dump 1 = the oops, dump 2 = the panic of the same event). The chain, on
CPU 0 in `swapper/0` during a hard IRQ:

```
mpp_dev_irq
  mpp_iommu_dev_deactivate          # spin_lock_irqsave(&info->dev_lock)
    mpp_iommu_clear_fault_handler
      rockchip_iommu_set_fault_handler(dev, NULL, NULL)
        platform_get_irq → of_irq_get → irq_find_matching_fwspec
          mutex_lock(&irq_domain_mutex)   # sleeping lock in hardirq
            __schedule_bug: "BUG: scheduling while atomic: swapper/0/0/0x00010003"
```

Scheduling out of a hard IRQ on the idle task corrupted the return path;
20 µs later the CPU branched to a non-executable data page
(`pc = lr = 0xffff000103439000`, `Code:` all zeros, ESR `8600000f` IABT
level-3 permission fault), oopsed, and — because the victim was
`swapper/0` — the kernel had to panic: *"Attempted to kill the idle
task!"*. `panic=10` rebooted the board.

Root cause: the rewrite-line hardening of
`rockchip_iommu_set_fault_handler()` (lineage of `ae66e093f0293`
"media: rockchip: harden rewrite drivers") appended a clear-side tail —
`platform_get_irq()` (takes the sleeping `irq_domain_mutex` on **every**
`of_irq_get()` lookup) plus `synchronize_irq()` (sleeps outright) — to
guarantee no in-flight fault callback survives unregistration. That
contract is fine for the rewrite drivers, which unregister only in
process context, but the **vendor** MPP driver clears the handler on
every completed job: `mpp_dev_irq()` → `mpp_iommu_dev_deactivate()`,
in hardirq and under the `dev_lock` spinlock. The vendor RGA3 driver and
the worker/timeout deactivate paths sit in the same atomic-context class.

Why it was latent for ~40 h of uptime across three boots on `~rk1`/`~rk2`:
the mutex fastpath is an uncontended cmpxchg that never schedules, and the
production config has no `DEBUG_ATOMIC_SLEEP`, so millions of per-frame
traversals passed silently. The panic fired the first time
`irq_domain_mutex` happened to be held by someone else at the instant an
encoder job IRQ retired. At that moment `gnome-remote-desktop-daemon`
(PID 703728) had just accepted the 08:00:54 RDP reconnect after the
07:55:29 logoff of a 7 h 25 m session and was actively H.264-encoding via
rkvenc2; the exact concurrent mutex holder is not recoverable post-mortem
(**INFERRED**: any coincident IRQ-descriptor creation/lookup suffices).

The installed binary provably contains the bad tail:
`rockchip_iommu_set_fault_handler` spans `0x110` bytes in the installed
`System.map` (`0xffff800080a3abe8`–`0xffff800080a3acf8`), containing the
crash offset `+0xc4`; the clean pointer-set variant is far smaller. How
rewrite-branch code got into a "forward-port" package is its own finding:
[the 20260725 orig is a rewrite-composite worktree snapshot](2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md).

**Fix** (committed on both rewrite tips):

- `rockchip_iommu_set_fault_handler()` is atomic-safe again — pointer
  swap under `fault_lock` only, as the VSI provider always was.
- The teardown guarantee moved to new sleepable
  `rockchip_iommu_sync_fault_handler()` / `vsi_iommu_sync_fault_handler()`
  (`might_sleep()`, `platform_get_irq` + `synchronize_irq` per IOMMU IRQ),
  called only from process-context teardown: `mpp_iommu_remove()`,
  vendor RGA3 `rga_iommu_clear_fault_handler()` (unbind-only), and both
  rewrite drivers' `rk_*_iommu_unregister_fault_handler()`.
- The per-job deactivate path keeps no synchronization, restoring
  pre-hardening vendor behavior: its token is the long-lived `mpp_dev`,
  so a late callback cannot use-after-free.

Verification: all touched objects compile on `rk3588-rewrite-6.18`
(`rockchip-iommu.o`, `vsi-iommu.o`, `mpp_iommu.o`, `rga_iommu.o`,
`mpp_rewrite.o`, `rga_rewrite.o`); `rewrite-build-gate.sh` normal
profile PASS on both tips — `[6.18/normal]` at `35eb735d21dd` (zero
warnings, KUnit manifest check green; log
`~/Code/tmp/panic-fix-20260729/gate-6.18.log`) and `[mainline/normal]`
at `2cf0126529c1`.

## Boundary

- No runtime gate has exercised the fix; the **currently installed kernel
  still carries the bug**, and every RDP/GRD encode session (or any MPP
  codec job) can reproduce the panic under mutex contention until a
  repaired package is installed.
- The panic record proves this boot's crash only. The 07-28 18:46 and
  07-29 00:24 restarts left no dmesg record (single ramoops dmesg slot)
  and journal shutdown evidence was inconclusive; the 07-27 19:34
  `console-ramoops-0` shows a *clean* systemd reboot, so no claim is made
  that earlier resets were this bug.
- The published rewrite-replacement and KASAN-rewrite kernels build the
  same hardened setter next to the vendor MPP driver and are presumed
  crash-capable the same way (**INFERRED**, not reproduced there).
- Composite `rk3588-rewrite-armbian-*` branches pick up the fix only on
  their next rebuild from the fixed tips.
