# libmpp architecture notes

These notes document how Rockchip's classic MPP userspace library is organized
and how work moves through it. They complement
[`how-the-userspace-libs-work.md`](how-the-userspace-libs-work.md), which gives
the higher-level userspace/kernel picture, and
[`mpp-kmpp-reverse-engineering.md`](mpp-kmpp-reverse-engineering.md), which
focuses on the newer KMPP direction.

Sources studied:

| Source | Notes |
|--------|-------|
| `mpp-rockchip` at `1375813cbbae5ad6861b166475dd8fb672183220` | Main userspace MPP tree studied for this document. |
| `inc/rk_mpi.h`, `mpp/mpi.c`, `mpp/mpp.c`, `mpp/inc/mpp.h` | Public MPI API and top-level context implementation. |
| `mpp/base/*`, `inc/mpp_task.h`, `inc/mpp_meta.h`, `inc/mpp_buffer.h` | Task queues, metadata, buffer groups, and allocator abstraction. |
| `mpp/codec/*` | Decoder parser/runtime and encoder scheduler/control logic. |
| `mpp/hal/*`, `osal/driver/*`, `osal/allocator/*` | HAL selection, register task generation, kernel device ABI, and dma-buf allocation. |
| `kmpp/base/*`, `mpp/base/mpp_enc_cfg.c`, `mpp/base/mpp_dec_cfg.c` | Structured config object system and KMPP object hooks. |

## Short Version

Classic `librockchip_mpp` is a userspace codec runtime. It does much more than
open `/dev/mpp_service`:

```text
application
  -> public MPI API: MppCtx + MppApi
    -> top-level Mpp context: queues, lists, buffer groups, controls
      -> decoder parser or encoder scheduler/control
        -> codec-specific syntax/DPB/reference/rate-control logic
          -> hardware-specific HAL register generation
            -> MppDev OSAL backend
              -> /dev/mpp_service or older vcodec-service ioctls
                -> kernel validates, maps dma-bufs, schedules hardware, waits IRQ
```

The kernel does not parse H.264/H.265/VP9 into codec state for classic MPP. In
this stack, userspace owns the codec recipe: bitstream parsing, DPB/reference
state, rate-control decisions, output buffer choice, and hardware register
payload generation. The kernel service is still critical, but its role is closer
to a protected scheduler and register executor.

## Source Map

| Area | Important files | Role |
|------|-----------------|------|
| Public API | `inc/rk_mpi.h`, `mpp/mpi.c` | Defines `MppApi`, creates/destroys contexts, validates calls, forwards into `Mpp`. |
| Top-level context | `mpp/inc/mpp.h`, `mpp/mpp.c` | Owns common queues, lists, buffer groups, decoder/encoder subcontexts, KMPP hook. |
| Task queues | `inc/mpp_task.h`, `mpp/base/inc/mpp_task_impl.h`, `mpp/base/mpp_task_impl.c` | Advanced API ports and internal work-item transport. |
| Metadata | `inc/mpp_meta.h`, `mpp/base/mpp_meta.c` | Typed key/value store used by tasks, frames, and packets. |
| Buffers | `inc/mpp_buffer.h`, `mpp/base/inc/mpp_buffer_impl.h`, `mpp/base/mpp_buffer_impl.c` | Buffer groups, refcounts, external imports, cache sync, fd to device mapping. |
| Allocators | `osal/mpp_allocator.c`, `osal/allocator/*` | Selects dma-heap, DRM, ION, external dma-buf, or normal memory backends. |
| Decoder | `mpp/codec/mpp_dec.c`, `mpp/codec/mpp_dec_normal.c`, `mpp/codec/mpp_parser.c` | Decoder object, parser/HAL threads, parser plugin dispatch, frame-slot state. |
| Encoder | `mpp/codec/mpp_enc_v2.c`, `mpp/codec/mpp_enc_impl.c`, `mpp/codec/enc_impl.c` | Encoder object, sync/async workers, RC/reference flow, codec-control plugin dispatch. |
| HAL | `mpp/hal/mpp_hal.c`, `mpp/hal/mpp_enc_hal.c`, `mpp/hal/rkdec/*`, `mpp/hal/rkenc/*`, `mpp/hal/vpu/*` | Chooses a hardware backend and generates/registers hardware tasks. |
| Device OSAL | `osal/inc/mpp_device.h`, `osal/driver/mpp_device.c`, `osal/driver/mpp_service.c`, `osal/driver/vcodec_service.c` | Common device API over newer `/dev/mpp_service` and older per-block vcodec devices. |
| Config/KMPP object system | `kmpp/base/*`, `mpp/base/mpp_enc_cfg.c`, `mpp/base/mpp_dec_cfg.c` | Table-driven config objects with update flags and optional kernel-shared backing. |

