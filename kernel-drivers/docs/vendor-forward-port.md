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
> per-change table), see [vendor delta](./vendor-delta.md).

---

## A. The `compat/` shim layer

The BSP drivers `#include` a pile of Rockchip-private SoC headers that **do not
exist in mainline**. Rather than rip out every call site, we provide thin
compatibility shims under `drivers/video/rockchip/mpp/compat/`. Each shim's
header banner is the authoritative per-shim spec; the table below transcribes
the essentials. (**SiP SMC** = Silicon-Provider Secure Monitor Call, a firmware
trap into ATF; **IPA** = Intelligent Power Allocator, the thermal static-power
model; **DMC** = Dynamic Memory Controller / DDR devfreq; **QoS** = the bus
Quality-of-Service priority registers; **modpost** = the kernel's module
post-processing / symbol-resolution step at link time.)

| Shim header | Stands in for (BSP) | Inclusion mechanism | What it stubs to | Consequence / W-tag |
|---|---|---|---|---|
| `soc/rockchip/rockchip_iommu.h` | BSP IOMMU mask/enable helpers | `-I$(src)/compat` | **unconditional** inline stubs: `rockchip_iommu_mask_irq()` no-op, `enable()/disable()` → `-ENODEV` | fault-storm mask **disabled**; `mpp_iommu_refresh()` re-attach is a no-op (retval ignored) — iommu fault-mask TODO |
| `soc/rockchip/rockchip_opp_select.h` | PVTM/OPP voltage selection | `-I$(src)/compat` | `rockchip_init_opp_table()` → `-EOPNOTSUPP`; **full (trimmed)** `struct rockchip_opp_info` (embedded by value) | `rkvenc_devfreq_init()` bails → no voltage/leakage management (**W15**) |
| `soc/rockchip/rockchip_system_monitor.h` | system-monitor (SoC thermal/voltage) | `-I$(src)/compat` | `rockchip_system_monitor_register()` → `ERR_PTR(-ENODEV)` | driver logs "without system monitor", continues; prod path = a mainline thermal-cooling device |
| `soc/rockchip/rockchip_dmc.h` | DDR devfreq (DMC) coupling | `-I$(src)/compat` | no-op `rockchip_dmcfreq_lock()/_unlock()` | **matches** the BSP's own `!CONFIG_ROCKCHIP_DMC` `#else` inlines — the stub *is* vendor behaviour |
| `soc/rockchip/rockchip_ipa.h` | IPA static-power thermal model | `-I$(src)/compat` | empty stub; **no `rockchip_ipa_*` symbol referenced** | dead include, deletable (**W6**) |
| `linux/rockchip/rockchip_sip.h` | SiP SMC VPU reset | `-I$(src)/compat` | `sip_smc_vpu_reset()` → zeroed `arm_smccc_res` | ATF SMC reset unavailable; live reset path is the CRU-based `rkvdec2_reset()` fallback (callers ignore retval) |
| `rockchip_qos_compat.h` | QoS save/restore (was in `pm_domains.h`) | **`-include`** (force) | `rockchip_save_qos()/_restore_qos()` → `0` | **matches** the BSP's `!CONFIG_ROCKCHIP_PM_DOMAINS` inline — correct for the SIP-off reset path |
| `rockchip_pmu_idle.h` | `rockchip_pmu_idle_request()` (absent from upstream `pm_domains.h`) | explicit `#include "compat/…"` | returns `0` | short-circuited by `mpp->skip_idle` (RK3588 DT carries `rockchip,skip-pmu-idle-request`) — never reached |

This keeps the vendor `.c` files close to upstream-BSP so future re-syncs are
easy, and confines the "this is a BSP-ism" knowledge to one directory. For
re-syncing against a newer BSP or kernel, see [resyncing guide](./resyncing.md).

### How the shims get included

Two distinct techniques are in play, and **knowing which is which is essential
to reproduce the build**:

1. **`-I$(src)/compat` header-search shadowing** — used for BSP headers that
   have **no upstream counterpart** (`rockchip_iommu`, `rockchip_dmc`,
   `rockchip_ipa`, `rockchip_opp_select`, `rockchip_system_monitor`, and
   `linux/rockchip/rockchip_sip.h`). The donor's unchanged
   `#include <soc/rockchip/…>` line finds our copy on the search path; nothing in
   the `.c` changes.
2. **explicit `-include` / `#include "compat/…"`** — used for headers that **do**
   exist upstream but are **incomplete**. Upstream `<soc/rockchip/pm_domains.h>`
   exists but lacks both the QoS helpers and `rockchip_pmu_idle_request()`.
   Because `LINUXINCLUDE` is searched **before** `-I$(src)/compat`, a compat copy
   of `pm_domains.h` would be **silently shadowed** by the real one — so the `-I`
   trick cannot help here. Instead the Makefile force-includes the QoS shim
   (`ccflags-y += -include $(src)/compat/rockchip_qos_compat.h`, mpp/Makefile:15)
   and `mpp_common.h:29` does an explicit `#include "compat/rockchip_pmu_idle.h"`
   right after the `pm_domains.h` include.

(Banners: `rockchip_qos_compat.h:8-14`, `rockchip_pmu_idle.h:10-13`.)

### Per-shim detail — *does stubbing X lose anything?*

- **`rockchip_iommu.h`** — the BSP declared these as real externs behind
  `IS_REACHABLE(CONFIG_ROCKCHIP_IOMMU)` with inline stubs only in the `#else`.
  Mainline **does** define `CONFIG_ROCKCHIP_IOMMU` (`drivers/iommu/rockchip-iommu.c`),
  so reusing the BSP header verbatim would leave the symbols as **unresolved
  externs at modpost/link**. We therefore provide **unconditional** inline stubs
  (`rockchip_iommu.h:33-39`). Cost: the fault-storm mask in the pagefault handler
  is disabled, and the error-recovery re-attach in `mpp_iommu_refresh()` is a
  no-op (its return is ignored).
