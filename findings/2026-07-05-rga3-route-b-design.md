# RGA3 Route B design: driver-owned contiguous IOVA for scattered userptr

> Scope: forward-port `../kernel/linux-6.18-rkvenc-av1-fwport` RGA3 driver,
> rewrite trees `../kernel/linux-6.18-rkvenc` and `../kernel/linux`, and patch
> artifacts in `kernel-drivers/patches/route-b/`.
> Source: Route B patch construction and focused object builds on 2026-07-05.
> Date: 2026-07-05
> Trust: CODE-INSPECTED / BUILD-VERIFIED. Hardware runtime validation pending.
> Related: [[2026-07-04-rga3-im2d-error-irq]],
> [[2026-07-05-rga3-memory-import-contract]],
> [[2026-07-05-rga3-scattered-iova-mechanism]]
> Architecture: `kernel-drivers/patches/route-b/architecture.md`

## Finding

Route B can be implemented without relaxing the RGA3 import contract. Keep
DMA-buf imports fail-closed on "one 32-bit-safe DMA span", but for driver-owned
sg-tables the driver can build its own contiguous IOVA span in the translated RGA
domain. Scattered pinned userptr is the target path.

The final architecture has two deliberately different hook points with the same
mapping semantics:

- **forward-port:** Route B lives in the shared `rga_dma_map_sgt()` helper. That
  covers `virt_addr` userptr imports and the physical-address IOMMU path because
  both are driver-owned sg-tables;
- **rewrite:** Route B is only used for pinned userptr imports and per-job
  userptr remaps. DMA-buf imports and remaps are validated and rejected if they
  are not one 32-bit-safe DMA span. Patch 0002 also sets the RGA3 streaming DMA
  mask, coherent DMA mask, and `bus_dma_limit` guard so normal DMA API placement
  follows the same 32-bit-safe contract before the userptr fallback is considered.

The common Route B flow is:

- normal `dma_map_sg*()` is still tried first;
- if it returns multiple DMA segments or a 32-bit-wrapping span, it is unmapped;
- the sg-table DMA bookkeeping from that abandoned map is cleared, including
  `SG_DMA_SWIOTLB`, so later cache sync uses the physical pages instead of stale
  bounce-buffer state;
- a page-aligned temporary sg-table is built from the original physical sg-table
  and passed to `iommu_map_sg()`;
- the original sg-table remains the pin/unpin and cache-maintenance object;
- the programmed address is the synthetic page-aligned IOVA plus the original
  first-page offset. The forward-port stores base and offset separately and
  `rga_mm_lookup_iova()` adds them; the rewrite stores the offset-adjusted IOVA
  and subtracts the saved offset during Route B teardown;
- teardown records Route B ownership and uses `iommu_unmap()` plus
  `free_iova_fast()`, never `dma_unmap_sg*()`, for synthetic mappings.
- the forward-port records writable userptr mappings and marks their GUP-held
  pages dirty before dropping the page references.

Because RGA3 consumes one base address rather than a scatterlist, Route B also
fails closed if the DMA domain's IOVA granule is larger than `PAGE_SIZE`. A
larger granule could force padding between non-contiguous user pages and break
the byte-contiguous view RGA expects. This is not expected to affect RK3588's
4 KiB Rockchip IOMMU setup, but making it explicit keeps the fallback honest on
future ports.

The allocator is intentionally the translated DMA domain's existing IOVA
allocator, not a private driver allocator. The patches expose that allocator
through a small `iommu_dma_get_iova_domain()` helper in
`drivers/iommu/dma-iommu.c`, where the private DMA cookie type is visible,
instead of casting the opaque cookie through an RGA-local shadow type. This
keeps Route B allocation in the same address space as the DMA API mappings.
Route B fails closed if the device has no translated paging domain or if the
domain has no DMA IOVA cookie.

The same 32-bit-safe guard band stays load-bearing. Route B caps allocations at
the minimum of the device DMA mask, `bus_dma_limit`, any forced domain aperture,
and `DMA_BIT_MASK(32) - SZ_512M`, so a synthetic mapping does not reintroduce
the RGA3 register-wrap fault fixed by the earlier guard-band change. The
validator uses an overflow-checked `base + size - 1` calculation, so oversized
or wrapped spans fail closed before any address is programmed.

This is still a candidate architecture until the runtime gate passes with
route-specific attribution. Static verification proves that the patches apply,
pass style, and build; it does not prove that scattered `virt_addr` jobs
complete on RK3588 hardware or that the silent Route B fallback was executed.

## Verification

Patch artifacts:

- `kernel-drivers/patches/route-b/0001-media-rockchip-rga3-map-scattered-userptr-through-IOMMU.patch`
- `kernel-drivers/patches/route-b/0002-media-rockchip-rga-rewrite-add-Route-B-userptr-mapping.patch`

Verification on 2026-07-05:

- `git apply --check` passes against the forward-port tree for patch 0001.
- `git apply --check` passes against both rewrite trees for patch 0002.
- strict checkpatch is clean for both patches.
- focused object builds pass for the touched forward-port RGA3 objects and the
  rewrite `rga_rewrite.o`, including the page-granule and overflow-safe span
  guards; the same focused targets also pass with `W=1`.

Hardware runtime validation is still pending; the runbook is
`kernel-drivers/patches/route-b/runtime-validation.md`. Until that is run and
records fallback-path evidence, the finding is "build-verified candidate
design", not a runtime-proven fix.