## Public API Layer

The public MPP API has two opaque handles:

| Handle | Real implementation |
|--------|---------------------|
| `MppCtx` | Actually points to `MpiImpl` from `mpp/inc/mpi_impl.h`. |
| `MppApi *` | Points to a static function table in `mpp/mpi.c`. |

`MpiImpl` is small. It contains a self-check pointer, the selected context type
and coding, a pointer to the public `MppApi`, and the internal `Mpp *ctx`.

The lifecycle is:

```text
mpp_create(&ctx, &mpi)
  -> allocate MpiImpl
  -> mpp_ctx_create(&impl->ctx, impl)
  -> return ctx as MpiImpl* and mpi as static MppApi*

mpp_init(ctx, MPP_CTX_DEC or MPP_CTX_ENC, coding)
  -> mpp_ctx_init(internal Mpp, type, coding)

use one API family:
  -> simple decode/encode put/get calls
  -> or advanced poll/dequeue/enqueue task API

mpi->reset(ctx)
  -> mpp_reset(internal Mpp)

mpp_destroy(ctx)
  -> mpp_ctx_destroy(internal Mpp)
  -> free MpiImpl
```

`inc/rk_mpi.h` exposes these main `MppApi` families:

| API family | Functions | Meaning |
|------------|-----------|---------|
| Simple decode | `decode`, `decode_put_packet`, `decode_get_frame` | Push compressed packets and pull decoded frames. |
| Simple encode | `encode`, `encode_put_frame`, `encode_get_packet` | Push raw frames and pull encoded packets. |
| Advanced task API | `poll`, `dequeue`, `enqueue` | Direct access to port/task queues. |
| Control | `control`, `reset` | Runtime/pre-init configuration, buffer groups, callbacks, reset. |

Important gotcha: `mpi_encode()` in `mpp/mpi.c` is still a TODO wrapper. The
real encode path is `encode_put_frame()` plus `encode_get_packet()`, or the
advanced task API.

## The Internal `Mpp` Object

`struct Mpp` in `mpp/inc/mpp.h` is the central context. It is shared by decode
and encode and contains the plumbing that both paths reuse.

| Field group | Examples | Purpose |
|-------------|----------|---------|
| Simple API lists | `mPktIn`, `mPktOut`, `mFrmIn`, `mFrmOut` | Blocking/nonblocking packet/frame lists for simple APIs and async encode. |
| Buffer groups | `mPacketGroup`, `mFrameGroup`, `mExternalBufferMode` | Internal stream/output groups or externally supplied decode frame group. |
| Task queues | `mInputTaskQueue`, `mOutputTaskQueue` | Two queues backing the advanced API and much of the simple API. |
| User ports | `mUsrInPort`, `mUsrOutPort` | Ports exposed to `mpi->poll/dequeue/enqueue`. |
| MPP internal ports | `mMppInPort`, `mMppOutPort` | Ports consumed/produced by decoder/encoder workers. |
| Timeouts/mode | `mInputTimeout`, `mOutputTimeout`, `mIoMode`, `mDisableThread` | Blocking behavior and whether simple or task IO is locked in. |
| Codec subcontexts | `mDec`, `mEnc` | Decoder or encoder implementation object. |
| KMPP hook | `mKmpp`, `mVencInitKcfg` | Optional bypass into kernel MPP path. |
| Pre-init decoder cfg | `mDecCfg`, `mDecHwType`, etc. | Control values saved before decoder init. |

`mpp_ctx_create()` sets defaults, allocates decoder config, and reads debug/dump
environment variables. `mpp_ctx_init()` does the real construction.

## Initialization Paths

`mpp_ctx_init()` has three major paths.

### KMPP Encoder Bypass

If `mVencInitKcfg` was set before init by `MPP_SET_VENC_INIT_KCFG`,
`mpp_ctx_init()` allocates `Kmpp`, calls `mpp_get_api()`, passes the init
kernel config, and returns early. In this mode the classic decoder/encoder task
queues and HAL path are not constructed. Later `mpp_put_frame()`,
`mpp_get_packet()`, and `mpp_reset()` dispatch through `m->mKmpp`.

This is the high-level KMPP hook documented in
[`mpp-kmpp-reverse-engineering.md`](mpp-kmpp-reverse-engineering.md).

### Decoder Init

For `MPP_CTX_DEC`, classic MPP:

