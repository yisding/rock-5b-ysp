# IOMMU-machinery debug patch set

Instrumentation to make the whole RK3588 IOMMU surface **observable** while
`kernel-drivers/tests/iommu-machinery-fuzz.sh` stresses it. These are additive to
the DIAG stack already in the fwport tree — DIAG shows the Route B *trigger*
(multi-segment `dma_map_sg` + contiguity); these show what happens *after* the
trigger, across *both* IOMMU providers, plus a leak/coverage signal.

Nothing here changes driver behavior except the opt-in force knob (default off).
Line anchors are against `../kernel/linux-6.18-rkvenc-av1-fwport` at the DIAG HEAD.

| # | File(s) | Adds | Runner signal |
|---|---------|------|---------------|
| 1 | `drivers/iommu/rockchip-iommu.c` | per-device page/bus-fault counter + debugfs | `rk_iommu` fault deltas |
| 2 | `drivers/iommu/vsi-iommu.c` | per-device fault counter + debugfs (AV1 path) | `vsi_iommu` fault deltas |
| 3 | `drivers/video/rockchip/rga3/{rga_dma_buf.c,rga_debugger.c}` | Route B stats + **active gauge** + interior trace + `force_iommu_remap` knob | `rkrga/route_b/*` coverage + leak check |
| 4 | `kconfig-debug.fragment` | `DMA_API_DEBUG`, `KALLSYMS_ALL`, `IOMMU_DEBUGFS` | `DMA-API:` dmesg lines |

> **Status.** The config layer (patch 4) is **build-wired**: `IOMMU_DEBUG=yes`
> makes `build-armbian-deb.sh` stage an Armbian `custom_kernel_config` hook
> ([`lib.config`](lib.config)) that enables `DMA_API_DEBUG` / `KALLSYMS_ALL` /
> `IOMMU_DEBUGFS` (staged/removed each run so the userpatches reset can't strand
> it). The **driver instrumentation** (patches 1–3: per-master fault counters,
> Route B stats/gauge, force knob) was applied and compile-verified with
> `ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`, then dropped when
> `rkvenc-fwport-6.18` was rebased clean (HEAD is now Route B + the rkvenc RCB
> fix, no DIAG). It is **not currently on the branch**. Re-apply it as either
> port commits or — to match the build-time debug-overlay model — staged
> `IOMMU_DEBUG` userpatches. Until then, a debug build has the config-level
> signals (`DMA-API:` dmesg lines, kprobe-able helpers) but **not** the
> `route_b/*` or `*-iommu/<dev>` debugfs counters. The sections below are the
> reference for re-applying. Signal usage:
> [`../../tests/IOMMU-FUZZING.md`](../../tests/IOMMU-FUZZING.md).

---

## Patch 1 — rockchip-iommu per-device fault counter

Covers RGA3, RKVDEC/VP9/H26x video-codec cores, RKVENC, VOP, NPU.

**`struct rk_iommu`** (after `struct device *dev;`, ~line 114):
```c
	u64 fault_count;		/* page + bus faults seen by this MMU */
```

**`rk_iommu_irq()`** — count on the fault branches (~line 619 page fault, ~line 660 bus error). One line at the top of each `if`:
```c
	if (int_status & RK_MMU_IRQ_PAGE_FAULT) {
		iommu->fault_count++;			/* <-- add */
		...
	if (int_status & RK_MMU_IRQ_BUS_ERROR) {
		iommu->fault_count++;			/* <-- add */
```

**`rk_iommu_probe()`** — expose it (after `iommu->dev = dev;` ~line 1508). Flat file per device so the runner's maxdepth-1 snapshot reads it:
```c
	{
		static struct dentry *rk_iommu_dbg;	/* shared root, created once */
		if (!rk_iommu_dbg)
			rk_iommu_dbg = debugfs_create_dir("rockchip-iommu", NULL);
		debugfs_create_u64(dev_name(dev), 0444, rk_iommu_dbg,
				   &iommu->fault_count);
	}
```
(Needs `#include <linux/debugfs.h>` if not already present.)

Result: `/sys/kernel/debug/rockchip-iommu/<addr>.iommu` = fault count.

---

## Patch 2 — vsi-iommu per-device fault counter (AV1 decoder path)

The `av1d` decoder rides `vsi-iommu.c`, a *separate* provider, so it needs its own
counter or AV1 faults are invisible to Patch 1.

**`struct vsi_iommu`** (~line 43, alongside `fault_lock`):
```c
	u64 fault_count;
```
**`vsi_iommu_irq()`** — in the `if (fault)` block (~line 257):
```c
	if (fault) {
		iommu->fault_count++;			/* <-- add */
		...
```
**Probe** (wherever `iommu->dev` is set / `request_irq` is wired, mirror Patch 1):
```c
	{
		static struct dentry *vsi_iommu_dbg;
		if (!vsi_iommu_dbg)
			vsi_iommu_dbg = debugfs_create_dir("vsi-iommu", NULL);
		debugfs_create_u64(dev_name(iommu->dev), 0444, vsi_iommu_dbg,
				   &iommu->fault_count);
	}
```
Result: `/sys/kernel/debug/vsi-iommu/<addr>` = AV1-IOMMU fault count.

---

## Patch 3 — RGA Route B stats + active gauge + force knob + trace

