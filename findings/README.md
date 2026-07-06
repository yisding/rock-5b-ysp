# findings/ — raw capture inbox

Low-ceremony landing zone for a technical fact you or an agent just learned while
reading code in one of the `../` source trees. **Drop first, sort later.** The bar
to add a file here is deliberately low: one fact, dated, with where it came from.

This is the write path that the polished per-project `docs/` do **not** offer —
depositing into a package doc means editing an index table and matching house
style, so hard-won detail gets re-derived instead of written down. Here you just
add a file.

## How to deposit

1. Copy [`TEMPLATE.md`](TEMPLATE.md) to `YYYY-MM-DD-<short-slug>.md`.
2. Fill the header (scope, source anchor, date, trust tag) and write the fact.
3. Add one line to the index below. That's it — no other file needs editing.

Trust tags (state how sure you are): **MEASURED** (observed on hardware / in a
run), **HYPOTHESIS** (reasoned but unverified), **UNVERIFIED** (copied from a
comment/commit, not checked).

## Lifecycle

A finding is raw by default. When it matures into durable reference, **graduate**
it: move the content into the owning project's `docs/`, and replace the file here
with a one-line tombstone (`promoted → <path> (YYYY-MM-DD)`) so the trail survives.
Findings that turn out wrong get deleted with a one-line note in the index.

**Boundary vs [`status.md`](../status.md) watchlist:** the watchlist tracks
*facts that go stale silently* (external PRs, distro versions, dev-box SPOFs).
`findings/` holds *newly-learned technical detail*. A finding with a follow-up
action belongs here; a stale-risk to re-check on every maintenance pass belongs
in the watchlist.

## Index (newest first)

Each row: `` `YYYY-MM-DD-slug.md` `` — one-line summary — trust tag.

- `` `2026-07-05-rkvenc-rcb-sram.md` `` — RK3588 RKVENC has real RCB descriptor plumbing in userspace, the 6.1 BSP driver, and the 7.2 rewrite, but neither studied RK3588 DT wires encoder `rockchip,sram`/`rockchip,rcb-iova`; decoder RCB SRAM is wired, encoder RCB is optional/dormant, so the forward-port must treat missing encoder RCB backing as best-effort like the BSP and must not borrow decoder SRAM without TRM/vendor evidence — CODE-INSPECTED / MEASURED live procfs/sysfs / ONLINE-SURVEY-NEGATIVE.
- `` `2026-07-05-rga3-route-b-runtime-smoke.md` `` — Route-B-only forward-port kernel on Rock 5B contained `driver-owned IOMMU` / `iommu_dma_get_iova_domain` but not the temporary `DIAG rga_dma_map_sgt` breadcrumb; six repeated `rga-mmu-debug.sh` runs (`20260705-182754` through `20260705-182808`) passed `rga_copy_demo`, `rga_resize_rect_demo`, and `rga_transform_rotate_demo` with no rejects, `INTR[0x2]`, IOMMU faults, or failed RGA jobs; debugfs confirms RGA3 uses external `RK_IOMMU` while RGA3 command `mmu: win0 = 00 ...` fields are internal command bits, so this is a behavioral pass and strong indirect Route B evidence, but direct fallback attribution still needs a positive breadcrumb/counter — MEASURED behavior / INFERRED fallback attribution.
- `` `2026-07-05-rga3-route-b-design.md` `` — Route B design for scattered RGA3 userptr: keep dma-buf imports fail-closed, but after a driver-owned sg-table DMA API map violates the single-span/32-bit contract, unmap it, clear stale sg-table DMA/SWIOTLB bookkeeping, allocate one guard-banded IOVA span from the translated RGA DMA domain cookie, map a page-aligned sg copy with `iommu_map_sg()`, program base+page-offset, reject overflowed 32-bit spans, and fail closed if the IOVA granule is larger than `PAGE_SIZE`; apply/checkpatch/object-build verified for forward-port and rewrite, forward-port Route-B-only behavioral smoke passed, rewrite debugfs counters now allow direct fallback attribution once a rewrite kernel is booted — CODE-INSPECTED / BUILD-VERIFIED / BEHAVIORAL-SMOKE-PASSED.
- `` `2026-07-05-rga3-scattered-iova-mechanism.md` `` — why the forward-port hands RGA3 userptr imports a *non-contiguous* IOVA mapping (the `contiguous=0` result): the 512 MB guard band is **not** the cause (it only sets the top-down IOVA ceiling and mapping behavior still varies buffer-by-buffer); the tell is *descending* IOVAs (`end < first`), which the coalescing path can't produce, so a per-segment mapping ran instead of `iommu_dma_map_sg()`'s one-IOVA path; RGA3 is non-coherent (DT: no `dma-coherent`) and the kernel has `CONFIG_DMA_BOUNCE_UNALIGNED_KMALLOC`+`SWIOTLB`, making read-back buffers eligible for the known per-segment bounce branch, but the exact trigger remains unresolved because large segments should not hit the stock bounce; post-Route-B-only smoke moved the same demo family from fail-closed rejects to fault-free completion, with direct fallback attribution still pending — MEASURED (address fingerprint and post-Route-B behavior) / CODE-INSPECTED (path, coherency, config) / trigger UNRESOLVED.
- `` `2026-07-05-rga3-memory-import-contract.md` `` — pre-Route-B RGA3 memory import semantics across vendor forward-port, rewrite, and local mainline V4L2 support: physical-address imports are distinct from userptr, VB2_MMAP is not arbitrary userspace memory, RGA3 needs one linear device-visible span, the forward-port rejected scattered malloc/userptr fail-closed, and the rewrite still needed the same single-segment/32-bit-span validation; superseded for candidate implementation details by `2026-07-05-rga3-route-b-design.md` — CODE-INSPECTED / MEASURED where tied to the runtime RGA3 IRQ finding.
- `` `2026-07-04-librga-consumer-survey.md` `` — public `librga` users outside the current conformance set, including RKNN/RKNPU, GStreamer/RKNN, Orbbec, Weston/pixman/SDL/LVGL-style hits, mostly reinforce RGB/NV12/NV21/RGBA crop preprocessing and simple fd/virtual legacy blit/display-rotate paths; no current Linux-media signal promotes RFBC64x4/AFBC32x8, per-channel rotation, tile alpha/pattern/color-key, or broad RGA2-Pro modes into the required RK3588 profile, so the rewrite now rejects the RGA2-Pro FBC source modes with `-EOPNOTSUPP` — UNVERIFIED public-source survey.
- `` `2026-07-04-rga3-im2d-error-irq.md` `` — RGA3 core0 `INTR[0x2]` on direct upstream librga virtual-buffer samples was root-caused to a forward-port DMA/IOMMU contract gap: missing BSP large-segment setup (`13afe70c8271`), RGA IOVAs being allocated too close to 4 GiB and wrapping in 32-bit registers (`6b9dba7abcd0`), and missing fail-closed validation for non-single-segment or 32-bit-wrapping DMA mappings. RUNTIME-VALIDATED 2026-07-05: the MMU IRQ is gone and the contiguous-buffer path runs clean; the remaining rejects are scattered `virt_addr` imports (`got 341 == orig_nents`) that are now fail-closed **by design**, and Step 0 (`max_seg_size`) was proven already-in-tree (`13afe70c8271`, ancestry-proven active) and insufficient (zero-merge signature) — so scattered userptr on RGA3 needs a driver-owned `iommu_map_sg` ("Route B"), now forward-port build-verified with Route-B-only behavioral smoke passed and direct fallback attribution still pending — MEASURED / ROOT-CAUSED / RUNTIME-VALIDATED for the base issue.
