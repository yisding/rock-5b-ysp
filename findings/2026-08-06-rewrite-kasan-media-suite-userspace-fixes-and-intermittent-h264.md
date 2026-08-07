# Rewrite KASAN media rerun fixes two GStreamer userspace gaps but exposes intermittent H.26x decode output

> Scope: `kernel-drivers/tests` conformance, JeffyCN GStreamer Rockchip, FFmpeg RKMPP, and rockchip-mpp userspace
> Source: kernel `67f323aebdf39`; JeffyCN `dcbcd6454ef892e385b3a782600369eb6c0719db`; FFmpeg `463f542c32`; MPP `a8b19653`
> Date: 2026-08-06
> Trust: MEASURED, SOURCE-INSPECTED, ROOT-CAUSED, FIX-RUNTIME-VERIFIED, PARTIAL

## Result

The `rewrite-kasan` run rooted at
`../rock-5b/build/rockchip-conformance/logs/rewrite-kasan/20260806-203117-*`
failed two required GStreamer cases and one required FFmpeg correctness case.
The bounded kernel logs were clean and all forbidden MPP/RGA debugfs counter
deltas were zero.  The two GStreamer failures were deterministic userspace
defects and are fixed; the FFmpeg failure is real but did not reproduce under
the focused differential runs, so it remains open and the bit-exact gate stays
required.

### GStreamer fixes

`generated_transcode_h264_dmabuf_to_h265` failed negotiation before preroll.
The decoder advertised `video/x-raw(memory:DMABuf)`, but the JeffyCN H.264 and
H.265 encoder sink templates advertised only plain `video/x-raw`.  Their shared
`gst_mpp_enc_convert()` path already imports a single DMABuf-backed memory, and
the JPEG encoder already advertises the corresponding feature.  The maintained
JeffyCN patch now adds symmetric DMABuf caps to both H.26x encoders.

`event_flush_dec_h264` sent a time-resetting target-pad flush and then resumed
mid-GOP buffers without a new segment or reference point.  The harness now
replays the active sticky segment after `FLUSH_STOP(TRUE)`, while decoder flush
cases use the existing flush-plus-keyframe-seek action.  Encoder flush cases
remain direct flushes because their raw input has no compressed reference
chain.

The integrated rebuilt prefix passed these six required controls:

| Case | Result |
|------|--------|
| `generated_transcode_h264_dmabuf_to_h265` | pass |
| `generated_transcode_h265_dmabuf_to_h264` | pass |
| `event_flush_dec_h264` | pass |
| `event_flush_dec_h265` | pass |
| `event_flush_enc_h264` | pass |
| `event_flush_enc_h265` | pass |

The summary is
`../rock-5b/build/mpp-h264-presentation-regression/gstreamer-integrated-fixed/summary.tsv`;
the bidirectional DMA-BUF summary is
`../rock-5b/build/mpp-h264-presentation-regression/gstreamer-dmabuf-bidirectional/summary.tsv`.
A subsequent complete rebuilt-prefix run passed all 103 required cases.  Its
ten failures were the already-diagnostic unsupported VP8/JPEG encoder cases;
the suite exited zero.  That summary is
`../rock-5b/build/mpp-h264-presentation-regression/gstreamer-full-fixed/summary.tsv`.

### FFmpeg differential

The original installed-runtime H.264 decode produced all 60 frames but only
`PSNR average:7.777343`; frame 1 was exact and frames 2-60 were grossly wrong.
The same installed FFmpeg and MPP runtime then passed the identical focused
suite case with `PSNR average:inf`.  A 30-run per-frame hash loop also produced
30 exact matches against the software reference.

A second complete FFmpeg suite replay did reproduce the defect, but this time
H.264 was bit-exact and the required HEVC decode was corrupt after its first
exact frame (`PSNR average:29.940386`).  HEVC had passed in the original full
run.  The failure therefore follows the shared RKMPP decode/presentation path,
not H.264 alone, and full-suite execution is a materially stronger provocation
than an isolated immediate repeat.  The replay is
`../rock-5b/build/mpp-h264-presentation-regression/ffmpeg-full-repeat/`.

Source-built MPP comparisons did not identify a deterministic revision
regression:

| MPP runtime | Build | Result |
|-------------|-------|--------|
| `ad325345` | `RelWithDebInfo` | one mismatching frame, average PSNR `64.754924` |
| `a8b19653` | `RelWithDebInfo` | bit-exact, average PSNR `inf` |
| `a8b19653` | `Release` | bit-exact, average PSNR `inf` |
| installed `a8b19653` | package runtime repeat | bit-exact, average PSNR `inf` |

Those summaries live under
`../rock-5b/build/mpp-h264-presentation-regression/{ad325345-ffmpeg,a8b19653-ffmpeg,a8b19653-release-ffmpeg,system-repeat-1}/`.
The non-monotonic rawvideo DTS warnings occur in both corrupt and bit-exact
runs, so they do not discriminate the corruption.

## Boundary

The GStreamer full suite proves the userspace fixes on this boot and pinned
plugin revision.  That replay was not run with privileged kernel-log access,
so its `dmesg-scan.tsv` is `unavailable`; the clean bounded KASAN log and
forbidden-counter evidence comes from the original failing suite window.

The FFmpeg evidence falsifies `a8b19653` as a deterministic H.264-only cause but
does not explain the corrupt H.264/HEVC presentations.  A useful next
reproduction must preserve the full-suite order and capture per-frame hashes
plus MPP frame/slot diagnostics on the first mismatch.  Do not demote either
bit-exact H.26x decode case or treat a clean immediate repeat as a fix.
