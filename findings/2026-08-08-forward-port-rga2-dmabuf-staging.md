# Forward port stages exporter-owned high DMA-BUFs for RGA2-only work

> Scope: RK3588 6.18 forward-port RGA scheduler and RGA2 DMA-BUF mapping
> Source: `rk3588-video-6.18@65f5b67940a79`, patch `0094`;
> `drivers/video/rockchip/rga3/rga_job.c` `rga_job_judgment_support_core()` /
> `rga_job_alloc()`, `rga_policy.c` `rga_job_assign()`, and `rga_mm.c`
> `rga_mm_get_rga2_sgt()` / `rga2_stage_get()` / `rga2_stage_put()`
> Date: 2026-08-08
> Trust: **CODE-INSPECTED** / **FIX-COMPILE-VERIFIED** / **PARTIAL**

## Result

Patch `0094` closes the forward port's remaining source-level response to the
exporter-owned SG form of the RGA2/SWIOTLB limit. The generic system DMA heap
may export a physically contiguous 1 MiB entry above 4 GiB. Unlike the
driver-owned USERPTR table repaired by `0093`, an importer cannot split that
DMA-BUF attachment table before `dma_buf_map_attachment_unlocked()` asks
SWIOTLB to map it. The selected 32-bit RGA2 device can therefore receive
`-EIO` even though the total SWIOTLB pool is mostly empty.

The forward port now distinguishes three cases during handle scheduling:

- below-4-GiB or otherwise directly servable memory remains direct;
- high DMA-BUFs are marked stageable, and a compatible RGA3 core is preferred
  so the normal zero-copy IOMMU path remains first choice; and
- raw high physical memory remains unsupported because no exporter authorizes
  CPU access or owns a copy lifetime.

When a task is RGA2-only or explicitly pins RGA2, only an exact RGA2 DMA-BUF
mapping `-EIO` enables staging. Other mapping errors retain their existing
fail-closed behavior. Direct-fd jobs keep a normal IOMMU-backed attachment
alive after the failed RGA2 probe; imported handles remember the incompatibility
so they do not repeat the doomed attachment on later jobs.

The staging object has these ownership rules:

- it belongs to one RGA job and is keyed by `struct dma_buf *`, so every plane
  and task alias of one DMA-BUF shares one object;
- the total staged DMA-BUF size per job is capped at 64 MiB;
- it owns individually allocated `GFP_DMA32` pages, a page-segmented SG table,
  the selected-RGA2 DMA mapping, a staging vmap, and a DMA-BUF reference;
- it copies the complete DMA-BUF into staging through the exporter CPU-access
  and vmap APIs before hardware starts, preserving partial-rectangle and
  read-modify-write behavior;
- it copies back once if any destination used the object, and only after the
  job has completed every task without timeout, reset, cancel, interrupt error,
  or other terminal failure; and
- its last plane/task reference unmaps and frees every owned resource. A
  residual object at `rga_job_free()` emits a warning rather than becoming a
  silent leak.

`/sys/kernel/debug/rkrga/` now exports the human-readable `rga2_stage` summary
and numeric attempt, success, failure, reuse, active object/byte, peak byte,
copy-in byte, and copy-out byte files. The generic `active` counter aliases the
active object count so the existing librga zero-after counter gate can detect a
staging leak. The librga suite now snapshots the forward-port debugfs root as
well as the rewrite root.

## Compile verification

The exported commit passes strict patch-only `checkpatch.pl` with zero errors,
warnings, or checks. A clean disposable source clone, configured from the
forward-port production `.config`, compiled the complete
`drivers/video/rockchip/rga3/` directory with arm64 GCC, central ccache, and
`WERROR=1`; all driver objects and `built-in.a` linked successfully. The final
object hashes are:

- `rga_mm.o`: `035df3b0a6e23ef175416f0278a03e80703650ee5d6aaa19a5e69773b95673b7`
- `rga3/built-in.a`: `0d32472c7a67aba737ad9b8927561a78efc394bb1fa5c2a051d3b498afb540a5`

The build state is retained under
`../rock-5b/build/forward-port-0094-rga2-stage/` and is disposable.

## Verification gate

Build and package the exact `0001`–`0094` series, install it with a recovery
kernel retained, and boot the matching YSP DTB. First require the original
three RGA2-only USERPTR failures to pass, proving `0093`. Then run the plain
system-heap DMA-BUF allocator sample and at least one forced-RGA2 partial write,
requiring correct output plus positive staging attempt/success/copy counters,
zero staging failures, and zero active objects/bytes after completion. Repeat
with one DMA-BUF aliased across planes or consecutive tasks and require a
positive reuse counter with one copy-back.

Finally rerun the complete production conformance matrix and a KASAN/lockdep
profile. Timeout/reset/cancel fault injection must leave output uncopied,
completion fences failed, staging active counts at zero, and no new SWIOTLB,
IOMMU, warning, oops, or recovery signature.

## Boundary

This change is source-, style-, and compile-verified only. It is not packaged,
installed, booted, or runtime-verified. CPU-inaccessible/secure exporters,
DMA-BUFs that would exceed the 64 MiB per-job cap, raw high physical memory,
and non-`-EIO` mapping failures remain deliberately unsupported on RGA2. The
separate rewrite implementation remains untouched; its proposed equivalent is
recorded in
[`2026-08-08-rewrite-rga2-dmabuf-staging-design.md`](2026-08-08-rewrite-rga2-dmabuf-staging-design.md).
