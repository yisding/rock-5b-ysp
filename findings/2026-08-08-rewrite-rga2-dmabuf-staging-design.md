# Rewrite RGA2 DMA-BUF staging design for exporter SG entries larger than SWIOTLB

> Scope: clean-room RGA rewrite, specifically the remaining RGA2-only and
> explicitly RGA2-pinned high-memory DMA-BUF gap
> Source: rewrite tree `rk3588-rewrite-6.18@7d1ba613d589` inspected at
> `drivers/video/rockchip/rga-rewrite/rga_rewrite.c`
> `rk_rga_job_map_import()` / `rk_rga_hw_dispatch()`; forward-port comparison
> at `rk3588-video-6.18@b54ba6079824b` `rga_mm_get_rga2_sgt()`; measured
> mechanism in [`2026-08-05-rewrite-rga2-dmabuf-userptr-bounce-followup.md`](2026-08-05-rewrite-rga2-dmabuf-userptr-bounce-followup.md)
> Date: 2026-08-08
> Trust: **DESIGN** / **SOURCE-INSPECTED** / **UNVERIFIED**

## Result

The rewrite already handles the common case correctly: when an RGA2
DMA-BUF attachment returns `-EIO` because an exporter-owned SG entry is larger
than SWIOTLB's per-map ceiling, dispatch excludes RGA2 and retries a compatible
task on RGA3. It deliberately leaves RGA2-only operations, explicit RGA2 core
masks, and systems without an accepting RGA3 core terminal. The rewrite source
tree is currently undergoing a separate RGA active-slot ownership refactor, so
this finding records the next change without modifying that tree.

The remaining design is a bounded, job-owned DMA32 staging fallback after the
existing RGA3 reroute is unavailable:

1. Enter staging only for a CPU-accessible DMA-BUF whose RGA2 attachment failed
   with the exact size-limit signal, `-EIO`. Do not stage raw physical addresses,
   secure/non-vmap exporters, arbitrary mapping failures, or buffers larger than
   the documented staging cap.
2. Allocate below-4-GiB pages owned by the RGA job, construct an SG table whose
   source entries are no larger than one page, and DMA-map it against the
   selected RGA2 device. A failure at any step remains a clean pre-hardware
   error.
3. Canonicalize staging by DMA-BUF identity for the whole job, not by channel.
   All planes and tasks which alias one DMA-BUF must share one staging object so
   an earlier task's output is visible to a later task's input.
4. Before hardware start, bracket the exporter mapping with
   `dma_buf_begin_cpu_access()` / `dma_buf_vmap()` /
   `dma_buf_end_cpu_access()`, copy the origin into staging, and synchronize the
   staging SG for RGA2. Copy-in is required even for destinations because RGA
   operations can preserve pixels outside their write rectangle.
5. Mark the shared object dirty if any destination references it. Only after a
   successful, quiesced hardware completion, synchronize staging for the CPU,
   copy the whole staged extent back through the same DMA-BUF CPU-access
   protocol, and only then signal completion fences. Timeout, reset, cancel,
   preparation failure, or interrupt error discards staged output.
6. Keep the staging object alive until its last plane/task reference drops.
   Teardown must unmap the RGA2 SG, remove the object from the job registry,
   release its DMA-BUF reference and vmap, and free every DMA32 page on all
   success and unwind paths.
7. Expose attempts, successes, active objects/bytes, peak bytes, copy-in bytes,
   copy-out bytes, and failures in the rewrite debugfs counters. Rate-limit the
   expected first `-EIO` diagnostic.

This staging path complements rather than replaces the existing USERPTR fix.
USERPTR pages are importer-owned and can be split before DMA mapping; a
DMA-BUF importer's attachment table is exporter-owned and cannot be legally
rewritten in place. Staging is therefore a different repair for the same
256-KiB SWIOTLB per-entry constraint.

## Verification gate

Implementation is not complete until the rewrite passes all of the following:

- KUnit allocation-failure coverage at every page/SG/map/vmap/copy step, with
  zero active staging objects and bytes after each unwind;
- source and KUnit checks that one DMA-BUF used by multiple planes/tasks maps
  to one staging object and copies back once;
- source-only, destination-only, read-modify-write, and partial-rectangle tests;
- timeout, reset, cancel, and interrupt-error tests proving no copy-back and no
  success fence before teardown;
- a forced-RGA2 high system-heap reproducer that previously emitted the 1-MiB
  SWIOTLB failure, plus the official RGA2-only librga cases; and
- KASAN/lockdep conformance with staging counters returning to zero and no new
  IOMMU, SWIOTLB, warning, or recovery signatures.

## Boundary

This is an implementation finding, not proof that the rewrite has the
fallback. No rewrite source was changed, compiled, packaged, or booted for this
record. CPU-inaccessible/secure exporters and buffers beyond the staging cap
remain intentionally unsupported on RGA2 and must use RGA3 or fail explicitly.
