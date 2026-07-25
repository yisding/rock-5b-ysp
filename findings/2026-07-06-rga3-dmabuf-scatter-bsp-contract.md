# RGA3 dma-buf scatter contract vs BSP

promoted → [`../kernel-drivers/rga/docs/userptr-iommu.md`](../kernel-drivers/rga/docs/userptr-iommu.md) (2026-07-08)

The dma-buf single-span DESIGN-CONSTRAINT (accept adjacent mapped spans, reject
true gaps; keep `userptr_iommu` scoped to driver-owned sg-tables) is now
section 5 of the consolidated RGA3 userptr-IOMMU doc.
