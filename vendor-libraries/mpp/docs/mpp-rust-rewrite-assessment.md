# Rust libmpp rewrite assessment

This note records the findings from reviewing the local `mpp-rockchip` checkout
and scoping what a Rust rewrite of Rockchip's classic `librockchip_mpp` would
cost while keeping the same public API. It is the MPP counterpart to
[`librga-rust-rewrite-assessment.md`](../../rga/docs/librga-rust-rewrite-assessment.md) and
builds on the internal structure documented in
[`mpp-library-architecture.md`](mpp-library-architecture.md).

The short version: keeping the API is the easy part, and it is the only easy
part. Unlike librga, libmpp cannot lean on the kernel to own the hard work.
Classic MPP puts bitstream parsing, reference-frame state, rate control, and
hardware register generation in userspace, so a Rust rewrite has to reproduce
all of it bit-exactly against real silicon. The best point estimate is
**roughly 5-10 person-years**, or **3-6 calendar years for a small team**, which
is several times the librga userspace rewrite rather than a fraction of it.

Sources studied: `mpp-rockchip` at
`1375813cbbae5ad6861b166475dd8fb672183220` (same tree as the architecture
notes). Line counts below are C/C++/header source, excluding `build/`, `test/`,
`tools/`, and `utils/`.

## Why "keep the same API" is the cheap part

The public API is a C ABI: a handful of free functions
(`mpp_create`, `mpp_init`, `mpp_destroy`, `mpp_check_support_format`) plus the
`MppApi` function-pointer vtable (`decode`, `encode`, `poll`/`dequeue`/`enqueue`,
`control`, `reset`), all over opaque `void *` handles
(`MppCtx`, `MppPacket`, `MppFrame`, `MppBuffer`, `MppMeta`, `MppTask`). Each
handle has its own accessor library, and configuration is string-keyed through
`mpp_dec_cfg_*` / `mpp_enc_cfg_*`.

Rust reproduces that boundary almost for free: `#[repr(C)]` structs,
`#[no_mangle] extern "C"` functions, and `Box::into_raw` for the opaque handles.
`cbindgen` can regenerate `rk_mpi.h` and the object headers from the Rust side,
and existing consumers (`ffmpeg-rockchip`, upstream FFmpeg `h264_rkmpp`, the
`mpi_*_test` tools) would link unchanged. Budget the whole shim at **a few
engineer-weeks**. Everything expensive is behind that boundary.

## Where the work actually is

The library is about 300K lines, and the API layer is a rounding error inside
it. The distribution is what makes this a multi-year program:

| Component | LOC | What it is | Port difficulty |
|-----------|----:|------------|-----------------|
| HAL (`mpp/hal`) | 147K | Per-hardware register generation: **20,369 packed register bitfields** plus device-task submission, across VDPU/VEPU generations. | Mechanical but enormous; must be bit-exact; needs silicon to validate. |
| Codec (`mpp/codec`) | 67K | 11 decoders and 4 encoders: bit-exact stream parsers, DPB/reference state, rate control. | Hard, algorithmic, subtle. |
| Base (`mpp/base`) | 23K | `MppBuffer`/`Frame`/`Packet`/`Meta`/`Task`, buffer groups, config objects. | Medium; the part Rust improves. |
| vproc (`mpp/vproc`) | 18K | IEP/RGA post-processing (deinterlace, scale, color). | Hardware-specific, unsafe. |
| OSAL (`osal`) | 18K | Threads, allocators bound to dma-heap/DRM/ION/dma-buf, `mpp_service`/`vcodec_service` ioctl drivers. | Medium; unsafe kernel-ABI interop. |
| kmpp (`kmpp`) | 8K | Kernel-offload layer over shared memory. | Tricky unsafe, kernel ABI. |

The HAL detail is the headline number. Correctness there means emitting the same
20K-plus register fields the C code emits, per codec, per hardware generation
(`hal/rkenc` 67K, `hal/rkdec` 44K, `hal/vpu` 30K). Every field is a silent
corruption opportunity, and Rust's bitfield ergonomics are weaker than C's, so
this is a large and error-prone transcription job rather than a satisfying
rewrite.

The codec parsers are the other pole of difficulty. They are not uniform:

| Decoder | LOC | Decoder | LOC |
|---------|----:|---------|----:|
| H.264 | 10.2K | VP8 | 2.0K |
| AV1 | 9.7K | MPEG-4 | 2.0K |
| H.265 | 6.1K | AVS | 1.5K |
| VP9 | 3.8K | JPEG | 1.5K |
| AVS2 | 3.2K | H.263 | 1.0K |
| MPEG-2 | 2.1K | | |

Each is a stateful, bit-exact mini-project, and bugs are the quiet
wrong-pixel kind that only conformance streams catch.

## Why the MPP rewrite is much larger than the librga rewrite

The librga assessment lands at ~45% of the `rga-rewrite` kernel effort because
the kernel driver already owns the hard problems: register/command generation,
dma-buf lifetime, fences, scheduling, IOMMU recovery. A Rust librga mostly
normalizes API calls into ioctl shapes the driver already accepts.

libmpp has no such backstop. As the architecture notes and the package README
both stress, **the kernel does not parse H.264/H.265/VP9 into registers -
libmpp does.** In this stack the `/dev/mpp_service` kernel service is closer to
a protected scheduler and register executor; userspace owns the entire codec
recipe. So the Rust rewrite cannot offload the 147K of HAL or the 67K of codec
logic to an existing kernel contract. It has to carry all of it.

That is the structural reason the two estimates point in opposite directions:

