# rockchip-vaapi H.264 VA encode is interoperable through FFmpeg and GStreamer

> Scope: experimental H.264 Main/High `VAEntrypointEncSlice` in
> `rockchip-vaapi`, backed by RKMPP/RKVENC2 on the ROCK 5B.
>
> Source: `../rockchip-vaapi` commit `760ef3c`; gates
> `make check-h264-encode-experimental`,
> `make check-h264-encode-experimental-sanitize`, and
> `make check-encode-decode-concurrent`.
>
> Date: 2026-07-26.
>
> Trust: **MEASURED** / **CODE-INSPECTED** / **ASAN-UBSAN-CLEAN** /
> **HARDWARE-INTEROPERABILITY-VERIFIED**.

## Result

`rockchip-vaapi@760ef3c` adds an opt-in H.264 VA encoder without changing the
shipping capability set. `RK_VAAPI_EXPERIMENTAL_ENCODE=h264` exposes Main and
High `VAEntrypointEncSlice` for NV12. Sequence, picture, one full-frame slice,
rate-control, and frame-rate buffers are snapshotted into an MPP encoder config;
the source surface is submitted with `encode_put_frame`, and one MPP packet is
returned as a `VACodedBufferSegment`.

Stock FFmpeg 8 `h264_vaapi` encoded all 48 deterministic 320x240 frames as
interoperable High-profile H.264 in every exposed rate-control mode:

| Mode | Average PSNR | Output bytes |
|------|--------------|--------------|
| CQP | 48.495713 dB | 130231 |
| CBR | 46.262560 dB | 150403 |
| VBR | 45.158094 dB | 145210 |

Each stream decoded through FFmpeg's standard software H.264 decoder, contained
exactly 48 frames, exceeded the 35 dB gate, and had exactly one audited MPP
packet per input frame.

After a fresh GStreamer 1.28 `va` plugin scan with its supported
`GST_VA_ALL_DRIVERS=1` vendor override, `vah264enc` registered against the
driver. Its sink caps correctly expose NV12 only, rather than the P010 format
used by separate 10-bit decode configs. A 48-frame system-memory I420 to NV12
pipeline produced High-profile H.264 at 48.644034 dB average PSNR and decoded
normally.

## Correctness boundaries learned

- `vaPutImage` cannot be a success-returning stub for system-memory encoder
  clients. It now validates full-frame NV12/P010 layout, performs explicit
  dma-buf CPU write synchronization, and copies visible rows into the aligned
  MPP surface.
- Surface attributes must be config-specific. Advertising both NV12 and P010
  globally caused GStreamer to claim unsupported H.264 encoder input; the
  selected RT format now determines the sole pixel format.
- An encode context must reject an input surface whose dimensions or bit depth
  differ from the context. The driver also enforces its advertised 7680x4320
  ceiling before stride arithmetic or MPP allocation.
- Coded-buffer overflow fails closed with
  `VA_CODED_BUF_STATUS_FRAME_SIZE_OVERFLOW`; invalid or incomplete VA parameter
  sets do not reach MPP.
- Fresh, unowned upload surfaces report `VASurfaceReady`, while decode-owned
  in-flight surfaces report `VASurfaceRendering`, aligning
  `vaQuerySurfaceStatus` with `vaSyncSurface`.

Normal and ASan/UBSan app gates pass for all three FFmpeg modes plus GStreamer.
The normal and sanitizer object-lifecycle gates cover capability hiding,
config/surface attributes, coded-segment mapping, byte-exact NV12 upload and
readback, surface status, dimension mismatch, and oversized-context rejection.

The board-level overlap gate also passed. It was subsequently strengthened at
`b579bad`: concurrent 96-frame H.264 and HEVC encoder runs completed while the
shipping synthetic decode matrix exercised six H.264 reference/B-frame
combinations, 4K H.264, five VP9 runs, and unadvertised VP8 software fallback.
All three independent MPP workloads completed cleanly.

## Boundary

This is deliberately an experimental frame-level path. It supports progressive
NV12, H.264 Main/High, CQP/CBR/VBR, MPP-generated headers, and one full-frame
slice. HEVC Main encode is validated separately at `b579bad`; multi-slice
operation, additional input formats, a WebRTC sender, browser encoder
integration, and long-duration encode soak remain open. The one-slice limit
also avoids claiming coverage beyond the kernel RKVENC2 slice-FIFO hardening
already validated elsewhere in this repo.
