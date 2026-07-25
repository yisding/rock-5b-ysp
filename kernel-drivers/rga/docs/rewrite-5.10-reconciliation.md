# RGA rewrite reconciliation with Rockchip 5.10

Design and implementation record for the Rockchip RGA changes that landed on
the vendor `develop-5.10` branch after the 6.1/6.6 RGA lineages diverged. The
adaptation is implemented and clean-build validated; booted RK3588 validation
is still required.

> **Conclusion.** Five 5.10 change groups were adapted to the rewrite:
> the two RK3588 low-voltage workarounds, RGA2 config/parse-error interrupt
> handling, cache-line-safe userptr boundary pages, and the RGA3 exception for
> librga's R2Y BT.709-limited `full_csc` compatibility flag. The changes could not
> be cherry-picked because the rewrite has different ownership, mapping,
> scheduling, and IRQ models. They landed as
> `linux-6.18-rkvenc@0d71ded1690c` and `linux@32696e87c9c7`. Several other 5.10
> fixes are already covered by the rewrite or concern hardware modes that it
> deliberately rejects.

## Scope and source pins

The comparison began on 2026-07-16 and the implementation was validated on
2026-07-17 against these trees:

| Role | Revision |
|------|----------|
| Newest Rockchip RGA donor examined | `rockchip-linux/kernel develop-5.10@bfa51d2ab08140d1309afc9a9fe0fc2878cee35a` |
| Rewrite implementation | `linux-rock5b rk3588-rewrite-6.18@0d71ded1690c` |
| Mainline mirror | `linux-rock5b rk3588-rewrite-mainline@32696e87c9c7` |
| Rewrite source | `drivers/video/rockchip/rga-rewrite/rga_rewrite.c` |

The broader branch comparison, including why the numerically older 5.10 tree
contains newer RGA work than 6.1/6.6, is in
[`../docs/bsp-6.1-6.6-comparison.md`](../../docs/bsp-6.1-6.6-comparison.md).
This note narrows that comparison to changes that affect the clean-room rewrite.

## Decision matrix

| Priority | 5.10 change | Rewrite disposition |
|----------|-------------|---------------------|
| P0 | RGA3 `logic_clk_on` on RK3588 (`561aab30f22b`) | **Implemented.** RK3588/RGA3 match data sets the logic-clock quirk. |
| P0 | Disable RGA2 `AUTO_RST` on RK3588 (`718fad971319`) | **Implemented.** The affected RGA2E match omits `AUTO_RST` and uses an explicit soft reset before each start. |
| P0 | RGA2 config interrupt and parse status (`ae8e8c4da037`) | **Implemented.** The rewrite enables, clears, snapshots, classifies, counts, and reports config errors as terminal `-EACCES`. |
| P1 | Userptr cache-line shadow pages (`a4afb82d881c`, `6a74aeec3409`, `31aa12084e3b`) | **Implemented.** Shadows are owned per mapping, including per-core rebound mappings and contiguous-IOMMU Route B. |
| P1 | Skip RGA3 full-CSC rejection for R2Y BT.709 limited (`b5061ad9d83f`) | **Implemented.** Only the narrow librga compatibility shape is accepted; RGA3 continues to emit its direct R2Y mode. |
| P2 | Sequential hardware batching (`02e0554b1e66`, `0c1499fbace4`) | Correctness is already covered because the rewrite always advances a request one task at a time. Hardware batching is an optional performance optimization. |
| — | Acquire-fence race, failed-submit leak, discontinuous DMA IOVA, scale coefficient, R2Y bit shift, LUT validation | Already covered or independently superseded; retain tests, do not transplant. |
| — | RGA2 internal prefetch and tile4x4 fixes | Not active because the rewrite does not enable the affected prefetch path and rejects RGA2 non-raster input. They become prerequisites if those modes are added. |
| — | RGA2-Pro formats, AFBC32x8/RKFBC, secure mode, RK3538/RK3572 | Outside the current RK3588 RGA2E/RGA3 profile; add only for a demonstrated consumer requirement. |

