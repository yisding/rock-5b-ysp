# RGA3 dma-buf scatter contract vs BSP

Scope: RK3588 RGA3 dma-buf imports, RGA userptr-IOMMU fallback boundary, and
local 6.1 BSP behavior.

Source anchor:

- local BSP tree: `/home/yi/Code/kernel/rockchip-kernel`
- `drivers/video/rockchip/rga3/rga_dma_buf.c`
- `drivers/video/rockchip/rga3/rga_mm.c`
- `drivers/video/rockchip/rga3/rga_iommu.c`
- YSP RGA userptr-IOMMU docs and patch series under
  `kernel-drivers/patches/rga-userptr-iommu/`

Date: 2026-07-06

Trust: CODE-INSPECTED / DESIGN-CONSTRAINT

## Finding

A dma-buf can be physically non-contiguous, but that is not by itself a problem
for RGA3. The RGA3 command stream still programs one base address per plane, so
the safety boundary is whether the dma-buf attachment maps to one byte-contiguous
device-visible DMA/IOVA span.

The local BSP does **not** implement a separate dma-buf IOMMU remap fallback that
allocates one synthetic contiguous IOVA span for exporter-owned dma-bufs. For
RGA3 dma-buf imports, the BSP:

1. calls `dma_buf_attach()` and `dma_buf_map_attachment()`;
2. records `sg_dma_address(sgt->sgl)` from the first scatterlist entry;
3. sums `sg_dma_len()` across the scatterlist into `buffer->size`;
4. does not call `iommu_map_sg()` or allocate a new IOVA span for that dma-buf.

The relevant BSP code paths are:

- `rga_dma_map_buf()` uses `dma_buf_map_attachment()` and stores the first
  `sg_dma_address()`;
- `rga_dma_map_fd()` does the same fd-backed import path;
- `rga_dma_map_sgt()` is the normal `dma_map_sg()` path for driver-owned
  sg-tables, not an exporter-owned dma-buf remap fallback.

The BSP also does not check for the safe "multi-entry but contiguous DMA span"
case. Its RGA3 `rga_mm_check_contiguous_sgt()` helper returns true only when
`sgt->orig_nents == 1`. It does not walk `sg_dma_address()` / `sg_dma_len()` and
does not test adjacency with `prev_dma + prev_len == next_dma`.

The BSP does have an internal RGA MMU page-table helper,
`rga_mm_sgt_to_page_table()`, which can walk scatterlist entries. That is not
the same as a dma-buf external-IOMMU remap fallback:

- it builds an RGA page table for the internal RGA MMU-style command path;
- `rga_mm_is_need_mmu()` explicitly returns false when the selected scheduler
  uses `RGA_IOMMU`, with the comment "RK_IOMMU no need to configure enable or
  not in the driver";
- RGA3 on RK3588 uses the external Rockchip IOMMU path, so the internal page-table
  mechanism is not evidence for option #5 style dma-buf remapping.

## Consequence For YSP

YSP should not add a dma-buf userptr-IOMMU-style remap path just because
dma-bufs can be physically scattered. That would create new ownership and fence /
cache-sync questions around exporter-owned mappings, and it is not something the
studied BSP RGA3 path does.

The better contract is:

- accept dma-bufs whose mapped attachment is one byte-contiguous, non-wrapping,
  32-bit-safe DMA/IOVA span;
- reject true gaps, descending DMA addresses, wrap, or 32-bit overflow;
- do not increment `userptr_iommu` counters for dma-buf imports;
- keep RGA userptr-IOMMU fallback scoped to driver-owned sg-tables: pinned
  userptr and the physical-address IOMMU path.

If real workloads frequently hit dma-buf rejects, the first improvement should be
a contiguous-DMA-span validator that accepts adjacent multi-entry mappings. That
would be stricter than the BSP unsafe case, because it proves the device-visible
span before programming base+size, while still accepting a safe case that
`orig_nents == 1` cannot distinguish.

## Validation Gap

A future negative gate should create or obtain a dma-buf whose RGA attachment maps
as multiple DMA segments, then verify:

1. adjacent entries are accepted only if the whole span is one contiguous,
   non-wrapping, 32-bit-safe DMA/IOVA range;
2. true gaps are rejected cleanly before hardware submit;
3. `userptr_iommu/{attempt,ok,active}` do not move for dma-buf imports, even with
   `force_remap` enabled;
4. dmesg contains no RGA/IOMMU fault for the rejected case.