1. Creates packet input and frame output lists.
2. Uses nonblocking defaults for input and output timeouts.
3. Creates an internal packet buffer group except for MJPEG.
4. Creates input and output task queues, usually with four tasks for non-MJPEG.
5. Wires `mUsrInPort`/`mMppInPort` around the input queue.
6. Wires `mUsrOutPort`/`mMppOutPort` around the output queue.
7. Builds `MppDecInitCfg` and calls `mpp_dec_init()`.
8. Starts decoder threads with `mpp_dec_start()`.

### Encoder Init

For `MPP_CTX_ENC`, classic MPP:

1. Creates packet output and frame input lists.
2. Defaults input to blocking and output to nonblocking.
3. Creates internal packet and frame buffer groups.
4. Creates input and output task queues and wires user/internal ports.
5. Calls `mpp_enc_init_v2()`.
6. Starts either `mpp_enc_thread()` or `mpp_enc_async_thread()` depending on
   async mode.

The encoder HAL is initialized before the codec-control implementation, because
the HAL reports the actual hardware client type and capabilities that the codec
control layer needs.

## Task Queue Model

The advanced task API is not bolted on. It is the common transport that the
simple API often uses internally.

`inc/mpp_task.h` defines the public idea:

- A queue has an input port and an output port.
- A `MppTask` is a container for input/output items.
- Items are carried in task metadata, usually `MppPacket`, `MppFrame`, or
  `MppBuffer`.

`mpp/base/mpp_task_impl.c` implements each queue with four task states:

```text
MPP_INPUT_PORT   -> MPP_INPUT_HOLD   -> MPP_OUTPUT_PORT
MPP_OUTPUT_PORT  -> MPP_OUTPUT_HOLD  -> MPP_INPUT_PORT
```

Port behavior:

| Port call | Input port effect | Output port effect |
|-----------|-------------------|--------------------|
| `poll` | Waits for tasks in `MPP_INPUT_PORT`. | Waits for tasks in `MPP_OUTPUT_PORT`. |
| `dequeue` | Moves task to `MPP_INPUT_HOLD`. | Moves task to `MPP_OUTPUT_HOLD`. |
| `enqueue` | Moves task to `MPP_OUTPUT_PORT`. | Moves task to `MPP_INPUT_PORT`. |

So an input queue is a user-to-worker handoff:

```text
empty task available to user
  -> user dequeues
  -> user attaches KEY_INPUT_PACKET or KEY_INPUT_FRAME
  -> user enqueues
  -> worker sees it on the queue output port
```

An output queue is a worker-to-user handoff:

```text
empty task available to worker
  -> worker dequeues
  -> worker attaches KEY_OUTPUT_FRAME or KEY_OUTPUT_PACKET
  -> worker enqueues
  -> user sees it on the queue output port
```

`mpp_set_io_mode()` locks a context into either normal simple-API IO or advanced
task-queue IO on first use. The code rejects switching after one style has been
used.

## Metadata

`MppTask` contains `MppMeta`, a typed key/value store. Frames and packets can
also carry metadata. The core keys are in `inc/mpp_meta.h`.

| Key | Typical value | Meaning |
|-----|---------------|---------|
| `KEY_INPUT_PACKET` | `MppPacket` | Compressed input to decoder. |
| `KEY_OUTPUT_FRAME` | `MppFrame` | Decoded output from decoder, or caller-specified decode output in secure/advanced flows. |
| `KEY_INPUT_FRAME` | `MppFrame` | Raw input to encoder. |
| `KEY_OUTPUT_PACKET` | `MppPacket` | Encoded output from encoder, optionally caller-supplied. |
| `KEY_MOTION_INFO` | `MppBuffer` | Optional encoder motion/MD output. |
| `KEY_INPUT_IDR_REQ` | `s32` | Request IDR on the next encode frame. |
| `KEY_OUTPUT_INTRA` | `s32` | Encoder output frame was intra. |
| `KEY_ENC_AVERAGE_QP`, `KEY_ENC_START_QP` | `s32` | Encoder quality metadata returned on output packet. |
| `KEY_ROI_DATA`, `KEY_OSD_DATA`, `KEY_QPMAP0` | pointer/buffer | Encoder sideband controls. |

This metadata scheme is the main reason a generic task queue can carry decode,
encode, secure-buffer, and extra-info workflows without changing the queue API.

## Simple Decode Flow

The split decode API is:

```text
mpi->decode_put_packet(ctx, packet)
mpi->decode_get_frame(ctx, &frame)
```

Internally:

1. `mpi_decode_put_packet()` validates the public context and calls
   `mpp_put_packet()`.
2. `mpp_put_packet()` polls/dequeues a task from `mUsrInPort`.
3. If the input packet has a backing `MppBuffer`, it uses the packet directly.
   If not, it allocates/copies the packet into an internal packet buffer so the
   hardware can DMA from it.
