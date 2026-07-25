# RGA3 userptr-IOMMU: from MMU fault to driver-owned contiguous IOVA

This is the consolidated RGA3 userptr-IOMMU story for the RK3588 forward-port. It
traces one investigation end to end: the `INTR[0x2]` RGA MMU interrupt that direct
`librga` IM2D samples hit, the DMA/IOMMU contract gaps behind it, why scattered
`virt_addr` imports still map to non-contiguous IOVAs after the obvious fixes, and
the driver-owned userptr-IOMMU fallback that finally makes scattered userptr work
without weakening the dma-buf contract. It supersedes six dated findings written
as the work progressed; those are now tombstones pointing here.

> Scope: forward-port kernel `../kernel/linux-6.18-rkvenc-av1-fwport` branch
> `rk3588-video-6.18`, RGA3 driver `drivers/video/rockchip/rga3/`, the rewrite
> trees `../kernel/linux-6.18-rkvenc` and `../kernel/linux`, the Rockchip IOMMU
> provider `drivers/iommu/rockchip-iommu.c`, and the generic
> `drivers/iommu/dma-iommu.c`.
> Source anchors: on-board debugfs runs of prebuilt `airockchip/librga` IM2D
> samples; BSP-vs-forward source comparison against `../kernel/rockchip-kernel`;
> patch artifacts under [`../patches/rga-userptr-iommu/`](../patches/rga-userptr-iommu/architecture.md).
> Trust: MEASURED for the fault addresses, IOVA fingerprints, and smoke behavior;
> CODE-INSPECTED / ROOT-CAUSED for the source deltas; BUILD-VERIFIED and
> BEHAVIORAL-SMOKE-PASSED for the fallback; the per-segment bounce *trigger* and
> direct fallback attribution remain UNRESOLVED / pending (see Status).

See also the patch-series docs — [`architecture.md`](../patches/rga-userptr-iommu/architecture.md)
(invariants and per-tree flow) and [`runtime-validation.md`](../patches/rga-userptr-iommu/runtime-validation.md)
(the hardware gate) — the RGA front door [`README.md`](README.md), the external
consumer scan [`userspace-consumers.md`](userspace-consumers.md), the layer model
in [`../docs/how-the-drivers-work.md`](../docs/how-the-drivers-work.md), and the
whole-project [`../../status.md`](../../status.md).

## 1. The RGA3 MMU interrupt root cause

The direct upstream `librga` samples first looked like bad tests. They are real
forward-port bugs in the DMA/IOMMU contract the vendor RGA driver assumes. The
failing samples import malloc-backed buffers with `importbuffer_virtualaddr()`
(not dma-heaps). RGA pins those pages, builds an sg-table, calls `dma_map_sg()`,
then programs only `sg_dma_address(sgt->sgl)` into RGA registers while treating
the sum of all sg lengths as one contiguous IOVA span. `rga_dma_map_sgt()` stores
just `sg_dma_address(sgt->sgl)` as `buffer->dma_addr` and sums every
`sg_dma_len()` into `buffer->size`; `win0` / `wr` image base registers are
generated from that one base. This depends on the DMA layer returning one
contiguous IOVA segment for the whole buffer.

MEASURED fault evidence, all on `RGA3_core0` (IOMMU `fdb60f00.iommu`), from
`../rockchip-conformance/logs/rga-mmu-debug/20260704-102533`
(`6.18.37-current-rockchip64 #8`). Debugfs `hardware` reported the RK3588 split:
`rga3 core 1/2: mmu: RK_IOMMU`, `rga2 core 4: mmu: RGA_MMU` — so these failures
are specifically on the RGA3 + Rockchip IOMMU path, not legacy RGA2. Sample
processes exited `0` but printed fatal librga errors:

- `rga_copy_demo`: src `iova = 0xfff7e010`, `size = 3686400`; `Page fault at
  0x00000000fff85810 of type read`, `pte ... valid: 0`, `INTR[0x2]`,
  `HW_STATUS[0xaaaaa]`, `RGA3_core0[0x1] soft reset complete`. The fault is
  ~`0x7800` bytes *inside* the logical src range — a fragmented mapping, not bad
  dimensions.
- `rga_resize_rect_demo`: dst `iova = 0xffe79010`, `size = 8294400`; `Page fault
  at 0x00000000fff78010 of type write`, `INTR[0x2]`, `HW_STATUS[0x5aaaa]`.
