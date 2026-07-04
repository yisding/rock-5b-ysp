# MPP and KMPP reverse-engineering notes

These notes summarize what we learned from the public Rockchip MPP userspace tree
and from the Luckfox RV1106 kernel package. They are not a replacement for the
main userspace guide in [`how-the-userspace-libs-work.md`](../../docs/how-the-userspace-libs-work.md);
they focus on the newer `kmpp` path and the boundary between known facts and
inference.

## Sources examined

| Source | What it contributed |
|--------|---------------------|
| `mpp-rockchip` userspace tree at `1375813cbbae5ad6861b166475dd8fb672183220` | Current userspace MPP/KMPP headers, object model, high-level MPI integration, tests, and `/dev/vcodec` client wrapper. |
| LuckfoxTECH `luckfox-pico` at `824b817f889c2cbff1d48fcdb18ab494a68f69d1` | Public RV1106 SDK package containing a newer kernel-side `kmpp` drop as a prebuilt module and generated ARM assembly. |
| Luckfox `release_version.txt` | The packaged `mpp_vcodec` module identifies an internal Rockchip source commit `424abb9bffcc6f077daa00572bca1301c757e079`, dated 2024-04-25, with subject `[mpp_enc]: fix wrap enc sw timeout when resolution switch`. |
| Older public `rockchip-kmpp` source lineage | Useful comparison point for the older `/dev/vcodec` channel ABI, especially `OUT_STRM_BUF_RDY` versus the newer `OUT_PKT_RDY` path. |

Luckfox package locations:

- <https://github.com/LuckfoxTECH/luckfox-pico/tree/main/sysdrv/drv_ko/kmpp>
- <https://github.com/LuckfoxTECH/luckfox-pico/blob/main/sysdrv/drv_ko/kmpp/release_kmpp_rv1106_arm_asm/Makefile>
- <https://github.com/LuckfoxTECH/luckfox-pico/blob/main/sysdrv/drv_ko/kmpp/release_kmpp_rv1106_arm_asm/vcodec/mpp_vcodec_driver.S>
- <https://github.com/LuckfoxTECH/luckfox-pico/blob/main/sysdrv/drv_ko/kmpp/release_kmpp_rv1106_arm_asm/vcodec/mpp_vcodec_chan.S>
- <https://github.com/LuckfoxTECH/luckfox-pico/blob/main/sysdrv/drv_ko/kmpp/release_kmpp_rv1106_arm_asm/release_version.txt>

## Short version

Rockchip has two related codec stacks:

1. **Classic MPP**: userspace `librockchip_mpp` owns codec parsing, frame state,
   rate control, HAL register generation, and buffer pools. The kernel exposes
   `/dev/mpp_service`, validates and maps dma-bufs, schedules tasks, writes
   registers, waits for interrupts, and returns result registers.
2. **KMPP**: Rockchip moves much more of MPP into the kernel. Userspace still
   calls MPI-style APIs, but it can divert into a kernel-resident encoder/decoder
   path through `/dev/vcodec` and, in the newer object design, through
   `/dev/kmpp_objs` and `/dev/kmpp_ioctl`.

The important compatibility finding is that there are at least two KMPP ABI
generations:

| Generation | Evidence | Output interface |
|------------|----------|------------------|
| Older `/dev/vcodec` channel ABI | Luckfox RV1106 kernel package and older public kmpp source | `VCODEC_CHAN_OUT_STRM_BUF_RDY` + `VCODEC_CHAN_OUT_STRM_END` |
| Newer shared-object ABI | Current `mpp-rockchip` userspace tree | `VCODEC_CHAN_OUT_PKT_RDY` returning a shared `KmppPacket` object |

The Luckfox kernel package is newer than the older public source, but it still
appears to implement the older stream-buffer output ABI. The current userspace
tree expects the newer packet-object ABI for its high-level KMPP encode path.

## Classic MPP architecture

Classic MPP is a split-responsibility design:

```text
application
  -> librockchip_mpp MPI API
    -> Mpp context, ports, tasks, buffers
      -> codec parser / encoder control / rate control
        -> HAL register builder
          -> /dev/mpp_service ioctl messages
            -> kernel MPP service, IOMMU, scheduler, hardware subdriver
```

The key point for this project is that classic MPP userspace is not a thin V4L2
shim. Userspace generates the hardware recipe. The kernel service runs that
recipe safely:

- Userspace parses H.264/H.265/VP9/JPEG syntax and tracks codec state.
- Userspace manages `MppPacket`, `MppFrame`, `MppBuffer`, `MppTask`, and
  `MppBufferGroup`.
- Userspace HAL code builds register tables for the selected hardware block.
- The kernel imports dma-bufs, maps them to IOVAs, copies bounded register
  payloads, schedules the task, handles IRQ completion, and reports status.

This is the model documented in the existing kernel and userspace guides. KMPP
does not replace the need to understand it; KMPP reuses many of the same internal
concepts but moves more of the machinery into kernel space.

## What KMPP is trying to do

