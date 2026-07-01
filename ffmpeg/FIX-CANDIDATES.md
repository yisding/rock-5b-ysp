# FFmpeg fix candidates from the 2026 Rockchip rebase

This records the fixes found while comparing the local `ffmpeg-rockchip-81`
working branch against both `origin/nyanmisaka` and the local `upstream` FFmpeg
branch.

Source points from the audit:

| Tree | Commit | Meaning |
|------|--------|---------|
| `ffmpeg-rockchip-81/main` | `1c73bd8e65` | Current rebased Rockchip stack with post-review cleanups. |
| `origin/nyanmisaka` | `40c412dacc` | Older ffmpeg-rockchip fork point used by this repo's build notes. |
| `upstream` | `87bd15dc3c` | Current FFmpeg branch used for the rebase comparison. |

The useful range for the new cleanup work is mostly `def08a047f..1c73bd8e65`.
The older commits in `upstream..main` are the replayed Rockchip feature stack,
not all fresh fixes. The recommendations below are grouped by where they are
worth sending.

## Summary

| Fix group | Send to NyanMisaka? | Send to FFmpeg upstream? | Why |
|-----------|---------------------|--------------------------|-----|
| V4L2 multi-planar packet accounting | Yes | Maybe, as a smaller port | It fixes real packet-size and data-offset handling. Upstream's V4L2 mplane path is narrower, so it needs a targeted version. |
| V4L2 framerate fallback and `NV16`/`NV24` guards | Yes | Partly | The framerate fallback is generic. The guards are already present upstream, but useful for older fork code. |
| Packed `NV15`/`NV20` swscale and descriptor fixes | Yes | Not as a fix-only patch | Upstream does not have `AV_PIX_FMT_NV15` or `AV_PIX_FMT_NV20_PACKED`; this would need a pixel-format feature series first. |
| RKMPP decoder ownership, errinfo, MJPEG, EOS, and format fixes | Yes | No, unless replacing/extending upstream RKMPP | These fix the fork's RKMPP hwcontext based decoder. Upstream's RKMPP decoder is a different, smaller implementation. |
| RKMPP encoder async, packet, DRM, submit-unwind, and RC fixes | Yes | Mostly no | Some ideas overlap with upstream, but the code paths and option surface differ substantially. |
| RKMPP hwcontext, RKRGA lifetime, and build cleanup | Yes | No | Upstream has no `AV_HWDEVICE_TYPE_RKMPP` hwcontext and no RKRGA filters. |

## 1. V4L2 multi-planar packet accounting

Relevant local commits: `021c7102d8`, `c44cc876db`.

Files/functions affected in the rebased tree:

- `libavdevice/v4l2.c:mmap_read_frame()`
- `libavdevice/v4l2.c:mmap_init()` in the broader multi-plane support series

What it fixes:

The older NyanMisaka V4L2 multi-planar read path sums each plane's `bytesused`
and then copies `bytesused` bytes starting at `data_offset`. In V4L2, for an
mplane buffer, `bytesused` is the number of bytes used in the plane buffer and
`data_offset` is where valid payload starts inside that plane. The payload length
is therefore:

```c
payload = plane.bytesused - plane.data_offset;
```

Using `bytesused` directly after adding `data_offset` makes the packet too large
and can copy bytes past the valid payload. The effect depends on the capture
driver: some drivers report zero offsets, but drivers that reserve per-plane
headers or alignment padding expose the bug.

What the fix does:

- Tracks per-plane payload sizes after subtracting `data_offset`.
- Rejects impossible buffers where `bytesused < data_offset` and requeues the
  V4L2 buffer before returning an error.
- Sums payload bytes, not raw `bytesused`, when allocating the output packet.
- Copies each plane from `plane_base + data_offset` for only the payload length.
- Clears both the packet size and per-plane payloads when `V4L2_BUF_FLAG_ERROR`
  is reported, so corrupted buffers do not leak stale lengths into the copy path.

