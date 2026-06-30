# Forward-porting the vendor code to 6.18

This is `patches/rk3588-rkvenc2-01-vcodec-rga-drivers.patch` — what we changed in
Rockchip's BSP driver code to make it **compile and run on Linux 6.18**. 58 files;
the donor is the Rockchip 6.1 BSP (`drivers/video/rockchip/mpp/` → `rk_vcodec.ko`)
plus `airockchip/librga`'s kernel driver (`drivers/video/rockchip/rga3/` →
`multi_rga`).

The changes fall into three buckets: **(A)** a compatibility shim layer for
vendor-only headers, **(B)** specific 6.18 API adaptations, and **(C)** bring-up
fixes found while validating on hardware.

> This doc is the **narrative** — what each change is and *why*. For the
> line-by-line accounting (how much is ours vs Rockchip's, plus the complete
> per-change table), see [`docs/06`](06-vendor-delta.md).

---

## A. The `compat/` shim layer

The BSP drivers `#include` a pile of Rockchip-private SoC headers that **do not
exist in mainline**. Rather than rip out every call site, we provide thin
compatibility shims under `drivers/video/rockchip/mpp/compat/`:

| Shim header | Stands in for (BSP) | What it does on 6.18 |
|-------------|---------------------|----------------------|
| `soc/rockchip/rockchip_opp_select.h` | PVTM/OPP voltage selection | no-op stubs (DVFS is tier-2, off) |
| `soc/rockchip/rockchip_system_monitor.h` | system-monitor devfreq | no-op stubs |
| `soc/rockchip/rockchip_dmc.h` | DDR freq coupling | no-op stubs |
| `soc/rockchip/rockchip_ipa.h` | IPA thermal model | no-op stubs |
| `soc/rockchip/rockchip_iommu.h` | BSP IOMMU helpers | maps onto mainline `iommu/` API |
| `linux/rockchip/rockchip_sip.h` | SiP SMC calls | minimal decls |
| `rockchip_pmu_idle.h`, `rockchip_qos_compat.h` | PM-domain idle request, QoS | shims / guarded out |

This keeps the vendor `.c` files close to upstream-BSP so future re-syncs are
easy, and confines the "this is a BSP-ism" knowledge to one directory.

## The `hack/` files — do **not** delete them

`mpp_rkvdec2.c` does `#include "hack/mpp_rkvdec2_hack_rk3568.c"` and the link
variant includes `hack/mpp_rkvdec2_link_hack_rk3568.c`; there are also
`mpp_hack_px30.*` and `mpp_hack_rk3576.*`. These hold **other-SoC** workaround
bodies that are `#ifdef`'d out on RK3588 but still must be present for the
`#include` to resolve. We restored all six from the BSP and keep them in the
patch. Deleting them breaks the build with
`fatal error: hack/mpp_rkvdec2_hack_rk3568.c: No such file or directory`.

---

## B. 6.18 API adaptations

### IOMMU `iommu_set_fault_handler()` cookie guard — `mpp_iommu.c`
6.18 added a `cookie_type != IOMMU_COOKIE_NONE` assertion inside
`iommu_set_fault_handler()`. The BSP installs a fault handler on the **DMA
default domain**, which now has a cookie → a `WARN` splat. Fix: in
`mpp_iommu_dev_activate()`, only call `iommu_set_fault_handler()` when
`domain->cookie_type == IOMMU_COOKIE_NONE`. (Marker: `IOMMU_COOKIE_NONE`.)

### `CONFIG_CPU_RK3588` guard removed — `mpp_rkvenc2.c` (and decoder of_match)
The BSP gates the RK3588 `of_device_id` entries behind `CONFIG_CPU_RK3588`, which
**mainline/Armbian configs don't define** — so the encoder/decoder cores would
never bind. We made the `rockchip,rkv-encoder-v2-core` /
`rockchip,rkv-decoder-v2` match entries **unconditional**. Harmless on non-RK3588
SoCs (no matching DT nodes).