KMPP appears to be Rockchip's kernel-resident form of MPP. Instead of keeping
codec control, rate control, packet/frame objects, and HAL work entirely in
userspace, the kernel module contains large pieces of the MPP stack.

The Luckfox module confirms this direction. Its generated assembly package pulls
in objects that look like kernel builds of familiar MPP components:

```text
mpp_service
mpp_iommu
mpp_rkvenc_540c
vepu_pp
mpp_buffer
mpp_packet
mpp_frame
mpp_enc_cfg
mpp_enc_impl
h264e / h265e / jpege encoder logic
rate control
vepu540c HAL
mpp_vcodec_driver
mpp_vcodec_chan
```

That is stronger than a normal kernel driver. It is a kernel-side encoder stack
with channel management, buffers, packets, encoder control, HAL, and scheduler
pieces packaged together.

## The older `/dev/vcodec` ABI

Both the Luckfox package and older public kmpp source point to a classic channel
ABI centered on `/dev/vcodec`.

Userspace request wrapper:

```c
struct vcodec_req {
    u32 cmd;
    u32 ctrl_cmd;
    u32 size;
    u64 data;
};
```

The ioctl command is:

```text
VOCDEC_IOC_CFG = _IOW('V', 1, unsigned int)
```

The current userspace wrapper still contains this in
`osal/driver/mpp_vcodec_client.c`:

```text
open("/dev/vcodec", O_RDWR | O_CLOEXEC)
ioctl(fd, VOCDEC_IOC_CFG, &vcodec_req)
```

Recovered channel event IDs:

| Event | Value | Meaning |
|-------|-------|---------|
| `VCODEC_CHAN_CREATE` | `0x000` | Create channel. |
| `VCODEC_CHAN_DESTROY` | `0x001` | Destroy channel. |
| `VCODEC_CHAN_RESET` | `0x002` | Reset channel. |
| `VCODEC_CHAN_CONTROL` | `0x003` | Per-channel control command. |
| `VCODEC_CHAN_START` | `0x100` | Start. |
| `VCODEC_CHAN_STOP` | `0x101` | Stop. |
| `VCODEC_CHAN_PAUSE` | `0x102` | Pause. |
| `VCODEC_CHAN_RESUME` | `0x103` | Resume. |
| `VCODEC_CHAN_IN_FRM_RDY` | `0x400` | Input frame is ready. |
| `VCODEC_CHAN_OUT_STRM_Q_FULL` | `0x600` | Output stream queue full. |
| `VCODEC_CHAN_OUT_STRM_BUF_RDY` | `0x601` | Get output stream buffer. |
| `VCODEC_CHAN_OUT_STRM_END` | `0x602` | Return/release output stream buffer. |
| `VCODEC_CHAN_OUT_PKT_RDY` | `0x603` | Newer packet-object output path. |

Luckfox implements the table through `0x602`. The current userspace header adds
`0x603` with the comment `new get packet interface`.

### Luckfox `/dev/vcodec` dispatch details

The Luckfox assembly makes the older ABI more concrete. Its `vcodec_ioctl`
handler checks for ioctl value `1074025985`, which is:

```text
0x40045601 == _IOW('V', 1, unsigned int)
```

It copies a 24-byte request envelope from userspace:

| Offset | Field | Notes |
|--------|-------|-------|
| `0x00` | `cmd` | Channel event ID. |
| `0x04` | `ctrl_cmd` | Per-control command for `VCODEC_CHAN_CONTROL`. |
| `0x08` | `size` | Byte size of the payload pointed to by `data`. |
| `0x0c` | padding | Alignment before the 64-bit field. |
| `0x10` | `data` | Userspace pointer copied as a 64-bit value. |

Then it dispatches these event IDs:

| Event ID | Handler in Luckfox assembly | Payload direction |
|----------|-----------------------------|-------------------|
| `0x000` | `mpp_vcodec_chan_create` | copy payload in, mutate it, copy payload out |
| `0x001` | `mpp_vcodec_chan_destory` | no payload |
| `0x002` | reset fast path | no payload |
| `0x003` | `mpp_vcodec_chan_control` | optional copy in, optional copy out |
| `0x100` | `mpp_vcodec_chan_start` | no payload |
| `0x101` | `mpp_vcodec_chan_stop` | no payload |
| `0x102` | `mpp_vcodec_chan_pause` | no payload |
| `0x103` | `mpp_vcodec_chan_resume` | no payload |
| `0x400` | `mpp_vcodec_chan_push_frm` | copy frame info in |
| `0x601` | `mpp_vcodec_chan_get_stream` | fill stream descriptor, copy out |
| `0x602` | `mpp_vcodec_chan_put_stream` | copy stream descriptor in |

There is no observed branch for `0x603` in that driver.

For `VCODEC_CHAN_CREATE`, Luckfox checks that the pointed-to payload is exactly
60 bytes and logs that the kernel/user `vcodec_attr` definitions differ if it is
not. That is the older create contract. Current `mpp-rockchip` userspace does
not send a 60-byte attr through its high-level KMPP path; it sends a
`KmppShmPtr` for a `KmppVencInitCfg` shared object.

