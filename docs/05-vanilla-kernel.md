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

Concretely, in `rk3588-base.dtsi`, instead of overriding `&vdec0/&vdec1`, define:

```dts
rkvdec_ccu: rkvdec-ccu@fdc30000 { compatible = "rockchip,rkv-decoder-v2-ccu"; ... };

rkvdec0: rkvdec-core@fdc38000 {
    compatible = "rockchip,rkv-decoder-v2";
    reg = <0x0 0xfdc38100 0x0 0x400>, <0x0 0xfdc38000 0x0 0x100>;  reg-names = "regs","link";
    interrupts = <GIC_SPI 95 ...>;  interrupt-names = "irq_rkvdec0";
    clocks = <&cru ACLK_RKVDEC0>, <&cru HCLK_RKVDEC0>, <&cru CLK_RKVDEC0_CORE>,
             <&cru CLK_RKVDEC0_CA>, <&cru CLK_RKVDEC0_HEVC_CA>;
    clock-names = "aclk_vcodec","hclk_vcodec","clk_core","clk_cabac","clk_hevc_cabac";
    resets = <&cru SRST_A_RKVDEC0>, ...;  reset-names = "video_a","video_h","video_core","video_cabac","video_hevc_cabac";
    iommus = <&rkvdec0_mmu>;
    rockchip,srv = <&mpp_srv>;  rockchip,ccu = <&rkvdec_ccu>;
    rockchip,core-mask = <0x00010001>;  rockchip,taskqueue-node = <9>;
    rockchip,sram = <&vdec0_sram>;
    rockchip,rcb-iova = <0xFFF00000 0x100000>;  rockchip,rcb-info = <...>;
    power-domains = <&power RK3588_PD_RKVDEC0>;
    status = "okay";
};
rkvdec0_mmu: iommu@fdc38700 { compatible="rockchip,rk3588-iommu","rockchip,rk3568-iommu"; ...; rockchip,disable-mmu-reset; #iommu-cells=<0>; };
/* rkvdec1 @ fdc40000 + rkvdec1_mmu @ fdc40700, core-mask 0x00020002, rcb-iova 0xFFE00000 */
/* vdecN_sram pools under system_sram2@ff001000 */
/* aliases: rkvdec0 = &rkvdec0; rkvdec1 = &rkvdec1; */
```

These exact node bodies are in the **commit history** of the dev tree (the state
*before* the convert-in-place rewrite) and in `docs/03`/`docs/04`. The git commit
that introduced convert-in-place is the diff between the two forms.

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

Re-check the **6.18-specific API adaptations** in `docs/02`, especially:
- `iommu_set_fault_handler()` `cookie_type` guard (IOMMU core churns often),
- any `iommu_map()` / `dma-buf` / devfreq signature drift.

The compat-shim + hack-file structure is designed to localize such churn; expect
to touch `mpp_iommu.c` and the `compat/` headers, little else.
