# BSP troubleshooting map

Use this page to decide which BSP area to inspect first.

| Symptom | Likely BSP area | First place to look |
|---------|-----------------|---------------------|
| Device node missing | DT, Kconfig, driver probe | `compatible`, `status`, config symbol, probe log |
| Probe defers forever | clocks, resets, regulators, power domains, IOMMU | `dmesg`, DT phandles, provider nodes |
| MPP codec job times out | media/Mpp, clocks, IRQ, IOMMU, taskqueue | `/dev/mpp_service`, IRQ count, IOMMU faults, taskqueue node |
| AV1 decode fails | AV1 MPP backend or AV1D IOMMU | `CONFIG_ROCKCHIP_MPP_AV1DEC`, `av1d`, `av1d_mmu`, `rockchip-iommu-av1d.c` |
| JPEG decode fails | JPGDEC backend or `jpegd` DT | `CONFIG_ROCKCHIP_MPP_JPGDEC`, `jpegd`, `jpegd_mmu` |
| JPEG encode fails | JPEGE core wiring or encoder-side task format | `jpege0..3`, `jpege_ccu`, per-core MMUs, RKVENC2 JPEG tables |
| RGA job fails | RGA driver, memory, IOMMU, format | `/dev/rga`, RGA generation, format/stride checks |
| RKNN/RKNPU job fails | RKNPU ABI, memory backend, IOMMU domain, power, or task format | RKNN version, DRM render node or `/dev/rknpu`, `drivers/rknpu/`, core mask, fence config |
| Camera produces no frames | sensor, CSI, CIF, ISP graph | `media-ctl`, endpoint graph, regulator/GPIO logs |
| Display blank | DRM bridge/panel/PHY/clock | KMS state, bridge attach, panel prepare/enable |
| Works only as root | device permissions and heaps | `/dev` ownership, udev rules, group membership |
| Works on BSP only | missing vendor service or common-kernel delta | compare DT, Kconfig, service calls, and common patches |
| Random boot race | boot-order/common-kernel policy | initcall/Thunder Boot/async behavior |
| Thunder Boot product hangs | storage handoff, ramdisk decompress, MCU service, or ISP reserved memory | `CONFIG_ROCKCHIP_THUNDER_BOOT*`, `initcall_nr_threads`, `thunder-boot-*` DT nodes, reserved-memory layout |

## Media-specific debug order

1. Confirm `CONFIG_ROCKCHIP_MPP_SERVICE` and the specific subdriver symbol.
2. Confirm the DT node is enabled and its `compatible` matches the subdriver.
3. Confirm the node points at `mpp_srv` when the BSP driver expects it.
4. Confirm taskqueue, CCU, power-domain, clock, reset, and IOMMU properties.
5. Confirm userspace opens `/dev/mpp_service` and required dma-buf heaps.
6. Check IOMMU faults and IRQ counters during a real job.
7. Verify the exact codec path. AV1, JPEG decode, JPEG encode, RKVDEC, and
   RKVENC are different BSP backends even though they share MPP service.

## RKNPU-specific debug order

1. Confirm `CONFIG_ROCKCHIP_RKNPU` and the selected memory backend:
   `ROCKCHIP_RKNPU_DRM_GEM` or `ROCKCHIP_RKNPU_DMA_HEAP`.
2. Confirm the effective DT enables the matching `rockchip,*-rknpu` node, its
   `iommus` provider, IRQ names, clocks, resets, regulators, OPP table, and power
   domains.
3. Confirm userspace opens the expected node: DRM render node for GEM builds or
   `/dev/rknpu` for dma-heap builds.
4. Treat the RKNN runtime, RKNPU ioctl structs, memory flags, IOMMU domain id,
   and PC-mode task buffer format as one compatibility tuple.
5. For `EINVAL`, check task count, core mask, non-PC job flags, fence-in/out
   support, and IOMMU domain id.
6. For timeout, check IRQ status, IOMMU faults, cache synchronization, power
   reset logs, and whether the userspace task buffer matches this BSP kernel.

## Thunder Boot debug order

1. Confirm this is actually a Thunder Boot product build. Check
   `CONFIG_ROCKCHIP_THUNDER_BOOT`, storage-specific symbols, service symbols,
   ISP symbols, and the `initcall_nr_threads=` bootarg.