### OPP / devfreq de-noised — `mpp_common.c`, `mpp_rkvenc2.c`, `mpp_rkvdec2.c`
With the OPP/system-monitor services stubbed, the BSP logs scary
`failed to init_opp_table` / `failed to add venc devfreq` `dev_err`s. We
downgraded these to `dev_dbg` and documented why (the cores run at fixed
`assigned-clock-rates`; full PVTM DVFS is BSP-only). The devfreq islands are
behind `ROCKCHIP_MPP_RKVENC2_DEVFREQ` / `..._RKVDEC2_DEVFREQ`, both `default n`,
which also elides the BSP-private `../drivers/devfreq/governor.h` include absent
from mainline trees.

### Build system — `Makefile`, `Kconfig`
Converted to clean in-tree style (objects build into `rk_vcodec.ko`), and added
Kconfig options (see `docs/08` for how the config is enabled with **zero**
built-in Armbian config edits).

---

## C. Bring-up fixes (found on hardware)

These aren't strictly "compile on 6.18" — they're correctness fixes surfaced by
actually probing the hardware. They matter for any kernel.

### Probe ordering → `-EPROBE_DEFER` (not `-ENOMEM`/oops)
The encoder and decoder cores attach to a **CCU** (clock/coordination unit) that
must bind first. If a core probes before its CCU has set `drvdata`, the BSP
returned `-ENOMEM` (hard fail) or oops'd dereferencing a not-yet-ready main core.
Fixes (6 sites):
- `rkvdec2_attach_ccu()` / `rkvenc_attach_ccu()`: return **`-EPROBE_DEFER`** when
  the CCU exists but its `drvdata` isn't set yet (plus `put_device()` to release
  the `of_find_device_by_node()` ref).
- decoder: `-EPROBE_DEFER` if the **main core (core0)** isn't ready when a
  secondary core attaches (avoids a `queue->cores[0]` NULL deref).
- `rkvenc_ccu_probe()` / `rkvdec2_ccu_probe()`: **publish `drvdata` last**, after
  `mutex_init`/`INIT_LIST_HEAD`, so `drvdata != NULL` genuinely means "ready".

### The CCU is mandatory for a `*core*` node
Both `rkvenc_probe()` and `rkvdec2_probe()` **dispatch by node name**:
`strstr(np->name,"ccu")` → ccu probe, `strstr(np->name,"core")` → core probe
(which *requires* the CCU). There is **no standalone path** for a node named
`*-core@…`. So enabling a core without enabling its CCU yields
`attach ccu failed` and the core never registers. Lesson baked into the DT
(`docs/07`): always enable the CCU alongside the cores.

### Compatible-based dispatch (decoder) — enables convert-in-place
We extended `rkvdec2_probe()` to dispatch by **compatible** first
(`of_device_is_compatible("rockchip,rkv-decoder-v2[-ccu]")`) and fall back to the
node-name `strstr`. This lets a decoder node keep a *generic* name (e.g.
Armbian's mainline `video-codec@…` node, retyped in place to the vendor binding)
and still reach `rkvdec2_core_probe()`. This is what makes the **zero-edit
convert-in-place** packaging possible — see `docs/08`. It's also just more
correct than dispatching on a substring of the node name. (Marker:
`of_device_is_compatible`.)

---

## Map of the key hunks

```
mpp_iommu.c        cookie_type guard on iommu_set_fault_handler
mpp_rkvenc2.c      CONFIG_CPU_RK3588 removed; attach_ccu -EPROBE_DEFER + put_device;
                   ccu_probe drvdata-last; OPP dev_err→dev_dbg
mpp_rkvdec2.c      compatible-based probe dispatch; attach_ccu/core0 -EPROBE_DEFER;
                   ccu_probe drvdata-last; OPP dev_err→dev_dbg
mpp_rkvdec2_link.c -EPROBE_DEFER on the link path
mpp_common.c       OPP/devfreq de-noise; compat glue
compat/**          shim headers for BSP-only SoC headers
hack/**            other-SoC bodies kept to satisfy #includes (NOT deletable)
mpp/Kconfig        default y on ROCKCHIP_MPP_SERVICE (gates the cores)
rga3/Kconfig       default y on ROCKCHIP_MULTI_RGA + select SYNC_FILE
Makefile, rockchip/{Kconfig,Makefile}   in-tree wiring
```

The full diff is the patch file; this is the reading guide.
