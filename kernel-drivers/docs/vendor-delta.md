# Exactly what we changed in the Rockchip 6.1 BSP

A line-level accounting of the forward-port: how much of the validated driver
code is Rockchip's, and precisely what our changes were and why.

## The answer: 90% Rockchip, 10% ours

Of the 39,535 lines of MPP + RGA driver code in the shipping tree
(`0001`–`0074`), **≈ 90% is Rockchip-authored and ≈ 10% is ours**:

| Provenance | Lines | Share |
|---|---:|---:|
| Rockchip 6.1 BSP, carried over verbatim | 34,382 | 87.0% |
| Rockchip `develop-5.10`, cherry-picked | 1,175 | 3.0% |
| **Rockchip, total** | **35,557** | **89.9%** |
| **Ours** | **3,978** | **10.1%** |

Measured 2026-07-24 against donor `rockchip-kernel@b4ef083dc0c3` (`develop-6.1`),
tree `linux-6.18-rkvenc-av1-fwport@710e6ad12af6`.

The 10% is not spread evenly: it concentrates in IOMMU/DMA integration and RGA
memory management, and the big register and hardware-table files are barely
touched. The rest of this page is where each class comes from, then the complete
per-change table.

> One number sits outside both columns: the **Verisilicon IOMMU driver**
> (1,039 lines) is third-party Collabora code living in `drivers/iommu/`, not
> in the driver directories measured above. It is
> [broken out below](#the-collabora-iommu-work-broken-out).

This page is the **quantitative** side. The narrative rationale for each hunk —
and the `compat/` and `hack/` story — is in the
[forward-port guide](../../kernel-versions/docs/vendor-forward-port.md); which blocks
are in or out of the port at all is [forward-port scope](./forward-port-scope.md);
how the Rockchip branches differ from each other is
[forward port vs BSP 6.1/6.6](./bsp-6.1-6.6-comparison.md).

> We ported the **minimal subset** of the MPP framework needed for the codecs:
> **7 of the BSP's 17 `mpp_*.c` files** (`mpp_common`, `mpp_iommu`,
> `mpp_service`, `mpp_rkvenc2`, `mpp_rkvdec2`, `mpp_rkvdec2_link`, `mpp_av1dec`)
> — **not** the legacy VPU1/2, VEPU1/2, RKVDEC-v1, RKVENC-v1, JPEG, IEP2, or
> VDPP blocks. The per-block rationale is in
> [forward-port scope](./forward-port-scope.md). (`mpp_av1dec` joined the set
> when AV1 was folded into the single line; older revisions of this doc list six
> files and count AV1 as unported.)

## Where each class comes from

### Rockchip 6.1 BSP, verbatim — 87.0%

The bulk. Patches `0001`–`0002` import the vendor MPP and RGA drivers and the
RK3588 device tree; the vendor `.c` files were never rewritten, so most of every
file is still byte-identical to `develop-6.1`. `mpp/hack/` (1,445 lines of
other-SoC workarounds RK3588 never executes) is carried unmodified on purpose, so
re-syncing against a newer BSP stays a clean diff.

### Rockchip `develop-5.10`, cherry-picked — 3.0%

Patches `0017`–`0036` bring 20 Rockchip-authored RGA commits forward from
`develop-5.10`, a branch the vendor kept developing after 6.1 (batching,
`shadow_page` for cache-line-unaligned VAs, CSC/scale and rotate fixes). This
code is Rockchip's; it simply is not in the 6.1 donor, so a naive donor
comparison books it as local work. It is **entirely RGA**, which is what you
would expect from where that branch's activity was:

| File | 5.10 lines |
|---|---:|
| `rga3/rga_mm.c` | 419 |
| `rga3/rga2_reg_info.c` | 320 |
| `rga3/rga3_reg_info.c` | 127 |
| `rga3/rga_job.c` | 97 |
| `rga3/rga_drv.c` | 47 |
| `rga3/rga_policy.c` | 43 |
| `rga3/include/rga2_reg_info.h` | 37 |
| `rga3/rga_debugger.c` | 21 |

### Ours — 10.1%

