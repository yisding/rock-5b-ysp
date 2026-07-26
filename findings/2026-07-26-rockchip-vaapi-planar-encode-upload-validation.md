# rockchip-vaapi planar VA uploads are normalized safely to MPP NV12

> Scope: I420/YV12 system-memory input for the experimental H.264 and HEVC VA
> encoders in `rockchip-vaapi` on the ROCK 5B.
>
> Source: `../rockchip-vaapi` commit `b98a606`; gates
> `make check-driver-objects-sanitize`,
> `make check-h264-encode-experimental-sanitize`,
> `make check-hevc-encode-experimental-sanitize`, and
> `make check-encode-decode-concurrent`.
>
> Date: 2026-07-26.
>
> Trust: **MEASURED** / **CODE-INSPECTED** / **ASAN-UBSAN-CLEAN** /
> **HARDWARE-INTEROPERABILITY-VERIFIED**.

## Result

Experimental 8-bit encode configs now advertise NV12, I420, and YV12 upload
surfaces. `vaQueryImageFormats` and `vaCreateImage` expose explicit two-plane
NV12/P010 and three-plane I420/YV12 layouts. `vaPutImage` validates every
plane's pitch, offset, visible row width, row count, and backing-buffer capacity
before interleaving planar U/V into the native NV12 MPP DMA-BUF under explicit
CPU synchronization. `vaGetImage` reverses the mapping. Odd planar dimensions,
conflicting surface format attributes, partial-frame transfers, and mismatched
image/surface formats fail closed.

The important architecture boundary is that app-visible format and hardware
storage format are separate. FFmpeg and GStreamer need I420 in the encode
surface constraints to avoid an application-side conversion, but RKVENC2/MPP
still receives `MPP_FMT_YUV420SP`. Treating an I420 surface as physically
planar at submission time would feed the encoder the wrong chroma layout;
advertising I420 without implementing `vaPutImage` conversion would be a
success-returning data-corruption path.

## Application evidence

Stock FFmpeg 8 uploads `yuv420p` directly into the VA surface for both codecs.
The planar CQP runs are output-identical in size and PSNR to native NV12:

| Codec | Direct I420 PSNR | Native NV12 CQP PSNR |
|-------|------------------|-----------------------|
| H.264 High | 48.495713 dB | 48.495713 dB |
| HEVC Main | 45.191850 dB | 45.191850 dB |

GStreamer 1.28 now feeds I420 directly into `vah264enc` and `vah265enc` without
`videoconvert`, producing 48-frame standard-decodable streams at 48.644034 and
45.310424 dB. Driver logs prove at least one checked `I420->NV12` conversion
per encoded frame. The object gate proves byte-exact I420 and YV12
upload/download round trips.

Normal and ASan/UBSan gates pass. The expanded concurrency gate also passes:
both 96-frame, five-path encoder suites run together with the complete shipping
synthetic decode matrix. The default safe conformance subset remains green, so
the global image-format list did not change shipping decode negotiation.

## Boundary

This is a CPU-backed `vaCreateImage`/`vaPutImage` path. It does not import
planar DMABUFs, accept RGB, or use RGA. Imported GPU/DMABUF and RGB conversion
still need a separately gated RGA path. It also does not add P010 encode; the
fixed P010/librga decode/export evidence remains in the Main10 AFBC/P010
finding and should not be inferred from these 8-bit planar tests.
