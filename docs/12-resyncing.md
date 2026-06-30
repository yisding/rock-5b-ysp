# Re-syncing against a newer BSP / a newer kernel

The maintenance view. When you bump the donor (a newer Rockchip BSP) or the host
kernel (a newer mainline/Armbian), this is what to re-check and in what order.
The forward-port deliberately keeps ~98% of the vendor code byte-identical
([`docs/06`](06-vendor-delta.md)) and confines the deltas to a shim layer
([`docs/05`](05-vendor-forward-port.md)), so re-syncing is mostly *re-applying a
small, well-located set of changes* — but a few of them are fragile against
kernel-internal churn. Read this before you start.

---

## 1. The two shim-inclusion mechanisms — and when each breaks

Everything in `mpp/compat/` reaches the vendor `.c` files by **one of two
techniques** ([`docs/05`](05-vendor-forward-port.md) § How the shims get
included). A re-sync that fails to build almost always traces back to one of
these flipping:

**(1) `-I$(src)/compat` header-search shadowing** — for BSP headers with **no
upstream counterpart** (`rockchip_iommu`, `rockchip_dmc`, `rockchip_ipa`,
`rockchip_opp_select`, `rockchip_system_monitor`, `linux/rockchip/rockchip_sip.h`).
The donor's unchanged `#include <soc/rockchip/…>` finds our copy on the include
path.

> **Breaks when** a newer kernel *adds* that header upstream. `LINUXINCLUDE` is
> searched **before** `-I$(src)/compat`, so the real header would win and
> **silently shadow** our shim — possibly with a different prototype, giving a
> wrong-behaviour build rather than a clean error. If a re-synced kernel suddenly
> ships e.g. `include/soc/rockchip/rockchip_dmc.h`, switch that shim to the
> explicit-include mechanism (below) or drop it if the real one is complete.

**(2) explicit `-include` / `#include "compat/…"`** — for headers that **do**
exist upstream but are **incomplete**. Upstream `<soc/rockchip/pm_domains.h>`
exists but lacks the QoS helpers (`rockchip_save_qos()/_restore_qos()`) and
`rockchip_pmu_idle_request()`. Because the real header is found first, the `-I`
trick cannot shadow it — so the QoS shim is **force-included**
(`ccflags-y += -include $(src)/compat/rockchip_qos_compat.h`, `mpp/Makefile:15`)
and the pmu-idle shim is `#include "compat/rockchip_pmu_idle.h"` in
`mpp_common.h:29`.

> **Breaks when** upstream `pm_domains.h` later *gains* those symbols. You then
> get **conflicting definitions** (our `static inline` vs the real decl). Fix:
> delete the now-redundant shim and its force-include / explicit include.

---

## 2. Forward-compat hazard ranking

Ranked by how badly a newer **kernel** can break the port silently. The higher
the rank, the more carefully you must re-verify.

### #1 — the `mpp_iommu_dma_cookie` struct-layout shadow *(most fragile)*

`mpp_iommu.h:20-29` defines a **private shadow** of the kernel-internal
`struct iommu_dma_cookie` so the driver can reach the IOVA allocator `iovad` via
`iommu_domain->iova_cookie` (`mpp_iommu.c:703-726`, `mpp_iommu_reserve_iova()`).
This depends on the **exact memory layout** of a struct the kernel considers
private and is free to reorder at any release. 6.18 already moved `iovad` to
offset 0 by deleting the leading `enum iommu_dma_cookie_type type` member.

The compile-time guard `BUILD_BUG_ON(offsetof(struct mpp_iommu_dma_cookie,
iovad) != 0)` (`mpp_iommu.c:719`) is only a **partial** safety net: it catches
`iovad` *not being at offset 0*, but it does **not** catch a reorder that keeps
`iovad` first while changing what precedes/follows it in the real cookie, nor a
type change of `iovad` itself. **On any kernel bump, manually diff
`drivers/iommu/dma-iommu.c`'s `struct iommu_dma_cookie`** and re-confirm that
`iovad` is still the first member and still a `struct iova_domain`.

