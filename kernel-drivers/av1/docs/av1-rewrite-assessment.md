# RK3588 RKMPP AV1 clean-room rewrite assessment

> Scope: estimate and decompose the work required to add an RK3588 AV1
> backend to the existing clean-room `/dev/mpp_service` rewrite while keeping
> the current `mpp-rockchip` / `av1_rkmpp` userspace ABI.
>
> Date: 2026-07-17
>
> Source pins: `rk3588-rewrite-6.18@563f329dd8c4`,
> `rk3588-rewrite-mainline@856743fc3c3d`, and the current AV1 forward-port
> oracle `rkvenc-fwport-6.18@df0d7037213c`.
>
> Trust: CODE-INSPECTED for the implementation boundaries and current limits;
> MEASURED for the forward-port's bit-exact AV1 result; INFERRED for effort and
> schedule estimates.

> **Implementation update, 2026-07-26.** The 6.18 implementation is committed
> on the dedicated worktree branch
> `rk3588-rewrite-av1-6.18@e58c57e50d0a0`, based on the complete current
> `rk3588-rewrite-6.18@c5faabf9d00b0` line. The three AV1 commits are
> `3327030e09029` (backend and shared architecture),
> `a5624fa024766` (warning-clean KUnit fixtures), and `402fc9c0bd785`
> (ABI documentation and initial hardening), followed by adversarial-repair
> commit `e58c57e50d0a0`. Three independent hostile reviews covered
> concurrency/fault recovery, ABI/DMA safety, and backend-oracle/test
> completeness. Focused arm64 GCC `W=1`, Clang `W=1`, and all three
> clean-archive profiles pass; Clang retains one pre-existing oversized KUnit
> stack-frame warning. Five AV1 KUnit cases now compile, bringing MPP to 90
> cases and the combined suite to 237, but neither they nor the driver have
> been booted on the ROCK 5B. The matching mainline carry and all board gates
> below remain open; this is source/build verification, not hardware parity.

## Result

Adding AV1 to the clean-room RKMPP rewrite is **medium-hard but bounded**. It
is materially smaller than the original MPP rewrite and much smaller than the
RGA rewrite because the expensive shared machinery already exists and the AV1
block is a single decoder core with no RKVDEC2 CCU/link-table path.

Assuming one engineer working primarily on this task:

| Milestone | Engineering estimate | Completion boundary |
|-----------|----------------------|---------------------|
| First bit-exact decode | 3-5 focused working days | AV1 device binds, advertises `MPP_DEVICE_AV1DEC`, and the direct MPP differential test decodes a raster-output IVF stream bit-exact. |
| Rewrite-quality backend | 2-3 focused weeks | Class-aware registers, complete built-in fd translation, VSI fault integration, reset/timeout containment, KUnit coverage, and matching 6.18/mainline commits. |
| Contingency range | 3-4 weeks | Allows for AFBC, 10-bit, malformed-input, timeout, or IOMMU-fault behavior that requires board-debug iterations. |

In source/complexity terms, the expected increment is roughly one-quarter to
one-third of the existing MPP rewrite, not another full rewrite. This estimate
is not a delivery commitment; hardware iteration dominates the uncertainty.

### Implemented 6.18 result

| Assessed requirement | Result at `e58c57e50d0a0` |
|----------------------|--------------------------|
| Register classes | Sparse, lazily allocated VCD/cache/AFBC regions with checked span mapping; holes, crossings, wrap, and alignment errors fail closed. |
| Translation capacity and provenance | Dynamic import/binding storage; all 103 built-in AV1 translation entries; retained dma-buf provenance, same-buffer range checks, and final validation after userspace address offsets. |
| AV1 backend | `rockchip,av1-decoder`, client type 4, hardware ID `0x80019000`, three validated MMIO regions, deferred start, class-aware readback, and shared timeout/reset/abort scheduling. |
| IRQ lifecycle | Generic auxiliary-IRQ descriptors, primary VCD threaded completion, AFBC mask/ack before synchronization and power-down, and fault-owned completions that cannot be consumed as ordinary IRQ success. |
| VSI-IOMMU | Provider-aware Rockchip/VSI fault registration and matching teardown, unconditional refresh after DMA quiescence during fault recovery, quarantine on refresh failure, and Kconfig integration. |
| AFBC | Checked 8/10-bit layout arithmetic, field bounds, full worst-case buffer-capacity validation, binding-derived header/payload IOVAs, kernel ownership of derived registers, deterministic cleanup, and raster fallback. |
| Diagnostics and tests | Codec-neutral per-client/core counters plus five AV1 KUnit cases covering layout, lazy allocation, 103-entry metadata, post-offset provenance, exact AFBC capacities/alignment, hardware ID, and fault-owned completion. |

