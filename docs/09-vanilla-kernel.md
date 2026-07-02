# Applying this to a vanilla (non-Armbian) kernel

The patches are generated against **pristine mainline `v6.18`** (the dev tree is
`v6.18` + two commits), so the **driver patch applies to vanilla 6.18 directly**.
The only thing that differs is the **device tree**, because the convert-in-place
form depends on Armbian's `media-0001` nodes existing.

## What carries over unchanged

- **`patches/rk3588-rkvenc2-01-vcodec-rga-drivers.patch`** — the whole driver
  forward-port (compat shims, hack files, API fixes, bring-up fixes, Kconfig).
  Applies cleanly to vanilla `v6.18`:
  ```bash
  cd linux-6.18
  git apply /path/to/rk3588-rkvenc2-01-vcodec-rga-drivers.patch
  ```
- **Kconfig enablement** — the patch sets `ROCKCHIP_MPP_SERVICE` and
  `ROCKCHIP_MULTI_RGA` to `default y` (which cascades to the encoder/decoder/RGA
  sub-options). With `ARCH_ROCKCHIP=y`, a `make olddefconfig` turns them on. Or
  set them explicitly in your defconfig.

## What you must change: the decoder DT

The shipped DT patch (`…-02-…dt.patch`) **overrides Armbian's `vdec0/vdec1`
`video-codec@…` nodes** (convert-in-place). **Vanilla mainline has no such
nodes**, so those `&vdec0 { … }` overrides reference an undefined label and won't
compile. For vanilla you need the **inline** form: define the decoder cores
directly, like the encoder and RGA already are.

Scope check: **only the decoder needs hand-authoring.** The encoder
(`rkvenc0`/`rkvenc1` + `rkvenc_ccu` + `mpp_srv`) and the RGA cores are already
written **inline** in `base.dtsi` by the same DT patch (they had no `media-0001`
counterpart to convert), so they apply to vanilla 6.18 unchanged. Everything
below is decoder-only.

### What the inline form must add that convert-in-place inherited

The convert-in-place form ([`docs/08`](08-armbian-packaging.md)) inherits four things from `media-0001`'s
nodes. The inline form has no node to inherit from, so it must **declare them
itself**:

- **`interrupts`** on every core *and* MMU — convert-in-place sets only
  `interrupt-names`. The DT patch itself never pins the decoder SPI numbers, but
  they are now **verified on the working board** (see the note below).
- **`iommus`** and the **`rkvdecN_mmu`** iommu nodes — convert-in-place reuses
  media's `vdecN_mmu`.
- **`power-domains`** on each core/MMU.
- the **`vdecN_sram`** RCB pools (children of `system_sram2@ff001000`) —
  convert-in-place reuses media's pool nodes untouched.

