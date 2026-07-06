# Why RGA3 userptr imports get non-contiguous IOVAs: per-segment mapping, not the guard band

> Scope: forward-port kernel `../kernel/linux-6.18-rkvenc-av1-fwport`
> branch `rkvenc-fwport-6.18`, RGA3 DMA import path
> `drivers/video/rockchip/rga3/rga_dma_buf.c` + `rga_mm.c`, the generic
> `drivers/iommu/dma-iommu.c`, and the RK3588 device tree.
> Source: temporary map-site DIAG (`eb0f3e209007` + fixups `30102c8f769e`,
> `171de4153e97`) run on `6.18.38-current-rockchip64 #13`
> (`../rockchip-conformance/logs/rga-mmu-debug/20260705-151723`), plus
> code / kernel-config / DT inspection; post-Route-B Route-B-only smoke runs
> `20260705-182754` through `20260705-182808`.
> Date: 2026-07-05
> Trust: MEASURED for the IOVA-address fingerprint and guard-band clustering;
> CODE-INSPECTED for the coalescing path, RGA3 coherency, and the bounce config;
> the exact per-segment *trigger* is UNRESOLVED (leading hypothesis only, twice
> mis-predicted from static reading — hardware is ground truth here).
> Related: [[2026-07-04-rga3-im2d-error-irq]], [[2026-07-05-rga3-memory-import-contract]]

## The question

An IOMMU's whole job is to remap scattered physical pages into one contiguous
device-visible (IOVA) span, and that is cheap. `iommu_dma_map_sg()`'s normal path
does exactly that: allocate **one** IOVA range for the whole buffer and map every
page into it. So why does the forward-port keep handing RGA3 a *non-contiguous*
mapping for scattered `virt_addr` imports (the `contiguous=0` result in
[[2026-07-04-rga3-im2d-error-irq]]), forcing the fail-closed reject? And is the
512 MB IOVA guard band (`6b9dba7abcd0`) responsible?

## The 512 MB guard band is NOT the cause

`6b9dba7abcd0` lowers the RGA mapping device's `bus_dma_limit` to ~`0xE0000000`
(512 MB below the 4 GB line) so an IOVA base plus RGA's 32-bit plane/stride
arithmetic cannot wrap past `0xFFFFFFFF`. It bounds *where* IOVAs are allocated,
not *whether* scattered pages are coalesced — those are independent mechanisms.

Two facts prove it is not the culprit:

- **Same device, same guard band, fragmentation still varies.** In one run the
  DIAG shows both a nearly-contiguous mapping and a fully-scattered one (below).
  A ceiling that caused scattering would scatter both the same way.
- **There is ample contiguous room.** A 3.6 MB buffer needs ~900 pages of IOVA; the
  aperture below `0xE0000000` is ~3.5 GB.

What the guard band *does* explain: every observed IOVA is `0xdf……010`, i.e. packed
just under the `0xE0000000` ceiling by the top-down IOVA allocator. That is the
guard band working as intended. Removing it would only move the cluster up under
`0xFFFFFFFF` and reintroduce the 32-bit wrap fault — so it must stay.

## The fingerprint: descending IOVAs ⟹ per-segment mapping, not the coalescer

Representative DIAG lines (`#13`, run `20260705-151723`):

```text
orig_nents=895 contiguous=0 gaps=894 first=0xdffff010 span=0xffffffffffc7a000 end=0xdfc7900f
orig_nents=386 contiguous=0 gaps=9   first=0xdfd04010 span=0x17c000           end=0xdfe8000f
```

The decisive tell is the first line: `end < first` (the huge `span=0xffffffff…` is a
negative wrap), i.e. the last segment ends **below** where the first begins — the
IOVA addresses run **backwards**, with a gap at essentially every segment
(`gaps=894` of 895).

The generic coalescing path *cannot* produce that. `iommu_dma_map_sg()`'s normal
path allocates one IOVA (`dma-iommu.c` `iommu_dma_alloc_iova`, ~`:1483`), maps the
whole scatterlist into it (`iommu_map_sg`, ~`:1493`), and `__finalise_sg`
(~`:1312`, `:1316`) assigns segment addresses that only ever **increment** from the
allocation base. Ascending, contiguous, `gaps=0`. Backwards addresses are therefore
proof that those buffers did **not** go through the coalescer — each segment got its
own IOVA, handed out top-down, one at a time. The non-contiguity is not "the IOMMU
can't"; it is "a per-segment mapping path ran instead of the coalescing one."

The `gaps=9` line is the same device producing a much less fragmented mapping,
but it is still not the ideal coalesced `gaps=0` case. The point is narrower:
the guard band does not force uniform fragmentation, and mapping behavior varies
buffer-by-buffer.

## Confirmed machinery and unresolved trigger

