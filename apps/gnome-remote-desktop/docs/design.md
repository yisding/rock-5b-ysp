# Design — why FFmpeg, and how the backend came together

This is the "how we got here" companion to [`README.md`](../README.md) (which is the
runtime story and the four issues we hit and fixed). It covers the **up-front decision** —
should GRD talk to the RK3588 encoder at all, and if so, through what? — and the
**hardware-enablement journey** that turned "it compiles" into "the Mali GPU and
the VEPU580 actually cooperate."

## The problem

gnome-remote-desktop encodes the virtual desktop to H.264 and streams it over
RDP. Out of the box it has two hardware encode backends: **VA-API** (Intel/AMD)
and **NVENC** (NVIDIA). On an RK3588 **neither exists** — the encoder is the
**VEPU580**, reached through Rockchip's **MPP** framework
(`/dev/mpp_service`), not VA-API, not V4L2. So GRD fell back to CPU H.264, which
on this SoC means a laggy, CPU-bound desktop. The whole point of this repo's
codec stack is to make that hardware usable; GRD is where it pays off.

Just how CPU-bound, and why, is measured in [`baseline.md`](baseline.md): the
software path burns **~20 ms per frame at 1080p** — ~90 % of the daemon — on a
single `glReadPixels` GPU→CPU copy (a CPU-side detile + BGRA swizzle that
panfrost never offloads to the GPU). Hardware encode deletes that copy outright,
which is the difference between a few-percent-CPU desktop and this one.

## Options we weighed