The P0/P1 labels record implementation order, not evidence that an observed
rewrite failure already existed. Both rewrite tips pass the normal, memory, and
race clean-source build profiles. No rewrite kernel containing these commits
has completed the board hardware-validation gate yet.

## Implementation and host validation record

The implementation deliberately follows rewrite ownership rather than copying
the BSP objects:

- RK3588 quirks live in hardware match data. The RGA2E start path performs a
  bounded manual reset before programming a job when automatic reset is
  disabled.
- RGA2 config-error IRQ masks include flag bit 25, enable bit 26, clear bit 27,
  and parse-status register `0x024`. Raw IRQ/status words and the config-error
  count are exported for hardware evidence. The donor's `STATUS2` RPP failure
  is bit 0; the rewrite's earlier bit-2 interpretation was corrected as part of
  the same audit.
- Each userptr DMA view owns its boundary shadows. Only active bytes are copied
  before device sync and after CPU sync. Cross-core handoff syncs the mapping
  that actually ran, and inactive mappings cannot overwrite the result with a
  stale shadow. Route B retains a real DMA mapping for cache maintenance while
  separately providing the contiguous manual IOVA.
- The RGA3 CSC exception accepts only the known BT.709-limited R2Y flag shape;
  RGA2 and all other custom/full-CSC shapes keep their existing validation.
- KUnit covers quirk words, config masks/results, the boundary/overflow matrix,
  inactive-byte guards, and positive/negative CSC cases. The focused object
  build also passed `W=1`, and `checkpatch --strict` reported no findings.

The conformance fuzzer now sweeps every offset modulo a 64-byte cache line and
checks guard bytes on both sides of every source and destination range. When
the new debugfs counters exist, the harness also requires positive shadow
copy-to/copy-from deltas, zero active head/tail shadows after the run, and zero
shadow setup failures. The clean-source gate stores scratch trees under the
parent of this repository rather than filling `/tmp`.

Sections 1–4 below preserve the pre-implementation mismatch analysis and design
rationale. Statements about what the rewrite “currently” lacked refer to the
parent of `0d71ded1690c`, not to the implementation tips recorded above.

## 1. Represent RK3588 workarounds as match-data quirks

### Pre-implementation rewrite behavior

The rewrite probes only exact RK3588 hardware tuples:

- RGA3 `3.0.76831`; and
- RGA2E `3.2.63318`.

`rk_rga3_start_hw()` currently writes only `RK_RGA3_SYS_CTRL_CMD_MODE` to the
RGA3 system-control register. The 5.10 donor instead sets system-control bit 2,
`RGA_LGC_CLK_ON`, on RK3588. Rockchip describes this as a low-voltage
workaround.

`rk_rga2_start_hw()` currently builds its system-control word from
`AUTO_CKG | AUTO_RST | CMD_MODE`. The 5.10 donor marks RGA2E `3.2.63318` with
`DIS_AUTO_RST` and omits bit 5, `AUTO_RST`, because automatic reset can cause
RK3588 low-voltage timeouts. This is the exact RGA2E revision the rewrite
accepts, so the current unconditional bit is a direct mismatch.

### Required design

Add quirk flags to `struct rk_rga_hw_match`, for example:

- `RK_RGA_QUIRK_RGA3_LOGIC_CLK_ON`; and
- `RK_RGA_QUIRK_RGA2_DISABLE_AUTO_RST`.

Set them in the two RK3588 match records and derive the start-time
system-control words through small helpers. Match data is preferable to version
string comparisons or unconditional global behavior: it records why the bit is
present, keeps future hardware descriptions honest, and makes the result
unit-testable.

The RGA3 start word must preserve command mode and add bit 2. The RGA2 start
word must preserve automatic clock gating and command mode while omitting bit 5
for `3.2.63318`. Both values must be rebuilt for every start because the soft
reset paths clear system control.