- `rga_transform_rotate_demo`: `Page fault at 0x0000000000071c10`, `INTR[0x2]`,
  `HW_STATUS[0xaaaaa]` — this one also shows 32-bit wrap, an amplifier, not the
  root cause.

The common pattern is not "address above 4 GiB"; it is "RGA programs a single
base and faults inside the buffer range because the IOMMU page table has no
contiguous mapping for the whole range."

Three BSP-derived forward-kernel fixes followed (all in
`../kernel/linux-6.18-rkvenc-av1-fwport`):

```text
13afe70c8271 iommu: rockchip: restore large DMA segment support
6b9dba7abcd0 video: rockchip: rga: keep IOVAs below 32-bit wrap guard
590c9ef297ce media: rockchip: harden IOMMU forward port   (the fail-closed reject)
```

- `13afe70c8271` restores the BSP contract the forward-port lost in
  `rk_iommu_probe_device()`: allocate `dev->dma_parms` and call
  `dma_set_max_seg_size(dev, DMA_BIT_MASK(32))`, letting media clients map a whole
  32-bit aperture as one DMA segment.
- `6b9dba7abcd0` was necessary because the fix above was **insufficient**. After
  rebuilding (`P60c0-Cb831`, `6.18.38-current-rockchip64 #9`, run `20260704-192122`),
  the generic IOVA allocator still placed a 3.5 MiB source at `iova = 0xfffff010`;
  RGA added 32-bit plane/stride offsets (`0x0110 : fffff010 000e0010 00118410`)
  and wrapped below 4 GiB, faulting at `0x0000000000000410`. The fix lowers the
  RGA mapping device's `bus_dma_limit` to keep a 512 MiB guard band below the
  32-bit IOVA ceiling, while preserving the 40-bit streaming DMA mask.
- `590c9ef297ce` makes the implicit driver/hardware contract explicit at import
  time: `rga_dma_check_iova_contract()` rejects and logs any mapping that is not
  exactly one nonzero DMA segment with a non-wrapping 32-bit span. MPP dma-buf
  imports apply the same rule. This is intentionally fail-closed — it turns a
  would-be MMU fault into a clean `-EOPNOTSUPP` reject.

Not in scope: the missing `dma32_heap` sample failures (a BSP ABI/sample gap),
and the `iommu_set_fault_handler()` guard (diagnostic plumbing that fires *after*
this fault).

## 2. The memory-import contract

CODE-INSPECTED across the forward-port vendor driver, the rewrite, and mainline
RGA3 V4L2. The vendor ABI enum has three distinct paths (`rga.h:83`):
`RGA_DMA_BUFFER`, `RGA_VIRTUAL_ADDRESS` (userptr — pin pages, sg-table, map,
program the device address; used by `importbuffer_virtualaddr()`), and
`RGA_PHYSICAL_ADDRESS` (the ABI field is already a physical address, assumed
contiguous). The rewrite `rk_rga_import_one()` rejects physical imports with
`-EOPNOTSUPP`; mainline RGA3 V4L2 exposes only `VB2_MMAP | VB2_DMABUF` (no
`VB2_USERPTR`, no raw physical import), and for RGA3 `.has_internal_iommu = false`
picks `vb2_dma_contig_memops`.

RGA3 needs one linear device-visible span per plane. It does not strictly require
physically contiguous DRAM *if* the IOMMU/DMA layer hands the device one
contiguous IOVA span — the command format consumes base addresses, not
scatterlists (`rga3-hw.c:110/:122`; rewrite `lower_32_bits()`). The BSP does not
build a synthetic contiguous range itself; it relies on the DMA API plus the
`dma_set_max_seg_size(dev, DMA_BIT_MASK(32))` contract and the `iommu-dma`
`iommu_map_sg_atomic()` coalescing path. BSP MPP is different: its DMA buffers are
dma-buf fds (`MPP_CMD_TRANS_FD_TO_IOVA`, `mpp_task_attach_fd()`), with no
`get_user_pages` / `pin_user_pages` / `VB2_USERPTR` / `.mmap` — so BSP RGA has a
userptr path, BSP MPP does not.

