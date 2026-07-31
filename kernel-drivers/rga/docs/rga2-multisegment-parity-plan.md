# RGA2 discontinuous DMA-BUF and USERPTR parity plan

The first mapping-parity target for the RGA rewrite is the RK3588 RGA2 core's
internal page-table MMU. A role-correct DMA-BUF attachment or USERPTR mapping
must remain owned by the DMA API; when its mapped DMA view has more than one
device extent, the rewrite should describe those extents to RGA2 through a
per-job internal-MMU page table instead of requiring `sg_table.nents == 1`.

This closes the ordinary system-heap failure without crossing the DMA-BUF
exporter boundary. It also gives RGA2 the same basic representation used by the
BSP and forward port for scattered memory. RGA3 support for a genuinely gapped
exporter attachment is a later, separate design problem.

## Implementation status — 2026-07-31

The first source-alignment pass is implemented at these commits:

- forward port: `rk3588-video-6.18@14c0456c4108`;
- 6.18 rewrite: `rk3588-rewrite-6.18@995a0aa710fb`; and
- mainline rewrite: `rk3588-rewrite-mainline@168f5f4acfa9`.

The rewrite commits remove the roleless persistent DMA-BUF attachment, map
each object against the selected core with its job role, retain discontinuous
RGA2 mappings, compose per-channel coherent PTE tables, program all four RGA2
MMU channels, preserve USERPTR DMA/SWIOTLB mappings, and release tables before
their data mappings. The two rewrite sources are byte-identical. Their existing
148-case KUnit manifest now exercises adjacent/gapped SG walking,
separate-plane address composition, and destination-as-source1 command words
inside the established IOVA-contract case.

The forward-port commit reconciles the same lower-level contracts: multiple
byte-adjacent mapped entries are a valid direct span, and RGA2 PTEs are built
from mapped DMA entries and lengths rather than mixing mapped addresses with
the original SG shape.

This is **source-fixed and build-verified, not runtime-verified**. The changed
forward objects compile cleanly. Both rewrite commits pass the clean-archive
rewrite build gate in its normal and test-disabled profiles, covering both
IOMMU providers, the MPP and RGA rewrite objects, and the Rock 5B DTB with
warnings fatal. The cross-tree byte-identity check, exact manifest, and KUnit
fixture audit also pass. Forced-RGA2 fragmented DMA-BUF content tests,
DMA-direction proof, fault/abort cleanup, new route counters, scheduler
fallback, and the captured CMA discriminator remain completion-gate work
below.

The source contract and measured failure are recorded in:

- [the multi-segment memory-contract finding](../../../findings/2026-07-31-rga-userptr-dmabuf-multisegment-contracts.md); and
- [the rewrite system-heap refusal finding](../../../findings/2026-07-31-rga-rewrite-multisg-dmabuf-cma-einval.md).

## Definition of RGA2 parity

This plan calls RGA2 mapping support at parity when all of the following are
true:

1. A normal system-heap DMA-BUF can run on RGA2 regardless of whether its
   selected-core attachment maps as one or several DMA segments.
2. The driver consumes only the mapped DMA view supplied for the selected RGA2
   device. It does not remap `sg_page()` behind an exporter-owned attachment.
3. The existing one-segment direct-address path remains the fast path.
4. When an RGA2 mapping requires the internal MMU, source, destination,
   pattern/source1, and palette/else channels receive correct page-table bases
   and virtual byte offsets.
5. Multiple image planes backed by either one DMA-BUF or separate DMA-BUFs are
   composed into the one page-table address space available to that hardware
   channel.
6. RGA2 USERPTR mappings use the same mapped-DMA-to-page-table mechanism. A
   32-bit RGA2 DMA mapping may therefore use SWIOTLB addresses for pages above
   4 GiB, with normal DMA unmap/copyback semantics.
7. Abort, timeout, core removal, session close, and every partial failure leave
   no attachment, mapping, coherent page table, hardware reference, or active
   counter behind.