Why it matters here:

This repo validates the full MPP/RGA stack with ffmpeg-rockchip, but V4L2 capture
is still useful for HDMI/USB capture devices and for comparing vendor userspace
against mainline media paths. Bad mplane accounting produces corrupt packets,
truncated frames, or out-of-bounds reads depending on the driver.

Submission guidance:

- Send to NyanMisaka as a direct bug fix for the fork's multi-plane support.
- For FFmpeg upstream, port only the data-offset correctness piece. Upstream's
  current V4L2 code already has a `multiplanar` path, but it accepts only one
  plane during mmap setup, so the multi-plane copy loop from the fork is not a
  direct drop-in.

## 2. V4L2 framerate fallback and pixel-format guards

Relevant local commits: `021c7102d8`, plus the older V4L2 feature commits
`3fab10a1f5` and `07ec138ade`.

Files/functions affected:

- `libavdevice/v4l2.c:v4l2_set_parameters()`
- `libavdevice/v4l2-common.c:ff_fmt_conversion_table[]`

What it fixes:

Some capture devices fail `VIDIOC_G_PARM`, even though they expose a valid mode
through `VIDIOC_G_DV_TIMINGS` or the user supplied an explicit `-framerate`.
The older fork had two problems in that error path:

- When falling back to the user-supplied rate, it wrote `framerate_q.num` into
  `timeperframe.numerator` and `framerate_q.den` into `timeperframe.denominator`.
  `timeperframe` is the reciprocal of framerate, so the values must be swapped.
- The fork added unconditional `V4L2_PIX_FMT_NV16` and `V4L2_PIX_FMT_NV24`
  mappings. Older kernel headers may not define those fourcc macros, so the
  build can fail even when the runtime device does not use those formats.

What the fix does:

- If `VIDIOC_G_PARM` fails, it first tries `VIDIOC_G_DV_TIMINGS` and estimates
  frame rate from pixel clock and total blanked dimensions.
- If timings are unavailable but the user passed `-framerate`, it stores
  `timeperframe = framerate.den / framerate.num`, which matches the normal
  `VIDIOC_S_PARM` path.
- It wraps `V4L2_PIX_FMT_NV16` and `V4L2_PIX_FMT_NV24` entries in `#ifdef`, just
  like upstream FFmpeg does.

Why it matters here:

This avoids false "time per frame unknown" behavior on devices that expose DV
timings but reject `G_PARM`, and it keeps the fork buildable on more distro and
vendor kernel headers.

Submission guidance:

- Send the framerate fallback and header guards to NyanMisaka.
- Upstream already has the `NV16`/`NV24` guards. The `G_DV_TIMINGS` fallback can
  be considered upstream after style and edge-case review.

## 3. Packed `NV15`/`NV20` swscale and descriptor fixes

Relevant local commits: `021c7102d8`, `275f06843a`, `93891823df`,
`1c73bd8e65`.

Files/functions affected:

- `libswscale/input.c:nv15_20ToYUV_c()`
- `libswscale/swscale_unscaled.c:nv15_20ToPlanarWrapper()`
- `libswscale/format.c` for `AV_PIX_FMT_NV20_PACKED` support in the new swscale
  format table
- `libavutil/pixdesc.c` for the packed `NV20` descriptor name

What it fixes:

The Rockchip fork carries compact 10-bit semi-planar formats:

- `AV_PIX_FMT_NV15`: compact 10-bit 4:2:0, similar to `P010` but without six zero
  padding bits per sample.
- `AV_PIX_FMT_NV20_PACKED`: compact 10-bit 4:2:2, similar to `P210` but without
  padding bits.

The old conversion helpers assume convenient groups:

- four luma samples per five bytes;
- two chroma pairs per five bytes;
- an even number of chroma rows.

