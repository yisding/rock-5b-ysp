# Rockchip FFmpeg 8.1.2 replay vs Jellyfin's forward port

Date: 2026-07-16

This is the same-base comparison that the earlier
[`jellyfin-ffmpeg-patch-survey.md`](jellyfin-ffmpeg-patch-survey.md) did not
perform. It compares the full `ffmpeg-rockchip-81` Rockchip stack replayed onto
canonical FFmpeg `n8.1.2` with Jellyfin's effective FFmpeg 8.1.2 source after
its complete Debian patch queue is applied.

The short result was to use the replayed `rockchip-8.1.2` branch as the
integration base. It has substantially stronger descriptor validation,
frame/EOS lifetime handling, current librga APIs, V4L2 fixes, and public
pixel-format hygiene. Jellyfin still has several valuable features to port
selectively: HEVC Dolby Vision RPU side data, `reset_sar`,
RKMPP-to-OpenCL/Vulkan derivation, and its packaging work.

> **Publication follow-up (2026-07-16):** the comparison snapshot below remains
> pinned to `rockchip-8.1.2@53b3551b9176` so its measured counts stay
> reproducible. Its maintained successor is the published
> `ffmpeg-81@8d3ca020b6a2`, 71 patch commits over
> `release/8.1@94138f6973dd`. Canonical `main@8b57e531d1fc` and
> `ffmpeg-80@be753f3bbb2c` carry the same complete logical patchset over current
> master and 8.0 bases. All unique refactor work, including the generic
> Jellyfin correctness import, is integrated. The Jellyfin-only DOVI,
> `reset_sar`, OpenCL/Vulkan, and packaging features listed below remain
> selective port candidates. The three new tips passed source compilation and
> `fate-source`, not new RK3588 runtime validation.

## 1. Source identity and materialization

| Source | Exact point | Materialized form |
|--------|-------------|-------------------|
| Canonical FFmpeg 8.1.2 | annotated tag `n8.1.2`, commit `38b88335f99e76ed89ff3c93f877fdefce736c13` | Release base for both effective trees. |
| Historical `ffmpeg-rockchip-81/main` snapshot | `be367abfe67045b9c68812ecee3b6162c92f9776`, described as `n8.2-dev-2123-gbe367abfe6` | The master-era Rockchip replay used during this comparison and recorded by the dedicated-PPA evidence. It is not a moving-tip claim. |
| Historical 8.0 port | branch `rockchip-8.0` at `463f542c325942f3e6b390cb940c32812570957d`, described as `n8.0.3-65-g463f542c32` | The earlier 8.0 source/package line, superseded for source work by published `ffmpeg-80@be753f3bbb2c`. |
| Comparison release replay | branch `rockchip-8.1.2` at `53b3551b9176b8db0f75eb7b0addd7bc26d20d5e`, described as `n8.1.2-63-g53b3551b91` | Reproducible snapshot for the counts below, superseded for source work by published `ffmpeg-81@8d3ca020b6a2`. It is 63 commits over canonical 8.1.2; `n8.1.2..HEAD` changes 37 files, with 9,507 insertions and 991 deletions. |
| Jellyfin FFmpeg | branch `jellyfin` at `455bfe53922014076d14c7f3f8c6631b4d3cd4c0`, described as `v8.1.2-1-13-g455bfe53` | Clean source/packaging checkout `/home/yi/Code/rock-5b/ffmpeg/jellyfin-ffmpeg`. |
| Jellyfin effective source | the same Jellyfin head with all 96 entries from `debian/patches/series` applied | Detached scratch worktree `/home/yi/Code/rock-5b/build/ffmpeg/jellyfin-ffmpeg-applied`; the original checkout remained clean. |

Jellyfin carries its Rockchip implementation primarily in
`debian/patches/0042-add-full-hwa-pipeline-for-rockchip-rk3588-platform.patch`,
not as committed files in the base source tree. Later queue entries also touch
shared codec/filter registration context, and patch `0079` adds the Vulkan
interop path. Comparing the unapplied checkout would therefore be wrong; all
96 patches were applied with quilt before the source comparison.

### How the real 8.1.2 branch was produced

The `upstream..main` Rockchip history contained 65 source commits. It was
replayed onto canonical `n8.1.2` with these integration decisions:

- the first conflict preserved 8.1.2's OMX registration while replacing its
  small native RKMPP implementation with the fork implementation;
- the `hwcontext_drm` preparation commit was already satisfied by 8.1.2 and
  became empty, so it was skipped;
