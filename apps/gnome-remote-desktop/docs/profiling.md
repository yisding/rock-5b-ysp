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
> fixed QP 22) with the panvk fixes (patches [`0004`–`0006`](../patches)) —
> *not* the upstream-8.1.2 drop-in tested later, though both drive the same MPP
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
preserved** — reconstruct it from the four components above. Remaining archival
action: archive a copy if the harness is ever rebuilt.

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

The concrete committed-patch signals that the hardware path is really engaged
(this closes [`testing.md`](testing.md) §7's "this repo's tags" gap; the
`[ACKDBG]`/`[SYNCDBG]`/`[GDMDBG]` tags in [`README.md`](../README.md)'s
methodology section were **throwaway instrumentation, present in no committed
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

## 8. Pipeline-starvation diagnostics in the `~exp2` package

The experimental `~exp2` package adds diagnostic-only instrumentation at
`debug/exp1-frame-starvation@1c870bc`, directly on top of the reconnect-v2
`~exp1` source. It does not change scheduling or drop policy. When pipeline
state changes, the daemon emits one rate-limited `[RDP.PIPELINE]` summary per
second with cumulative counters and the most recent frame serials for:

- buffers received and frames queued;
- view creations started/completed;
- stale frames dropped, including the dropped and latest serials;
- encodes started/completed and the most recent encode duration;
- frames submitted to RDPGFX;
- full-refresh requests/deferrals and render-context-reset waits;
- hardware-encode cooldown starts/expirations; and
- ages since the last buffer and submitted frame.

If buffers continue arriving but no frame is submitted for two seconds while
queued work is outstanding, it also emits a `Suspected frame starvation`
warning. That warning is limited to once every five seconds. This should
separate the observed Firefox freeze into three broad cases: capture stopped
(buffer age rises), frames are repeatedly discarded as stale (stale count and
serial gap rise), or encoding/submission stopped after views completed. In
`~exp2` this timer shares the graphics main context, so it cannot fire after
that thread itself blocks; `~exp3` moves it to an independent context/thread.

For the current handover service, capture just these diagnostics with:

```bash
journalctl --user -u gnome-remote-desktop-handover.service -f \
  | rg 'RDP\.PIPELINE'
```

For a standard non-handover unit, replace the unit name with
`gnome-remote-desktop.service`. Preserve several seconds before Firefox opens
and after the image freezes; the counters are cumulative, so the transition is
more useful than a single final line.

## 9. Firefox freeze diagnosis and the `~exp3` recovery design

The `~exp2` logging made the Firefox-triggered freeze conclusive. The kernel
and compositor remained alive, but the RDP pipeline stopped at 12:08:40 while
constructing its sixth RKMPP encode session:

- the last summary at 12:08:39 reported 23 buffers received, 25 frames queued,
  25/24 view creations, two stale drops, 17/17 encodes, and 17 submitted
  frames;
- five earlier RKMPP smoke encodes completed, while the sixth logged encoder
  open and smoke-frame preparation but never returned a packet;
- the RDP graphics thread waited in a futex, the encode worker waited in
  `poll`, and `mpp_h264e` waited in a futex; the service and RDP socket stayed
  alive;
- the boot journal contained no kernel Oops, IOMMU, RGA, codec, or GPU fault,
  and Firefox itself did not hold `/dev/mpp_service`; and
- the RKVENC interrupt counter stopped advancing. Attaching gdb was blocked by
  the host ptrace policy, but the source/log/thread boundary identified the
  synchronous wait; it did not by itself distinguish a missing hardware
  completion from an input frame that was never submitted.

The blocking chain was:

1. a Firefox damage burst made a completed view stale;
2. the stale-drop path requested a full refresh **and render-context reset**;
3. that destroyed and recreated the RKMPP encoder, including a synchronous
   zero-copy smoke encode on the RDP graphics thread;
4. GRD set `AV_CODEC_FLAG_LOW_DELAY`, and the Rockchip FFmpeg encoder therefore
   selected `MPP_TIMEOUT_BLOCK` for `encode_get_packet()`; and
5. the first-frame path issued `MPP_ENC_SET_IDR_FRAME`; libmpp's asynchronous
   control worker posted the command-complete semaphore before releasing
   `mFrmIn->cond_lock` and completing its post-control work;
6. FFmpeg immediately submitted the frame, but libmpp's input trylock failed
   and returned `MPP_NOK`, which FFmpeg surfaced as `EAGAIN`;
7. the low-delay encode wrapper still entered blocking `encode_get_packet()`
   even though no input was queued, so no packet or RKVENC interrupt could
   arrive; and
8. the diagnostics timer could not report the stall because it was attached
   to the same blocked main context.

The exact control/input ordering was reproduced twice by the standalone
[`../bench/rkmpp_lifecycle_bench.c`](../bench/rkmpp_lifecycle_bench.c) churn
test after 360 and 364 successful lifecycles. MPP debug logs showed the control
acknowledgement, failed input handoff, and worker returning to its input wait;
the interrupt counter did not move because there was no hardware task. That
causally explains the reproducer's stall. It is strongly consistent with the
older Firefox incident at the same first-frame/IDR boundary, but the old
incident lacked the MPP debug trace needed to prove that exact attribution.

`~exp3` fixes each boundary rather than merely adding another warning:

| Layer | Change | Failure behavior |
|---|---|---|
| FFmpeg `540657970e` | Internally replaces `MPP_TIMEOUT_BLOCK` with a 500 ms deadline for synchronous low-delay and drain waits; its asynchronous path stays nonblocking. It adds no AVOption or public API. | Containment: the empty packet wait becomes libavcodec `EAGAIN`; no caller of the hardened encoder can remain blocked forever. The separate correctness fix is to skip blocking receive when input submission returned `EAGAIN`. |
| GRD session open | Continues using the standard `AV_CODEC_FLAG_LOW_DELAY`; the Debian package requires the hardened FFmpeg version. | GRD remains source-compatible with normal libavcodec and has no Rockchip-specific timeout API. |
| Smoke/refresh | Keeps the successfully smoke-tested encoder, requests an IDR for the first real frame, and separates content refresh from context reset. A stale drop requests an IDR plus full-frame content refresh only. | Firefox damage no longer causes rapid MPP close/open/smoke cycles. |
| Encode error | Treats an AVC packet timeout as a hardware failure, not a fatal graphics-subsystem failure. | The failed frame/resource is released, the context is reset, software encoding runs for ten seconds, then hardware is retried. |
| Diagnostics | Runs the one-second timer on a dedicated main context/thread and diagnoses outstanding view/encode work rather than only recently arriving buffers. | Starvation warnings continue even if the graphics thread itself stalls. |

The 500 ms bound is deliberately much larger than the measured normal RKMPP
encode time (about 1–2 ms) and larger than the existing 250 ms single-encode
stall threshold. Compilation passed for both FFmpeg and GRD; GRD's RDP
integration test passed three times. The remaining acceptance gate is the live
Firefox stress/reconnect test with both `~exp3` and the matching FFmpeg package
installed. Do not manually pair `~exp3` with the older FFmpeg: the package
dependency prevents that unsupported combination because the old encoder can
still wait indefinitely.

## 10. Exp5 closes the readback hang and exposes a separate encoder fallback

The later `exp5@b3f0e20` run separates two problems that earlier sessions
presented as one generic freeze:

1. Exported patch `0017` copies the imported linear dma-buf into a cached,
   driver-owned texture before `glReadPixels`. A full-screen YouTube run proved
   the multi-minute EGL-thread wedge is gone: the thread bursts and idles,
   submit age stays below one second and recovers, and no fallback-to-direct
   readback occurred. The software path remains CPU-heavy and drops stale
   frames, but it is fluid rather than wedged.
2. Once that path recovered reliably, intermittent hardware-to-software
   fallbacks remained. MPP and rkvenc2 traces showed the hardware completing
   normally. The deployed FFmpeg wrapper (`540657970e`) occasionally received
   `MPP_NOK` when the finite input task pool was momentarily full, then waited
   for output from the refused, never-submitted frame and surfaced the elapsed
   wait as `AVERROR_EXTERNAL`.

FFmpeg fix `da5befc806` retries a refused synchronous put within the same 500 ms
deadline and maps an elapsed packet wait to `EAGAIN`. Its object compiles, and
normal-PPA source `18628833` plus arm64 build `33417109` are Published. The
remaining acceptance gate is one combined board run with patch `0017` and that
FFmpeg package: sustain full-screen video without a readback wedge or transient
hardware fallback, then repeat the macOS Windows App reconnect scenario.

The detailed evidence is split by boundary:

- [uncached readback diagnosis and exp5 proof](../../../findings/2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md);
- [driver/hardware exclusion](../../../findings/2026-07-19-grd-rkmpp-encoder-wedge-userspace-not-driver.md); and
- [MPP backpressure mechanism and FFmpeg fix](../../../findings/2026-07-19-grd-rkmpp-encoder-wedge-mpp-input-backpressure.md).

## 11. Open item: which DRM modifier does mutter's dma-buf carry?

Still the section's highest-value open measurement
([`baseline.md`](baseline.md) §2/§5): whether mutter's screencast dma-buf is
AFBC, tiled, or linear decides the real software-path detile cost (and matters
to the HW path's Vulkan import too). **No verified procedure exists yet.**
Untested candidate approach: log the fixated format's modifier in GRD at
`spa_format_video_raw_parse` time in `grd-rdp-pipewire-stream.c`
(`on_format_changed`), or dump the negotiated `SPA_FORMAT_VIDEO_modifier` via
`PIPEWIRE_DEBUG`/`pw-dump` while a session is live. After patch 0004, the
offered intersection is LINEAR-only ([`design.md`](design.md) §journey), which
constrains what mutter *can* pick on the patched stack — the open question is
about the stock/pre-patch negotiation.
