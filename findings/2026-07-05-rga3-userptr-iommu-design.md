# RGA3 userptr-IOMMU fallback design: driver-owned contiguous IOVA for scattered userptr

> Scope: forward-port `../kernel/linux-6.18-rkvenc-av1-fwport` RGA3 driver,
> rewrite trees `../kernel/linux-6.18-rkvenc` and `../kernel/linux`, and patch
> artifacts in `kernel-drivers/patches/rga-userptr-iommu/`.
> Source: RGA userptr-IOMMU fallback patch construction, focused object builds, RGA-userptr-IOMMU-only
> `rga-mmu-debug.sh` smoke runs on 2026-07-05, and committed rewrite build gates
> on 2026-07-06.
> Date: 2026-07-05
> Trust: CODE-INSPECTED / BUILD-VERIFIED for the rewrite branches;
> BEHAVIORAL-SMOKE-PASSED for the forward-port; booted rewrite runtime and
> direct forward-port RGA userptr-IOMMU fallback attribution still pending; rewrite
> fallback attribution is now instrumentable but not hardware-run.
> Related: [[2026-07-04-rga3-im2d-error-irq]],
> [[2026-07-05-rga3-memory-import-contract]],
> [[2026-07-05-rga3-scattered-iova-mechanism]]
> Architecture: `kernel-drivers/patches/rga-userptr-iommu/architecture.md`

## Finding

RGA userptr-IOMMU fallback can be implemented without relaxing the RGA3 import contract. Keep
DMA-buf imports fail-closed on "one 32-bit-safe DMA span", but for driver-owned
sg-tables the driver can build its own contiguous IOVA span in the translated RGA
domain. Scattered pinned userptr is the target path.

The final architecture has two deliberately different hook points with the same
mapping semantics:

- **forward-port:** RGA userptr-IOMMU fallback lives in the shared `rga_dma_map_sgt()` helper. That
  covers `virt_addr` userptr imports and the physical-address IOMMU path because
  both are driver-owned sg-tables;
- **rewrite:** RGA userptr-IOMMU fallback is only used for pinned userptr imports and per-job
  userptr remaps. DMA-buf imports and remaps are validated and rejected if they
  are not one 32-bit-safe DMA span. Patch 0002 also sets the RGA3 streaming DMA
  mask, coherent DMA mask, and `bus_dma_limit` guard so normal DMA API placement
  follows the same 32-bit-safe contract before the userptr fallback is considered.

The common RGA userptr-IOMMU fallback flow is:

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
  and subtracts the saved offset during RGA userptr-IOMMU fallback teardown;
- teardown records RGA userptr-IOMMU fallback ownership and uses `iommu_unmap()` plus
  `free_iova_fast()`, never `dma_unmap_sg*()`, for synthetic mappings.
- the forward-port records writable userptr mappings and marks their GUP-held
  pages dirty before dropping the page references.

Because RGA3 consumes one base address rather than a scatterlist, RGA userptr-IOMMU fallback also
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
keeps RGA userptr-IOMMU fallback allocation in the same address space as the DMA API mappings.
RGA userptr-IOMMU fallback fails closed if the device has no translated paging domain or if the
domain has no DMA IOVA cookie.

The same 32-bit-safe guard band stays load-bearing. RGA userptr-IOMMU fallback caps allocations at
the minimum of the device DMA mask, `bus_dma_limit`, any forced domain aperture,
and `DMA_BIT_MASK(32) - SZ_512M`, so a synthetic mapping does not reintroduce
the RGA3 register-wrap fault fixed by the earlier guard-band change. The
validator uses an overflow-checked `base + size - 1` calculation, so oversized
or wrapped spans fail closed before any address is programmed.

Static verification proves that the patches apply, pass style, and build. The
rewrite-side RGA userptr-IOMMU fallback slice is also committed and pushed on both rewrite
branches: `rk3588-rewrite-6.18` @ `d1cfb432da7f` and
`rk3588-rewrite-mainline` @ `c8a41bb830a6`. The RGA-userptr-IOMMU-only forward-port image
also now proves the selected scattered
`virt_addr` demo family can complete on RK3588 hardware without RGA/IOMMU fault
signatures. What remains unproven is direct attribution to the silent fallback:
the clean test image intentionally did not include a success log/counter in
`rga_dma_map_sgt_iommu()`. The rewrite tips now expose
`rk_rga_rewrite/route_b/{attempt,ok,active,force_remap}` so the equivalent
booted hardware run can prove fallback execution directly.

## Runtime smoke after RGA userptr-IOMMU fallback-only build

RGA userptr-IOMMU fallback strings were present in the installed image:

```text
driver-owned IOMMU
iommu_dma_get_iova_domain
```

The temporary diagnostic string was absent:

```text
DIAG rga_dma_map_sgt
```

So the booted image was the clean RGA-userptr-IOMMU-only profile, not the debug-tip profile
with fallback breadcrumbs.

Repeated runs under
`../rockchip-conformance/logs/rga-mmu-debug/20260705-182754` through
`../rockchip-conformance/logs/rga-mmu-debug/20260705-182808` all reported `pass`
for:

- `rga_copy_demo`
- `rga_resize_rect_demo`
- `rga_transform_rotate_demo`

The filtered dmesg in those runs contained no `DIAG rga_dma_map_sgt`, no
`reject sg_table DMA mapping`, no `INTR[0x2]`, no IOMMU page fault, and no RGA
`finished N failed M` fault where `M > 0`.

This is strong indirect RGA userptr-IOMMU fallback evidence because the earlier debug run at
`../rockchip-conformance/logs/rga-mmu-debug/20260705-151723` showed the same
demo family fail closed with non-contiguous userptr imports:

```text
orig_nents=895 nents=895 contiguous=0 gaps=894 ... reject sg_table DMA mapping
orig_nents=386 nents=386 contiguous=0 gaps=9   ... reject sg_table DMA mapping
orig_nents=367 nents=367 contiguous=0 gaps=306 ... reject sg_table DMA mapping
orig_nents=492 nents=492 contiguous=0 gaps=68  ... reject sg_table DMA mapping
orig_nents=390 nents=390 contiguous=0 gaps=367 ... reject sg_table DMA mapping
orig_nents=389 nents=389 contiguous=0 gaps=36  ... reject sg_table DMA mapping
```

The exact fallback execution count is still unknown from the clean-image logs.
To make the fallback itself runtime-proven, rebuild the debug-tip profile or add
a temporary positive breadcrumb/counter in `rga_dma_map_sgt_iommu()` and capture
a passing selected case that entered RGA userptr-IOMMU fallback.

## IOMMU notes from bring-up

RK3588 RGA3 uses the external Rockchip IOMMU. Debugfs identifies the RGA3 cores
as `mmu: RK_IOMMU`, while the older RGA2 core is `mmu: RGA_MMU`.

The RGA3 command dumps can still show:

```text
mmu: win0 = 00 win1 = 00 wr = 00
```

That line is the internal RGA3 command MMU bitfield and is expected to be zero
when RGA3 uses the external RK_IOMMU. It is not evidence that the command uses
physical addresses. The `handle[...] iova = ... dma_addr = ...` lines are the
device-visible IOVA values that the command path programs.

## Verification

Patch artifacts:

- `kernel-drivers/patches/rga-userptr-iommu/0001-media-rockchip-rga3-map-scattered-userptr-through-IOMMU.patch`
- `kernel-drivers/patches/rga-userptr-iommu/0002-media-rockchip-rga-rewrite-add-userptr-IOMMU-mapping.patch`
- `kernel-drivers/patches/rga-userptr-iommu/0003-media-rockchip-rga-rewrite-add-userptr-IOMMU-debugfs-counters.patch`

Verification on 2026-07-05:

- `git apply --check` passes against the forward-port tree for patch 0001.
- `git apply --check` passes against both rewrite trees for patch 0002.
- strict checkpatch is clean for both patches.
- focused object builds pass for the touched forward-port RGA3 objects and the
  rewrite `rga_rewrite.o`, including the page-granule and overflow-safe span
  guards; the same focused targets also pass with `W=1`.

Rewrite integration on 2026-07-06:

- patch 0002 is committed and pushed as `media: rockchip: map RGA userptr
  through IOMMU`;
- patch 0003 is committed as `media: rockchip: rga-rewrite: count RGA userptr-IOMMU fallback
  fallback mappings`;
- 6.18 branch: `d1cfb432da7f` on `yisding/linux-rock5b/rk3588-rewrite-6.18`;
- mainline branch: `c8a41bb830a6` on
  `yisding/linux-rock5b/rk3588-rewrite-mainline`;
- pre-commit clean-archive builds of the dirty patch passed for
  `rga_rewrite.o` on both target kernels with no warning lines;
- committed-tip `kernel-drivers/tests/rewrite-build-gate.sh all` passed from
  git-archive sources for both kernels, building the KUnit-enabled
  `mpp_rewrite.o` and `rga_rewrite.o` targets.

The runbook is `kernel-drivers/patches/rga-userptr-iommu/runtime-validation.md`. The
forward-port has a behavioral smoke pass. Until a RGA userptr-IOMMU fallback breadcrumb/counter is
captured, the forward-port finding is "behavioral smoke passed; direct fallback
attribution pending", not a fully runtime-proven fallback. The rewrite finding
is "committed, build-verified, and attribution-instrumented; booted hardware
validation pending".