The finding enumerated five options if RGA3 userptr must work (wholesale BSP IOMMU
import; repair the normal DMA path; keep fail-closed; a staging copy; a scoped
userptr-IOMMU remap; or an RGA allocator/mmap path). **This section is SUPERSEDED
for the candidate implementation by the fallback design in section 4** — option 4
(scoped driver-owned `iommu_map_sg()`) is the one that was built. What survives
here is the durable ABI map and the standing guidance: use dma-buf / dma-heap /
CMA-style buffers for dependable RGA3 operation, and pass the dma-buf *fd* (not an
mmap pointer) so the exporter/importer contract is preserved. A dma-buf is a
sharing handle, not a contiguity guarantee; what matters is that importing it
produces one contiguous device-visible span.

## 3. Why scattered userptr imports get non-contiguous IOVAs

An IOMMU's whole job is to remap scattered pages into one contiguous IOVA, and
that is cheap — `iommu_dma_map_sg()`'s normal path allocates one IOVA range and
maps every page into it. So why does the forward-port keep handing RGA3 a
non-contiguous mapping for scattered `virt_addr` imports? This section walks the
elimination, each step MEASURED, not argued.

**The 512 MB guard band is not the cause.** `6b9dba7abcd0` bounds *where* IOVAs
are placed (packed just under ~`0xE0000000`, explaining the observed `0xdf……010`
cluster), not *whether* pages coalesce. Same device and guard band produce both
near-contiguous and fully-scattered mappings in one run, and there is ~3.5 GB of
contiguous room below the ceiling for a ~900-page buffer.

**`max_seg_size` is maxed and proven insufficient.** The first runtime pass after
the three fixes (`6.18.38-current-rockchip64 #10`, runs `20260704-233927` /
`20260705-000005`) confirmed the MMU IRQ is gone: programmed IOVAs land well below
the guard (e.g. `0xde800010`, `0xdec00010`), and `rga_resize_rect_demo` ran four
hardware jobs to completion (`finished 1 failed 0`). But scattered malloc buffers
were rejected by design: copy/rotate's first buffer had `orig_nents = 341`
(ordinary fragmentation of a 3.6 MB / 900-page buffer) → `reject sg_table DMA
mapping: expected one DMA segment, got 341` → `importbuffer failed!`, while
contiguous draws (`orig_nents = 1`) passed. The pass/fail split is allocation
luck, not a regression; `got 341 == orig_nents` means **zero merging** — the map
is not being serviced by the coalescing path.

Three map-site DIAG builds (temporary forward-port commits `eb0f3e209007` +
fixups `30102c8f769e`, `171de4153e97`) pinned this down:

- `#11` (`20260705-125811`): `dev=fdb60000.rga max_seg_size=4294967295
  orig_nents=254 nents=254 domain_type=0x3`. The 4 GB cap is active on the real
  map device (directly measured), and the domain is `IOMMU_DOMAIN_DMA` —
  **translated, paging, DMA-API-managed**, not identity (`0x4`). This corrected an
  earlier "direct/identity path" wording and reopened the "route it onto
  iommu-dma" option.
- `#12` (`P4256-Cb831`, `20260705-142730`): adds `use_dma_iommu=1` (orig_nents =
  nents = 332). This **eliminates** that option — the device is already on the
  generic iommu-dma path; `dma_map_sg()` dispatches to `iommu_dma_map_sg()`. A
  static read of that function then suggested the multi-segment return might just
  be non-coalesced *reporting* over one contiguous IOVA block, which would mean
  "relax the check" rather than a fallback. That hypothesis was staged for
  measurement.
- `#13` (`20260705-151717` contiguous-by-luck → pass; `20260705-151723`
  fragmented → the interesting one): **every** multi-segment mapping came back
  `contiguous=0`:

  ```text
  orig_nents=386 contiguous=0 gaps=9   first=0xdfd04010 span=0x17c000            end=0xdfe8000f
  orig_nents=492 contiguous=0 gaps=68  first=0xdfebd010 span=0x89000             end=0xdff4600f
  orig_nents=367 contiguous=0 gaps=306 first=0xdfe27010 span=0x96000            end=0xdfebd00f
  orig_nents=895 contiguous=0 gaps=894 first=0xdffff010 span=0xffffffffffc7a000  end=0xdfc7900f
  orig_nents=390 contiguous=0 gaps=367 first=0xdfd0d010 span=0xffffffffffc5f000  end=0xdf96c00f
  ```

