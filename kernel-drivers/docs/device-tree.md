# Device tree

`patches/rk3588-rkvenc2-02-vcodec-rga-dt.patch` touches two files:
`rk3588-base.dtsi` (the nodes, all `status = "disabled"` by default) and
`rk3588-rock-5b.dtsi` (the board enables them). The encoder and RGA are defined
**inline**; the decoder is **convert-in-place** for Armbian (see
[Armbian packaging guide](../../packaging/docs/armbian-packaging.md)) or inline for vanilla (see
[vanilla-kernel guide](./vanilla-kernel.md)). A third variant exists for **post-6.18
mainline-master**, where mainline itself defines `&vdec0`/`&vdec1` and the
override targets *those* nodes (same `fdc38100`/`fdc38000` regs/link split) —
see [rewrite-driver track § 5](./rewrite-drivers.md) for that bring-up DT.

## Glossary (terms used below)

| Term | Meaning |
|------|---------|
| **CCU** | Core-cluster coordination unit — schedules/load-balances tasks across the two cores of a codec cluster. The **decoder** CCU is a real MMIO block (`@fdc30000`); the **encoder** CCU is purely virtual (software-only, no registers). |
| **mpp_srv** | The shared MPP *service* node (`compatible = "rockchip,mpp-service"`, owns `/dev/mpp_service`). Every core attaches to it via `rockchip,srv`. Virtual — no `reg`. |
| **RCB** | Row-Cache Buffer — scratch storage for per-row reconstruction/context data during decode/encode. |
| **SRAM** | On-chip static RAM (`system_sram2@ff001000`). The decoder maps a slice of it as fast RCB; the encoder does not (it row-caches from DRAM). |
| **IOMMU / MMU** | I/O memory-management unit — per-core translation between device DMA addresses (IOVA) and physical pages. |
| **taskqueue** | The MPP framework's per-cluster work queue. Both cores of a cluster share one `rockchip,taskqueue-node` index into a global array of `rockchip,taskqueue-count` (`12`). |
| **core-mask** | Logical bitmask (`rockchip,core-mask`) identifying a core to the CCU scheduler, independent of MMIO address. |
| **power-domain** | The PMU power island that must be on for the block (e.g. `RK3588_PD_VENC0`). |
| **GRF** | General Register Files — SoC-wide syscon misc registers; the MPP OPP path pokes voltage-margin bits there (`mpp_rkvenc2.c:2234`). Not referenced by the Rock 5B codec nodes directly. |

## Address map (from the RK3588 TRM)

`MMIO?` distinguishes register-backed nodes from *virtual* nodes — a virtual node
legitimately has **no `reg`** (and no MMIO window); it exists only so a driver can
attach software state. The encoder CCU and `mpp_srv` are pure software
coordinators, so the DT validator does not (and must not) expect `reg` on them.

| Block | Base | MMIO? | Notes |
|-------|------|-------|-------|
| `rkvenc0` (VEPU580 core 0) | `fdbd0000` | yes | single `0x6000` window, no `reg-names`; `rkvenc0_mmu@fdbdf000` |
| `rkvenc1` (VEPU580 core 1) | `fdbe0000` | yes | single `0x6000` window, no `reg-names`; `rkvenc1_mmu@fdbef000` |
| `rkvenc_ccu` | (virtual) | **no** | software-only coordinator (no `reg`/clock/reset) |
| `rkvdec_ccu` | `fdc30000` | yes | VDPU381 CCU MMIO (`0x100`, `reg-names = "ccu"`) |
| `rkvdec0` (VDPU381 core 0) | `fdc38000` | yes | regs `@fdc38100`, link `@fdc38000`; `…_mmu@fdc38700` |
| `rkvdec1` (VDPU381 core 1) | `fdc40000` | yes | regs `@fdc40100`, link `@fdc40000`; `…_mmu@fdc40700` |
| `rga3_core0` | `fdb60000` | yes | RGA3; `rga3_0_mmu@fdb60f00` |
| `rga3_core1` | `fdb70000` | yes | RGA3; `rga3_1_mmu@fdb70f00` |
| `rga2` | `fdb80000` | yes | RGA2 |
| `mpp_srv` | (virtual) | **no** | shared MPP service coordinator (`/dev/mpp_service`, no `reg`) |

