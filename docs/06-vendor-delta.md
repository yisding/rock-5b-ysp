# Exactly what we changed in the Rockchip 6.1 BSP

A line-level accounting of the forward-port: how much of the shipped driver code
is Rockchip's, and precisely what our changes were and why.

> This doc is the **quantitative** side — counts, percentages, and the complete
> per-change table. For the narrative rationale (why each hunk exists, the
> `compat/` and `hack/` story), see [`docs/05`](05-vendor-forward-port.md).

## Method

We diff every forward-ported file against its **original in the Rockchip 6.1 BSP
donor** (`rockchip-kernel/drivers/video/rockchip/`). A line in our tree is
counted as **ours** if it isn't byte-identical to the BSP (i.e. a `+` line in
`diff -u bsp ours`); everything else is **Rockchip, carried over unchanged**.
New files with no BSP counterpart (the `compat/` shims) are 100% ours. Generated
build artifacts (`*.mod.c`) are excluded.

Note a `diff -u` `+` line counts a **modified** line, not only a net addition —
a one-line edit shows as one `-` (old) plus one `+` (new), and we count the `+`.
So "ours" is *lines that differ*, which is why it reads higher than
`git diff --stat`'s net-added figure.

### Reproduce the count

The percentages are auditable against any future BSP with this loop.
`BSP` = the Rockchip 6.1 BSP donor checkout, `OURS` = the forward-ported
tree — both are pinned, with reconstruction recipes, in
[`docs/00`](00-source-trees.md) (`$OURS` is reproducible from
`patches/rk3588-rkvenc2-01…` on v6.18; you don't need the original dev box):

```sh
for f in mpp/mpp_common.c mpp/mpp_iommu.c mpp/mpp_iommu.h mpp/mpp_service.c \
         mpp/mpp_common.h mpp/mpp_rkvenc2.c mpp/mpp_rkvdec2.c \
         mpp/mpp_rkvdec2_link.c rga3/rga_drv.c rga3/rga_iommu.c rga3/rga_mm.c; do
  printf '%-26s %s\n' "$f" "$(diff -u "$BSP/$f" "$OURS/$f" | grep -c '^+[^+]')"
done
```

(`grep '^+[^+]'` skips the `+++` file-header line.) As measured today: MPP core
sums to **139**, RGA3 to **38**, of which `rga_mm.c` is **21**.

> We ported the **minimal subset** of the MPP framework needed for the two
> codecs: 6 of the BSP's 17 `mpp_*.c` files (`mpp_common`, `mpp_iommu`,
> `mpp_service`, `mpp_rkvenc2`, `mpp_rkvdec2`, `mpp_rkvdec2_link`) — **not** the
> legacy VPU1/2, VEPU1/2, RKVDEC-v1, JPEG, AV1, IEP, or VDPP blocks.

## The headline

| Category | Total lines | Ours | Rockchip | % ours |
|----------|-------------|------|----------|--------|
| MPP core (`mpp/*.c,*.h`) | 13,965 | 139 | 13,826 | 1.0% |
| MPP `compat/` (our shim layer, **new files**) | 338 | 338 | 0 | 100% |
| MPP `hack/` (restored verbatim from BSP) | 1,445 | 0 | 1,445 | 0% |
| RGA3 (`rga3/**`) | 19,099 | 38 | 19,061 | 0.2% |
| Kconfig / Makefile wiring | 152 | 63 | 89 | 41% |
| **Total** | **34,999** | **578** | **34,421** | **≈ 1.7%** |

**≈ 98% of the code is Rockchip's BSP, carried over unchanged. Our forward-port
is ≈ 1.7% — about 580 lines**, and of those, 338 are a small new compatibility
shim layer, ~140 are surgical in-place edits, and ~60 are build wiring. The big
files are essentially untouched: `mpp_common.c` (2,691 lines) changed by **3**,
`mpp_rkvdec2_link.c` (2,763) by **22**, `rga_mm.c` (2,556) by **21**.

> Integers are the **measured** diff counts (see *Reproduce the count* above) and
> will drift slightly against a future BSP; the **≈ 580 / 1.7% / 98% headline
> holds** regardless.

This is the point of the structure: keep the vendor code as close to the BSP as
possible (easy to re-sync), and confine our deltas to a shim directory plus a
handful of well-commented hunks.

---

## Every change, and what it was for