| Route | What it is | Verdict |
|-------|-----------|---------|
| **VA-API** (GRD's main HW path) | GRD already has `GrdEncodeSessionVaapi` | ❌ Incompatible with the MPP-backed driver: GRD requires application-authored packed slice headers and MPP emits each complete slice NAL as an inseparable unit. |
| **Mainline V4L2 stateful encoder** | The kernel-standard encode API | ❌ mainline RK3588 encoder support is JPEG-only — no H.264 — and GRD has no V4L2 encode backend anyway. The V4L2/JPEG-only rationale (with the Collabora mainline-status citation) is owned by [`kernel-versions/docs/vanilla-kernel.md`](../../../kernel-versions/docs/vanilla-kernel.md). |
| **Direct `librockchip_mpp`** | A new GRD encode session calling MPP directly | ⚠️ full control, but reinvents everything FFmpeg's `h264_rkmpp` already does (MPP setup, DRM-PRIME import, 1-in-1-out packet handling) and couples GRD to the MPP API. More code, more to maintain. |
| **GStreamer Rockchip MPP** | A new GRD encode session around `appsrc -> rockchipmpp H.264 encoder -> appsink` | ⚠️ plausible as a second backend, especially for testing and GNOME-adjacent review, but not shorter for this repo: we would still keep GRD's PipeWire capture, Vulkan RGB→NV12 view-creator, RDPGFX pacing, packet handling, and fail-closed smoke test. The hard part becomes proving low-latency zero-copy dmabuf caps/allocator negotiation through the pipeline. |
| **FFmpeg `h264_rkmpp`** | Wrap FFmpeg's rkmpp encoder in a GRD encode session | ✅ **chosen** — least code, reuses a maintained encoder, and FFmpeg 8.1 is an ABI drop-in that gives *every* app rkmpp, not just GRD. |

### Why FFmpeg won

- **GRD's `GrdEncodeSession` is a clean seam.** The VA-API backend is already one
  implementation; a `GrdEncodeSessionFfmpeg` sibling slots in with no changes to
  the RDP/graphics pipeline above it.
- **FFmpeg already does the MPP dance** — device setup, DRM-PRIME frame import,
  `avcodec_send_frame`/`receive_packet`. We wrap it, we don't reimplement it.
- **System-wide win.** FFmpeg **8.1.2** is ABI-compatible with Ubuntu's `8.0.1`
  (same SONAME majors), so it's an *in-place* upgrade — Jellyfin/mpv/etc. get
  rkmpp too, not just GRD. (Packaged in [`packaging/ppa`](../../../packaging/ppa).)
- **Fail-closed.** The backend declines (returns `NULL`) unless a zero-copy,
  low-latency session genuinely works, so it can never turn a working software
  desktop into a broken hardware one.

### Where GStreamer fits

GStreamer is worth keeping as an experiment and conformance target, not as the
production replacement for this backend yet. The clean version would be another
`GrdEncodeSession` implementation:

```
PipeWire dma-buf capture
  -> GRD Vulkan RGB->NV12 view-creator
  -> NV12 dma-buf
  -> GStreamer appsrc
  -> Rockchip MPP H.264 encoder
  -> appsink
  -> GRD RDPGFX AVC420 packet path
```

That deliberately does **not** replace GRD's capture side with `pipewiresrc`.
GRD's frame pacing, damage handling, RDP frame acknowledgements, failover policy,
and session lifecycle are all already tied into its own PipeWire path; swapping
that out would create a bigger integration project without making RK3588 encode
more correct.

The upside of GStreamer is a natural media graph, GNOME familiarity, and a good
stress target for dmabuf caps, buffer pools, EOS/flush/restart, and multi-stream
state changes. The downside is that GRD would need to prove every queue is
one-buffer/low-latency, that SPS/PPS/IDR and rate-control behaviour match the RDP
client's expectations, and that dmabuf ownership/sync survives caps renegotiation.
Until that benchmark exists, FFmpeg remains the narrower production route.

JeffyCN's Rockchip GStreamer branch is staged in the external conformance bundle
(`../rock-5b/build/rockchip-conformance/sources/jeffycn-gstreamer-rockchip`) for exactly this:
test the kernel and userspace stack hard, then only consider a GRD GStreamer
backend if it beats the FFmpeg route on reliability, latency, or upstreamability.

### VA-API status, rechecked 2026-07-02

The heading preserves the dated investigation anchor, but the durable
conclusion is stronger now. A maintained MPP-backed VA-API driver exists and
can encode through ordinary `VAEntrypointEncSlice` clients. GRD is not an
ordinary client: it requires `SEQUENCE`, `PICTURE`, `SLICE`, and `RAW_DATA`
packed-header support together and authors the slice header itself. MPP accepts
no external slice header and exposes no separable entropy-coded payload to
splice safely.

Advertising a partial contract would make GRD attach and silently lose required
state. Therefore the native VA-API backend is not a pending comparison gate on
this MPP implementation. The
[VA-API capability policy](../../../video-libraries/vaapi/README.md#encode-surface-contract)
owns the permanent wall.

### The upstream-vs-fork sub-decision

There are **two** FFmpeg `h264_rkmpp` encoders (see the table in
[`README.md`](../README.md)). We picked **upstream FFmpeg 8.1.2** over
[`ffmpeg-rockchip`](../../../video-libraries/ffmpeg) for one reason: upstream FFmpeg 8.1.2 is an
**ABI drop-in** over the distro's `ffmpeg`, so it upgrades the whole system
cleanly, while ffmpeg-rockchip has its own ABI and vendoring. The cost is that
upstream's encoder is thin (no QP/profile/forced-IDR knobs) — which is exactly
what the two runtime fixes in [`README.md`](../README.md) work around.
ffmpeg-rockchip remains the better choice if you only care about GRD and want
reference-grade fixed-QP quality out of the box.

## The backend, fail-closed and narrow

`GrdEncodeSessionFfmpeg` / `GrdHwAccelFfmpeg` (patches
[`0001`–`0003`](../patches)) are deliberately minimal:

- **H.264 only, AVC420 only** — never AVC444v2. One codec, one path.
- **Zero-copy.** The NV12 surface is allocated from `/dev/dma_heap/system`, wrapped
  as a DRM-PRIME descriptor, and handed to `h264_rkmpp` — no CPU copies.
- **Reuses GRD's machinery.** The RGB→NV12 step is GRD's existing Vulkan
  view-creator (`GrdRdpViewCreatorAVC`, on the Mali GPU via **panvk**); rate
  pacing is GRD's RDPGFX frame controller. The backend is *just* the NV12→H.264
  encode.
- **Gated.** It only engages when the capture buffer is a dma-buf with a Vulkan
  image, sync objects, and a real DRM modifier — otherwise GRD uses software RFX.
- **Self-validating.** A start-up **smoke encode** imports a real dma-buf and runs
  one encode; if zero-copy import is broken, construction fails *there* and GRD
  never commits to the hardware path. (This same smoke encode caused the
  first-frame-IDR bug — see [`README.md`](../README.md) #1.)

## The hardware-enablement journey (patches 0004–0006)

Getting the Mali GPU (panvk) and the encoder (MPP) to share buffers took three
fixes, and a lesson. This is the part that looked like a Mesa bug and wasn't.

**The blocker.** GRD's Vulkan probe rejected the Mali device, so there was no
`vk_device`, so the shared view-creator was unavailable, so **every** hardware
encode path (VA-API *and* ours) was gated off → software RFX. The probe was
asking panvk for the DRM format modifiers of the capture format and getting
**zero** back — which read like "panvk has no modifier support."

**It was a GRD bug, not a panvk gap.** GRD queried the `…List2EXT` (the "version 2")
modifier list; panvk advertises the extension but only fills the **base**
`VkDrmFormatModifierPropertiesListEXT`, returning an empty List2. Querying the
base list instead (patch **0004**, `hwaccel-vulkan`) made panvk report `LINEAR`,
the device was accepted, and — because GRD now offered the Vulkan∩EGL
intersection (LINEAR) — the compositor stopped handing us AFBC-tiled buffers too.
One query fix cleared the whole logjam.

**Then two panvk quirks surfaced, one per layer:**

- **NV12 allocation.** panfrost's GBM can't allocate NV12, so the backend
  allocates the NV12 surface from the **dma-heap** as one linear object and lays
  out the Y and UV planes by hand, with the row stride aligned to **64 bytes**
  (panvk requires it for single-plane R8/R8G8 LINEAR images, and MPP independently
  wants a 64-aligned input stride). Patch **0005** (`encode-session-ffmpeg`).
- **Readback memory.** The view-creator's damage/chroma readback buffer asked for
  `HOST_VISIBLE|HOST_COHERENT|HOST_CACHED`, but panvk exposes no *cached* host
  type — so `vkCreateBuffer` failed and the view-creator silently fell back to
  RFX. Retry without `HOST_CACHED` (still coherent, reads stay correct). Patch
  **0006** (`rdp-view-creator-avc`).

**The lesson (worth internalising).** The start-up smoke encode only exercises the
encode **session** (MPP import + one encode) — **not** the view-creator. So a
single-frame test showed `Created h264_rkmpp encode session` and looked healthy
while the *actual* frames were silently RFX (the view-creator was failing on the
`HOST_CACHED` buffer). **Only a multi-frame test caught it.** Any "is the hardware
path really engaged?" check has to run several frames and confirm an `mpp_h264e`
thread and traffic — not just trust the session-created log line.

## Where each decision lives

| Decision / fix | Patch | Doc |
|---|---|---|
| FFmpeg route, backend, renderer + render-context wiring | [`0001`–`0003`](../patches) | this file |
| panvk base modifier list (unblocks the Mali device) | [`0004`](../patches) | this file §journey |
| dma-heap NV12 surfaces (+64-align) | [`0005`](../patches) | this file §journey |
| HOST_CACHED readback fallback | [`0006`](../patches) | this file §journey |
| upstream rkmpp: first-frame IDR + VBR quality | [`0007`](../patches) | [`README.md`](../README.md) #1, #2 |
| hardware-encode backpressure/cooldown guard | [`0008`](../patches) | [`README.md`](../README.md) #4 |
| greeter device permissions | — (udev) | [`packaging/gdm-hwenc`](../../../packaging/gdm-hwenc), [`README.md`](../README.md) #3 |
| corrected handover reconnect | [`0009`–`0013`](../patches) | [`apps/gnome-remote-desktop/patches/README.md`](../patches/README.md) §"Reconnect history and design boundary", [`packaging/ppa`](../../../packaging/ppa) |
