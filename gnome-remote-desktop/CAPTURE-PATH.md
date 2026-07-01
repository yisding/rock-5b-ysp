# Capture path — how GRD gets pixels from mutter to the encoder

A map of GRD 50.1's capture→encode pipeline, reverse-engineered while chasing the
readback bottleneck ([`BASELINE.md`](BASELINE.md)) and building the hardware
backend ([`README.md`](README.md)). It answers three questions that took real
digging: **where does the frame come from, how is its buffer type chosen, and
where exactly does the encoder get selected** — which is also where this repo's
rkmpp backend plugs in. All file:line references are upstream GRD 50.1
(`rdp-handover-reconnect` base, before this repo's patches).

## The pipeline at a glance

```
  mutter (gnome-shell)                         gnome-remote-desktop daemon
  ┌───────────────────────┐   PipeWire    ┌──────────────────────────────────────┐
  │ screen-cast stream src │──screencast──▶│ GrdRdpPipeWireStream                   │
  │  renders virtual monitor│   buffer      │   negotiates format + buffer type      │
  │  → DMA-BUF *or* MemFd   │               │        │                               │
  └───────────────────────┘               │        ▼   (buffer_type)               │
                                           │   GrdRdpViewCreator  ── gets pixels to  │
                                           │     gen-gl / gen-sw / avc   a usable form│
                                           │        │                               │
                                           │        ▼                               │
                                           │   GrdEncodeSession ── encodes a frame   │
                                           │     ca-sw (RFX) / vaapi / (ffmpeg)      │
                                           └────────┬───────────────────────────────┘
                                                    ▼  RDPGFX over RDP → client
```

Two knobs decide everything downstream: **which buffer type** mutter hands over
(DMA-BUF vs MemFd), and **which encode session** GRD builds for it. They are
linked — the buffer type *selects* the encode session.

---

## 1. Buffer negotiation (PipeWire)

GRD is the *consumer*; mutter is the *producer*. They negotiate a format and a
buffer type over PipeWire's SPA param mechanism, in
`grd-rdp-pipewire-stream.c`:

- **`add_format_params()` (`:301`)** advertises the pixel formats GRD accepts. The
  crucial line is the gate at **`:327`**:
  ```c
  if (egl_thread && !hwaccel_nvidia)   // → also advertise a DMA-BUF (modifier) EnumFormat
  ```
  When GRD has an EGL thread and isn't on NVIDIA, it advertises a
  **modifier-bearing** format — i.e. it offers DMA-BUF. Otherwise it offers only
  plain (MemFd-able) formats.
- **`allowed_buffer_types` (`:536`)** states which SPA data types GRD will accept:
  ```c
  allowed_buffer_types = 1 << SPA_DATA_MemFd;                       // :536
  if (egl_thread && !hwaccel_nvidia)
    allowed_buffer_types |= 1 << SPA_DATA_DmaBuf;                    // :538
  ```
  advertised via `SPA_PARAM_BUFFERS_dataType` (`:550`).
- **Mutter chooses** based purely on whether the *negotiated format carries a
  modifier*: in `meta-screen-cast-stream-src.c`, `prop_modifier ? DmaBuf : MemFd`.
  So the format advertisement (`:327`) and the buffer-type advertisement (`:536`)
  **must agree**, or negotiation fails.

> **The failure mode we hit.** Force MemFd by touching only `:536`, and mutter
> still sees the modifier format from `:327`, fixates it, and builds buffers with
> `dataType = 1<<SPA_DATA_DmaBuf` (8). GRD demanded `1<<SPA_DATA_MemFd` (4).
> `8 & 4 = 0` → empty param intersection → libpipewire
> `error alloc buffers: Invalid argument`. The `EINVAL` is a *reconciliation*
> failure between two `SPA_PARAM_Buffers`, **not** a missing producer capability
> (mutter fully supports MemFd for virtual monitors). Fix: gate **both** blocks.
> See [`BASELINE.md`](BASELINE.md) §4.

---

## 2. The three view-creators

A `GrdRdpViewCreator` turns whatever PipeWire delivered into a form the encoder
can consume. There are three implementations, and **which one runs is dictated by
the buffer type + encoder** (next section):

| View creator | File | Input | What it does | Cost |
|---|---|---|---|---|
| **gen-gl** | `grd-rdp-view-creator-gen-gl.c` | DMA-BUF | Imports the dma-buf as an EGL image, then **`glReadPixels(GL_BGRA)`** into a CPU buffer for the software RFX encoder | **The bottleneck** — ~20 ms/frame @1080p (`grd-egl-thread.c:963`) |
| **gen-sw** | `grd-rdp-view-creator-gen-sw.c` | MemFd | Directly `mmap`s the shm buffer — no readback in GRD | Free *in GRD* (mutter paid an equivalent readback upstream) |
| **avc** | `grd-rdp-view-creator-avc.c` | DMA-BUF | RGB→NV12 colour-convert in a **Vulkan compute shader** (on the Mali GPU via panvk); output is an NV12 dma-buf for a HW encoder | GPU compute; needs a `GrdVkDevice` |

> **Key insight.** `gen-gl` and `gen-sw` feed the *same* software encoder — they
> differ only in **how the pixels reach CPU memory**. `gen-gl` pays GRD's
> `glReadPixels`; `gen-sw` gets a ready CPU buffer (because mutter already did the
> read). Neither reduces total system work — see [`BASELINE.md`](BASELINE.md) §4.
> `avc` is the only one that keeps pixels on the GPU, and it is the path both
> VA-API and this repo's rkmpp backend build on.

---

## 3. Encode-session selection — the decision tree

`create_encode_session()` (`grd-rdp-render-context.c:634`) switches on the
buffer type:

```
create_encode_session(buffer_type)                         # :634
├─ DMA_BUF → create_hw_accelerated_encode_session          # :553
│            ├─ try_create_vaapi_session                   # :422 / called :569
│            │     needs vk_device  (grd_rdp_renderer_get_vk_device, :426)
│            │     → avc view creator (:476) + VA-API encode session (:456)
│            │     ── on RK3588: no VA-API driver → returns NULL
│            └─ else create_egl_based_rfx_progressive…      # :510 / fallback :574
│                     → gen-gl view creator (:532) + ca-sw software RFX (:525)
│                     ══ THIS is the software path that pays the readback
│
├─ MEM_FD  → create_sw_based_encode_session                # :624
│            └─ create_sw_based_rfx_progressive…            # :580
│                     → gen-sw view creator (:601) + ca-sw software RFX (:595)
│
└─ NONE    → error
```

So on a stock RK3588 the frame arrives as **DMA-BUF**, GRD tries the VA-API
session, that fails (no driver), and it falls back to **gen-gl + software RFX** —
the `glReadPixels` path. That fallback is what [`BASELINE.md`](BASELINE.md)
measures.

### Where the rkmpp backend plugs in

This repo's [`patch 0003`](patches/) inserts the FFmpeg/rkmpp session into
`create_hw_accelerated_encode_session`, **after** the VA-API attempt and **before**
the `gen-gl` RFX fallback. So the new decision tree is: DMA-BUF → try VA-API
(fails) → **try FFmpeg rkmpp (succeeds)** → else gen-gl RFX. The rkmpp session
reuses the **`avc` view creator** (Vulkan RGB→NV12) for its input — which is why
it depends on the same `vk_device` that VA-API needs.

---

## 4. The `vk_device` gate (why panvk mattered)

Both the `avc` view creator and the VA-API session require a `GrdVkDevice`
(`grd_rdp_renderer_get_vk_device`, `:426`). That device only exists if GRD's
Vulkan probe **accepts** the Mali GPU. The probe
(`grd-hwaccel-vulkan.c`: `check_physical_device` `:430`,
`supports_bgrx_dma_buf_images` `:351`) hinges on
`get_egl_vulkan_format_modifier_intersection` (`:77`) — the EGL↔Vulkan
XRGB8888/LINEAR modifier list intersection, under `VK_API_VERSION_1_2` (`:39`).

On stock panvk that intersection came back **empty**, so `vk_device` was `NULL`,
so the `avc` view creator couldn't be built, so **every** HW path was gated off →
software RFX. On a *pure software* box that looked harmless — its only consumer
was the absent VA-API encoder — which is why our early notes called the panvk
rejection "moot." It is **not** moot once the rkmpp backend exists: it is the
single gate that unblocks the whole HW pipeline. The fix (query the base
`VkDrmFormatModifierPropertiesListEXT`, not the empty `…List2`) is this repo's
[`patch 0004`](patches/); the full story is in [`DESIGN.md`](DESIGN.md).

---

## 5. The consumer is single-in-flight

One structural fact that shapes every optimization: GRD's RDP consumer is
**single-frame-in-flight**. The download/encode of frame *N+1* is not enqueued
until frame *N*'s completion callback returns. There is no queue of outstanding
frames.

Consequence: a **PBO ring / double-buffered readback gives no cross-frame
pipelining** — there is never a second frame in flight to overlap with, so a ring
would simply stall (or deadlock) waiting on itself. The only thing async readback
can buy on this pipeline is letting the EGL thread **sleep on a GPU fence** during
the detile instead of spinning a CPU core on it — and that only helps when the
detile actually runs on the GPU (`MESA_COMPUTE_PBO=1`). This is the reason the
async-PBO prototype is a dead end on default Mesa. See
[`BASELINE.md`](BASELINE.md) §4.
