# iommu/vsi probe error-path fixes

Three error-path corrections to mainline's Verisilicon IOMMU driver,
`drivers/iommu/vsi-iommu.c`. Unlike everything else under
[`patches/`](../README.md), these target **mainline itself** rather than this
project's forward port — mainline gained its own `vsi-iommu.c` in April 2026,
and the defects below are in that driver, not in our copy.

| Field | Value |
|-------|-------|
| Target tree | IOMMU subsystem, `git://git.kernel.org/pub/scm/linux/kernel/git/iommu/linux.git` |
| Base | `iommu/next` @ `b4f6d7b19f3ae` |
| Prepared branch | `iommu-vsi-probe-fixes` in `../rock-5b/kernel/linux-iommu-vsi-fixes` |
| Prepared tip | `1240a1c2c6894` |
| Author/sign-off | `Yi Ding <yi.s.ding@gmail.com>` |
| Fixes target | `917ace84b770 ("iommu: Add verisilicon IOMMU driver")`, all three |
| Runtime state | **Not hardware-tested** — these are probe failure paths a working board does not take |

## Contents

| Patch | Defect in `vsi_iommu_probe()` |
|-------|-------------------------------|
| `0000-cover-letter.patch` | Draft cover letter, including the tool-assistance disclosure the kernel process documents require. |
| `0001-…-propagate-the-register-mapping-error-from-.patch` | `devm_platform_ioremap_resource()` failures are all reported as `-ENOMEM`, discarding the real error and losing `-EPROBE_DEFER`, so a deferrable probe fails permanently. |
| `0002-…-unwind-prepared-clocks-when-the-interrupt-.patch` | A `platform_get_irq()` failure returns directly, leaking the `clk_bulk_prepare()` done a few lines earlier. The `err_unprepare_clocks` label it should use already exists and is used by the very next failure path. |
| `0003-…-check-that-the-DMA-mask-was-applied.patch` | The `dma_set_mask_and_coherent()` return value is discarded, so a platform that cannot apply the 32-bit mask continues into `iommu_device_register()` anyway. |

They are three patches rather than one because each is an independent defect of
a different kind — a wrong errno, a resource leak, an unchecked return. Sending
them bundled would invite a "split this up" round trip.

## Validation

| Check | Result |
|-------|--------|
| `checkpatch.pl --strict --show-types -g` | 0 errors, 0 warnings, 0 checks on all three commits |
| Clean-base application | `git am` of the three exported files onto `b4f6d7b19f3ae` reproduces the prepared tip byte for byte |
| Compile | arm64 native `defconfig` + `CONFIG_VSI_IOMMU=y`, `make W=1 drivers/iommu/vsi-iommu.o`, zero warnings |

That is shape and compile integration, not behavior. **None of the three error
paths has been exercised**, which is the honest boundary and is stated in the
cover letter rather than hidden: they are probe failures that a working RK3588
board does not reach. The list is being asked to review them as code.

A fourth candidate defect — the hardirq handler calls
`pm_runtime_resume_and_get()` with no `pm_runtime_irq_safe()` — is deliberately
**excluded** until it is reproduced under `CONFIG_DEBUG_ATOMIC_SLEEP`. Do not
add it to this series without that evidence.

### If you do want runtime evidence

Two of the three are reachable by editing the device tree, with no kernel source
change. Both failures happen before the driver touches an IOMMU register, so
neither needs RK3588 silicon — a QEMU `arm64 virt` machine with a synthetic
`verisilicon,iommu-1.2` node and a `fixed-clock` is enough, and arm64
`defconfig` already enables both `ARCH_ROCKCHIP` and virt.

