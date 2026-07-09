# Why RGA3 userptr imports get non-contiguous IOVAs: per-segment mapping, not the guard band

promoted → [`../kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) (2026-07-08)

The descending-IOVA fingerprint, the per-segment-vs-coalesced analysis, and the
still-UNRESOLVED bounce trigger are now section 3 of the consolidated RGA3
userptr-IOMMU doc.
