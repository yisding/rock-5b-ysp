# rockchip-vaapi 10-bit decode needs MPP AFBC plus crop metadata

> Scope: RK3588 HEVC Main10 and VP9 Profile 2 decode through `rockchip-vaapi`,
> MPP, librga, and the 6.18.40 ysp forward-port kernel.
>
> Source: `../rockchip-vaapi` commits `f03905a`, `820d88c`, and `039dc85`; gates
> `make check-hevc-main10-experimental` and
> `make check-vp9-profile2-experimental`; direct MPP/RGA and
> reconstructed-Annex-B probes retained locally in that checkout.
>
> Date: 2026-07-26.
>
> Trust: **MEASURED** / **CODE-INSPECTED** / **ROOT-CAUSED** /
> **FIX-RUNTIME-VERIFIED**.

## Result

Yes: for this decode path, the new kernel plus current librga fixes the P010/RGA
problem below `rockchip-vaapi`. A 48-frame 320x240 HEVC Main10 clip now decodes
through VA-API to P010 byte-for-byte identically to software. Direct RKMPP plus
RGA is also byte-identical, and software decode of the driver's reconstructed
Annex B is byte-identical. No additional kernel change was needed for the final
Main10 fix.

The remaining failure was the MPP output-layout contract, not broken P010
conversion in the kernel:

- VDPU383's default linear 10-bit output reported a 448-byte horizontal stride
  and a derived 358-pixel stride for a 320-pixel frame.
- NV15 stores four 10-bit pixels in five bytes. MPP derives pixel stride as
  `byte_stride * 8 / 10`, so 448 bytes truncates to 358 pixels and loses the
  fractional packing relationship.
- librga correctly rejects 358 because the NV15 virtual-width contract requires
  a 64-pixel-aligned stride. Treating 448 bytes as 358 or rounding it elsewhere
  cannot describe the original linear buffer exactly.
- The known-good Rockchip FFmpeg path avoids that impossible representation by
  requesting `MPP_FRAME_FBC_AFBC_V2`. `rockchip-vaapi` now does the same for
  experimental HEVC Main10 contexts.

For AFBC output, the fields needed by librga are not the ordinary MPP horizontal
stride alone. The working contract is:

- format: `MPP_FMT_YUV420SP_10BIT | MPP_FRAME_FBC_AFBC_V2`;
- RGA source read mode: `IM_AFBC16x16_MODE`;
- pixel stride: `mpp_frame_get_fbc_hdr_stride()` (320 in the measured case);
- vertical stride: `mpp_frame_get_ver_stride()` (256);
- source rectangle origin: `mpp_frame_get_offset_x/y()` (measured as `(0,4)`);
- conversion: NV15 to linear P010 with the visible 320x240 rectangle.

The crop origin is correctness-critical. Ignoring `offset_y=4` produced a
vertically shifted image with average PSNR 21.718395 dB. Passing `(0,4)` to RGA
made every byte of all 48 output frames match software.

## Driver guardrails

`rockchip-vaapi@820d88c` keeps Main10 behind the exact opt-in
`RK_VAAPI_EXPERIMENTAL_PROFILES=hevc-main10`. The driver:

- advertises `VAProfileHEVCMain10` and `VA_RT_FORMAT_YUV420_10` only under that
  opt-in;
- requests AFBC V2 from MPP when creating the Main10 decoder;
- rejects Main10 context creation if RGA is unavailable;
- validates AFBC pixel/vertical stride and visible crop bounds before import;
- accepts linear NV15 only when byte stride converts exactly to the reported,
  64-aligned pixel stride, so the 448-byte/358-pixel case fails closed;
- converts into a P010 dma-buf and exports that buffer through the normal surface
  path.

The reproducible gate generates its own 48-frame libx265 Main10 stream, compares
software and VA-API P010 outputs with `cmp`, verifies exact output size, and
requires one logged AFBC conversion per frame. It passed together with the
normal build, object lifecycle hardware test, sanitizer, Valgrind, lint, and safe
decode gates before `820d88c` was pushed.

## VP9 Profile 2 confirmation

`rockchip-vaapi@039dc85` applies the same contract to VP9 Profile 2. Direct
RKMPP linear output mislabeled as P010 measured only 8.478340 dB average PSNR,
while direct RKMPP AFBC plus RGA P010 was byte-identical to software. The
forced VA-API gate then generated and decoded 48 lossless 320x240 Profile 2
frames with exact P010 output and 48 audited AFBC conversions.

The VP9 header parser now preserves hidden references with profile-matched
`show_existing_frame` packets and rejects Profile 2's 12-bit/RGB syntax because
the driver exposes only 10-bit 4:2:0 P010. Profile 2 remains experimental
pending pinned conformance and HDR playback.

## Boundary

This validates one generated sequence per 10-bit codec, not broad Main10 or VP9
Profile 2 conformance, HDR metadata propagation, every resolution/stride
combination, or browser integration. Both profiles therefore remain
experimental. It does settle the kernel-facing question for the measured
paths: do not add another kernel stride workaround for linear NV15 output.
Request AFBC and honor MPP's AFBC header stride and crop metadata.