| Fix | Force it by | Pass/fail signal |
|-----|-------------|------------------|
| `0001` | removing `reg` from the node | dmesg `probe with driver ... failed with error -22` (`-EINVAL`) after the fix, `-12` (`-ENOMEM`) before |
| `0002` | removing `interrupts`, keeping `reg` and `clocks` | the clock's `prepare_count` in `/sys/kernel/debug/clk/clk_summary` returns to baseline after the fix, stays elevated before |
| `0003` | — | not forceable; `dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32))` does not fail on arm64 |

An on-board run needs no DT authoring either, because mainline already
instantiates this driver as `av1d_mmu: iommu@fdca0000` with no `status`
property — edit that node. Method, observability rules and the untested
assumptions are in
[the test-design finding](../../../findings/2026-08-02-driver-probe-error-path-test-design.md);
note that none of it has been run, so the signals above are predictions.

Keep any QEMU node restricted to the failure cases. Given a valid `reg` and
`interrupts` the driver will ioremap arbitrary address space and register an
IOMMU on a machine that has none.

## Provenance — this is a fix we already carry downstream

The driver is not Rockchip BSP code; the BSP has no standard VSI provider. It
instead carries a private `rockchip-iommu-av1d.c` driver integrated through
Rockchip's `third_iommu_ops` hook. Mainline's VSI copy and this project's
forward-port copy both descend from Collabora's `rockchip-3588` tree, whose
`vsi_iommu_probe()` is character-identical to mainline's pre-fix form. All
three defects are in that shared ancestor.

`rk3588-fwport-0005` already ships the corrected form — `PTR_ERR()`, the
`goto err_unprepare_clocks`, and the checked DMA mask — folded in silently
during the port; its commit message never mentions error handling. So this
series re-derives a correction the project has been carrying since July, and
that agreement between two independent derivations is the closest thing to
review these patches have had.

It is **not** evidence that the fixes work. Our copy's error paths are exactly
as unexercised as mainline's, which is why the cover letter claims source
inspection and nothing more. See
[the convergence finding](../../../findings/2026-08-02-vsi-iommu-mainline-convergence-and-resync-collision.md)
for the full comparison and for what it means at the next resync.

## Recipients

From `scripts/get_maintainer.pl` on the series:

```text
Benjamin Gaignard <benjamin.gaignard@collabora.com>   # VERISILICON IOMMU DRIVER, and authored the blamed commit
Joerg Roedel (AMD) <joro@8bytes.org>                  # IOMMU SUBSYSTEM
Will Deacon <will@kernel.org>                         # IOMMU SUBSYSTEM
Robin Murphy <robin.murphy@arm.com>                   # IOMMU SUBSYSTEM reviewer
iommu@lists.linux.dev
linux-kernel@vger.kernel.org
```

Two adjustments to that output. `get_maintainer.pl` also emits
`Joerg Roedel <joerg.roedel@amd.com>`, harvested from an old signature — use
`joro@8bytes.org` and drop the `amd.com` address. And
`linux-rockchip@lists.infradead.org` is not produced, because the driver's
MAINTAINERS block lists only `iommu@lists.linux.dev`; adding it is optional but
reasonable, since RK3588 is the only in-tree user.

## Reconstruct

```bash
git clone git://git.kernel.org/pub/scm/linux/kernel/git/iommu/linux.git
cd linux
git checkout b4f6d7b19f3ae
git am /path/to/rock-5b-ysp/kernel-drivers/patches/iommu-vsi-probe-fixes/000[123]-*.patch
```

`vsi-iommu.c` was byte-identical between this base and Torvalds
`3708dd9488440` when the series was prepared, so the
[2026-07-30 audit](../../docs/driver-architecture-comparison.md#12-current-mainline-and-maxline-rockchip-codec-audit-2026-07-30)
findings carry over to `iommu/next` unchanged. Re-check that before rebasing
onto a newer base.

Each patch carries an `Assisted-by:` trailer in mainline's documented format;
see [the tool-assisted contribution policy](../../../findings/2026-08-02-mainline-tool-assisted-contribution-policy.md)
for why that string is not the one this repository uses in its own commits.