8. Forced-RGA2 system-heap and USERPTR cases are content-exact and warning-free
   under the rewrite's normal KASAN/DMA-API/lockdep validation profile.

Parity does not mean that RGA2 must accept every possible exporter mapping. A
mapping whose logical discontinuity occurs inside a 4 KiB RGA-MMU page cannot
be represented without copying. It must fail with a precise `-EOPNOTSUPP` and
remain eligible for another core when the request did not force RGA2.

## Non-goals for this phase

- Do not add an RGA3 synthetic-IOMMU mapping for DMA-BUF attachments.
- Do not reuse the USERPTR Route-B helper on exporter-owned SG tables.
- Do not change RGA3's current single-safe-span admission rule.
- Do not promise support for exporter-specific staging, moving attachments, or
  sub-page discontinuities that the public DMA-BUF mapping does not make safe
  to reinterpret.
- Do not fold the still-unlocalized CMA `EINVAL` into this patch set unless a
  new trace proves that it shares the RGA2 mapping path.
- Do not broaden the rewrite's mixed DMA-BUF/USERPTR alias policy as part of
  this work.

## Donor contract to preserve

The BSP/forward-port RGA2 path supplies the useful model:

```text
DMA-BUF attachment or USERPTR SG table
  -> DMA-map against the executing RGA2 device
  -> mapped DMA segments, including any SWIOTLB addresses
  -> one 32-bit PTE per RGA-MMU virtual page
  -> DMA-visible page-table allocation
  -> RGA2 channel MMU base + virtual byte offsets
```

The donor's `rga_mm_sgt_to_page_table()` selects `sg_dma_address()` for
per-job RGA2 mappings. That point is essential: a page above 4 GiB may have a
valid below-4-GiB SWIOTLB DMA address even though `sg_phys()` cannot be encoded
in an RGA2 PTE. The data mapping must stay alive until hardware completion so
DMA synchronization and destination copyback still target the mapping that RGA
actually used.

The donor command encoding is also concrete:

| Command offset | Meaning |
|---|---|
| `0x06c` | Per-channel MMU enable/control nibbles |
| `0x070` | Source0 page-table DMA base, shifted right by four |
| `0x074` | Source1 page-table DMA base, shifted right by four |
| `0x078` | Destination page-table DMA base, shifted right by four |
| `0x07c` | Else/palette page-table DMA base, shifted right by four |

These five words already fit the rewrite's 32-word RGA2 command buffer. Port
the donor bit meanings and base encoding explicitly; do not infer them from
the userspace `mmu_flag`, which is import provenance before materialization and
not proof that the selected job mapping needs the internal MMU.

## Target ownership model

### Import lifetime

DMA-BUF import should retain the `struct dma_buf`, its logical size, and import
identity. It should not keep a roleless `DMA_TO_DEVICE` attachment merely to
obtain an address placeholder. That persistent map currently creates both an
overly early one-segment admission rule and the observed direction mismatch
when a later destination is synchronized for CPU reads.

Task materialization should use import identity and logical layout. A usable
device address is not assigned until the scheduler has selected a core and the
source/destination role is known.

### Per-import selected-core mapping

`rk_rga_job_mapping` should continue to own each selected-core data mapping:

- DMA-BUF attachment, mapped SG table, and role-correct DMA direction;
- USERPTR mapped SG table, shadow-page view, and DMA/SWIOTLB state;
- mapped logical size and a classification of the DMA view; and
- the hardware/device references needed to tear it down.

Refactor `rk_rga_job_map_import()` to return the mapping object, not only one
IOVA. On RGA3, the mapping still must resolve to one safe span. On RGA2, a
multi-segment result is retained for internal-MMU materialization rather than
being unmapped and sent to USERPTR Route B.

### Per-channel RGA2 page tables

The page table cannot live only in `rk_rga_job_mapping`. RGA2 has one MMU base
per hardware channel, while one image channel can reference multiple imports:

```text
source channel
  Y  -> DMA-BUF A
  UV -> DMA-BUF B
  V  -> DMA-BUF C
  => one source0 RGA-MMU table containing A, then B, then C
```

Add a current-task RGA2 MMU object with `src0`, `src1`, `dst`, and `els`
tables. Each table owns:

- CPU and DMA addresses;
- allocation size and PTE count;
- the virtual byte offset assigned to each plane/region; and
- an enabled flag used by command emission and cleanup.

Several channels may refer to the same data mapping. They may initially use
separate page tables for simple ownership; sharing identical tables is an
optional optimization after correctness and cleanup are proven.

## Mapping and page-table algorithm

### 1. Classify the mapped DMA view

Introduce a pure helper that walks the DMA entries, using `sg_dma_address()`
and `sg_dma_len()` over the mapped entry count. It must distinguish:

- one nonzero, non-wrapping 32-bit span;
- multiple entries whose byte ranges are exactly adjacent;
- page-representable discontinuities; and
- malformed, short, overflowing, above-32-bit, or sub-page-discontinuous
  mappings.

One segment and proven-adjacent segments can use the direct-address fast path.
Do not treat `nents > 1` as proof of a gap, and do not sum lengths without
checking every transition.

### 2. Emit PTEs from DMA addresses

Create a pure range helper that copies a requested logical subrange of a mapped
SG table into a caller-supplied `u32` PTE array. It must:

1. preserve exporter/DMA logical order;
2. use DMA addresses, never `sg_phys()` or `sg_page()`;
3. coalesce adjacent DMA entries before testing a boundary;
4. retain the first byte's page offset;
5. require every real discontinuity to occur at a 4 KiB logical and DMA page
   boundary;
6. reject a PTE address above `SZ_4G - PAGE_SIZE` rather than truncate it;
7. prove that the mapped entries cover the requested logical range; and
8. overflow-check every offset, page count, table byte count, and address.

The helper should support `(logical_offset, length)` so a single-buffer
Y/UV/V image can reuse the correct regions of one mapped DMA-BUF.

### 3. Compose an image channel

After all imports for the selected task are mapped:

- keep direct addresses when every plane used by the channel has a safe direct
  mapping;
- if any plane needs RGA-MMU translation, build one channel table covering all
  required planes;
- collapse planes backed by the same import into the appropriate logical range;
- append separately backed planes at a new page-table page boundary; and
- rewrite the task's Y/UV/V addresses to virtual offsets within the resulting
  channel table.

The existing format/layout helpers remain the authority for plane byte sizes.
Table construction must not derive a different layout from the exporter SG
shape.

### 4. Allocate DMA-visible tables

Start with one `dma_alloc_coherent(hw->dev, ...)` allocation per enabled
channel. The rewrite already uses coherent RGA2 command buffers, and the RGA2
device's coherent mask is 32 bits. This avoids introducing the vendor global
ring allocator or streaming-table cache synchronization into the first patch.

Before programming a table, require:

- a nonzero PTE count and exact allocation-size calculation;
- a table DMA base that fits the RGA2 register contract;
- at least 16-byte base alignment, because the command stores `base >> 4`; and
- a bounded size derived from validated image/import extents.

If repeated large-image testing shows unacceptable high-order coherent
allocation failures, replace the per-channel allocator with a bounded coherent
pool in a later patch. Do not weaken the ownership checks to hide allocation
pressure.

## Command emission

Add a single `rk_rga2_emit_mmu()` step after normal address emission and before
the command is marked ready. It should program only tables built for the
current task; the zeroed command buffer keeps every unused channel disabled.

Role mapping is:

| Rewrite task role | RGA2 MMU channel |
|---|---|
| bitblt/palette source | `src0` |
| destination | `dst` |
| alpha-bitmap or OSD pattern | `src1` |
| update-palette table | `els` |
| destination read as the blend background | `src1` aliases the destination table, matching the donor |

For each enabled channel, write the donor enable bit and the table DMA base
shifted right by four. Do not enable undocumented flush/prefetch bits until the
donor comparison or hardware evidence requires them.

