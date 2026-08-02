# Mainline absorbed the VSI IOMMU driver and its RK3588 DT node in v7.2-rc1, and our forward port will collide with both

> Scope: `drivers/iommu/vsi-iommu.c` and the RK3588 AV1 decoder IOMMU DT node,
> across mainline, the Collabora rockchip-3588 tree, the Rockchip BSP, and this
> project's forward-port series
> Source: `~/Code/rock-5b/kernel/linux-iommu-vsi-fixes` @ `iommu/next`
> `b4f6d7b19f3ae`; driver commit `917ace84b770`, DT commit `6ddfbec80077e`,
> both 2026-04-15; `collabora/rockchip-release` @ `566f27ab33057`;
> `rockchip-linux/kernel develop-6.1`; forward-port patches
> `rk3588-fwport-0005` and `rk3588-fwport-0009`
> Date: 2026-08-02
> Trust: SOURCE-INSPECTED, CONFIRMED

## Result

Mainline now carries the Verisilicon IOMMU driver **and** the RK3588 device-tree
node that binds it, both merged for **v7.2-rc1** on 2026-04-15:

| Thing | Commit | First tag |
|-------|--------|-----------|
| `drivers/iommu/vsi-iommu.c` | `917ace84b770` ("iommu: Add verisilicon IOMMU driver") | `v7.2-rc1` |
| `av1d_mmu: iommu@fdca0000` in `rk3588-base.dtsi` | `6ddfbec80077e` ("arm64: dts: rockchip: Add verisilicon IOMMU node on RK3588") | `v7.2-rc1` |

Neither is in 6.18, which is why the forward port had to supply both. The node
carries no `status` property, so it is **enabled by default**: a mainline kernel
booted on a ROCK 5B probes this driver without any DT work.

### The forward port will not rebase past v7.2 without conflict

`rk3588-fwport-0005` and mainline now add the same objects under the same names.
Every one of these is a direct collision:

| Object | Forward port | Mainline since v7.2-rc1 |
|--------|--------------|--------------------------|
| `drivers/iommu/vsi-iommu.c` | `create mode 100644` | exists |
| `Documentation/devicetree/bindings/iommu/verisilicon,iommu.yaml` | `create mode 100644` | exists |
| `drivers/iommu/Kconfig` | adds `config VSI_IOMMU`, **bool** | has `config VSI_IOMMU`, **tristate** |
| `drivers/iommu/Makefile` | adds `obj-$(CONFIG_VSI_IOMMU) += vsi-iommu.o` | identical line |
| Compatible matched | `verisilicon,iommu-1.2` | `verisilicon,iommu-1.2` |
| `av1d_mmu` DT node | added by `rk3588-fwport-0009` | in `rk3588-base.dtsi` |

A `git am` of `0005` onto anything at or past `v7.2-rc1` fails outright on the
two file creations, before any semantic question arises. The Kconfig help text
is word-for-word identical in both, which is the first hint that these are not
two independent drivers.

### It is not BSP code, and the defects came from the shared upstream source

The provenance matters because it inverts the usual direction of this project's
work. Rockchip's `develop-6.1` has **no** VSI IOMMU driver and no
`rk3588-av1-iommu` compatible anywhere in the tree — grepping the whole BSP
returns nothing. This driver never came from Rockchip.

It came from Collabora's `rockchip-3588` tree, which is also where mainline's
copy came from. `collabora/rockchip-release` @ `566f27ab33057` carries
`drivers/iommu/vsi-iommu.c`, and its `vsi_iommu_probe()` is character-identical
to the merged mainline version — including the distinctive `if  (` double space
before `(iommu->num_clocks < 0)`, which survives in both.

That shared ancestor carries all three defects the
[KRW-4 series](../kernel-drivers/patches/iommu-vsi-probe-fixes/README.md) fixes:

```c
	iommu->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(iommu->regs))
		return -ENOMEM;                       /* real error discarded */
	...
	iommu->irq = platform_get_irq(pdev, 0);
	if (iommu->irq < 0)
		return iommu->irq;                    /* clocks left prepared */
	...
	dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));   /* return dropped */
```

**This project's forward port is the only one of the three trees that has the
corrected form.** `rk3588-fwport-0005` ships `return PTR_ERR(iommu->regs)`, a
`goto err_unprepare_clocks` on the `platform_get_irq()` failure, and a checked
`dma_set_mask_and_coherent()`. The corrections were folded in silently during
the port — patch `0005`'s commit message describes only adding the provider and
never mentions error handling — so they are a source-review artifact, not a
response to an observed failure.

## Boundary

- The collision is established by comparing file paths, Kconfig symbols and
  compatible strings, not by attempting the rebase. Nobody has actually tried
  `git am`-ing `0005` onto v7.2; the two file creations are sufficient to know
  it fails, but the full conflict set past that point is unenumerated.
- "Our forward port has the corrected form" is a statement about source, not
  behavior. Those error paths have never been exercised in our tree either, so
  this is not evidence that the corrections work — only that they are present.
- The Collabora ancestry is established by identical source including a shared
  typo, plus the absence of the driver from the BSP. The exact Collabora commit
  our copy was taken from was not identified; `566f27ab33057` is the currently
  fetched tip, not necessarily the snapshot used.
- Whether mainline's `tristate` versus our `bool` Kconfig matters in practice
  was not investigated. Nothing here says the two drivers are functionally
  equivalent apart from the probe paths compared.

## Why it matters

**For the resync path.** [`resyncing.md`](../kernel-drivers/docs/resyncing.md)
treats the forward-port series as rebasing onto a newer mainline. For the IOMMU
patches that stops being true at v7.2: the correct move is to **drop** the
`vsi-iommu.c`, binding, Kconfig and Makefile halves of `0005` and the `av1d_mmu`
half of `0009`, and consume mainline's, rather than to resolve the conflict.
What remains genuinely ours in `0005` is the `rockchip-iommu.c` provider hooks
and the `include/soc/rockchip/` headers, which mainline does not have.

**For the upstream series.** The three fixes are not a discovery about someone
else's code that we happened to make — they are a correction this project has
been carrying downstream since July while the same defects went into mainline
through a different route. That does not change the patches, and it does not
strengthen them as evidence, because our copy's error paths are equally
unexercised. It does explain why a forward-port audit found real mainline bugs:
the two trees are the same code.

**For the AV1 track.** [`av1-rk3588.md`](../kernel-drivers/av1/docs/av1-rk3588.md)
records the `av1d_mmu` provider as something the forward port added. From
v7.2-rc1 that is upstream's job, and the mainline AV1 decode path has its own
IOMMU without any of our DT work.
