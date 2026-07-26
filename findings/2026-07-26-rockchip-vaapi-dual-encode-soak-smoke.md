# rockchip-vaapi dual encode soak exposed HEVC visible/aligned geometry

> Scope: paced concurrent H.264 and HEVC VA encode soak on the ROCK 5B.
>
> Source: `../rockchip-vaapi` commit `4fbc2b2`; gates
> `make check-encode-soak-experimental`,
> `make check-encode-soak-experimental-sanitize`, and a targeted 640x360
> `make check-hevc-encode-experimental` run.
>
> Date: 2026-07-26.
>
> Trust: **MEASURED** / **ROOT-CAUSED** / **CODE-INSPECTED** /
> **ASAN-UBSAN-CLEAN** / **SMOKE-ONLY**.

## Result and root cause

The first paced dual-codec run appeared to fail HEVC after 120 seconds, but
retained logs proved `vah265enc` had failed its first frame while H.264 kept the
parent harness alive. GStreamer created a 640x368 HEVC VA context/sequence for
a 640x360 visible I420 surface. The driver's strict context/surface equality
rejected `vaBeginPicture`.

The driver now accepts only the exact 16-pixel ceiling for HEVC encode. MPP
prep and frame geometry use the visible 640x360 surface and its 640x368 stride;
the HEVC sequence may carry either visible or aligned dimensions. Arbitrary
dimension mismatches still fail. A targeted 640x360 gate then passed all four
FFmpeg modes plus direct-I420 GStreamer, whose MPP log reports visible
`640:360` prep with `640:368` stride.

The corrected concurrent smoke completed 1,800 live frames per codec over 60
seconds. Combined post-warmup RSS was flat at 58,792 KiB, fds were flat at 60,
and both driver logs contained exactly 1,800 MPP packets plus at least 1,800
checked planar uploads. A 30-second full-driver ASan/UBSan smoke completed 900
frames per codec with stable fds and bounded sanitizer RSS growth.

## Harness lesson and boundary

Backgrounding a shell function made `$!` identify wrapper subshells, producing
false resource samples near 1 MiB/5 fds. Launching each `gst-launch` command
directly makes `$!` identify the real pipeline; valid combined samples are
roughly 59 MiB/60 fds. Resource soak harnesses must prove which process they
sample.

This is smoke coverage only. The committed gate defaults to two paced hours
and reports shorter durations as smoke. That qualification run, kernel-log
window audit, imported RGB/DMABUF conversion, and full WebRTC peer negotiation
remain open.
