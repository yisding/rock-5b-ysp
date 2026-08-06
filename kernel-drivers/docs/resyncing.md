# Re-syncing against a newer BSP / a newer kernel

The maintenance view. When you bump the donor (a newer Rockchip BSP), the host
kernel (a newer mainline/Armbian), or Armbian's own patch stack, this is what to
re-check and in what order. The forward-port deliberately keeps ~87% of the
vendor code byte-identical ([vendor delta](./vendor-delta.md)) and confines the
deltas to a shim layer ([forward-port guide](../../kernel-versions/docs/vendor-forward-port.md)), so re-syncing is
mostly *re-applying a small, well-located set of changes* — but a few of them are
fragile against kernel-internal churn. Read this before you start.

> **Every fix here has two consumers.** The same driver source ships as (a) the
> combined `=y` Armbian kernel (`scripts/`) and (b) the DKMS module
> ([`packaging/dkms`](../../packaging/dkms)), whose KSRC input is the identical
> `v6.18` + patch-01 tree ([source-tree pins](../../docs/source-trees.md)). Any shim/compat fix
> you make while re-syncing must land in both; DKMS is actually the early-warning
> channel — it re-builds on every `apt upgrade` kernel bump and surfaces API
> breaks loudly, before you've re-built the combined kernel.

---

## 1. The two shim-inclusion mechanisms — and when each breaks