2. Check the loaded DT for `rockchip,thunder-boot-mmc`,
   `rockchip,thunder-boot-sfc`, `rockchip,thunder-boot-service`,
   `rockchip,thunder-boot-rkisp`, `memory-region-src`,
   `memory-region-dst`, and `memory-region-thunderboot`.
3. Verify reserved-memory addresses and sizes match the loader/RTOS expectation.
   Thunder Boot comments in DTS often state that offsets must match RTOS.
4. If rootfs unpack hangs, check the storage handoff and hardware-decompress
   path before debugging generic initramfs.
5. If camera handoff fails, check the Thunder Boot header completion state,
   sensor `is_thunderboot` behavior, GPIO preservation, and RKISP private ioctls.
6. If probes race only with Thunder Boot enabled, test with
   `initcall_nr_threads=0` to separate async-initcall races from storage, MCU, or
   camera handoff problems.

## DT/probe debug order

1. Verify the loaded DTB.
2. Check `status = "okay"` in the effective tree.
3. Check the OF match table in the driver source.
4. Check probe-defer logs for every provider.
5. Check whether a product DTS overlay disabled or replaced the base node.
6. Check whether the block uses normal `rockchip,iommu-v2` or a special provider
   such as `rockchip,iommu-av1d`.

## Silent probe/boot hang: making it self-report

For a boot that **soft-hangs during device probe** — never reaches
`multi-user.target`, no clean shutdown, no oops/panic, and a manual power-cycle is
needed. This is a *sleeping* hang (a probe blocked on a mutex/completion, or a
stuck `deferred_probe_work_func` worker), not a CPU spin.

**Key insight — the detectors are usually already armed; the output has nowhere to
land.** On the dev box, `kernel.hung_task_timeout_secs=60` and
`workqueue.watchdog_thresh=30` are on, and deferred probe runs on a workqueue, so
a stuck probe *does* print `BUG: workqueue lockup` (~30 s) and a hung-task
backtrace (~60 s) into the ring buffer. You just never see them because no console
is attached, journald cannot flush a frozen boot, and ramoops came up empty
(on **this firmware stack** the reserved window is zeroed across a warm reset —
see the
[maintained boot-firmware evidence boundary](../../boot-firmware/docs/ramoops-retention.md)).
`soft/hardlockup` and the NMI watchdog do **not** fire on a sleeping hang.

So the triage priority is: give those dumps a durable channel, then force a fast
reboot instead of a manual wait.

1. **netconsole** — the no-cable alternative to serial. Stream printk over UDP to
   another host (`modprobe netconsole netconsole=@/,@<host>/`, or a `netconsole=`
   cmdline arg for early boot). Receives the already-armed hung-task and
   workqueue-watchdog dumps live.
