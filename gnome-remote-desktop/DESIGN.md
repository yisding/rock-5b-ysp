# Design — why FFmpeg, and how the backend came together

This is the "how we got here" companion to [`README.md`](README.md) (which is the
runtime story and the three shipping bugs). It covers the **up-front decision** —
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

Just how CPU-bound, and why, is measured in [`BASELINE.md`](BASELINE.md): the
software path burns **~20 ms per frame at 1080p** — ~90 % of the daemon — on a
single `glReadPixels` GPU→CPU copy (a CPU-side detile + BGRA swizzle that
panfrost never offloads to the GPU). Hardware encode deletes that copy outright,
which is the difference between a few-percent-CPU desktop and this one.

## Options we weighed

| Route | What it is | Verdict |
|-------|-----------|---------|
| **VA-API** (GRD's main HW path) | GRD already has `GrdEncodeSessionVaapi`; if a VA-API driver existed for the VEPU we'd get HW encode for free | ❌ no VA-API driver for the RK3588 encoder. `libva` loads `panthor_drv_video.so`, which has no encode — GRD logs `Did not initialize VAAPI: Failed to initialize VA display`. Dead end on this hardware. *(Observed 2026-06 during bring-up, GRD 50.1 / Mesa 26.0.x / libva 2.23 on Ubuntu 26.04 "resolute"; re-check this row if a VA driver for the VEPU ever appears.)* |
| **Mainline V4L2 stateful encoder** | The kernel-standard encode API | ❌ GRD's target is H.264 encode, and Collabora's [RK3588 mainline-status note](https://gitlab.collabora.com/hardware-enablement/rockchip-3588/notes-for-rockchip-3588/-/blob/main/mainline-status.md) lists mainline encoder support as JPEG-only. GRD also has no V4L2 encode backend anyway. |
| **Direct `librockchip_mpp`** | A new GRD encode session calling MPP directly | ⚠️ full control, but reinvents everything FFmpeg's `h264_rkmpp` already does (MPP setup, DRM-PRIME import, 1-in-1-out packet handling) and couples GRD to the MPP API. More code, more to maintain. |
| **FFmpeg `h264_rkmpp`** | Wrap FFmpeg's rkmpp encoder in a GRD encode session | ✅ **chosen** — least code, reuses a maintained encoder, and FFmpeg 8.1 is an ABI drop-in that gives *every* app rkmpp, not just GRD. |

### Why FFmpeg won

- **GRD's `GrdEncodeSession` is a clean seam.** The VA-API backend is already one
  implementation; a `GrdEncodeSessionFfmpeg` sibling slots in with no changes to
  the RDP/graphics pipeline above it.
- **FFmpeg already does the MPP dance** — device setup, DRM-PRIME frame import,
  `avcodec_send_frame`/`receive_packet`. We wrap it, we don't reimplement it.
- **System-wide win.** FFmpeg **8.1.2** is ABI-compatible with Ubuntu's `8.0.1`
  (same SONAME majors), so it's an *in-place* upgrade — Jellyfin/mpv/etc. get
  rkmpp too, not just GRD. (Packaged in [`../packaging/ppa/`](../packaging/ppa/).)
- **Fail-closed.** The backend declines (returns `NULL`) unless a zero-copy,
  low-latency session genuinely works, so it can never turn a working software
  desktop into a broken hardware one.

### The upstream-vs-fork sub-decision

There are **two** FFmpeg `h264_rkmpp` encoders (see the table in
[`README.md`](README.md)). We picked **upstream FFmpeg 8.1.2** over
[`ffmpeg-rockchip`](../ffmpeg/) for one reason: upstream FFmpeg 8.1.2 is an
**ABI drop-in** over the distro's `ffmpeg`, so it upgrades the whole system
cleanly, while ffmpeg-rockchip has its own ABI and vendoring. The cost is that
upstream's encoder is thin (no QP/profile/forced-IDR knobs) — which is exactly
what the two runtime fixes in [`README.md`](README.md) work around.
ffmpeg-rockchip remains the better choice if you only care about GRD and want
reference-grade fixed-QP quality out of the box.

## The backend, fail-closed and narrow

`GrdEncodeSessionFfmpeg` / `GrdHwAccelFfmpeg` (patches
[`0001`–`0003`](patches/)) are deliberately minimal:

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
  first-frame-IDR bug — see [`README.md`](README.md) #1.)

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
| FFmpeg route, backend, renderer + render-context wiring | [`0001`–`0003`](patches/) | this file |
| panvk base modifier list (unblocks the Mali device) | [`0004`](patches/) | this file §journey |
| dma-heap NV12 surfaces (+64-align) | [`0005`](patches/) | this file §journey |
| HOST_CACHED readback fallback | [`0006`](patches/) | this file §journey |
| upstream rkmpp: first-frame IDR + VBR quality | [`0007`](patches/) | [`README.md`](README.md) #1, #2 |
| greeter device permissions | — (udev) | [`../packaging/gdm-hwenc/`](../packaging/gdm-hwenc/), [`README.md`](README.md) #3 |
| handover reconnect revert | — (packaging) | [`patches/README.md`](patches/README.md) §"What's *not* here" (the full story), [`../packaging/ppa/`](../packaging/ppa/) (the deb-side quilt revert) |