The descending-IOVA fingerprint is decisive: `end < first` (the huge
`span=0xffffffff…` is a negative wrap) means the last segment ends **below** the
first — IOVAs run **backwards**, with a gap at essentially every segment
(`gaps=894` of 895). The generic normal path (`iommu_dma_alloc_iova` +
`iommu_map_sg` + `__finalise_sg`, `dma-iommu.c` ~`:1483/:1493/:1312/:1316`) can
only ever hand back monotonically ascending addresses tiling one allocation, so it
is **not** what ran. Each segment got its own IOVA, handed out top-down — a
per-segment mapping path, not the coalescer. That kills the "one contiguous span,
just non-coalesced reporting" hypothesis: RGA's `base + size` programming really
would walk into unmapped/out-of-order IOVA and fault. **The fail-closed reject is
correct.**

Two enabling facts for a stock per-segment (swiotlb) path are CODE-INSPECTED:
RGA3 is **non-coherent** (its DT node `rga@fdb60000`, `rk3588-base.dtsi`, has no
`dma-coherent`), and this kernel bounces unaligned kmalloc DMA
(`/boot/config-6.18.38-current-rockchip64`: `CONFIG_SWIOTLB=y`,
`CONFIG_DMA_BOUNCE_UNALIGNED_KMALLOC=y`; `dma_kmalloc_safe()` returns false for a
non-coherent read-back mapping). **Honest boundary:** the stock bounce should not
actually fire — every userptr segment here is ≥ 4 KB, so `dev_use_sg_swiotlb()`
would compute "no bounce" — yet the hardware shows a per-segment mapping. So
either the heavily-modified forward-port `dma-iommu.c` (~890 insertions) takes a
Rockchip-specific per-segment path, or there is a trigger not visible in the stock
reading. The exact **trigger is UNRESOLVED** (leading hypothesis only, twice
mis-predicted from static analysis). It is not load-bearing: `contiguous=0` is
measured, so the reject and the fallback are correct regardless of *why* the
coalescer was skipped. One more DIAG field (the `dir` argument plus which
`iommu_dma_map_sg()` branch ran) would settle it in one reflash.

Once the DIAG served its purpose, `eb0f3e209007` + `30102c8f769e` + `171de4153e97`
were to be dropped from the forward-port branch; the fail-closed reject in
`590c9ef297ce` is unaffected.

## 4. The userptr-IOMMU fallback design

Every cheap lever is eliminated by measurement (not `max_seg_size`, not
iommu-dma routing, not check-relaxation). The one technical path that makes
scattered `virt_addr` work on RGA3 is a **driver-owned contiguous IOVA**: the
driver does by hand, once, what the coalescer does for the lucky contiguous
buffers — allocate one IOVA range in the translated RGA domain, `iommu_map_sg()`
the scatter into it, program that single base, do explicit cache maintenance, and
tear it down on release. This works regardless of *why* the generic path scatters
some buffers.

The fallback is implemented without relaxing the import contract. DMA-buf imports
stay fail-closed on "one 32-bit-safe DMA span"; the fallback is scoped to
**driver-owned sg-tables only**. Two hook points, same mapping semantics:

- **forward-port** (patch 0001): the fallback lives in the shared
  `rga_dma_map_sgt()` helper, covering `virt_addr` userptr imports and the
  physical-address IOMMU path (both are driver-owned sg-tables).
- **rewrite** (patch 0002): scoped to pinned userptr imports and per-job userptr
  remaps only; dma-buf imports/remaps are validated and rejected if not one
  32-bit-safe span. Patch 0002 also sets the RGA3 40-bit streaming DMA mask,
  32-bit coherent mask, and `bus_dma_limit` clamp at `DMA_BIT_MASK(32) - SZ_512M`.

Common flow: normal `dma_map_sg*()` is tried first; if it returns multiple
segments or a 32-bit-wrapping span, it is unmapped and its sg DMA bookkeeping
(including `SG_DMA_SWIOTLB`) is cleared so later cache sync uses the physical
pages, not stale bounce state; a page-aligned temporary sg-table copy is built and
passed to `iommu_map_sg()`; the original sg-table stays the pin/unpin and
cache-maintenance object; the programmed address is the synthetic page-aligned
IOVA plus the original first-page offset (`rga_mm_lookup_iova()` returns
`buffer->iova + buffer->offset`); teardown records fallback ownership and uses
`iommu_unmap()` + `free_iova_fast()`, never `dma_unmap_sg*()`. Forward-port
writable userptr mappings mark their GUP-held pages dirty before dropping page
references.

