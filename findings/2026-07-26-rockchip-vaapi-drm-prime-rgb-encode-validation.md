# rockchip-vaapi imports linear RGB DMA-BUFs for checked RGA encode input

> Scope: DRM PRIME 2 input for the experimental H.264/HEVC VA encoders in
> `rockchip-vaapi` on the ROCK 5B.
>
> Source: `../rockchip-vaapi` commit `0cce0b6`; gates
> `make check-rgb-dmabuf-encode-experimental`,
> `make check-rgb-dmabuf-encode-experimental-sanitize`,
> `make check-driver-objects-sanitize`,
> `make check-h264-encode-experimental`,
> `make check-hevc-encode-experimental`, and
> `make check-encode-decode-concurrent`.
>
> Date: 2026-07-26.
>
> Trust: **MEASURED** / **CODE-INSPECTED** / **ASAN-UBSAN-CLEAN** /
> **HARDWARE-INTEROPERABILITY-VERIFIED**.

## Result

Encode surfaces now implement the PRIME 2 import contract instead of silently
ignoring external descriptors. The accepted shape is intentionally narrow:

- one DRM object and one composed layer;
- `DRM_FORMAT_MOD_LINEAR`, exact visible dimensions, and checked capacity;
- canonical NV12 Y/UV offsets and equal pitches for direct MPP submission; or
- zero-offset packed RGBA, RGBX, BGRA, or BGRX with a four-byte-aligned pitch.

The driver duplicates the application fd and wraps that owned duplicate as an
external MPP buffer, so closing the descriptor fd after `vaCreateSurfaces2`
does not invalidate the surface. Compatible NV12 is submitted directly.
Packed RGB is converted synchronously by RGA into the driver's aligned native
NV12 allocation before each MPP encode submission. VA-managed RGB,
multi-object, tiled/modifier, undersized, mismatched, non-DMA-BUF, P010, and
planar external descriptors fail during surface creation. Imported surfaces
also reject `vaPutImage`, preventing the application from updating unrelated
driver-owned storage.

## Hardware evidence

The new public-libva probe allocates a real 320x240 BGRA DMA-BUF, imports it,
closes the application descriptor fd, updates the retained object for 48
frames, and encodes H.264 High. Standard FFmpeg decode returns all 48 frames at
**37.140921 dB** against a software BGRA-to-YUV reference. Driver audits show
exactly one accepted import, **48 RGA RGB-to-NV12 conversions**, and **48 MPP
packets**. The full-driver ASan/UBSan run produces the same frame count, PSNR,
and output size.

The object gate independently verifies imported BGRA and direct imported NV12
fd lifetime plus re-export identity, and rejects VA-managed RGB and a
multi-object descriptor. A build with `RGA_LIBS=` remains warning-clean and no
longer advertises RGB imports. `clang-tidy` is clean.

Existing native paths did not regress: H.264 CQP/CBR/VBR/I420 and GStreamer
remain at their prior 45.16-48.64 dB values; HEVC remains at 40.91-45.31 dB;
and concurrent H.264+HEVC encode plus the shipping decode matrix passes.

## Boundary

This closes linear one-object 8-bit encode import. It does not claim
multi-object GPU images, AFBC or other modifiers, planar external imports,
P010 encode, a display-sink DMA-BUF path, or application negotiation around
those formats. Those cases need separate descriptor and hardware gates.
