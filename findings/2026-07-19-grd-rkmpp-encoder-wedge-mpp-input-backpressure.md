# GRD encoder wedge, pinned: MPP input-task backpressure + get_packet timeout (userspace flow control)

> Scope: continuation of
> [`2026-07-19-grd-rkmpp-encoder-wedge-userspace-not-driver.md`](./2026-07-19-grd-rkmpp-encoder-wedge-userspace-not-driver.md).
> gnome-remote-desktop `exp5`, FFmpeg `8.0.3+rockchip+540657970e` `h264_rkmpp`,
> MPP `1.0.12` (`mpp-rockchip @ 1375813c`), RK3588, full-screen video over RDP.
> Source: MPP library trace (`mpp_enc_debug=0x101b0`, `mpi_debug=0x3`) captured
> live across ~6 wedge events, daemon 452265.
> Date: 2026-07-19
> Trust: MEASURED (mpi/mpp_enc trace at the failure) / SOURCE-INSPECTED
> (`mpp.c` `mpp_put_frame_async`) / CONFIRMED (driver exonerated separately)

## Root cause

The intermittent `Failed to get packet from encoder output queue`
(`AVERROR_EXTERNAL`) → 10 s software fallback is a **userspace encoder
flow-control stall** between GRD's FFmpeg encode session and the MPP async
encoder. It is **not** the rkvenc2 driver or the VEPU (both healthy — see the
companion finding), and **not** an outright failure: the MPP trace shows the
encoder producing `output packet`s continuously.

The trigger is **input backpressure**. In `mpp_put_frame_async` (`mpp/mpp.c`),
`mpi_encode_put_frame` polls the input port for a **free task slot**; GRD's input
timeout is non-blocking, so when the input task pool is momentarily exhausted
under sustained 60 fps load it returns **`MPP_NOK` (-1)**. Then GRD's
`mpi_encode_get_packet` returns **`-8` (`MPP_ERR_TIMEOUT`)** after its bounded
~500 ms low-delay wait, which the FFmpeg wrapper maps to `AVERROR_EXTERNAL`.

Trace at the failure (daemon 452265):

```
mpi: mpi_encode_put_frame  leave ... ret -1     ← input task pool full → MPP_NOK (backpressure)
mpp_enc: try_get_async_task get input frame failed
mpi: mpi_encode_get_packet leave ... ret -8     ← MPP_ERR_TIMEOUT (~500 ms)
[h264_rkmpp] Failed to get packet ... -542398533  → AVERROR_EXTERNAL
[RDP] Hardware encode is unavailable (encode failed, duration 500xxx us)
```

`put_frame` succeeds 1208× vs only 6 rejections in the window, and the encoder
emits `output packet pts …` throughout — so this is a **transient** pool-exhaustion
race under load, which is why it recovers on its own and recurs after a stretch.

## Why GRD trips on it — the exact wrapper mechanism (resolved)

Read against the **deployed** encoder, `ffmpeg-rockchip-81 @ 540657970e`
("avcodec/rkmppenc: bound synchronous output waits"), the loop in
`rkmpp_encode_frame` is:

```
send: put the oldest unsent frame; if MPP_NOK → EAGAIN → goto get
get:  encode_get_packet(timeout = RKMPP_SYNC_TIMEOUT_MS = 500 ms)
```

For GRD's `AV_CODEC_FLAG_LOW_DELAY` frame, when `put_frame` is refused
(`MPP_NOK`, the finite input task pool momentarily full because the previous
frame's slot is reclaimed asynchronously), the loop `goto get`s and **waits the
full 500 ms on output for a frame that was never submitted**. The wait elapses
(`MPP_ERR_TIMEOUT`, -8), which `rkmpp_get_packet` mapped to `AVERROR_EXTERNAL`,
and GRD declares the hardware encoder dead → software for 10 s (readback hang
fixed by 0017), repeatedly. The put-refused frame was **never retried**; the
hardware was healthy and draining packets the whole time (companion finding).

## Where the fix must live — and why not GRD

The fix has to be **inside the ffmpeg-rockchip wrapper**, not GRD. GRD's
synchronous `lock_bitstream` is strictly 1-in-1-out by construction
(`grd-encode-session-ffmpeg.c`: `encode_frame` stashes the `AVFrame` per
`image_view`; `lock_bitstream` steals *that* frame and demands *its* packet), so
it cannot pipeline. And it cannot safely retry either: a submitted frame is
already in MPP's pipeline, so re-`send` would double-submit, while re-`receive`
enters the encode2 drain path (`rkmpp_submit_frame(NULL)` → `mpp_frame_set_eos`)
and would **end the stream**. Only the wrapper, which owns the put/get pairing
and the send queue, can absorb the transient without those hazards.

## Fix — implemented

`ffmpeg-rockchip-81` `fix/rkmpp-output-timeout` commit **`da5befc806`**
("avcodec/rkmppenc: absorb transient input backpressure on sync encode"):

1. On a **synchronous** call, a refused `put` is transient: back off
   `RKMPP_INPUT_RETRY_US` (250 µs) and **retry the send** within the deadline,
   instead of blocking output on an unsent frame. The async (nonblocking) path
   keeps its drain-on-EAGAIN behavior.
2. **One shared `RKMPP_SYNC_TIMEOUT_MS` deadline** across the put retries and the
   output wait, so absorbing a full pool never runs a call past its 500 ms
   budget; a genuine stall still fails fast → GRD software fallback.
3. `MPP_ERR_TIMEOUT` → `AVERROR(EAGAIN)` in `rkmpp_get_packet`, matching the
   `540657970e` comment's stated intent ("return EAGAIN after this deadline") — a
   bounded wait elapsing means "no packet yet", not a hardware failure.

Compile-verified (object build of `rkmppenc.o` in the configured tree). **Still
needs a runtime rebuild + reproduce under sustained RDP video load** to confirm
the wedge is gone. GRD needs no change; its fallback-on-genuine-stall is correct.

Complementary (optional): raise the MPP input task/buffer count so momentary
60 fps spikes don't exhaust the pool at all; and (task c) shorten
`HW_ENCODE_COOLDOWN_US` so any residual transient costs far less software time.

## Cleanup after tracing

```
rm ~/.config/systemd/user/gnome-remote-desktop-handover.service.d/20-mpp-trace.conf
systemctl --user daemon-reload && systemctl --user restart gnome-remote-desktop-handover.service
sudo sysctl -w kernel.yama.ptrace_scope=1
```
(Driver debug `mpp_dev_debug` already disabled.)