The stock per-segment path in `iommu_dma_map_sg()` is the swiotlb branch
(`dev_use_sg_swiotlb()` → `iommu_dma_map_sg_swiotlb()`, `dma-iommu.c:1409`),
which maps each segment independently. Two enabling facts for that path are
confirmed:

- **RGA3 is non-coherent.** Its DT node `rga@fdb60000` (`compatible =
  "rockchip,rga3_core0"`, `rk3588-base.dtsi`) has **no** `dma-coherent` property.
- **This kernel bounces unaligned kmalloc DMA.** `/boot/config-6.18.38-current-rockchip64`
  has `CONFIG_SWIOTLB=y` and `CONFIG_DMA_BOUNCE_UNALIGNED_KMALLOC=y`, and
  `dma_kmalloc_safe()` (`include/linux/dma-map-ops.h:262`) returns *false* precisely
  for a **non-coherent device on a non-`DMA_TO_DEVICE` mapping** (read-back). So a
  source buffer (`DMA_TO_DEVICE`) is always "safe" for the normal path, while a
  destination/read-back buffer is the one eligible to be diverted. That direction
  split is a plausible match for the more-fragmented-vs-less-fragmented split
  seen in the data.

## What is NOT pinned (honest boundary)

The stock bounce trigger should *not* actually fire for these buffers: after
`dma_kmalloc_safe()` returns false, `dev_use_sg_swiotlb()` still only bounces if
some segment length is unaligned, and `dma_kmalloc_size_aligned()`
(`include/linux/dma-map-ops.h:287`) returns true for any `size >= 2 *
ARCH_DMA_MINALIGN` (= 256 on arm64, `arch/arm64/include/asm/cache.h:35`). Every
userptr segment here is ≥ 4 KB, so the stock path would compute "no bounce."

Yet the hardware shows a per-segment mapping. So either the heavily-modified
forward-port `dma-iommu.c` (≈890 insertions vs mainline) takes a Rockchip-specific
per-segment path, or there is a bounce trigger not visible in the stock reading.
This was mis-predicted twice from static analysis (first "it will be contiguous,"
then "it is the kmalloc bounce"), so the mechanism is labeled **leading hypothesis,
not conclusion**. It is not load-bearing for the decision: `contiguous=0` is
measured, so the fail-closed reject is correct regardless of *why* the coalescer was
skipped. If it ever needs nailing, one more DIAG field — the `dir` argument plus
which `iommu_dma_map_sg()` branch ran — settles it in one reflash.

## Implications for Route B

Route B (driver-owned `iommu_map_sg()` into a translated RGA domain) is exactly the
"cheap contiguous remap" this whole question is about — the driver does by hand what
the coalescer does for the contiguous buffers, so it works regardless of why the
generic path scatters some of them. Two constraints fall directly out of the facts
above:

1. **Non-coherent ⟹ Route B must do explicit cache maintenance**
   (`dma_sync_sg_for_device()` before the job, `dma_sync_sg_for_cpu()` after).
   Whatever diverts the scattered buffers today is silently providing read-back
   coherency; a direct mapping will not. Skipping this yields correct addresses but
   stale/corrupt pixel data — this is why the Route B sketch in
   [[2026-07-04-rga3-im2d-error-irq]] lists `dma_sync_sg_*` explicitly.
   The candidate Route B patches keep cache maintenance on the original
   physical sg-table: the forward-port syncs through the same `map_dev` used for
   the mapping, and the rewrite's userptr sync hooks continue to wrap submission
   and completion.
2. **Keep the 32-bit-safe placement.** Route B's own IOVA allocation must stay below
   the ~`0xE0000000` guard ceiling (or otherwise guarantee base + RGA plane offsets
   do not cross `0xFFFFFFFF`), or the wrap fault `6b9dba7abcd0` fixed comes back.

## Post-Route-B smoke comparison

The Route-B-only 6.18 image installed for the 18:28 runs contained the clean
Route B strings (`driver-owned IOMMU`, `iommu_dma_get_iova_domain`) and did not
contain the temporary `DIAG rga_dma_map_sgt` string. Repeated runs at
`../rockchip-conformance/logs/rga-mmu-debug/20260705-182754` through
`../rockchip-conformance/logs/rga-mmu-debug/20260705-182808` reported `pass` for
`rga_copy_demo`, `rga_resize_rect_demo`, and `rga_transform_rotate_demo`.

The filtered logs for those Route-B-only runs contained no `reject sg_table DMA
mapping`, no `INTR[0x2]`, no IOMMU page fault, and no failed RGA jobs. That is a
behavioral regression pass for the scattered userptr demo family that previously
hit the fail-closed rejects documented above.

This does not invalidate the mechanism boundary in this finding. The exact
reason the generic DMA path returned per-segment IOVAs remains unresolved, and
the clean Route-B-only logs cannot directly prove which import entered
`rga_dma_map_sgt_iommu()`. What the comparison does prove is that the selected
demo family moved from measured non-contiguous userptr rejects to fault-free
completion under a kernel that contains Route B.