- the fork-wide README replacement conflicted and was omitted because it does
  not affect the implementation;
- V4L2 multi-planar changes were translated onto the 8.1.2 APIs rather than
  accepting either side wholesale;
- the public libavutil addition was versioned as `60.27.100`, following
  8.1.2's `60.26.102`, instead of copying master's `61.3.100` version;
- the ten core Rockchip implementation files at the resulting branch were
  byte-for-byte identical to then-current `ffmpeg-rockchip-81/main@be367abfe6`;
  the remaining branch differences were release-base integration,
  registrations, API versioning, tests, and V4L2 context.

The two skipped source commits explain why the result is 63 commits above the
release tag rather than 65.

## 2. Common hardware surface

The implementations share the main platform feature set:

| Area | Both implementations expose |
|------|-----------------------------|
| RKMPP decoders | AV1, H.263, H.264, HEVC, MJPEG, MPEG-1, MPEG-2, MPEG-4, VP8, and VP9. |
| RKMPP encoders | H.264, HEVC, and MJPEG. |
| Decoder controls | deinterlace, AFBC policy, fast parsing, and buffer mode. |
| Encoder controls | rate-control modes, QP controls, intra refresh/GDR, profile/tier/level, user-data-unregistered SEI, and MJPEG chroma format. |
| RKRGA filters | scale, VPP, and overlay with core scheduling, asynchronous execution, AFBC, forced YUV, and forced chroma controls. |
| Frame model | an RKMPP hardware device layered on DRM PRIME/dma-buf descriptors so decode, RGA, and encode can remain in hardware frames. |

The matching codec and option lists do not imply matching failure behavior.
Most of the replay's extra code is validation and lifecycle handling around the
same user-visible surface.

## 3. Core implementation size

These counts are from the materialized trees above and cover the ten core
Rockchip files, not configure/registration/tests or Jellyfin's later interop
patches.

| File | `rockchip-8.1.2` | Jellyfin applied | Difference |
|------|-----------------:|-----------------:|-----------:|
| `libavcodec/rkmppdec.c` | 1,554 | 1,506 | +48 |
| `libavcodec/rkmppdec.h` | 148 | 181 | -33 |
| `libavcodec/rkmppenc.c` | 1,960 | 1,312 | +648 |
| `libavcodec/rkmppenc.h` | 330 | 321 | +9 |
| `libavfilter/rkrga_common.c` | 2,559 | 1,453 | +1,106 |
| `libavfilter/rkrga_common.h` | 139 | 133 | +6 |
| `libavfilter/vf_overlay_rkrga.c` | 379 | 377 | +2 |
| `libavfilter/vf_vpp_rkrga.c` | 698 | 592 | +106 |
| `libavutil/hwcontext_rkmpp.c` | 733 | 603 | +130 |
| `libavutil/hwcontext_rkmpp.h` | 138 | 153 | -15 |
| **Total** | **8,638** | **6,631** | **+2,007** |

Line count is not a quality score. Here it is useful because inspection shows
where the additional code went: encoder queue/lifetime state and RGA/DRM
validation dominate the difference.

## 4. Where the release replay is stronger

### DRM and AFBC validation

The replay treats DRM descriptors as externally supplied data and validates
their complete shape before importing them. It checks object, layer, and plane
counts; object indices; fourcc/modifier pairing; offsets, pitches, strides, and
object sizes; linear chroma layout; AFBC alignment and minimum size; and cases
where an AFBC byte stride cannot make a valid round trip.

Representative encoder helpers include
`rkmpp_is_supported_afbc_modifier()`, `rkmpp_get_drm_format()`,
`get_afbc_pixel_stride()`, `check_afbc_byte_stride_roundtrip()`,
`get_afbc_min_size()`, `rkmpp_check_drm_object0()`,
`rkmpp_check_drm_layer_format()`, `rkmpp_get_expected_chroma_pitch()`,
`rkmpp_check_linear_drm_layout()`, and `rkmpp_check_afbc_drm_layout()`.
RGA has the corresponding descriptor-shape, linear/AFBC layer, active-rectangle
stride, core-mask, and RGA2/RGA3 format checks.

Jellyfin performs much lighter validation. For example, its hwcontext contains
assert-style assumptions about descriptor plane counts where the replay returns
errors for invalid input. That difference matters at application and filter
boundaries, where a malformed descriptor should not abort the process or cause
an out-of-bounds import.

### Encoder ownership, asynchronous submission, and drain

