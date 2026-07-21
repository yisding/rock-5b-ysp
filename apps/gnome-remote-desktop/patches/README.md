# gnome-remote-desktop/patches/

The **complete exported investigation series** for the FFmpeg/rkmpp H.264
backend and corrected RDP handover reconnect path in gnome-remote-desktop: the seven
backend commits from the
[`ffmpeg-rkmpp-encode-backend`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/commits/ffmpeg-rkmpp-encode-backend)
branch of the GNOME fork `gitlab.gnome.org/yding/gnome-remote-desktop`, plus
`0008` as the July 3 backpressure/cooldown follow-up, `0009`–`0013` from
[`rdp-handover-reconnect-v2`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/commits/rdp-handover-reconnect-v2),
and the `0014`–`0015` diagnosis/recovery pair for the Firefox-triggered RKMPP
stall, `0016`'s defensive starvation actuator, `0017`'s hardware-verified fix
for uncached imported-buffer readback, `0018`'s bounded recovery from a stalled
RDPGFX frame-acknowledgement resume, and `0019`'s correction for focus-idle time
being misclassified as pipeline starvation. Diagnostic patch `0020` logs every
client `AUDIO_FORMAT` field so an absent AAC/Opus offer can be distinguished
from a format that GRD rejects only because one field differs. Diagnostic
patch `0021` traces every boundary from channel setup through PipeWire capture
and `SNDC_WAVE2` confirmation, and temporarily removes Opus from the advertised
server formats for the Microsoft macOS client experiment.

The complete `0001`–`0021` series, including its `0001`–`0008` backend subset,
applies to upstream commit `c14e09e` (`50.1` + 16). This base contains both the
`cf250ed` VA-API revert required by `0003` and the GNOME-50 reconnection
simplification that `0009` officially reverts. Replay is verified with
`git am`; pristine tag `50.1` is **not** a valid base for this exported series.
The series base is also
[`apps/gnome-remote-desktop/docs/capture-path.md`](../docs/capture-path.md)'s line anchors, which resolve
against `50.1`+16 — see its header.

> These change the gnome-remote-desktop **userspace**. The *kernel* drivers that
> make `/dev/mpp_service` exist are in [`kernel-drivers/patches`](../../../kernel-drivers/patches).

