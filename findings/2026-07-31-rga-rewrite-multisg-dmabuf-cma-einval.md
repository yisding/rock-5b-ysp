# RGA rewrite rejects legal multi-SG DMA-BUFs; the CMA `EINVAL` is a separate untraced failure

> Scope: [`kernel-drivers`](../kernel-drivers/README.md), specifically the
> RK3588 RGA rewrite DMA-BUF import/remap path exercised by
> [`rga-core-match-test`](../kernel-drivers/tests/rga-core-match-test.cpp),
> `rockchip-vaapi` export repacks, mpv presentation, and Main10 AFBC-to-P010
> conversion.
>
> Source: booted `6.18.41-video-rewrite-kasan-rockchip64 #21`, kernel source
> identity `rk3588-rewrite-6.18@06ab78b696157`; inspected source tree
> `~/Code/rock-5b/kernel/linux-6.18-rkvenc@a12e4116c758`, whose only changes
> after the booted pin are in `drivers/video/rockchip/mpp-rewrite/`, leaving
> `drivers/video/rockchip/rga-rewrite/rga_rewrite.c` identical. Primary anchors:
> `rk_rga_check_dma_sgt()`, `rk_rga_import_dmabuf_object()`,
> `rk_rga_job_map_import()`, `rk_rga_job_prepare_hw_mappings()`,
> `rk_rga_task_hw_type_mask()`, and `rk_rga_backend_start()`.
>
> Date: 2026-07-31
>
> Trust: **MEASURED** / **SOURCE-INSPECTED** / **ROOT-CAUSED** (system-heap
> multi-SG refusal) / **SOURCE-FIXED** / **BUILD-VERIFIED** /
> **RUNTIME-UNVERIFIED** / **HYPOTHESIS** (the exact CMA `EINVAL` branch) /
> **PARTIAL**.

> **Implementation follow-up — 2026-07-31:** the source fix is committed as
> forward-port `14c0456c4108`, rewrite 6.18 `995a0aa710fb`, and byte-identical
> rewrite mainline `168f5f4acfa9`. The forward objects compile, and both rewrite
> commits pass clean-archive normal and test-disabled builds of the IOMMU
> providers, MPP/RGA rewrite objects, and Rock 5B DTB with warnings fatal. The
> 148-case manifest is stable and the KUnit fixture audit passes. No fragmented
> DMA-BUF workload has run on those commits yet, so this finding does not claim
> hardware closure; the CMA branch remains unlocalized.

## Result

The RGA rewrite has one confirmed DMA-BUF mapping defect and one likely but
not-yet-localized sibling failure:

1. **Confirmed:** ordinary system-heap DMA-BUFs are legal scatter-gather
   allocations, but both the persistent import path and the selected-core
   per-job remap require `sg_table.nents == 1`. Real video/export workloads
   reached those checks with 8 and 15 mapped segments and were rejected. This
   is a rewrite-driver limitation, not allocator corruption and not an EGL or
   DRM-format problem.
2. **Open:** a direct 352x352 RGBA8888 copy using
   `/dev/dma_heap/default_cma_region` for both source and destination also
   failed and userspace reported `EINVAL`, but the capture did not identify the
   kernel return site. The source trace shows that the explicit multi-SG branch
   returns `-EOPNOTSUPP`, not `-EINVAL`, while RGA hardware errors are surfaced
   as `-EACCES` or `-EFAULT`. If `errno=EINVAL` came directly from the blit
   ioctl, the CMA failure is a separate pre-hardware rewrite validation,
   materialization, mapping, or command-emission defect.

The earlier description of the CMA probe as "unreliable" was imprecise. The
CMA allocator was not shown to be intermittent. The **probe was
non-discriminating**: it established only that the operation failed, not
whether CMA produced one mapped segment, which ioctl returned `EINVAL`, which
core was selected, or which driver stage generated the error.

The source alignment now removes the import-time one-segment rule, maps each
DMA-BUF only after the core and role are known, accepts verified-adjacent spans
directly, and feeds page-representable gaps to RGA2's internal MMU using the
selected device's DMA addresses. RGA3 still rejects a genuinely gapped mapped
view. That is the intended reconciliation with userspace: legal discontinuous
backing works on RGA2 without pretending every gapped attachment is a linear
RGA3 address range.