That loses tail samples when width is not a multiple of four, loses tail chroma
samples when chroma width is odd, and truncates chroma height when the luma slice
height is odd for a subsampled format. The input helper also used a second
shifted 16-bit load that is unnecessary and can contaminate the unpacked 10-bit
sample near byte boundaries.

The fork's compact `AV_PIX_FMT_NV20_PACKED` descriptor was also named `nv20`.
That collides with FFmpeg's normal `NV20` name family and can make
`av_get_pix_fmt("nv20")` resolve to the compact packed format rather than the
ordinary endian `NV20` format.

What the fix does:

- Extracts each packed 10-bit sample by sample index instead of by fixed groups.
- Handles sample positions 0, 1, 2, and 3 inside each five-byte group explicitly.
- Iterates up to the actual luma width and chroma width rather than truncating
  with `/ 4` or `/ 2`.
- Uses ceil division for chroma slice height: `(srcSliceH + vsub - 1) / vsub`.
- Registers `AV_PIX_FMT_NV20_PACKED` as an input-capable swscale format in the
  current swscale format table.
- Renames the packed descriptor to `nv20_packed` and updates the FATE references
  that query pixel-format names.

Why it matters here:

Rockchip MPP and RGA commonly expose compact 10-bit NV formats. Broken unpacking
shows up as wrong colors, dropped right-edge pixels, or bad chroma on odd-sized
content and cropped slices. These formats are also used when transferring RKMPP
hardware frames back to software for debugging.

The descriptor rename prevents command-line users, filters, and tests from
confusing the fork-only packed format with FFmpeg's normal `NV20` spelling.

Submission guidance:

- Send to NyanMisaka. The old branch has the same helper shape and benefits from
  the same tail-sample fixes, although the file names and swscale internals differ.
- Do not send this to upstream as a standalone bug fix. Upstream has endian
  `NV20LE/BE` but not the fork's compact `NV15`/`NV20_PACKED` formats. Upstream
  would first need a pixel-format addition with tests and documentation, and the
  compact format should keep the unambiguous `nv20_packed` name.

## 4. RKMPP decoder: MJPEG output buffer sizing

Relevant local commit: `93891823df`.

Files/functions affected:

- `libavcodec/rkmppdec.c:rkmpp_mjpeg_parse_dimensions()`
- `libavcodec/rkmppdec.c:rkmpp_mjpeg_output_buffer_size()`
- `libavcodec/rkmppdec.c:rkmpp_mjpeg_put_packet()`

What it fixes:

The RKMPP MJPEG decoder requires the caller to attach an output frame buffer to
packet metadata. The older code sized that buffer from `avctx->width` and
`avctx->height`. Those fields can be unset before the first MJPEG frame is parsed,
or stale if the stream changes dimensions.

What the fix does:

- Parses JPEG SOF markers from the input packet when codec dimensions are not yet
  known.
- Computes an aligned output size from the parsed or known dimensions.
- Checks for overflow before multiplying width, height, and bytes per pixel.
- Fails with `AVERROR_INVALIDDATA` when dimensions cannot be determined, instead
  of allocating a bad buffer and letting MPP fail later.

Why it matters here:

MJPEG is not the primary ROCK 5B validation target, but ffmpeg-rockchip exposes
`mjpeg_rkmpp`. This fix makes first-frame behavior deterministic and avoids
buffer-size mistakes that are hard to diagnose from MPP errors alone.

Submission guidance:

- Send to NyanMisaka with a focused explanation that this only affects the fork's
  MJPEG decoder path.
- Not useful for upstream as-is. Upstream does not have the same MJPEG RKMPP
  decoder flow.

## 5. RKMPP decoder: frame ownership, info-change, and errinfo cleanup

Relevant local commits: `383bd2a4f3`, `9319172196`, `1c73bd8e65`.

Files/functions affected:

- `libavcodec/rkmppdec.c:rkmpp_get_frame()`
- `libavcodec/rkmppdec.c:rkmpp_decode_close()`
- `libavcodec/rkmppdec.c:rkmpp_set_buffer_group()`
- `libavcodec/rkmppdec.c:rkmpp_export_frame()`

What it fixes:

Several decoder paths transfer ownership of an MPP frame into an FFmpeg `AVFrame`
buffer callback. Once that happens, the local `MppFrame` variable must not be
cleaned up by the error-exit path. The decoder also keeps a pending `AVPacket`
for retry after MPP input queue backpressure; that packet needs to be unreferenced
on close.

The half-internal buffer mode also borrows the buffer group owned by the RKMPP
hardware frames context. The decoder must not put that group directly after the
frames context owns it.

The latest review cleanup found three additional edge cases: export failures
after an `MppFrame` is attached to an `AVFrame` can leak or double-free depending
on which cleanup path runs; `info_change` was assigned the truth value of a
larger expression rather than the exact MPP flag; and hardware errinfo frames
were still ignored when the caller requested fail-fast behavior with
`AV_EF_EXPLODE`.

What the fix does:

- Sets `mpp_frame = NULL` after successful `rkmpp_export_frame()` so the shared
  exit path does not deinitialize a frame now owned by the output frame.
- Unrefs `r->last_pkt` during decoder close.
- Clears `r->buf_group` after unreffing `r->hwframe` in half-internal mode,
  avoiding a dangling pointer to a group owned by the frames context.
- Avoids directly putting the half-internal group in the setup-failure path after
  ownership has moved to the frames context.
- Makes `rkmpp_export_frame()` consume the `MppFrame` on both success and
  failure, with `av_frame_unref()` handling callbacks after the frame buffer owns
  the MPP frame and DRM descriptor.
- Frees the temporary software-output frame if hardware export fails.
- Stores the real `mpp_frame_get_info_change()` value in `r->info_change`.
- Returns `AVERROR_INVALIDDATA` for errinfo frames when `AV_EF_EXPLODE` is set.

Why it matters here:

These are lifetime fixes. Without them, decode failures or close/flush edges can
become double-free, stale-pointer, or leaked-packet bugs rather than clean FFmpeg
errors.

The `AV_EF_EXPLODE` handling also restores FFmpeg API expectations: users who
ask the decoder to fail on damaged frames should not silently receive EAGAIN and
continue through a hardware-reported decode error.

Submission guidance:

- Send to NyanMisaka. This is high-value cleanup for the fork's RKMPP hardware
  frame model.
- Not a standalone upstream patch because upstream's decoder uses generic DRM
  frames and a different lifetime model.

## 6. RKMPP decoder: EOS and backpressure handling

Relevant local commits: `021c7102d8`, `5c0c56e8c8`.

Files/functions affected:

- `libavcodec/rkmppdec.c:rkmpp_send_eos()`
- `libavcodec/rkmppdec.c:rkmpp_decode_receive_frame()`

What it fixes:

The older EOS path could spin until `decode_put_packet()` accepted an EOS packet.
If MPP reports temporary input queue fullness, a busy loop is the wrong FFmpeg
behavior: receive-frame should surface `EAGAIN` or drain available output, then
retry later.

What the fix does:

- Sends EOS once and maps temporary MPP input-full statuses to `AVERROR(EAGAIN)`.
- Logs temporary backpressure at trace level instead of as a hard failure.
- Lets the receive loop attempt output retrieval and retry rather than blocking in
  a tight put-packet loop.
- Treats MJPEG specially because its decoder is one-input/one-output and does not
  need a normal delayed EOS drain.

Why it matters here:

This aligns the RKMPP decoder with FFmpeg's nonblocking receive API. It prevents
hangs during flush/end-of-stream on streams that leave MPP's input queue full
while decoded frames are still pending.

Submission guidance:

- Send to NyanMisaka.
- Upstream has different RKMPP receive logic; only the general principle is
  transferable.

## 7. RKMPP decoder: output format and HDR metadata details

