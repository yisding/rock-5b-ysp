# Scope: RGA2 page-table DMA ownership (0050) and DMA-API over-4G path (0051)

> **2026-07-21 renumbering:** this scope originally reserved `0049`/`0050`;
> `0049` was taken by the 10-bit UV plane-offset fix
> (`a398364aaf8ed`), so the planned patches here are now `0050`/`0051`.
> A third small item joined the queue: `dma_set_max_seg_size()` for the RGA
> devices (DMA-debug flags 96 KiB CMA segments against the rga2 device's
> 64 KiB default); it can ride with `0050` since both touch RGA2 DMA setup.

> **2026-07-21 implemented:** `0050@473903525009a` and `0051@13c503286f6e2`
> are committed on `rkvenc-fwport-6.18` per this scope, checkpatch-clean,
> and native-compiled. Deviations from the plan as written: `0050` carries
> the DMA device parameters (`dma_set_max_seg_size`, and
> `dma_set_min_align_mask(PAGE_SIZE - 1)` so swiotlb bounces stay
> page-aligned for the MMU); `0051` folds B1 and B2 into one patch and also
> covers the per-job (non-handle) path, whose buffers were already mapped
> against the executing RGA2 device — they just needed the page-granular
> mapping contract (multi-segment allowed, per-segment 32-bit span checks)
> and the dormant `use_dma_address` fill branch. Transient handle bounces
> post-clean the origin pages through their persistent mapping so a later
> cache invalidate cannot discard copied-back data (a raw sync, not the
> shadow-aware helper, which would overwrite device output). The gates
> below remain the booted verification plan.

> **2026-07-21 booted gates on `P9636-C4ad2` (BOOT-VERIFIED, one defect
> found and fixed):**
>
> - **`0050` PASSES.** Full librga smoke (28 ok / 0 fail, 10-bit cases
>   included) with the kernel journal completely clean across the whole
>   window: the July 20 `rga_dma_sync_flush_range` DMA-debug splat and the
>   July 21 `mapping sg segment longer than device claims to support`
>   warning are both gone, no KASAN, no other DMA-API output. ABI replay
>   (`abi_status=0 clean=1`), the 12-case MPP matrix, and the 24-case
>   FFmpeg suite (14 required + 10 diagnostic, all pass) are green on the
>   same boot.
> - **`0051` half-passed and exposed a copy-back defect.** The inverted
>   `0047` probe (64×64 RGBA imcopy from `/dev/dma_heap/system`, RGA2-only
>   by the 68 px RGA3 width floor) now *runs* on RGA2 — `EOPNOTSUPP` gone,
>   DMA-debug clean — but the destination read back stale zeros even with
>   proper `DMA_BUF_IOCTL_SYNC` brackets (a 256×256 control, which lands
>   on RGA3, was content-exact). Root cause: the transient-bounce
>   post-clean in `rga_mm_put_rga2_bounce()` was guarded with
>   `!origin->dma_buffer->iommu_mapped`, which excludes exactly the normal
>   case — handles import against the RGA3 *default map core*, which is
>   IOMMU-backed — so the swiotlb copy-back stayed dirty in CPU cache and
>   the subsequent `rga_mm_put_buffer()` `sync_for_cpu` invalidate
>   discarded it. Fixed by keying the post-clean on the bounce direction
>   instead (`bounce->dir != DMA_TO_DEVICE`; read-only bounces have
>   nothing copied back); `0051` (originally `34a1d970da1c5`, the hash
>   the `P9636` build carries) amended to `13c503286f6e2`,
>   checkpatch-clean, native-compiled. The content-exact gate re-runs on
>   the next debug build.

> Scope: forward-port `rkvenc-fwport-6.18` RGA3 driver, RGA2 (`RGA_MMU`) core
> paths in `rga_iommu.c`, `rga_mm.c`, `rga_dma_buf.c`, `rga_policy.c`.
>
> Source: code inspection at tip `8e641bcd48a38` plus the measured behavior in
> [`2026-07-20-rga2-unmapped-page-table-dma-sync.md`](./2026-07-20-rga2-unmapped-page-table-dma-sync.md)
> and
> [`2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md`](./2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md);
> upstream `v6.18` `drivers/media/platform/rockchip/rga` and the rewrite
> driver's per-core mask pattern as reference models.
>
> Date: 2026-07-21
>
> Trust: **DESIGN** (this is an implementation plan); the supporting facts are
> **CODE-INSPECTED**.

## Established facts the scope rests on

1. **The RGA2 4G limit is hardware, not driver conservatism.** RGA2 MMU page
   table entries are raw 32-bit byte physical page addresses:
   `page_table[i] = (uint32_t)(Address + (i << PAGE_SHIFT))`
   (`rga_mm.c:1471`). Pages above 4G are inexpressible; serving high buffers
   on RGA2 requires below-4G copies (swiotlb bounce or equivalent).
2. **The DMA-ownership bug is confined to the page-table metadata path.**
   `rga_dma_sync_flush_range()` calls
   `dma_sync_single_for_device(scheduler->dev, virt_to_phys(pstart), ...)`
   on memory that was never DMA-mapped (`rga_dma_buf.c:574`) — the exact
   DMA-debug splat from July 20. The tables themselves come from two
   allocators, both `GFP_DMA32` (so the value programmed into the register
   fits; only the mapping/sync discipline is illegal):
   - the shared ring `rga_drvdata->mmu_base` (`rga_mmu_base_init()`, created
     in the `RGA_MMU` branch of the iommu bind loop where the RGA2
     `scheduler->dev` is in hand), used by non-handle jobs;
   - per-job `GFP_DMA32` pages for `RGA_JOB_USE_HANDLE` jobs
     (`rga_mm.c` handle path).