Do not infer additional voltage-management policy. Clock rates, runtime PM,
regulators, and OPP selection remain owned by their existing public kernel
frameworks; these are narrow hardware register quirks.

### Verification

- KUnit: exact system-control word for each RK3588 match, plus a synthetic
  no-quirk match proving future hardware does not inherit either workaround.
- Build gate: normal, memory-debug, and race-debug rewrite profiles.
- Hardware: repeated RGA2 and RGA3 copy/scale/CSC loops at idle and load,
  suspend/resume between runs, no timeout/recovery/error-counter deltas, and
  register readback when safely available.

## 2. Add RGA2 config/parse-error interrupt support

### What 5.10 added

Commit `ae8e8c4da037` adds a previously unhandled RGA2 terminal error:

- interrupt flag bit 25: config error;
- interrupt enable bit 26;
- interrupt clear bit 27; and
- `RGA2_INTR_STATUS2` at system-register offset `0x024`.

The low status bits distinguish at least:

| Bit | Parse failure |
|----:|---------------|
| 0 | source and destination rectangles are not equal where equality is required |
| 1 | source-1 horizontal overlay bounds violation |
| 2 | source-1 vertical overlay bounds violation |
| 3 | source-1 odd-alignment violation |

The rewrite currently has no definitions for those bits. Its RGA2 enable,
clear, and error masks stop at the existing FBC/scale/MMU/bus errors, and
`rk_rga2_read_irq_status()` does not snapshot offset `0x024`. A hardware parser
rejection can therefore lack the immediate classified completion path added by
Rockchip and may be observed only as a generic error or timeout.

### Required design

1. Define the register and all config-error flag/enable/clear/status bits.
2. Include config error in `RK_RGA2_INT_ERROR_MASK`,
   `RK_RGA2_INT_CLEAR_MASK`, and `RK_RGA2_INT_ENABLE_MASK`.
3. Add a dedicated field such as `parse_status` to `struct rk_rga_job` and
   snapshot `RGA2_INTR_STATUS2` in `rk_rga2_read_irq_status()` before the IRQ is
   cleared.
4. Make config error a terminal IRQ that wakes the thread immediately. Map it
   to `-EACCES`, matching the donor's externally visible result, and retain the
   normal reset/recovery path used for other RGA2 hardware errors.
5. Record the raw interrupt and parse-status values in the rewrite debug event
   stream. Decode the four known causes for diagnostics, but preserve the raw
   word so unknown future bits are not hidden.
6. Include the config bit in spurious-IRQ recognition and clearing when no job
   is active.

Validation in the command generator remains the first line of defense. This
interrupt is still necessary because it catches generator defects, undocumented
hardware constraints, and malformed states that pass software validation.

### Verification

- KUnit: mask composition; synthetic config-error IRQ result; DONE+config-error
  precedence; all four status decodes; unknown status bits; and spurious IRQ
  recognition.
- Debug-only fault injection, if added: corrupt one safe command constraint and
  prove the job completes with an error rather than reaching the one-second
  timeout.
- Hardware conformance: normal RGA2 jobs must leave the config-error counter at
  zero; an injected parse error must not strand the active job or its release
  fence, and the next valid job must run after recovery.

## 3. Make userptr DMA cache-line safe with boundary shadows

### Why the existing Route B is not sufficient

The rewrite's userptr path correctly:

1. validates `size + page_offset` for overflow;
2. long-term pins the user pages;
3. creates an SG table for the requested byte range;
4. uses `dma_map_sgtable()` when it yields one safe span; and
5. otherwise maps the driver-owned pages into one contiguous system-IOMMU IOVA
   (Route B), with 32-bit span guards where required.

That solves address continuity. It does not isolate bytes that share the first
or last CPU cache line with an unaligned malloc-style buffer. The rewrite still
calls `dma_sync_sgtable_for_device()` and `dma_sync_sgtable_for_cpu()` on SG
entries backed by the original user pages. On non-coherent DMA, cache
maintenance and bounce-buffer handling operate at cache-line or larger
granularity. A partial head/tail fragment can therefore touch unrelated bytes
outside the userspace-requested range or trigger the small-fragment SWIOTLB
behavior addressed by the 5.10 series.

