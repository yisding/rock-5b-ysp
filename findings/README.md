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

- `` `2026-07-05-rga3-memory-import-contract.md` `` — RGA3 memory import semantics across vendor forward-port, rewrite, and local mainline V4L2 support: physical-address imports are distinct from userptr, VB2_MMAP is not arbitrary userspace memory, RGA3 needs one linear device-visible span, the forward-port rejects scattered malloc/userptr fail-closed, and the rewrite still needs the same single-segment/32-bit-span validation because neither driver implements a synthetic contiguous IOVA Route B — CODE-INSPECTED / MEASURED where tied to the runtime RGA3 IRQ finding.
- `` `2026-07-04-librga-consumer-survey.md` `` — public `librga` users outside the current conformance set, including RKNN/RKNPU, GStreamer/RKNN, Orbbec, Weston/pixman/SDL/LVGL-style hits, mostly reinforce RGB/NV12/NV21/RGBA crop preprocessing and simple fd/virtual legacy blit/display-rotate paths; no current Linux-media signal promotes RFBC64x4/AFBC32x8, per-channel rotation, tile alpha/pattern/color-key, or broad RGA2-Pro modes into the required RK3588 profile, so the rewrite now rejects the RGA2-Pro FBC source modes with `-EOPNOTSUPP` — UNVERIFIED public-source survey.
- `` `2026-07-04-rga3-im2d-error-irq.md` `` — RGA3 core0 `INTR[0x2]` on direct upstream librga virtual-buffer samples was root-caused to a forward-port DMA/IOMMU contract gap: missing BSP large-segment setup (`13afe70c8271`), RGA IOVAs being allocated too close to 4 GiB and wrapping in 32-bit registers (`6b9dba7abcd0`), and missing fail-closed validation for non-single-segment or 32-bit-wrapping DMA mappings. RUNTIME-VALIDATED 2026-07-05: the MMU IRQ is gone and the contiguous-buffer path runs clean; the remaining rejects are scattered `virt_addr` imports (`got 341 == orig_nents`) that are now fail-closed **by design**, and Step 0 (`max_seg_size`) was proven already-in-tree (`13afe70c8271`, ancestry-proven active) and insufficient (zero-merge signature) — so scattered userptr on RGA3 would need a driver-owned `iommu_map_sg` ("Route B"), not a config tweak — MEASURED / ROOT-CAUSED / RUNTIME-VALIDATED.