> **The decoder SPI numbers are board-verified.** Every decoder `GIC_SPI` value
> and the MMU `reg`-window layout below were verified on the working ROCK 5B
> (2026-07-01, kernel `6.18.37-current-rockchip64 #7`) against three agreeing
> sources: `/proc/interrupts` (`GICv3 127/129` for the cores = SPI 95/97,
> hwirq = SPI + 32; `GICv3 128` = SPI 96 for the IOMMUs), the live
> `/proc/device-tree` node properties, and the text of Armbian's
> `media-0001-Add-rkvdec-Support-v5.patch` (whose `interrupts` the running
> convert-in-place build inherits). Full 5-minute re-verification procedure:
> [`docs/07` § Interrupts](07-device-tree.md#interrupts-gic-spi).
>
> **One non-obvious fact:** the two decoder IOMMUs **share** `GIC_SPI 96` — one
> interrupt line for both `iommu@fdc38700` and `iommu@fdc40700`
> (`/proc/interrupts`: `GICv3 128 Level  fdc38700.iommu, fdc40700.iommu`). Don't
> give `rkvdec1_mmu` its own number. (The encoder IRQs are additionally pinned
> in-tree — see [`docs/07`](07-device-tree.md).)

### Complete inline decoder DT (copy-pasteable)

Drop this into `rk3588-base.dtsi` (cores/CCU/MMUs as siblings of `av1d@fdc70000`)
plus the `&system_sram2` / `&{/aliases}` fragments. Lines marked `DIFF` differ
from the convert-in-place form. Clock/reset macro names, `core-mask`, `rcb-*`,
`taskqueue-node`, and base addresses are all verified against the driver + DT
patch; the `GIC_SPI` numbers and the MMU `reg`-window layout are verified against
the running board + `media-0001` (blockquote above).

```dts
rkvdec_ccu: rkvdec-ccu@fdc30000 {
    compatible = "rockchip,rkv-decoder-v2-ccu";
    reg = <0x0 0xfdc30000 0x0 0x100>;
    reg-names = "ccu";
    clocks = <&cru ACLK_RKVDEC_CCU>;
    clock-names = "aclk_ccu";
    assigned-clocks = <&cru ACLK_RKVDEC_CCU>;
    assigned-clock-rates = <600000000>;
    resets = <&cru SRST_A_RKVDEC_CCU>;
    reset-names = "video_ccu";
    rockchip,skip-pmu-idle-request;
    rockchip,ccu-mode = <1>;                 /* 1 = soft CCU, 2 = hw CCU */
    power-domains = <&power RK3588_PD_RKVDEC0>;
    status = "okay";
};

rkvdec0: rkvdec-core@fdc38000 {              /* DIFF: full node (convert form is `&vdec0 { … }`) */
    compatible = "rockchip,rkv-decoder-v2";
    reg = <0x0 0xfdc38100 0x0 0x400>,        /* "regs" at core+0x100 -> io_base; MMU = io_base+0x600 = fdc38700 */
          <0x0 0xfdc38000 0x0 0x100>;        /* "link" at core+0x000 */
    reg-names = "regs", "link";
    interrupts = <GIC_SPI 95 IRQ_TYPE_LEVEL_HIGH 0>;  /* DIFF: present (inherited in convert). Verified on board 2026-07-01 */
    interrupt-names = "irq_rkvdec0";
    clocks = <&cru ACLK_RKVDEC0>, <&cru HCLK_RKVDEC0>, <&cru CLK_RKVDEC0_CORE>,
             <&cru CLK_RKVDEC0_CA>, <&cru CLK_RKVDEC0_HEVC_CA>;
    clock-names = "aclk_vcodec", "hclk_vcodec", "clk_core",
                  "clk_cabac", "clk_hevc_cabac";
    rockchip,normal-rates = <800000000>, <0>, <600000000>, <600000000>, <1000000000>;
    resets = <&cru SRST_A_RKVDEC0>, <&cru SRST_H_RKVDEC0>, <&cru SRST_RKVDEC0_CORE>,
             <&cru SRST_RKVDEC0_CA>, <&cru SRST_RKVDEC0_HEVC_CA>;
    reset-names = "video_a", "video_h", "video_core",
                  "video_cabac", "video_hevc_cabac";
    iommus = <&rkvdec0_mmu>;                  /* DIFF: present (inherited in convert) */
    rockchip,skip-pmu-idle-request;
    rockchip,srv = <&mpp_srv>;
    rockchip,ccu = <&rkvdec_ccu>;
    rockchip,core-mask = <0x00010001>;
    rockchip,taskqueue-node = <9>;
    rockchip,task-capacity = <16>;            /* recommended: default 1 = no link-mode batching */
    rockchip,sram = <&vdec0_sram>;
    rockchip,rcb-iova = <0xFFF00000 0x100000>;
    rockchip,rcb-info = <136 24576>, <137 49152>, <141 90112>, <140 49152>,
                        <139 180224>, <133 49152>, <134 8192>, <135 4352>,
                        <138 13056>, <142 291584>;
    rockchip,rcb-min-width = <512>;
    power-domains = <&power RK3588_PD_RKVDEC0>; /* DIFF: present (inherited in convert) */
    status = "okay";
};

rkvdec0_mmu: iommu@fdc38700 {                 /* DIFF: full node (convert reuses media's vdec0_mmu) */
    compatible = "rockchip,rk3588-iommu", "rockchip,rk3568-iommu";
    reg = <0x0 0xfdc38700 0x0 0x40>, <0x0 0xfdc38740 0x0 0x40>;  /* two 0x40 windows -- verified vs live DT + media-0001 */
    interrupts = <GIC_SPI 96 IRQ_TYPE_LEVEL_HIGH 0>;             /* verified on board; SHARED with vdec1's MMU (one line for both) */
    clocks = <&cru ACLK_RKVDEC0>, <&cru HCLK_RKVDEC0>;
    clock-names = "aclk", "iface";
    power-domains = <&power RK3588_PD_RKVDEC0>;
    rockchip,disable-mmu-reset;
    #iommu-cells = <0>;
    status = "okay";
};

rkvdec1: rkvdec-core@fdc40000 {
    compatible = "rockchip,rkv-decoder-v2";
    reg = <0x0 0xfdc40100 0x0 0x400>, <0x0 0xfdc40000 0x0 0x100>;
    reg-names = "regs", "link";
    interrupts = <GIC_SPI 97 IRQ_TYPE_LEVEL_HIGH 0>;  /* verified on board 2026-07-01 */
    interrupt-names = "irq_rkvdec1";
    clocks = <&cru ACLK_RKVDEC1>, <&cru HCLK_RKVDEC1>, <&cru CLK_RKVDEC1_CORE>,
             <&cru CLK_RKVDEC1_CA>, <&cru CLK_RKVDEC1_HEVC_CA>;
    clock-names = "aclk_vcodec", "hclk_vcodec", "clk_core",
                  "clk_cabac", "clk_hevc_cabac";
    rockchip,normal-rates = <800000000>, <0>, <600000000>, <600000000>, <1000000000>;
    resets = <&cru SRST_A_RKVDEC1>, <&cru SRST_H_RKVDEC1>, <&cru SRST_RKVDEC1_CORE>,
             <&cru SRST_RKVDEC1_CA>, <&cru SRST_RKVDEC1_HEVC_CA>;
    reset-names = "video_a", "video_h", "video_core",
                  "video_cabac", "video_hevc_cabac";
    iommus = <&rkvdec1_mmu>;
    rockchip,skip-pmu-idle-request;
    rockchip,srv = <&mpp_srv>;
    rockchip,ccu = <&rkvdec_ccu>;
    rockchip,core-mask = <0x00020002>;        /* core1 bitmask */
    rockchip,taskqueue-node = <9>;            /* same queue as core0 */
    rockchip,task-capacity = <16>;
    rockchip,sram = <&vdec1_sram>;
    rockchip,rcb-iova = <0xFFE00000 0x100000>;/* core1 RCB window */
    rockchip,rcb-info = <136 24576>, <137 49152>, <141 90112>, <140 49152>,
                        <139 180224>, <133 49152>, <134 8192>, <135 4352>,
                        <138 13056>, <142 291584>;
    rockchip,rcb-min-width = <512>;
    power-domains = <&power RK3588_PD_RKVDEC1>;
    status = "okay";
};

rkvdec1_mmu: iommu@fdc40700 {
    compatible = "rockchip,rk3588-iommu", "rockchip,rk3568-iommu";
    reg = <0x0 0xfdc40700 0x0 0x40>, <0x0 0xfdc40740 0x0 0x40>;  /* two 0x40 windows -- verified vs live DT + media-0001 */
    interrupts = <GIC_SPI 96 IRQ_TYPE_LEVEL_HIGH 0>;             /* verified on board: SAME line as vdec0's MMU (shared), NOT 98 */
    clocks = <&cru ACLK_RKVDEC1>, <&cru HCLK_RKVDEC1>;
    clock-names = "aclk", "iface";
    power-domains = <&power RK3588_PD_RKVDEC1>;
    rockchip,disable-mmu-reset;
    #iommu-cells = <0>;
    status = "okay";
};
```

```dts
/* DIFF: SRAM RCB pools defined here (convert-in-place reuses media's). */
/* system_sram2@ff001000 has #address-cells=<1> #size-cells=<1>, ranges 0..0xef000. */
&system_sram2 {
    vdec0_sram: sram@0 {
        reg = <0x0 0x78000>;
        pool;                                 /* media marks it a pool; the vendor reads it raw via */
                                              /* of_address_to_resource -- so `pool;` is harmless either way */
    };
    vdec1_sram: sram@78000 {
        reg = <0x78000 0x77000>;              /* 0x78000 + 0x77000 = 0xef000 = system_sram2 size */
        pool;
    };
};

/* DIFF: aliases point at the inline labels (convert points at &vdec0/&vdec1). MANDATORY: */
/* of_alias_get_id(np, "rkvdec") -> core_id; without these no core becomes core 0. */
&{/aliases} {
    rkvdec0 = &rkvdec0;
    rkvdec1 = &rkvdec1;
};
```

Verified-good above (against the driver + the shipped DT patch): all base
addresses, the `regs`/`link` split, the 5 clock + 5 reset macro names for both
cores, `core-mask` (`0x00010001` / `0x00020002`), `taskqueue-node = <9>`,
`rcb-iova`, `rcb-info`, `rcb-min-width`, `ccu-mode`, and the SRAM `@0`/`@78000`
arithmetic. Verified-good against the **running board + `media-0001`**
(2026-07-01, blockquote above): every decoder `GIC_SPI` number (95 / 97 cores,
96 shared MMU line) and the two-window `0x40`+`0x40` MMU `reg` layout. Note
`rockchip,disable-mmu-reset` on the MMU nodes matches the validated config too —
the shipped DT patch's `&vdec0_mmu`/`&vdec1_mmu` overrides add it. To reproduce
the exact trees these anchors resolve against (forward-port tree, `media-0001`
source), see [`docs/00`](00-source-trees.md); the convert-in-place commit is
precisely the diff between this inline form and the `&vdec0 { … }` form
([`docs/08`](08-armbian-packaging.md)).

### Don't ship a working-but-degraded node

A copied core probes even if you drop the *optional* tuning properties, but you
lose throughput silently. In particular set **`rockchip,task-capacity`** (the
example uses `16`): it defaults to `1` (`mpp_common.c:2177`), and `1` disables
link-mode batching, so the decoder runs one task at a time. Also keep
`rockchip,skip-pmu-idle-request` and the `rockchip,rcb-*` set to match the shipped
profile.

> Because mainline 6.18 itself has **no** node at `fdc38000`/`fdc40000`, the inline
> form is purely additive — no conflict, no `/delete-node/`. The convert-in-place
> dance is *only* needed because Armbian backports the V4L2 nodes there.

## If your kernel already has the V4L2 `rkvdec` driver

Pick one stack. Either:
- **Vendor MPP** (this port): don't enable the V4L2 `rockchip,rk3588-vdec` nodes
  (or retype them, convert-in-place style); set `CONFIG_VIDEO_ROCKCHIP_VDEC` off
  or leave it on — it binds nothing if no matching nodes.
- **Mainline V4L2**: don't apply the decoder DT; use the kernel's own nodes. You
  lose H.265 *encode* (no V4L2 encoder) and full-feature RGA.

## Newer kernels (6.19+)

**Read [`docs/12`](12-resyncing.md) first** — it is the dedicated resync
playbook (the two shim-inclusion mechanisms and their opposite failure modes,
the ranked forward-compat hazards, the delta re-measurement). In short, re-check
the **6.18-specific API adaptations** in [`docs/05`](05-vendor-forward-port.md),
especially:
- `iommu_set_fault_handler()` `cookie_type` guard (IOMMU core churns often),
- any `iommu_map()` / `dma-buf` / devfreq signature drift.

The compat-shim + hack-file structure is designed to localize such churn; expect
to touch `mpp_iommu.c` and the `compat/` headers, little else. If your target is
**mainline master** (which now carries its own `&vdec0`/`&vdec1` nodes), the DT
side changes shape — see [`docs/13 § 5`](13-rewrite-drivers.md).
