# The RGA rewrite's IOMMU-IRQ-mask fallback was unreachable, and it blocked the mainline mirror

> Scope: `rga-rewrite` fault-handler teardown, and the 6.18 → mainline port of
> the 2026-08-02 [adversarial review](../kernel-drivers/docs/rewrite-driver-adversarial-review-2026-08-02.md)
> Source: `rk3588-rewrite-6.18@2f05724a20036` (defect) → `501a2b47f3503` (fix);
> mainline `rk3588-rewrite-mainline@94e9ad41a19a2` → `694aac9b7c0ff`
> Date: 2026-08-03
> Trust: **SOURCE-PROVEN** (both provider implementations read),
> **BUILD-VERIFIED** (both objects, both kernel bases). Not boot-tested — no
> behavior change to test.

## Result

The 2026-08-02 hardening commit added a defensive fallback to
`rk_rga_iommu_unregister_fault_handler()`:

```c
ret = rockchip_iommu_set_fault_handler(hw->dev, NULL, NULL);
if (ret) {
	dev_warn(hw->dev, "failed to clear IOMMU fault handler: %pe\n",
		 ERR_PTR(ret));
	/*
	 * If the provider still exists but refused the clear, prevent a
	 * newly delivered IRQ from invoking the stale token after teardown.
	 */
	rockchip_iommu_mask_irq(hw->dev);
	return ret;
}
```

Its premise — "the provider still exists but refused the clear" — is a state
the provider cannot produce. `rockchip_iommu_set_fault_handler()` has exactly
one failure exit:

```c
struct rk_iommu *iommu = rk_iommu_from_dev_checked(dev);

if (!iommu)
	return -ENODEV;
/* ... store handler+token under fault_lock, return 0 ... */
```

It stores the handler under `fault_lock` and returns 0 unconditionally
afterwards, so `ret != 0` is equivalent to `rk_iommu_from_dev_checked(dev) ==
NULL`. And `rockchip_iommu_mask_irq()` opens with the *same* lookup:

```c
struct rk_iommu *iommu = rk_iommu_from_dev_checked(dev);

if (!iommu)
	return;
```

So on the only control path that reaches the fallback, the mask call returns
immediately without touching `RK_MMU_INT_MASK`. There is also nothing for it to
protect: with no `rk_iommu` for the device, no provider IRQ exists to deliver
and no token was ever stored to be invoked. The driver never calls
`rockchip_iommu_unmask_irq()` either, so had the mask ever applied, nothing
would have lifted it.

The identical MPP teardown (`mpp_rewrite.c`, the `RK_MPP_IOMMU_ROCKCHIP` /
`RK_MPP_IOMMU_VSI` clear switch) already reports the failure and returns, with
no mask fallback — so removing it makes the two rewrite drivers agree.

## How it surfaced

Not by reading the diff — by porting it. The mainline branch keeps a
deliberately minimal Rockchip IOMMU provider surface, declaring only the two
functions the rewrite track needs:

| Symbol | `rk3588-rewrite-6.18` | `rk3588-rewrite-mainline` |
|---|---|---|
| `rockchip_iommu_set_fault_handler()` | yes | yes |
| `rockchip_iommu_sync_fault_handler()` | yes | yes |
| `rockchip_iommu_enable/disable/is_enabled/force_reset()` | yes (BSP) | no |
| `rockchip_iommu_mask_irq()` / `unmask_irq()` | yes (BSP) | no |
| `rockchip_pagefault_done()` | yes (BSP) | no |

The 6.18 header guards the BSP set with `#if IS_ENABLED(CONFIG_ROCKCHIP_IOMMU)`
and supplies disabled-config stubs; the mainline header uses `IS_REACHABLE` and
declares only the fault-handler pair. Cherry-picking the hardening commit onto
mainline therefore applied cleanly and then failed to compile:

```
rga_rewrite.c:23882:17: error: implicit declaration of function
	‘rockchip_iommu_mask_irq’ [-Wimplicit-function-declaration]
```

`mpp_rewrite.o` built fine; only RGA referenced the missing helper. The compile
error is what forced the reachability question, and the answer made the choice
easy: the alternatives were to export a BSP helper into the upstream-shaped
branch, or to diverge the two driver files — both to serve a path that can
never execute.

## Fix

`501a2b47f3503` on 6.18, cherry-picked to mainline as `694aac9b7c0ff`: drop the
mask call, keep the warn-and-return, and replace the comment with the
reachability argument so the fallback is not reintroduced.

No functional change on either kernel.

## Verification

| Check | Result |
|---|---|
| `rga_rewrite.o` on 6.18 (`501a2b47f3503`) | Pass |
| `rga_rewrite.o` + `mpp_rewrite.o` on `v7.2-rc5` (`694aac9b7c0ff`) | Pass — first build of the review fixes on mainline |
| `mpp-rewrite/` + `rga-rewrite/` diff between the two tips | Empty — byte-identical restored |
| `kunit-manifest-check.sh` on both trees | Pass (92 MPP + 152 RGA) |
| `git diff --check` | Clean |

Built with an isolated `git worktree` under `~/Code/tmp` and a `defconfig` plus
`ROCKCHIP_{MPP,RGA}_REWRITE{,_KUNIT_TEST}=y`, `VIDEO_ROCKCHIP_RGA` and
`ROCKCHIP_MULTI_RGA` disabled to satisfy the rewrite Kconfig's `depends on !`
clauses. The shared `linux` worktree's `.config` was left untouched.

## What this does not close

The removal is provable from source and needs no boot, but it does not advance
the rewrite track's real gate: the review fixes remain unbooted. See
[`status.md`](../status.md) track 4 — KASAN package `#30` (`g2f05724a2003`) is
built and installed but never booted, and it predates this commit, so a
successor package is now required for the 92+152 run.

One process note worth keeping: this defect passed a three-lane adversarial
review that was looking for exactly this class of problem. It survived because
review read the fallback as *code that runs when the provider misbehaves*, and
never asked whether the provider can produce that state. Cross-kernel porting
caught it because the mainline branch's narrower surface made the dead
dependency a hard error rather than a silent one — an argument for keeping the
mainline mirror at parity as a review instrument, not only as a comparison tip.