The emitter must be shared by bitblt, color fill, color palette, and update
palette paths so a future render-mode addition cannot silently omit MMU
programming.

## Synchronization and teardown

Construction order for a DMA-BUF channel is:

```text
get hardware/device reference
  -> attach DMA-BUF
  -> map attachment with role direction
  -> classify/build logical DMA ranges
  -> allocate and fill coherent RGA2 page table
  -> emit/run command
```

Release in strict reverse order after hardware has stopped reading both data
and PTEs:

```text
free coherent page table
  -> unmap attachment (including destination copyback if exporter/DMA requires)
  -> detach DMA-BUF
  -> drop device/hardware references
```

USERPTR follows the same table lifetime, then the existing mapping/view cleanup
performs DMA synchronization, SWIOTLB copyback, boundary-shadow copyback, and
page release. Never abandon the DMA mapping after copying its DMA addresses
into PTEs; those addresses are valid only while that mapping remains active.

Centralize current-task table cleanup and call it from normal completion,
mapping failure, command-allocation/emission failure, timeout, IRQ error,
abort, session close, and core removal. Cleanup must tolerate a partially built
set of four channels.

## Review sequence and remaining patches

The source alignment was reviewed in the dependency order below and landed as
one atomic commit in each rewrite branch to preserve their exact source
identity. Follow-up observability, scheduling, and runtime-gate work should
remain separately bisectable:

1. **Discriminator and observability.** Add an explicit selected-core field to
   the direct probe/capture, plus rate-limited RGA2 mapping diagnostics and
   counters. Reconfirm whether the measured 8/15-entry failures selected
   RGA2.
2. **Import-lifetime cleanup.** Remove the roleless persistent DMA-BUF mapping;
   retain logical identity/size and defer mapping to the selected job. Preserve
   RGA3 behavior through the per-job single-span check.
3. **Pure SG/PTE helpers.** Add DMA-span classification, logical-range walking,
   PTE construction, and exhaustive KUnit coverage without enabling hardware
   MMU mode.
4. **RGA2 table ownership.** Add per-channel coherent allocations, partial
   unwind, and selected-core mapping state. Keep multi-SG jobs rejected until
   command emission lands in the next patch.
5. **RGA2 command integration.** Add the five MMU command words, channel/plane
   rebasing, render-mode role selection, and command-word KUnit fixtures; then
   enable multi-SG DMA-BUF execution on forced RGA2.
6. **RGA2 USERPTR parity.** Preserve multi-entry RGA2 DMA mappings instead of
   attempting external-IOMMU Route B, and feed their DMA/SWIOTLB addresses into
   the same page-table builder.
7. **Scheduler behavior.** For an unforced task, make a pre-hardware
   `-EOPNOTSUPP` mapping/materialization result eligible for another compatible
   core without retrying after MMIO start. A forced-RGA2 request returns the
   precise error.
8. **Runtime gates and documentation.** Promote the forced-core matrix,
   counters, cleanup assertions, and paired forward/rewrite evidence before
   calling RGA2 mapping parity complete.

Steps 2 through 6 are present in the source-alignment commits. Steps 1, 7, and
8 remain open; the hardware gate must also review the page-table walker,
resource ownership, command encoding, and SWIOTLB copyback as independent
failure domains even though they share the initial source commit.

## Device-free verification

Add KUnit cases for at least:

- one mapped segment and several byte-adjacent mapped entries;
- two page-aligned gapped entries producing the expected PTE order;
- first-page offsets and exact final-page truncation;
- rejection of a discontinuity inside a logical or DMA page;
- short coverage, zero length, count/size overflow, descending/overlapping DMA
  extents, and PTE addresses above 32 bits;
- one-buffer and separate-buffer Y/UV/V channel composition;
- source, destination, pattern/source1, palette/else, and destination-as-src1
  command words;
- page-table DMA-base alignment and 32-bit rejection;
- one import reused by multiple roles without double unmap/free;
- failure after each successive attachment, mapping, table, and command
  allocation; and
