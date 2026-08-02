# GRD hardware-encode recovery: forced IDR was implemented but unwired, and the detector could never see a hung encode

> Scope: `gnome-remote-desktop` AVC420 render path on RK3588; fix committed as
> `fix/forced-idr-recovery@100da72`, branched off
> `release/50.2-rkmpp-upstream-20260729@c4ef3c9` (which is unchanged), worktree
> `~/Code/rock-5b/gnome/grd/grd-upstream-20260729`
> Source: `grd-rdp-renderer.c` `start_hw_encode_cooldown()`,
> `recover_hw_encode_after_cooldown()`, `note_hw_encode_duration()`,
> `on_bitstream_locked()`, `encode_image_views()`;
> `grd-encode-session-ffmpeg.c` `create_encoder()`; `grd-encode-session.h`
> Date: 2026-08-01
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, DESIGN (runtime not yet exercised)

## Result

Three defects in the hardware-encode recovery path, all in the same failure
story: when AVC encoding degrades, the client is never given a way back.

**1. The key-frame mechanism existed but nothing called it.**
`request_key_frame` is a `GrdEncodeSessionClass` vfunc and *both* backends
implement it — `grd_encode_session_ffmpeg_request_key_frame()` sets
`force_next_idr`, which `build_av_frame()` honours as
`AV_PICTURE_TYPE_I` / `key_frame = 1`; the VA-API backend has the equivalent
`pending_idr_frame`. It had exactly **one** caller, the stale-frame branch of
`maybe_start_encodings()`. Neither `start_hw_encode_cooldown()` nor
`recover_hw_encode_after_cooldown()` called it; both only invoked
`request_full_refresh_for_all_surfaces()`, which sets
`needs_full_refresh` on the surface renderer and does **not** recreate the
render context.

That matters because of design decision D5 in the backend's own
`docs/ffmpeg-rkmpp-backend.md` (in the grd source tree, not this repo): the
AVC backends run an effectively infinite GOP (`gop_size = refresh_rate * 3600`,
one IDR per session), and "client refresh is driven by render context
recreation". Since the cooldown paths do not recreate the context, a client
whose decoder state had diverged had **no resync point at all**.

**2. The stall detector could never fire for a hung encode.**
`note_hw_encode_duration()` — and therefore `start_hw_encode_cooldown()` — is
reachable only from `on_bitstream_locked()`, the completion callback. An encode
that never returns reports no duration, so it can never trigger the recovery
built for it. This is the structural gap recorded in
[2026-07-18](2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md),
confirmed here at source level.

**3. Fixed QP had no bitrate ceiling.** Covered in
[the transport finding](2026-08-01-grd-rdp-video-stall-transport-congestion.md).

## Fix

`fix/forced-idr-recovery@100da72` — 3 files, +287/−49, builds clean with no new
warnings. Not yet packaged, installed, or booted.

- **`request_key_frame_for_all_render_contexts()`** walks
  `render_context_table` under `inhibition_mutex` and requests an IDR from each
  live encode session. Called from *both* cooldown transitions — entering the
  degraded state, and returning to hardware, the latter being the case where
  the client's H.264 decoder state is stale and previously got nothing.
- **Atomic key-frame flags.** The request is now issued from the encode thread
  and consumed on the renderer thread. FFmpeg's read-modify-write became
  `g_atomic_int_exchange()`, which also closes a lost-request window that
  existed in principle before; VA-API's set/get became atomic.
- **Watchdog.** `note_hw_encode_submitted()` / `note_hw_encode_completed()`
  track in-flight hardware encodes and the time of last completion progress;
  `check_hw_encode_watchdog()` polls every
  `HW_ENCODE_WATCHDOG_INTERVAL_US` (250 ms) while anything is outstanding and
  drives the normal cooldown path once no completion has been seen for
  `HW_ENCODE_WATCHDOG_TIMEOUT_US` (2 s). The timeout sits an order of magnitude
  above `HW_ENCODE_STALL_THRESHOLD_US` (250 ms) so merely slow encodes remain
  `note_hw_encode_duration()`'s business. The source disarms itself when
  nothing is in flight, so an idle session keeps no timer. On firing it resets
  the progress clock, so a permanently stuck encode retriggers once per timeout
  rather than on every poll.
