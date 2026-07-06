# RGA3 Route B userptr mapping

Follow-up patches for scattered RGA3 `virt_addr` / userptr buffers. Patch 0001
is the forward-port Route B implementation that now has RK3588 behavioral smoke
coverage; patch 0002 is the same design ported to the rewrite trees; patch 0003
adds rewrite-side debugfs counters and a `force_remap` knob so a booted rewrite
kernel can directly attribute fallback execution. The rewrite path remains
build-verified until a rewrite kernel is booted.

## Patches

| Patch | Target | Purpose |
|-------|--------|---------|
| `0001-media-rockchip-rga3-map-scattered-userptr-through-IOMMU.patch` | `../kernel/linux-6.18-rkvenc-av1-fwport` | Adds Route B to the vendor-style RGA3 forward-port. |
| `0002-media-rockchip-rga-rewrite-add-Route-B-userptr-mapping.patch` | `../kernel/linux-6.18-rkvenc` and `../kernel/linux` | Adds the same userptr fallback to the compatibility rewrite. |
| `0003-media-rockchip-rga-rewrite-add-route-b-debugfs-counters.patch` | `../kernel/linux-6.18-rkvenc` and `../kernel/linux` | Adds `rk_rga_rewrite/route_b/{attempt,ok,active,force_remap}` for rewrite runtime attribution. |

Detailed architecture notes live in [`architecture.md`](architecture.md).
Runtime validation instructions live in [`runtime-validation.md`](runtime-validation.md).

## Consumption Boundary

For the RK3588 forward-port runtime test, point `build-armbian-deb.sh` at a
source tree whose checked-out commit already contains patch 0001 with
`KERNEL_TREE=...`. If starting from a pre-Route-B base, apply patch 0001 once in
that source tree first. Do not apply patch 0001 again on top of a Route-B branch.
The build script regenerates a complete Armbian userpatch archive from
`v6.18..HEAD`, minus the script's `SKIP_COMMITS` list for commits already
carried by the Armbian base. It does not consume patch 0001 directly as a
standalone Armbian userpatch.

Patches 0002 and 0003 are not part of the forward-port kernel build. They are
the compatibility rewrite version of the same Route B design and the matching
rewrite attribution surface, and should only be applied when building one of the
rewrite trees.

The local forward-port state recorded on 2026-07-05 has
`rkvenc-fwport-6.18-route-b` as the clean Route-B-only branch at
`2b52e8174c12`. The `rkvenc-fwport-6.18` and
`rkvenc-fwport-6.18-route-b-debug-tip` branches keep temporary diagnostic
commits above Route B. Those diagnostics are useful for one-run fallback
attribution, but they are not part of the publishable Route-B-only branch. If
the installed image contains `driver-owned IOMMU` and
`iommu_dma_get_iova_domain` strings but does not contain
`DIAG rga_dma_map_sgt`, it is a clean Route-B-only image: good for behavioral
testing, but it will not prove the silent fallback path by itself.

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
  dma-buf validation use the same 32-bit guard-band contract. Patch 0003 adds a
  rewrite-only `rk_rga_rewrite/route_b` debugfs directory with `attempt`, `ok`,
  `active`, and `force_remap`; this is development evidence, not userspace ABI.

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

On RK3588, RGA3 debugfs reports `mmu: RK_IOMMU`, while the older RGA2 core
reports `mmu: RGA_MMU`. RGA3 command dumps can still show
`mmu: win0 = 00 win1 = 00 wr = 00`; that is the internal RGA3 command MMU state,
not evidence that the job bypassed the external RK_IOMMU. The programmed
`handle[...] iova` / `dma_addr` values are the device-visible IOVA addresses.

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

Run from this repo. Patch 0003 is layered on top of patch 0002, so check it in
a scratch tree that is already at the post-0002/pre-0003 rewrite state, or
after applying patch 0002 in a temporary checkout:

```bash
git -C ../kernel/linux-6.18-rkvenc-av1-fwport apply --check \
  /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/route-b/0001-media-rockchip-rga3-map-scattered-userptr-through-IOMMU.patch

git -C ../kernel/linux-6.18-rkvenc apply --check \
  /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/route-b/0002-media-rockchip-rga-rewrite-add-Route-B-userptr-mapping.patch
git -C ../kernel/linux-6.18-rkvenc apply --check \
  /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/route-b/0003-media-rockchip-rga-rewrite-add-route-b-debugfs-counters.patch

git -C ../kernel/linux apply --check \
  /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/route-b/0002-media-rockchip-rga-rewrite-add-Route-B-userptr-mapping.patch
git -C ../kernel/linux apply --check \
  /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/route-b/0003-media-rockchip-rga-rewrite-add-route-b-debugfs-counters.patch

../kernel/linux-6.18-rkvenc-av1-fwport/scripts/checkpatch.pl --strict \
  kernel-drivers/patches/route-b/0001-media-rockchip-rga3-map-scattered-userptr-through-IOMMU.patch \
  kernel-drivers/patches/route-b/0002-media-rockchip-rga-rewrite-add-Route-B-userptr-mapping.patch \
  kernel-drivers/patches/route-b/0003-media-rockchip-rga-rewrite-add-route-b-debugfs-counters.patch
```

Status on 2026-07-06:

- Patch 0001 applies to the forward-port tree, patch 0002 applies to both
  rewrite trees, and patch 0003 applies to both rewrite trees at the post-0002
  pre-0003 state.
- Strict checkpatch reports `0 errors, 0 warnings, 0 checks` for the checked
  Route B patches, including patch 0003.
- Focused object builds pass in temp trees after the page-granule and
  overflow-safe span guards; the same focused targets also pass with `W=1`:
  - forward-port: `rga_dma_buf.o`, `rga_mm.o`, `rga_drv.o`
  - rewrite: `rga_rewrite.o`
- A clean Route-B-only forward-port image passed repeated RK3588
  `rga-mmu-debug.sh` smoke runs for `rga_copy_demo`, `rga_resize_rect_demo`, and
  `rga_transform_rotate_demo`.
- The rewrite tips `d1cfb432da7f` (6.18) and `c8a41bb830a6` (mainline) passed
  `kernel-drivers/tests/rewrite-build-gate.sh all` from clean `git archive`
  sources after patch 0003 landed.

The Route-B-only smoke evidence is a behavioral pass and strong indirect
evidence because the same demo family previously failed closed with
non-contiguous `orig_nents == nents` userptr mappings. It is not direct fallback
attribution: the clean image did not include a Route B success breadcrumb. To
claim the forward-port fallback itself is runtime-proven, rebuild the debug-tip
profile or add a temporary counter/print in `rga_dma_map_sgt_iommu()` and
capture at least one passing case that entered the fallback. For the rewrite,
boot a kernel carrying patch 0003 and capture `route_b/attempt`, `route_b/ok`,
and `route_b/active` around the selected cases.
