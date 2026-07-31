# kernel-drivers/rga/ — RGA 2D engine driver

The RGA (Raster Graphic Acceleration) 2D engine driver — scale, color-convert,
rotate, blend — exposed via `/dev/rga`. On RK3588 that is two RGA3 cores plus one
RGA2 core, wrapped by the `multi_rga` driver.

The RGA driver ships in the **same** combined patch series as MPP, and the
end-to-end architecture is covered by the shared
[`../docs/how-the-drivers-work.md`](../docs/how-the-drivers-work.md); this
sub-project is the RGA-specific front door.

## Brief

| Field | Contents |
|-------|----------|
| Purpose | The RGA3/RGA2 driver, its `/dev/rga` ABI, IOMMU wiring, and core-profile selection. |
| Developer focus | Buffer-import lifetime, core capability selection, virtual-address/contiguous-IOVA behavior, fence handling, and ABI compatibility with current librga consumers. |
| Owns | [`userptr-iommu.md`](docs/userptr-iommu.md), [`rga2-multisegment-parity-plan.md`](docs/rga2-multisegment-parity-plan.md), [`raw-physical-import-crash.md`](docs/raw-physical-import-crash.md), [`rewrite-5.10-reconciliation.md`](docs/rewrite-5.10-reconciliation.md), [`userspace-consumers.md`](docs/userspace-consumers.md), and [`keywords.md`](keywords.md); shared architecture, patches, and runtime suites remain owned by [`../`](../README.md). |
| Depends on | RK3588 RGA device-tree/IOMMU wiring, the shared kernel infrastructure, and [`../../vendor-libraries/rga/`](../../vendor-libraries/rga/README.md) for userspace jobs. |
| Code lives in | `linux-6.18-rkvenc*` / `rockchip-kernel` `drivers/video/rockchip/rga3/` (`multi_rga`), plus `librga`'s kernel driver. |
| Current state | Probe, IOMMU, and the scale/color-convert path validated through FFmpeg. See [`../../status.md`](../../status.md). |

## Where to read / test

- End-to-end layer model + RGA sections: [`../docs/how-the-drivers-work.md`](../docs/how-the-drivers-work.md).
- DT wiring (nodes `fdb60000`/`fdb70000`/`fdb80000`, IOMMUs): [`../docs/device-tree.md`](../docs/device-tree.md).
- ioctl ABI (incl. intentional `RGA2_GET_VERSION ret=1`): [`../docs/dev-uapis.md`](../docs/dev-uapis.md).
- On-hardware RGA tests: [`../tests/`](../tests/README.md) (`librga-smoke.*`, `librga-suite*.sh`).
- External userspace scan beyond the current conformance set:
  [`userspace-consumers.md`](docs/userspace-consumers.md).
- RGA3 virtual-address import and contiguous-IOVA fallback investigation:
  [`userptr-iommu.md`](docs/userptr-iommu.md).
- RGA2-first plan for legal multi-segment DMA-BUF and USERPTR mappings through
  the internal RGA MMU:
  [`rga2-multisegment-parity-plan.md`](docs/rga2-multisegment-parity-plan.md).
- Raw physical-address import crash, affected Rockchip BSP branches, and the
  required validation fix:
  [`raw-physical-import-crash.md`](docs/raw-physical-import-crash.md).
- Design, implementation, and validation record for the applicable Rockchip
  5.10 RGA fixes adapted to the rewrite:
  [`rewrite-5.10-reconciliation.md`](docs/rewrite-5.10-reconciliation.md).
- Userspace side: [`../../vendor-libraries/rga/`](../../vendor-libraries/rga/README.md).

Project vocabulary: [`keywords.md`](keywords.md).