For `VCODEC_CHAN_OUT_STRM_BUF_RDY`, `mpp_vcodec_chan_get_stream` fills a
184-byte stream descriptor. The exact C struct is not public in the Luckfox drop,
but the assembly calls packet getters and writes these fields:

| Offset | Inferred field | Evidence |
|--------|----------------|----------|
| `0x00` | stream data address / packet position | loaded from the kernel packet before copyout |
| `0x08` | packet token / handle | written from the kernel packet pointer; used by put-stream matching |
| `0x10` | `length` | result of `mpp_packet_get_length()` |
| `0x14` | buffer `size` | result of `mpp_buffer_get_size_with_caller()` |
| `0x18` | `pts` | result of `mpp_packet_get_pts()` |
| `0x20` | `dts` | result of `mpp_packet_get_dts()` |
| `0x28` | `flag` | result of `mpp_packet_get_flag()` |
| `0x2c` | `temporal_id` | result of `mpp_packet_get_temporal_id()` |
| `0x30` | `status` | loaded from the packet object |
| `0x34` | ready/valid marker | assembly writes `1` |

The rest of the 184-byte descriptor is unknown or reserved from the evidence we
have. The empty-stream/error path clears the full 184 bytes before returning.

For `VCODEC_CHAN_IN_FRM_RDY`, the old frame payload is also struct-like. The
Luckfox assembly reads a dma-buf fd at offset `0x20`. That matches the
unused/legacy-looking `KmppFrameInfos` layout still present in `kmpp/kmpp.c`,
where the first fields are:

| Offset | Field |
|--------|-------|
| `0x00` | `width` |
| `0x04` | `height` |
| `0x08` | `hor_stride` |
| `0x0c` | `ver_stride` |
| `0x10` | `hor_stride_pixel` |
| `0x14` | `offset_x` |
| `0x18` | `offset_y` |
| `0x1c` | `fmt` |
| `0x20` | dma-buf `fd` |

That gives a plausible bridge between the older struct ABI and the newer
`KmppFrame` shared-object ABI: the same semantic fields are being carried, but
the newer path moves them into a kernel-described object.

## What the Luckfox kernel package tells us

The Luckfox SDK does not publish the original KMPP C source. It publishes:

- a prebuilt `mpp_vcodec.ko`;
- a generated ARM assembly release tree;
- Makefiles that link the assembly release into `drivers/kmpp`;
- a release marker from an internal Rockchip source commit.

The module metadata reports:

```text
module:    mpp_vcodec
license:   GPL
depends:   rk_dvbm
vermagic:  5.10.160 mod_unload ARMv7 thumb2 p2v8
```

Notable parameters include:

```text
mpp_dev_debug
rc_debug
hal_h264e_debug
hal_h265e_debug
mpp_enc_debug
ring_buf_debug
thread_debug
max_packet_num
max_stream_cnt
```

Recovered symbols and strings show:

```text
rockchip,vcodec
vcodec_class
venc_info
vdec_info
mpp_vcodec_chan_create
mpp_vcodec_chan_start
mpp_vcodec_chan_stop
mpp_vcodec_chan_control
mpp_vcodec_chan_push_frm
mpp_vcodec_chan_get_stream
mpp_vcodec_chan_put_stream
vcodec_msg_enc_out_strm_buf_rdy
vcodec_msg_enc_out_strm_end
```

Important negative findings:

```text
no KMPP_SHM
no kmpp_objs
no kmpp_ioctl
no KmppObj/KmppPacket object-device symbols
no VCODEC_CHAN_OUT_PKT_RDY handler
```

The Luckfox driver assembly checks for the same `VOCDEC_IOC_CFG` ioctl and copies
a 24-byte request structure. Its create path expects a 60-byte `vcodec_attr`-style
payload, copies it in, calls `mpp_vcodec_chan_create`, copies it back to userspace,
and updates channel identity fields. That matches the older stream-buffer shape,
not the newer shared-object packet path.

## The newer KMPP object model

The current userspace tree contains a generic object system under `kmpp/base`.
This is the clearest evidence for Rockchip's newer KMPP design.

Public opaque types include:

```c
typedef void *KmppObjDef;
typedef void *KmppObj;
typedef void *KmppShm;
typedef void *KmppMeta;
typedef void *KmppFrame;
typedef void *KmppPacket;
typedef void *KmppBuffer;
typedef void *KmppBufGrp;
```

The shared pointer is the key wire object:

```c
typedef struct KmppShmPtr_t {
    union {
        rk_u64 uaddr;
        void *uptr;
    };
    union {
        rk_u64 kaddr;
        void *kptr;
    };
} KmppShmPtr;
```

The comment says it must match the kernel `KmppObjShm` definition in
`rk-mpp-kobj.h`. That kernel header is not in the public userspace tree, but the
userspace contract is explicit: every shared object carries both userspace and
kernel addresses.

### Object discovery

Userspace opens:

```text
/dev/kmpp_objs
/dev/kmpp_ioctl
```

and asks each device for a trie root:

```text
KMPP_SHM_IOC_QUERY_INFO
KMPP_IOCTL_IOC_QUERY_INFO
```

The kernel publishes:

- object definitions by name;
- object entry sizes;
- field offsets and element types;
- object indices;
- ioctl/method command tables.

Userspace then constructs local wrappers around those kernel-published schemas.

This is why KMPP configs can be addressed by strings such as:

```text
type
coding
chan_id
chan_dup
chan_fd
prep:width
prep:height
rc:bps_target
h264:profile
```

The object system uses tries so these names resolve to offsets and update flags
without hardcoding a C struct definition in every caller.

### Shared object allocation

For a kernel object, userspace asks `/dev/kmpp_objs` for a shared allocation by
object name. The kernel returns a `KmppShmPtr`. Userspace wraps that shared memory
as a local `KmppObjImpl` and treats the object's entry body as:

```text
entry = shm.uaddr + kernel-published entry_offset
```

The kernel uses the same shared object through:

```text
shm.kaddr + entry_offset
```

When a kernel returns a shared pointer, userspace can reconstruct the object with
`kmpp_obj_get_by_sptr()`.

### Generic object ioctl

The newer object ioctl path is built around a `KmppIoc` object with fields:

```text
def
cmd
flags
id
ret
ctx
in
out
```

The wrapper fills this object, points `/dev/kmpp_ioctl` at its shared memory, and
then calls ioctl. The kernel reads:

- which object definition is being invoked;
- which method command is requested;
- the shared object for `ctx`;
- optional shared object for `in`;
- optional shared object for `out`.

The generated user APIs for `kmpp_venc`, `kmpp_vdec`, `kmpp_buffer`, and buffer
groups are all thin wrappers over this generic object ioctl mechanism.

## Reconstructed newer ioctl surfaces

The current userspace tree exposes three distinct KMPP ioctl surfaces. They are
easy to conflate, but they serve different roles:

| Device | Role |
|--------|------|
| `/dev/kmpp_objs` | Discover object layouts and allocate/release shared objects. |
| `/dev/kmpp_ioctl` | Dispatch methods against shared objects. |
| `/dev/vcodec` | High-level channel/event interface used by the MPI-compatible KMPP path. |

### `/dev/kmpp_objs`: schema and shared-memory manager

The userspace definitions in `kmpp/base/kmpp_obj.c` are:

```c
#define KMPP_SHM_IOC_MAGIC              'm'
#define KMPP_SHM_IOC_QUERY_INFO         _IOW('m', 1, unsigned int)
#define KMPP_SHM_IOC_RELEASE_INFO       _IOW('m', 2, unsigned int)
#define KMPP_SHM_IOC_GET_SHM            _IOW('m', 3, unsigned int)
#define KMPP_SHM_IOC_PUT_SHM            _IOW('m', 4, unsigned int)
#define KMPP_SHM_IOC_DUMP               _IOW('m', 5, unsigned int)
```

Despite the `_IOW(..., unsigned int)` macro argument, userspace passes pointers
to richer payloads.

`KMPP_SHM_IOC_QUERY_INFO`

- Input: pointer to a zeroed `rk_u64`.
- Output: kernel writes a userspace address into that `rk_u64`.
- Meaning: the address is the root of a kernel-published `MppTrie` blob.
- Userspace uses it to discover object names, sizes, field offsets, object
  indices, entry offsets, private offsets, and name offsets.

`KMPP_SHM_IOC_RELEASE_INFO`

- Defined in userspace, but not observed in the current callers.
- The current `kmpp_ktrie_put()` path closes the fd and deinitializes the local
  trie wrapper.

`KMPP_SHM_IOC_GET_SHM`

Userspace passes a variable-length header:

```c
typedef struct KmppObjIocArg_t {
    __u32 count;
    __u32 flag;
    union {
        __u64      name_uaddr[0];
        KmppShmPtr obj_sptr[0];
        KmppShmReq shm_req[0];
    };
} KmppObjIocArg;

typedef struct KmppShmReq_t {
    __u64 shm_name;
    __u32 shm_size;
    __u32 shm_flag;
} KmppShmReq;
```

There are two observed request forms:

| Use | Input union | Output union |
|-----|-------------|--------------|
| Allocate a typed kernel object | `name_uaddr[0] = (u64)object_name` | `obj_sptr[0].uaddr` points to a returned `KmppShmPtr` |
| Allocate raw shared memory | `shm_req[0] = { .shm_name = 0, .shm_size = size, .shm_flag = 0 }` | `obj_sptr[0].uaddr` points to a returned `KmppShmPtr` |

The shared pointer itself is:

```c
typedef struct KmppShmPtr_t {
    union { rk_u64 uaddr; void *uptr; };
    union { rk_u64 kaddr; void *kptr; };
} KmppShmPtr;
```

`uaddr` is what userspace dereferences. `kaddr` is the matching kernel-side
address or token that userspace preserves and passes back.

`KMPP_SHM_IOC_PUT_SHM`

- Input: `KmppObjIocArg` with `obj_sptr[0]` set to the object's `uaddr/kaddr`.
- Output: ioctl return code only.
- Meaning: release a typed object or raw shared-memory allocation.

`KMPP_SHM_IOC_DUMP`