4. The task gets `KEY_INPUT_PACKET` and is enqueued to the decoder side.
5. The decoder parser thread dequeues from `mMppInPort`, splits/prepares one
   frame worth of compressed data, parses codec syntax, updates DPB/frame slots,
   allocates or reuses output frame buffers, generates decoder registers, and
   starts the hardware.
6. The decoder HAL thread waits for hardware completion, clears slot use flags,
   pushes displayable frame slots, and adds `MppFrame` copies to `mFrmOut`.
7. `mpi_decode_get_frame()` calls `mpp_get_frame()`, which waits on `mFrmOut`,
   pops a frame, begins read-only cache sync on its buffer, and returns it.

The combined `mpi->decode(ctx, packet, &frame)` wrapper exists, but the split
put/get API is easier to reason about and maps more closely to how the library
really works.

## Decoder Internals

`mpp_dec_init()` constructs a decoder-specific object:

| Component | Source | Role |
|-----------|--------|------|
| `MppDecCfg` | `mpp/base/mpp_dec_cfg.c` | Table-driven decoder config object. |
| `frame_slots` | `mpp/base/inc/mpp_buf_slot.h` | DPB/display/output frame state. |
| `packet_slots` | `mpp/base/inc/mpp_buf_slot.h` | Hardware packet input slot state. |
| `MppHal` | `mpp/hal/mpp_hal.c` | Decoder hardware backend. |
| `Parser` | `mpp/codec/mpp_parser.c` | Codec parser backend. |
| `HalTaskGroup` | `mpp/hal/inc/hal_task.h` | Parser-to-HAL task handles. |
| threads | `mpp/codec/mpp_dec_normal.c` | Parser worker and HAL wait/output worker. |

### Parser Plugins

`mpp/codec/mpp_parser.c` keeps a table of `ParserApi` implementations indexed by
coding type. Codec parser files register themselves with `MPP_PARSER_API_REGISTER`.

Parser APIs provide:

| Function | Role |
|----------|------|
| `prepare` | Split/copy input packet data into a per-frame packet for hardware. |
| `parse` | Parse codec syntax, set output slot, references, flags, and syntax payload. |
| `reset` / `flush` | Reset parser state or push delayed frames. |
| `control` | Apply decoder-specific controls. |
| `callback` / `sync` | Error callbacks and zero-copy lifetime sync. |

Registered parsers include H.264, H.265, VP8, VP9, AV1, JPEG, MPEG-2, MPEG-4,
H.263, AVS, and AVS2, depending on compile flags.

### Buffer Slots

`MppBufSlots` are the decoder's DPB and slot-state model. They are separate from
generic `MppTask` queues. The comments in `mpp/base/inc/mpp_buf_slot.h` are one
of the best explanations in the tree.

Slot responsibilities:

- Track frame buffer allocation and ownership.
- Track packet buffer lifetime for hardware input.
- Mark codec reference use and hardware input/output use.
- Queue frames for display or post-processing.
- Detect stream info changes such as resolution, stride, format, or buffer size.

When parser setup changes slot requirements, `mpp_buf_slot_is_changed()` becomes
true. MPP then emits an info-change frame and waits until the application calls
`MPP_DEC_SET_INFO_CHANGE_READY`, which ends in `mpp_buf_slot_ready()`.

### Normal Decoder Threads

For most codecs, `mpp_dec_start_normal()` starts:

| Thread | Function | Role |
|--------|----------|------|
| Parser thread | `mpp_dec_parser_thread()` | Pull packets, parse, allocate slots/buffers, generate registers, start hardware, submit HAL task. |
| HAL thread | `mpp_dec_hal_thread()` | Wait hardware completion, clear slot flags, push display frames, wake parser. |

The parser thread's main work is `try_proc_dec_task()`:

1. Acquire an idle HAL task handle.
2. Get an input packet task.
3. Call parser `prepare`.
4. Allocate a packet slot and hardware-readable stream buffer.
5. Copy prepared stream bytes and cache-sync them.
6. Optionally wait for previous task if not in fast-parse mode.
7. Ensure display queue and frame slots are not full.
8. Call parser `parse`.
9. Handle info-change flow.
10. Ensure/allocate an output frame buffer.
11. Generate registers with `mpp_hal_reg_gen()`.
12. Start hardware with `mpp_hal_hw_start()`.
13. Submit the task to the HAL thread.

The HAL thread then:

1. Gets a task in `TASK_PROCESSING`.
2. Handles info-change and EOS-only tasks specially.
3. Calls `mpp_hal_hw_wait()`.
4. Clears `SLOT_HAL_INPUT` and `SLOT_HAL_OUTPUT`.
5. Clears reference hardware-use marks.
6. Flushes/pushes display slots and wakes the parser.