Relevant local commits: `021c7102d8`, `93891823df`.

Files/functions affected:

- `libavcodec/rkmppdec.h:rkmpp_dec_pix_fmts[]`
- `libavcodec/rkmppdec.c:rkmpp_export_frame()`

What it fixes:

The decoder can map MPP 4:4:4 semi-planar output to `AV_PIX_FMT_NV24`, but the
advertised software pixel format list omitted `NV24`. HDR side data export was
also limited to HEVC even though AV1 can carry mastering display and content light
metadata through MPP.

What the fix does:

- Adds `AV_PIX_FMT_NV24` to the decoder pixel-format list.
- Exports mastering display and content light side data for AV1 as well as HEVC
  when the transfer function indicates HDR (`SMPTE2084` or `ARIB_STD_B67`).

Why it matters here:

It makes negotiated software output match the formats the decoder already knows
how to describe, and it preserves HDR metadata for AV1 decode tests or users.

Submission guidance:

- Send to NyanMisaka.
- Not useful upstream without the fork's broader output-format model.

## 8. RKMPP encoder: DRM descriptor validation

Relevant local commit: `c44cc876db`.

Files/functions affected:

- `libavcodec/rkmppenc.c:rkmpp_check_drm_object0()`
- `libavcodec/rkmppenc.c:rkmpp_set_enc_cfg_prep()`
- `libavcodec/rkmppenc.c:rkmpp_submit_frame()`

What it fixes:

The encoder imports dma-buf frames through an `AVDRMFrameDescriptor`, but MPP
import in this encoder path supports only a single DRM object. The old code used
object zero directly and trusted each layer plane's `object_index`.

What the fix does:

- Validates object and layer counts before reading descriptor arrays.
- Validates each plane's `object_index` is in range.
- Rejects frames split across multiple DRM objects with `ENOSYS`, rather than
  silently importing only object zero and producing wrong output.

Why it matters here:

It turns malformed or unsupported DRM PRIME input into a clear FFmpeg error. This
is especially useful when frames come from non-RKMPP producers, compositors, or
test tools that may split planes across dma-bufs.

Submission guidance:

- Send to NyanMisaka.
- Upstream has a simpler encoder with its own DRM handling; a similar validation
  idea could be reviewed separately, but this function is fork-specific.

## 9. RKMPP encoder: async queue, submit-failure, and EOS cleanup

Relevant local commits: `c44cc876db`, `5c0c56e8c8`, `275f06843a`,
`9319172196`, `1c73bd8e65`.

Files/functions affected:

- `libavcodec/rkmppenc.h:MPPEncFrame`
- `libavcodec/rkmppenc.c:get_sent_frame_count()`
- `libavcodec/rkmppenc.c:get_oldest_unsent_frame()`
- `libavcodec/rkmppenc.c:rkmpp_encode_frame()`
- `libavcodec/rkmppenc.c:rkmpp_submit_frame()`

What it fixes:

The fork's encoder supports asynchronous MPP operation and keeps a list of frames
whose buffers must stay alive until MPP returns a packet. The old accounting
mixed "queued in our list" with "actually sent to MPP". That can overfill the
MPP input queue, repeatedly try to send the same frame, or mishandle EOS when the
output side needs to be drained first.

A later review found that `rkmpp_submit_frame()` could fail after reserving a
frame-list entry and creating an MPP frame. Leaving that partially initialized
entry queued lets the async path pick it later, send a bufferless frame to MPP,
or leak the frame because the normal unused-frame cleanup cannot reclaim it.

What the fix does:

- Adds a monotonically increasing `order` and a `sent` flag to each tracked frame.
- Counts only frames actually sent to MPP when enforcing async depth.
- Picks the oldest unsent frame for submission.
- On MPP input backpressure, switches to packet retrieval instead of spinning.
- Queues EOS once and keeps draining until MPP returns EOF.
- Resets async and EOS state on init/close.
- Checks `av_frame_clone()` when the encoder receives DRM PRIME input directly.
- On submit failure, releases any imported `MppBuffer`, deinitializes the
  `MppFrame`, frees pending user-data SEI storage, frees the cloned frame, and
  clears the queued/sent state so the failed entry cannot be sent later.

Why it matters here:

The full transcode path depends on stable decoder -> RGA -> encoder buffering.
Incorrect async ownership causes hangs or dropped frames under load, especially
with H.26x/MJPEG nonblocking output.

Submission guidance:

- Send to NyanMisaka. This is one of the highest-value encoder fixes.
- Not directly upstreamable because upstream's encoder receive loop is much
  simpler and does not use this frame-list model.

## 10. RKMPP encoder: packet pointer, error cleanup, empty packet, and extradata size

Relevant local commits: `c44cc876db`, `275f06843a`, `1c73bd8e65`.

Files/functions affected:

- `libavcodec/rkmppenc.c:rkmpp_get_packet()`
- `libavcodec/rkmppenc.c:rkmpp_encode_init()`

What it fixes:

MPP packets have a base pointer and a current position pointer. Encoded output
should be copied from `mpp_packet_get_pos()`, not necessarily from the original
base pointer. The old code also treated a null packet from `encode_get_packet()`
as `ENOMEM`, even though it represents no packet available in nonblocking mode.
Finally, the H.26x global-header path set `extradata_size` to payload plus FFmpeg
padding bytes.

The async encoder also needs to reclaim the consumed input buffer once MPP
returns the corresponding packet. Before the review cleanup, error exits after a
packet was obtained could skip that reclamation and leave the input buffer pinned
forever.

What the fix does:

- Copies packet bytes from `mpp_packet_get_pos()`.
- Maps `!mpp_pkt` to `AVERROR(EAGAIN)`.
- Sets `avctx->extradata_size` to the actual header length and still allocates
  zeroed FFmpeg padding after it.
- Uses a single packet exit path that, when possible, looks up `KEY_INPUT_FRAME`
  from packet metadata, gets its `MppBuffer`, marks that buffer unused with a
  negative index, and calls `clear_unused_frames()` before deinitializing the
  packet.

Why it matters here:

These fixes prevent subtle bitstream corruption and API contract violations. They
also make nonblocking output behave as FFmpeg callers expect.

The buffer-reclaim path is important under sustained async transcode load: a
single failed packet post-processing step should not permanently reduce the
available RKMPP input-buffer pool.

Submission guidance:

- Send to NyanMisaka.
- Upstream already uses `mpp_packet_get_pos()` in its current encoder, so this is
  not a new upstream fix in the audited branch.

## 11. RKMPP encoder: rate-control and MJPEG configuration guards

Relevant local commits: `c44cc876db`, `021c7102d8`.

Files/functions affected:

- `libavcodec/rkmppenc.c:rkmpp_set_enc_cfg()`
- `libavcodec/rkmppenc.c:rkmpp_get_mpp_fmt_mjpeg()`

What it fixes:

The fork computes bitrate bounds for MPP rate control and derives
`rc:stats_time` from `rc_buffer_size / max_bps`. If `max_bps` is zero or invalid,
that becomes a divide-by-zero risk. The MJPEG path also logs QP min/max I-frame
values even though MJPEG uses JPEG quality-factor fields, not H.26x I-frame QP
fields. Finally, `YUVJ420P` should map to the MJPEG YUV420 input format just like
`YUV420P`.

What the fix does:

- Rejects invalid `max_bps <= 0` before calculating stats time.
- Initializes `qp_max_i` and `qp_min_i` for MJPEG logging consistency.
- Accepts `AV_PIX_FMT_YUVJ420P` in the MJPEG format mapper.

Why it matters here:

These are small hardening changes. They make bad user rate-control inputs fail
cleanly and reduce surprises when testing MJPEG encode paths.