- Input: pointer to `KmppShmPtr` for an object.
- Output: ioctl return code; kernel logs/dumps the object.

### `/dev/kmpp_ioctl`: generic object method dispatcher

The userspace definitions are:

```c
#define KMPP_IOCTL_IOC_MAGIC            'i'
#define KMPP_IOCTL_IOC_QUERY_INFO       _IOW('i', 1, unsigned int)
#define KMPP_IOCTL_IOC_PROC             _IOW('i', 2, unsigned int)
```

`KMPP_IOCTL_IOC_QUERY_INFO` is used like the object query ioctl: the kernel
returns a trie root. That trie maps object names to method-name tables.

`KMPP_IOCTL_IOC_PROC` is defined but the current userspace dispatcher does not
call it. `kmpp_obj_ioctl()` fills a `KmppIoc` object, wraps its shared pointer in
`KmppObjIocArg`, and calls:

```c
ioctl(p->ioc.fd, 0, ioc_arg);
```

That is an important reverse-engineering finding. Either the kernel uses ioctl
number `0` for the process operation in this ABI generation, or this userspace
tree is out of sync with the symbolic define.

The command object passed through shared memory is:

```text
KmppIoc {
    u32        def;    // kernel object-definition index
    u32        cmd;    // method command index
    u32        flags;
    u32        id;
    s32        ret;    // kernel writes operation result here
    KmppShmPtr ctx;    // context object
    KmppShmPtr in;     // optional input object
    KmppShmPtr out;    // optional output object
}
```

The method command number is not compiled into userspace for codec objects.
Generated wrappers call:

```text
kmpp_objdef_get_cmd(def, "method_name")
```

and the numeric command is read from the kernel-published trie. So we can recover
method names and input/output object types from userspace, but not the exact
numeric command IDs without the kernel trie or a live target.

Known native method signatures:

| Object | Method | Input | Output |
|--------|--------|-------|--------|
| `KmppVenc` | `init` | `MppVencKcfg` | none |
| `KmppVenc` | `deinit` | none | none |
| `KmppVenc` | `reset` | none | none |
| `KmppVenc` | `start` | none | none |
| `KmppVenc` | `stop` | none | none |
| `KmppVenc` | `suspend` | none | none |
| `KmppVenc` | `resume` | none | none |
| `KmppVenc` | `get_cfg` | `MppVencKcfg` destination object | none |
| `KmppVenc` | `set_cfg` | `MppVencKcfg` | none |
| `KmppVenc` | `encode` | `KmppFrame` | `KmppPacket` |
| `KmppVenc` | `put_frm` | `KmppFrame` | none |
| `KmppVenc` | `get_pkt` | none | `KmppPacket` |
| `KmppVenc` | `put_pkt` | `KmppPacket` | none |
| `KmppVdec` | `init` | `MppVdecKcfg` | none |
| `KmppVdec` | `deinit` | none | none |
| `KmppVdec` | `reset` | none | none |
| `KmppVdec` | `start` | none | none |
| `KmppVdec` | `stop` | none | none |
| `KmppVdec` | `get_cfg` | `MppVdecKcfg` destination object | none |
| `KmppVdec` | `set_cfg` | `MppVdecKcfg` | none |
| `KmppVdec` | `get_rt_cfg` | `MppVdecKcfg` destination object | none |
| `KmppVdec` | `set_rt_cfg` | `MppVdecKcfg` | none |
| `KmppVdec` | `decode` | `KmppPacket` | `KmppFrame` |
| `KmppVdec` | `put_pkt` | `KmppPacket` | none |
| `KmppVdec` | `get_frm` | none | `KmppFrame` |
| `KmppVdec` | `put_frm` | `KmppFrame` | none |

Buffer object methods are partly legacy-numbered in userspace:

| Object | Method | Observed numeric command |
|--------|--------|--------------------------|
| `KmppBufGrp` | `setup` | `0` |
| `KmppBuffer` | `setup` | `0` |
| `KmppBuffer` | `inc_ref` | `1` |
| `KmppBuffer` | `flush` | `2` |

For those `IOC_CTX(..., number)` helpers, the wrapper passes the object as both
`ctx` and `in`.

### `/dev/vcodec`: newer packet-object channel path

Current userspace still uses the same outer request envelope:

```c
typedef struct vcodec_req_t {
    RK_U32 cmd;
    RK_U32 ctrl_cmd;
    RK_U32 size;
    RK_U64 data;
} vcodec_req;
```

The high-level `kmpp/kmpp.c` path sends these payloads:

| Event | `ctrl_cmd` | `size` | `data` points to | Direction |
|-------|------------|--------|------------------|-----------|
| `VCODEC_CHAN_CREATE` (`0x000`) | `0` | `sizeof(KmppShmPtr)` | shared pointer for `KmppVencInitCfg` | in/out through shared object |
| `VCODEC_CHAN_DESTROY` (`0x001`) | `0` | `0` | `NULL` | none |
| `VCODEC_CHAN_RESET` (`0x002`) | `0` | `0` | `NULL` | none |
| `VCODEC_CHAN_CONTROL` (`0x003`) | `MpiCmd` | command-specific | command-specific pointer | in/out or in |
| `VCODEC_CHAN_START` (`0x100`) | `0` | `0` | `NULL` | none |
| `VCODEC_CHAN_STOP` (`0x101`) | `0` | `0` | `NULL` | defined, but not sent by current `stop()` wrapper |
| `VCODEC_CHAN_PAUSE` (`0x102`) | `0` | `0` | `NULL` | none |
| `VCODEC_CHAN_RESUME` (`0x103`) | `0` | `0` | `NULL` | none |
| `VCODEC_CHAN_IN_FRM_RDY` (`0x400`) | `0` | `sizeof(KmppShmPtr)` | shared pointer for `KmppFrame` | in |
| `VCODEC_CHAN_OUT_PKT_RDY` (`0x603`) | `0` | `sizeof(KmppShmPtr)` | stack `KmppShmPtr` storage | out |

Observed details:

- Before `CREATE`, userspace reads `chan_dup` from `KmppVencInitCfg` and writes
  `chan_fd` into it.
- After `CREATE`, userspace reads `chan_id` back from the same config object.
- If `chan_dup` is false, userspace sends `START` immediately after `CREATE`.
- Current `kmpp/kmpp.c::stop()` appears to send `VCODEC_CHAN_START`, not
  `VCODEC_CHAN_STOP`. That looks like a bug or placeholder in the examined tree,
  so the table above records the defined ABI separately from observed calls.
- `OUT_PKT_RDY` is not a stream-copy operation. Userspace passes storage for a
  `KmppShmPtr`; the kernel fills it with a shared `KmppPacket` pointer.

Command-specific `VCODEC_CHAN_CONTROL` payloads in the high-level wrapper:

| `MpiCmd` group | Payload |
|----------------|---------|
| `MPP_ENC_SET_CFG`, `MPP_ENC_GET_CFG` | Must be a KMPP object; payload is its `KmppShmPtr`. |
| `MPP_ENC_SET_HEADER_MODE`, `MPP_ENC_SET_SEI_CFG` | `u32`. |
| `MPP_ENC_GET_REF_CFG`, `MPP_ENC_SET_REF_CFG` | `MppEncRefParam`. |
| `MPP_ENC_GET_ROI_CFG`, `MPP_ENC_SET_ROI_CFG` | `MppEncROICfgLegacy`. |
| `MPP_ENC_SET_JPEG_ROI_CFG`, `MPP_ENC_GET_JPEG_ROI_CFG` | `MppJpegROICfg`. |
| `MPP_ENC_SET_OSD_DATA_CFG` | `MppEncOSDData3`. |
| `MPP_ENC_SET_USERDATA` | `MppEncUserData`. |
| `MPP_SET_VENC_INIT_KCFG` | KMPP object shared pointer. |
| `MPP_ENC_SET_IDR_FRAME` | no payload. |
| `MPP_SET_SELECT_TIMEOUT` | local userspace setting only; no ioctl sent. |
| default | current wrapper returns `MPP_OK` without sending an ioctl. |

### Shared payload objects

These are the important object payloads visible in current userspace headers.
The actual offsets come from the kernel-published object definition when a kernel
object exists, but these tables show the semantic fields userspace expects.

`KmppFrame`

```text
width
height
hor_stride
ver_stride
hor_stride_pixel
offset_x
offset_y
poc
pts
dts
eos
color_range
color_primaries
color_trc
colorspace
chroma_location
fmt
buf_size
buf_fd
is_gray
buffer        // KmppShmPtr
sar           // MppFrameRational
```

The frame helper also asks the object schema for a `meta` shared field by name.

`KmppPacket`

```text
size
length
pts
dts
status
temporal_id
data          // KmppShmPtr
buffer        // KmppShmPtr
pos           // KmppShmPtr
meta          // KmppShmPtr
flag
```

`KmppBufGrpCfg`

```text
flag
count
size
mode
fd
grp_id
used
unused
name          // KmppShmPtr
allocator     // KmppShmPtr
```

`KmppBufCfg`

```text
size
offset
flag
fd
index
grp_id
buf_gid
buf_uid
sptr          // KmppShmPtr
group         // KmppShmPtr
uptr
upriv
ufp
```

Config object definitions are mostly kernel-provided:

| Userspace type | Kernel object names requested |
|----------------|-------------------------------|
| `MppVencKcfg` | `KmppVencInitCfg`, `KmppVencDeinitCfg`, `KmppVencResetCfg`, `KmppVencStartCfg`, `KmppVencStopCfg`, `KmppVencStCfg` |
| `MppVdecKcfg` | `KmppVdecInitCfg`, `KmppVdecDeinitCfg`, `KmppVdecResetCfg`, `KmppVdecStartCfg`, `KmppVdecStopCfg` |

Observed VENC init keys include `type`, `coding`, `chan_id`, `online`,
`buf_size`, `max_strm_cnt`, `shared_buf_en`, `smart_en`, `max_width`,
`max_height`, `max_lt_cnt`, `qpmap_en`, `chan_dup`, `tmvp_enable`,
`only_smartp`, `ntfy_mode`, `input_timeout`, and the wrapper-written `chan_fd`.