## Do not conflate these observations

| Observation | Proven meaning | Not proven |
|---|---|---|
| `expected one DMA segment, got 8, orig_nents=8` | The selected DMA attachment remained multi-SG and `rk_rga_check_dma_sgt()` refused it. | Nothing is wrong with the DMA-BUF or system heap. |
| The same message with 15 segments during mpv/export work | Fragmentation and allocation history can change the SG shape of otherwise equivalent logical buffers. | The media format or EGL importer caused the failure. |
| `default_cma_region` copy returned userspace `EINVAL` | The direct operation did not complete successfully. | That CMA was multi-SG; that import passed; that the kernel itself returned 22; or that the failure shares the system-heap cause. |
| DMA-API debug warning: mapped `DMA_TO_DEVICE`, synchronized `DMA_FROM_DEVICE` | The rewrite's persistent attachment direction/lifetime disagrees with later destination CPU access. | That this warning caused the CMA `EINVAL`. |
| Correct P010 plane descriptor plus Panfrost zero-copy GR1616 import | The earlier chroma-fourcc/EGL boundary is fixed. | RGA conversion/export repacks are reliable. |

## Evidence

### Boot and userspace identity

The measured host had the required video/DMA devices and was exercised outside
the filesystem/device sandbox:

```text
/dev/mpp_service
/dev/rga
/dev/dma_heap/system
/dev/dma_heap/default_cma_region
/dev/dma_heap/reserved
/dev/dri/renderD128
```

The relevant installed media stack included `rockchip-vaapi
1.0.11+ysp7-0ubuntu1~rk1`, `librga2
2.2.0+git20260725.26a50ef`, and the booted rewrite kernel named above. The
GR1616 exporter correction was independently observed reaching successful
Panfrost EGL import, so the RGA failures below occur at a different layer.

### System-heap multi-SG failures

The first synthetic NV12 export repack reached the host allocator and RGA, then
the kernel rejected its remap:

```text
rockchip_rga_rewrite: reject dma-buf remap DMA mapping:
expected one DMA segment, got 8, orig_nents=8
```

The mpv H.264 presentation path later hit the same refusal with 15 mapped
segments. From userspace this appeared as a failed RGA repack followed by a
surface-export/EGL-image failure. The different segment counts are expected for
system-heap allocations: one logical DMA-BUF can be backed by physically
discontiguous pages, and DMA mapping may coalesce some adjacent entries but is
not required to reduce the table to one entry.

The failure can depend on allocation history because the driver happens to
accept only the subset of system-heap allocations whose attachment coalesces
to a single mapped segment. A passing run therefore does not validate the
mapping design.

### Direct system/CMA discriminator

The tracked
[`rga-core-match-test`](../kernel-drivers/tests/rga-core-match-test.cpp)
allocates independent source and destination buffers, imports both through
librga, performs an RGBA8888 `imcopy()`, then checks the visible bytes under
DMA-BUF CPU-access brackets. The direct comparison used these logical cases:

```sh
rga-core-match-test /dev/dma_heap/system \
  /dev/dma_heap/system 352

rga-core-match-test /dev/dma_heap/default_cma_region \
  /dev/dma_heap/default_cma_region 352
```

Both operations failed and userspace reported `EINVAL`. The system case also
exposed the separate DMA-direction warning described below. The CMA terminal
capture did **not** preserve an ioctl trace, per-stage rewrite counters, selected
core, mapped `nents`, or a stage-specific kernel diagnostic. There is therefore
no licensed conclusion that CMA bypassed the one-segment check, nor that it
failed that check.

Raw terminal output from this narrow experiment was not committed. That
evidence gap is material and is the reason the first next step is a repeated,
fully captured differential rather than a source patch based on the presumed
CMA cause.

### The mapping-direction warning

The system-heap probe also triggered DMA-API debugging:

```text
device driver syncs DMA memory with different direction
mapped with DMA_TO_DEVICE, synced with DMA_FROM_DEVICE
```