### #2 — IOMMU-core symbol churn

The fault-handler guard reads `domain->cookie_type == IOMMU_COOKIE_NONE`
(`mpp_iommu.c:669-672`). Both `cookie_type` and the `IOMMU_COOKIE_*` enum are
IOMMU-core internals introduced by the same 6.18 rework. A future release may
rename or restructure them. Re-check that `iommu_set_fault_handler()` still WARNs
on a cookie-owning domain and that the guard symbol still exists.

### #3 — dma-buf / devfreq signature drift

Lower-stakes because these usually fail *loudly* at compile time: the
`dma_buf_*_unlocked()` accessors, the `iommu_map()` `gfp` parameter,
`follow_pfnmap_start()/end()`, `hrtimer_setup()`, `class_create()` arity, and the
`void`-returning platform `.remove`. Each has a row (with a `Since` kernel
version) in [`docs/06`](06-vendor-delta.md) § 1 — that table is the re-sync
checklist for API drift.

---

## 3. Reproduce the delta

After bumping the donor, re-measure so the ~580-line / 1.7% headline stays
honest (full method + caveats in [`docs/06`](06-vendor-delta.md) § Method):

```sh
BSP=…/rockchip-kernel/drivers/video/rockchip
OURS=…/linux-6.18-rkvenc/drivers/video/rockchip
for f in mpp/mpp_common.c mpp/mpp_iommu.c mpp/mpp_iommu.h mpp/mpp_service.c \
         mpp/mpp_common.h mpp/mpp_rkvenc2.c mpp/mpp_rkvdec2.c \
         mpp/mpp_rkvdec2_link.c rga3/rga_drv.c rga3/rga_iommu.c rga3/rga_mm.c; do
  printf '%-26s %s\n' "$f" "$(diff -u "$BSP/$f" "$OURS/$f" | grep -c '^+[^+]')"
done
```

A `+` line counts a **modified** line, not only a net addition, so the totals
read higher than `git diff --stat`. Today this sums to **139** (MPP core) + **38**
(RGA3). A *rising* count after a BSP bump means the donor changed lines we'd
edited — re-inspect those hunks first; they are the most likely to need
re-application.

---

## 4. Residual TODOs (W-tags) — what's intentionally stubbed

These are **deliberate** stubs, tracked so a re-syncer doesn't mistake them for
regressions. Same list as [`docs/06`](06-vendor-delta.md) § 6, framed for the
production path:

- **W6 — dead / DVFS-off includes.** `rockchip_ipa.h` is a dead include
  (`mpp_rkvenc2.c:31` references no `rockchip_ipa_*` symbol) and is deletable;
  the devfreq islands are `default n`. Production: drop the dead include; only
  enable devfreq once DVFS is genuinely wired.
- **W15 — OPP voltage/leakage management absent.** `rockchip_init_opp_table()`
  returns `-EOPNOTSUPP`, so `rkvenc_devfreq_init()` bails and the cores run at
  fixed `assigned-clock-rates`. Production: port the OPP/PVTM voltage stack, or
  drive voltage from a mainline regulator + devfreq governor.
- **iommu fault-mask no-op.** `rockchip_iommu_mask_irq()` is a no-op stub, so the
  pagefault-handler fault-storm guard and the `mpp_iommu_refresh()` re-attach are
  inert. Production: a real mask path against the mainline `rockchip-iommu`
  driver.
- **system-monitor absent.** `rockchip_system_monitor_register()` returns
  `ERR_PTR(-ENODEV)`; the encoder logs "without system monitor" and runs without
  SoC-wide thermal/voltage coordination. Production: register the venc as a
  mainline thermal-cooling device.

None of these block the validated transcode path; they are the gap between this
conservative forward-port and a full BSP-equivalent power/thermal stack.
