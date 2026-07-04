# Area 1: SoC and board descriptions

## Normal-user view

This area is what makes the kernel know which board it is running on and which
hardware blocks are present. Without it, a board can boot and still miss major
features: no video decoder, no encoder, no display connector, no camera, wrong
regulators, wrong clocks, or missing GPIOs.

A user usually experiences this area as:

- the correct board `.dtb` being loaded by the bootloader,
- devices appearing under `/dev` and `/sys`,
- `dmesg` showing drivers probing instead of deferring forever,
- board variants having the right ports, regulators, and lane maps,
- accelerators appearing only after their DT nodes are enabled.

## Kernel-developer view

The BSP adds a wide SoC and product matrix. The first layer is explicit CPU
selection in `drivers/soc/rockchip/Kconfig.cpu`; the BSP includes selectors for
RK312x, RK3036, RK30xx, RK3188, RK3288, RK322x, RV1103B, RV1106, RV1108,
RV1126, RV1126B, PX30, RK1808, RK3308, RK3328, RK3368, RK3399, RK3506, RK3528,
RK3562, RK3568, RK3576, and RK3588. Driver code then uses those symbols to
include SoC-specific tables, quirks, and compatible strings.

The second layer is device tree. In the BSP comparison, most architecture-level
new files are Rockchip DTS/DTSI files and config fragments. RK3588 alone has a
large set of base, EVB, tablet, PC, NVR, vehicle, toybrick, and product include
files.

Typical BSP paths:

- `drivers/soc/rockchip/Kconfig.cpu`
- `arch/arm64/boot/dts/rockchip/`
- `arch/arm/boot/dts/`
- `arch/arm64/configs/`
- `arch/arm/configs/`
- `Documentation/devicetree/bindings/`

```mermaid
flowchart LR
  bootloader["Bootloader"]
  dtb["Board DTB"]
  ofcore["Linux OF core"]
  pdev["platform devices"]
  drivers["BSP and generic drivers"]
  hw["Enabled board hardware"]

  bootloader --> dtb --> ofcore --> pdev --> drivers --> hw
```

## What the BSP adds beyond stock Linux

| Addition | What it does |
|----------|--------------|
| CPU selectors | Let BSP drivers compile SoC-specific feature tables and workarounds. |
| Product DTS/DTSI files | Describe complete boards and product families, not just SoC IP blocks. |
| Media/display/camera nodes | Wire MMIO, IRQs, clocks, resets, power domains, IOMMUs, and service phandles. |
| Config fragments | Build product kernels with the expected BSP driver stack enabled. |
| Vendor bindings | Add properties such as `rockchip,srv`, taskqueue nodes, CCU phandles, OPP/PVTM details, and QoS/shaping links. |

## RK3588 media example

RK3588's base DTSI shows the style clearly. The BSP defines an `mpp-srv` service
node with task queues, then routes codec devices to it with `rockchip,srv` and
`rockchip,taskqueue-node`. It also defines separate IOMMU nodes for the media
blocks.

For RK3588, relevant BSP nodes include:

- `mpp_srv: mpp-srv` with `rockchip,taskqueue-count = <12>`.
- `jpegd` plus `jpegd_mmu`.
- `jpege0` through `jpege3`, each with its own MMU and shared `jpege_ccu`.
- `rkvenc0` and `rkvenc1`, each with MMU nodes and `rkvenc_ccu`.
- `rkvdec0` and `rkvdec1`, each with MMU nodes, RCB information, SRAM, and
  `rkvdec_ccu`.
- `av1d` plus `av1d_mmu`, where the AV1 node has `vcd`, `cache`, and `afbc`
  register banks.

## Bring-up checklist

1. Verify the bootloader loaded the DTB you are editing.
2. Match every `compatible` string against the BSP driver's OF match table.
3. Check clocks, resets, power domains, and IOMMU phandles together.
4. Check service phandles such as `rockchip,srv`; they are real dependencies for
   vendor drivers.
5. Check taskqueue and CCU properties for multi-core codec blocks.
6. Do not copy product DTS fragments blindly; many carry board-specific GPIO,
   regulator, lane-map, or power assumptions.

## Common failure signs

| Symptom | Likely DT issue |
|---------|-----------------|
| Driver never probes | missing/disabled node or wrong `compatible` string |
| Probe defers forever | missing clock, reset, regulator, power domain, or IOMMU provider |
| Device probes but no jobs complete | wrong IRQ, clock rate, reset, service phandle, or IOMMU mapping |
| One board variant works and another does not | board-level power, pinctrl, or lane-map difference |