The replay explicitly separates sent and unsent frames, tracks the oldest
unsent frame, records EOS queue state, and has a dedicated flush callback.
Relevant anchors include `get_sent_frame_count()`,
`get_oldest_unsent_frame()`, `get_rkmpp_drm_desc()`,
`rkmpp_get_valid_afbc_offset_y()`, and `rkmpp_encode_flush()`.

This is more robust than Jellyfin's simpler used-frame count when nonblocking
MPP submission, delayed output, flush, and frame ownership interact. It reduces
the risk of dropping a queued input, reusing a live frame, or hanging at EOS.

### Decoder initialization and drain

The replay:

- sends codec extradata as an explicit MPP extra-data packet before the first
  non-MJPEG payload (`mpp_packet_set_extra_data()`);
- negotiates an initially unknown output format through `ff_get_format()`
  instead of forcing DRM PRIME before MPP reports the frame format;
- has the newer drain/flush and buffer-group ownership fixes;
- parses MJPEG SOF dimensions and validates the output allocation size;
- centralizes AFBC capability decisions and rejects unsupported RKFBC export.

Jellyfin does not have the same lifecycle hardening, but it has the Dolby Vision
feature described in §5.

### Current librga API and input validation

The replay requires the modern im2d symbols `querystring`, `imsync`,
`improcessOpt`, and `wrapbuffer_fd_t`, wraps dma-buf fds directly, and executes
through `improcessOpt()`. Jellyfin still executes its main operation through
the legacy `c_RkRgaBlit()` API, although it uses `imsync()` for fences.

The replay also validates active rectangles against strides, scheduler core
masks, RGA2/RGA3 format restrictions, compressed layouts, scale ratios after
rotation, and object bounds before dispatch. These checks account for much of
the 1,106-line `rkrga_common.c` difference.

### V4L2 fixes outside the core ten files

The release replay also carries fixes that Jellyfin's Rockchip series does not:

- safer ownership/release and copy bounds in `libavcodec/v4l2_buffers.c`;
- multi-planar negotiation and format handling in
  `v4l2_context.c`/`v4l2_fmt.c`;
- multi-planar capture, padded raw reads, two-pass fallback, retry handling,
  bounds checks, and NV21 mapping in `libavdevice/v4l2.c` and
  `v4l2-common.c`.

These are not RKMPP features, but they are part of the replayed stack and are
relevant to a future V4L2-stateless or mixed pipeline.

### SAR, public pixel formats, and modifiers

The replay guards unknown sample aspect ratios and bases SAR adjustments on the
cropped active dimensions. In particular, a 90/270-degree rotation cannot turn
an unknown `0/1` SAR into invalid `1/0` metadata.

It also preserves upstream's endian-neutral
`AV_PIX_FMT_NV20 = AV_PIX_FMT_NE(NV20BE, NV20LE)` macro and registers the
fork's compact 20-bit layout separately as `AV_PIX_FMT_NV20_PACKED`. The public
addition has APIchanges entries, tests, and the libavutil `60.27.100` version
bump.

The replay deliberately removed the private RFBC DRM modifier. No official DRM
modifier describes Rockchip RFBC, so publishing a locally invented modifier
would make descriptors appear interoperable when they are not. The decoder
rejects RKFBC export instead.

## 5. Features Jellyfin has that the replay does not

| Jellyfin feature | What it does | Porting disposition |
|------------------|--------------|---------------------|
| HEVC Dolby Vision RPU propagation | Initializes an FFmpeg DOVI context, parses HEVC RPU NAL units, queues by PTS, and attaches `AV_FRAME_DATA_DOVI_RPU_BUFFER` plus parsed DOVI metadata to decoded frames. Configure selects `dump_extradata_bsf`, `dovi_rpudec`, and `hevcparse` for `hevc_rkmpp`. | Port to the replay, preserving its newer decoder queue/drain model. |
| `reset_sar` in `vpp_rkrga` | Scales proportionally to square pixels and writes SAR 1:1. | Port; it is a contained, user-visible feature. |
| OpenCL derivation | Handles `AV_HWDEVICE_TYPE_RKMPP` like DRM under the ARM DRM OpenCL path. | Port and compile/runtime-test with the intended OpenCL implementation. |
| Vulkan derivation | Jellyfin patch `0079` derives a linear multiplane Vulkan image from RKMPP frames. | Port after checking it against the replay's descriptor validation and current Vulkan APIs. |
| Debian/build integration | Carries arm64 packaging and builder integration for MPP/RGA. | Reuse selectively in the PPA/package flow. |
| RFBC/RK3576 path | Detects RK3576 from `/proc/device-tree/compatible`, publishes a private RFBC modifier, and lets RGA consume RFBC. | Do **not** copy as-is; it needs an official modifier or a clearly private non-DRM transport contract. |
| Legacy librga FBCE fixup | Uses `RGA_NORMAL_FBCE_RGB_BGR_FIXUP` around `c_RkRgaBlit()` for older libraries. | Test whether the same hardware/library issue affects modern `improcessOpt()`; port only the proven workaround, not the legacy execution path. |