| # | Patch | Files | What |
|---|-------|:-----:|------|
| 0001 | `...-add-ffmpeg-rkmpp-h.264-encode-...` | 10 | The backend: `GrdEncodeSessionFfmpeg` + `GrdHwAccelFfmpeg` — h264_rkmpp via the libavcodec C API, DRM-PRIME NV12 zero-copy, 1-in-1-out, fixed-QP intent, the `-Dffmpeg` meson feature. |
| 0002 | `rdp-renderer-initialize-...` | 2 | Bring the FFmpeg hwaccel up in the renderer alongside VA-API/NVENC. |
| 0003 | `rdp-render-context-select-...` | 1 | Pick the FFmpeg session **after** VA-API (VA-API stays preferred); the gate that falls back to RFX. |
| 0004 | `hwaccel-vulkan-query-the-base-drm-format-modifier-list` | 1 | **Unblocks the Mali GPU.** Query the base `VkDrmFormatModifierPropertiesListEXT`, not the `…List2` variant panvk leaves empty. See [`apps/gnome-remote-desktop/docs/design.md`](../docs/design.md) §journey. |
| 0005 | `encode-session-ffmpeg-allocate-nv12-surfaces-from-the-dma-heap` | 1 | panfrost GBM can't allocate NV12 → allocate from the dma-heap, lay out Y/UV by hand, 64-byte stride align (panvk + MPP). |
| 0006 | `rdp-view-creator-avc-fall-back-when-host_cached-...` | 1 | Retry the readback buffer without `HOST_CACHED` (panvk has no cached host memory type). |
| 0007 | `encode-session-ffmpeg-make-the-mainline-rkmpp-encoder-…` | 1 | The two **mainline-rkmpp** runtime fixes: first-frame IDR (recreate the encoder) + VBR quality (`rc_max_rate`/`rc_min_rate` + target). See [`../README.md`](../README.md) #1, #2. |
| 0008 | `rdp-avoid-hardware-encode-backpressure-stalls` | 9 | The hardware-encode backpressure guard: busy-session gating, stale-frame dropping, slow-encode cooldown fallback to software RFX/CAPROGRESSIVE, and automatic AVC retry after cooldown. See [`../README.md`](../README.md) #4. |
| 0009 | `Revert-daemon-system-Simplify-remote-display-reconnection` | 2 | The official GNOME 50.2 revert of `5230bf3`, restoring `SetRemoteId` and the two-stage GDM→session handover contract. The reverted change was not intended for GNOME 50. |
| 0010 | `daemon-system-Fix-RedirectClient-variant-ownership` | 1 | Sink the floating `GVariant` before `g_dbus_connection_emit_signal()` consumes it, preventing the observed double-unref assertion. |
| 0011 | `daemon-handover-Release-taken-socket-connection` | 1 | Release the socket returned by `TakeClient` after the handover daemon has adopted its fd. |
| 0012 | `daemon-system-Harden-handover-timeout-cleanup` | 1 | Reject `TakeClient` without a pending socket, re-arm/cancel the timeout consistently, and prevent a direct abort from leaving a live source behind. |
| 0013 | `daemon-system-Coalesce-pending-redirected-connections` | 1 | Replace only a simultaneously pending redirected socket. Once `TakeClient` consumes it, the same routing token remains reusable for the next GDM→session stage or a later reconnect. |
| 0014 | `rdp-add-pipeline-starvation-diagnostics` | 4 | Rate-limited counters for capture, view creation, stale drops, encode, submission, refresh/reset, and hardware cooldown; this produced the evidence that localized the Firefox freeze. |
| 0015 | `rdp-recover-from-stalled-hardware-encoding` | 7 | Rely on bounded low-delay waits in the matching FFmpeg package, reuse the smoke-tested context, refresh stale content with a forced IDR instead of recreating MPP, recover to software on an encode error, and put the watchdog on an independent thread. Requires FFmpeg `540657970e` or newer. |
| 0016 | `rdp-recover-from-pipeline-starvation-not-just-warn` | 1 | Make the starvation detector an **actuator** (escalate a sustained stall to `start_hw_encode_cooldown()`). ⚠️ **Does not fix the RK3588 wedge** — that turned out to be the `0017` readback cliff, not a recovery gap (the cooldown was already firing). Kept as a defensive improvement for genuine encode stalls; reconsider before upstreaming. See [finding](../../../findings/2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md). |
| 0017 | `egl-thread-read-back-via-a-cached-GPU-copy` | 1 | **The actual RK3588 hang fix.** `download_in_impl` read the captured frame back with `glReadPixels(GL_BGRA)` straight off the imported dma-buf texture, which panthor maps **uncached**; Mesa's per-pixel `convert_ubyte` fallback over uncached memory costs seconds-to-minutes/frame → EGL thread pinned at 100% CPU → pipeline wedge. Copy the import into a cached, driver-owned scratch texture on the GPU (`glCopyTexSubImage2D`, GLES2-safe) and read *that* back cached; lazy/resized, falls back to the direct read. Upstream-general (helps any driver with uncached imports); see [finding](../../../findings/2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md) and the Mesa/panfrost bugs it also exposes. |
| 0018 | `rdp-recover-when-resumed-frame-acknowledgements-stall` | 1 | Log RDPGFX acknowledgement suspend/resume state. When a real resume reconstructs suspended history but `totalFramesDecoded` makes no progress for two seconds, clear only that stale acknowledgement state, unthrottle surfaces, and force a full refresh/fresh render context. This preserves normal slow-client throttling and the intended suspend semantics; see [finding](../../../findings/2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md). |
| 0019 | `rdp-ignore-idle-time-when-detecting-pipeline-starvation` | 1 | Record when a drained pipeline first gains outstanding view/encode work and include that timestamp in the starvation baseline. This prevents a focus return from charging the preceding idle/output-suppressed interval as an immediate hardware stall while preserving the watchdog for continuously busy pipelines; see [finding](../../../findings/2026-07-20-grd-focus-return-false-pipeline-starvation.md). |
| 0020 | `rdp-log-every-client-audio-format` | 1 | Emit one normal-priority journal line per client `AUDIO_FORMAT`, including the tag, channels, sample rate, average byte rate, block alignment, sample depth, `cbSize`, and up to 256 codec-specific bytes. The cap prevents an untrusted client from creating an unbounded journal entry. |
| 0021 | `rdp-trace-audio-playback-and-disable-opus-offer` | 2 | Log DVC/SVC setup, formats/quality mode, training, delayed absence of PipeWire sinks, sink stream state, PCM buffers, first queueing, rate-limited `SNDC_WAVE2` sends, and rate-limited wave confirms. Temporarily advertise only AAC and PCM; the Opus implementation remains intact for restoration after the client investigation. |