The implementation deliberately reuses the existing rewrite's job ownership,
DMA mapping, scheduler, timeout, reset, and debug infrastructure. It does not
import the BSP AV1 driver body.

## Why this is tractable

The existing `mpp-rewrite` already owns the difficult codec-independent work:

- fixed-width native/compat `MPP_IOC_CFG_V1` parsing and message validation;
- sessions, batch/session switching, staged/pending/active job ownership, and
  reset epochs;
- dma-buf import, contiguous 32-bit IOVA validation, fd-to-IOVA translation,
  register-address provenance, and mapping lifetime;
- per-core scheduling, platform removal, timeout/reset serialization, runtime
  PM, clocks, reset arrays, and generic IOMMU TLB flushing;
- differential-test plumbing, debugfs lifecycle counters, and 85 MPP KUnit
  cases.

AV1 does not need the most complicated codec-specific parts of the current
rewrite: RKVDEC2 SOFT/HARD CCU coordination, linked descriptor tables, peer-core
power ownership, resend recovery, decoder RCB scratch, or RKVENC2 DCHS/slice
handling.

The rewrite trees also already carry most non-backend AV1 infrastructure:

- the standalone `vsi-iommu` provider and its public fault/refresh hooks;
- the RK3588 base Hantro/VSI topology;
- a ROCK 5B board override that retypes the AV1 consumer to
  `rockchip,av1-decoder` with VCD, cache, and AFBC register banks;
- the three AV1 interrupts, clocks, resets, power domain, MPP service phandle,
  and taskqueue number;
- the `rockchip,av1-decoder` binding.

The two rewrite copies of `mpp_rewrite.c` at the pins above are byte-identical,
so the backend should be developed once and carried between the 6.18 and
mainline branches with only surrounding kernel/DT integration differences.

Most importantly, the AV1 forward-port is a working behavioral oracle. On the
ROCK 5B it advertised `MPP_DEVICE_AV1DEC` with hardware ID `0x80019000` and
decoded 30/30 frames bit-exact against the software reference. The rewrite
does not have to infer the happy-path register ABI from an unproven donor.

## Required implementation work

### 1. Register classes need a real representation

The AV1 MPP ABI exposes three logical register classes:

| Class | Userspace offset range | Physical bank |
|-------|------------------------|---------------|
| VCD | `0x00000..0x007fc` | decoder core |
| cache | `0x10000..0x10294` | decoder cache |
| AFBC | `0x20000..0x2034c` | AFBC post-processor |

The current rewrite materializes all requests in one flat register image capped
at 128 KiB (`0x20000`). An AV1 AFBC word can end at `0x20350`, so the existing
representation cannot hold a valid complete AV1 job.

Raising the limit alone is a poor long-term fix. A four-byte request at a high
AV1 offset would allocate roughly 132 KiB, and a multi-session batch could
multiply that sparse allocation. The preferred rewrite design is a small
class/region descriptor table with lazily allocated dense storage per touched
class. Absolute ABI offsets should be translated to `(region, local offset)`
for copying, validation, fd translation, MMIO write/readback, and offset lookup.
RKVENC2/RKVDEC2 can remain a single region through the same abstraction.

Class validation must reject holes between these ranges and requests that wrap,
are unaligned, or cross a class boundary incorrectly. A request spanning two
valid classes may be split only after each resulting span is independently
bounded; this is where the donor BSP previously had high-severity bugs.

### 2. Translation state must grow without weakening provenance

The AV1 donor uses three built-in fd-translation tables:

| Class | Built-in entries |
|-------|-----------------:|
| VCD | 67 |
| cache | 24 |
| AFBC | 12 |
| **Total** | **103** |

The rewrite currently caps translation tables, register bindings, offsets, and
job-held import slots at 80. AV1 therefore cannot be supported by merely adding
the donor tables.

The clean option is dynamically sized, overflow-checked translation/binding
storage bounded by the validated backend tables plus the permitted userspace
extension. At minimum, any new fixed bound must be explicitly large enough for
all 103 mandatory AV1 entries and tested at the exact boundary.

The rewrite's existing security property must remain intact: every translated
address retains its dma-buf/import provenance until completion, cumulative
embedded plus explicit offsets stay within that import, and `REG_FD_NO_TRANS`
literal IOVAs are admitted only when they fall inside a session mapping owned by
the selected AV1 DMA device.

### 3. Add a single-core AV1 backend

The backend should add:

- an `rk_mpp_hw_match` for `rockchip,av1-decoder`, client type 4, expected
  hardware ID `0x80019000`, three required MMIO regions, and the AV1 backend
  operations;
- exact VCD/cache/AFBC minimum sizes and a three-region request mapper;
- the 67/24/12 mandatory translation tables, applied once per valid class;
- start-register deferral at VCD offset `0x0004`, followed by the same
  write-memory-barrier/start ordering used by the working forward-port;
- class-aware readback with the latched VCD interrupt word substituted for the
  cleared hardware status register;
- cache completion cleanup and error-mask-driven reset handling;
- normal scheduling, timeout, removal, and session-abort behavior through the
  existing single-core rewrite machinery.

The existing hardware object already maps up to four MMIO resources. Its match
metadata currently describes only one minimum register size, however, so probe
validation should become per-region rather than checking region zero and merely
accepting any additional regions.

### 4. Add the AV1 IRQ shape

The rewrite hardware object currently retains one primary IRQ. The AV1 backend
needs the main VCD completion/error IRQ and should preserve the current hardened
forward-port's AFBC acknowledgement handler. The cache IRQ is described by DT
but is not an active completion path in the inspected driver.

The clean representation is an optional per-backend IRQ descriptor array, not
AV1-specific fields in the shared object. The primary VCD IRQ participates in
the existing active-job/timeout state machine. The AFBC handler only
acknowledges AFBC state while runtime PM says the device is active and must be
synchronized before clocks are disabled or the device is removed.

### 5. Complete VSI-IOMMU integration in the rewrite

The provider and public `vsi_iommu_*` hooks are already present, and generic
dma-buf/DMA mapping plus `iommu_flush_iotlb_all()` works for the happy path.
The current MPP rewrite nevertheless registers fault callbacks only through
`rockchip_iommu_set_fault_handler()`. An AV1 device behind VSI-IOMMU would fail
that probe.

Fault registration/unregistration should select the provider explicitly:

1. try the Rockchip provider hook;
2. on provider mismatch, try `vsi_iommu_set_fault_handler()`;
3. fail closed when a paging domain exists but neither unregisterable provider
   hook owns it.

The selected provider type should be retained in `rk_mpp_hw` so teardown clears
the same hook. Reset/fault recovery should use generic TLB flushing where that
is sufficient and `vsi_iommu_refresh()` only when the provider needs a hardware
disable/re-enable cycle. Kconfig must guarantee VSI-IOMMU is present when the
ROCK 5B RKMPP AV1 node is enabled independently of Hantro.

### 6. Reimplement AFBC with checked arithmetic

The donor derives AFBC programming from VCD width, height, bit-depth, virtual
padding, configuration, and output-buffer registers. This is small in line
count but is the highest-risk AV1-specific logic.

The rewrite should not reproduce its unchecked arithmetic literally. It must:

- use checked width/height/padding/stride/header-size calculations;
- validate field widths before packing AFBC registers;
- derive header and payload IOVAs from the translated output binding, not from
  an unproven 32-bit literal;
- prove both derived spans remain inside the retained dma-buf mapping;
- handle 8-bit and 10-bit output explicitly;
- acknowledge or disable AFBC state deterministically on completion, timeout,
  reset, and removal.

