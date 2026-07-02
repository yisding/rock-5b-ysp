# Profiling the hardware path — 60 fps, and where the time goes

[`baseline.md`](baseline.md) measures the software path (the ~20 ms
`glReadPixels`). This is the **after**: per-stage profiling of the working
hardware AVC420 pipeline (Vulkan RGB→NV12 on panvk → FFmpeg `h264_rkmpp` →
VEPU580), answering "what limits the frame rate now that hardware encode
works?" It also records the headless harness that produced these numbers
(reconciling [`testing.md`](testing.md) §5) and the client-capability
prerequisite without which every measurement silently measures software RFX.

> **Provenance.** Measured on this box during backend bring-up; raw write-up is
> `docs/ffmpeg-rkmpp-profiling.md` (commits `5b09e60` + `4e07167`) on the
> `ffmpeg-rkmpp-encode-backend` branch of the
> [GNOME `yding/` fork](https://gitlab.gnome.org/yding/gnome-remote-desktop).
> Profiled build: GRD linked against **static ffmpeg-rockchip** (libavcodec 60,
> fixed QP 22) with the panvk fixes (patches [`0004`–`0006`](../patches/)) —
> *not* the shipped upstream-8.1.2 drop-in, though both drive the same MPP
> encoder. Surface 800×600 (encoder dims 800×608); statistics over the
> ~200-frame steady state, startup frames excluded.

## 1. Headline: the pipeline sustains 60 fps, vsync-bound

The hardware path runs at a **sustained 60 fps**, bounded by the 60 Hz capture
source (mutter's virtual monitor), not by any stage GRD owns:

| stage | median | p95 | max | rate |
|---|---|---|---|---|
| Capture interval (input) | 16.66 ms | 17.36 ms | 30.4 ms | **60.0 fps** |
| Encode interval (output) | 15.45 ms | 16.66 ms | 32.5 ms | **64.7 fps** |
| MPP encode (`avcodec_send_frame`+`receive_packet`) | **1.26 ms** | — | 1.74 ms | — |

- **Captured frames dropped before render: 0** (of ~205).
- **MPP encode = 1.26 ms ≈ 7.6 % of the 16.6 ms (60 fps) frame budget** — the
  VEPU580 could feed far more than 60 fps.
- Method: temporary `g_get_monotonic_time()` instrumentation (reverted after
  measurement) at three seams — `grd_rdp_surface_renderer_submit_buffer`
  (capture interval + drop detection), `…_lock_bitstream` (encode interval),
  and around the send/receive pair (encode duration).

## 2. Frame-jitter breakdown — the ~3 % > 25 ms spikes are not the encoder

Instrumenting *every* stage over a 201-frame run (GPU compute timed via
`GNOME_REMOTE_DESKTOP_DEBUG=vk-times`) shows **no hardware stage ever
spikes**:

| stage | median | p95 | max | spikes > 25 ms |
|---|---|---|---|---|
| Capture interval | 16.66 ms | 17.22 ms | 29.72 ms | 1 |
| GPU compute (RGB→NV12) | 1.36 ms | 1.39 ms | **1.91 ms** | **0** |
| View-creation wall-clock | 2.40 ms | 3.02 ms | **3.86 ms** | **0** |
| Encode (MPP) | 1.24 ms | 1.71 ms | **2.11 ms** | **0** |
| Encode interval (output) | 15.38 ms | 16.42 ms | 32.26 ms | 2 |

Correlating each output spike with its same-frame signals: one tracks a late
capture (29.7 ms), one had *every* measured stage normal yet the encode fired
~16 ms late (a missed frame period). So the jitter is **capture-delivery
pacing (compositor/PipeWire) and occasional renderer view→encode
thread-handoff scheduling — CPU/environmental, not the encoder**. The whole
hardware path is ~5 ms of work in a 16.6 ms budget and contributes none of it.
Chasing the residual spike would mean instrumenting the renderer's
`finished_view_creations` → `maybe_start_encodings` handoff.

## 3. Measurement artifact: where "28 fps" came from

An earlier figure of ~28 fps was **not a real limit**: it averaged total frames
over total wall-clock, but the test started the animation ~4 s *after* the
client connected, and a static screen produces no frames (**damage-gated**) —
so ~3.8 s of dead time halved the apparent average. The frame-to-frame steady
state is 60 fps. Rule: for rate measurements, count intervals in the steady
state, never frames-over-wall-clock across a damage-gated start.

## 4. The headless harness that actually worked

[`testing.md`](testing.md) §5 warns that headless capture numbers are soft —
that observation came from `glxgears` on a *client-created virtual monitor*,
where mutter often delivered nothing. This harness, by contrast, delivered
60 fps capture with zero drops:

- `mutter --headless --wayland` (a dedicated headless compositor, not the live
  session — so no eviction hazard, see testing.md §1),
- the built `gnome-remote-desktop-daemon --headless`,
- a **frame-counting AVC420 FreeRDP client** (§5 below — the client *must*
  advertise H.264 caps or you profile RFX),
- `eglgears_wayland` as a continuously-changing content source (it kept
  delivering frames where the testing.md §5 glxgears setup did not — observed
  difference; the mechanism was not root-caused).

The driver script (`scratchpad/run-grd-mf.sh`) was throwaway and is **not
preserved** — reconstruct it from the four components above. TODO: archive a
copy if the harness is ever rebuilt.

## 5. Client caps: without H.264 the server silently negotiates RFX

**The single easiest way to invalidate every number on this page** is to
measure through a client that doesn't advertise AVC420. RDPGFX codec choice is
negotiated from *client* capabilities; a client without H.264 caps silently
gets RemoteFX / `RDPGFX_CODECID_CAPROGRESSIVE` even when the server-side
hardware path is perfectly healthy — no error anywhere.

- Distro `sdl-freerdp`/`xfreerdp3` builds may lack H.264. The working test
  client was FreeRDP master built with **`-DWITH_OPENH264=ON`**
  (`WITH_FFMPEG=OFF`, installed to a private prefix, e.g. `install-h264/`).
  macOS/Windows Microsoft RDP clients advertise AVC420 out of the box (the
  live validation used the macOS client — [`README.md`](../README.md) status
  table).
- **Check the client log, not the server.** The tell for the fallback is the
  client-side surface-command log, e.g. FreeRDP's
  `[com.freerdp.channels.rdpgfx.client] … Got GFX RDPGFX_CODECID_CAPROGRESSIVE`
  — if you see CAPROGRESSIVE surface commands, you are *not* measuring the
  H.264 path, whatever the server logs say.

## 6. If chasing > 60 fps

Encode has so much slack that the next limiter is elsewhere. To find the true
ceiling, drive a higher-refresh virtual monitor (e.g. 120 Hz) and re-measure;
the likely candidates then are the **Vulkan view-creator** (RGB→NV12 compute +
view-creation, ~3.8 ms worst-case today) and the **RDPGFX transmit /
frame-ack flow control** ([`README.md`](../README.md) #1 describes the frame
controller), **not the encoder**. For perfectly smooth pacing the thing to
chase is the ~3 % > 25 ms jitter (§2): instrument the view-creator
`create_view`→`finish_view` and the transmit path.

## 7. Verification signals — what to grep

The concrete, shipped-patch signals that the hardware path is really engaged
(this closes [`testing.md`](testing.md) §7's "this repo's tags" gap; the
`[ACKDBG]`/`[SYNCDBG]`/`[GDMDBG]` tags in [`README.md`](../README.md)'s
methodology section were **throwaway instrumentation, present in no shipped
patch**):

| Signal | What to look for | Emitted by |
|---|---|---|
| Backend up (`g_message`, always in journal) | `[HWAccel.FFmpeg] Initialized FFmpeg/rkmpp encode backend (encoder "h264_rkmpp")` | patch 0001 |
| Session created (`g_message`) | `[HWAccel.FFmpeg] Created h264_rkmpp encode session for surface with size WxH (encoder dimensions WxH)` | patch 0001 |
| Backend init failed (`g_message`) | `[RDP] Did not initialize FFmpeg/rkmpp: …` | patch 0002 |
| Session-create failed (`g_debug` — needs debug env) | `[HWAccel.FFmpeg] Could not create rkmpp encode session: …` | patch 0003 |
| Encoder thread | an `mpp_h264e` thread in `ps -T -p <pid>` | libmpp |
| Device fds | open `/dev/mpp_service` + `/dev/dma_heap/*` in `/proc/<pid>/fd` | libmpp/backend |

Journal one-liner:
`journalctl --user -u gnome-remote-desktop -g 'HWAccel.FFmpeg'`.

⚠️ "Created … encode session" alone is **not** proof — the smoke encode
exercises only the encode session, not the view-creator
([`design.md`](design.md) §lesson). Run **multiple frames** and confirm the
thread + fds + client-side AVC420 (§5).

## 8. Open item: which DRM modifier does mutter's dma-buf carry?

Still the section's highest-value open measurement
([`baseline.md`](baseline.md) §2/§5): whether mutter's screencast dma-buf is
AFBC, tiled, or linear decides the real software-path detile cost (and matters
to the HW path's Vulkan import too). **No verified procedure exists yet.**
Untested candidate approach (TODO): log the fixated format's modifier in GRD at
`spa_format_video_raw_parse` time in `grd-rdp-pipewire-stream.c`
(`on_format_changed`), or dump the negotiated `SPA_FORMAT_VIDEO_modifier` via
`PIPEWIRE_DEBUG`/`pw-dump` while a session is live. After patch 0004, the
offered intersection is LINEAR-only ([`design.md`](design.md) §journey), which
constrains what mutter *can* pick on the patched stack — the open question is
about the stock/pre-patch negotiation.