- idempotent normal, abort, timeout, and partial-construction cleanup.

Build both rewrite trees with KUnit enabled and disabled, keep the exact KUnit
manifest stable or update it intentionally, and keep their rewrite source
behavior synchronized. Run the repository's rewrite build gate before
producing a bootable package.

## On-hardware verification

Extend [`rga-core-match-test`](../../tests/rga-core-match-test.cpp) or add a
narrow sibling so every case records the requested and selected core, heap,
role, `orig_nents`, mapped `nents`, direct/MMU route, PTE count, errno, and byte
comparison.

Run the following forced on RGA2, first at a normal 352x352 RGBA size and then
at the 64/68-pixel scheduler boundary:

| Source | Destination | Required result |
|---|---|---|
| system heap | system heap | content-exact, including captures with `nents > 1` |
| system heap | CMA heap | content-exact source-table path |
| CMA heap | system heap | content-exact destination-table/copyback path |
| CMA heap | CMA heap | direct-address control remains content-exact |
| USERPTR | USERPTR | content-exact scattered-page path |
| above-4-GiB USERPTR | USERPTR and inverse | content-exact when SWIOTLB can map it; precise clean failure when bounded resources cannot |

Repeat the DMA-BUF matrix for single-plane RGBA, NV12, supported 10-bit
semi-planar formats, separate-plane imports, fill, palette, and a destination-
read/blend case. Run enough allocation churn and bounded memory pressure to
observe changing SG shapes rather than proving only one lucky allocation.

For every run require:

- selected-core evidence that RGA2 actually executed the job;
- matching internal-MMU counters and a zero active-table gauge afterward;
- exact destination bytes under DMA-BUF CPU-access brackets;
- no DMA-direction warning, RGA2 MMU/bus/config error, timeout, KASAN report,
  lockdep report, or fatal journal line; and
- unchanged forced-RGA3 results for the same supported requests.

Then exercise timeout/abort, request cancellation, session close with queued
work, and RGA2 unbind/rebind while mappings exist. Finish with the maintained
librga, FFmpeg, GStreamer, mpv, ABI, recovery, booted-KUnit, and paired
forward-port/rewrite evidence gates.

## Observability and failure policy

Expose stable counters for:

- RGA2 direct data mappings;
- RGA2 internal-MMU jobs and PTEs;
- RGA2 internal-MMU construction failures;
- scheduler retries caused by pre-start mapping incompatibility; and
- currently active RGA2 page tables.

Failure diagnostics should be rate-limited and name the core, role, mapping
kind, `nents`/`orig_nents`, required logical size, and the exact representability
reason. Do not leave per-frame success logging enabled.

Use `-EOPNOTSUPP` for a well-formed mapping that RGA2 cannot represent,
`-EOVERFLOW` for arithmetic or address-range failures, `-ENOMEM` for table
allocation failure, and `-EINVAL` only for malformed logical layout. Do not
translate every branch back to userspace `EINVAL`; the direct probe needs a
discriminating result.

## Completion gate

RGA2 mapping parity is complete only when a booted debug kernel proves all of
the following on the same reviewed source/package identity:

1. forced-RGA2 system-heap jobs with measured multi-entry attachments are
   content-exact across source, destination, both-leg, multi-plane, and blend
   roles;
2. RGA2 scattered and above-4-GiB USERPTR controls are content-exact or hit only
   the documented bounded-resource failure;
3. direct CMA/single-span jobs remain on the direct path;
4. every success and injected lifecycle exit returns the active table/mapping
   gauges to zero;
5. DMA-API debugging, KASAN, lockdep, RGA2 fault/status registers, and bounded
   journal scans stay clean; and
6. the full rewrite conformance and paired forward-port comparison remain
   green.

Only after this gate should work begin on a generic RGA3 response to genuinely
gapped exporter attachments. RGA2 parity removes the common non-IOMMU-core
failure without prejudging that separate ownership design.
