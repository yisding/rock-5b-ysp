# Re-syncing against a newer BSP / a newer kernel

The maintenance view. When you bump the donor (a newer Rockchip BSP), the host
kernel (a newer mainline/Armbian), or Armbian's own patch stack, this is what to
re-check and in what order. The forward-port deliberately keeps ~98% of the
vendor code byte-identical ([`docs/06`](06-vendor-delta.md)) and confines the
deltas to a shim layer ([`docs/05`](05-vendor-forward-port.md)), so re-syncing is
mostly *re-applying a small, well-located set of changes* — but a few of them are
fragile against kernel-internal churn. Read this before you start.

> **Every fix here has two consumers.** The same driver source ships as (a) the
> combined `=y` Armbian kernel (`scripts/`) and (b) the DKMS module
> ([`packaging/dkms/`](../packaging/dkms/)), whose KSRC input is the identical
> `v6.18` + patch-01 tree ([`docs/00`](00-source-trees.md)). Any shim/compat fix
> you make while re-syncing must land in both; DKMS is actually the early-warning
> channel — it re-builds on every `apt upgrade` kernel bump and surfaces API
> breaks loudly, before you've re-built the combined kernel.

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

## 4. The Armbian-side resync — bump checklist

The driver-code hazards above are only half the maintenance surface. The
Armbian packaging ([`docs/08`](08-armbian-packaging.md)) leans on Armbian
internals that drift on *their* schedule. **When Armbian bumps
`rockchip64-current` (or you re-target a new Armbian release), check:**

1. **Is `media-0001` still present, with the same nodes?**
   (`patch/kernel/archive/rockchip64-<ver>/media-0001-Add-rkvdec-Support-v5.patch`.)
   Convert-in-place *depends* on its `&vdec0`/`&vdec1` labels existing: if the
   patch is dropped or the labels renamed, our `&vdec0 { … }` overrides reference
   an undefined label and the DT build fails (loud). Subtler: if its
   `interrupts`/`iommus`/`power-domains`/`sram` properties change, the converted
   cores silently inherit the *new* values — re-verify against the board
   ([`docs/07` § Interrupts](07-device-tree.md#interrupts-gic-spi): SPI 95/97
   cores, shared 96 MMU line, verified 2026-07-01).
2. **Does the `av1d` `@@` anchor still hold?** Our `base.dtsi` block is placed
   *after* `av1d` precisely so our hunk anchors at `@@ -1366` while media's
   anchors at `@@ -1353` ([`docs/08`](08-armbian-packaging.md) § the `av1d`
   relocation). If Armbian's `rk3588-base.dtsi` gains/loses lines near there,
   the two patches can collide again — re-check that both apply in either order.
3. **Re-derive the `P####-C####` hash and update `PHASH`.** Any patch or config
   change alters the Armbian deb-name hash;
   `scripts/build-combined-kernel.sh` prints the new value (`:59`) — set it in
   `scripts/install-combined-kernel.sh` (`PHASH=`, currently `Pb6ab-Cb831`) or
   the installer refuses the new debs.
4. **Kconfig `default y` still honored?** The zero-edit config trick relies on
   Armbian running `make olddefconfig` over our patched Kconfig defaults
   ([`docs/08`](08-armbian-packaging.md)); confirm the tristate parents still
   land `=y` in the built config.
5. **Python-patcher semantics unchanged?** The whole convert-in-place strategy
   assumes `lib/tools/patching.py` stays last-write-wins with core patches
   appended after userpatches ([`docs/10`](10-gotchas.md)).
6. **udev PR [armbian/build#10085](https://github.com/armbian/build/pull/10085)
   status.** Once merged, new Armbian images grant `video`-group access to
   `mpp_service`/`rga`/dma-heaps out of the box and the local
   `scripts/99-rockchip-codec.rules` install step becomes redundant there (it
   stays necessary for the DKMS-on-stock-Ubuntu path).

---

## 5. Residual TODOs (W-tags) — what's intentionally stubbed

These are **deliberate** stubs, tracked so a re-syncer doesn't mistake them for
regressions. **The canonical W-tag table (W6, W15, iommu fault-mask,
system-monitor) is [`docs/06` § 6](06-vendor-delta.md)** — one list, maintained
there. Re-syncer-relevant addenda not in that table:

- the iommu fault-mask no-op means **both** the pagefault-handler fault-storm
  guard *and* the `mpp_iommu_refresh()` re-attach are inert;
- with W15 stubbed (`rockchip_init_opp_table()` → `-EOPNOTSUPP`) the cores run at
  fixed `assigned-clock-rates`, and the encoder's "without system monitor" boot
  log line is expected, not a regression ([`docs/10`](10-gotchas.md) § benign
  boot noise).

None of these block the validated transcode path; they are the gap between this
conservative forward-port and a full BSP-equivalent power/thermal stack.

---

## 6. Update propagation — when you touch X, update Y

The repo's cross-cited facts drift unless edits propagate. The standing rules:

| When you touch… | …also update |
|-----------------|--------------|
| `patches/rk3588-rkvenc2-01-…drivers.patch` (driver source) | re-derive `P####-C####` → `PHASH` in `scripts/install-combined-kernel.sh`; rebuild/retest [`packaging/dkms/`](../packaging/dkms/) (same source, second consumer); re-run `tests/`; re-measure the § 3 delta and [`docs/06`](06-vendor-delta.md)'s headline; note that [`docs/11`](11-bsp-audit.md)'s line pins are against the *pre-cleanup* tree ([`docs/00`](00-source-trees.md)) |
| `patches/rk3588-rkvenc2-02-…dt.patch` (DT) | [`docs/07`](07-device-tree.md) tables + annotated node; [`docs/09`](09-vanilla-kernel.md)'s inline block; the DKMS overlay in [`packaging/dkms/`](../packaging/dkms/) (encodes the same nodes as string-path aliases) |
| the host kernel version (mainline or Armbian bump) | § 1 shim mechanisms + § 2 hazards here; [`docs/06` § 1](06-vendor-delta.md) API table; DKMS rebuild (the loud early warning); if it's an Armbian bump, the full § 4 checklist above |
| the donor BSP | § 3 delta re-measurement; [`docs/06`](06-vendor-delta.md); re-check the [`docs/11`](11-bsp-audit.md) findings still map (they're latent BSP bugs — a donor bump may fix or move them) |
| `patches/cleanup-split/` (applying or editing the audit series) | the ⏳ runtime-gate row in [`cleanup-draft/VERIFICATION.md`](../patches/cleanup-draft/VERIFICATION.md) and `STATUS.md`; [`docs/11`](11-bsp-audit.md)'s line-pin caveat |
| any file you **add** to the repo | the owning directory's hub README (every README indexes every file/subdir); if you added a *top-level package directory*, also update the root `README.md` repository map and [`15-work-packages.md`](15-work-packages.md) |