2. **Do not count on ramoops here** — the reserved window comes back **zeroed**
   after a warm reset on this firmware stack (confirmed three independent ways),
   so there is nothing to recover on the next boot. Earlier revisions of this
   list advised recovering the dump with a *cold power-off*; that is **backwards
   and was never tested** — a cold power-off removes DRAM power outright and
   forces a full DDR re-init, while a warm reset is the only path with any
   chance at all. Use step 1 (netconsole) or a ttyS2 serial console instead, and
   pair with step 3 so the hang panics promptly. Since 2026-07-28 ramoops
   *does* recover records across warm reboots on the 6.18.40-era kernels —
   check `journalctl -b -u systemd-pstore` and `/var/lib/systemd/pstore/`,
   never `/sys/fs/pstore` (archived-and-erased seconds after boot). The
   remaining qualification A/B is in
   [the retention guide's next-proof section](../../boot-firmware/docs/ramoops-retention.md#next-causal-experiment).
3. **Force reboot + dump** — set `kernel.hung_task_panic=1` (default here is `0` =
   warn-only); with `panic=10` already on the cmdline the blocked task panics at
   60 s and self-recovers in seconds instead of a ~6-minute dead wait.
4. **Enable SysRq debug dumps** — the box ships `kernel.sysrq=176`
   (reboot/sync/remount-ro only; **not** the debug-dump bit 8). Set
   `kernel.sysrq=1`, then while hung trigger `SysRq-w` (blocked/D-state tasks —
   the smoking gun), `SysRq-t` (all tasks), `SysRq-d` (held locks; works because
   lockdep is on), `SysRq-l` (per-CPU backtraces). Output still needs a console
   (serial or netconsole).
5. **`initcall_debug ignore_loglevel`** — makes probe self-describing: every driver
   logs `calling <driver>…` / `probe of <dev> returned N after M usecs`. The last
   `calling` with no matching `returned` names the exact stuck driver.
6. **Bisect only unmatched probes** — blacklist a driver only when its probe
   start lacks a matching return. A completion line closes that path.
7. **Automated reboot-loop harness** — for an intermittent hang, script N reboots
   to measure the hit-rate, gather multiple captures, and provide a regression
   test for any fix. Pair with the RK3588 **hardware watchdog** so each hang
   auto-recovers and the loop runs unattended.
8. **kgdb/kdb** — interactive escalation (break in, inspect live) via `kgdboc`
   over the serial port, if passive capture is not enough.

**Reading two adjacent messages that often appear at such a freeze:**

- `rockchip-pm-domain …: sync_state() pending due to <addr>.video-codec` can be
  **benign**. `sync_state()` only runs once *every* consumer of a
  bootloader-left-on resource (power domain, clock, regulator) has probed; the
  message alone says only that consumers are not all bound. In the 2026-07-22
  incident, the `fdba4000/fdba8000/fdbac000` nodes are Hantro VEPU121 JPEG
  secondary instances that Hantro intentionally ignores, and the same pending
  messages occur on the healthy boot. They do not imply a forward-port MPP probe
  was still running.
- The Rockchip PCIe PMU-notifier lockdep splat (`WARNING: possible recursive
  locking … dwc_pcie_pmu_notifier → dwc_pcie_register_dev → device_add →
  blocking_notifier_call_chain`) is real **cross-bus nesting**, but the
  recursive-lock classification is false: the printed addresses are the
  distinct PCI and platform bus notifier rwsems. `bus_register()` initializes
  every bus notifier at one call site, so both instances share one lockdep class
  and look recursive when the DWC callback synchronously creates its platform
  device. The observed path completes on healthy boots and is not evidence that
  the probe hung. It still matters for debug qualification because the report
  disables lockdep for the rest of that boot; see the
  [source-backed triage](../../findings/2026-07-26-dwc-pcie-pmu-bus-notifier-lockdep-false-positive.md).

This probe-capture playbook is generic. The 2026-07-22 incident that initially
motivated it was subsequently proven to be a Plymouth userspace stall, not a
stuck probe.

## Plymouth stall before `sysinit.target`

Fingerprint:

- `plymouth-read-write.service` logs `Starting` but never `Finished`;
- `plymouth-start.service` logs `Starting` but never `Started`;
- no `Received SIGRTMIN+20 from PID … (plymouthd)`;
- udev settle finishes, but `sysinit.target` and `basic.target` never arrive.

The initramfs-started daemon retains Plymouth's abstract socket but does not
complete the real-root read-write handshake. Ordinary Plymouth clients have no
timeout for this path, and the read-write unit is `Before=sysinit.target` with
an infinite start timeout. A second `plymouthd` cannot replace the socket owner;
its `show-splash` post-command blocks on the same server.

This is not evidence of a malformed initramfs. In the captured incident, the
same pre-existing build-`#6` initrd failed once and booted successfully on the
next attempt. Its extracted Plymouth binaries/scripts were package-identical,
and its Plymouth theme, DRM renderer, Rockchip DRM modules/dependencies, and
DPTX firmware were present. Real-root PID 1 also proves that the daemon had
already processed and ACKed initramfs's new-root request. The remaining defect
is a post-pivot daemon event-loop wedge; udev/DRM activity is a timing suspect,
not yet a proven internal cause.

On Armbian, `bootlogo=false` still injects `splash=verbose`; it does **not**
disable Plymouth. Append `plymouth.enable=0` to `/boot/armbianEnv.txt`'s
`extraargs=` line. `extraargs` follows `consoleargs`, so the later disable token
wins without regenerating the initramfs or `boot.scr`.

If Plymouth must remain enabled, make non-interactive control requests
fail-open: add client-side reply timeouts for `update-root-fs --read-write` and
`show-splash`, plus finite systemd start timeouts for the read-write, start,
quit, and quit-wait units. A start-only timeout is insufficient because the
later quit-wait client also has an unlimited wait.

Capture with `plymouth.debug=stream:/dev/ttyS2`; plain `plymouth.debug` may
remain buffered because its normal file flush is triggered by the blocked
read-write request.
See
[`findings/2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md`](../../findings/2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md)
and watchlist [`W20`](../../status.md#watch-w20).
