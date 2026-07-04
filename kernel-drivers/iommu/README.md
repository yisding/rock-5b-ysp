# kernel-drivers/iommu/ — CCU / IOMMU memory path

The codec memory path: per-core IOMMUs, dma-buf mapping, and the decoder's
Central Control Unit (CCU). Holds the net-new CCU MMU/IOMMU plan and the SOFT/HARD
CCU finding from the rewrite track.

## Brief

| Field | Contents |
|-------|----------|
| Purpose | How dma-buf buffers get device-side addresses (IOVAs) through each core's IOMMU, and how the decoder CCU shares that across a cluster. |
| Code lives in | Rockchip IOMMU + MPP service code in the sibling kernel trees (`drivers/iommu/rockchip-iommu.c`, `mpp/mpp_iommu.c`, `mpp_rkvdec2*.c`). |
| Current state | CCU IOMMU plan implemented in the rewrite track; SOFT/HARD CCU finding resolved. See [`../docs/rewrite-drivers.md`](../docs/rewrite-drivers.md) and [`../../status.md`](../../status.md). |

## Scoped docs

| Doc | One-liner |
|-----|-----------|
| [`docs/mpp-ccu-iommu-plan.md`](docs/mpp-ccu-iommu-plan.md) | The net-new CCU MMU/IOMMU plan (shared-domain conversion, map/unmap count handling for large dma-buf mappings). |
| [`docs/rewrite-hard-ccu-finding.md`](docs/rewrite-hard-ccu-finding.md) | The RKVDEC2 SOFT/HARD CCU rewrite finding and its validation gap — an exemplary self-describing finding (scope/provenance/date/MEASURED labeling). |

Project vocabulary: [`keywords.md`](keywords.md).