There is also a CLI-visible default difference: Jellyfin defaults
`force_original_aspect_ratio` to `decrease` (`1`), while the replay defaults it
to `disable` (`0`). Commands that omit this option can therefore produce
different output dimensions. `reset_sar` exists only in Jellyfin.

## 6. Jellyfin compatibility hazards

Jellyfin repurposes the public name `AV_PIX_FMT_NV20`. Canonical 8.1.2 already
defines `AV_PIX_FMT_NV20LE`, `AV_PIX_FMT_NV20BE`, and the native-endian
`AV_PIX_FMT_NV20` macro for that format family. Jellyfin removes the macro,
appends a new packed enum with the same source-level name, and marks LE/BE as
deprecated in favor of it. Existing callers can compile with changed format
semantics.

Jellyfin also leaves libavutil at `60.26.102` and has no APIchanges entry for
the public pixel-format addition. That makes the ABI/API delta invisible to
version checks. The replay's `NV20_PACKED` name and version bump are the safer
contract.

The other two integration cautions are the unofficial public RFBC modifier and
the older librga blit API. Neither should be imported wholesale merely to make
the code resemble Jellyfin.

## 7. Build validation performed

This pass was compile validation and source inspection, not RK3588 runtime
validation.

The host's default pkg-config search path pointed at Homebrew, so the builds
used:

```bash
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig
```

Detected dependencies were `rockchip_mpp 1.3.10`, `librga 2.1.0`, and
`libdrm 2.4.131`. Both effective trees configured successfully with:

```bash
--enable-rkmpp --enable-rkrga --enable-version3 --enable-libdrm \
--disable-doc --disable-programs --disable-debug
```

Both trees compiled these core objects:

- `libavcodec/rkmppdec.o`, `libavcodec/rkmppenc.o`;
- `libavfilter/rkrga_common.o`, `vf_overlay_rkrga.o`, `vf_vpp_rkrga.o`;
- `libavutil/hwcontext_rkmpp.o`.

Both also compiled the codec/filter registration and public pixel-format paths:
`allcodecs.o`, `allfilters.o`, `pixdesc.o`, and swscale's
`format.o`/`input.o`/`swscale_unscaled.o`. The replay additionally compiled
`v4l2_buffers.o`, `v4l2_context.o`, `v4l2_fmt.o`, and libavdevice's
`v4l2.o`/`v4l2-common.o`.

The out-of-tree build directories were `/tmp/rk812-build-replayed` and
`/tmp/rk812-build-jellyfin`. Successful compilation proves the sources match
the installed headers and libraries; it does not prove decode, encode, AFBC,
RGA, DOVI, OpenCL/Vulkan interop, EOS behavior, or malformed-descriptor
rejection on hardware.

## 8. Integration recommendation

Use published `ffmpeg-81@8d3ca020b6a2` as the maintained FFmpeg 8.1 Rockchip
base. The generic Jellyfin correctness work is already integrated; port only
these remaining Jellyfin deltas first:

1. HEVC Dolby Vision RPU parsing/side data, adapted to the replay's frame queue;
2. `vpp_rkrga=reset_sar`;
3. RKMPP OpenCL and Vulkan derivation hooks;
4. packaging pieces that are still missing from this repository's PPA flow.

Keep the replay's `NV20_PACKED`, modern im2d execution, descriptor validation,
and RFBC rejection. Treat the legacy FBCE RGB/BGR workaround as a test case for
modern librga, not as a reason to revert to `c_RkRgaBlit()`.

Before shipping the combined tree, run RK3588 hardware tests for every shared
codec, linear and AFBC decode-to-RGA-to-encode, forced rotation/SAR, delayed
output plus flush/EOS, malformed DRM descriptors, DOVI PTS reordering, and the
OpenCL/Vulkan derive paths. The compile results above are intentionally not a
substitute for that matrix.
