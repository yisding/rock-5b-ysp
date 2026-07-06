# Route B Architecture

Route B is the scoped fallback for RGA3 buffers that are owned by the RGA
driver, backed by an sg-table, and cannot be represented by the normal DMA API
as one 32-bit-safe DMA segment. It maps those pages into one contiguous IOVA span
inside the already translated RGA DMA domain, then programs that synthetic IOVA
into the existing RGA command path.

The implementation deliberately does not change the RGA hardware contract:
command streams still carry base addresses, not scatterlists. Every imported
plane must still resolve to one byte-contiguous device-visible address range
whose programmed base and final byte fit in the RGA3 32-bit address registers.

## What "IOMMU" Means Here

RGA3 on RK3588 uses the external Rockchip system IOMMU, not the older internal
RGA MMU. Debugfs reports the RGA3 cores as `mmu: RK_IOMMU`; the RGA2 core reports
`mmu: RGA_MMU`. That distinction matters when reading the vendor debug logs:

- RGA3 command dumps can print internal command fields as
  `mmu: win0 = 00 win1 = 00 wr = 00`. That does not mean the job is using
  physical addresses. It means the RGA3 internal MMU command bits are disabled.
  Address translation is still handled by the external RK_IOMMU attached to the
  RGA device.
- `handle[...] iova = ... dma_addr = ...` lines in the RGA3 logs are the
  device-visible addresses programmed into the command stream. With Route B,
  those addresses can be synthetic IOVAs allocated by the driver from the same
  translated DMA domain allocator that the DMA API uses.
- The hardware still gets one base address per plane. Neither the external
  RK_IOMMU nor Route B changes the command stream into a scatterlist ABI.

The installed Route-B-only 6.18 test image was checked with `strings` on
`/boot/vmlinuz-6.18.38-current-rockchip64`: it contains the Route B strings
`driver-owned IOMMU` and `iommu_dma_get_iova_domain`, and it does not contain the
temporary diagnostic string `DIAG rga_dma_map_sgt`. That proves the image has the
clean Route B code, but not the temporary fallback breadcrumb commits.

## Invariants

- DMA-buf imports remain fail-closed. If a dma-buf import does not map as one
  non-wrapping 32-bit DMA span, the import is rejected rather than remapped by
  RGA.
- Route B is only for driver-owned sg-tables. In the forward-port, that means
  `rga_dma_map_sgt()` users: scattered pinned userptr and the physical-address
  IOMMU path that builds an sg-table from pages. In the rewrite, it is wired only
  into pinned userptr imports and per-job userptr remaps.
- The fallback uses the translated RGA domain that the DMA API already uses for
  the selected mapping device. It does not create a private IOMMU domain.
- IOVA allocation comes from the domain's existing DMA IOVA allocator via the
  domain cookie, so Route B shares allocator ownership with the DMA API instead
  of inventing an overlapping allocator.
- Route B caps allocation at the minimum of the device DMA mask,
  `dev->bus_dma_limit`, any forced IOMMU aperture limit, and
  `DMA_BIT_MASK(32) - SZ_512M`.
- Route B fails closed if the IOVA allocator granule is larger than `PAGE_SIZE`.
  RGA needs a byte-contiguous view; larger granules can require padding between
  unrelated physical pages.
- All span arithmetic is overflow-checked before any address is accepted for RGA
  register programming.

## Forward-Port Flow

Patch 0001 modifies the vendor-style RGA3 forward-port.

1. `rga_mm_map_virt_addr()` pins user pages and builds an sg-table through the
   existing vendor memory path. `rga_mm_map_phys_addr()` can also build a
   driver-owned sg-table when the scheduler uses the Rockchip IOMMU.
2. Both paths call `rga_dma_map_sgt()`.
3. `rga_dma_map_sgt()` first tries `dma_map_sg()`.
4. If the DMA API result satisfies the one-segment/32-bit contract, the existing
   DMA API mapping is kept.
5. If the normal map returns multiple segments or a wrapping/overflowing span,
   the driver immediately calls `dma_unmap_sg()`, resets sg DMA bookkeeping
   (`sg_dma_address`, `sg_dma_len` when present, and `SG_DMA_BUS_ADDRESS` /
   `SG_DMA_SWIOTLB` when present), then enters Route B.
6. Route B builds a temporary page-aligned sg-table copy. This copy is used only
   for `iommu_map_sg()`, because the IOMMU map operation needs page-aligned
   physical ranges.
7. The driver allocates one IOVA span from the RGA DMA domain cookie and maps the
   aligned sg copy into that span with `iommu_map_sg()`.
8. The original first-page offset is added back when programming the IOVA. The
   stored base remains the page-aligned IOVA so teardown can unmap the exact
   mapped range.
9. `rga_mm_lookup_iova()` returns `buffer->iova + buffer->offset`, preserving the
   existing command generator shape.
10. Writable userptr imports remember that they were mapped for device writes.
    On release, their GUP-held pages are marked dirty before `put_page()`.
11. Teardown checks `buffer->iommu_mapped`. Route B mappings use
    `iommu_unmap()` plus `free_iova_fast()`; normal DMA API mappings still use
    `dma_unmap_sg()`.

The forward-port also changes non-contiguous cache sync to use
`buffer->dma_buffer->map_dev`, the device that created the mapping, rather than
the current scheduler device. That matters because Route B keeps cache
maintenance on the original physical sg-table while the programmed address is
the synthetic IOVA.

## Rewrite Flow

Patch 0002 applies the same design to the compatibility rewrite, but at the
rewrite import layer rather than a shared `rga_dma_map_sgt()` helper.

