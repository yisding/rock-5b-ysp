# Exactly what we changed in the Rockchip 6.1 BSP

A line-level accounting of the forward-port: how much of the shipped driver code
is Rockchip's, and precisely what our changes were and why.

## Method

We diff every forward-ported file against its **original in the Rockchip 6.1 BSP
donor** (`rockchip-kernel/drivers/video/rockchip/`). A line in our tree is
counted as **ours** if it isn't byte-identical to the BSP (i.e. a `+` line in
`diff -u bsp ours`); everything else is **Rockchip, carried over unchanged**.
New files with no BSP counterpart (the `compat/` shims) are 100% ours. Generated
build artifacts (`*.mod.c`) are excluded.

> We ported the **minimal subset** of the MPP framework needed for the two
> codecs: 6 of the BSP's 17 `mpp_*.c` files (`mpp_common`, `mpp_iommu`,
> `mpp_service`, `mpp_rkvenc2`, `mpp_rkvdec2`, `mpp_rkvdec2_link`) — **not** the
> legacy VPU1/2, VEPU1/2, RKVDEC-v1, JPEG, AV1, IEP, or VDPP blocks.

## The headline

| Category | Total lines | Ours | Rockchip | % ours |
|----------|-------------|------|----------|--------|
| MPP core (`mpp/*.c,*.h`) | 13,965 | 141 | 13,824 | 1.0% |
| MPP `compat/` (our shim layer, **new files**) | 338 | 338 | 0 | 100% |
| MPP `hack/` (restored verbatim from BSP) | 1,445 | 0 | 1,445 | 0% |
| RGA3 (`rga3/**`) | 19,099 | 39 | 19,060 | 0.2% |
| Kconfig / Makefile wiring | 152 | 63 | 89 | 41% |
| **Total** | **34,999** | **581** | **34,418** | **≈ 1.7%** |

**≈ 98% of the code is Rockchip's BSP, carried over unchanged. Our forward-port
is ≈ 1.7% — about 580 lines**, and of those, 338 are a small new compatibility
shim layer, ~180 are surgical in-place edits, and ~60 are build wiring. The big
files are essentially untouched: `mpp_common.c` (2,691 lines) changed by **3**,
`mpp_rkvdec2_link.c` (2,763) by **22**, `rga_mm.c` (2,556) by **22**.

This is the point of the structure: keep the vendor code as close to the BSP as
possible (easy to re-sync), and confine our deltas to a shim directory plus a
handful of well-commented hunks.

---

## Every change, and what it was for

### 1. 6.18 kernel-API adaptations — *make it compile/run on 6.18*

These are pure "the kernel API moved" fixes. Each is commented in-tree.

| Change | File(s) | Why |
|--------|---------|-----|
| `f.file` → `fd_file(f)` | `mpp_common.c` | the `struct fd` accessor changed; `.file` is now reached via `fd_file()` |
| `class_create(THIS_MODULE, name)` → `class_create(name)` | `mpp_service.c` | `class_create()` dropped the `THIS_MODULE` argument |
| platform `.remove` returns `void` (was `int`) | `mpp_service.c`, `mpp_rkvdec2.c` | the platform-driver `remove` callback signature changed to `void` |
| `MODULE_IMPORT_NS(DMA_BUF)` → `MODULE_IMPORT_NS("DMA_BUF")` | `mpp_service.c`, `rga_drv.c` | 6.13+ requires the namespace as a quoted string literal |
| `dma_buf_{map,unmap}_attachment`, `dma_buf_{vmap,vunmap}` → `_unlocked` | `mpp_iommu.c` | the locked variants now assert `dma_resv` is held; the unlocked ones are correct here |
| `<linux/dma-buf-cache.h>` → `<linux/dma-buf.h>` | `mpp_iommu.c` | the BSP's `dma-buf-cache` doesn't exist upstream; the cache path folds to dead code |
| `iommu_map(... , GFP_KERNEL)` | `mpp_rkvdec2.c` | `iommu_map()` gained a `gfp` argument |
| `MAX_ORDER` → `MAX_PAGE_ORDER` | `mpp_rkvdec2.c` | the constant was renamed |
| `hrtimer_init()` + `.function=` → `hrtimer_setup()` | `rga_drv.c` | hrtimer init was consolidated into one call |
| `__pte_offset_map_lock()` → `follow_pfnmap_start()/end()` | `rga_mm.c` | `__pte_offset_map_lock()` is no longer module-exported on 6.12+; `follow_pfnmap_*()` is the GPL-exported page-table walker (version-gated) |
| `iommu_dma_cookie` shadow struct: `iovad` moved to offset 0 (+ `BUILD_BUG_ON`) | `mpp_iommu.h`, `mpp_iommu.c` | 6.18 deleted the leading `enum iommu_dma_cookie_type type` member; our shadow struct (used to reach `iovad` via `iommu_domain->iova_cookie`) must keep `iovad` first |
| `iommu_set_fault_handler()` guarded by `cookie_type == IOMMU_COOKIE_NONE` | `mpp_iommu.c`, `rga_iommu.c` | the IOMMU core now WARNs if the domain already owns a cookie (e.g. the default DMA domain); only register our handler on a cookie-less domain |