- **`rockchip_opp_select.h`** (`:53-58`) returns `-EOPNOTSUPP`, so
  `rkvenc_devfreq_init()` bails before registering anything. Note `struct
  rockchip_opp_info` is **embedded by value** in `struct rkvenc_dev`
  (`mpp_rkvenc2.c:342`), so a **complete** (trimmed) type is mandatory — a no-op
  forward declaration won't compile. Stubbing OPP loses voltage/leakage
  management → **W15**.
- **`rockchip_system_monitor.h`** (`:47`) returns `ERR_PTR(-ENODEV)`; the driver
  checks `IS_ERR()`, logs "without system monitor", and continues.
- **`rockchip_ipa.h`** (`:5-8`) is a **dead include** — `mpp_rkvenc2.c:31`
  `#include`s it but references no `rockchip_ipa_*` symbol. The include line is
  deletable → **W6**.
- **`rockchip_pmu_idle.h`** (`:15-18`) — the only caller, `mpp_pmu_idle_request()`
  in `mpp_common.h:826`, short-circuits when `mpp->skip_idle` is set, and the
  RK3588 DT carries `rockchip,skip-pmu-idle-request`, so the stub is **never
  reached** on this SoC.
- **`rockchip_sip.h`** (`:10-16`) — `sip_smc_vpu_reset()` returns a zeroed
  `arm_smccc_res`. The real ATF SMC reset is unavailable on this firmware, so the
  live reset path is the CRU-based `rkvdec2_reset()` fallback; all three call
  sites (`mpp_rkvdec2.c:1441`, `mpp_rkvdec2_link.c:1815,:2434`) ignore the return.
- **`rockchip_dmc.h`** / **`rockchip_qos_compat.h`** — both banners note their
  stubs **match** the BSP's own `!CONFIG_…` `#else` no-op inlines. In other words
  the stub *is* the vendor's own behaviour when the service is absent — a
  reassuring correctness argument, not a behavioural change.

## The `hack/` files — do **not** delete them

`mpp_rkvdec2.c` does `#include "hack/mpp_rkvdec2_hack_rk3568.c"` (`mpp_rkvdec2.c:18-19`)
and the link variant includes `hack/mpp_rkvdec2_link_hack_rk3568.c`
(`mpp_rkvdec2_link.c:19`); there are also `mpp_hack_px30.*` and `mpp_hack_rk3576.*`.
These hold **other-SoC** workaround bodies that are `#ifdef`'d out on RK3588 but
still must be present for the `#include` to resolve. We restored all six from the
BSP and keep them in the patch. Deleting them breaks the build with
`fatal error: hack/mpp_rkvdec2_hack_rk3568.c: No such file or directory`.

Note the unusual pattern: a `.c` file `#include`d **into another `.c`**. The hack
body is not a separately-compiled object — it is pasted in as a **fragment of the
same translation unit**, so it shares the host file's `static` symbols, macros,
and `#ifdef` context. That is why it is `#include`d rather than added to the
Makefile's object list, and why it must live on disk even when its body compiles
to nothing on RK3588.

---

## B. 6.18 API adaptations

### The 6.18 iommu-dma cookie rework — `mpp_iommu.c`, `mpp_iommu.h`
6.18 reworked `struct iommu_dma_cookie` (`drivers/iommu/dma-iommu.c`). **Two**
consequences fall out of the same change, and both are handled in the iommu glue:

1. **Fault-handler cookie guard** (`mpp_iommu.c:669-672`). The core now `WARN`s and
   bails inside `iommu_set_fault_handler()` if the domain already owns a cookie
   (e.g. the default DMA domain from `iommu_get_domain_for_dev()`). The BSP
   installed its handler unconditionally → a `WARN` splat. Fix: in
   `mpp_iommu_dev_activate()`, only call `iommu_set_fault_handler()` when
   `domain->cookie_type == IOMMU_COOKIE_NONE`; on a DMA-managed domain the core
   reports faults itself. (Marker: `IOMMU_COOKIE_NONE`.)
2. **`iovad` moved to offset 0** (`mpp_iommu.h:20-29`). The cookie dropped its
   leading `enum iommu_dma_cookie_type type` member (the enum itself was deleted),
   so the IOVA allocator `iovad` now sits at offset 0. The driver reaches `iovad`
   through `iommu_domain->iova_cookie` via a private shadow struct
   `mpp_iommu_dma_cookie`, so that shadow must keep `iovad` **first**. This is
   pinned at compile time by `BUILD_BUG_ON(offsetof(struct mpp_iommu_dma_cookie,
   iovad) != 0)` (`mpp_iommu.c:719`). See [resyncing guide](./resyncing.md) for why this
   is the single most fragile forward-port hazard.

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
Kconfig options (see `armbian-packaging.md` for how the config is enabled with **zero**
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
(`device-tree.md`): always enable the CCU alongside the cores.

### Compatible-based dispatch (decoder) — enables convert-in-place
We extended `rkvdec2_probe()` to dispatch by **compatible** first
(`of_device_is_compatible("rockchip,rkv-decoder-v2[-ccu]")`) and fall back to the
node-name `strstr`. This lets a decoder node keep a *generic* name (e.g.
Armbian's mainline `video-codec@…` node, retyped in place to the vendor binding)
and still reach `rkvdec2_core_probe()`. This is what makes the **zero-edit
convert-in-place** packaging possible — see `armbian-packaging.md`. It's also just more
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
