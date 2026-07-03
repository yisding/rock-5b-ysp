# BSP troubleshooting map

Use this page to decide which BSP area to inspect first.

| Symptom | Likely BSP area | First place to look |
|---------|-----------------|---------------------|
| Device node missing | DT, Kconfig, driver probe | `compatible`, `status`, config symbol, probe log |
| Probe defers forever | clocks, resets, regulators, power domains, IOMMU | `dmesg`, DT phandles, provider nodes |
| MPP codec job times out | media/Mpp, clocks, IRQ, IOMMU, taskqueue | `/dev/mpp_service`, IRQ count, IOMMU faults, taskqueue node |
| AV1 decode fails | AV1 MPP backend or AV1D IOMMU | `CONFIG_ROCKCHIP_MPP_AV1DEC`, `av1d`, `av1d_mmu`, `rockchip-iommu-av1d.c` |
| JPEG decode fails | JPGDEC backend or `jpegd` DT | `CONFIG_ROCKCHIP_MPP_JPGDEC`, `jpegd`, `jpegd_mmu` |
| JPEG encode fails | JPEGE core wiring or encoder-side task format | `jpege0..3`, `jpege_ccu`, per-core MMUs, RKVENC2 JPEG tables |
| RGA job fails | RGA driver, memory, IOMMU, format | `/dev/rga`, RGA generation, format/stride checks |
| Camera produces no frames | sensor, CSI, CIF, ISP graph | `media-ctl`, endpoint graph, regulator/GPIO logs |
| Display blank | DRM bridge/panel/PHY/clock | KMS state, bridge attach, panel prepare/enable |
| Works only as root | device permissions and heaps | `/dev` ownership, udev rules, group membership |
| Works on BSP only | missing vendor service or common-kernel delta | compare DT, Kconfig, service calls, and common patches |
| Random boot race | boot-order/common-kernel policy | initcall/Thunder Boot/async behavior |

## Media-specific debug order

1. Confirm `CONFIG_ROCKCHIP_MPP_SERVICE` and the specific subdriver symbol.
2. Confirm the DT node is enabled and its `compatible` matches the subdriver.
3. Confirm the node points at `mpp_srv` when the BSP driver expects it.
4. Confirm taskqueue, CCU, power-domain, clock, reset, and IOMMU properties.
5. Confirm userspace opens `/dev/mpp_service` and required dma-buf heaps.
6. Check IOMMU faults and IRQ counters during a real job.
7. Verify the exact codec path. AV1, JPEG decode, JPEG encode, RKVDEC, and
   RKVENC are different BSP backends even though they share MPP service.

## DT/probe debug order

1. Verify the loaded DTB.
2. Check `status = "okay"` in the effective tree.
3. Check the OF match table in the driver source.
4. Check probe-defer logs for every provider.
5. Check whether a product DTS overlay disabled or replaced the base node.
6. Check whether the block uses normal `rockchip,iommu-v2` or a special provider
   such as `rockchip,iommu-av1d`.
