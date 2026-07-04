# video-libraries/ — media libraries on the codec stack

The media libraries that consume the kernel drivers + vendor libraries: FFmpeg
(hardware codecs and RGA filters) and Mesa/Panfrost (the Mali-G610 transfer work
behind the GRD fallback path).

| Project | Covers | Entry |
|---------|--------|-------|
| [`ffmpeg/`](ffmpeg/README.md) | `ffmpeg-rockchip` (upstream, 6.1-era base) and `ffmpeg-rockchip-81` (the port to FFmpeg 8.1.2): `h264_rkmpp`/`hevc_rkmpp` codecs, `scale_rkrga`/`vpp_rkrga` filters, rebase and fix series, upstream submission plan. | [`ffmpeg/`](ffmpeg/README.md) |
| [`mesa/`](mesa/README.md) | Mali-G610 Panfrost/panvk transfer + blit precision: the `u_blitter` `gl_FragCoord` fix, AFBC constraint, reproducers, and the upstream MR stack. | [`mesa/`](mesa/README.md) |

GStreamer is not yet its own project here — the GStreamer test harness lives with
the shared on-hardware tests in
[`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md).

State rollup: [`../status.md`](../status.md). Cross-cutting vocabulary:
[`../glossary.md`](../glossary.md).
