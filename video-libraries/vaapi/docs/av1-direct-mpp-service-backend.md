# Direct AV1 submission from `rockchip-vaapi` to `/dev/mpp_service`

The vendor-kernel AV1 path can plausibly bypass userspace `librockchip_mpp` and
submit hardware jobs directly from `rockchip-vaapi`. This is a serious
RK3588-specific backend candidate, not merely an OBU-reconstruction experiment.
It would, however, replace the AV1 portion of libmpp rather than make that work
disappear: the VA driver would own the parsed-picture-to-register compiler,
per-surface decode state, DMA-BUF allocation, task submission, and recovery.

The recommended boundary is:

```text
standard VA AV1 buffers
  -> immutable, validated RKAV1Picture
  -> VDPU383 job compiler
       -> hardware parameter/global-header buffer
       -> canonical hardware tile stream
       -> VCD/cache/AFBC register banks
       -> DMA-BUF fd + offset fixups
  -> minimal /dev/mpp_service transport
  -> kernel DMA-BUF translation, scheduling, IRQ/status, and reset
  -> current VA surface pixels + surface-keyed AV1 reference state
```

This document is a **SOURCE-INSPECTED / INFERRED / DESIGN** result dated
2026-07-29. No direct `rockchip-vaapi` AV1 job has been submitted. AV1 must
remain unadvertised until the replay, conformance, recovery, application, and
sandbox gates below pass.

The inspected source pins are recorded in
[`docs/source-trees.md`](../../../docs/source-trees.md):

- `yisding/mpp` `ysp/main@3381fd2c9a0099135a94852c9434b47075458de1`;
- forward-port kernel `rk3588-video-6.18@12a7da02bea835e5f7024c42073bb84eb682fd99`;
- `yisding/rockchip-vaapi` AV1 plan at
  `4d98eca2c76a007bc46523a26d39f3043d80ec52`.

## Fast re-entry