- **Capped VBR** in `create_encoder()`: `rc_mode=VBR` (numeric constant 0),
  `qp_min = FIXED_QP`, `qp_max = 40`, `avctx->qmin/qmax` for codec-generic
  builds, and a ceiling from `compute_bitrate_ceiling()` — pixel rate ÷ 8
  (~0.125 bpp/frame), clamped to [2, 40] Mbps, overridable via
  `GNOME_REMOTE_DESKTOP_RDP_MAX_BITRATE`. For the 2056×1290@60 surface that is
  a **19.9 Mbps ceiling** with a 15.9 Mbps target.

Naming the mode stays inside D3's portability rule: `rc_mode` is a known option
on ffmpeg-rockchip and `0` is a valid constant for it, while on mainline the
name is unknown and is tolerated and logged rather than fatal. Verified against
the installed encoder (`ffmpeg 8.0.3+rockchip+git20260729.33a651a55b`), whose
AVOptions are `rc_mode` (`VBR 0 / CBR 1 / CQP 2 / AVBR 3`, default 6),
`qp_init`, `qp_min`, `qp_max`, `qp_min_i`, `qp_max_i`.

**Lock-order check.** Both new call sites run with no renderer mutex held:
`start_hw_encode_cooldown()` releases `hw_encode_mutex` before its refresh
calls, `on_bitstream_locked()` reaches it before taking
`frame_encodings_mutex`, `check_hw_encode_watchdog()` is a `GSource` dispatch,
and `handle_graphics_subsystem_failure()` — the one path that runs under
`inhibition_mutex` — never reaches the cooldown. The new
`frame_encodings_mutex` → `hw_encode_mutex` nesting in `encode_image_views()`
has no inverse anywhere.

## Boundary

**COMPILE-VERIFIED only.** Nothing here has been exercised at runtime. In
particular these are unproven:

- that a forced IDR after a cooldown actually restores a wedged client;
- that the watchdog fires on a real hung encode rather than only on synthetic
  reasoning — no stall was induced to trigger it;
- that capped VBR holds the stream under the ceiling on this hardware, or that
  `qp_min = 22` really reproduces FIXQP output on static content;
- that `rc_mode=VBR` behaves as documented on the installed fork; the option
  table was read, but no encode was run to confirm MPP reports VBR rather than
  FIXQP.

The change also does **not** make recovery fire more often for the
acknowledgement wedges in
[2026-07-20](2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md) — those deadlock
in frame flow control with the encoder idle and healthy, which neither the
watchdog (nothing is in flight) nor an IDR addresses.

Two consequences worth tracking:

- `GrdAVCFrameInfo` still reports `qp = 22`, which under capped VBR is now the
  **floor** rather than every frame's QP. rkmpp exposes no per-packet quality
  statistics, so the floor is the closest honest value; MS-RDPEGFX treats it as
  advisory. This breaks D3's "mirror the reported constants" symmetry with
  VA-API.
- VA-API's key-frame request retains a lost-request window: its flag is read in
  `h264_frame_new()` and cleared at the far end of the frame lifecycle, so it
  cannot be claimed with a single exchange. Left as-is and commented — VA-API
  declines on this board (no AVC encode entrypoint), so the path is untestable
  here.

## Verification gate

On hardware, with a client attached:

1. Confirm the daemon logs `[HWAccel.FFmpeg] Rate control: VBR, ceiling
   19891800 bps, target 15913440 bps, QP 22-40` at session start, and that MPP
   reports a VBR mode rather than `mode fixqp`.
2. Replay the YouTube workload and re-sample `ss -tin` on port 3389; the
   `Send-Q` excursions recorded in
   [the transport finding](2026-08-01-grd-rdp-video-stall-transport-congestion.md)
   should shrink or disappear.
3. Induce a hardware-encode stall (the MPP conformance-suite workload from
   [2026-07-18](2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md)
   is the known trigger) and confirm a `[RDP] Hardware encode is unavailable
   (encode watchdog, ...)` warning appears within ~2 s and that the session
   recovers rather than staying wedged for ~90 s.
