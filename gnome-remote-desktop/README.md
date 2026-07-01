# gnome-remote-desktop/ — hardware-accelerated RDP encode on RK3588

The codec stack in this repo exists to be *used*. This directory documents the
first real application built on it: a **hardware H.264 encode backend for
[gnome-remote-desktop](https://gitlab.gnome.org/GNOME/gnome-remote-desktop)
(GRD)**, so a remote desktop (RDP) session is encoded on the **VEPU580** instead
of in software. On an RK3588 the difference is a live, full-framerate desktop at
a few percent CPU instead of a laggy, CPU-bound one.

| Piece | What | Status |
|-------|------|--------|
| **Encode backend** | `GrdEncodeSessionFfmpeg` → FFmpeg `h264_rkmpp` → VEPU580, zero-copy | ✅ live over real RDP (macOS client), post-login desktop |
| **RGB→NV12** | Vulkan (**panvk**) compute on the Mali GPU, explicit-sync dma-buf | ✅ cross-driver panfrost→panvk sync works |
| **Login screen** | GDM greeter, same path | ✅ with the opt-in [`gdm-hwenc`](../packaging/gdm-hwenc/) package |
| **Quality** | VBR, artifact-free at ~0.25 bpp target | ✅ after the bitrate fix (below) |

> **This is the *consumer* layer.** The kernel drivers are in [`patches/`](../patches/),
> libmpp/librga in [`docs/02`](../docs/02-how-the-userspace-libs-work.md), and the
> FFmpeg build in [`ffmpeg/`](../ffmpeg/). GRD sits on top of all of it. If the
> validate script and `tests/` pass, the hard part is already done — GRD is just
> another `/dev/mpp_service` + `/dev/dma_heap` client.

## How it fits the stack

```
  macOS / Windows RDP client
        │  H.264 (AVC420) over RDP
  ┌─────┴───────────────────────────────────────────────┐
  │  gnome-remote-desktop daemon                         │
  │    GrdRdpViewCreatorAVC  ── RGB→NV12 on the Mali GPU  │→ /dev/dri/renderD128 (panvk)
  │    GrdEncodeSessionFfmpeg ── NV12 → H.264             │
  └─────┬───────────────────────────────────────────────┘
        │  FFmpeg h264_rkmpp  (MAINLINE 8.1.2, not the fork — see below)
        │  librockchip_mpp
   ┌────┴─────────────┬──────────────────────┐
   │ /dev/mpp_service │ /dev/dma_heap/system  │   ← this repo's kernel drivers
   │  (VEPU580)       │  (frame/stream bufs)  │     (patches/01, docs/01)
   └──────────────────┴───────────────────────┘
```

Two device classes do the work, both from this repo's drivers: the **encoder**
(`/dev/mpp_service`, the `rkvenc2` driver) and the **DMA-heaps**
(`/dev/dma_heap/*`, where rkmpp allocates every frame/stream buffer). A third,
the **Mali GPU** (`/dev/dri/renderD128`, mesa/panvk — *not* from this repo), does
the RGB→NV12 colour conversion in a Vulkan compute shader before handing the NV12
dma-buf to the encoder zero-copy.

> **Which FFmpeg?** GRD here links the **mainline** FFmpeg `h264_rkmpp`
> (`8.1.2+rk1`, an ABI-compatible drop-in over Ubuntu's `ffmpeg`), **not** the
> [`ffmpeg-rockchip` fork](../ffmpeg/) this repo otherwise recommends. That choice
> drove every bug below — mainline's rkmpp encoder is far thinner than the fork's.
> See the table.

## mainline FFmpeg `h264_rkmpp` vs the ffmpeg-rockchip fork ⭐

There are **two independent** `h264_rkmpp` encoders with the same name. Knowing
which one you have explains everything else on this page.

| Capability | **mainline** FFmpeg 8.1.x (`libavcodec/rkmppenc.c`) | **ffmpeg-rockchip** fork |
|---|:---:|:---:|
| Rate control | `-rc vbr / cbr / avbr` only | vbr / cbr / avbr / **fixqp** |
| Fixed QP (`qp_init`, `qp_min/max`) | ✗ never set on MPP | ✅ `qp_init ≥ 0 → MPP FIXQP` (constant quality) |
| H.264 profile (`h264:profile`) | ✗ never set → **Constrained Baseline** | ✅ honoured (High, etc.) |
| Forced IDR (`frame->pict_type = I`) | ✗ ignored | ✅ `→ MPP_ENC_SET_IDR_FRAME` (`rkmppenc.c:926`) |
| `bps_max` (VBR ceiling) | only from `avctx->rc_max_rate`, else MPP's **~2.5 Mbps** default | same (plus the QP path) |

The RK3588 VPU and libmpp support fixed QP, High profile, and forced IDR — it's
purely mainline's FFmpeg *glue* that doesn't wire them up. On the fork, GRD's
existing `qp_init=22` already yields constant-quality output and forced IDR just
works; **both fixes below are mainline-only workarounds, harmless on the fork.**

## The three bugs we hit (and fixed)

Getting from "compiles" to "live, crisp remote desktop" took three fixes. Each is
a good worked example of a mainline-rkmpp gotcha.

### 1. The frozen desktop — no IDR in the stream

**Symptom.** RDP connects, the login works, then the desktop freezes on the first
frame. The daemon isn't crashed — every thread is idle.

**What we saw.** gdb stacks: all worker threads parked in their main loops (a
*starvation*, not a deadlock). The socket had sent ~450 KB (real frames, not just
the TLS/RDP handshake) and the client had ACK'd it at the TCP level — but had sent
**zero** `RDPGFX_FRAME_ACKNOWLEDGE` PDUs. Dumping the first H.264 packets and
parsing their NAL units showed the smoking gun: **every packet, including frame
#0, was a bare P-slice (NAL type 1)** — no SPS, no PPS, no IDR anywhere.

**Root cause.** A decoder cannot start from a P-frame with no parameter sets, so
the client decoded nothing and never acknowledged a frame. GRD's RDPGFX **frame
controller** then did exactly what it's designed to: after
`activate_throttling_th = MAX(2, MIN(rtt_frames+2, fps))` = **2** unacknowledged
frames on a LAN, it throttled `total_frame_slots` to **0** and stopped producing —
a permanent freeze. Why no IDR? Two things compounded, both mainline-specific:

1. rkmpp only emits a real IDR access unit (SPS+PPS+IDR) for the **first frame
   after the encoder is opened**; and
2. the backend's start-up **smoke encode** (a throwaway frame that proves
   zero-copy DRM-PRIME import works) *consumed* that one natural IDR — and mainline
   ignores the `pict_type=I` request that was supposed to force the next one.

**Fix.** Recreate the encoder immediately after the smoke test, so the first
*real* frame is a fresh natural IDR. `avcodec_flush_buffers()` was ruled out — it
*hangs* the rkmpp encoder; the NV12 surfaces are standalone dma-buf descriptors
that outlive the encoder, so tearing it down and reopening is safe.
→ [`patches/0002`](patches/), `run_smoke_test()`.

### 2. Terrible quality — the 2.5 Mbps ceiling

**Symptom.** It worked, but with blocking artifacts everywhere.

**What we saw.** The MPP log line said it all:
`set rc vbr bps [16049664:2500000:1500000]` — a 16 Mbps *target* but a **2.5 Mbps**
ceiling. A standalone test confirmed it: a complex full-screen frame capped at
~6 Mbps without `rc_max_rate` vs ~26 Mbps with it.

**Root cause.** Mainline's `rkmppenc.c` sets MPP's `bps_max` **only** from
`avctx->rc_max_rate`, and GRD left that unset — so MPP kept its ~2.5 Mbps default
ceiling and quantised every frame hard to stay under it. With **no QP knob on
mainline**, bitrate *is* the only quality control.

**Fix.** Set `rc_max_rate` (`bps_max` = target×3) and `rc_min_rate`
(`bps_min` = target÷8), and raise the target to ~0.25 bpp. VBR still keeps static
frames near-free (idle ≈ 0), but active/detailed frames can now spend the bits they
need — measured peaks ~67 Mbps under heavy motion on a LAN, and the artifacts are
gone. → [`patches/0002`](patches/), `create_encoder()`.

> On the **fork** this whole bug is moot: `qp_init=22` selects MPP FIXQP and you
> get constant-quality output with no bitrate tuning at all. The bitrate triplet
> is the mainline substitute for a QP knob.

### 3. The login screen stayed software — the greeter's dynamic user

**Symptom.** After logging in, the desktop is hardware-encoded — but the **GDM
login screen** is software (RFX), even though it's the same daemon and codec.

**What we saw.** Instrumenting the codec-selection point showed the greeter's
capture buffer passes *every* hardware gate (dma-buf, `XRGB8888`, `LINEAR`
modifier, sync objects, a Vulkan image) — yet it still fell back to software. The
rkmpp encode session was failing to *create*, silently. The tell: the greeter
runs as a **dynamic per-session user** — `gdm-greeter`, `gdm-greeter-2`, … (uid
60578+), a member of only the **`gdm`** group, never `video`/`render`.

**Root cause.** That user cannot open `/dev/dma_heap/system` or `/dev/mpp_service`
(both `root:video 0660`, no ACL), so the encode session dies at the very first
`open()`. It reaches the **GPU** (`renderD128`) only because DRM nodes get a
systemd **`uaccess`** ACL for the active seat — but the codec nodes have no such
rule.

**Why `uaccess` alone doesn't fix it.** We tried tagging the codec nodes
`uaccess`. It half-worked: `getfacl` showed the ACL granted to `gdm-greeter` — but
the *active* greeter was `gdm-greeter-2`, which had no access. logind reliably
refreshes the **DRM seat node's** ACL across GDM's dynamic-user churn, but leaves
these **non-seat** codec nodes stuck with whichever greeter user was first. So the
grant has to be to something *stable* across the churn.

**Fix.** A persistent **`g:gdm` ACL** — `setfacl -m g:gdm:rw` on the codec nodes
via udev. Every greeter user shares the `gdm` group, so the grant always applies.
This is packaged, opt-in, as
[`gnome-remote-desktop-gdm-hwenc`](../packaging/gdm-hwenc/) — *separate* from GRD
because it widens codec access to the whole `gdm` group, which is a deliberate
security choice, not a default.

> **Precedent check.** Armbian grants the *interactive login user* the codec
> groups (`armbian-firstlogin` adds `video`+`render`); it never grants the display
> manager. `uaccess` (the desktop-standard) only covers the logged-in seat user.
> Neither covers a *pre-login greeter that encodes video* — that's novel to this
> GRD-over-RDP use case, which is why there's no existing rule for it. See the
> [`codec-udev` group discussion](../packaging/codec-udev/README.md) for the wider
> `video`/`render`/`uaccess` map.

## How we diagnosed it (methodology)

Every fix above came from the same cheap toolkit — useful for anyone debugging a
codec consumer:

- **`g_message` instrumentation** at the pipeline seams (`[ACKDBG]`/`[SYNCDBG]`/
  `[GDMDBG]`): the encoded packet size + keyframe flag, the RDPGFX frame-ack
  callback, and the buffer-info gate values. `g_message` always reaches the
  journal, so no debug-env dance.
- **Dump the bitstream.** Writing the first few `AVPacket`s to `/tmp/*.h264` and
  parsing NAL units offline (`SPS=7 PPS=8 IDR=5 P=1`) is what proved "all
  P-slices, no IDR."
- **gdb thread stacks** (`thread apply all bt`): *all idle* ⇒ starvation, not a
  deadlock — which pointed at flow-control, not a stuck encoder.
- **`ss -ti`** on the RDP socket: `bytes_sent` growing in KB bursts = real frames
  on the wire; flat = nothing. Distinguishes "encoder stalled" from "client not
  acking."
- **`getfacl` / `udevadm info`**: the whole greeter bug is visible in one
  `getfacl /dev/dma_heap/system`.
- **Standalone `ffmpeg` CLI + reading `rkmppenc.c`** (both trees) to establish
  what the encoder *actually* does vs. what the API asked for — this is how the
  mainline/fork table got nailed down.

## The patches

The two source patches are in [`patches/`](patches/) (git-format-patch of the two
commits on the GRD fork branch). They map 1:1 to the fixes above; see
[`patches/README.md`](patches/README.md).

| Patch | Fixes |
|-------|-------|
| `0001-Revert-rdp-make-handover-reconnect-cleanup-robust.patch` | a cherry-picked handover-reconnect change that broke the basic GDM→session handover (reverted) |
| `0002-encode-session-ffmpeg-make-the-mainline-rkmpp-encode.patch` | bugs **#1** (IDR) and **#2** (bitrate) |

Bug **#3** (greeter access) is not a code change — it's the udev package in
[`packaging/gdm-hwenc/`](../packaging/gdm-hwenc/).

## Packaging & install

Three pieces, built from a vendored GRD fork (upstream 50.1 + the rkmpp backend):

| Package | What | Needed? |
|---------|------|:---:|
| `gnome-remote-desktop` `50.1+rkmpp-2` | GRD with the rkmpp encode backend | required |
| `gnome-remote-desktop-gdm-hwenc` `1.0` | greeter codec ACL ([`packaging/gdm-hwenc/`](../packaging/gdm-hwenc/)) | optional (login-screen HW) |
| the codec stack | this repo's kernel + `libmpp` + FFmpeg `8.1.2+rk1` | required |

```bash
# 1. Codec stack first — kernel drivers + udev + system FFmpeg with rkmpp.
#    (This repo's Quickstart + the video-group codec-udev rule.)

# 2. GRD with the backend, + (optionally) the greeter access package:
sudo apt install ./gnome-remote-desktop_50.1+rkmpp-2_arm64.deb
sudo apt install ./gnome-remote-desktop-gdm-hwenc_1.0_all.deb    # optional

# 3. Enable + connect an RDP client. Confirm it's on hardware:
#    the session daemon has an "mpp_h264e" thread and an open /dev/mpp_service fd.
```

The full stack (codec libs + FFmpeg + GRD) is prepared as upload-ready Launchpad
**PPA** source packages (a personal `resolute`/arm64 PPA); `gnome-remote-desktop`
is `50.1+rkmpp-2` and `gnome-remote-desktop-gdm-hwenc` is an independent
`Arch: all` add-on.

## Provenance & licensing

- **gnome-remote-desktop** is GPL-2.0+. The rkmpp encode backend is our addition
  on top of upstream **50.1**, on the branch
  `ffmpeg-rkmpp-encode-backend` of the GNOME `yding/` fork. The backend is a
  sibling of GRD's existing VA-API path and reuses its design (fixed QP 22 intent,
  the Vulkan view-creator, the frame controller).
- It links **mainline** FFmpeg `8.1.2+rk1` (GPL-3 via `--enable-version3`, for
  rkmpp), an ABI drop-in over Ubuntu's `ffmpeg`. This repo's [`ffmpeg/`](../ffmpeg/)
  documents the *fork*; GRD uses mainline for the in-place upgrade. Either works —
  the fork gives better default quality (fixed QP), mainline needs the bitrate fix.
- `gnome-remote-desktop-gdm-hwenc` is a few lines of udev + a tiny package; GPL-2+.

This directory is the *integration + the debugging story*; the remote-desktop
heavy lifting is GNOME's, and the codec heavy lifting is Rockchip's (the rest of
this repo).
