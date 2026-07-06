# IOMMU-machinery debug patch set

Instrumentation to make the whole RK3588 IOMMU surface **observable** while
`kernel-drivers/tests/iommu-machinery-fuzz.sh` stresses it. The forward-port
keeps this out of the clean .deb path; apply it only when building a diagnostic
kernel.

Nothing here changes driver behavior except the opt-in force knob (default off).
`forward-port-route-b/` archives the debug-only commits removed from
`../kernel/linux-6.18-rkvenc-av1-fwport` on 2026-07-06. The same commits remain
reachable in that kernel repo on branch `rkvenc-fwport-6.18-iommu-debug-20260706`.
The clean forward-port branch now stops before these diagnostics.

| # | File(s) | Adds | Runner signal |
|---|---------|------|---------------|
| 1 | `drivers/iommu/rockchip-iommu.c` | per-device page/bus-fault counter + debugfs | `rk_iommu` fault deltas |
| 2 | `drivers/iommu/vsi-iommu.c` | per-device fault counter + debugfs (AV1 path) | `vsi_iommu` fault deltas |
| 3 | `drivers/video/rockchip/rga3/{rga_dma_buf.c,rga_debugger.c}` | Route B stats + **active gauge** + interior trace + `force_iommu_remap` knob | `rkrga/route_b/*` coverage + leak check |
| 4 | `kconfig-debug.fragment` | `DMA_API_DEBUG`, `KALLSYMS_ALL`, `IOMMU_DEBUGFS` | `DMA-API:` dmesg lines |

> **Status.** The driver instrumentation is archived here, not carried by the
> clean forward-port branch. A plain `build-armbian-deb.sh` run therefore builds
> the functional Route B forward-port without `DIAG` dmesg traces, per-master
> debugfs fault counters, or `rkrga/route_b/*` counters/force knob.
>
> The **config layer** (patch 4: `DMA_API_DEBUG` / `KALLSYMS_ALL` /
> `IOMMU_DEBUGFS`) is opt-in via `IOMMU_DEBUG=yes`, which stages an Armbian
> **extension** ([`extensions/ysp-iommu-debug.sh`](extensions/ysp-iommu-debug.sh))
> and passes `ENABLE_EXTENSIONS=ysp-iommu-debug` to `compile.sh`. **Do not** use
> `userpatches/lib.config` for this: Armbian sources `lib.config` *after* the
> extension manager has initialized, so a `custom_kernel_config` hook defined
> there is never registered (Armbian calls it "wishful hooking"; see
> `lib/functions/configuration/main-config.sh`). The earlier `lib.config` wiring
> silently no-op'd — an `IOMMU_DEBUG=yes` build came out byte-identical to a
> normal one, with `DMA_API_DEBUG` still unset. The extension path is the fix.
>
> Net: a plain build is clean. To recreate the diagnostic kernel used for Route B
> attribution, first apply `forward-port-route-b/*.patch` to the kernel tree,
> then build with `IOMMU_DEBUG=yes` if you also want config-level DMA/IOMMU
> auditing. Signal usage:
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

Clean Armbian .deb build, with the archived diagnostics excluded:

```sh
bash kernel-drivers/scripts/build-armbian-deb.sh
```

Diagnostic Armbian .deb build with the archived Route B/IOMMU instrumentation:

```sh
cd ../kernel/linux-6.18-rkvenc-av1-fwport
git switch rkvenc-fwport-6.18-iommu-debug-20260706
cd ../../rock-5b-ysp
IOMMU_DEBUG=yes bash kernel-drivers/scripts/build-armbian-deb.sh
# reboot into the new kernel, then:
sudo env IOMMU_FUZZ_REQUIRE_ROUTE_B_COUNTERS=1 \
  PHASES=ABC RGA_ITERS=128 DECODE_LOOPS=3 \
  bash kernel-drivers/tests/iommu-machinery-fuzz.sh
```

For a **direct / non-Armbian** debug kernel build, apply the patch bundle and
config fragment yourself:

```sh
git switch -c rkvenc-fwport-6.18-debug-work rkvenc-fwport-6.18
git am /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/iommu-debug/forward-port-route-b/*.patch
./scripts/kconfig/merge_config.sh -m .config /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/iommu-debug/kconfig-debug.fragment
make olddefconfig && make ...     # build as usual; boot; then run the fuzzer above
```

With the instrumented kernel, a run prints `route_b/*` deltas (proving the
fallback fired and how often), per-master fault counts from both providers, any
`DMA-API:` violations, and asserts the `active` gauge returned to baseline.