### 2. Bring-up / correctness fixes — *make the cores actually bind on RK3588*

Surfaced by probing real hardware; they matter on any kernel.

| Change | File(s) | Why |
|--------|---------|-----|
| Remove `CONFIG_CPU_RK3588` guard on the RK3588 `of_device_id` entries | `mpp_rkvenc2.c`, `mpp_rkvdec2.c` | mainline/Armbian configs never define `CONFIG_CPU_RK3588`, so the cores would never bind. Made unconditional (harmless elsewhere — no matching DT nodes) |
| `attach_ccu` returns **`-EPROBE_DEFER`** (was `-ENOMEM`/oops) when the CCU isn't probed yet; **`-EPROBE_DEFER`** if core 0 isn't ready when a secondary core attaches; `put_device()` on the defer path | `mpp_rkvenc2.c`, `mpp_rkvdec2_link.c` | probe order is only guaranteed for a built-in driver; a module (or different boot order) can probe a core before its CCU/core 0, which hard-failed or NULL-deref'd `queue->cores[0]` |
| Publish CCU `drvdata` **last** (after `mutex_init`/list init) | `mpp_rkvenc2.c` (+ decoder) | so a core's "`drvdata != NULL` ⇒ CCU ready" test can't observe a half-initialised CCU |
| Dispatch by **compatible** first (`of_device_is_compatible`), fall back to node-name `strstr` | `mpp_rkvdec2.c` | lets a generic-named node (Armbian's `video-codec@…`, retyped in place) reach `core_probe` — the enabler for the zero-edit convert-in-place packaging (`docs/04`) |

### 3. Devfreq / OPP de-noise — *the BSP DVFS stack isn't on mainline*

| Change | File(s) | Why |
|--------|---------|-----|
| `RKVENC2_DEVFREQ` / `RKVDEC2_DEVFREQ` `#ifdef`-gated (default `n`) | `mpp_rkvenc2.c`, `mpp_rkvdec2.c` | the devfreq islands pull BSP-only governor headers; off by default |
| `dev_err` → `dev_dbg` for `init_opp_table` / `add venc devfreq` | `mpp_rkvenc2.c` | with OPP stubbed, these aren't errors — the core runs at fixed DT `assigned-clock-rates` |
| Guard devfreq teardown on `enc->devfreq != NULL` | `mpp_rkvenc2.c` | otherwise a symmetric `--governor_count` underflows a counter that was never incremented |

### 4. The `compat/` shim layer — *stand in for BSP-only SoC headers* (338 lines, all new)

Thin headers under `mpp/compat/` so the vendor `.c` files keep their original
`#include`s and call sites. Mostly no-op stubs:

`rockchip_pmu_idle.h`, `rockchip_opp_select.h`, `rockchip_system_monitor.h`,
`rockchip_iommu.h`, `rockchip_dmc.h`, `rockchip_ipa.h`, `rockchip_sip.h`,
`rockchip_qos_compat.h`. See [`docs/02`](02-vendor-forward-port.md).

### 5. Wiring — Kconfig / Makefile (63 lines)

In-tree `obj-$(CONFIG_…)` rules and the menu structure, plus `default y` on
`ROCKCHIP_MPP_SERVICE` / `ROCKCHIP_MULTI_RGA` and `select SYNC_FILE` (so the
config travels in the patch — `docs/04`). The `hack/` files are restored
verbatim from the BSP and **must not be deleted** ([`docs/06`](06-gotchas.md)).

---

## What this says

The forward-port did **not** rewrite or "clean up" the vendor code — it kept
~98% byte-identical and adapted the ~2% that the 6.1→6.18 kernel API churn
demanded, plus the minimum to bind on RK3588 and to package cleanly for Armbian.
Any latent bugs or non-idiomatic patterns in the BSP code are *still there* — see
the companion effort to audit and optionally clean the BSP code in a **separate**
patch series (tracked outside this conservative forward-port).