### Required ownership model

Do not replace pointers in `rk_rga_import.pages` in place as the BSP patch does.
The rewrite permits refcounted imports to outlive individual jobs and may create
per-core job mappings. Mutating the canonical pinned-page array would make
concurrent or rebound mappings share hidden state.

Instead, give every mapped userptr SG table an owned boundary-shadow object.
It should contain:

- the original pinned head/tail page references;
- separately allocated shadow pages;
- page indexes, active offsets, and active byte lengths;
- whether head and tail collapse to the same page;
- the SG table, DMA/IOMMU mapping state, and selected device it accompanies;
  and
- explicit initialization/active state so partial setup unwinds safely.

The canonical import continues to own and eventually unpin only the original
pages. An import mapping or `rk_rga_job_mapping` owns the SG table plus its
shadow object and frees/unmaps the shadows before dropping the import reference.
This matches the rewrite's existing per-device mapping lifetime.

### Boundary and mapping algorithm

Use `dma_get_cache_alignment()` and checked arithmetic:

1. `active_start = page_offset`, `active_end = page_offset + size`;
2. shadow the first page when `active_start` is not cache-line aligned;
3. shadow the last page when `active_end` is not cache-line aligned or the tail
   fragment is too small for safe DMA mapping;
4. allocate one shadow when head and tail are the same page; and
5. build the mapping SG table from shadow pages at the affected indexes and the
   original pinned pages for all interior indexes.

Preserve the active offset/length in the DMA-sync SG view. Route B may still
construct its existing page-aligned IOMMU mapping view and program the hardware
IOVA as `mapped_base + page_offset`, but any expanded head/tail coverage must be
backed by a shadow page rather than an original boundary page. Never expand a
DMA mapping or cache-maintenance range across inactive bytes in an original
user page. This is safer than mechanically copying the donor's intermediate
head/tail map-size branches, including the tail-size calculation corrected by
`31aa12084e3b`.

Route A and Route B must resolve to the same active hardware span even if their
mapping views differ. The usual command/image validation must still constrain
hardware to the requested bytes; the shadows isolate neighboring bytes within
a boundary page rather than authorizing access to them.

Allocate through normal page APIs and map through the selected device's DMA or
IOMMU API. Request DMA32 memory only for a path whose device mask and lack of an
IOMMU require it; do not make physical-address assumptions in common code.

### Synchronization order

The rewrite currently treats userptr mappings as bidirectional. Preserve that
conservative ABI behavior:

- before `dma_sync_sgtable_for_device()`, copy only the active head/tail bytes
  from original pages into shadow pages;
- after `dma_sync_sgtable_for_cpu()`, copy only the active bytes from shadow
  pages back into the original pages; and
- use `kmap_local_page()`/`kunmap_local()` for the CPU copies.

Copying only the active region is essential: bytes outside it belong to the
userspace allocation sharing that page and must never be overwritten from the
shadow. The copy and DMA-sync order must be wrapped in helpers so every normal,
error, timeout, and IOMMU-fault completion follows the same rule.

If direction-aware mapping is introduced later, source-only buffers need the
pre-device copy, destination-only buffers need the post-CPU copy, and buffers
used in both roles need both. Until then, bidirectional copy-in/copy-out is
safer and matches current behavior.

### Failure and concurrency requirements

- Partial shadow allocation or SG construction must restore no shared pointer:
  free only objects already owned by the new mapping and leave the canonical
  import untouched.
- DMA mapping failure, Route A rejection, Route B failure, command-generation
  rejection, close, timeout, fault recovery, and device removal must each
  unmap before freeing shadow pages.
- A single import can be rebound to another core; each mapping must use shadows
  appropriate to that core's DMA device.
