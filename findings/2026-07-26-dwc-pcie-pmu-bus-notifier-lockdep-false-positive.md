# DWC PCIe PMU nests distinct same-class bus notifier locks and disables lockdep

> Scope: upstream Linux DWC PCIe PMU and driver core on the ROCK 5B
> Source: booted `6.18.40-video-rewrite-kasan-rockchip64`; `linux-6.18-rkvenc@0cc483d3ee20` `drivers/perf/dwc_pcie_pmu.c` `dwc_pcie_pmu_notifier()` / `dwc_pcie_register_dev()`, `drivers/base/bus.c` `bus_register()` / `bus_notify()`, and `kernel/locking/lockdep.c` `print_deadlock_bug()`
> Date: 2026-07-26
> Trust: MEASURED / SOURCE-INSPECTED / ROOT-CAUSED / PARTIAL

## Result

The boot-time `possible recursive locking detected` report is not recursion on
one rwsem and has no rewrite-driver frame. It is a lockdep class collision
caused by the upstream DWC PCIe PMU's synchronous cross-bus device creation:

1. PCI discovery calls `bus_notify()` and takes the PCI bus notifier's read
   lock.
2. `dwc_pcie_pmu_notifier()` handles `BUS_NOTIFY_ADD_DEVICE` and calls
   `dwc_pcie_register_dev()`.
3. That function synchronously calls
   `platform_device_register_simple("dwc_pcie_pmu", ...)`.
4. `device_add()` notifies the platform bus and takes the platform bus
   notifier's read lock before the PCI notifier callback has returned.

The warning itself prints two different lock addresses:

```text
trying:  ffff000101c692a8
holding: ffff000112e872a8
```

Those are distinct notifier rwsems. Lockdep calls them both
`&(&priv->bus_notifier)->rwsem` because `bus_register()` initializes every
bus's notifier head through the same `BLOCKING_INIT_NOTIFIER_HEAD()` call site.
Dynamic lock initialization therefore assigns the PCI and platform instances
the same lock class, and lockdep mistakes the real PCI-notifier → platform-
notifier nesting for recursive acquisition of one class.

The same source shape remains in the local mainline rewrite tree at
`edba1c58a726` and in upstream Linux `master` inspected on 2026-07-26:
`dwc_pcie_pmu_notifier()` still registers the platform device synchronously,
and `bus_register()` still initializes all bus notifier heads at the common
call site.

The three live PMU devices under
`/sys/bus/event_source/devices/dwc_rootport_{0,22000,44000}` show that device
creation completed on this boot. The interleaved
`mmc2: Failed to initialize a non-removable card` line came from another
probe/CPU and is not a frame or causal step in this lockdep report.

## Qualification impact

This is not evidence of an MPP, RGA, IOMMU, or rewrite deadlock. It is still a
debug-kernel qualification blocker: `print_deadlock_bug()` calls
`debug_locks_off_graph_unlock()`, which disables lockdep after emitting the
first report. Later rewrite workloads on this boot retain KASAN coverage but
cannot claim continuing lockdep coverage, and the boot is not warning-clean.

For a clean rewrite qualification boot, the smallest low-risk experiment is a
kernel with optional `CONFIG_DWC_PCIE_PMU=n`; that removes the PCIe performance
event-source driver, not the PCIe host controller or NVMe function. A durable
driver fix should avoid registering/unregistering platform devices
synchronously from inside the PCI bus notifier, for example by handing
reference-safe add/remove work to a workqueue after the notifier returns.
Merely assigning distinct lock classes would remove this report but would not
remove the cross-bus nesting, so it needs a separate ordering review.

## Boundary

This source inspection explains the reported recursive-lock classification and
shows that the captured boot made forward progress. It does not prove that
every cross-bus notifier ordering is deadlock-free under hotplug or concurrent
notifier registration/removal. No fix was implemented or boot-tested here.
