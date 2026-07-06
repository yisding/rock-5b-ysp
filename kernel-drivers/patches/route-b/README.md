# RGA3 Route B userptr mapping

Experimental follow-up patches for scattered RGA3 `virt_addr` / userptr
buffers. These are not part of the validated base patch pair yet; they are the
candidate Route B implementation on top of the current forward-port and rewrite
trees.

## Patches

| Patch | Target | Purpose |
|-------|--------|---------|
| `0001-media-rockchip-rga3-map-scattered-userptr-through-IOMMU.patch` | `../kernel/linux-6.18-rkvenc-av1-fwport` | Adds Route B to the vendor-style RGA3 forward-port. |
| `0002-media-rockchip-rga-rewrite-add-Route-B-userptr-mapping.patch` | `../kernel/linux-6.18-rkvenc` and `../kernel/linux` | Adds the same userptr fallback to the compatibility rewrite. |

Detailed architecture notes live in [`architecture.md`](architecture.md).
Runtime validation instructions live in [`runtime-validation.md`](runtime-validation.md).

## Consumption Boundary

For the RK3588 forward-port runtime test, consume patch 0001 by applying it to
the current forward-port source tree first, then point `build-armbian-deb.sh` at
that patched source tree with `KERNEL_TREE=...`. The build script regenerates a
complete Armbian userpatch archive from `v6.18..HEAD`, minus the script's
`SKIP_COMMITS` list for commits already carried by the Armbian base. It does not
consume patch 0001 directly as a standalone Armbian userpatch.

Patch 0002 is not part of the forward-port kernel build. It is the compatibility
rewrite version of the same Route B design and should only be applied when
building one of the rewrite trees.

Before installing a Route B kernel, use the exact `PHASH` printed by the build
script. Do not reuse an older `PHASH`, and do not treat the static checks below
as runtime validation.

## Architecture

RGA3 command streams carry base addresses, not scatterlists. The normal import
contract is therefore still one non-wrapping DMA segment below the 32-bit-safe
guard band. DMA-buf imports remain fail-closed on that contract.

Route B is a fallback for driver-owned sg-tables after the normal DMA API map
has been tried and rejected. Scattered pinned userptr is the target path.
DMA-buf imports remain excluded because the driver does not own their physical
page list and should not replace the exporter/attachment mapping contract.

The two patch targets share the same mapping model, but the hook points differ:

- forward-port: the shared `rga_dma_map_sgt()` helper uses Route B for
  driver-owned sg-tables, including the `virt_addr` path and the
  physical-address IOMMU path that builds an sg-table from pages;
- rewrite: Route B is wired only into pinned userptr imports and per-job
  userptr remaps; dma-buf imports and dma-buf remaps are validated and rejected
  if they are not one 32-bit-safe DMA span. Patch 0002 also sets the RGA3 DMA
  mask/coherent mask and clamps `bus_dma_limit`, so normal DMA API placement and
  dma-buf validation use the same 32-bit guard-band contract.

1. Try the normal DMA API map first.
2. If the result violates the single-segment or 32-bit span contract, unmap it.
3. Reset the sg-table DMA bookkeeping left by that abandoned map, including
   stale SWIOTLB flags when present.
4. Build a temporary page-aligned sg-table copy from the original physical
   sg-table. This is only for the IOMMU map call; the original sg-table remains
   the ownership and cache-maintenance object.
5. Allocate one IOVA range from the translated RGA DMA domain's existing DMA
   IOVA allocator, capped by the device DMA mask, bus limit, domain aperture,
   and `DMA_BIT_MASK(32) - SZ_512M`.
6. Map the aligned sg-table copy with `iommu_map_sg()` using permissions derived
   from the original DMA direction.
7. Program the synthetic IOVA plus the original first-page offset as the RGA
   base address.
8. Track Route B ownership in the buffer/import metadata; teardown uses
   `iommu_unmap()` plus `free_iova_fast()` instead of `dma_unmap_sg*()`.

Route B deliberately uses the DMA domain's allocator instead of a private driver
allocator. Both patches add a small exported `iommu_dma_get_iova_domain()`
helper in `drivers/iommu/dma-iommu.c`, where the private DMA cookie type is
visible, instead of casting the opaque cookie through an RGA-local shadow type.
This keeps synthetic IOVA allocation in the same address space as the DMA API
mappings.

Route B fails closed if the domain is not a translated paging domain, if the
domain does not expose a DMA IOVA cookie, or if the DMA domain's IOVA granule is
larger than `PAGE_SIZE`. RGA needs one byte-contiguous view; with larger IOVA
granules, `iommu_map_sg()` may need padding between non-contiguous user pages.
The 32-bit span validator also treats arithmetic overflow as a hard mapping
error before checking the RGA register-visible end address.

The forward-port also fixes non-contiguous cache sync to use the device that
created the mapping. The rewrite already had userptr sync hooks; the Route B
patch makes sure those hooks see a clean physical sg-table after the abandoned
DMA API map. In both targets, cache maintenance stays on the original physical
sg-table, not on the temporary aligned copy. The forward-port patch also marks
writable userptr pages dirty before dropping their GUP references.

## Verification

Run from this repo:

```bash
git -C ../kernel/linux-6.18-rkvenc-av1-fwport apply --check \
  /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/route-b/0001-media-rockchip-rga3-map-scattered-userptr-through-IOMMU.patch

git -C ../kernel/linux-6.18-rkvenc apply --check \
  /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/route-b/0002-media-rockchip-rga-rewrite-add-Route-B-userptr-mapping.patch

git -C ../kernel/linux apply --check \
  /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/route-b/0002-media-rockchip-rga-rewrite-add-Route-B-userptr-mapping.patch

../kernel/linux-6.18-rkvenc-av1-fwport/scripts/checkpatch.pl --strict \
  kernel-drivers/patches/route-b/0001-media-rockchip-rga3-map-scattered-userptr-through-IOMMU.patch \
  kernel-drivers/patches/route-b/0002-media-rockchip-rga-rewrite-add-Route-B-userptr-mapping.patch
```

Status on 2026-07-05:

- All three `git apply --check` commands pass.
- Strict checkpatch reports `0 errors, 0 warnings, 0 checks` for both patches.
- Focused object builds pass in temp trees after the page-granule and
  overflow-safe span guards; the same focused targets also pass with `W=1`:
  - forward-port: `rga_dma_buf.o`, `rga_mm.o`, `rga_drv.o`
  - rewrite: `rga_rewrite.o`

No RK3588 hardware runtime validation has been run yet for Route B. The required
runtime gate is the scattered `virt_addr` librga path that previously failed
closed, plus the contiguous-buffer regression path that already passed before
Route B. The gate must also include route-specific attribution, such as a
temporary debug counter/print proving `rga_dma_map_sgt_iommu()` handled at least
one selected case, before claiming the Route B fallback itself is runtime-proven.
