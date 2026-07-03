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
| RKNN/RKNPU job fails | RKNPU ABI, memory backend, IOMMU domain, power, or task format | RKNN version, DRM render node or `/dev/rknpu`, `drivers/rknpu/`, core mask, fence config |
| Camera produces no frames | sensor, CSI, CIF, ISP graph | `media-ctl`, endpoint graph, regulator/GPIO logs |
| Display blank | DRM bridge/panel/PHY/clock | KMS state, bridge attach, panel prepare/enable |
| Works only as root | device permissions and heaps | `/dev` ownership, udev rules, group membership |
| Works on BSP only | missing vendor service or common-kernel delta | compare DT, Kconfig, service calls, and common patches |
| Random boot race | boot-order/common-kernel policy | initcall/Thunder Boot/async behavior |
| Thunder Boot product hangs | storage handoff, ramdisk decompress, MCU service, or ISP reserved memory | `CONFIG_ROCKCHIP_THUNDER_BOOT*`, `initcall_nr_threads`, `thunder-boot-*` DT nodes, reserved-memory layout |

## Media-specific debug order

1. Confirm `CONFIG_ROCKCHIP_MPP_SERVICE` and the specific subdriver symbol.
2. Confirm the DT node is enabled and its `compatible` matches the subdriver.
3. Confirm the node points at `mpp_srv` when the BSP driver expects it.
4. Confirm taskqueue, CCU, power-domain, clock, reset, and IOMMU properties.
5. Confirm userspace opens `/dev/mpp_service` and required dma-buf heaps.
6. Check IOMMU faults and IRQ counters during a real job.
7. Verify the exact codec path. AV1, JPEG decode, JPEG encode, RKVDEC, and
   RKVENC are different BSP backends even though they share MPP service.

## RKNPU-specific debug order

1. Confirm `CONFIG_ROCKCHIP_RKNPU` and the selected memory backend:
   `ROCKCHIP_RKNPU_DRM_GEM` or `ROCKCHIP_RKNPU_DMA_HEAP`.
2. Confirm the effective DT enables the matching `rockchip,*-rknpu` node, its
   `iommus` provider, IRQ names, clocks, resets, regulators, OPP table, and power
   domains.
3. Confirm userspace opens the expected node: DRM render node for GEM builds or
   `/dev/rknpu` for dma-heap builds.
4. Treat the RKNN runtime, RKNPU ioctl structs, memory flags, IOMMU domain id,
   and PC-mode task buffer format as one compatibility tuple.
5. For `EINVAL`, check task count, core mask, non-PC job flags, fence-in/out
   support, and IOMMU domain id.
6. For timeout, check IRQ status, IOMMU faults, cache synchronization, power
   reset logs, and whether the userspace task buffer matches this BSP kernel.

## Thunder Boot debug order

1. Confirm this is actually a Thunder Boot product build. Check
   `CONFIG_ROCKCHIP_THUNDER_BOOT`, storage-specific symbols, service symbols,
   ISP symbols, and the `initcall_nr_threads=` bootarg.
2. Check the loaded DT for `rockchip,thunder-boot-mmc`,
   `rockchip,thunder-boot-sfc`, `rockchip,thunder-boot-service`,
   `rockchip,thunder-boot-rkisp`, `memory-region-src`,
   `memory-region-dst`, and `memory-region-thunderboot`.
3. Verify reserved-memory addresses and sizes match the loader/RTOS expectation.
   Thunder Boot comments in DTS often state that offsets must match RTOS.
4. If rootfs unpack hangs, check the storage handoff and hardware-decompress
   path before debugging generic initramfs.
5. If camera handoff fails, check the Thunder Boot header completion state,
   sensor `is_thunderboot` behavior, GPIO preservation, and RKISP private ioctls.
6. If probes race only with Thunder Boot enabled, test with
   `initcall_nr_threads=0` to separate async-initcall races from storage, MCU, or
   camera handoff problems.

## DT/probe debug order

1. Verify the loaded DTB.
2. Check `status = "okay"` in the effective tree.
3. Check the OF match table in the driver source.
4. Check probe-defer logs for every provider.
5. Check whether a product DTS overlay disabled or replaced the base node.
6. Check whether the block uses normal `rockchip,iommu-v2` or a special provider
   such as `rockchip,iommu-av1d`.