3. **The vendor fill already anticipates DMA addresses.**
   `rga_mm_sgt_to_page_table(sg, table, count, use_dma_address)` has a
   `use_dma_address` branch whose comment explicitly describes swiotlb
   producing device-compatible addresses — but every RGA2 handle-path call
   passes `false` (`sg_phys()`), and dma-buf imports are mapped against the
   *default mapping core* (RGA3 core0, 40-bit mask + IOMMU), so nothing ever
   bounces for RGA2's benefit.
4. **Per-device masks are already set correctly** (`rga_drv.c:1529`): RGA3
   cores get 40-bit/32-bit-coherent behind the IOMMU, RGA2 gets 32/32. The
   upstream V4L2 driver (`dma_set_mask_and_coherent(32)` + vb2 against that
   device + `lower_32_bits(sg_dma_address)`) and the rewrite driver
   (per-core 40/32 masks, `GFP_DMA32` shadows, DMA-API mapping per core) both
   get bounce-or-place-below-4G behavior from the DMA API for free.

## Patch 0050 — RGA2 page-table DMA ownership (closes the July 20 finding)

Make the page-table memory a properly owned streaming DMA buffer of the RGA2
device:

- Extend `struct rga_mmu_base` with the owning device and a retained
  `dma_addr`; after `rga_mmu_base_init()` in the `RGA_MMU` bind branch,
  `dma_map_single(scheduler->dev, buf_virtual, ring_bytes, DMA_TO_DEVICE)`
  once, and unmap in teardown.
- Ring path (`rga_set_mmu_base()`): program
  `mmu_base->dma_addr + (page_table - buf_virtual)` instead of
  `virt_to_phys(page_table)`, and replace `rga_dma_sync_flush_range()` with
  `dma_sync_single_for_device()` on the mapped range. The device never
  writes the tables, so `DMA_TO_DEVICE` sync-for-device after each CPU fill
  is sufficient.
- Handle path: `dma_map_single()` the per-job table after it is filled
  (mapping itself performs the initial flush), retain the dma address in the
  job buffer struct for register programming, unmap at job cleanup.
- No address values change (RGA2 has no IOMMU; `GFP_DMA32` keeps everything
  below 4G) — this legalizes the lifetime/sync discipline, so DMA-debug
  stops flagging and the sync actually covers the right cachelines on any
  future kernel where `virt_to_phys` ≠ dma address.

**Gate:** rerun the July 20 direct dma-buf smoke on a KASAN/DMA-debug boot —
the `rga_dma_sync_flush_range` splat must be gone with the full smoke still
green and kernel scans clean.

**Risk:** low; mechanical ownership fix confined to RGA2 table metadata.

## Patch 0051 — RGA2 over-4G jobs via DMA-API mapping (staged, opt-in path)

Adopt the upstream model for RGA2 *data* memory instead of rejecting >4G:

- **B1 — dma-buf handle imports:** when a job lands on the RGA2 core and the
  buffer lacks `RGA_MEM_UNDER_4G`, create a transient per-job attachment and
  `dma_buf_map_attachment()` against the RGA2 `scheduler->dev` (32-bit mask
  → the exporter/DMA API places or swiotlb-bounces below 4G), fill PTEs via
  the existing `use_dma_address = true` branch, and bracket the job with
  `dma_sync_sgtable_for_device()/for_cpu()` so bounce copies stay coherent.
  Transient (not cached) mapping is deliberate: a persistent RGA2 mapping
  would pin a bounce copy for the buffer-handle cache's whole lifetime.
- **B2 — virtual/userptr jobs:** same treatment after page pinning
  (`dma_map_sgtable()` on the RGA2 device instead of consuming raw
  `sg_phys()`).
- **Policy interaction:** with 0051, `RGA_JOB_UNSUPPORT_RGA_MMU` is no
  longer set purely from the phys range for mappable buffer types; RGA2
  stays a candidate and a mapping failure at commit time falls back to the
  `0047` `EOPNOTSUPP` + explanatory log.

**Costs and risks (why this is staged and kept opt-in-shaped):**

- swiotlb's default pool is 64 MiB; video-sized buffers can exhaust it under
  concurrency, so map-failure fallback to `EOPNOTSUPP` must stay.
- A bounce is a full CPU copy per direction per job — often more expensive
  than the blit. Below-4G allocation (CMA/dma32) remains the documented fast
  path; 0051 is a correctness/compatibility net, not a performance feature.
- dma-buf bounce coherence depends on the exporter syncing attachments in
  its `begin/end_cpu_access`; the system heap does. Heaps that skip
  attachment syncs would need the explicit per-job `dma_sync_sgtable_*`
  brackets, which B1 includes anyway.

**Gate:** the `0047` probe scenario inverted — a 64×64 RGBA imcopy from the
`system` heap on a >4G allocation must now run on RGA2 and verify
content-exact, with DMA-debug clean; the smoke and MPP/FFmpeg suites stay
green; and with an artificially exhausted bounce pool the job must fail
`EOPNOTSUPP`, not corrupt.

**Ordering:** 0050 lands first (0051's sync brackets assume the table path
is already legal), then B1, then B2. The alternative — porting the vendor
dma32 heaps — remains rejected for now per the 2026-07-21 decision; it only
helps heap-name-hardcoding userspace and adds no capability beyond what the
DMA API provides here.