Observed VENC stream-config keys include `codec:type`, `prep:*`, `rc:*`,
`h264:*`, and `jpeg:*` names used by `kmpp_venc_test.c`.

### Confidence boundaries

High confidence:

- ioctl numbers and request envelopes present in current userspace;
- `/dev/vcodec` event IDs and current wrapper payload pointers/sizes;
- `/dev/kmpp_objs` argument structs and allocation/release call flow;
- `/dev/kmpp_ioctl` `KmppIoc` fields and native method input/output types;
- Luckfox support through `0x602` and absence of observed `0x603`.

Medium confidence:

- exact meanings of some older Luckfox stream descriptor fields;
- output mutation details inside shared config objects beyond `chan_id`;
- whether the `ioctl(fd, 0, ...)` object-dispatch command is intentional ABI or
  a userspace/kernel version mismatch.

Low confidence without a live newer kernel:

- numeric command IDs for native `KmppVenc`/`KmppVdec` methods;
- full field layout of kernel-provided config objects;
- whether newer kernels keep both stream output (`0x601`/`0x602`) and packet
  output (`0x603`) active at the same time.

## KMPP VENC API in the current userspace tree

The current tree exposes two VENC paths.

### MPI-compatible path

The high-level `Mpp` object diverts into KMPP when the application sets:

```text
MPP_SET_VENC_INIT_KCFG
```

The test path creates a `MppVencKcfg` named `KmppVencInitCfg`, sets fields like:

```text
type
coding
chan_id
online
buf_size
max_strm_cnt
shared_buf_en
smart_en
max_width
max_height
max_lt_cnt
qpmap_en
chan_dup
tmvp_enable
only_smartp
ntfy_mode
input_timeout
```

then calls `mpp_init()`. In that case `mpp_init()` allocates a `Kmpp` context,
opens `/dev/vcodec`, sends `VCODEC_CHAN_CREATE` with a `KmppShmPtr`, optionally
starts the channel, and routes `mpp_put_frame()` / `mpp_get_packet()` through the
KMPP operations table.

The frame input path converts a normal `MppFrame` into a shared `KmppFrame` when
needed, including:

```text
width
height
strides
format
pts/dts
offsets
dma-buf fd
eos
```

It then sends that object through:

```text
VCODEC_CHAN_IN_FRM_RDY
```

The packet output path waits on `select()` for `/dev/vcodec`, then calls:

```text
VCODEC_CHAN_OUT_PKT_RDY
```

The kernel returns a `KmppShmPtr` for a `KmppPacket`. Userspace reads:

```text
length
flag
pos
pts
dts
meta
```

and either copies into a caller-supplied `MppPacket` or wraps the kernel packet
with a release callback that calls `kmpp_packet_put()`.

### Direct object path

There is also a more native KMPP object API:

```text
kmpp_venc_get()
kmpp_venc_init()
kmpp_venc_get_cfg()
kmpp_venc_set_cfg()
kmpp_venc_encode()
kmpp_venc_put_frm()
kmpp_venc_get_pkt()
kmpp_venc_put_pkt()
```

The test `kmpp_venc_test.c` uses this path directly:

1. Get a `KmppVenc` object.
2. Allocate a `KmppVencInitCfg`.
3. Initialize the encoder.
4. Get/set the runtime `KmppVencStCfg`.
5. Allocate a `KmppBuffer`.
6. Attach it to a `KmppFrame`.
7. Send the frame with `kmpp_venc_put_frm()`.
8. Receive a `KmppPacket` with `kmpp_venc_get_pkt()`.

This is cleaner than the MPI-compatible path, but it requires a kernel that
implements the newer `/dev/kmpp_objs` and `/dev/kmpp_ioctl` object ABI.

## KMPP VDEC status

The current userspace tree has a `kmpp_vdec` object API:

```text
kmpp_vdec_init()
kmpp_vdec_get_cfg()
kmpp_vdec_set_cfg()
kmpp_vdec_get_rt_cfg()
kmpp_vdec_set_rt_cfg()
kmpp_vdec_decode()
kmpp_vdec_put_pkt()
kmpp_vdec_get_frm()
kmpp_vdec_put_frm()
```

Its headers carry 2025 copyright notices, and there is a `kmpp_vdec_test.c`.
However, the high-level `mpp.c` integration we examined is primarily VENC-focused:

- `put_packet()` is effectively a stub;
- `get_frame()` is effectively a stub;
- `poll()`, `dequeue()`, and `enqueue()` are also stubby in the KMPP operations
  table.

So VDEC looks like a planned or emerging object API, not something we should
assume is wired through the MPI-compatible path in the examined tree.

## Compatibility matrix