Submission guidance:

- Send to NyanMisaka.
- Only the general divide-by-zero guard is conceptually upstream-relevant; the
  exact code does not match upstream.

## 12. RKMPP hwcontext: cache sync, pool sizing, and map cleanup

Relevant local commits: `5c0c56e8c8`, `383bd2a4f3`, `9319172196`,
`1c73bd8e65`.

Files/functions affected:

- `libavutil/hwcontext_rkmpp.c:rkmpp_frames_get_buffer_flags()`
- `libavutil/hwcontext_rkmpp.c:rkmpp_drm_pool_alloc()`
- `libavutil/hwcontext_rkmpp.c:rkmpp_map_frame()`
- `libavutil/hwcontext_rkmpp.c:rkmpp_unmap_frame()`
- `libavutil/hwcontext_rkmpp.c:rkmpp_map_from()`

What it fixes:

The RKMPP hardware context has cacheability flags at both device and frames
levels. The old map/unmap path checked only the frames-context flags before doing
`DMA_BUF_IOCTL_SYNC`, so cacheable buffers requested through the device context
could miss CPU/device synchronization. The non-linear mapping error path also
leaked the just-allocated mapping object.

The pool allocator also multiplied aligned width, aligned height, and padded
bits-per-pixel in `int` before assigning to `size_t`. Very large dimensions can
overflow the signed intermediate even though the destination type is wide enough.

What the fix does:

- Combines device and frames flags through `rkmpp_frames_get_buffer_flags()`.
- Stores the effective flags in the map descriptor so unmap uses the same sync
  decision as map.
- Frees the mapping descriptor before returning `ENOSYS` for non-linear frames.
- Allows `map_from` callers with `dst->format == AV_PIX_FMT_NONE` by filling in
  the hardware frame context's software format.
- Casts the aligned width to `size_t` before calculating the MPP pool buffer
  size, avoiding signed overflow in the intermediate multiply.

Why it matters here:

CPU mapping is mostly a debug or transfer path, but when it is used it must be
cache coherent. Missing dma-buf sync can produce stale reads or lost writes on
cacheable buffers.

The size calculation hardening keeps bad or extreme frame dimensions from
turning into undefined signed-overflow behavior during pool allocation.

Submission guidance:

- Send to NyanMisaka.
- Not upstreamable directly because upstream has no RKMPP hardware context.

## 13. RKRGA filter output lifetime, metadata, and active-rectangle cleanup

Relevant local commits: `275f06843a`, `383bd2a4f3`, `1c73bd8e65`.

Files/functions affected:

- `libavfilter/rkrga_common.c:submit_frame()`
- `libavfilter/rkrga_common.c:ff_rkrga_filter_frame()`
- `libavfilter/rkrga_common.c:query_frame()`

What it fixes:

The RGA filters copy frame properties from input to output before allocating the
output hardware frame. That also copies crop metadata. If the filter has already
applied the crop/scale into the output frame, leaving old crop fields on the
output describes a second crop to downstream filters or encoders. The old overlay
preprocess path also recomputed active width/height inline and checked RGA2 size
limits against fields before the output rect was set.

The async output path also called `ff_filter_frame()` and then freed the same
frame on error. FFmpeg's filter API consumes the frame even when delivery fails,
so that cleanup is a double-free/use-after-free risk. The input submission path
also assumed `av_frame_clone()` succeeded before reading the cloned DRM
descriptor.

What the fix does:

- Clears all four crop fields on the output frame after copying frame properties.
- Computes `act_w` and `act_h` once, clipping overlay preprocess output to the
  base frame's active dimensions.
- Uses the computed active rectangle for the RGA2 4096x4096 limit check.
- Uses the same active rectangle in `rga_set_rect()` for both normal and pattern
  preprocess output.