Each **decoder** core's `reg` is two windows: function/regs at core `+0x100`
(size `0x400`, named `"regs"`, looked up as index 0 → the driver's `io_base`) and
the link-mode window at core `+0x000` (size `0x100`, named `"link"`,
`platform_get_resource_byname`, `mpp_rkvdec2_link.c:824`). That `+0x100` is
**load-bearing** — the decoder derives its IOMMU register window as
`ioremap(io_base + 0x600, 0x80)` (`mpp_rkvdec2.c:1944`), so
`io_base = 0xfdc38100 → MMU @ 0xfdc38700`. The **encoder** is *not* like this: a
**single** `0x6000` window with **no `reg-names`** (see *Encoder vs decoder
differences* below).

### `fdc40000` vs `fdc48000` — resolved
The vendor BSP places decoder **core 1** at `fdc48000`; mainline (and Armbian's
`media-0001`) use `fdc40000`. The TRM "Address Mapping" table is decisive:
`VDPU381_core1_base = 0xFDC4_0000` (RKVDEC1, a 64 KB window). The vendor's
`fdc48000` is the `+0x8000` **mirror** inside that 64 KB window — both work, but
`fdc40000` is canonical, and it's what `media-0001` uses, so convert-in-place
requires it. **Confirmed on hardware**: core 1 probes clean at `fdc40100`. The
vendor driver has zero hard-coded decoder addresses (all access is DT
`reg_base + fixed offset`; the CCU coordinates via a logical `core-mask` bitmask,
not address), so the move is purely a DT change.

### Interrupts (GIC SPI)

All SPI numbers below are **verified live on the working board** (2026-07-01,
kernel `6.18.37-current-rockchip64 #7`, combined kernel) via `/proc/interrupts`
and the running `/proc/device-tree` — see the verification procedure below. The
encoder rows are also pinned in-tree (`rk3588-base.dtsi`, encoder block of the DT
patch); the decoder rows are **inherited**, not in-tree (next paragraph).

| Node | Core IRQ | MMU IRQ(s) | Pinned by | Board hwirq (core / MMU) |
|------|----------|------------|-----------|--------------------------|
| `rkvenc0` / `rkvenc0_mmu` | SPI 101 | SPI 99, SPI 100 | in-tree (DT patch) | 133 / 131, 132 |
| `rkvenc1` / `rkvenc1_mmu` | SPI 104 | SPI 102, SPI 103 | in-tree (DT patch) | 136 / 134, 135 |
| `rkvdec0` / `vdec0_mmu` | SPI 95 | SPI 96 (**shared**) | inherited from `media-0001` | 127 / 128 |
| `rkvdec1` / `vdec1_mmu` | SPI 97 | SPI 96 (**shared**) | inherited from `media-0001` | 129 / 128 |

The encoder MMU carries **two** IRQs (a dual read/write channel — see below).
The **two decoder IOMMUs share one line**: both `vdec0_mmu` and `vdec1_mmu`
declare `GIC_SPI 96`, so `/proc/interrupts` shows a single row
`GICv3 128 Level  fdc38700.iommu, fdc40700.iommu` (the rockchip-iommu driver
requests it shared). Do **not** "fix" an inline DT to give `vdec1_mmu` its own
number — SPI 96 for both is what the silicon (and `media-0001`, and the running
board) has.

The decoder IRQs are still *not pinned in this repo's DT patch*: the
convert-in-place cores inherit `interrupts` from Armbian's `media-0001` node and
override only `interrupt-names` (`"irq_rkvdec0"` / `"irq_rkvdec1"`). The inline
(vanilla) form must supply them itself — the verified values live in
[vanilla-kernel guide](./vanilla-kernel.md)'s copy-pasteable block. Either way the IRQ is
mandatory: `platform_get_irq(pdev, 0)` (`mpp_common.c:2206`) fails the probe if
no `interrupts` resolves.

**Verification procedure (5 minutes, on any board where the port runs):**

```bash
grep -E 'video-codec|iommu' /proc/interrupts
#  GICv3 <hwirq>: for SPI interrupts, hwirq = GIC_SPI + 32
#  → 127 = SPI 95 (fdc38100.video-codec), 129 = SPI 97 (fdc40100.video-codec),
#    128 = SPI 96 (fdc38700.iommu, fdc40700.iommu — one shared row)

od -A x -t x1z /proc/device-tree/video-codec@fdc38000/interrupts
#  16 bytes = 4 be32 cells: 00000000 0000005f 00000004 00000000
#  = <GIC_SPI 95 IRQ_TYPE_LEVEL_HIGH 0>   (GIC_SPI = 0, IRQ_TYPE_LEVEL_HIGH = 4)
```

Cross-check: Armbian's `media-0001-Add-rkvdec-Support-v5.patch` declares exactly
these values (`vdec0` SPI 95, `vdec1` SPI 97, both MMUs SPI 96) — the same node
text the convert-in-place build inherits and the board runs.

## Encoder vs decoder differences

The two clusters look symmetric but their DT bindings are not. Copying decoder
assumptions onto the encoder (or vice-versa) silently breaks things.

| Aspect | Encoder (VEPU580) | Decoder (VDPU381) |
|--------|-------------------|-------------------|
| Core `reg` | **single** `<… 0x6000>` window, **no `reg-names`** | two windows `regs`(`+0x100`)/`link`(`+0x000`) |
| CCU | `rkvenc_ccu` is **purely virtual** — `rkvenc_ccu_probe` (`mpp_rkvenc2.c:2880`) allocates state only, **no reg/clock/reset** | `rkvdec_ccu` is **real MMIO** `@fdc30000` with `aclk_ccu` + `video_ccu` reset + `rockchip,ccu-mode` |
| Clocks | **3**: `aclk_vcodec`, `hclk_vcodec`, `clk_core` (`:2379`) | **5**: + `clk_cabac`, `clk_hevc_cabac` (`:1216`) |
| Resets | **3**: `video_a`, `video_h`, `video_core` (`:2397`) | up to **7**: + optional `niu_a`/`niu_h`, plus `video_cabac`, `video_hevc_cabac` (`:1242`) |
| RCB / SRAM | **none** on Rock 5B — no `rockchip,sram`, no `rockchip,rcb-iova`; `rkvenc2_alloc_rcbbuf` returns early and its return is **ignored** (`mpp_rkvenc2.c:3145`) → encoder row-caches from **DRAM** | maps on-chip **SRAM** as RCB (`rockchip,sram` + `rockchip,rcb-iova`) |
| MMU | two `0x40` reg windows (`@fdbdf000`/`+0x40`) + **two** IRQs (dual R/W channel) | one window the *codec* driver reaches via the hardcoded `io_base+0x600` poke; the `vdecN_mmu` iommu node is separate |

The asymmetry is real silicon, not a packaging artifact: the decoder needs CABAC
clocks and on-chip row-cache that the encoder pipeline does not.

## Two things that *will* break the codecs if you forget them

### 1. Aliases are mandatory
The MPP framework derives each core's `core_id` from
`of_alias_get_id(np, "rkvenc"/"rkvdec")`. **Without the aliases**, it returns
`-ENODEV`, no core becomes core 0, and the decoder defers forever / oopses.

```dts
aliases {
    rkvenc0 = &rkvenc0;  rkvenc1 = &rkvenc1;
    rkvdec0 = &rkvdec0;  rkvdec1 = &rkvdec1;   /* or &vdec0/&vdec1 in convert-in-place */
};
```

> This bit us via a **DT overlay** alias bug: overlay aliases resolve to the
> fragment-internal path (`/fragment@0/__overlay__/rkvdec-core@…`), so
> `of_alias_get_id` failed and every core got a wrong `core_id`. In an **in-tree**
> DT, aliases resolve correctly. This is one reason the project moved from a
> configfs overlay to a built-in combined kernel.

### 2. Enable the CCU with the cores
A node named `*-core@…` always dispatches to the CCU-attaching probe (see
[forward-port guide](./vendor-forward-port.md)). Enable the CCU **and** both cores **and** both IOMMUs together, or you
get `attach ccu failed` and nothing registers:

```dts
&mpp_srv     { status = "okay"; };
&rkvenc_ccu  { status = "okay"; };
&rkvenc0     { status = "okay"; };   &rkvenc0_mmu { status = "okay"; };
&rkvenc1     { status = "okay"; };   &rkvenc1_mmu { status = "okay"; };
&rkvdec_ccu  { status = "okay"; };
/* + the decoder cores/mmus (inline) or the &vdec0/&vdec1 overrides (Armbian) */
```

## What each driver reads from the DT

Every property below is read by name; get the name wrong and the property is
silently skipped (or the probe fails). Symbol:line cites the read site.

| Property | Read by (symbol : line) | Required? | Effect / failure if absent |
|----------|-------------------------|-----------|----------------------------|
| `reg` idx 0 | `platform_get_resource(MEM,0)` `mpp_common.c:2213` | yes | main `reg_base`/`io_base` (decoder: `fdc38100`); also the base for the hardcoded MMU poke |
| `reg-names = "link"` | `platform_get_resource_byname` `mpp_rkvdec2_link.c:824` | yes (decoder link mode) | absent ⇒ `"link mode resource not found"` |
| `interrupts` | `platform_get_irq(pdev,0)` `mpp_common.c:2206` | yes | absent ⇒ probe fails (no IRQ) |
| `aliases/{rkvdec,rkvenc}N` | `of_alias_get_id` `mpp_rkvdec2.c:1936`, `mpp_rkvenc2.c:3132` | yes | absent ⇒ `core_id = -ENODEV`, no core 0 (see *Aliases are mandatory*) |
| `rockchip,srv` | `of_parse_phandle` `mpp_common.c:1023` | yes | absent ⇒ `"failed to attach service"`, `-ENODEV` |
| `rockchip,taskqueue-node` | `mpp_common.c:1044` | yes | must be `< rockchip,taskqueue-count` (`12`); absent ⇒ `"failed to get taskqueue-node"` |
| `rockchip,ccu` | `rkvdec2_attach_ccu` / `rkvenc_attach_ccu` | yes (a `*-core` node) | absent/disabled ⇒ `"attach ccu failed"` |
| `rockchip,core-mask` | `of_property_read_u32` `mpp_rkvdec2_link.c:1556` | yes (decoder core) | CCU schedule bitmask; absent ⇒ error return |
| `rockchip,ccu-mode` | `rkvdec2_ccu_probe` `mpp_rkvdec2.c:1759` | no (default soft CCU) | `1` = soft, `2` = hw CCU; CCU node only |
| `reg-names = "ccu"` | `rkvdec2_ccu_probe` `mpp_rkvdec2.c:1765` | yes (CCU node) | absent ⇒ `-ENODEV` |
| `rockchip,rcb-iova` | `device_property_read_u32_array` `mpp_rkvdec2.c:1810` | decoder: yes for RCB | absent ⇒ `"could not find property rcb-iova"` |
| `rockchip,sram` | `of_parse_phandle` + `of_address_to_resource` + `iommu_map` `mpp_rkvdec2.c:1828` | no | maps raw physical SRAM into the codec IOMMU at the RCB IOVA (no gen_pool, no `request_mem_region`) |
| `rockchip,rcb-min-width` / `rockchip,rcb-info` | `mpp_rkvdec2.c:1886` / `:1891` | no | RCB sizing / per-buffer layout |
| `rockchip,task-capacity` | `of_property_read_u32` `mpp_common.c:2177` | no (default `1`) | link-mode batch depth; `1` ⇒ **no** batching |
| `rockchip,skip-pmu-idle-request` | `device_property_read_bool` `mpp_common.c:2174` | no (bool) | skip the PMU idle handshake on power transitions |
| `iommus` | rockchip-iommu binding | yes | binds the core to its MMU translation domain |

## Annotated decoder core node (inline form)

This is the *inline* (vanilla) shape of one decoder core. Every non-obvious line
is annotated; the `reg`/MMU block is the part people get wrong.

```dts
rkvdec0: rkvdec-core@fdc38000 {              /* unit-addr = link window; name has "core" -> CCU-attaching probe path */
    compatible = "rockchip,rkv-decoder-v2"; /* dispatches to the vendor core probe, not the V4L2 rk3588-vdec driver */
    reg = <0x0 0xfdc38100 0x0 0x400>,        /* idx0 "regs": function block at core+0x100 -> becomes io_base (LOAD-BEARING) */
          <0x0 0xfdc38000 0x0 0x100>;        /* idx1 "link": link-mode command window at core+0x000 */
    reg-names = "regs", "link";
    /* NB: no MMU reg here. The driver hardcodes ioremap(io_base + 0x600, 0x80)   */
    /* = 0xfdc38100 + 0x600 = 0xfdc38700 (mpp_rkvdec2.c:1944). Set idx0 to        */
    /* 0xfdc38000 by mistake and the MMU maps 0xfdc38600 -- the WRONG page.       */
    interrupts = <GIC_SPI 95 IRQ_TYPE_LEVEL_HIGH 0>;  /* verified on board 2026-07-01 -- see Interrupts table + vanilla-kernel.md */
    interrupt-names = "irq_rkvdec0";
    clocks = <&cru ACLK_RKVDEC0>, <&cru HCLK_RKVDEC0>, <&cru CLK_RKVDEC0_CORE>,
             <&cru CLK_RKVDEC0_CA>, <&cru CLK_RKVDEC0_HEVC_CA>;        /* 5 clocks */
    clock-names = "aclk_vcodec", "hclk_vcodec", "clk_core",
                  "clk_cabac", "clk_hevc_cabac";       /* matched by string, mpp_rkvdec2.c:1216 */
    resets = <&cru SRST_A_RKVDEC0>, <&cru SRST_H_RKVDEC0>, <&cru SRST_RKVDEC0_CORE>,
             <&cru SRST_RKVDEC0_CA>, <&cru SRST_RKVDEC0_HEVC_CA>;
    reset-names = "video_a", "video_h", "video_core",
                  "video_cabac", "video_hevc_cabac";   /* optional niu_a/niu_h omitted here */
    iommus = <&rkvdec0_mmu>;                  /* DMA-domain binding (distinct from the hardcoded io_base+0x600 poke) */
    rockchip,srv = <&mpp_srv>;                /* attach /dev/mpp_service, else -ENODEV */
    rockchip,ccu = <&rkvdec_ccu>;             /* a "core" node always attaches a CCU */
    rockchip,core-mask = <0x00010001>;        /* logical id the CCU schedules on (core0); core1 = 0x00020002 */
    rockchip,taskqueue-node = <9>;            /* shared by both decoder cores; must be < taskqueue-count (12) */
    rockchip,task-capacity = <16>;            /* link-mode batch depth; default 1 = no batching */
    rockchip,sram = <&vdec0_sram>;            /* on-chip SRAM mapped as RCB via of_address_to_resource + iommu_map */
    rockchip,rcb-iova = <0xFFF00000 0x100000>;/* reserved IOVA the RCB lives at (core1 uses 0xFFE00000) */
    rockchip,rcb-info = <136 24576>, <137 49152>, ... ;  /* per-buffer (regid, size) RCB layout */
    rockchip,rcb-min-width = <512>;
    rockchip,skip-pmu-idle-request;
    power-domains = <&power RK3588_PD_RKVDEC0>;
    status = "okay";
};
```

## CCU / taskqueue / core-mask

- Encoder and decoder each share a `rockchip,taskqueue-node` (`7` for enc, `9`
  for dec) across their two cores.
- Decoder cores carry `rockchip,core-mask` (`0x00010001` core 0, `0x00020002`
  core 1) — the logical bitmask the CCU uses to schedule, independent of address.
- `rkvdec_ccu` uses `rockchip,ccu-mode = <1>` (soft CCU).

## SRAM / row-cache-buffer (RCB)

Each decoder core points at an on-chip SRAM pool via `rockchip,sram = <&vdecN_sram>`
(`@0` size `0x78000`, `@78000` size `0x77000`, children of `system_sram2@ff001000`)
and an `rcb-iova`/`rcb-info` map. The driver translates the SRAM phandle with
`of_address_to_resource()` and `iommu_map()`s the physical region as the RCB — it
does **not** use a gen_pool, which is why the convert-in-place reuses Armbian's
`pool;`-flavored SRAM nodes untouched ([Armbian packaging guide](../../packaging/docs/armbian-packaging.md)).