### 1. 6.18 kernel-API adaptations — *make it compile/run on 6.18*

These are pure "the kernel API moved" fixes. Each is commented in-tree. **This
table is for driver developers** re-syncing or auditing the port; the `Since`
column is the mainline kernel version the new API first appeared in, so a
re-syncer can tell which deltas a *newer* kernel still needs (anchored by version
only — we do **not** cite commit SHAs, and `—` means "not version-pinned here").

| Change | File(s) | Since | Why |
|--------|---------|-------|-----|
| `f.file` → `fd_file(f)` | `mpp_common.c` | 6.11 | the `struct fd` accessor changed; `.file` is now reached via `fd_file()` |
| `class_create(THIS_MODULE, name)` → `class_create(name)` | `mpp_service.c` | 6.4 | `class_create()` dropped the `THIS_MODULE` argument |
| platform `.remove` returns `void` (was `int`) | `mpp_service.c`, `mpp_rkvdec2.c` | 6.11 | the platform-driver `remove` callback signature changed to `void` |
| `MODULE_IMPORT_NS(DMA_BUF)` → `MODULE_IMPORT_NS("DMA_BUF")` | `mpp_service.c`, `rga_drv.c` | 6.13 | requires the namespace as a quoted string literal |
| `dma_buf_{map,unmap}_attachment`, `dma_buf_{vmap,vunmap}` → `_unlocked` | `mpp_iommu.c` | 6.2 | the locked variants now assert `dma_resv` is held; the unlocked ones are correct here |
| `<linux/dma-buf-cache.h>` → `<linux/dma-buf.h>` | `mpp_iommu.c` | — | the BSP's `dma-buf-cache` doesn't exist upstream; the cache path folds to dead code |
| `iommu_map(... , GFP_KERNEL)` | `mpp_rkvdec2.c` | 6.3 | `iommu_map()` gained a `gfp` argument |
| `MAX_ORDER` → `MAX_PAGE_ORDER` | `mpp_rkvdec2.c` | 6.8 | the constant was renamed |
| `hrtimer_init()` + `.function=` → `hrtimer_setup()` | `rga_drv.c` | — | hrtimer init was consolidated into one call |
| `__pte_offset_map_lock()` → `follow_pfnmap_start()/end()` | `rga_mm.c` | 6.12 | `__pte_offset_map_lock()` is no longer module-exported on 6.12+; `follow_pfnmap_*()` is the GPL-exported page-table walker (version-gated) |
| `iommu_dma_cookie` shadow struct: `iovad` moved to offset 0 (+ `BUILD_BUG_ON`, `mpp_iommu.c:719`) | `mpp_iommu.h`, `mpp_iommu.c` | 6.18 | 6.18 deleted the leading `enum iommu_dma_cookie_type type` member; our shadow struct (used to reach `iovad` via `iommu_domain->iova_cookie`) must keep `iovad` first |
| `iommu_set_fault_handler()` guarded by `cookie_type == IOMMU_COOKIE_NONE` | `mpp_iommu.c`, `rga_iommu.c` | 6.18 | the IOMMU core now WARNs if the domain already owns a cookie (e.g. the default DMA domain); only register our handler on a cookie-less domain |
| `-DMPP_VERSION="6.18-rkvenc-fwport"` (`ccflags-y`) | `mpp/Makefile` | — | replaces the donor's `$(shell git …)` version string, which fails in this tree (no vendor git metadata) |

### 2. Bring-up / correctness fixes — *make the cores actually bind on RK3588*

Four hunks (part of the ~140 in-place edits), surfaced by probing real hardware
and relevant on any kernel. Narrated in full in
[`docs/05`](05-vendor-forward-port.md) (§ C — Bring-up fixes); the `file:symbol`
anchors are pinned here so the line-level count stays auditable:

| Hunk | `file:symbol` (anchor) |
|------|------------------------|
| `CONFIG_CPU_RK3588` of_match unguard | `mpp_rkvenc2.c` `mpp_rkvenc_dt_match[]` (`rockchip,rkv-encoder-v2-core`, ~:2867-2871) + decoder `mpp_rkvdec2.c` `rockchip,rkv-decoder-v2` of_match |
| attach_ccu `-EPROBE_DEFER` (+ `put_device`, + core0-not-ready guard) | `rkvenc_attach_ccu()` `mpp_rkvenc2.c:2904` (`put_device`:2930, `-EPROBE_DEFER`:2931); `rkvdec2_attach_ccu()` `mpp_rkvdec2.c` (call site :1949) |
| publish CCU `drvdata` **last** | `rkvenc_ccu_probe()` `mpp_rkvenc2.c:2880` (`platform_set_drvdata`:2899); `rkvdec2_ccu_probe()` `mpp_rkvdec2.c:1740` (:1757) |
| compatible-based decoder dispatch | `rkvdec2_probe()` `mpp_rkvdec2.c:2083-2087` (`of_device_is_compatible` before the `strstr(np->name,…)` fallback) |