MJPEG uses a special `mpp_dec_advanced_thread()` path that can decode from a
caller-supplied input buffer directly into a caller-supplied output frame.

## Simple Encode Flow

The split encode API is:

```text
mpi->encode_put_frame(ctx, frame)
mpi->encode_get_packet(ctx, &packet)
```

There are two classic userspace execution modes:

| Mode | Main structures | Worker |
|------|-----------------|--------|
| Queue-backed sync mode | `MppTaskQueue`, `mUsrInPort`, `mUsrOutPort` | `mpp_enc_thread()` |
| List-backed async mode | `mFrmIn`, `mPktOut` lists | `mpp_enc_async_thread()` |

`mpp_put_frame()` does a KMPP bypass first if `m->mKmpp` exists. Otherwise it
uses either the async list path or the task-queue path. In task-queue mode it:

1. Polls/dequeues an input task from `mUsrInPort`.
2. Sets `KEY_INPUT_FRAME`.
3. Copies optional `KEY_OUTPUT_PACKET` and `KEY_MOTION_INFO` from frame metadata.
4. Enqueues to the encoder worker.
5. Waits for the task to finish in blocking mode.

`mpp_get_packet()` similarly bypasses to KMPP if present. Otherwise it polls the
output port or async output list, gets `KEY_OUTPUT_PACKET`, cache-syncs the
encoded range, and returns the packet.

## Encoder Internals

`mpp_enc_init_v2()` constructs `MppEncImpl`:

| Component | Role |
|-----------|------|
| `set_obj` / `cfg_obj` | External and internal `MppEncCfg` KMPP objects. |
| `MppEncRefs` | Reference picture and CPB state. |
| `MppEncHal` | Hardware-specific encoder HAL. |
| `EncImpl` | Codec-specific control/syntax implementation. |
| `RcCtx` | Rate-control plugin context. |
| `HalTaskGroup` | Async hardware task handles. |
| `hdr_pkt` | Cached codec header packet for SPS/PPS/VPS/JPEG headers. |
| semaphores/lock | Control and reset synchronization. |

The encoder comments in `mpp/codec/inc/mpp_enc.h` describe the design well:
configuration is split into rate control, source/prep settings, codec settings,
and extra sideband inputs such as ROI, OSD, motion detection, and SEI/user data.

### Codec-Control Plugins

`mpp/codec/enc_impl.c` selects an `EncImplApi` by coding type. The codec-control
layer handles codec syntax and DPB/reference work that is not hardware-register
specific.

Important `EncImplApi` callbacks:

| Callback | Role |
|----------|------|
| `proc_cfg` | Validate/apply codec-specific config. |
| `gen_hdr` | Generate codec headers. |
| `start` | Start one logical frame in codec-control state. |
| `proc_dpb` | Update codec DPB/reference state. |
| `proc_hal` | Fill syntax structures for the HAL. |
| `add_prefix` | Add SEI/user/debug prefixes. |
| `sw_enc` | Optional software encode path. |

Registered encoder control implementations include H.264, H.265, JPEG, and VP8
when enabled.

### Encoder Worker Steps

The normal worker `mpp_enc_thread()` loops over:

1. Process pending control commands when not encoding.
2. Process reset requests.
3. Get a pair of input and output tasks.
4. Extract `MppFrame`, optional caller packet, and optional motion-info buffer.
5. Check per-frame metadata such as `KEY_INPUT_IDR_REQ`.
6. Run rate-control frame-drop checks.
7. Allocate or validate output packet buffer.
8. Update codec info sent to the kernel.
9. Generate headers if needed.
10. Call `enc_impl_start()`.
11. Apply reference force config and stash DPB state.
12. Run normal encode.
13. Handle reencode, forced P-skip, super-frame/drop behavior.
14. Run rate-control frame end.
15. Attach output metadata such as intra flag, QP, SSE, realtime bits, and MD.
16. Enqueue output packet and return input frame task.

The normal encode core calls these stages:

```text
mpp_enc_refs_get_cpb()
enc_impl_proc_dpb()
rc_frm_start()
mpp_enc_add_sw_header()
enc_impl_proc_hal()
mpp_enc_hal_get_task()
rc_hal_start()
mpp_enc_hal_gen_regs()
mpp_enc_hal_start()
mpp_enc_hal_wait()
rc_hal_end()
mpp_enc_hal_ret_task()
rc_frm_end()
```

Low-delay split output uses `part_start`/`part_wait` and can emit packet
partitions before the full frame is done. Async mode can have multiple hardware
tasks in flight: it moves tasks to `TASK_PROCESSING` and later calls
`try_proc_processing_task()` / `enc_async_wait_task()`.