The stack passed through `system_heap_dma_buf_begin_cpu_access()`. The source
explains the mismatch: `rk_rga_import_dmabuf_object()` creates a persistent
attachment and maps it `DMA_TO_DEVICE`, even though the imported object can
later be an RGA destination and then be read by the CPU. Per-job mappings do
choose `DMA_TO_DEVICE` for source-only imports and `DMA_BIDIRECTIONAL` for a
destination, but the persistent import mapping remains alive independently.

This is a rewrite-driver direction/lifetime bug even if it is not the cause of
the CMA `EINVAL`. A correct multi-SG fix must not retain the current mismatch or
silence DMA debugging without fixing ownership and synchronization.

## Why multi-SG DMA-BUFs are valid

A DMA-BUF is one logical allocation and synchronization object. It does not
promise physically contiguous backing. `/dev/dma_heap/system` normally
allocates pages that may appear as multiple entries in an attachment's
scatter-gather table:

```text
logical image
  -> DMA-BUF object
  -> attachment to the selected RGA device
  -> sg_table with N physical/DMA extents
  -> device-visible address mapping
```

`orig_nents` records the original SG entry count. `nents` records the mapped
DMA segment count after the DMA API has had an opportunity to merge entries.
Multiple mapped entries remain a supported DMA API result.

RGA3's image registers need a contiguous address range **from the device's
point of view**. They do not inherently require one physically contiguous RAM
extent. RGA2 has a different native representation: its internal MMU can walk
a driver-built page table whose entries are the mapped DMA pages supplied for
the selected RGA2 device.

The rewrite already creates a synthetic contiguous IOVA for driver-owned
USERPTR pages on an external-IOMMU RGA3 core. That Route B demonstrates the
required ownership bookkeeping, but it is not a drop-in DMA-BUF fix: the
exporter owns attachment mapping, staging, synchronization, and movement. The
rewrite currently has neither the RGA2 internal page-table path nor a separately
audited RGA3 response to a genuinely gapped exporter attachment.

## Source trace: confirmed system-heap defect

### 1. Persistent import rejects multi-SG before a job exists

Librga's `importbuffer_fd()` reaches `RGA_IOC_IMPORT_BUFFER`, then:

```text
rk_rga_ioctl_import_buffer()
  -> rk_rga_import_one()
  -> rk_rga_import_dmabuf()
  -> rk_rga_import_dmabuf_object()
  -> dma_buf_attach(map_hw->dev)
  -> dma_buf_map_attachment_unlocked(..., DMA_TO_DEVICE)
  -> rk_rga_check_dma_sgt(..., "dma-buf", ...)
```

`rk_rga_check_dma_sgt()` rejects every `sgt->nents != 1` with
`-EOPNOTSUPP`. This persistent attachment is described as a placeholder and as
proof that at least one RGA core can use the object. That design unnecessarily
turns one arbitrarily selected core's DMA mapping into an import-time global
admission rule, before the operation's source/destination role and scheduled
core are known.

### 2. The selected-core job remap repeats the restriction

Even an import that passes the placeholder map is attached again to the
scheduled core in `rk_rga_job_map_import()`:

```text
rk_rga_backend_start()
  -> rk_rga_job_prepare_hw_mappings()
  -> rk_rga_job_rebase_img_to_hw()
  -> rk_rga_job_map_import()
  -> dma_buf_attach(selected_hw->dev)
  -> dma_buf_map_attachment_unlocked(..., role_direction)
  -> rk_rga_check_dma_sgt(..., "dma-buf remap", ...)
```

This is the branch that emitted the measured `got 8` and `got 15` messages.
It discards the attachment and fails the job instead of selecting the
representation supported by the chosen core: a mapped-DMA page table on RGA2,
or a proven contiguous span on RGA3.

### 3. Userptr proves the ownership shape, not the DMA-BUF mechanism

`rk_rga_map_userptr_sgt()` first tries `dma_map_sgtable()`. If that does not
produce one usable segment, it abandons the normal DMA mapping and invokes
`rk_rga_map_userptr_sgt_iommu()` to create a driver-owned contiguous IOVA.
It records the domain, IOVA, size, and `iommu_mapped` state so cleanup can
reverse the mapping.