Two constraints fall directly out of section 3's facts. **Non-coherent ⟹ explicit
cache maintenance:** the fallback keeps `dma_sync_sg_for_device()` before the job
and `dma_sync_sg_for_cpu()` after, on the original physical sg-table through the
same `map_dev` — whatever silently provided read-back coherency before will not,
so skipping this yields correct addresses but stale/corrupt pixels. **Keep 32-bit-
safe placement:** the fallback caps its own IOVA allocation at the minimum of the
device DMA mask, `bus_dma_limit`, any forced aperture, and
`DMA_BIT_MASK(32) - SZ_512M`, with overflow-checked `base + size - 1` arithmetic,
so it cannot reintroduce the wrap fault `6b9dba7abcd0` fixed.

Two more invariants keep it honest. It uses the **translated RGA domain's existing
DMA IOVA allocator**, not a private one — the patches add a small exported
`iommu_dma_get_iova_domain()` helper in `drivers/iommu/dma-iommu.c` (checking
`domain->cookie_type == IOMMU_COOKIE_DMA_IOVA`) so allocations share ownership
with the DMA API instead of overlapping it; it fails closed if there is no
translated paging domain or no DMA IOVA cookie. And because RGA3 needs a
byte-contiguous view, it **fails closed if the IOVA granule is larger than
`PAGE_SIZE`** — not expected on RK3588's 4 KiB Rockchip IOMMU, but explicit for
future ports.

Patch artifacts under [`../patches/rga-userptr-iommu/`](../patches/rga-userptr-iommu/architecture.md):
0001 (forward-port), 0002 (rewrite mapping), 0003 (rewrite debugfs counters).
The rewrite slice is committed and pushed on both rewrite branches:
`rk3588-rewrite-6.18` @ `d1cfb432da7f` and `rk3588-rewrite-mainline` @
`c8a41bb830a6`, and exposes `rk_rga_rewrite/userptr_iommu/{attempt,ok,active,force_remap}`
for direct fallback attribution.

## 5. dma-buf scatter contract vs BSP

CODE-INSPECTED / DESIGN-CONSTRAINT (from the local 6.1 BSP,
`/home/yi/Code/kernel/rockchip-kernel`). A dma-buf can be physically
non-contiguous, but that alone is not a problem for RGA3: the safety boundary is
whether the dma-buf attachment maps to one byte-contiguous device-visible span.
The BSP does **not** implement a separate dma-buf IOMMU remap fallback. For RGA3
dma-buf imports it calls `dma_buf_attach()` / `dma_buf_map_attachment()`, records
`sg_dma_address(sgt->sgl)` from the first entry, sums `sg_dma_len()` into
`buffer->size`, and does **not** call `iommu_map_sg()` or allocate a new IOVA span
(`rga_dma_map_buf()`, `rga_dma_map_fd()`; `rga_dma_map_sgt()` is the driver-owned
sg-table path, not an exporter-owned dma-buf remap). Its
`rga_mm_check_contiguous_sgt()` returns true only for `orig_nents == 1` and does
not test `prev_dma + prev_len == next_dma` adjacency. Its internal
`rga_mm_sgt_to_page_table()` is for the internal RGA-MMU command path;
`rga_mm_is_need_mmu()` returns false when the scheduler uses `RGA_IOMMU`, so it is
not evidence for an external-IOMMU dma-buf remap.

Consequence for YSP: do **not** add a dma-buf userptr-IOMMU-style remap just
because dma-bufs can be scattered — that creates ownership and fence/cache-sync
questions around exporter-owned mappings that the studied BSP path does not take.
The contract: accept dma-bufs whose mapped attachment is one byte-contiguous,
non-wrapping, 32-bit-safe span; reject true gaps, descending addresses, wrap, or
overflow; do not increment `userptr_iommu` counters for dma-buf imports; keep the
fallback scoped to driver-owned sg-tables (pinned userptr and the physical-address
IOMMU path). If real workloads frequently hit dma-buf rejects, the first
improvement is a contiguous-DMA-span validator that accepts adjacent multi-entry
mappings — stricter than the BSP's unsafe `orig_nents == 1` case because it proves
the span before programming base+size.

## 6. Runtime validation

BEHAVIORAL-SMOKE-PASSED (forward-port). The installed RGA-userptr-IOMMU-only test
kernel was `Linux rock-5b 6.18.38-current-rockchip64 #14`. `strings
/boot/vmlinuz-6.18.38-current-rockchip64` found the fallback identifiers
`driver-owned IOMMU` and `iommu_dma_get_iova_domain` but not `DIAG
rga_dma_map_sgt` — i.e. a clean fallback image, not the debug-tip profile.