1. Persistent userptr imports pin pages, build an sg-table, and try
   `dma_map_sgtable()`.
2. Per-job userptr remaps use the same helper when an import must be mapped for a
   different RGA device.
3. If the DMA API map is one segment and 32-bit-safe, it is kept.
4. If that map violates the contract, the rewrite unmaps it, clears stale sg DMA
   state, and runs Route B with the same cookie-backed IOVA allocation and
   page-aligned `iommu_map_sg()` copy used in the forward-port.
5. Persistent imports and per-job mappings both store `domain`, `iova_size`,
   `page_offset`, and `iommu_mapped`, so their release paths can distinguish
   Route B from DMA API ownership.
6. Dma-buf imports and dma-buf per-job remaps only run the fail-closed contract
   check. They do not enter Route B.

The rewrite already had explicit userptr sync hooks around job submission and
completion. Route B preserves those hooks by keeping the original physical
sg-table as the object passed to `dma_sync_sgtable_for_device()` and
`dma_sync_sgtable_for_cpu()`.

Patch 0002 also adds RGA3 DMA-mask setup in probe: 40-bit streaming DMA mask,
32-bit coherent mask, and a `bus_dma_limit` clamp at
`DMA_BIT_MASK(32) - SZ_512M`. That is not a Route B fallback hook, but it is part
of the rewrite's RGA3 import contract because it constrains normal DMA API
placement and dma-buf validation before any userptr fallback is considered.

## Domain And Allocator Model

The patches call `iommu_get_domain_for_dev(map_dev)` because the 6.18 trees used
here declare `iommu_get_dma_domain()` but do not export it. The selected
`map_dev` is the same device used for the normal DMA API map, so the returned
domain is expected to be the translated DMA domain.

The kernel does not expose `struct iommu_dma_cookie` to drivers. Route B adds a
small exported `iommu_dma_get_iova_domain()` helper inside
`drivers/iommu/dma-iommu.c`, where the private cookie type is visible, and has
RGA call that helper instead of casting the opaque cookie through a local shadow
type. The helper checks `domain->cookie_type == IOMMU_COOKIE_DMA_IOVA` and
returns `NULL` for unsupported domains.

This is intentionally narrower than a private allocator. `alloc_iova_fast()` and
`free_iova_fast()` operate on the DMA domain's allocator, so Route B allocations
cannot overlap DMA API allocations from the same domain.

## Cache And Coherency Model

RK3588 RGA3 is non-coherent. Route B maps the pages directly with
`iommu_map_sg()`, so it must not depend on SWIOTLB bounce buffers for coherency.
The implementation keeps cache maintenance on the original physical sg-table:

- forward-port userptr buffers keep `RGA_MEM_FORCE_FLUSH_CACHE`, and the
  non-contiguous sync helpers call `dma_sync_sg_for_device()` /
  `dma_sync_sg_for_cpu()` on the original sg-table through `map_dev`;
- forward-port writable userptr buffers also mark their GUP-held pages dirty on
  release before dropping the page references;
- rewrite userptr imports and remaps continue to run
  `dma_sync_sgtable_for_device()` before submission and
  `dma_sync_sgtable_for_cpu()` after completion.

Resetting stale `SG_DMA_SWIOTLB` state after the abandoned DMA API map is part of
that coherency model. Without it, later sync calls could operate on stale bounce
state rather than the pinned physical pages now mapped by Route B.

## Failure Behavior

Route B returns an error and leaves no ownership behind if any step fails:

- no translated paging domain;
- unsupported DMA IOVA cookie;
- IOVA granule larger than `PAGE_SIZE`;
- map size not aligned to the allocator granule;
- IOVA allocation failure;
- invalid DMA direction/protection flags;
- short or failed `iommu_map_sg()`;
- overflow or 32-bit-span violation after adding the original page offset.

Short `iommu_map_sg()` results are explicitly unmapped before the IOVA is freed.
Normal DMA API maps are always unmapped before Route B starts, and the sg-table
DMA state is reset before later cache sync or remap attempts.

## Differences Between The Two Patches

The algorithm is intentionally the same, but the attachment points differ:

- the forward-port has a reusable `rga_dma_map_sgt()` helper, so Route B lives
  there and covers every driver-owned sg-table that flows through it;
- the rewrite has explicit import objects and per-job mapping records, so Route B
  is implemented at the userptr import/remap boundary and records ownership in
  those objects.

That difference avoids forcing the rewrite into the vendor helper shape while
still keeping the core Route B rules aligned.

## Runtime Evidence Boundary

As of 2026-07-05:

- both patches apply to their target trees;
- strict checkpatch is clean;
- focused object builds pass;
- focused `W=1` object builds pass;
- a Route-B-only forward-port kernel passed repeated scattered `virt_addr`
  librga smoke runs on RK3588 without RGA/IOMMU faults.

The runtime result is a behavioral pass and strong indirect evidence for Route B:
the same demo family previously produced non-contiguous `orig_nents == nents`
DMA mappings and failed closed with `reject sg_table DMA mapping`, while the
Route-B-only image now runs the selected cases to completion with no rejects,
faults, or failed RGA jobs.

It is still not direct forward-port fallback-path proof. The clean image
intentionally lacks a success log/counter in `rga_dma_map_sgt_iommu()`, so the
artifacts cannot show which individual import entered Route B. Forward-port
completion still requires either a one-run debug-tip kernel or a temporary
positive breadcrumb/counter in the Route B helper, plus the same case passing
without RGA/IOMMU faults. The rewrite now has a permanent development-only
`rk_rga_rewrite/route_b` counter surface for this attribution, but it still needs
a booted rewrite run.