DMA-BUF job mappings record no alternative representation state. The root cause
of the confirmed system-heap refusal is the rewrite's unconditional
single-segment admission rule combined with the absence of any DMA-BUF-safe
multi-segment path. Reusing the USERPTR remapper without an exporter ownership
audit would replace one defect with another.

## Source trace: why CMA `EINVAL` is still open

For a 352x352 RGBA8888 copy, the request itself should fit both rewrite
backends:

- 352 exceeds RGA3's 68-pixel active-width floor;
- 352 is 16-aligned;
- active and virtual width/height are equal;
- source and destination are distinct single-plane objects;
- there is no scale, rotation, compression, pattern, or cross-plane alias;
- `352 * 352 * 4` is 495,616 bytes, exactly 121 base pages.

Static inspection gives these return-code discriminators:

| Stage | Relevant result |
|---|---|
| `rk_rga_check_dma_sgt()` sees `nents != 1` | `-EOPNOTSUPP`, with the segment-count log |
| Mapped segment is shorter than the DMA-BUF | `-EINVAL`, with a "segment too small" log |
| RGA IOVA exceeds the 32-bit span | `-EOVERFLOW`, with a span log |
| RGA2/RGA3 hardware reports an execution error | `-EACCES` or `-EFAULT` |
| Several layout, handle-resolution, geometry, rebasing, extent-building, and command-emission guards | bare `-EINVAL`, often without a diagnostic |

The legacy `RGA_BLIT_SYNC` ioctl returns its internal error directly. The newer
request ioctl instead converts any configuration/submit failure to `-EFAULT`
through `rk_rga_request_ioctl_ret()`. Librga can also translate or overwrite
`errno`. Therefore the saved userspace `EINVAL` is useful only after `strace`
identifies the ioctl that produced it.

If `strace` confirms that `RGA_BLIT_SYNC` itself returned `EINVAL`, the error is
pre-hardware and likely in the rewrite's compatibility/validation pipeline.
Because the geometry above is ordinary and `imcheck()` accepted it, that would
be a second rewrite-driver bug. The existing evidence is not sufficient to
choose among the silent branches.

## Boundary

- The system-heap multi-SG rejection is measured and source-root-caused. The
  implementation commits above are source-fixed and build-verified, but no
  fix has been boot-verified.
- The CMA operation is measured only as a userspace failure. Its attachment SG
  shape, failing ioctl, selected core, and kernel return site remain unmeasured.
- No evidence shows that `default_cma_region` is a flaky allocator. Conversely,
  no evidence proves it is a reliable workaround.
- The roleless persistent mapping that caused the DMA-direction mismatch has
  been removed in source, but a DMA-API-debug hardware run has not yet proved
  the warning absent or isolated it from the CMA `EINVAL`.
- A generic contiguous-IOVA DMA-BUF design still needs a DMA/IOMMU ownership
  audit. The implemented RGA2 path deliberately retains the exporter mapping
  and consumes its DMA entries; it does not program only the first address or
  blindly remap `sg_page()` entries.
- These results do not reopen the GR1616/Mesa issue. Correct GR1616 EGL import
  has been observed independently.

## Next steps

### 1. Re-run a captured heap/role/core differential before changing source

Run at least three iterations of each pair at 352x352:

```text
system -> system
CMA    -> CMA
system -> CMA
CMA    -> system
```

The mixed pairs distinguish a source mapping failure from a destination
mapping/direction failure. Add 64x64 and 68x68 controls, or an explicit core
selector in the direct probe, to distinguish RGA2 from RGA3 behavior. Keep the
ordinary 352x352 request as the no-scaling/no-minimum-width control.

For every individual operation capture:

1. `strace -f -yy -e trace=ioctl` so the failing ioctl and kernel errno are
   unambiguous;
2. a bounded kernel-journal window with a unique marker;
3. before/after `/sys/kernel/debug/rk_rga_rewrite` counters;
4. the probe's import messages, `imcheck()` status, `imcopy()` status, errno,
   and byte-comparison result;
5. source/destination allocation sizes and heap names.

The existing debugfs counters localize the stage without a kernel rebuild:

| Counter delta | Interpretation |
|---|---|
| `prepared_job_count` unchanged | Failure while resolving handles/imports or materializing plane layout. |
| Prepared increases, `scheduled_job_count` unchanged | Backend validation or core selection failed. |
| Scheduled and `dispatched_job_count` increase, `started_job_count` unchanged | Selected-core mapping, power, command allocation, or command emission failed. |
| Started increases | Hardware ran; inspect IRQ/fault/config counters and re-check whether userspace's `EINVAL` was translated. |

Also record per-core scheduled/dispatched/started counters to name the selected
RGA2/RGA3 instance.

### 2. Trace exact return values if counters do not isolate CMA

Use temporary kretprobes/fprobes, or a short-lived tracepoint patch when the
static functions are not probeable, on:

```text
rk_rga_ioctl_import_buffer
rk_rga_prepare_tasks_locked
rk_rga_task_hw_type_mask
rk_rga_job_prepare_hw_mappings
rk_rga_job_rebase_img_to_hw
rk_rga_job_map_import
rk_rga_job_emit_cmd
rk_rga_backend_start
rk_rga_ioctl_blit
```

Capture the function result, task/core identity, source/destination role,
DMA direction, attachment `nents`/`orig_nents`, first DMA address/length, and
required size. Do not leave unconditional per-frame logging in the production
driver; promote only stable counters or rate-limited failure diagnostics.

### 3. Bring RGA2 to parity before designing an RGA3 exporter remap

The maintained implementation sequence is now the
[RGA2 multi-segment parity plan](../kernel-drivers/rga/docs/rga2-multisegment-parity-plan.md):

1. retain only DMA-BUF identity/size at import and defer role-correct mapping to
   the selected job;
2. accept one segment or several proven-adjacent DMA segments directly;
3. on RGA2, keep a multi-segment attachment mapped and build the internal-MMU
   page table from its DMA addresses, including legitimate SWIOTLB addresses;
4. compose separate Y/UV/V imports into the one page-table address space
   available to each RGA2 hardware channel;
5. program and own the source0/source1/destination/else MMU tables through every
   completion and failure path; and
6. leave a genuinely gapped RGA3 exporter attachment fail-closed until a
   separate exporter-aware remap or copy design is audited.

This ordering satisfies ordinary system-heap userspace on the non-IOMMU core
without treating exporter pages as driver-owned USERPTR backing.

### 4. Treat the CMA result as a separate patch only after localization

Do not fold a guessed CMA fix into the multi-SG patch. Once the trace names the
branch:

- add the exact 352x352 CMA request as a KUnit validation/mapping fixture;
- add a live direct-copy regression on the selected RGA2 and RGA3 cores;
- return a semantically accurate errno and emit a stage-specific diagnostic;
- compare with the vendor/BSP driver's acceptance of the same wire request
  before calling it a rewrite compatibility defect.

If the failure instead proves to be a userspace/librga errno translation or
probe construction problem, fix that owner and retain the kernel differential
as the counterexample.

### 5. Verification gate for the eventual mapping fix

A complete gate should require all of the following on one booted debug kernel:

- system-heap multi-SG source-only, destination-only, and both-leg RGBA/NV12
  copies are content-exact;
- CMA controls are content-exact on every eligible core;
- repeated allocations under bounded memory pressure remain green regardless
  of `nents`;
- RGA2 and RGA3 cases both run, including the 64/68-pixel scheduler boundary;
- source, destination, bidirectional, in-place/alias refusal, timeout, abort,
  and core-removal cleanup cases leave zero active mappings/imports;
- no DMA-API direction warning, IOMMU fault, RGA parser/config error, timeout,
  KASAN report, lockdep report, or new fatal journal line;
- `check-driver-objects`, mpv H.264/Main10 presentation, and Firefox Main10
  playback stop failing at the RGA repack boundary;
- existing P010/NV15, librga smoke, MPP, ABI, recovery, and KUnit suites remain
  green.

Only after this gate should CMA be described as a control rather than a
workaround. The architectural success criterion is that ordinary legal
system-heap DMA-BUFs work independently of their physical fragmentation.
