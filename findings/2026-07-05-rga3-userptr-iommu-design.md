# RGA3 userptr-IOMMU fallback design: driver-owned contiguous IOVA for scattered userptr

promoted → [`../kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) (2026-07-08)

The driver-owned contiguous-IOVA fallback design (guard band, `iommu_map_sg`,
32-bit span rejection, granule fail-closed) is now section 4 of the consolidated
RGA3 userptr-IOMMU doc.