## HAL Layer

The HAL layer has two plugin APIs:

| Direction | Common wrapper | Plugin struct | Main callbacks |
|-----------|----------------|---------------|----------------|
| Decode | `mpp/hal/mpp_hal.c` | `MppHalApi` | `reg_gen`, `start`, `wait`, `reset`, `flush`, `control` |
| Encode | `mpp/hal/mpp_enc_hal.c` | `MppEncHalApi` | `prepare`, `get_task`, `gen_regs`, `start`, `wait`, `part_start`, `part_wait`, `ret_task` |

HAL implementations register at module init with `MPP_DEC_HAL_API_REGISTER` or
`MPP_ENC_HAL_API_REGISTER`. Registration is filtered by detected SoC, so only
matching hardware backends enter the runtime table.

Decode HAL selection considers:

- `mpp_get_vcodec_type()` platform capability bits.
- Requested codec.
- Optional requested hardware type in decoder config.
- Client priority, for example RKVDEC before VDPU for H.264/H.265/VP9 on
  capable SoCs.

Encode HAL selection tries hardware clients in roughly this order:

```text
RKVENC
JPEG_ENC for MJPEG
VEPU2
VEPU1
VEPU22
```

The HAL is where codec syntax and buffer slots become hardware registers. HAL
files are hardware-family specific, for example:

- `mpp/hal/rkdec/h264d/*`, `mpp/hal/rkdec/h265d/*`, `mpp/hal/rkdec/vp9d/*`
- `mpp/hal/rkenc/h264e/*`, `mpp/hal/rkenc/h265e/*`
- `mpp/hal/vpu/*` for older VPU/VDPU/VEPU generations

## Kernel Device Boundary

The HAL does not usually issue raw ioctls directly. It goes through `MppDev`
from `osal/inc/mpp_device.h`.

`mpp_dev_init()` chooses one backend:

| Backend | When selected | Devices |
|---------|---------------|---------|
| `vcodec_service_api` | `IOCTL_VCODEC_SERVICE` | Older per-block names such as `/dev/vpu_service`, `/dev/rkvdec`, `/dev/rkvenc`, `/dev/vepu`, `/dev/h265e`, with `/dev/mpp_service` fallback. |
| `mpp_service_api` | `IOCTL_MPP_SERVICE_V1` | Newer `/dev/mpp_service` or `/dev/mpp-service`. |

The common `MppDevIoctlCmd` operations are:

| Command | Purpose |
|---------|---------|
| `MPP_DEV_REG_WR` / `MPP_DEV_REG_RD` | Queue register write/read payloads. |
| `MPP_DEV_REG_OFFSET` / `MPP_DEV_REG_OFFS` | Tell kernel which registers contain fd/IOVA offsets. |
| `MPP_DEV_RCB_INFO` | Send row/RCB buffer info for newer blocks. |
| `MPP_DEV_SET_INFO` | Send codec info such as width, height, format, fps. |
| `MPP_DEV_ATTACH_FD` / `MPP_DEV_DETACH_FD` | Import/release dma-buf fd in the device context. |
| `MPP_DEV_CMD_SEND` | Submit the queued hardware task. |
| `MPP_DEV_CMD_POLL` | Wait for hardware completion or IRQ/slice info. |

### `/dev/mpp_service`

`osal/driver/mpp_service.c` wraps the newer ABI around `MPP_IOC_CFG_V1` and
`MppReqV1`. It probes:

- Hardware support with `MPP_CMD_PROBE_HW_SUPPORT`.
- Supported command ranges through `/proc/mpp_service/supports-cmd` or
  `/proc/mpp_service/support_cmd`.
- Per-client hardware IDs through `MPP_CMD_QUERY_HW_ID`.

During a task, the userspace backend queues requests such as:

- `MPP_CMD_SET_REG_WRITE`
- `MPP_CMD_SET_REG_READ`
- `MPP_CMD_SET_REG_ADDR_OFFSET`
- `MPP_CMD_SET_RCB_INFO`
- `MPP_CMD_SEND_CODEC_INFO`
- `MPP_CMD_TRANS_FD_TO_IOVA`
- `MPP_CMD_RELEASE_FD`

Then `mpp_service_cmd_send()` marks multi-message and last-message flags and
submits the first request. Completion uses `MPP_CMD_POLL_HW_IRQ` when supported,
otherwise `MPP_CMD_POLL_HW_FINISH`.

This confirms the classic split: userspace sends prebuilt register payloads and
metadata; the kernel validates/copies/maps/schedules them.

## Buffer System

The public buffer API is in `inc/mpp_buffer.h`; the implementation is in
`mpp/base/mpp_buffer_impl.c`.

