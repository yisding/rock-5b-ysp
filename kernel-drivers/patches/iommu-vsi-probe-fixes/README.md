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
