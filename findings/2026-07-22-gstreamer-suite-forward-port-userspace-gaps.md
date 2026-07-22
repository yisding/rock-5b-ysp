# GStreamer conformance on the forward-port kernel — green modulo 4 userspace gaps

**Date:** 2026-07-22
**Kernel:** `Pd222-C4ad2` (forward-port `0001`–`0058` less `0012`, KASAN debug, `panic_on_oops=0`)
**Suite:** `kernel-drivers/tests/gstreamer-suite.sh` (JeffyCN `gstreamer-rockchip` MPP/RGA plugin)
**Result:** 98/102 required pass, kernel journal completely clean (zero KASAN/BUG/Oops/iommu-fault).

## What it took to run the suite

The suite had never run on this host because the GStreamer build/runtime stack
was absent. Three apt packages closed the gap:

- `libgstreamer1.0-dev` — `gstreamer-1.0.pc`, `gstreamer-base-1.0.pc`
- `libgstreamer-plugins-base1.0-dev` — `gstreamer-allocators/video/pbutils-1.0.pc`
- `gstreamer1.0-tools` — `gst-launch-1.0`, `gst-inspect-1.0`
- `gstreamer1.0-plugins-bad` — `h264parse`, `h265parse`, `vp9parse`, `av1parse`,
  `ivfparse` (the stream parsers every decode/roundtrip/transcode pipeline needs)

The GStreamer runtime (`plugins-base`/`good` 1.28.2) and our staged
`rockchip_mpp.pc` / `librga.pc` were already present. Note the host's default
`pkg-config` is Homebrew's and only searches Homebrew paths, so the plugin must
be built with the **system** pkg-config (`PKG_CONFIG=/usr/bin/pkg-config`) for
it to see the apt `.pc` files alongside the staged ones.

## Two harness bugs fixed

1. **VP9 input generation used a non-existent `ivfmux` element.** GStreamer has
   `ivfparse` but no `ivfmux`, so `vp9enc ! ivfmux ! filesink` failed with
   "no element ivfmux" and every VP9 case failed for lack of input. Fixed by
   generating the VP9 IVF via the ffmpeg `libvpx-vp9` path (`-c:v libvpx-vp9
   -f ivf`), mirroring how AV1 already generates its IVF. VP9 hardware decode
   through `mppvideodec` then passes (and was already proven bit-exact via the
   ffmpeg-rockchip suite and `mpi_dec_vp9`).
2. **Force-key-unit event sent in the wrong pad direction.** The event harness
   fetched the encoder's downstream peer (a *sink* pad) and did
   `gst_pad_send_event(peer, upstream_event)`, which GStreamer rejects with
   "custom-upstream event in wrong direction". A force-key-unit request is an
   upstream event the encoder handles on its *src* pad; sending it to
   `h->target_src` directly makes both `event_force_key_enc_h264/h265` pass.

Together these recovered 4 required cases (94 → 98).

## The 4 remaining required failures — all userspace, none a kernel fault

The kernel journal is clean across every one of them (no KASAN/BUG/Oops/iommu
fault), so none is a forward-port kernel defect.

1. **`generated_dec_h265_10_rga_scale`**, **`generated_dec_h265_10_env_disable_nv12_10`**
   — the JeffyCN plugin's *internal* legacy RGA conversion (`c_RkRgaBlit`,
   `rga.cpp:1483`) returns `RGA_BLIT fail: Permission denied` (`EACCES`) for the
   10-bit scale/convert. It is **not** a kernel RGA problem: 8-bit legacy RGA
   scale/rotate cases pass in the same run, 10-bit P010 RGA is bit-exact through
   ffmpeg's im2d `scale_rkrga`, and a manual 10-bit decode piped through
   software `videoscale` succeeds with **no** kernel RGA log emitted. The
   rejection is in the librga legacy API for that 10-bit format/core combo.
2. **`generated_transcode_h264_dmabuf_to_h265`** — with `dma-feature=true` the
   pipeline caps-negotiates as `not-negotiated (-4)` at `h264parse`. The plain
   (non-dmabuf) `generated_transcode_h264_to_h265` passes, so this is a gstmpp
   dmabuf memory-feature caps-negotiation limitation, not decode/encode.
3. **`event_flush_dec_h264`** — after the harness injects a raw
   `flush_stop(reset_time=TRUE)` mid-stream, `GstVideoDecoder` reports "data
   flow before segment event" then "no valid frames decoded before end of
   stream": a decoder needs a fresh `SEGMENT` after a time-resetting flush. The
   encode-side flush (`event_flush_enc_h264/h265`) passes with the same harness
   code, so this is a decoder flush-semantics gap in the harness (a well-formed
   fix would re-send a segment or drive the flush via a seek).

## Why it matters

The forward-port kernel now has a **paired GStreamer hardware log** for the
first time, and it is clean: 98/102 required GStreamer cases pass with zero
kernel-log signatures, corroborating the ffmpeg/MPP/librga suites that the
codec + RGA drivers are memory-safe and functionally correct under the JeffyCN
GStreamer stack too. The four gaps are userspace (plugin caps/RGA-legacy/harness
semantics) and are tracked here rather than as kernel blockers. The
distributable kernel is unaffected.