### Buffer Types

| Type | Meaning |
|------|---------|
| `MPP_BUFFER_TYPE_NORMAL` | malloc-like memory, mostly tests/simulation. |
| `MPP_BUFFER_TYPE_ION` | Historical ION allocator path; on new kernels may map to dma-heap. |
| `MPP_BUFFER_TYPE_EXT_DMA` | Import an application-provided dma-buf fd. |
| `MPP_BUFFER_TYPE_DRM` | DRM allocator path. |
| `MPP_BUFFER_TYPE_DMA_HEAP` | Linux dma-heap allocator. |

For kernel 5.10+ style systems, `mpp_allocator_get()` prefers dma-heap for ION,
DRM, and DMA_HEAP requests when dma-heap is available.

### Buffer Groups

MPP buffers are normally owned through `MppBufferGroup`.

| Group mode | Meaning |
|------------|---------|
| `MPP_BUFFER_INTERNAL` | MPP allocates and recycles buffers itself. |
| `MPP_BUFFER_EXTERNAL` | Application commits/imports buffers; MPP borrows/recycles them. |

| Limit mode | Meaning |
|------------|---------|
| normal | Allocate any size/count as needed. Useful for stream/table buffers. |
| limit | Restrict size/count. Useful for externally managed frame pools. |

The implementation tracks used/unused lists, refcounts, discard-on-reset, group
limits, callbacks, and optional debug logs. When a buffer is attached to a
device, MPP creates a `MppDevBufMapNode` tying together:

- the `MppBuffer`
- the dma-buf fd
- the `MppDev`
- the kernel-returned IOVA
- list links on both buffer and device sides

`mpp_buffer_get_iova()` attaches the buffer to the device if needed and returns
the cached IOVA. Cache operations such as `mpp_buffer_sync_partial_end()` are
used before hardware reads output/input ranges.

### dma-heap Details

`osal/allocator/allocator_dma_heap.c` probes these heaps:

- `system-uncached`
- `system-uncached-dma32`
- `system`
- `system-dma32`
- `cma-uncached`
- `cma-uncached-dma32`
- `cma`
- `cma-dma32`

If the exact heap is missing, it tries to remap by flipping cacheable and dma32
flags. Allocation uses `DMA_HEAP_IOCTL_ALLOC` and returns a dma-buf fd.

## Control and Config

`mpp_control()` dispatches commands by module:

| Command family | Handler |
|----------------|---------|
| OSAL/platform | `mpp_control_osal()` |
| common MPP | `mpp_control_mpp()` |
| codec common | `mpp_control_codec()` |
| decoder | `mpp_control_dec()` |
| encoder | `mpp_control_enc()` |
| ISP/image | `mpp_control_isp()` |

Common MPP controls include:

- input/output blocking timeout
- disable-thread mode
- KMPP encoder init config
- start/stop/pause/resume worker controls

Decoder controls include:

- external frame buffer group setup
- info-change ready
- pre-init decoder config storage
- runtime decoder config
- output format and fast-parse behavior

Encoder controls mostly delegate to `mpp_enc_control_v2()`, which serializes
most non-query commands through the encoder worker thread. This avoids changing
rate-control, HAL, or reference state while a frame is mid-encode.

### Config Objects

Both decoder and encoder configs are table-driven `KmppObj` objects.

| Config | Source | Examples |
|--------|--------|----------|
| `MppDecCfg` | `mpp/base/mpp_dec_cfg.c` | `base:fast_parse`, `base:out_fmt`, `base:hw_type`, `status:width` |
| `MppEncCfg` | `mpp/base/mpp_enc_cfg.c` | `rc:bps_target`, `prep:width`, `prep:format`, `h264:profile`, `h265:level` |

The macro tables define:

- string path
- element type
- struct field offset
- update-flag behavior
- aliases
- hierarchy

When code calls `mpp_enc_cfg_set_s32(cfg, "rc:bps_target", value)`, the KMPP
object layer resolves the name through a trie, writes the struct field, and sets
the relevant update flag. Encoder code then tests those flags to decide which
parts of RC, prep, headers, refs, or HAL need updating.

This is an important bridge to KMPP: classic MPP already expresses config as
structured objects with update flags. Newer KMPP appears to extend the same idea
across a kernel-shared object boundary.

## KMPP Hooks in This Library

The classic tree contains an optional KMPP path, but it is not the normal flow.

Known high-level hooks:

| Hook | Source | Meaning |
|------|--------|---------|
| `Mpp::mKmpp` | `mpp/inc/mpp.h` | Active KMPP context pointer. |
| `Mpp::mVencInitKcfg` | `mpp/inc/mpp.h` | Pre-init kernel encoder config object. |
| `MPP_SET_VENC_INIT_KCFG` | `mpp/mpp.c` | Stores KMPP encoder init config before init. |
| `mpp_ctx_init()` KMPP branch | `mpp/mpp.c` | Creates `Kmpp`, calls `mpp_get_api()`, returns early. |
| `mpp_put_frame()` KMPP branch | `mpp/mpp.c` | Encodes through `m->mKmpp->put_frame()`. |
| `mpp_get_packet()` KMPP branch | `mpp/mpp.c` | Gets output packet through `m->mKmpp->get_packet()`. |
| `mpp_reset()` KMPP branch | `mpp/mpp.c` | Resets through `m->mKmpp->reset()`. |

The object layer in `kmpp/base/kmpp_obj.c` also defines device-facing ioctls for:

- `/dev/kmpp_objs` style object definition and shared-memory query
- `/dev/kmpp_ioctl` style command processing
- shared `KmppShmPtr` object mapping
- object ioctl with input/output objects

The current userspace tree therefore contains both:

1. The mature classic MPP path through `/dev/mpp_service`.
2. A newer object-oriented KMPP path intended to share richer objects and move
   more MPP runtime state into the kernel.

## Debug and Runtime Knobs

The library reads many environment variables with `mpp_env_get_u32()`. Useful
ones found in the studied paths:

| Variable | Area |
|----------|------|
| `mpi_debug` | Public MPI wrapper logging. |
| `mpp_debug` | Top-level MPP context logging. |
| `mpp_task_debug` | Task queue state transitions. |
| `mpp_buffer_debug` | Buffer lifecycle/refcount/group logging. |
| `mpp_dec_debug` | Decoder runtime and timing. |
| `mpp_hal_debug` | Decoder HAL API selection/flow. |
| `mpp_enc_hal_debug` | Encoder HAL API selection/flow. |
| `mpp_device_debug` | Device probing, request, and buffer-map logging. |
| `dma_heap_debug` | dma-heap probing and allocation. |
| `disable_rcb_info` | Disables RCB info submission in `mpp_service`. |
| `enable_deinterlace` | Overrides decoder post-process/deinterlace enable. |

The exact bit meanings vary by module. Most modules define local `*_DBG_*`
bitmasks near the top of their source file.

## Practical Mental Models

### MPP is queue-driven

Even the simple API quickly becomes queue/list work. If a call seems to block,
look at:

- input/output timeout controls
- task queue port state
- `mFrmOut` or `mPktOut` list size
- decoder info-change wait
- encoder output task availability

### Decode is parser plus slots plus HAL

For decode bugs, classify the failure:

| Symptom | Likely layer |
|---------|--------------|
| stream not accepted | parser `prepare`/`parse` |
| resolution/format mismatch | frame slot setup/info-change |
| stalls after resolution change | app did not complete info-change ready flow |
| DMA/import failure | buffer group or `MppDev` fd attach |
| hardware timeout | HAL register generation or kernel service/device |

### Encode is scheduler plus RC plus codec control plus HAL

For encode bugs, classify the failure:

| Symptom | Likely layer |
|---------|--------------|
| wrong bitrate/QP | RC config/update path |
| missing/incorrect SPS/PPS/VPS | `enc_impl_gen_hdr` or header status |
| frame order/reference issue | `MppEncRefs` and codec DPB processing |
| no output packet | output task/list or packet buffer setup |
| hardware timeout | encoder HAL register generation or device service |

### The kernel ABI is a register-task ABI

In classic MPP, the ABI is not "send H.264 packet, receive frame". It is closer
to:

```text
send device client type
translate dma-buf fds to device addresses
send codec info
send register writes/reads
send register address-offset metadata
send optional RCB metadata
submit task
poll completion
read status registers / slice info
```

That is why classic userspace and kernel must agree on subtle hardware details.
KMPP appears motivated by reducing that fragile userspace/kernel split.

## What This Explains About Rockchip's KMPP Direction

The classic design gives Rockchip a lot of userspace flexibility, but it also
means every userspace release carries hardware-specific scheduling assumptions,
register layouts, buffer metadata, and codec runtime behavior. The newer KMPP
direction is easier to understand after reading this code:

- The library already has structured task/config objects.
- The library already has clear "codec runtime" objects that could live in the
  kernel.
- The current kernel ABI already has to translate many dma-bufs, register
  offsets, RCB buffers, and codec-info sideband messages.
- Moving more of that state into the kernel can make scheduling, security,
  timeout handling, and ABI compatibility easier.

So KMPP is not a random replacement for MPP. It looks like Rockchip taking the
existing MPP object/task architecture and moving the most hardware-coupled parts
behind a richer kernel interface.