- The completion sync must select only the mapping actually programmed for the
  chosen hardware. The current cache-only implementation can harmlessly sync
  both the canonical import mapping and a rebound job mapping; with shadows,
  copying back from an inactive mapping would overwrite the active result with
  stale data. Record the active per-import mapping in the job or filter both
  device and mapping identity on the CPU-sync path.
- Existing fences define ordering between dependent jobs. Simultaneous writes
  to the same imported bytes without a dependency remain a userspace data race;
  the shadow implementation must not add a global lock that serializes all
  unrelated userptr jobs.
- Add counters for active head/tail shadows, setup failures, and copied bytes so
  the hardware test can prove the path was exercised rather than merely passed.

### Verification

- KUnit boundary matrix: aligned start/end; unaligned head only; tail only;
  both; one-page collapse; exact page end; one-byte ranges; cache-line-sized
  tails; arithmetic overflow; and allocation failure at every step.
- KUnit data integrity: sentinel bytes before/after the active region remain
  unchanged for source, destination, and bidirectional copy sequences.
- KUnit lifetime: Route A, forced Route B, per-core rebind, command rejection,
  timeout cleanup, and import release all return mapping/shadow counters to
  zero.
- Hardware: extend the direct librga virtual-buffer suite with every
  `0..cache_alignment-1` head offset and representative tail offsets around a
  cache-line/page boundary. Compare active output and surrounding sentinels
  against the forward port, with forced Route B repeated on RGA3 and RGA2.

## 4. Accept the narrow RGA3 R2Y BT.709-limited compatibility shape

### Pre-implementation mismatch

Current librga may set `full_csc.flag` while requesting RGB-to-YUV BT.709
limited because RGA2E needs its full-CSC path for that conversion. RGA3 can
perform the conversion directly. Rockchip's 5.10 policy therefore ignores that
flag when evaluating RGA3 for this one R2Y mode.

The rewrite already decodes the R2Y selector correctly with
`yuv2rgb_mode >> 2`, and the RGA3 emitter can program its direct CSC mode.
However, `rk_rga3_validate_bitblt()` rejects every nonzero `full_csc.flag`.
The scheduler consequently excludes both RGA3 cores and needlessly routes the
job to RGA2, or rejects it if the caller forced an RGA3 core.

### Required design

Add a named predicate for an ignorable RGA3 compatibility flag. It must return
true only when:

- the full-CSC flag contains exactly the supported enable bit;
- the operation is R2Y BT.709 limited; and
- the otherwise selected RGA3 profile supports the source/destination formats
  and operation.

Use the predicate in RGA3 validation and nowhere in RGA2 validation. The RGA3
emitter must continue to use the direct `yuv2rgb_mode` conversion and must not
program the user-provided full-CSC coefficient block. Other full-CSC requests,
unknown flag bits, Y2R modes, and other R2Y standards remain rejected by RGA3
unless their real hardware path is implemented later.

This is a core-selection compatibility fix, not general RGA3 full-CSC support.

### Verification

- KUnit: BT.709-limited + enable flag admits RGA3 and emits the same direct CSC
  fields as the no-flag request.
- KUnit: the same request remains valid on RGA2's real full-CSC path.
- KUnit: BT.601 limited/full, Y2R, unknown flag bits, and arbitrary custom
  full-CSC requests remain rejected by RGA3.
- Hardware: compare RGA2 and RGA3 output against a software RGB-to-YUV BT.709
  limited reference and verify forced-RGA3/current-librga submission succeeds.

## 5. Changes the rewrite already covers

These donor changes are important regression oracles, but they do not require a
new implementation transplant.