Everything else: the 6.18 API adaptations and IOMMU/DMA integration, the
`compat/` shim layer, RK3588 bring-up fixes, and the locally-found and
audit-ported defect fixes. Enumerated in full in
[Every change, and what it was for](#every-change-and-what-it-was-for).

Where it lands, for the largest files:

| File | Total | Rockchip 6.1 | Rockchip 5.10 | Ours | % ours |
|---|---:|---:|---:|---:|---:|
| `mpp/mpp_rkvenc2.c` | 3,596 | 3,156 | 0 | 440 | 12% |
| `rga3/rga2_reg_info.c` | 3,548 | 3,219 | 320 | 9 | 0% |
| `rga3/rga_mm.c` | 3,310 | 2,353 | 419 | 538 | 16% |
| `mpp/mpp_rkvdec2_link.c` | 3,045 | 2,652 | 0 | 393 | 13% |
| `mpp/mpp_common.c` | 2,938 | 2,635 | 0 | 303 | 10% |
| `rga3/rga3_reg_info.c` | 2,395 | 2,232 | 127 | 36 | 2% |
| `mpp/mpp_rkvdec2.c` | 2,324 | 2,149 | 0 | 175 | 8% |
| `rga3/rga_drv.c` | 1,785 | 1,709 | 47 | 29 | 2% |
| `rga3/rga_job.c` | 1,731 | 1,478 | 97 | 156 | 9% |
| `mpp/mpp_av1dec.c` | 1,171 | 1,005 | 0 | 166 | 14% |
| `mpp/mpp_iommu.c` | 1,135 | 697 | 0 | 438 | 39% |
| `rga3/rga_debugger.c` | 1,020 | 990 | 21 | 9 | 1% |

Two things stand out. **`mpp_iommu.c` is the one heavily-local file** (39%) —
mainline's IOMMU core is where the port could not simply carry vendor code.
And the **register and hardware-table files are essentially untouched by us**:
`rga2_reg_info.c` is 0% ours despite 320 lines of change, because all of it is
Rockchip's `develop-5.10` work.

### How the classes were separated

Two signals, because either alone lands in the wrong place:

- **`git blame` at HEAD** identifies lines introduced by the vendor cherry-pick
  range `0017`–`0036`. Alone it over-credits us, because it attributes a
  whole-file *vendor* import to whoever imported it — `mpp_av1dec.c` (1,171
  lines of Rockchip's AV1 decoder, patch `0007`) would count entirely as ours.
- **A donor comparison** identifies lines byte-identical to 6.1. Alone it also
  over-credits us, because it cannot see that 1,175 lines came from Rockchip's
  later branch.

Each line is classified: *5.10* if its commit falls in the cherry-pick range,
else *6.1 verbatim* if it matches the donor, else *ours*.

> **Deleted lines are invisible.** A line we removed from a vendor file leaves
> nothing behind to classify, so these figures describe *what the tree
> contains*, not the total size of the edit.

## The footprint outside `drivers/video/rockchip`

The table above is deliberately scoped to the driver directories so it stays
comparable across revisions of this doc. The port also touches **20 files
elsewhere, +2,566 lines** against mainline v6.18 — and this is where a third
provenance class appears that a vendor/ours split cannot express:

| Area | Lines | Provenance |
|---|---|---|
| `drivers/iommu/vsi-iommu.c` + `include/soc/rockchip/vsi_iommu.h` | 1,071 | **Third-party upstream** — the Verisilicon IOMMU driver, © 2025 Collabora (Yandong Lin, Simon Xue, Benjamin Gaignard). **Not in the 6.1 BSP at all**; neither vendor-carried nor ours. |
| `Documentation/devicetree/bindings/…` (6 files) | 518 | Ours — written for upstream submission. |
| `arch/arm64/boot/dts/rockchip/` (2 files) | 451 | Ours as written; node *content* is BSP-derived. |
| `drivers/iommu/rockchip-iommu.c` | +333 | Ours — additions to a **mainline** file (the [IOMMU decision](./forward-port-scope.md#the-iommu-decision)). |
| `include/soc/rockchip/rockchip_iommu.h` | 68 | 20 differ vs the BSP's 89-line original; mostly BSP-derived, trimmed. |
| `include/uapi/linux/rk-mpp.h` | 85 | **4** differ vs the BSP's 82-line original — essentially the vendor uAPI carried over. |
| iommu/video Kconfig+Makefile, `dma-iommu.c`, `iommu.h`, verisilicon Kconfig | 40 | Ours — wiring. |

Two of these rows are the reason a naive `git diff v6.18..HEAD` overstates local
authorship: `rk-mpp.h` and `rockchip_iommu.h` look 100% new against mainline but
are ~95% and ~70% vendor code respectively when compared against the donor that
actually supplied them.

### The Collabora IOMMU work, broken out

The two IOMMU files deserve the same treatment as the driver code, because their
provenance is different again — and in opposite directions. Both are measured by
`git blame` at HEAD against our own commit ranges:

| File | Total | Imported / upstream | Ours | % ours |
|---|---:|---:|---:|---:|
| `drivers/iommu/vsi-iommu.c` | 1,039 | 1,016 (patch `0005` import) | 23 (patch `0014`) | **2.2%** |
| `drivers/iommu/rockchip-iommu.c` | 1,683 | 1,349 (mainline v6.18) | 334 (`0005` +221, `0014` +103, rest +10) | **19.8%** |

**`vsi-iommu.c` — we are essentially a consumer, not an author.** The Verisilicon
IOMMU driver carries `Copyright (C) 2025 Collabora` and names Yandong Lin and
Simon Xue (Rock-Chips) with Benjamin Gaignard (Collabora). Patch `0005` imports it
wholesale; our only subsequent edit is 23 lines of fault-handling hardening in
`0014`. So **97.8% of that file is third-party code we carry**, which is why the
headline driver-code table deliberately excludes it — folding 1,016 lines of
someone else's driver into either the "Rockchip" or the "ours" column would
misrepresent both.

**`rockchip-iommu.c` — the inverse.** Here the baseline is *mainline*, not the
BSP: 80.2% is upstream v6.18 code, and our 334 lines are the provider hooks that
implement the [IOMMU decision](./forward-port-scope.md#the-iommu-decision) —
enable/disable/reset, IRQ mask/unmask, and the Rockchip fault callback that MPP
needs. This is the one place in the port where we materially extend a mainline
driver rather than carry a vendor one.

> **Boundary.** `vsi-iommu.c` is **not** in mainline v6.18, so there is no local
> upstream baseline to diff against: the 1,016-line figure is "as imported by
> patch `0005`", and the delta between that import and the original Collabora
> posting is **unmeasured**. Authorship is taken from the file's copyright
> banner, not from a tree comparison.

## Method

Every line of `drivers/video/rockchip/` at the shipping tip is assigned exactly
one of the three classes. Two signals are combined, because either alone lands in
the wrong place (see
[How the classes were separated](#how-the-classes-were-separated)):

- **the donor comparison** — is this line byte-identical to `develop-6.1`?
- **`git blame` at HEAD** — was it introduced by the vendor cherry-pick range,
  patches `0017`–`0036`?

Generated build artifacts (`*.mod.c`) are excluded. Both source trees are pinned,
with reconstruction recipes, in [source-tree pins](../../docs/source-trees.md).

### Reproduce it

Walk the **whole** tree rather than a hand-listed file subset — the fixed list
this doc used to carry silently omitted `mpp_av1dec.c`, `rga_job.c`, and
`rga2_reg_info.c` once the port grew past its original two-patch base.

```sh
BSP=…/rockchip-kernel/drivers/video/rockchip           # develop-6.1 donor
OURS=…/linux-6.18-rkvenc-av1-fwport                    # the forward-port tree

# 1. patch number for every commit, so the 0017-0036 range can be recognised
git -C "$OURS" rev-list --reverse v6.18..HEAD | nl

# 2. per line: owning commit ...
git -C "$OURS" blame -l --line-porcelain HEAD -- <file>

# 3. ... and whether that line is unchanged from the donor
diff -u "$BSP/<file>" "$OURS/drivers/video/rockchip/<file>"
```

Classify each line: **5.10** if its commit is patch `0017`–`0036`; else
**6.1 verbatim** if it is unchanged from the donor; else **ours**.

Re-measure after bumping the donor. A *rising* "ours" count means the donor
changed lines we had edited — inspect those hunks first, they are the ones most
likely to need re-application.

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
| MPP IOMMU fault handler moved to Rockchip provider hook | `mpp_iommu.c`, `rockchip-iommu.c` | 6.18 | the IOMMU core now WARNs if the domain already owns a cookie; MPP uses DMA domains, so Rockchip faults are reported through a provider-local callback instead of `iommu_set_fault_handler()` |
| `-DMPP_VERSION="6.18-rkvenc-fwport"` (`ccflags-y`) | `mpp/Makefile` | — | replaces the donor's `$(shell git …)` version string, which fails in this tree (no vendor git metadata) |

### 2. Bring-up / correctness fixes — *make the cores actually bind on RK3588*

Four hunks (part of the ~140 in-place edits), surfaced by probing real hardware
and relevant on any kernel. Narrated in full in
[forward-port guide](../../kernel-versions/docs/vendor-forward-port.md) (§ C — Bring-up fixes); the `file:symbol`
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
`NULL`-guarded. Narrated in [forward-port guide](../../kernel-versions/docs/vendor-forward-port.md) (§ B — OPP /
devfreq de-noised).

### 4. The `compat/` shim layer — *stand in for BSP-only SoC headers* (338 lines, all new)

Thin headers under `mpp/compat/` so the vendor `.c` files keep their original
`#include`s and call sites. Mostly no-op stubs:

`rockchip_pmu_idle.h`, `rockchip_opp_select.h`, `rockchip_system_monitor.h`,
`rockchip_dmc.h`, `rockchip_ipa.h`, `rockchip_sip.h`, `rockchip_qos_compat.h`.
`rockchip_iommu.h` graduated out of `compat/` into a real `include/soc/rockchip`
header backed by `drivers/iommu/rockchip-iommu.c`. See
[forward-port guide](../../kernel-versions/docs/vendor-forward-port.md).

### 5. Wiring — Kconfig / Makefile (63 lines)

In-tree `obj-$(CONFIG_…)` rules and the menu structure, plus `default y` on
`ROCKCHIP_MPP_SERVICE` / `ROCKCHIP_MULTI_RGA` and `select SYNC_FILE` (so the
config travels in the patch — `armbian-packaging.md`). The `hack/` files are restored
verbatim from the BSP and **must not be deleted** ([gotchas](../../docs/gotchas.md)).

### 6. Residual W-tag stubs

Several shim banners point at `W6` / `W15` / the old residual-stubs label (e.g.
`rockchip_opp_select.h:8,11`, `rockchip_ipa.h:8`, `rockchip_system_monitor.h:12`)
but no master list lives in the tree. Consolidated here —
these are **intentionally stubbed**, not bugs; a production path would restore
them. See [resyncing guide](./resyncing.md) for the maintenance view.

| Tag | What's stubbed | Production path |
|-----|----------------|-----------------|
| **W6** | dead/dvfs-off includes: `rockchip_ipa.h` is a dead include; the devfreq islands are `default n` | delete the dead `#include` (`mpp_rkvenc2.c:31`); leave devfreq off unless DVFS is wired |
| **W15** | real OPP voltage/leakage management absent — `rkvenc_devfreq_init()` bails on the `-EOPNOTSUPP` stub | port the OPP/PVTM voltage stack, or drive voltage from a mainline regulator/devfreq governor |
| iommu fault-mask | formerly `rockchip_iommu_mask_irq()` was a no-op, disabling the pagefault-handler fault-storm guard | fixed in the AV1 forward-port worktree by provider-local Rockchip IOMMU helpers |
| system-monitor | `rockchip_system_monitor_register()` → `ERR_PTR(-ENODEV)`; encoder runs without SoC thermal/voltage monitoring | register the venc as a mainline thermal-cooling device |

---

## What this says

The forward-port did **not** rewrite or "clean up" the vendor code — it keeps
**87% byte-identical to the 6.1 donor** — 90% Rockchip-authored once the
`develop-5.10` cherry-picks are counted on the vendor side (98% at the original
two-patch import) — and changed only
what the 6.1→6.18 API churn demanded, plus the minimum to bind on RK3588, the
vendor fixes 6.1 never received, and the defects found on hardware.

The structural claim that matters for the audit tracks is unchanged by the
re-audit: **we did not refactor the vendor logic**, so latent bugs and
non-idiomatic patterns in the untouched 87% are *still there* — and the
per-file table above shows the density is lowest exactly in the big register and
hardware-table files. That is why BSP-latent defects keep surfacing under
sanitizers. The companion audit-and-clean effort lives **in this repo**:
[BSP audit](./bsp-audit.md) is the audit (89 reviewer findings, 16 HIGH), the
fixes are the reviewable 65-patch series in
[`kernel-drivers/patches/cleanup-split`](../patches/cleanup-split) (with the per-file
history and verification record in
[`kernel-drivers/patches/cleanup-draft`](../patches/cleanup-draft)) — all kept **separate**
from this conservative forward-port, and with the **runtime regression gate
still PENDING** ([`verification.md`](../patches/cleanup-draft/verification.md)).