### 3a. Counters (`rga_dma_buf.c`, file scope near the Route B helpers)
```c
static atomic_t rgb_attempt, rgb_ok, rgb_active;	/* rgb = route-b */
static atomic_t rgb_fail_granule, rgb_fail_iova, rgb_fail_map, rgb_fail_span;
```
Wire them in `rga_dma_map_sgt_iommu()` (~line 219): `atomic_inc(&rgb_attempt)` on
entry; at each fail `goto`, bump the matching `rgb_fail_*`; on success
(~line 291) `atomic_inc(&rgb_ok); atomic_inc(&rgb_active);`. In
`rga_dma_unmap_sgt_iommu()` (~line 305) `atomic_dec(&rgb_active)`.
The **granule** fail lives in `rga_dma_alloc_iommu_iova()` — bump `rgb_fail_granule`
on the `PAGE_SIZE` reject; `rgb_fail_iova` on `alloc_iova_fast` empty;
`rgb_fail_map` on partial `iommu_map_sg`; `rgb_fail_span` on the overflow check.

`rgb_active` is the **leak canary**: the runner asserts it returns to baseline.

### 3b. Interior trace (gated, no dmesg flood)
At the top of `rga_dma_map_sgt_iommu()` and at each fail `goto`:
```c
	if (DEBUGGER_EN(MM))
		rga_err("routeB: enter nents=%u size=%zu off=%#zx\n",
			sgt->orig_nents, data_size, offset);
	/* on fail: rga_err("routeB: FAIL <reason> ret=%d\n", ret); */
	/* on ok:   rga_err("routeB: ok base=%pad size=%#zx prog=%pad\n", ...); */
```
Move the existing DIAG `rga_err` behind `DEBUGGER_EN(MM)` too, so verbosity is a
runtime switch (`echo mm > /sys/kernel/debug/rkrga/debug`) and fuzz loops don't
drown `dmesg`.

### 3c. Force knob (100% coverage + same-buffer differential)
`rga_dma_map_sgt()` is the driver-owned path *only* (dma-buf uses
`rga_dma_map_buf()`), so forcing here can't weaken the dma-buf contract:
```c
static bool rga_force_iommu_remap;
module_param(rga_force_iommu_remap, bool, 0644);
MODULE_PARM_DESC(rga_force_iommu_remap,
	"debug: route every driver-owned map through Route B even if contiguous");
```
In `rga_dma_map_sgt()`, after the contract check passes and before
`rga_dma_set_buffer_mapping()` (~line 489):
```c
	if (rga_force_iommu_remap) {
		dma_unmap_sg(map_dev, sgt->sgl, sgt->orig_nents, dir);
		rga_dma_reset_sgt_dma_state(sgt);
		return rga_dma_map_sgt_iommu(sgt, buffer, dir, map_dev);
	}
```
Toggle at runtime: `echo 1 > /sys/module/rga3/parameters/rga_force_iommu_remap`
(module name may be `rga` — check `/sys/module/`). With it on, the fuzzer's
*contiguous* buffers also traverse Route B, giving a same-buffer normal-vs-RouteB
diff with zero dependence on the scatter trick.

### 3d. Expose counters as a `route_b` debugfs subdir (`rga_debugger.c`)
In `rga_debugfs_init()` after the root dir is created (~line 678), matching the
runner's `rkrga → /sys/kernel/debug/rkrga/route_b` snapshot path:
```c
	{
		struct dentry *rb = debugfs_create_dir("route_b", rga_debugfs_root);
		debugfs_create_atomic_t("attempt",      0444, rb, &rgb_attempt);
		debugfs_create_atomic_t("ok",           0444, rb, &rgb_ok);
		debugfs_create_atomic_t("active",       0444, rb, &rgb_active);
		debugfs_create_atomic_t("fail_granule", 0444, rb, &rgb_fail_granule);
		debugfs_create_atomic_t("fail_iova",    0444, rb, &rgb_fail_iova);
		debugfs_create_atomic_t("fail_map",     0444, rb, &rgb_fail_map);
		debugfs_create_atomic_t("fail_span",    0444, rb, &rgb_fail_span);
	}
```
Export the `rgb_*` atomics (or a small accessor) from `rga_dma_buf.c` so
`rga_debugger.c` can reference them.

---

## Optional Patch 5 — KUnit fail-closed unit (`CONFIG_KUNIT=m`)

The `granule > PAGE_SIZE` and 32-bit-span-overflow rejects can't be hit at runtime
on RK3588 (4 KiB granule, guard band holds). A tiny KUnit module that calls the
Route B span/granule checkers with synthetic pathological inputs covers those
branches deterministically. Lower priority; ask and I'll write it.

---

## Apply + build

```sh
# 1. config
./scripts/kconfig/merge_config.sh -m .config kernel-drivers/patches/iommu-debug/kconfig-debug.fragment
make olddefconfig
# 2. patches 1–3 by hand (above) or ask for git-apply-ready diffs
# 3. build as usual; boot; then:
sudo kernel-drivers/tests/iommu-machinery-fuzz.sh          # full A+B+C run
```
With the instrumented kernel, a run prints `route_b/*` deltas (proving the
fallback fired and how often), per-master fault counts from both providers, any
`DMA-API:` violations, and asserts the `active` gauge returned to baseline.