### 3. Devfreq / OPP de-noise — *the BSP DVFS stack isn't on mainline*

The devfreq islands are `#ifdef`-gated off (`default n`), the `init_opp_table` /
`add venc devfreq` `dev_err`s are downgraded to `dev_dbg`, and devfreq teardown is
`NULL`-guarded. Narrated in [`docs/05`](05-vendor-forward-port.md) (§ B — OPP /
devfreq de-noised).

### 4. The `compat/` shim layer — *stand in for BSP-only SoC headers* (338 lines, all new)

Thin headers under `mpp/compat/` so the vendor `.c` files keep their original
`#include`s and call sites. Mostly no-op stubs:

`rockchip_pmu_idle.h`, `rockchip_opp_select.h`, `rockchip_system_monitor.h`,
`rockchip_iommu.h`, `rockchip_dmc.h`, `rockchip_ipa.h`, `rockchip_sip.h`,
`rockchip_qos_compat.h`. See [`docs/05`](05-vendor-forward-port.md).

### 5. Wiring — Kconfig / Makefile (63 lines)

In-tree `obj-$(CONFIG_…)` rules and the menu structure, plus `default y` on
`ROCKCHIP_MPP_SERVICE` / `ROCKCHIP_MULTI_RGA` and `select SYNC_FILE` (so the
config travels in the patch — `docs/08`). The `hack/` files are restored
verbatim from the BSP and **must not be deleted** ([`docs/10`](10-gotchas.md)).

### 6. Residual TODOs (W-tags)

Several shim banners point at `W6` / `W15` / "see Residual TODOs" (e.g.
`rockchip_opp_select.h:8,11`, `rockchip_ipa.h:8`, `rockchip_system_monitor.h:12`,
`rockchip_iommu.h:22`) but no master list lives in the tree. Consolidated here —
these are **intentionally stubbed**, not bugs; a production path would restore
them. See [`docs/12`](12-resyncing.md) for the maintenance view.

| Tag | What's stubbed | Production path |
|-----|----------------|-----------------|
| **W6** | dead/dvfs-off includes: `rockchip_ipa.h` is a dead include; the devfreq islands are `default n` | delete the dead `#include` (`mpp_rkvenc2.c:31`); leave devfreq off unless DVFS is wired |
| **W15** | real OPP voltage/leakage management absent — `rkvenc_devfreq_init()` bails on the `-EOPNOTSUPP` stub | port the OPP/PVTM voltage stack, or drive voltage from a mainline regulator/devfreq governor |
| iommu fault-mask | `rockchip_iommu_mask_irq()` is a no-op → the pagefault-handler fault-storm guard is disabled | a real mask path against the mainline `rockchip-iommu` driver |
| system-monitor | `rockchip_system_monitor_register()` → `ERR_PTR(-ENODEV)`; encoder runs without SoC thermal/voltage monitoring | register the venc as a mainline thermal-cooling device |

---

## What this says

The forward-port did **not** rewrite or "clean up" the vendor code — it kept
~98% byte-identical and adapted the ~2% that the 6.1→6.18 kernel API churn
demanded, plus the minimum to bind on RK3588 and to package cleanly for Armbian.
Any latent bugs or non-idiomatic patterns in the BSP code are *still there* —
the companion audit-and-clean effort now lives **in this repo**:
[`docs/11`](11-bsp-audit.md) is the audit (89 reviewer findings, 16 HIGH), the
fixes are the reviewable 65-patch series in
[`patches/cleanup-split/`](../patches/cleanup-split/) (with the per-file
history and verification record in
[`patches/cleanup-draft/`](../patches/cleanup-draft/)) — all kept **separate**
from this conservative forward-port, and with the **runtime regression gate
still PENDING** ([`VERIFICATION.md`](../patches/cleanup-draft/VERIFICATION.md)).