- Checks `av_frame_clone()` before dereferencing the submitted DRM PRIME frame.
- Sets the async destination frame pointer to `NULL` immediately after
  `ff_filter_frame()` and decrements the queued count before returning an error,
  because ownership has already transferred to the next filter.

Why it matters here:

This prevents downstream double-cropping and makes overlay/preprocess dimensions
match what is actually submitted to librga. It is directly relevant to the full
hardware transcode and overlay validation path.

The lifetime fix is also important for async RGA stability: delivery failures
should propagate as filter errors, not corrupt the frame queue or free a frame
that is no longer owned by the RKRGA filter.

Submission guidance:

- Send to NyanMisaka.
- Not upstreamable directly because upstream has no RKRGA filters.

## 14. RKMPP build hygiene: private headers and `checkheaders`

Relevant local commit: `1c73bd8e65`.

Files/functions affected:

- `libavcodec/Makefile:SKIPHEADERS-$(CONFIG_RKMPP)`

What it fixes:

The RKMPP decoder and encoder headers include Rockchip MPP headers. They are
private implementation headers, not public standalone FFmpeg headers, so
`make checkheaders` should not require a system without MPP development files to
preprocess them successfully.

What the fix does:

- Adds `rkmppdec.h` and `rkmppenc.h` to `SKIPHEADERS-$(CONFIG_RKMPP)`.

Why it matters here:

This keeps FFmpeg's header self-containment checks useful on generic build hosts
while still allowing RKMPP-enabled builds to compile when the MPP SDK is
available. It is a small fix, but it reduces noise for anyone reviewing or
testing the fork.

Submission guidance:

- Send to NyanMisaka as build hygiene.
- Not useful upstream unless upstream has equivalent private RKMPP headers that
  include external SDK headers.

## Suggested patch split for NyanMisaka

A good backport series would keep review surfaces small:

1. `avdevice/v4l2: fix mplane payload accounting and framerate fallback`
2. `swscale: fix compact NV15/NV20 unpacking tails and descriptor name`
3. `avcodec/rkmppdec: fix MJPEG output sizing, decoder ownership, errinfo, and info-change`
4. `avcodec/rkmppdec: handle EOS backpressure without spinning`
5. `avcodec/rkmppenc: validate DRM descriptors before MPP import`
6. `avcodec/rkmppenc: fix async frame accounting, submit failure unwind, packet buffer release, and EOS drain`
7. `avcodec/rkmppenc: copy packets from MPP position and fix extradata size`
8. `avutil/hwcontext_rkmpp: fix cache-sync flag propagation, pool-size overflow, and map cleanup`
9. `avfilter/rkrga: fix consumed-frame ownership, clear stale crop metadata, and use clipped active rects`
10. `avcodec: skip private RKMPP headers in checkheaders`

The older `origin/nyanmisaka` branch predates current FFmpeg internals, so these
should be backported by behavior rather than blindly cherry-picked.

## Suggested upstream candidates

Only two pieces are plausible upstream submissions without first proposing the
whole fork stack:

1. V4L2 mplane `data_offset` correctness. The upstream patch should be scoped to
   the current upstream V4L2 model and not assume the fork's multi-plane buffer
   arrays unless that support is submitted first.
2. V4L2 `VIDIOC_G_DV_TIMINGS` framerate fallback. This is generic, but it needs
   normal FFmpeg review around overflow, zero timing fields, logging, and whether
   the fallback belongs in `v4l2_set_parameters()` exactly as in the fork.

The packed `NV15`/`NV20_PACKED` work could become upstream material only as a
feature series that adds the pixel formats, imgutils/pixdesc coverage, swscale
support, and tests. If that series is ever proposed, the compact 10-bit 4:2:2
format should use an explicit name such as `nv20_packed` so `nv20` remains
available for FFmpeg's ordinary endian `NV20` formats. The RKMPP/RKRGA fixes
should stay fork-side unless upstream accepts a larger RKMPP hardware-context
and RGA-filter design.
