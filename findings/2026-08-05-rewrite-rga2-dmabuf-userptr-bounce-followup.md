# RGA2 bounce follow-up: reroute incompatible DMA-BUFs and preserve USERPTR page offsets

> Scope: clean-room RGA rewrite and official librga conformance on ROCK 5B
> Source: measured 6.18 `df22eeef8757`, suite run
> `20260805-190822-librga-suite`; fixed 6.18 `571e261b26f79` and mainline
> `5db5ddf046825`; `drivers/video/rockchip/rga-rewrite/rga_rewrite.c`
> `rk_rga_job_map_import()`, `rk_rga_hw_dispatch()`, and
> `rk_rga_hw_probe()`
> Date: 2026-08-05
> Trust: **MEASURED** / **SOURCE-INSPECTED** / **ROOT-CAUSED** /
> **FIX-COMPILE-VERIFIED** / **INFERRED** / **PARTIAL**

## Result

The repaired `df22eeef8757` KASAN package boots and passes the exact 92 MPP +
152 RGA KUnit manifest with live lockdep. Its official MPP suite passes all 12
required cases. The corrected librga wrapper records **21/34 required
cases passing**. This materially narrows the earlier SWIOTLB diagnosis:

- the USERPTR SG-size cap is runtime-confirmed. The prior run emitted 17
  416-KiB, 1-MiB, or 2-MiB SWIOTLB mapping failures; this run emits none of
  those. It emits exactly one 1-MiB line, from
  `rga_allocator_dma_cache_demo` and its plain `/dev/dma_heap/system` DMA-BUF;
- RGA scheduled and dispatched 54 jobs but started only 48. All 11 RGA3 jobs
  started; the six pre-start failures were selected on RGA2. There were no
  IOMMU faults, timeouts, RGA2 config errors, shadow-setup failures, or
  recovery failures;
- USERPTR Route B completed 64/64 import-time mappings. That proves the RGA3
  driver-owned IOVA path, not the later selected-RGA2 mapping, so it did not
  explain the six RGA2 pre-start failures; and
- the maintained smoke passes every IM2D, DMA-BUF, legacy BLIT, fill, and
  rectangle operation before the REQUEST fd-zero sentinel issue already fixed
  in successor `67d4229c3d9ad`.

## DMA-BUF root cause and fix

The generic system heap is allowed to allocate physically contiguous order-8
pages and exports the resulting 1-MiB SG entry unchanged to each attachment.
RGA2 correctly has a 32-bit DMA mask. If that entry lies above 4 GiB, the DMA
layer tries SWIOTLB; this kernel's per-map ceiling is 128 2-KiB slots, or 256
KiB, regardless of the mostly empty 64-MiB pool. The exporter therefore returns
`-EIO` from `dma_buf_map_attachment_unlocked()`.

This is not a reason to change the global system heap for one consumer. Commit
`571e261b26f79` (mainline mirror `5db5ddf046825`) records RGA2 as incompatible
with the current task only when an RGA2 DMA-BUF attachment returns `-EIO`.
Dispatch has not started hardware at that point and has already released the
failed mappings and powered the core off. It revalidates the task with RGA2
excluded and requeues the same queue reference onto an available RGA3 core.
An RGA2-only task, an explicit RGA2 core mask, or the absence of an accepting
RGA3 core leaves the original `-EIO` terminal; the retry cannot convert an
unsupported operation into an apparent success. The exclusion resets when a
multi-task job advances to its next task.

This first retry can still leave one rate-limited SWIOTLB line in dmesg because
the generic DMA-BUF API exposes no mapping attribute through which the importer
can suppress the exporter's failed probe. The important functional distinction
is that the compatible RGA3 execution then succeeds.

## USERPTR root cause and fix

The earlier SG-size fix uses
`sg_alloc_table_from_pages_segment(..., dma_max_mapping_size(dev), ...)`, so an
unaligned first segment is `max_segment - page_offset` bytes long. On RGA2,
high USERPTR pages can be bounced. Without a device minimum-alignment mask,
SWIOTLB may return a page-aligned DMA address and lose the original nonzero page
offset. That first DMA entry consequently ends mid-page; when the next bounced
entry begins elsewhere, `rk_rga2_mmu_append_sgt()` rejects the discontinuity
because RGA2's internal MMU can change physical pages only at a page boundary.
The failure occurs before `rk_rga_hw_start()`, matching the measured
dispatch/start gap. Attribution of each individual failed sample remains
inferred because the old default event mask did not record terminal job
failures.

The fix sets `dma_set_min_align_mask(dev, PAGE_SIZE - 1)` only on RGA2 devices,
matching the newer Rockchip driver's page-granular RGA2-MMU requirement. The
DMA API then reports a 252-KiB SWIOTLB maximum rather than 256 KiB; the existing
SG splitter consumes that value, preserves the page offset, and keeps every
discontinuous entry boundary page-aligned.

The same commit adds evidence for the next boot: per-RGA2 DMA-BUF map-failure
and reroute counters, USERPTR map-attempt/failure/internal-MMU/preparation
counters, and default `job-fail` / `job-reroute` debug events. The conformance
counter gate now forbids positive USERPTR map and MMU-preparation failure
deltas.

## Compile verification

Both maintained tips pass strict checkpatch and the warning-fatal clean-archive
`normal` build, including Rockchip and VSI IOMMU providers, both KUnit-enabled
rewrite objects, and the ROCK 5B DTB. The exact 92/152 manifest is unchanged;
the source audit reports 306 known signals, zero new, and zero absent; and all
tracked rewrite source, Kconfig, ABI, and UAPI files are byte-identical between
the two trees.

## Boundary and verification gate

The new commits are not boot- or runtime-verified. Build, install, and boot an
exact-tip 6.18 KASAN package from `571e261b26f79`, then require:

1. exact 92/152 KUnit with a clean outer interval and live lockdep;
2. 12/12 official MPP and the complete maintained librga smoke;
3. the plain-system-heap allocator demo to pass with a matched positive
   `dmabuf_rga2_map_failure_count` and `dmabuf_rga2_reroute_count`;
4. zero `userptr_rga2_map_failure_count` and
   `userptr_rga2_mmu_prepare_failure_count`, with no terminal USERPTR
   `job-fail` event; and
5. a corrected official librga result reviewed separately for genuine
   unsupported-feature samples.

That boot distinguishes this pinned alignment mechanism from any remaining
USERPTR issue. It does not claim that RGA2-only operations can consume arbitrary
high-memory DMA-BUF exporter layouts; those must use compatible low memory or
fail explicitly.
