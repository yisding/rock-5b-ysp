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
| Code lives in | `linux-6.18-rkvenc*` / `rockchip-kernel` `drivers/video/rockchip/rga3/` (`multi_rga`), plus `librga`'s kernel driver. |
| Current state | Probe, IOMMU, and the scale/color-convert path validated through FFmpeg. See [`../../status.md`](../../status.md). |

## Where to read / test

- End-to-end layer model + RGA sections: [`../docs/how-the-drivers-work.md`](../docs/how-the-drivers-work.md).
- DT wiring (nodes `fdb60000`/`fdb70000`/`fdb80000`, IOMMUs): [`../docs/device-tree.md`](../docs/device-tree.md).
- ioctl ABI (incl. intentional `RGA2_GET_VERSION ret=1`): [`../docs/dev-uapis.md`](../docs/dev-uapis.md).
- On-hardware RGA tests: [`../tests/`](../tests/README.md) (`librga-smoke.*`, `librga-suite*.sh`).
- External userspace scan beyond the current conformance set:
  [`userspace-consumers.md`](userspace-consumers.md).
- RGA3 virtual-address import and contiguous-IOVA fallback investigation:
  [`userptr-iommu.md`](userptr-iommu.md).
- Userspace side: [`../../vendor-libraries/rga/`](../../vendor-libraries/rga/README.md).

Project vocabulary: [`keywords.md`](keywords.md).
