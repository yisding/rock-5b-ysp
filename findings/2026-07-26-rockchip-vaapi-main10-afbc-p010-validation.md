# rockchip-vaapi 10-bit decode needs MPP AFBC plus crop metadata

> Scope: RK3588 HEVC Main10 and VP9 Profile 2 decode through `rockchip-vaapi`,
> MPP, librga, and the 6.18.40 ysp forward-port kernel.
>
> Source: `../rockchip-vaapi` commits `f03905a`, `820d88c`, `039dc85`,
> `e6c6aca`, `7e7980b`, `876a64f`, and `c383234`; gates
> `make check-hevc-main10-experimental`,
> `make check-hevc-main10-hdr-experimental`, and
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

`e6c6aca` expanded that result with checksum-pinned FATE
`WP_A_MAIN10_Toshiba_3.bit`: 256/256 displayed frames at 416x240 are P010
byte-identical through the same AFBC/RGA path. Three other official candidates
were rejected rather than counted as driver passes: direct MPP duplicated or
missed frames for `DBLK_A_MAIN10_VIXS_2.bit`, emitted an extra frame for
`WPP_A_ericsson_MAIN10_2.bit`, and the unequal luma/chroma bit depths in
`TSUNEQBD_A_MAIN10_Technicolor_2.bit` cannot be represented by P010.

## HDR metadata and pre-decode P010 export

`7e7980b` adds a 24-frame HDR10 gate. Hardware-decoded P010 remains
byte-identical to software and every frame retains limited-range BT.2020
non-constant-luminance color, BT.2020 primaries, SMPTE ST 2084 (PQ), mastering
display chromaticities plus 0.0001-1000 nit luminance, and MaxCLL 1000/MaxFALL
400 metadata.

The ownership boundary matters: libavcodec parses the original VUI and SEI
before VA submission and carries that metadata on its output `AVFrame`. VA's
HEVC picture parameters do not expose the original VUI/SEI syntax, so the SPS
reconstructed privately for MPP deliberately has
`vui_parameters_present_flag=0`; MPP does not need to reproduce the
application-facing metadata.

`876a64f` fixes the other P010 consumer boundary. `vaCreateSurfaces2` had
ignored both the 10-bit RT format and `VASurfaceAttribPixelFormat`, causing a
surface exported before first decode to claim NV12. Surface creation now
records NV12/P010, validates inconsistent requests, sizes the placeholder for
the declared linear format, and exports pre-decode P010 as either composed
P010 or Firefox-style split R16/GR1616. Normal and ASan/UBSan lifecycle tests
cover both descriptors; HDR and shipping-profile hardware regressions remain
green.

## VP9 Profile 2 confirmation

`rockchip-vaapi@039dc85` applies the same contract to VP9 Profile 2. Direct
RKMPP linear output mislabeled as P010 measured only 8.478340 dB average PSNR,
while direct RKMPP AFBC plus RGA P010 was byte-identical to software. The
forced VA-API gate then generated and decoded 48 lossless 320x240 Profile 2
frames with exact P010 output and 48 audited AFBC conversions.

`c383234` adds official conformance coverage from the WebM/libvpx test-data
set. Checksum-pinned `vp92-2-20-10bit-yuv420.webm` produces 10/10 displayed
P010 frames byte-identical to software and 11 audited AFBC conversions; the
extra decoder output is a hidden/reference frame and is retained as an exact
gate expectation. The default conformance run still requires software fallback
unless the Profile 2 opt-in is present.

The VP9 header parser now preserves hidden references with profile-matched
`show_existing_frame` packets and rejects Profile 2's 12-bit/RGB syntax because
the driver exposes only 10-bit 4:2:0 P010. Profile 2 remains experimental
pending application validation.

## GStreamer and Debian packaging

`a0ee342` adds the first stock desktop-app gate. GStreamer 1.28's `va` plugin
rejects an unfamiliar Rockchip vendor string by default; its supported
`GST_VA_ALL_DRIVERS=1` override registers `vah264dec`, `vah265dec`, and
`vavp9dec`. System-memory readback is byte-identical to software for pinned
H.264 High (10 frames), VP9 Profile 0 (1 frame), official VP9 Profile 2
(10 displayed/11 decoded frames), and HEVC Main10 (256 frames). This proves the
GStreamer VA/libva/driver readback path, not DMABUF display or HDR presentation.
A forced DMABUF-to-fakesink probe negotiated caps but correctly failed because
fakesink does not advertise the mandatory `GstVideoMeta`; a real display sink
must be tested in a graphical session.

`93320e6` builds lintian-clean `rockchip-vaapi` and
`rockchip-vaapi-config` packages at version `1.0.11+ysp3`. The driver package's
generated dependency set includes the installed MPP and `librga2` ABI versions,
and its ELF has full immediate-binding hardening. The optional config package
owns only driver selection plus GStreamer's vendor override. It does not set
`MOZ_DISABLE_RDD_SANDBOX`, `MOZ_ENABLE_WAYLAND`, or `MOZ_X11_EGL`; upgrading
the driver removes the old unowned ysp2 environment files that globally
disabled Firefox's RDD sandbox. A proper distribution Firefox policy remains
an open app-integration deliverable.

## Boundary

This now validates generated sequences for both codecs, one official vector per
codec, static HDR metadata propagation, and stock GStreamer system-memory
readback. It does not validate every resolution/stride combination, the broader
Main10 corpus, DMABUF display sinks, browser sandbox integration, or actual HDR
presentation in Firefox/mpv and the display stack. Both profiles therefore
remain experimental. It does settle the kernel-facing question for the
measured paths: do not add another kernel stride workaround for linear NV15
output. Request AFBC and honor MPP's AFBC header stride and crop metadata.

Do not extend this decode verdict to encode. At `rockchip-vaapi@03e6cb6`,
`rk_BeginPicture()` and `rk_mpp_enc_encode()` explicitly reject 10-bit encoder
surfaces, encoder preparation and `MppFrame` submission hard-code
`MPP_FMT_YUV420SP`, and the HEVC sequence validator accepts only Main profile
with 8-bit luma/chroma. HEVC Main10 capability advertisement, P010 input,
10-bit MPP stride/format setup, and a standard-decoder round-trip gate remain
unimplemented Phase 4 work.
