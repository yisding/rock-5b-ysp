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

## Why GRD trips on it

The `AV_CODEC_FLAG_LOW_DELAY` strict 1-in-1-out `lock_bitstream` model (patches
0007/0015) assumes each `send_frame` is immediately followed by one
`receive_packet`. The MPP async encoder is **pipelined** with a finite input task
pool and applies backpressure via `MPP_NOK` from `put_frame`. Under sustained
high-frame-rate load the pipeline backs up, `put_frame` is refused, and the
strict-pairing waiter times out instead of draining — so GRD declares the
hardware encoder dead and drops to software for 10 s (the readback path fixed by
0017), repeatedly.

## Fix directions (userspace)

1. **GRD encode session** (`grd-encode-session-ffmpeg.c`): on `send_frame`
   `EAGAIN`/`put_frame` `MPP_NOK`, drain `receive_packet` to free input slots and
   retry, instead of treating it as an encode failure — i.e. don't require strict
   1-in-1-out against a pipelined encoder. This is the primary fix.
2. **FFmpeg-rockchip `rkmppenc.c`**: handle the input-full `MPP_NOK` internally
   (bounded retry with an interleaved get) so a transient full pool isn't surfaced
   as `AVERROR_EXTERNAL`.
3. **Tuning**: raise the MPP encoder input task/buffer count so momentary 60 fps
   spikes don't exhaust the pool; and (mitigation, task c) shorten
   `HW_ENCODE_COOLDOWN_US` so a transient costs far less software time.

## Cleanup after tracing

```
rm ~/.config/systemd/user/gnome-remote-desktop-handover.service.d/20-mpp-trace.conf
systemctl --user daemon-reload && systemctl --user restart gnome-remote-desktop-handover.service
sudo sysctl -w kernel.yama.ptrace_scope=1
```
(Driver debug `mpp_dev_debug` already disabled.)