Raster output should land first. AFBC should become required before declaring
feature parity because it is part of the current FFmpeg/RGA zero-copy path.

### 7. Keep diagnostics codec-neutral

The current per-core debug counters are split into RKVENC and RKVDEC arrays.
AV1 will still increment aggregate counters, but useful validation needs a
named AV1 row or a codec-neutral `(device type, core id)` counter layout. The
same applies to state dumps and lifecycle event names. This is not required for
first decode, but it is required for evidence that an AV1 test actually reached
hardware and for fault/timeout attribution.

## Validation sequence

The rewrite itself still lacks a booted conformance record. Baseline it before
adding AV1 so shared-service failures are not confused with backend failures.

### Gate 0: existing rewrite baseline

1. Boot the current rewrite without an AV1 backend.
2. Run the required H.264/H.265/VP9 MPP, FFmpeg, GStreamer, and RGA suites.
3. Save counters, artifacts, kernel logs, and forward-port comparisons.

### Gate 1: device and direct MPP decode

1. Confirm `/proc/mpp_service/supports-device` advertises AV1DEC and hardware
   ID `0x80019000` only after the AV1 core, VSI provider, clocks, resets, MMIO,
   and primary IRQ are valid.
2. Use a from-source `mpp-rockchip` that actually registers the AV1 parser; the
   historical distro library did not.
3. Run `mpi_dec_test -t 16777224` against the same generated IVF asset used by
   the forward-port oracle.
4. Require full frame count and infinite-PSNR/bit-exact output through
   `decode-differential.sh`.

### Gate 2: format and application coverage

- 8-bit and 10-bit AV1;
- raster output and AFBC output;
- IVF plus MP4 `av1C` and Matroska `CodecPrivate` inputs;
- `ffmpeg-rockchip av1_rkmpp` null decode and PSNR comparison;
- AV1 decode -> RGA scale/format conversion -> H.264 and HEVC encode;
- FFmpeg decoder `afbc=off`, `afbc=on`, and `afbc=rga` modes where supported;
- GStreamer AV1 decode/transcode when the selected plugin/runtime advertises
  the path.

### Gate 3: lifecycle and recovery

- repeated short streams, EOS/drain, reset, close with queued/active work, and
  parallel sessions;
- malformed, boundary, cross-class, and high-offset register requests;
- allocation/usercopy fault injection at class and binding allocations;
- forced 500 ms timeout and successful subsequent decode;
- VSI IOMMU fault attribution, IRQ masking/refresh, exact-job completion with
  `-EIO`, and successful subsequent decode;
- unbind/rebind with no stale IRQ, mapping, work item, runtime-PM, or session
  references;
- KASAN, KCSAN/lockdep, and warning-free focused builds on both rewrite pins.

## Recommended implementation order

1. Introduce codec-neutral class-aware register images and per-region probe
   validation, retaining single-region behavior for RKVENC2/RKVDEC2.
2. Make translation/binding/import tracking dynamically sized or raise all
   related bounds coherently, with exact-boundary KUnit coverage.
3. Generalize provider fault registration to Rockchip and VSI IOMMUs.
4. Add the raster-only AV1 backend and reach direct bit-exact decode.
5. Add checked AFBC programming and its auxiliary IRQ lifecycle.
6. Extend debug counters and the existing AV1 diagnostic suite into required
   rewrite-vs-forward-port evidence.
7. Carry the identical backend commit to mainline, build both clean-source
   profiles, then run the full board gates.

This order keeps the first three commits independently useful and reviewable;
they improve the shared rewrite rather than hiding AV1 exceptions inside the
backend.

## API choice boundary

This assessment is specifically for RKMPP compatibility. If the only goal is
hardware AV1 playback, the existing Hantro/Verisilicon V4L2 stateless driver is
the smaller kernel-side path. It uses a different userspace contract and does
not make `av1_rkmpp` work.

For the current FFmpeg/Kodi/MPP/RGA stack, the RKMPP rewrite backend is the
relevant path because libmpp already supplies the AV1 parser/HAL and register
recipes. The RKMPP and Hantro drivers cannot bind the AV1 hardware
simultaneously; the board DT must continue to choose one consumer model.
