# FFmpeg Rockchip review learnings

This note captures the review lessons from hardening
[`ffmpeg-rockchip-81`](https://github.com/yisding/ffmpeg-rockchip-81), branch
`main`, through commit `a7f67c4cf4` (`fix v4l2 fallback buffer release`) on
2026-07-02.

The fixes came from repeated focused review passes over three surfaces:

- V4L2 capture and V4L2 M2M behavior in FFmpeg's upstream-ish code paths.
- RKMPP decoder/encoder hwcontext and AFBC/DRM descriptor handling.
- RKRGA filter capability selection, transform validation, and AFBC handling.

The point of this file is the reusable trap list: what went wrong, why it was
subtle, and what to check next time.

## V4L2 capture lessons

### Dual-cap capture fallback is larger than format probing

Some devices expose both `V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE` and
`V4L2_BUF_TYPE_VIDEO_CAPTURE`. The Rockchip-oriented code should prefer MPLANE,
but preference is not enough: fallback has to cover the entire setup path, not
only `TRY_FMT`, `S_FMT`, or early layout validation.

Practical rule: if the MPLANE path reaches a recoverable buffer setup, `QBUF`,
or `STREAMON` failure on a dual-cap device, retry single-planar capture from a
clean state.

The clean-state part matters:

- Reset width, height, pixel format, and layout-derived state before retrying.
- Do not let a failed probe leak a stale codec or raw format choice into the
  single-planar path.
- Treat the retry as a new device-mode selection, not a continuation of the
  failed MPLANE setup.

### Kernel buffers must be released on fallback

When fallback happens after `VIDIOC_REQBUFS`, userspace cleanup with `munmap`
does not release the kernel-side queue. The retry can then fail because the
driver still owns buffers for the abandoned buffer type.

Practical rule: track whether `VIDIOC_REQBUFS` succeeded independently from
userspace mmap state. On fallback, call `VIDIOC_REQBUFS` again with `count = 0`
for the failed queue before selecting the alternate capture type.

This is especially easy to miss because partial mmap initialization can already
clear local userspace state while kernel buffers remain allocated.

### Single-planar and MPLANE fourcc entries must stay paired

The V4L2 raw format table needs both single-planar and MPLANE entries where the
kernel has both forms. NV21 had `V4L2_PIX_FMT_NV21M` but not
`V4L2_PIX_FMT_NV21`, which meant a single-planar NV21 device, or a dual-cap
device falling back to single-planar, could never try the valid fourcc.

Practical rule: for every semiplanar raw format table edit, verify the single
and mplane variants together: NV12/NV12M, NV21/NV21M, NV16/NV16M, NV61/NV61M,
and their 10-bit or vendor-specific equivalents.

### Padded raw capture is valid, but packets must be compacted

V4L2 drivers may report `sizeimage` or `bytesused` larger than the compact frame
size because the image is padded. FFmpeg packet consumers generally expect the
compact raw frame size.

Practical rule for raw capture:

- Accept `sizeimage >= frame_size` when the reported layout is otherwise valid.
- Trim trailing padding before the final raw packet-size check.
- For single-planar capture, only trim when `G_FMT` confirms a tight
  `bytesperline` and the compact frame size is known.
- For MPLANE capture, trim per-plane padding before combining/checking the
  packet.

Without the trim, valid padded devices can produce empty packets or fail a
strict frame-size check.

### Capability checks should use device_caps when present

If `V4L2_CAP_DEVICE_CAPS` is set, the effective device capability bits live in
`device_caps`, not in the top-level `capabilities` field.

Practical rule: normalize capability reads before deciding whether a device has
capture, output, MPLANE, streaming, or M2M support.

## V4L2 M2M lessons

### Requested raw pixel format probing must try all matching fourccs

Several V4L2 fourccs can map back to the same `AVPixelFormat`. A type-preferred
mapping is not enough when the requested software pixel format has alternate
single-planar/MPLANE or vendor-specific encodings.

Practical rule: when the caller requested an `AVPixelFormat`, enumerate all
driver-advertised fourccs that map to that requested format before falling back
to any acceptable raw format.

This avoids selecting a looser "any raw" format even though the driver offered a
valid alternate fourcc for the exact requested format.

### TRY_FMT must verify the returned fourcc

A successful `VIDIOC_TRY_FMT` does not necessarily mean the requested fourcc was
accepted unchanged. Drivers can adjust the format.

Practical rule: after `TRY_FMT`, verify that the returned fourcc is still the
candidate being tested before accepting the candidate.

## RKMPP AFBC and DRM lessons

### Revalidate afbc=rga after decoder info-change

The decoder can only know actual dimensions, strides, and software format after
MPP reports info-change. `afbc=rga` therefore cannot be fully validated at
static option-parse time.

Practical rule: after info-change, re-check whether the actual frame layout can
be consumed by RGA. If not, disable AFBC output with
`MPP_DEC_SET_OUTPUT_FORMAT = MPP_FRAME_FBC_NONE` before sending
`INFO_CHANGE_READY`.

This prevents creating AFBC decoder output that the configured downstream RGA
path cannot process.

### AFBC DRM pitch math must use padded bits-per-pixel

Compact 10-bit formats such as `NV15` and `NV20_PACKED` are not described
correctly by simple chroma subsampling ratios. AFBC DRM descriptors need pitches
computed from the padded bits-per-pixel model.

Practical rule: use `av_get_padded_bits_per_pixel()` for AFBC DRM pitch
conversion instead of deriving pitch from plane subsampling alone.

### AFBC object-size validation must include headers and body payload

A DRM object that is large enough for the first address is not necessarily large
enough for the full AFBC image. Validation needs a floor that includes AFBC
headers plus compressed block payloads, accounting for padded bits-per-pixel,
block columns/rows, and `afbc_offset_y`.

Practical rule: validate AFBC object size against the full layout, not just
against visible dimensions or the first plane offset.

### RKMPP hwcontext chroma pitch can be format-specific

For NV24/NV42-style semiplanar 4:4:4 formats, the chroma pitch expected by the
encoder follows the packed chroma relationship, not the 4:2:0/4:2:2 chroma
subsampling intuition.

Practical rule: for NV24/NV42 in the RKMPP hwcontext, use `chroma pitch =
luma pitch * 2` to match the encoder's expected single-stride relationship.

## RKRGA lessons

### Compact 10-bit linear input is not compact 10-bit AFBC input

`NV15` and `NV20_PACKED` linear input requires conservative runtime handling.
Linear compact 10-bit input forces RGA2. AFBC compact 10-bit input is a
different path and can be valid on RGA3/RGA2-Pro.

Practical rule: do not force RGA2 statically just because the software format is
`NV15` or `NV20_PACKED`; wait until the frame modifier tells whether the input
is linear or AFBC. At runtime, force RGA2 for compact 10-bit linear input.

### force_yuv output selection must be conservative before input modifiers are known

`force_yuv=auto` and explicit `force_yuv=10bit` can be evaluated before the
input frame's modifiers are known — and therefore before it is known whether the
pipeline will be forced onto RGA2. If the filter commits to a 10-bit output
format up front, a later RGA2 fallback (triggered by the scale ratio, RGA2 size
limits, or RGA2-only compact 10-bit linear input) can leave the graph demanding a
10-bit output the selected RGA core cannot actually produce. That surfaces as a
runtime blit failure rather than a clean negotiation error, which is the harder
class to diagnose.

Practical rule: keep `force_yuv` output-format selection conservative until both
the input frame modifier and the final RGA core choice (RGA2 vs RGA3) are
settled. Do not lock in a 10-bit output before confirming the eventual core can
emit it; re-derive the output format once the modifier and the RGA2/RGA3 decision
are known, the same way compact 10-bit *input* handling waits for the modifier
(see the RGA2-forcing rule above). The `vpp_rkrga` path is the concrete offender:
it could keep a 10-bit output selected even after scale ratio, size limits, or
RGA2-only input had already forced RGA2.

