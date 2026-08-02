# Probe error paths are testable by DT alone, but -ENXIO and -ENODEV probe failures are silent by default

> Scope: how to exercise a platform driver's probe failure paths; worked through
> on `vsi_iommu_probe()`, but the observability rules are generic
> Source: `~/Code/rock-5b/kernel/linux-iommu-vsi-fixes` @ `iommu/next`
> `b4f6d7b19f3ae` — `drivers/base/dd.c` `really_probe()` (~:634-648),
> `drivers/base/platform.c` `platform_get_irq()` (~:301-312),
> `drivers/iommu/vsi-iommu.c` `vsi_iommu_probe()` (~:669),
> `arch/arm64/boot/dts/rockchip/rk3588-base.dtsi` (~:1479)
> Date: 2026-08-02
> Trust: SOURCE-INSPECTED, DESIGN

## Result

Two reusable facts came out of asking how to test the
[KRW-4 fixes](../kernel-drivers/patches/iommu-vsi-probe-fixes/README.md).

### 1. The driver core hides three errnos

`really_probe()` classifies a failing probe's return value before logging it:

| Probe returns | Logged as |
|---------------|-----------|
| `-EPROBE_DEFER` | `dev_dbg` — "requests probe deferral" |
| `-ENODEV`, `-ENXIO` | `dev_dbg` — "rejects match" |
| anything else | **`dev_err`** — "probe with driver %s failed with error %d" |

So a driver that fails probe with `-ENXIO` leaves **no trace in dmesg** at
default log levels, while the same driver failing with `-EINVAL` prints a clear
error naming the errno. When a device is silently absent and the driver looks
loaded, this asymmetry is the first thing to check — and it means "nothing in
dmesg" is not evidence that probe succeeded.

`platform_get_irq()` compensates for its own case: it routes failures through
`dev_err_probe()` and prints `IRQ index %u not found` itself, so a missing
interrupt is visible even though the resulting `-ENXIO` is invisible at the
driver-core layer. Helpers vary in whether they do this; do not assume.

### 2. Probe error paths can be forced from the device tree, with no code change

For any platform driver, deleting a property the probe consumes forces the
matching failure, because the failures happen in resource lookup before the
driver touches hardware:

| Remove from the node | Failure produced | Visible as |
|----------------------|------------------|------------|
| `reg` | `devm_platform_ioremap_resource()` → `-EINVAL` | `dev_err` naming `-22` |
| `interrupts` | `platform_get_irq()` → `-ENXIO` | `IRQ index 0 not found`; core log silent |

Applied to `vsi_iommu_probe()` this covers two of the three KRW-4 fixes without
patching the kernel:

- **Discarded ioremap error.** Drop `reg`. Before the fix the core prints
  `failed with error -12` (`-ENOMEM`); after, `-22` (`-EINVAL`). One line in
  dmesg, unambiguous.
- **Clocks leaked on a missing interrupt.** Drop `interrupts`, keep `reg` and
  `clocks`. The signal is not the errno — it is the clock's `prepare_count`
  column in `/sys/kernel/debug/clk/clk_summary`. Before the fix it stays
  elevated after the failed probe; after, it returns to baseline.
- **Unchecked DMA mask.** Not forceable. `dma_set_mask_and_coherent(dev,
  DMA_BIT_MASK(32))` does not fail on arm64 in any reachable configuration, so
  this fix has no runtime test short of contriving a platform.

### 3. For this driver, the test needs no RK3588 silicon

Both reachable failures occur before `vsi_iommu_probe()` touches an IOMMU
register — the sequence is `devm_kzalloc`, `devm_platform_ioremap_resource`,
`devm_clk_bulk_get_all`, `clk_bulk_prepare`, `platform_get_irq`, and only later
any hardware access. A QEMU `arm64 virt` machine with a synthetic node
(`compatible = "verisilicon,iommu-1.2"` plus a `fixed-clock`) therefore
exercises both paths. arm64 `defconfig` already enables both `ARCH_ROCKCHIP` and
virt, so one kernel serves both, and `CONFIG_VSI_IOMMU` is reachable.

An on-board test is also available and needs no DT authoring, because mainline's
`rk3588-base.dtsi` already instantiates the driver as `av1d_mmu:
iommu@fdca0000` with no `status` property — see
[the convergence finding](2026-08-02-vsi-iommu-mainline-convergence-and-resync-collision.md).
Editing that existing node is enough.

## Boundary

**None of this has been run.** The tag is DESIGN: the mechanisms are read out of
the source, the expected observables follow from it, and no QEMU boot, no board
boot, and no `clk_summary` capture exists. Treat the errno values and the
prepare-count behaviour as predictions until something records them.

Specifically untested: whether a `fixed-clock` under QEMU produces a
`prepare_count` column that moves the way a real Rockchip clock does; whether
the synthetic node probes far enough to reach `platform_get_irq()` without other
DT requirements (`power-domains` is present on the real node and absent from any
synthetic one); and whether removing `interrupts` from `av1d_mmu` on a real
board has side effects on the AV1 decoder beyond losing its IOMMU.

The QEMU route must stay restricted to the **failure** cases. A synthetic node
with valid `reg` and `interrupts` would have the driver ioremap arbitrary
address space and register a real IOMMU on a machine that has none.

## Why it matters

The generic half — that `-ENXIO` and `-ENODEV` probe failures are invisible by
default — is the durable part, and it applies to every driver this project
touches, not just this one. It belongs in the trap index for that reason.

The specific half sets the honest ceiling on what the KRW-4 series can claim.
Two of three fixes are testable cheaply and without hardware; the third is not
testable at all. That is worth knowing before promising a maintainer any runtime
evidence, and it is why the series' cover letter states compile-only testing
rather than implying more.