| | librga rewrite | libmpp rewrite |
|--|----------------|----------------|
| Source size | ~51K LOC | ~300K LOC (about 6x) |
| Kernel owns register/command generation? | Yes (`rga-rewrite`) | No, userspace owns it |
| Bit-exact parser state in userspace? | No | Yes, 11 codecs |
| Hardware generations to validate | RGA2/RGA3 | Multiple VDPU/VEPU per codec |
| Verdict | ~45% of `rga-rewrite` | several times the librga rewrite |

## What remains difficult in Rust

As with librga, the risks are compatibility and validation risks, not
Rust-language risks - but here they are much larger:

- Exact `#[repr(C)]` and bitfield layout for the register structs that get
  handed to the kernel or DMA'd to hardware. There are tens of thousands of
  fields and no compiler will tell you when one is wrong.
- Bit-exact codec parsing. The acceptance bar is pixel-identical decode and
  byte-identical encode against reference streams, not "it plays."
- The DMA/ioctl surface is irreducibly `unsafe`: memory-mapped submission,
  dma-heap/DRM/ION allocation, `mpp_service` and legacy `vcodec_service` ioctl
  ABIs, and the kmpp shared-memory path. This is where Rust's safety story is
  weakest and where most of the bulk lives.
- Preserving libmpp quirks: control-command semantics, config-key names and
  update-flag behavior, buffer-group refcount and cache-sync policy, info-change
  handshakes, and EOS/reset edge cases that current FFmpeg and GRD paths depend
  on.

## Where Rust actually helps

The safety win is real but concentrated in the smaller half of the tree. The
base object model, buffer-group refcounting, task queues, and the OSAL threading
layer (roughly `mpp/base` + the non-ioctl parts of `osal`, ~40K LOC) are exactly
the lifetime- and concurrency-heavy code where MPP has historically had bugs, and
where Rust ownership pays off. The HAL, vproc, kmpp, and allocator layers
(~180K LOC) stay `unsafe` at the hardware boundary and gain little. So a full
rewrite spends most of its effort in the region where Rust helps least.

## Estimated size

For a small team already fluent in both Rust and video codec hardware, with
continuous access to the target RK3588 silicon:

| Component | Estimate |
|-----------|----------|
| API/ABI shim (`rk_mpi.h` + object headers) | ~2-4 weeks |
| Base object model + OSAL | ~6-12 person-months |
| Codec parsers and encoders | ~12-24 person-months |
| HAL register generation | ~18-36 person-months |
| vproc + kmpp | ~5-10 person-months |
| Conformance infra, multi-chip bring-up, perf parity | ~6-12 person-months |
| **Total** | **~5-10 person-years, ~3-6 calendar years** |

The dominant cost is not translation, it is validation, and validation is
serial: correctness means bit-exact output across ~10 codecs and multiple
hardware generations, checked on real silicon against large reference-stream
suites. That loop, not the typing, sets the schedule. Ramp-up on either video
hardware or Rust pushes the estimate toward the high end.

## Suggested strategy

Do not scope this as "rewrite libmpp." Two saner framings, matching the librga
note's "compatibility frontend" philosophy:

1. **Safety-first, incremental (recommended).** Port only `mpp/base` plus the
   object model and the threading/buffer-lifetime logic to Rust behind the
   existing C ABI, leaving HAL, codec, and OSAL in C via FFI. That captures most
   of the real safety value for a small fraction of the cost and ships
   continuously. It also gives the team a working C-ABI boundary to expand from.
2. **Full reimplementation.** Treat it as a hardware bring-up program, not a
   library rewrite. Keep the C ABI stable with `cbindgen`, reuse the existing
   `mpi_*_test` and FFmpeg/GRD paths as the acceptance matrix, and port
   codec-by-codec and hardware-by-hardware so each slice can be conformance-gated
   against the C build before the C version is retired.

Either way, build a Rust core with a stable `extern "C"` boundary and keep the
existing headers as thin source-compatibility wrappers, exactly as recommended
for librga. Do not attempt a big-bang swap.

## Practical milestone plan

| Milestone | Contents |
|-----------|----------|
| 1. ABI skeleton | `#[repr(C)]` handles, `MppApi` vtable, `mpp_create`/`init`/`destroy`, error codes, `cbindgen` header parity. |
| 2. Object model | `MppPacket`, `MppFrame`, `MppMeta`, `MppTask` accessors and `MppBuffer`/`MppBufferGroup` refcount + cache-sync, validated against C behavior. |
| 3. OSAL boundary | Threads, dma-heap/DRM allocators, `mpp_service` ioctl client, kept `unsafe` and layout-tested. |
| 4. First decode path | One codec end-to-end (H.264) through a Rust parser + Rust HAL to real hardware, pixel-exact against the C build. |
| 5. First encode path | One encoder (H.264) with rate control, byte-compared against the C build. |
| 6. Codec breadth | Remaining decoders/encoders one at a time, each conformance-gated. |
| 7. HAL breadth | Remaining hardware generations, register-diffed against C output. |
| 8. vproc + kmpp | Post-processing and the kernel-offload path, once the core is proven. |
| 9. Perf parity | Throughput/latency matched to the C library before retirement. |

## Bottom line

Keeping the MPP API in Rust is trivial; reproducing the behavior behind it is a
mountain. Because libmpp owns codec parsing and register generation in userspace
rather than delegating them to the kernel, the rewrite cannot be scoped like the
librga one. Budget it at **5-10 person-years / 3-6 calendar years**, expect most
of that effort in `unsafe` hardware-facing code where Rust helps least, and if
the goal is safety rather than a full port, do the incremental
`mpp/base`-behind-the-C-ABI version instead - that captures roughly 80% of the
real safety value for about 15% of the cost.