| 5.10 change | Why no rewrite port is needed |
|-------------|-------------------------------|
| Acquire fence already signaled (`f7643d9a9d22`) | The rewrite checks fence status before registration, handles `dma_fence_add_callback()` returning `-ENOENT`, rechecks status, and balances its pending count. |
| Failed multi-task submit leak (`3727985456c1`) | Requests, jobs, imports, acquire fences, and release-fence reservations have explicit owners and rollback paths; retain allocation-failure KUnit coverage. |
| Reject discontinuous DMA IOVAs (`f2f903866ece`) | dma-bufs fail closed unless they form one safe span; driver-owned userptr pages use contiguous-IOMMU Route B when normal DMA mapping fragments the IOVA. |
| Bilinear scale-down guard (`864c7565ca65`) | `rk_rga2_scale_down_bilinear_protect()` independently reduces the coefficient until the final sample lies strictly inside the source limit and derives the active source width/height. |
| Correct R2Y bit shift (`e519206d10d9`) | The rewrite decodes R2Y from `yuv2rgb_mode >> 2` and has emission tests for that representation. |
| LUT/update-palette validation (`56de3c1ee427`) | The rewrite has separate update-palette validation and emission instead of applying generic source/destination checks to that command. |
| Sequential request correctness (`02e0554b1e66`) | The rewrite advances `current_task` only after the prior task completes and requeues between tasks, so dependent tasks cannot run concurrently even without consulting bit 6. |

The last row leaves a performance distinction: unflagged independent BSP tasks
can fan out across cores, while the rewrite serializes them too. A later
optimization may preserve the current serial path for
`IM_JOB_FLAGS_EXEC_SEQUENTIAL` and split unflagged requests into independently
owned jobs. Alternatively, RGA3 hardware command batching could reduce
per-command IRQ and power overhead for flagged requests. Either design needs
new release-fence aggregation, cancellation, error, and mixed-RGA2/RGA3 rules;
it is not a prerequisite for semantic correctness.

## 6. Changes that become prerequisites only with new features

### RGA2 internal IOMMU prefetch

Commit `e78e66240ba6` corrects internal RGA2 MMU prefetch thresholds. The rewrite
uses the Linux system IOMMU and does not currently enable that internal
prefetch-programming path. Do not add unused register writes. If internal
prefetch is enabled later, carry the corrected bound logic and add guard-page
tests before exposing it.

### RGA2 tile4x4 input

Commit `c2df109b01ad` zeros secondary input bases for tile4x4. The rewrite
currently rejects non-raster RGA2 sources, so it cannot reach the affected
command shape. Treat this fix as mandatory in the same change that introduces
RGA2 tile4x4 input.

### Formats, compression, secure mode, and extra SoCs

The 5.10 RKCFA/Y1/RGBA1010102/YUV101010/full-CSC-10-bit work and AFBC32x8
expansion are feature additions, not fixes to a rewrite path that claims to
support them. The rewrite deliberately targets RK3588 RGA2E/RGA3 and rejects
RGA2-Pro RFBC64x4/AFBC32x8 modes. Keep those boundaries explicit until a
current librga, FFmpeg, GStreamer, display, or NPU consumer demonstrates need.
RK3538/RK3572 match data is outside this target entirely.

## Implemented order and remaining acceptance gate

The rewrite adaptation was implemented as one reviewable kernel commit mirrored
across both rewrite branches, in this order:

1. add match-data quirks and both RK3588 system-control fixes;
2. add RGA2 config-error IRQ/status support;
3. add per-mapping userptr boundary shadows and instrumentation;
4. add the narrow RGA3 BT.709-limited compatibility predicate; and
5. extend KUnit/conformance for all four changes before considering batching or
   new formats.

The complete change passes the rewrite normal/memory/race clean-source build
profiles on both kernel lines. Device-free conformance validates the extended
fuzzer and counter wiring. It remains
**unvalidated** until a booted RK3588 run proves:

- both RGA3 cores and RGA2 execute ordinary jobs without new errors/timeouts;
- low-voltage/suspend-resume stress does not strand a job;
- injected RGA2 parse errors complete and recover immediately;
- unaligned userptr sentinels survive on Route A and forced Route B; and
- the forced-RGA3 BT.709-limited librga request is pixel-correct.

The source reconciliation is implemented. Only after those gates should the
rewrite status ledger describe it as hardware validated or conformant.