| Question | Go to | Load-bearing fact |
|----------|-------|-------------------|
| What does “direct” mean? | [Device interfaces](#device-interfaces-do-not-conflate-them) | `/dev/mpp_service` bypasses userspace libmpp, not the kernel MPP framework. |
| What still has to be implemented? | [Transferred responsibilities](#what-bypassing-libmpp-transfers) | Register construction, hardware stream packing, auxiliary state, allocation, and recovery move into the VA backend. |
| How can stock libva work without `refresh_frame_flags`? | [Surface-keyed state](#surface-keyed-state-removes-the-refresh-mask-requirement) | Persistent CDF, segmentation, and motion state follows explicit VA surfaces rather than abstract AV1 DPB slots. |
| Where should the code boundary be? | [Backend structure](#backend-structure) | Keep picture translation, VDPU383 compilation, and ioctl transport separate. |
| Which vendor route costs less? | [Backend comparison](#backend-comparison) | Direct replay is the cheapest first hardware proof; a maintained parsed MPP API is the lower-cost production implementation when it can be carried. |
| Why not use V4L2 instead? | [Backend comparison](#backend-comparison) | V4L2 is the mainline destination, but this image exposes vendor AV1 through MPP service and the current V4L2 driver consumes the missing refresh mask. |
| What is the first proof? | [Implementation sequence](#implementation-sequence) | Replay one normalized, known-good libmpp hardware job through a standalone direct transport. |
| What remains unknown? | [Open discriminators](#open-discriminators) | Tile-stream layout, exact state transitions, output layout, film grain, resource ceilings, and recovery all need measured answers. |

## Current evidence boundary

Three statements must remain separate:

1. **MEASURED:** the RK3588 AV1 block, hybrid VSI-IOMMU integration, vendor
   `mpp_av1dec` kernel backend, and ordinary libmpp/FFmpeg path decoded AV1
   bit-exact on the 2026-07-04 `P1c9d` image. The kernel evidence is owned by
   [`kernel-drivers/av1/`](../../../kernel-drivers/av1/README.md).
2. **SOURCE-INSPECTED:** `/dev/mpp_service` accepts register-class messages,
   translates DMA-BUF fds at known address registers, schedules the job, and
   returns hardware status. The AV1 userspace HAL already turns an internal
   parsed-picture structure into those messages.
3. **DESIGN:** `rockchip-vaapi` can replace the AV1 parser/HAL/OSAL slice with a
   checked direct backend and key persistent decode state to VA surfaces.

The first statement proves the hardware endpoint and kernel path. It does not
prove the direct transport, the VA-to-hardware translation, or the proposed
surface-state semantics.

## Device interfaces: do not conflate them

| Interface | Meaning here | Verdict |
|-----------|--------------|---------|
| `/dev/mpp_service` | Vendor MPP kernel framework. Userspace submits register banks, DMA-BUF fds, offsets, and status-read requests. | Credible first vendor backend on the present image. |
| `/dev/video*` plus media requests | Upstream stateless V4L2 AV1. Userspace submits parsed AV1 controls; the kernel owns register programming. | Preferred long-term ABI, but the current development image has no VPU981 AV1 video node and the inspected driver consumes `refresh_frame_flags`. |
| `/dev/dma_heap/*` or DRM render allocation | Possible source of DMA-BUFs for output, stream, and auxiliary storage. | Needed for an AV1 path with no runtime libmpp allocation dependency. Hide behind a generic allocator. |
| `/dev/rga` | Optional output conversion/post-processing. It is not an AV1 decoder interface. | Reuse only for a measured native-layout-to-NV12/P010 conversion or a separate display stage. |
| `/dev/mem` or userspace MMIO | Raw physical register access outside the codec scheduler and IOMMU import contract. | Not an acceptable design. |

Calling the first route “bypassing MPP entirely” is imprecise. It bypasses the
userspace MPI/parser/HAL library while retaining the kernel MPP service and its
AV1 hardware driver.

## The actual `/dev/mpp_service` contract

The userspace/kernel division is already sharp:

- libmpp parses codec syntax, manages frame/reference slots, allocates buffers,
  builds the hardware parameter block and register recipe, and submits it;
- the kernel validates the message shape and register classes, copies the
  requested register ranges, translates designated DMA-BUF fd registers to
  IOVAs, applies registered offsets, schedules the device, handles completion,
  and returns selected registers.

The common transport is one ioctl number, `MPP_IOC_CFG_V1`, carrying one or
more `MppReqV1`/`mpp_request` messages. The command families needed by a direct
backend are:

- query command and hardware support;
- initialize the AV1 decoder client (`VPU_CLIENT_AV1DEC`, value 4 in the
  inspected userspace definitions);
- write register ranges;
- request register readback;
- associate byte offsets with fd-bearing registers;
- send the accumulated task;
- poll for hardware completion or IRQ status;
- reset the session and release imported fds when required.

The direct-ioctl shape and `MULTI_MSG`/`LAST_MSG` rules are documented in
[`mpp-ioctl-batch-mode.md`](../../../vendor-libraries/mpp/docs/mpp-ioctl-batch-mode.md).
A normal task batches its register writes, readbacks, and offset fixups into
one request array, marks the final message as the task boundary, submits once,
then polls once.

The AV1 kernel backend divides the register address space into three classes:

| Class | Userspace offset range | Role |
|-------|------------------------|------|
| VCD | `0x0000`–`0x07fc` | Decode core, stream, references, working buffers, start, and primary status. |
| Cache | `0x10000`–`0x10294` | AV1 cache-side controls and address registers. |
| AFBC | `0x20000`–`0x2034c` | AFBC/post-processing controls and buffers. |

`mpp_av1dec.c` function `av1dec_extract_task_msg()` checks alignment,
overflow, request counts, and class overlap before copying register messages.
`av1dec_alloc_task()` then translates fds only at the driver's pinned address
register tables and adds separately supplied offsets. This is useful kernel
containment, but it is not picture-level AV1 validation: userspace still
decides the semantic content of the register recipe.

The inspected kernel also sets `AV1DEC_SESSION_MAX_BUFFERS` to 40. A direct
backend must therefore prove its import/release behavior under a browser-sized
surface pool; it cannot assume every pixel and auxiliary buffer can remain
cached in one session indefinitely.

## Why the direct backend fits the VA boundary

The normal packet decoder fails because stock VA clients provide parsed AV1
state and headerless tile data, while public MPP accepts complete OBU packets
and runs its own parser. Recreating the complete original OBU stream is not a
sound stock-client solution because libva omits original header bytes and
`refresh_frame_flags`.

The internal MPP boundary is different. The parser emits
`DXVA_PicParams_AV1`, and the AV1 HAL consumes that parsed structure plus frame
slots and buffers. That demonstrates that the hardware recipe can be generated
from effective picture state without feeding a second packet parser.

The direct route exploits that boundary:

```text
VADecPictureParameterBufferAV1
VASliceParameterBufferAV1[]
VASliceDataBufferType bytes
explicit destination/reference VASurfaceIDs
        |
        v
checked RKAV1Picture + RKAV1Tile[]
        |
        v
VDPU383 compiler formerly reached through MPP parser + HAL
```

It therefore avoids both unsound OBU reconstruction and coordination on a new
public MPP API. Its cost is ownership of the relevant HAL behavior.

## Backend structure

The backend should have three independent layers.

### 1. Neutral AV1 picture translation

This layer is hardware- and transport-independent:

```c
struct RKAV1Picture {
    uint32_t abi_version;
    uint32_t coded_width;
    uint32_t coded_height;
    uint8_t bit_depth;

    RKAV1FrameSyntax frame;
    RKAV1Tile *tiles;
    size_t tile_count;
    uint8_t *tile_bytes;
    size_t tile_bytes_size;

    RKSurfaceGeneration *destination;
    RKSurfaceGeneration *references[8];
};
```

The exact public structure can differ, but it must be immutable after
`EndPicture`, size/version tagged, dynamically sized for tiles, and contain no
borrowed client pointers. Every field must have one of four documented
origins:

- copied and range-checked from standard VA parameters;
- copied from a referenced surface's stored AV1 metadata;
- canonically derived from supplied effective state;
- unavailable, with any dependent feature rejected.

It must not expose MPP's private `DXVA_PicParams_AV1` as the driver contract.
That structure is useful as a differential oracle, not a stable ABI.

### 2. VDPU383/VDPU384b job compiler

This layer accepts the neutral picture and explicit buffer roles, then emits a
deterministic hardware job:

```c
struct RKAV1HwJob {
    RKRegisterBank vcd;
    RKRegisterBank cache;
    RKRegisterBank afbc;
    RKAddressFixup *fixups;
    size_t fixup_count;

    RKNativeBuffer parameter_buffer;
    RKNativeBuffer stream_buffer;
    RKAV1SurfaceState *destination_state;
};
```

It owns:

- effective AV1 syntax to hardware-parameter/global-header packing;
- tile validation and canonical hardware stream construction;
- fixed register templates and feature-dependent fields;
- destination/reference pixel addresses;
- CDF, segmentation, colmv, and other working-buffer selection;
- reference scaling and format metadata;
- status masks and hardware error classification;
- hardware-generation dispatch selected from a runtime hardware-ID query.

The compiler should be runnable in a host unit test without opening a device.
Its output must use symbolic buffer roles plus offsets until the transport
binds actual fds. No VA client value may become an unchecked register word,
allocation size, shift count, or array index.

### 3. Minimal MPP-service transport

This layer knows the kernel UAPI but no AV1 syntax. It:

1. opens `/dev/mpp_service`;
2. probes supported commands and hardware identity;
3. initializes an AV1 decoder session;
4. binds each symbolic buffer role to an owned DMA-BUF fd;
5. builds checked register-write, register-read, and address-offset requests;
6. submits exactly one bounded task;
7. polls with a deadline;
8. returns normalized completion/error status;
9. resets or quarantines the context after timeout/device errors; and
10. releases imports before the session buffer ceiling is exhausted.

Keeping the transport codec-blind makes the dangerous ABI code small and
allows captured jobs to test it before the VA translator exists.

An illustrative backend vtable is:

```c
struct RKAV1BackendOps {
    VAStatus (*probe)(RKAV1BackendCaps *caps);
    VAStatus (*create_context)(RKAV1Context **context,
                               const RKAV1BackendConfig *config);
    VAStatus (*submit)(RKAV1Context *context,
                       const RKAV1Picture *picture,
                       RKSurfaceFence *completion);
    VAStatus (*reset)(RKAV1Context *context);
    void (*destroy)(RKAV1Context *context);
};
```

The neutral frontend can later feed a public parsed-picture MPP API or V4L2
Request backend without changing VA buffer ingestion.

## Surface-keyed state removes the refresh-mask requirement

### What the existing HAL does

The inspected AV1 HAL already allocates the large hardware state buffers by
frame slot:

- `vdpu38x_av1d_cdf_setup()` sizes one CDF-plus-segmentation buffer per frame
  slot;
- `vdpu38x_av1d_colmv_setup()` sizes one colmv buffer per frame slot;
- `vdpu383_av1d_gen_regs()` supplies current and referenced frame-slot buffers
  to the hardware.

The missing `refresh_frame_flags` is used separately to update a small,
eight-entry logical-reference metadata table containing CDF validity and the
default coefficient-CDF bucket. It is needed because MPP's parser maintains
the codec's abstract eight-slot DPB.

### Replace logical slots with explicit surface generations

VA clients name destination and reference surfaces on every submitted picture.
The direct backend can attach the hardware state to those concrete surface
generations:

```c
struct RKAV1SurfaceState {
    uint64_t surface_generation;

    RKNativeBuffer pixels;
    RKNativeBuffer cdf_and_segid;
    RKNativeBuffer colmv;

    RKAV1StoredFrameMetadata frame;
    uint8_t coefficient_cdf_bucket;
    bool cdf_valid;

    RKSurfaceFence completion;
    enum {
        RK_AV1_STATE_PENDING,
        RK_AV1_STATE_READY,
        RK_AV1_STATE_FAILED,
    } status;
};
```

For each picture:

1. Acquire strong references to the exact destination and reference surface
   generations named by the VA request.
2. Reject stale, failed, format-incompatible, or unresolved reference
   generations.
3. Wait for every required reference fence before its pixels or auxiliary state
   can be read.
4. For a key frame or `PRIMARY_REF_NONE`, select the pinned default CDF state.
5. Otherwise map `primary_ref_frame` through the named-reference index to the
   referenced surface and load that surface's CDF/segmentation metadata.
6. Give the hardware distinct output buffers for the destination surface's
   pixels, CDF/segmentation state, and colmv state.
7. On successful completion, atomically mark the destination pixels and AV1
   state ready.
8. On any error, mark the generation failed and publish none of its state.

There is no abstract DPB update at this boundary. If a future picture can use
the decoded frame, its VA parameters name the corresponding surface. If the
frame was not retained by the client, no future request can name it. This
removes the synchronous need to know which internal AV1 slots were refreshed.

This is a design conclusion, not yet a conformance result. Differential tests
must cover at least:

- key, intra-only, inter, and switch frames;
- primary-reference selection through every named reference;
- `disable_cdf_update` and `disable_frame_end_update_cdf`;
- segmentation-map inheritance and disabled updates;
- order hints, reference scaling, and frame-size changes;
- hidden reference frames;
- destination-surface reuse and generation rollover;
- failure before and after hardware start.

When frame-end CDF updates are disabled, the backend must explicitly construct
the state that a later reference should observe; it must not assume the
hardware wrote a new CDF buffer. An implementation may copy or alias a prior
immutable/default state, but that choice must follow the AV1 semantics and
match the ordinary MPP path.

### `show_existing_frame`

If the client resolves `show_existing_frame` without submitting a VA decode
job, the driver does nothing: it exports or displays the already-ready surface
and state remains unchanged.

If a client submits a show-existing form through VA, reject it until that call
shape and its destination/reference semantics are captured and tested. Do not
invent a decode job or mutate state merely to make the request appear
successful.

### Film grain and two outputs

The current MPP common register setup explicitly programs
`av1_fgs_en = 0`. A direct backend must therefore begin by rejecting
driver-applied film grain. It must not return grained pixels as the ungrained
reference surface.

Production support requires a measured implementation of the two-surface VA
contract:

- ungrained decoded pixels and reference state attached to `current_frame`;
- separately grained pixels attached to `current_display_picture`.

That may eventually use hardware, GPU, or a separate validated grain stage.
Until then, advertise no combination that asks the VA driver to apply grain.

## What bypassing libmpp transfers

The direct backend would own the following work now performed by libmpp:

| Responsibility | Evidence in the inspected MPP path | Direct-backend consequence |
|----------------|------------------------------------|----------------------------|
| Parsed syntax normalization | AV1 parser produces `DXVA_PicParams_AV1` | VA translator must provide every hardware-relevant effective value or reject the feature. |
| Parameter/global-header packing | `hal_av1d_com.c` writes a large bit-packed hardware parameter block | Port into the deterministic job compiler and differential-test every field family. |
| Input stream layout | Parameter block includes `frame_header_size`, tile rows/columns, and `tile_sz_mag` | Build a canonical hardware stream from VA tile bytes and prove what prefix/size fields the core requires. |
| Pixel reference routing | `vdpu383_av1d_gen_regs()` maps frame slots to current/reference address registers | Bind explicit VA surface generations to register buffer roles. |
| CDF/segmentation state | Per-frame-slot CDF/segid buffers plus logical reference metadata | Use per-surface state and prove all update-disabled cases. |
| Motion-vector state | Per-frame-slot colmv buffers | Allocate and retain colmv with the corresponding surface generation. |
| Working buffers | HAL allocates parameter, RCB, default/state, optional origin/downscale, and generation-specific working storage | Inventory and size every buffer with checked arithmetic and hard caps. |
| Register generation | VDPU383 and VDPU384b HALs emit several register ranges and readbacks | Own pinned register definitions and dispatch only on recognized hardware IDs. |
| DMA-BUF wrappers and cache sync | MPP buffer APIs allocate/import/synchronize buffers | Introduce a generic owned DMA-BUF abstraction and issue the required CPU/device synchronization. |
| Submission and polling | MPP device OSAL assembles and sends the request array | Implement the small transport described above. |
| Fast mode and concurrency | MPP retains multiple register/buffer sets for overlapping work | Start serialized per context; add overlap only after dependency and teardown tests. |
| Timeout and recovery | MPP/kernel cooperate on poll, session reset, and import lifetime | Add bounded waits, fail-closed quarantine, reset tests, and fd release. |

The kernel still owns IOVA creation and hardware scheduling. Userspace places
DMA-BUF fds in designated registers and supplies offsets; `mpp_av1dec` performs
the fd-to-device-address translation.

## DMA-BUF and existing driver integration

The present driver uses `MppBuffer`, `MppFrame`, and MPP buffer groups across
decode pools, surfaces, mapping, export, and conversion. Merely replacing
`mpp_decode()` while continuing to allocate all AV1 storage through MPP would
bypass the packet decoder but would not remove the AV1 path's runtime libmpp
dependency.

A complete direct AV1 backend needs an internal buffer contract such as:

```c
struct RKNativeBuffer {
    int fd;                 /* owned duplicate */
    size_t size;
    uint32_t format;
    uint64_t modifier;
    uint32_t pitches[4];
    uint32_t offsets[4];
    void *allocator_owner;
};
```

The existing codecs can implement this contract using MPP-backed storage.
Direct AV1 can use a tested DMA heap or DRM allocation path while presenting
the same surface/export operations. Requirements include:

- one clear fd owner and explicit duplicate/close rules;
- checked allocation sizes, pitches, offsets, modifiers, and alignment;
- CPU/device synchronization for written stream and parameter buffers;
- no auxiliary buffer export to the client;
- state buffers retained exactly as long as their surface generation can be a
  reference;
- deferred destruction until every submitted job releases its strong
  references.

The first standalone replay may use MPP allocation as scaffolding, but its
result must be labelled accordingly. The no-libmpp milestone requires the same
replay with only the direct allocator and transport linked.

## Hardware stream and register compilation

The VA slice buffers cannot simply become the stream DMA-BUF unchanged. The
inspected HAL programs both a packed input stream and a separately generated
hardware parameter block. That parameter block includes
`frame_header_size` and tile-size-width information, while stock VA supplies
tile descriptors and headerless tile bytes rather than the original frame
OBU.

The compiler must therefore define and test one canonical representation:

1. sort and validate tile descriptors in raster order;
2. reject overlap, gaps that violate the selected representation, overflow,
   duplicate coordinates, excessive tile count, and out-of-range payload;
3. choose a legal fixed tile-size-field width when the hardware stream needs
   one;
4. write size fields and tile bytes into a bounded owned stream buffer;
5. set `frame_header_size`, `tile_sz_mag`, tile count, dimensions, and stream
   length consistently with those bytes;
6. pad only where the hardware contract requires it and zero all padding.

Whether a zero-length/canonical prefix is sufficient or a hardware-specific
synthetic prefix is required remains an empirical discriminator. It should be
settled by a golden-job capture and one-variable replay, not inferred from
register names.

Register generation must begin from zeroed, known templates for the exact
hardware ID. The transport should accept only compiler-produced register
banks and an allowlisted set of fd-bearing indices. It must never expose a
generic “write arbitrary register array” entrypoint to the VA buffer parser.

## Synchronization and error rules

The simplest correct first implementation serializes one AV1 context:

```text
validate and retain picture
  -> wait for referenced surface generations
  -> compile job
  -> submit with hard deadline
  -> inspect all error/status registers
  -> synchronize output/state buffers
  -> atomically publish success or failure
  -> signal the VA surface generation fence
```

Later overlap is permissible only when jobs form an explicit dependency graph
through retained surface generations. A context teardown must:

- stop accepting jobs;
- cancel jobs not submitted to hardware;
- bound the wait for an in-flight hardware job;
- reset/quarantine on timeout;
- signal every affected destination fence with failure;
- release imported fds and buffers only after kernel and worker ownership ends.

A timeout or bus/stream/reference error must never publish destination state.
Subsequent pictures referencing a failed surface must fail before submission.
After a device-level timeout, later calls should fail quickly until context
recreation or a proved reset establishes recovery.

## Security boundary

Direct submission is not expected to add a new ioctl family to Firefox's RDD
sandbox: the pinned but not yet runtime-validated policy already allowlists the
MPP v1 command ioctl used by libmpp, and direct submission uses that same
family. Allocator paths and broker pathname policy still need a live audit. The
security review also grows because `rockchip-vaapi` would now contain the
register compiler and its validation.

Required containment:

- accept only standard VA AV1 buffers and copy them before validation;
- hard-cap dimensions, tile count, tile payload, references, and every
  auxiliary allocation;
- use checked add/multiply/align helpers;
- generate registers from allowlisted templates rather than client-supplied
  words;
- allow fd translation only at the pinned AV1 address-register table;
- zero reserved bits and padding;
- reject unknown hardware IDs, kernel command sets, and structure versions;
- keep a hard poll deadline and a bounded reset path;
- fuzz the picture translator and pure job compiler without a device;
- mutate captured jobs only in a dedicated privileged test, never in the VA
  process;
- audit broker access to `/dev/mpp_service`, the selected DMA allocator, RGA
  if used, and DMA-BUF synchronization separately.

The kernel's register-class and fd-table validation is a second boundary, not
a substitute for these checks.

## Backend comparison

The two credible vendor-kernel routes share the VA-facing work but place the
hardware boundary on opposite sides of libmpp:

```text
parsed/stateless MPP API

  rockchip-vaapi
    -> RKAV1Picture + explicit surface/state handles
    -> public libmpp AV1 parsed-picture API
         -> MPP-owned HAL, buffers, register generation, OSAL, recovery
         -> /dev/mpp_service

direct MPP-service backend

  rockchip-vaapi
    -> RKAV1Picture + explicit surface state
    -> YSP-owned VDPU compiler, buffers, recovery, ioctl transport
         -> /dev/mpp_service
```

“Stateless MPP API” describes the caller boundary: each submission contains a
complete effective picture and explicit surfaces. MPP may still retain opaque
per-surface hardware state behind versioned state handles.

### Work that is identical on both routes

Neither backend avoids:

- copying and validating standard VA AV1 picture, slice, and tile buffers;
- defining the backend-neutral `RKAV1Picture` and capability model;
- retaining strong references to destination and referenced surface
  generations;
- resolving the missing `refresh_frame_flags` with explicit surface-keyed
  state;
- handling hidden frames, `show_existing_frame`, sequence changes, and failed
  references;
- deciding the two-output film-grain policy;
- proving NV12/P010 surface export, mapping, synchronization, and reuse;
- conformance, fuzzing, application, sandbox, concurrency, teardown, and soak
  gates.

The comparison is therefore about who owns everything below the neutral
picture boundary.

### Side-by-side ownership and benefit

| Dimension | Public parsed/stateless MPP API | Direct `/dev/mpp_service` backend |
|-----------|---------------------------------|-----------------------------------|
| Caller input | Versioned parsed picture, checked tile list, destination/reference frame handles, opaque surface-state handles. | Same neutral picture, but the driver also supplies hardware buffer roles and compiles the job. |
| Existing code reuse | Reuses MPP AV1 common/HAL code, default probability data, RCB sizing, buffer groups, fd translation wrappers, fast-mode machinery, hardware-ID dispatch, poll, and recovery. | Reuses behavior only as a source oracle; the necessary pieces are ported or reimplemented under YSP ownership. |
| New public contract | Substantial. Structure versioning, feature discovery, state-handle lifetime, async completion, and compatibility rules must be designed and reviewed. | Small private backend boundary inside `rockchip-vaapi`; kernel UAPI already exists. |
| Parser bypass | MPP needs a supported route from the public parsed submission into its internal syntax/HAL task path without depending on parser-owned DPB assumptions. | No MPP parser or task graph is entered. |
| Persistent AV1 state | MPP owns opaque CDF/segmentation/colmv state attached to caller frame handles. | `rockchip-vaapi` owns the DMA-BUFs, metadata, and state transitions attached to VA surface generations. |
| Hardware parameter/register compiler | Existing MPP implementation remains authoritative. | YSP owns a pinned VDPU383/VDPU384b compiler and its differential tests. |
| DMA-BUF allocation/import | Existing MPP buffer groups and device attachment remain usable. | Requires a generic DMA-BUF allocator/owner and explicit import-release discipline. |
| Kernel transport | Existing MPP OSAL assembles, submits, polls, and resets. | New codec-blind transport implements the v1 request ABI directly. |
| Integration with current driver | Fits the existing MPP worker, external pool, frame, and conversion model most closely. | Requires decoupling AV1 surfaces from `MppBuffer`/`MppFrame` assumptions while leaving other codecs on MPP. |
| Hardware generations | MPP selects and maintains the generation-specific HAL. | Every supported hardware ID needs a YSP compiler, capture, and conformance matrix. |
| Security review | New public input validation and state-handle code, but existing register compiler and transport stay centralized in MPP. | VA process gains a raw-job compiler, allocator, and transport; all register templates and sizes become YSP's audit burden. |
| Debuggability | More layers, but ordinary MPP traces and comparison clients remain available. | Deterministic compiler and symbolic job capture make register-level debugging unusually direct. |
| Release independence | Requires a new enough libmpp package and, ideally, Rockchip acceptance of the API. | Can ship in the YSP VA driver against the pinned kernel without waiting for a libmpp release. |
| Reuse outside VA | Other parsed clients and API bridges can use the MPP API. | Normally useful only to this driver and exact hardware/kernel combination. |
| Ordinary upgrades | A stable public ABI can absorb internal MPP and hardware changes. | Independent of userspace MPP upgrades, but exposed directly to kernel register ABI and hardware-generation drift. |

### Relative implementation cost

The following scores are planning estimates, not measured person-time. `1`
means a small or already-owned change; `5` means a large, high-risk work
package. “MPP” assumes YSP may prototype on a pinned fork. External review
latency is scored separately from implementation effort.

| Work package | Parsed MPP API | Direct service | Why |
|--------------|----------------|----------------|-----|
| Neutral VA picture and validation | 4 | 4 | Shared work. |
| Surface-keyed state semantics | 4 | 4 | Shared design, although the storage owner differs. |
| Public ABI, versioning, capabilities | 5 | 1 | The principal MPP-route upfront cost. |
| Parser-bypass/task-path integration | 3 | 1 | MPP must safely enter the HAL without parser-owned assumptions; direct never enters MPP. |
| Parameter and register generation | 1 | 5 | Already exists in MPP; must be ported and owned directly. |
| DMA-BUF allocation and auxiliary pools | 1 | 4 | Existing MPP machinery versus a new generic direct allocator. |
| Submit, poll, reset, import release | 1 | 3 | Existing OSAL versus a small but safety-critical transport. |
| Current `rockchip-vaapi` surface integration | 2 | 4 | Current object model is MPP-heavy. |
| Hardware variants and future kernel drift | 1 | 5 | Central MPP maintenance versus per-generation YSP ownership. |
| Register-level security hardening | 2 | 5 | Direct route duplicates the most privileged userspace layer. |
| External coordination/calendar risk | 5 | 1 | Rockchip/API review may dominate elapsed time; direct can proceed independently. |

Two different “initial” milestones therefore have different winners:

- **First independently submitted hardware frame:** direct service is easier.
  A normalized known-good register job can be replayed without designing a
  public API or modifying MPP's task graph.
- **First reasonably complete stock-client Profile 0 decoder:** the parsed MPP
  route is probably less implementation work if a pinned MPP fork is allowed.
  It reuses the HAL, allocator, hardware dispatch, submission, and recovery
  that the direct route otherwise has to absorb.
- **First upstream-quality release:** uncertain in elapsed calendar time. The
  MPP route has less technical duplication but may wait on API review; the
  direct route has no coordination dependency but substantially more code and
  qualification.

### Long-term maintenance cost

The answer depends on who owns the MPP API:

| Deployment future | Easier route | Reason |
|-------------------|--------------|--------|
| Rockchip accepts and maintains the parsed API | Parsed MPP API, decisively | Hardware revisions, register changes, buffer rules, and recovery stay with the vendor library that already owns them. |
| YSP carries a small, pinned parsed-API MPP fork | Parsed MPP API, moderately | YSP owns an API patch but still reuses one authoritative HAL/OSAL implementation rather than forking its behavior into the VA driver. |
| Rockchip rejects the API and YSP cannot carry an MPP fork | Direct service, by necessity | It is the only independently shippable parsed route on the vendor kernel. |
| Kernel and board are permanently frozen to this RK3588 image | Direct becomes more defensible | Register-ABI drift is bounded, although security and conformance ownership remain. |
| More Rockchip SoCs or hardware revisions must be supported | Parsed MPP API | Direct compiler and golden-job matrices multiply per generation. |

Even on a frozen image, direct maintenance is not free. Browser and libva
changes still exercise the translator, and every kernel AV1 fix must be checked
against the private register contract. Its main maintenance benefit is
organizational autonomy, not reduced technical surface.

### Recommended cost-benefit decision

Use a two-checkpoint sequence:

1. Build the **direct normalized golden-job replay** first. It is the cheapest
   way to prove the kernel UAPI, DMA-BUF roles, register classes, stream layout,
   status handling, and reset behavior without committing the production
   driver to either backend.
2. In parallel with that bounded proof, implement a narrow **MPP parsed-path
   spike** on the pinned MPP fork: one 8-bit keyframe, explicit destination and
   state handle, no public compatibility promise yet.
3. Compare actual diff size, private assumptions crossed, testability, and
   Rockchip's willingness to review the API.
4. Select one production backend before adding inter-frame and application
   breadth. Do not maintain two incomplete general decoders.

The default recommendation is:

- direct `/dev/mpp_service` for the first hardware proof and as the fallback
  production plan if external API coordination fails;
- a versioned parsed-picture MPP API for the maintained production path when
  YSP can carry it and preferably get it accepted upstream.

### Other routes in context

| Route | What it buys | Main cost/blocker | Position |
|-------|--------------|-------------------|----------|
| Direct `/dev/mpp_service` | Works with the vendor AV1 node already present; no packet parser; no new public MPP API coordination; surface-keyed state can fit stock VA calls. | Own the AV1 HAL behavior, private register ABI, allocator, validation, and recovery. | Best independent vendor-kernel proof; acceptable production candidate only on a pinned, tested stack. |
| Public MPP parsed-picture API | Reuses MPP's allocator, generation dispatch, HAL, OSAL, and recovery behind a versioned public boundary. | Requires MPP design/upstream or a permanently pinned fork. | Lower duplicated hardware code and still the cleanest vendor-library API. |
| V4L2 Request AV1 | Stable upstream media ABI; kernel owns register compilation and native VPU981 integration. | No AV1 V4L2 node on the present image; inspected driver stores CDF state using `refresh_frame_flags`, which stock libva omits. | Preferred long-term/mainline route after the endpoint and state contract are solved. |
| Reconstructed complete OBUs | Reuses public MPP packet decode unchanged. | Original header bytes and some state are gone at the VA boundary; heuristics are not correct for stock clients. | Diagnostic only. |
| Direct private MPP HAL calls | Reuses some implementation without a new public API. | In-process dependency on uninstalled private types and slot rules; ordinary MPP upgrades can break it. | Do not link the VA driver against private HAL symbols. Port/own a bounded backend instead. |

The direct route changes the earlier blanket “private ioctl is proof-only”
verdict. On a YSP-controlled kernel and userspace image, a deliberately owned,
version-pinned AV1 hardware backend is maintainable enough to evaluate for
release. It is not portable to arbitrary Rockchip kernels and must fail closed
outside its exact capability probe.

## Implementation sequence

### Phase D0 — normalized golden-job capture

Capture one successful ordinary libmpp AV1 decode on the pinned vendor path:

- source stream and software-decoder checksum;
- parsed syntax after the MPP parser;
- all three register banks with fd values normalized to symbolic buffer roles;
- every register offset fixup;
- stream and parameter/global-header buffers;
- default/input/output CDF and segmentation data;
- colmv and other required working-buffer sizes;
- status/readback registers and output layout.

Do not replay process-local fd integers or stale IOVAs. The capture format must
identify buffers symbolically and bind fresh DMA-BUFs at replay time.

Exit gate: a standalone transport with no libva dependency submits that captured
job through `/dev/mpp_service` and reproduces the pixel checksum, 100 times,
including clean process teardown.

### Phase D1 — direct transport and allocator

Replace any MPP allocation scaffolding with the selected DMA-BUF allocator.
Prove:

- command/hardware probing;
- AV1 client initialization;
- register write/read and offset messages;
- import release below the 40-buffer session ceiling;
- timeout, error, reset, and process-exit cleanup;
- no fd or resident-memory growth.

Exit gate: the same normalized replay remains bit-exact without linking
librockchip_mpp.

### Phase D2 — deterministic VDPU383 compiler

Port the minimum AV1 common and VDPU383 register logic behind owned structures.
For the same parsed picture, compare normalized outputs with the pinned MPP HAL:

- parameter/global-header bytes;
- canonical stream bytes;
- register values outside runtime status fields;
- symbolic buffer roles and offsets;
- auxiliary sizes and default-state selection.

Start with one 8-bit Profile 0 keyframe, one tile, no super-resolution,
intrabc, restoration, warped motion, or applied film grain. Add one feature
family at a time.

Exit gate: compiler output is deterministic and differential mismatches are
either zero or explicitly explained by the direct surface-state design.

### Phase D3 — neutral picture and surface-state replay

Feed the compiler from a versioned `RKAV1Picture` capture rather than MPP's
private syntax. Add:

- inter frames and all named references;
- primary-reference state;
- CDF-update-disabled cases;
- segmentation inheritance;
- hidden reference frames;
- multiple tiles and tile groups;
- resolution and bit-depth changes;
- failed-reference rejection.

Exit gate: key, inter, hidden, multi-tile, and 10-bit captures match both the
ordinary MPP path and a trusted software decoder.

### Phase D4 — `rockchip-vaapi` integration

Suggested ownership boundaries:

```text
src/av1_picture.[ch]              VA buffers -> RKAV1Picture
src/av1_backend.[ch]              backend vtable and capabilities
src/av1_surface_state.[ch]        per-generation persistent state
src/av1_vdpu383.[ch]              pure hardware-job compiler
src/mpp_service_transport.[ch]    codec-blind ioctl transport
tests/av1_replay.*                capture/replay and differential tool
```

Reuse the existing context worker and generation fence model, but place decoded
pixels and AV1 auxiliary state under one atomic completion result. Initially
expose only an environment-gated Profile 0 8-bit configuration.

Exit gate: stock FFmpeg and GStreamer VA clients decode, seek, flush, change
resolution, and tear down without parser stalls or stale surfaces.

### Phase D5 — hardening and release qualification

Before any default advertisement:

- AV1 conformance vectors are pixel-exact against software;
- translator/compiler fuzzing is sanitizer-clean;
- malformed tile and parameter captures fail before submission;
- multiple AV1 contexts and mixed MPP codecs complete concurrently;
- timeout/reset/fault injection leaves no hung service or referenceable failed
  surfaces;
- 8-bit NV12 export/map/derive-image and 10-bit P010 behavior are exact;
- applied film grain is either correctly two-output or rejected;
- Firefox and Chromium application gates prove actual hardware frames;
- the RDD/browser sandbox remains enabled with audited device/ioctl access;
- long seek, suspend/resume, context churn, and soak runs have bounded memory,
  fds, and latency;
- unavailable or mismatched hardware falls back in milliseconds.

Only the exact measured formats and features may be advertised.

## Open discriminators

| Question | Why source inspection is insufficient | Smallest useful proof |
|----------|---------------------------------------|-----------------------|
| What exact bytes must precede VA tile payload? | HAL field names show `frame_header_size` and tile-size width, not whether a zero/canonical prefix is accepted. | Replay the golden job while changing only the prefix and matching parameter fields. |
| Can every CDF/segmentation transition be surface-keyed? | The existing HAL combines frame-slot buffers with an eight-slot metadata table. | Differential sequences covering primary refs, disabled updates, switch frames, and surface reuse. |
| What output layout should the first backend request? | Register support does not prove the VA driver's existing NV12/AFBC/P010 assumptions for AV1. | Capture the known-good output registers/descriptor, then validate map/export bytes. |
| How will film grain produce two surfaces? | Current common register setup disables AV1 film grain. | Keep it rejected until a separate ungrained/grained differential test exists. |
| Can one session stay below 40 imported buffers? | Browser surface depth plus per-surface CDF/colmv can exceed a naïve retained-import model. | Trace import/release counts during high-DPB decode and implement eviction/release before integration. |
| Which hardware variants are supportable? | MPP contains VDPU383 and VDPU384b paths with different registers. | Query hardware ID and permit only the variant whose golden job and conformance matrix pass. |
| Does reset fully recover the hybrid VSI-IOMMU path? | Successful decode does not exercise timeout/fault recovery and existing kernel docs retain reset caveats. | Forced timeout/fault followed by a known-answer decode in the same and a recreated context. |
| Does direct allocation interoperate with current surfaces? | Existing driver ownership is MPP-object-heavy. | Export, map, derive image, reuse, and destroy a direct DMA-BUF surface under sanitizer instrumentation. |
| Is the browser sandbox delta really zero? | The ioctl number may match while allocator paths or broker pathname policy differ. | Live sandbox-enabled Firefox run plus broker/seccomp audit. |

## Decision and handoff

The direct `/dev/mpp_service` route should be carried as the first independent
vendor-backend proof alongside, not underneath, the public parsed-MPP proposal.
Its design rules are:

1. Preserve a backend-neutral `RKAV1Picture`.
2. Key all persistent hardware reference state to explicit surface
   generations.
3. Keep the VDPU compiler pure and the ioctl transport codec-blind.
4. Own pinned register definitions; do not link private MPP HAL symbols.
5. Begin with normalized golden-job replay before touching VA capability
   advertisement.
6. Fail closed on unknown hardware, ABI, feature, output layout, or recovery
   behavior.
7. Retain V4L2 Request as the mainline destination.

This route may be faster than negotiating a public MPP API because YSP owns the
kernel/userspace image. It is not less engineering than a thin VA adapter; it
is a conscious decision to maintain an AV1-only userspace hardware backend.

## Source map

The source-inspected facts above came from these pinned functions and
structures:

- libmpp `mpp/common/av1d_syntax.h`: private `DXVA_PicParams_AV1`;
- libmpp `mpp/hal/rkdec/av1d/hal_av1d_vdpu383.c`:
  `vdpu383_av1d_gen_regs()`, `vdpu383_av1d_start()`, and the completion path;
- libmpp `mpp/hal/rkdec/av1d/hal_av1d_com.c`:
  hardware-parameter packing, `vdpu38x_av1d_cdf_setup()`,
  `vdpu38x_av1d_set_cdf_segid()`, and `vdpu38x_av1d_colmv_setup()`;
- libmpp `mpp/hal/rkdec/common/vdpu383_com.c`: common register setup, including
  disabled AV1 film grain;
- libmpp `osal/driver/mpp_service.c` and `osal/inc/mpp_service.h`: request
  assembly, probing, submission, poll, and the v1 command ABI;
- forward-port kernel `include/uapi/linux/rk-mpp.h`: kernel-visible request
  commands and flags;
- forward-port kernel `drivers/video/rockchip/mpp/mpp_av1dec.c`:
  `av1dec_extract_task_msg()`, `av1dec_alloc_task()`, register classes, fd
  translation, scheduling, and the session buffer ceiling;
- forward-port kernel
  `drivers/media/platform/verisilicon/rockchip_vpu981_hw_av1_dec.c`: the
  alternative V4L2 driver's CDF load/store dependence on
  `refresh_frame_flags`;
- `rockchip-vaapi` `docs/AV1_SUPPORT_PLAN.md`: VA information inventory,
  surface-keyed parsed-backend model, lifecycle, and release gates.

The stable userspace/kernel ownership explanation is
[`how-the-userspace-libs-work.md`](../../../vendor-libraries/docs/how-the-userspace-libs-work.md);
the AV1 block and V4L2-versus-MPP driver models are in
[`av1-rk3588.md`](../../../kernel-drivers/av1/docs/av1-rk3588.md).