| Userspace expectation | Luckfox RV1106 kernel package | Current `mpp-rockchip` userspace |
|----------------------|-------------------------------|----------------------------------|
| `/dev/vcodec` exists | Yes | Required for high-level KMPP path |
| `VOCDEC_IOC_CFG` request wrapper | Yes | Yes |
| Channel create/start/stop/control | Yes | Yes |
| `VCODEC_CHAN_IN_FRM_RDY` | Yes | Yes |
| `VCODEC_CHAN_OUT_STRM_BUF_RDY` | Yes | Still defined |
| `VCODEC_CHAN_OUT_PKT_RDY` | No evidence found | Required by `kmpp.c::get_packet()` |
| `/dev/kmpp_objs` | No evidence found | Required by object model |
| `/dev/kmpp_ioctl` | No evidence found | Required by object method calls |
| `KmppFrame` / `KmppPacket` shared-object return path | No evidence found | Yes |
| Kernel-side encoder control/HAL/RC | Yes, strongly indicated | Expected |

The practical result: Luckfox validates that Rockchip's kernel-side MPP encoder
stack is real, but it does not appear ABI-compatible with the newest KMPP userspace
path in the examined `mpp-rockchip` checkout.

## What we can infer about Rockchip's direction

Confirmed:

- KMPP is active enough to have 2024 and 2025 userspace headers and tests.
- Rockchip has a real kernel-side `mpp_vcodec` module in at least the RV1106 SDK.
- The older KMPP ABI is `/dev/vcodec` plus fixed channel commands.
- The newer userspace ABI introduces shared kernel/user objects and a packet-object
  output path.
- The object system is schema-driven: kernel object definitions and ioctl method
  tables are discovered at runtime.

Likely:

- Rockchip wants one object model for buffers, frames, packets, metadata, encoder
  configs, decoder configs, and codec instances.
- The kernel-side object ABI is meant to reduce C-struct version skew by publishing
  field metadata through tries.
- `KmppShmPtr` is the core cross-boundary handle. Most newer APIs pass shared
  object pointers rather than raw structs.
- The VENC path is ahead of the VDEC path in public userspace integration.
- Luckfox's RV1106 package is an intermediate generation: newer kernel-side codec
  internals, older stream-buffer output ABI.

Unknown:

- Whether a public kernel source tree currently implements `/dev/kmpp_objs` and
  `/dev/kmpp_ioctl`.
- Whether the newest KMPP object ABI exists only in internal Rockchip SDK branches.
- Whether RK3588 has a corresponding KMPP kernel package. The evidence examined
  was RV1106-oriented.
- Whether `VCODEC_CHAN_OUT_STRM_BUF_RDY` and `VCODEC_CHAN_OUT_PKT_RDY` coexist in
  newer kernels or whether the packet path replaced the stream path.

## Relevance to ROCK 5B / RK3588 work

For this repo's current ROCK 5B stack, classic MPP remains the relevant shipping
path:

```text
librockchip_mpp -> /dev/mpp_service -> RK3588 rkvenc2/rkvdec2 drivers
```

KMPP is useful for understanding Rockchip's newer internal direction, but it is
not something we can assume for RK3588 unless we find a matching kernel package.

Implications:

- Do not design ROCK 5B validation around `/dev/vcodec` or `/dev/kmpp_objs` unless
  the target kernel actually exposes those nodes.
- Keep `/dev/mpp_service` ABI compatibility as the primary requirement for current
  FFmpeg/GRD work.
- Treat `kmpp` in current userspace as a version-sensitive optional path.
- If testing newer Rockchip SDKs, probe for all relevant codec nodes:

  ```text
  /dev/mpp_service
  /dev/vcodec
  /dev/kmpp_objs
  /dev/kmpp_ioctl
  ```

- Also probe the specific output event support. A kernel with `/dev/vcodec` may
  still be too old for `VCODEC_CHAN_OUT_PKT_RDY`.

## Useful probes

On a target system, start with node presence:

```sh
ls -l /dev/mpp_service /dev/vcodec /dev/kmpp_objs /dev/kmpp_ioctl
```

For a Luckfox-style module:

```sh
modinfo mpp_vcodec
grep -R . /proc 2>/dev/null | grep -E 'venc_info|vdec_info|vcodec' | head
```

For ABI behavior, the minimal probe is not just "can I open `/dev/vcodec`". It
needs to issue `VOCDEC_IOC_CFG` with known commands and check which command IDs
are accepted. The critical differentiator is:

```text
0x601  OUT_STRM_BUF_RDY  older stream-buffer ABI
0x603  OUT_PKT_RDY       newer KmppPacket ABI
```

## Engineering takeaway

Classic MPP and KMPP are related but not interchangeable:

- Classic MPP: userspace owns codec/HAL logic and sends register recipes to
  `/dev/mpp_service`.
- Older KMPP: kernel owns more encoder logic and exposes `/dev/vcodec` with stream
  buffer get/put commands.
- Newer KMPP: kernel and userspace share typed objects; userspace discovers object
  schemas and method tables from `/dev/kmpp_objs` and `/dev/kmpp_ioctl`; `/dev/vcodec`
  returns `KmppPacket` objects through `OUT_PKT_RDY`.

The most important reverse-engineered fact is the ABI split. The Luckfox kernel
drop proves the kernel-side KMPP direction is real, but the current userspace tree
has already moved beyond the Luckfox-exposed ABI.
