# rockchip-vaapi H.264 reaches the WebRTC-compatible RTP boundary

> Scope: direct-I420 `vah264enc` output through GStreamer H.264 RTP
> payload/depay on the ROCK 5B.
>
> Source: `../rockchip-vaapi` commit `d30f81f`; gates
> `make check-webrtc-rtp-experimental` and
> `make check-webrtc-rtp-experimental-sanitize`.
>
> Date: 2026-07-26.
>
> Trust: **MEASURED** / **ASAN-UBSAN-CLEAN** /
> **HARDWARE-INTEROPERABILITY-VERIFIED** / **PARTIAL-WEBRTC**.

## Result

A 120-frame 640x360 I420 stream now passes through the experimental H.264 VA
encoder, `h264parse`, `rtph264pay`, `application/x-rtp`, `rtph264depay`, and a
standard software H.264 decoder. The payloader uses WebRTC's 90 kHz H.264 RTP
caps, payload type 96, zero-latency aggregation, repeated SPS/PPS on IDR, and a
strict 1,200-byte MTU.

The measured run produced 604 RTP buffers; the largest was exactly 1,200
bytes. Depayloading reconstructed all 120 High-profile frames without parser
or decoder errors at 41.061795 dB average PSNR. Driver audits recorded one MPP
packet per encoded frame and at least one checked I420-to-NV12 upload per
frame. Normal and full-driver ASan/UBSan runs produced identical results.

## Boundary

This proves the hardware encoder's output can cross the media boundary a
WebRTC sender consumes: H.264 access units, parameter-set insertion, RTP caps,
fragmentation/MTU, depayload, and interoperable decode. It is not a full
WebRTC peer test. The installed GStreamer 1.28 image has `webrtcbin`, but lacks
`webrtcsink`/`webrtcsrc` and the `GstWebRTC` introspection typelib needed for
the available in-process signaling approach. SDP offer/answer, ICE, DTLS,
SRTP, congestion feedback, browser interop, and keyframe requests remain open.