Six consecutive `rga-mmu-debug.sh` artifact directories reported `pass` for
`rga_copy_demo`, `rga_resize_rect_demo`, and `rga_transform_rotate_demo`:

```text
20260705-182754  20260705-182758  20260705-182801
20260705-182803  20260705-182806  20260705-182808
```

The filtered dmesg for those runs had no `DIAG rga_dma_map_sgt`, no `reject
sg_table DMA mapping`, no `INTR[0x2]`, no IOMMU page fault, and no `finished N
failed M` fault with `M > 0`. Debugfs confirmed the RK3588 split (`rga3 core 1/2:
RK_IOMMU`, `rga2 core 4: RGA_MMU`), and logs showed device-visible IOVA handles
such as `iova = 0xdd800000, dma_addr = 0xdd800000, offset = 0x10` with jobs
`finished 1 failed 0`. (RGA3 dumps still print `mmu: win0 = 00 win1 = 00 wr = 00`
— the internal command-MMU bitfield, expected zero under the external RK_IOMMU,
not evidence of physical addressing.)

This is strong **indirect** evidence: the same demo family previously failed
closed at `20260705-151723` with non-contiguous `orig_nents == nents` mappings
(`contiguous=0`, gaps 9–894, two cases with `end < first`). But direct attribution
is still INFERRED, not proven — the clean image intentionally carries no positive
success log/counter in `rga_dma_map_sgt_iommu()`, so the artifacts cannot identify
which individual import entered the fallback. To close it, boot the debug-tip
profile or add a temporary breadcrumb/counter and capture one passing case that
entered the fallback. On the rewrite, patch 0003's `rk_rga_rewrite/userptr_iommu`
counters exist for exactly this, but need a booted rewrite run
(`LIBRGA_FORCE_RGA_USERPTR_IOMMU=1` requires `attempt`/`ok` to move and `active`
to return to 0). The full hardware gate is in
[`../patches/rga-userptr-iommu/runtime-validation.md`](../patches/rga-userptr-iommu/runtime-validation.md).

## Status and open items

BUILD-VERIFIED:

- `git apply --check` and strict checkpatch clean for patches 0001 (forward-port)
  and 0002/0003 (both rewrite trees); focused object builds pass, including the
  page-granule and overflow-safe span guards, and also pass with `W=1`.
- Rewrite slice committed and pushed: `rk3588-rewrite-6.18` @ `d1cfb432da7f`,
  `rk3588-rewrite-mainline` @ `c8a41bb830a6`; committed-tip
  `rewrite-build-gate.sh all` passed from git-archive sources for both kernels
  (`mpp_rewrite.o`, `rga_rewrite.o`).

BEHAVIORAL-SMOKE-PASSED:

- The three-fix forward-port (`13afe70c8271` + `6b9dba7abcd0` + `590c9ef297ce`,
  `#10`) removed the `INTR[0x2]` MMU IRQ; the contiguous-buffer path runs clean.
- The RGA-userptr-IOMMU-only forward-port kernel (`#14`) ran the previously
  fail-closed scattered `virt_addr` demo family to completion, fault-free, across
  the six 18:28 runs.

Still pending:

- **Direct fallback attribution** (forward-port and rewrite). Behavioral smoke
  passed, but no run has yet shown, per-import, that `rga_dma_map_sgt_iommu()` (or
  the rewrite `userptr_iommu` counters) actually executed for a passing case.
- **The per-segment bounce trigger is UNRESOLVED.** Why the generic iommu-dma path
  returns backwards, per-segment IOVAs for these buffers (rather than the stock
  coalesced path) is a leading hypothesis only. Not load-bearing — `contiguous=0`
  is measured, so the reject and the fallback are correct regardless — but it
  would take one more DIAG field to nail.
- **A dma-buf negative gate** (multi-segment attachment rejected cleanly under the
  single-span contract, `userptr_iommu` counters unmoved) should be added before
  promoting the rewrite from build-verified to runtime-proven.

Standing recommendation: RGA3 requires dma-buf / physically-contiguous input;
scattered userptr otherwise routes to the RGA2 core (`RGA_MMU`, its own page-table
MMU). Real pipelines (GStreamer/MPP) hand RGA dma-buf fds from suitable exporters,
and the forward-port already validates those before programming RGA3. The
userptr-IOMMU fallback exists to make the direct `virt_addr` path deterministic
when it is needed, without weakening the dma-buf contract.