`0001`–`0003` are the backend; `0004`–`0006` are the panvk/hardware-enablement
fixes ([`apps/gnome-remote-desktop/docs/design.md`](../docs/design.md)); `0007` is the mainline-rkmpp runtime fix
([`../README.md`](../README.md)); `0008` is the backpressure/cooldown guard
([`../README.md`](../README.md) #4); and `0009`–`0013` are the corrected
handover/reconnect series; `0014`–`0015` are the Firefox-stall diagnosis and
recovery; `0016` makes the starvation detector actuate the software fallback;
`0017` fixes the uncached readback cliff that `0016` could not recover from;
`0018` bounds a separate client-focus/RDPGFX acknowledgement-resume stall; and
`0019` prevents focus-idle time from falsely firing `0016`'s actuator. `0020`
logs the RDP audio-format exchange without changing selection, while `0021`
adds the end-to-end playback trace and temporarily changes the server offer
from AAC/Opus/PCM to AAC/PCM.
Patch `0007`'s quality settings remain relevant to the mainline
forward port, while `0015` supersedes its startup encoder recreation with a
forced IDR on the packaged Rockchip FFmpeg, which honours
`MPP_ENC_SET_IDR_FRAME`.

## Reference prototypes (not part of the series)

[`reference/`](reference/) preserves two measured, deliberately unshipped
experiments that were previously available only as dirty dev-box worktrees:

| Patch | Base | Purpose | Disposition |
|-------|------|---------|-------------|
| [`async-pbo-prototype.patch`](reference/async-pbo-prototype.patch) | `c14e09ef67e916ae83a4eddee6a56591078e78e0` | Adds the opt-in `GRD_ASYNC_READBACK` PBO/fence path (506 changed lines across four files). | Useful only with Mesa's compute-PBO route; slower on the default path and unable to pipeline across GRD's single-in-flight consumer. |
| [`memfd-prototype.patch`](reference/memfd-prototype.patch) | `c14e09ef67e916ae83a4eddee6a56591078e78e0` | Adds the opt-in `GRD_FORCE_MEMFD` negotiation and shm geometry (21 changed lines across two files). | Moves readback work into Mutter rather than removing it; not a performance fix. |

These are raw working-tree diffs, not `git format-patch` commits, and are not
included by either apply command below. Generated SPIR-V files were
excluded. The measurements and conclusions are in
[`../docs/baseline.md`](../docs/baseline.md) and
[`../docs/capture-path.md`](../docs/capture-path.md).

## Apply

```bash
# On upstream gnome-remote-desktop c14e09ef67e916ae83a4eddee6a56591078e78e0:
cd gnome-remote-desktop
git am /path/to/00*.patch

# Backend only on that same base, if reconnect changes are intentionally omitted:
git am /path/to/000[1-8]-*.patch /path/to/001[45]-*.patch

# Or as quilt patches in a Debian source package (from the matching base):
cp 00*.patch debian/patches/ && ls 00*.patch | sed 's#.*/##' >> debian/patches/series
```

## Reconnect history and design boundary

- **Bug #3 (greeter access)** is a udev rule, not code — packaged separately as
  [`packaging/gdm-hwenc`](../../../packaging/gdm-hwenc).

The earlier `rdp-handover-reconnect@a3a1a32` experiment set a global
`client_taken` flag and preserved registered displays on abort. It was
cherry-picked as `4e0d599` and reverted as `afc8f55` after it broke the normal
GDM→session transition: the routing token is intentionally reused for a second
leg, so treating it as globally single-use discarded a legitimate connection;
the preserve-on-abort path also left zombie remote displays.

The replacement branch fixes the actual boundaries. `0009` first restores the
GNOME 50 `SetRemoteId` protocol using GNOME's own 50.2 revert. `0013` coalesces
duplicates only while a socket is waiting for `TakeClient`; consuming that
socket clears the pending state, allowing the same token to drive the next
handover leg. No global `client_taken` state and no preserve-on-abort behavior
remain. `0010`–`0012` carry the independently valid ownership, NULL-socket, and
timeout cleanup fixes from the old experiment.

The published reconnect-only branch tip is
[`eb91daf476dc`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/commit/eb91daf476dc1c4ba23ccfdd8c077b8b83e84773).
Published `~exp3` is `2571326322c7` on top of diagnostic commit `1c870bc82d19`;
it passes a full build and the RDP integration test but predates patches `0016`
through `0019`. Local `exp5@b3f0e20` hardware testing validates `0017`.
Installed `exp6@7e958e6` fired `0018` once in the live focus workload and
restored hardware submissions, while also exposing the separate false
starvation actuator on focus return. Candidate `exp7@3e4480e` carries the
cleaned `0018@34145d9` plus `0019`; source and arm64 package builds pass, while
install/repeated macOS focus validation remains with FFmpeg `da5befc806`.
The local `exp8` diagnostic package applies `0020` on top of that clean commit
to capture the client's exact AAC, Opus, PCM, or other format tuples. Local
`exp9` adds `0021`; its source and native arm64 builds pass, the packaged
daemon contains the expected trace strings, and APT simulates a clean upgrade
from installed `exp8`. The package was then installed and traced a complete
SVC fallback through PipeWire PCM capture, `SNDC_WAVE2`, wave confirmation, and
audible macOS rendering after the PipeWire migration reboot. It remains a
temporary diagnostic build; compressed-codec interoperability and
publication/promotion remain.
