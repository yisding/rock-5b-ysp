# GRD's intermittent HW-encode wedge is userspace (rkmpp/ffmpeg), not the rkvenc2 driver

> Scope: gnome-remote-desktop `exp5` (patch 0017) on the ROCK 5B KASAN debug
> kernel (`Pf558`, forward-port rkvenc2), FFmpeg `8.0.3+rockchip+540657970e`
> `h264_rkmpp` encoder, under sustained full-screen video (YouTube) over RDP.
> Source: live driver task-trace (`mpp_dev_debug=0x20604`) correlated with GRD
> logs + gdb captures; daemon PID 127813, rkvenc session 16:109.
> Date: 2026-07-19
> Trust: MEASURED (driver task-trace at the exact failure second) / CONFIRMED
> (isolation test) / INFERRED (exact userspace mechanism, not yet pinned)

## Result

Under sustained load GRD's hardware H.264 encode intermittently enters a failure
loop: `h264_rkmpp` logs `Failed to get packet from encoder output queue`
(`AVERROR_EXTERNAL`), GRD (correctly) falls back to software for 10 s, recreates
the encoder session, fails again — for a stretch, then recovers. The software
windows stack up to far more than one 10 s cooldown, making the session laggy
(and, before patch 0017, the software readback path hung outright).

**The rkvenc2 driver and VEPU hardware are healthy throughout.** This is the
decisive evidence, from the driver task-trace at the *exact* failure second
(18:46:14, "Failed to get packet"):

```
mpp_process_task_default: session 16:109 task 43842 state 0x70000
mpp_task_run:             session 16:109 task 43842 state 0xf0003
irq_status: 00000001                                  ← normal completion (WDG bit8 clear)
mpp_free_task:            session 16:109 task 43842 state 0x1ff00bf abort 0
... tasks 43843, 43844, 43845, 43846 ... all identical, all normal ...
```

At the moment GRD reports the encoder failed, the driver is **submitting,
running, and completing GRD's frames normally** — `irq_status 00000001`, `abort
0`, and the abnormal-signature monitor (WDG/timeout/soft-reset/`abort 1`/nonzero
ret/IOMMU fault) stayed **silent** the entire time. So the hardware **produces
the encoded packets**; they just don't reach `encode_get_packet` within its
timeout.

## Scoping (what it is / isn't)

- **Not driver/hardware.** Confirmed twice: `mpi_enc_test` in a fresh process
  encodes flawlessly (173–226 fps, any resolution incl. GRD's 2064×1296) *while*
  GRD is wedged, and the driver trace shows GRD's own tasks completing normally.
- **Not the RDP session, MPP context, resolution, or a resource leak.** Persists
  across reconnect; GRD fully `mpp_destroy`/`mpp_create`s each retry; fd/session
  counts are stable (one session).
- **Not the reset-session/wait_result driver bugs (0042/0043).** No KASAN, no
  driver error/timeout.
- **It is GRD-process-specific and intermittent** — a stretch of failures on a
  session that is *actually encoding*, then self-recovery.

## Conclusion

The wedge is in **userspace**: the MPP library (`rkmpp`) packet output path or
the **ffmpeg-rockchip `h264_rkmpp` wrapper** (`rkmpp_get_packet`, the low-delay
`encode_put_frame`/`encode_get_packet` pairing with `MPP_SET_OUTPUT_TIMEOUT`).
Hardware-completed packets are not delivered to `encode_get_packet` before its
timeout, under sustained load. The kernel rkvenc2 driver is exonerated.

## Next

- **(b) finish**: trace the userspace side — `rkmpp` library debug
  (`mpp_debug`/`mpp_syslog` env) and the ffmpeg-rockchip `rkmppenc.c` put/get
  pairing — to pin where the completed packet is lost or the get times out (a
  1-in-1-out stall, an output-queue drain gap, or a timeout mismatch).
- **(c) mitigations** (help regardless): shorten `HW_ENCODE_COOLDOWN_US` (10 s →
  ~1–2 s) so each transient costs far less software time; and note GRD's
  session-recreate recovery is aimed at the wrong layer.
- Patch **0017** already removes the *hang* during these software windows
  (verified) — see
  [`2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md`](./2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md).

Disable the driver trace when done: `echo 0 > /sys/module/rk_vcodec/parameters/mpp_dev_debug`.