Everything in `mpp/compat/` reaches the vendor `.c` files by **one of two
techniques** ([forward-port guide](../../kernel-versions/docs/vendor-forward-port.md) § How the shims get
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

### #2b — the VSI IOMMU is now upstream; stop carrying it at v7.2

This one is not drift, it is convergence, and it fails *loudly* rather than
silently — but the right response is to delete our copy, not to fix the
conflict, which is why it needs to be written down before someone resolves it
the wrong way.

Mainline merged `drivers/iommu/vsi-iommu.c` (`917ace84b770`) and the RK3588
`av1d_mmu` DT node (`6ddfbec80077e`) for **v7.2-rc1**. Both are absent from
6.18, which is why the port supplies them. From v7.2 onward
`rk3588-fwport-0005` collides with mainline on the driver file, the
`verisilicon,iommu.yaml` binding, the `VSI_IOMMU` Kconfig symbol (ours `bool`,
mainline `tristate`), the Makefile line and the `verisilicon,iommu-1.2`
compatible; `rk3588-fwport-0009` collides on the DT node. `git am` fails on the
two file creations before anything else is even evaluated.

They are the same code — both trees took it from Collabora's `rockchip-3588`
tree, and the Rockchip BSP never had it at all. On a bump to v7.2 or later:

- **drop** the `vsi-iommu.c`, binding, Kconfig and Makefile hunks of `0005`, and
  the `av1d_mmu` hunk of `0009`, and consume mainline's;
- **keep** the rest of `0005` — the `rockchip-iommu.c` provider hooks and the
  `include/soc/rockchip/{rockchip_iommu,vsi_iommu}.h` headers, which mainline
  does not have; and
- **re-apply or re-send the probe error-path corrections**, because our copy has
  them and mainline's does not. They are prepared as a standalone series in
  [`patches/iommu-vsi-probe-fixes/`](../patches/iommu-vsi-probe-fixes/README.md);
  if that series has landed upstream by then, this step is already done.

Full comparison in
[the convergence finding](../../findings/2026-08-02-vsi-iommu-mainline-convergence-and-resync-collision.md).

### #3 — dma-buf / devfreq signature drift

Lower-stakes because these usually fail *loudly* at compile time: the
`dma_buf_*_unlocked()` accessors, the `iommu_map()` `gfp` parameter,
`follow_pfnmap_start()/end()`, `hrtimer_setup()`, `class_create()` arity, and the
`void`-returning platform `.remove`. Each has a row (with a `Since` kernel
version) in [vendor delta](./vendor-delta.md) § 1 — that table is the re-sync
checklist for API drift.

---

## 3. Reproduce the delta

After bumping the donor, re-measure so the ~4,600-line / 12% headline stays
honest (full method + caveats in [vendor delta](./vendor-delta.md) § Method;
prefer the whole-tree loop there over a hand-listed file subset, so a newly
added file cannot escape the count):

```sh
BSP=…/rockchip-kernel/drivers/video/rockchip
OURS=…/linux-6.18-rkvenc-av1-fwport/drivers/video/rockchip
find "$OURS" -type f \( -name '*.c' -o -name '*.h' -o -name Kconfig \
     -o -name Makefile \) ! -name '*.mod.c' | sort | while IFS= read -r f; do
  rel=${f#"$OURS"/}
  [ -f "$BSP/$rel" ] || { printf '%-40s %6s (new)\n' "$rel" "$(wc -l < "$f")"; continue; }
  printf '%-40s %6s\n' "$rel" "$(diff -u "$BSP/$rel" "$f" | grep -c '^+[^+]')"
done
```

A `+` line counts a **modified** line, not only a net addition, so the totals
read higher than `git diff --stat`. Measured at the `0001`–`0074` tip
(`710e6ad12af6` vs `rockchip-kernel@b4ef083dc0c3`): **1,886** MPP core +
**297** `mpp/compat/` + **2,441** RGA + **2** Kconfig/Makefile = **4,626**
overall. Quote all four parts or none — an MPP-plus-RGA pair alone omits the
compat shims and the build wiring, and will not add up. A *rising* count after
a BSP bump means the donor changed lines we'd edited — re-inspect those hunks
first; they are the most likely to need re-application.

> Walk the whole tree, not a fixed file list. The list this section used to carry
> silently omitted `mpp_av1dec.c`, `rga_job.c`, and `rga2_reg_info.c` once the
> port grew past its two-patch base.

---

## 4. The Armbian-side resync — bump checklist

The driver-code hazards above are only half the maintenance surface. The
Armbian packaging ([Armbian packaging guide](../../packaging/docs/armbian-packaging.md)) leans on Armbian
internals that drift on *their* schedule. **When Armbian bumps
`rockchip64-current` (or you re-target a new Armbian release), check:**

1. **Is `media-0001` still present, with the same nodes?**
   (`patch/kernel/archive/rockchip64-<ver>/media-0001-Add-rkvdec-Support-v5.patch`.)
   Convert-in-place *depends* on its `&vdec0`/`&vdec1` labels existing: if the
   patch is dropped or the labels renamed, our `&vdec0 { … }` overrides reference
   an undefined label and the DT build fails (loud). Subtler: if its
   `interrupts`/`iommus`/`power-domains`/`sram` properties change, the converted
   cores silently inherit the *new* values — re-verify against the board
   ([device-tree guide § Interrupts](./device-tree.md#interrupts-gic-spi): SPI 95/97
   cores, shared 96 MMU line, verified 2026-07-01).
2. **Does the `av1d` `@@` anchor still hold?** Our `base.dtsi` block is placed
   *after* `av1d` precisely so our hunk anchors at `@@ -1366` while media's
   anchors at `@@ -1353` ([Armbian packaging guide](../../packaging/docs/armbian-packaging.md) § the `av1d`
   relocation). If Armbian's `rk3588-base.dtsi` gains/loses lines near there,
   the two patches can collide again — re-check that both apply in either order.
3. **Re-derive the `P####-C####` hash and pass `PHASH`.** Any patch or config
   change alters the Armbian deb-name hash. The Armbian build emits the new
   value in each deb filename — pass it to
   `scripts/install-combined-kernel.sh` (`sudo RECOVERY_READY=1
   PHASH='P####-C####' ...`, after the recovery preflight in `install.md`) or
   the installer refuses the new debs.
4. **Kconfig `default y` still honored?** The zero-edit config trick relies on
   Armbian running `make olddefconfig` over our patched Kconfig defaults
   ([Armbian packaging guide](../../packaging/docs/armbian-packaging.md)); confirm the tristate parents still
   land `=y` in the built config.
5. **Python-patcher semantics unchanged?** The whole convert-in-place strategy
   assumes `lib/tools/patching.py` stays last-write-wins with core patches
   appended after userpatches ([gotchas](../../docs/gotchas.md)).
6. **udev PR [armbian/build#10085](https://github.com/armbian/build/pull/10085)
   status.** Once merged, new Armbian images grant `video`-group access to
   `mpp_service`/`rga`/dma-heaps out of the box and the local
   `scripts/99-rockchip-codec.rules` install step becomes redundant there (it
   stays necessary for the DKMS-on-stock-Ubuntu path).

---

## 5. Residual W-tag stubs — what's intentionally stubbed

These are **deliberate** stubs, tracked so a re-syncer doesn't mistake them for
regressions. **The canonical W-tag table (W6, W15, iommu fault-mask,
system-monitor) is [vendor delta § 6](./vendor-delta.md)** — one list, maintained
there. Re-syncer-relevant addenda not in that table:

- the iommu fault-mask no-op means **both** the pagefault-handler fault-storm
  guard *and* the `mpp_iommu_refresh()` re-attach are inert;
- with W15 stubbed (`rockchip_init_opp_table()` → `-EOPNOTSUPP`) the cores run at
  fixed `assigned-clock-rates`, and the encoder's "without system monitor" boot
  log line is expected, not a regression ([gotchas](../../docs/gotchas.md) § benign
  boot noise).

None of these block the validated transcode path; they are the gap between this
conservative forward-port and a full BSP-equivalent power/thermal stack.

---

## 6. Update propagation — when you touch X, update Y

The repo's cross-cited facts drift unless edits propagate. The standing rules:

| When you touch… | …also update |
|-----------------|--------------|
| `patches/rk3588-rkvenc2-01-…drivers.patch` (driver source) | re-derive `P####-C####` → `PHASH` in `scripts/install-combined-kernel.sh`; rebuild/retest [`packaging/dkms`](../../packaging/dkms) (same source, second consumer); re-run `tests/`; re-measure the § 3 delta and [vendor delta](./vendor-delta.md)'s headline; note that [BSP audit](./bsp-audit.md)'s line pins are against the *pre-cleanup* tree ([source-tree pins](../../docs/source-trees.md)) |
| `patches/rk3588-rkvenc2-02-…dt.patch` (DT) | [device-tree guide](./device-tree.md) tables + annotated node; [vanilla-kernel guide](../../kernel-versions/docs/vanilla-kernel.md)'s inline block; the DKMS overlay in [`packaging/dkms`](../../packaging/dkms) (encodes the same nodes as string-path aliases) |
| the host kernel version (mainline or Armbian bump) | § 1 shim mechanisms + § 2 hazards here; [vendor delta § 1](./vendor-delta.md) API table; DKMS rebuild (the loud early warning); if it's an Armbian bump, the full § 4 checklist above |
| the donor BSP | § 3 delta re-measurement; [vendor delta](./vendor-delta.md); re-check the [BSP audit](./bsp-audit.md) findings still map (they're latent BSP bugs — a donor bump may fix or move them) |
| `patches/cleanup-split/` (applying or editing the audit series) | the ⏳ runtime-gate row in [`kernel-drivers/patches/cleanup-draft/verification.md`](../patches/cleanup-draft/verification.md) and `status.md`; [BSP audit](./bsp-audit.md)'s line-pin caveat |
| any file you **add** to the repo | the owning directory's hub README (every README indexes every file/subdir); if you added a *top-level project or category*, also update the [work-package map](../../docs/work-packages.md) and add a root task route only when it serves a common entry path |
