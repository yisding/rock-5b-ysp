# rockchip-vaapi HEVC VA encode requires the native RK3588 CTU64 contract

> Scope: experimental HEVC Main `VAEntrypointEncSlice` in `rockchip-vaapi`,
> backed by RKMPP/RKVENC2 on the ROCK 5B.
>
> Source: `../rockchip-vaapi` commit `b579bad`; gates
> `make check-hevc-encode-experimental`,
> `make check-hevc-encode-experimental-sanitize`,
> `make check-driver-objects-sanitize`, and
> `make check-encode-decode-concurrent`.
>
> Date: 2026-07-26.
>
> Trust: **MEASURED** / **CODE-INSPECTED** / **ROOT-CAUSED** /
> **ASAN-UBSAN-CLEAN** / **HARDWARE-INTEROPERABILITY-VERIFIED**.

## Result

`rockchip-vaapi@b579bad` adds an opt-in HEVC Main VA encoder without changing
the shipping capability set. `RK_VAAPI_EXPERIMENTAL_ENCODE=hevc` exposes one
NV12 `VAEntrypointEncSlice`; `h264,hevc` enables both experimental codecs.
The driver snapshots HEVC sequence, picture, and one full-frame CTU slice,
maps the supported rate-control and codec state to MPP, and returns each MPP
packet as an Annex B `VACodedBufferSegment` with VPS/SPS/PPS on IDR frames.

Stock FFmpeg 8 `hevc_vaapi` encoded all 48 deterministic 320x240 frames as
parser-clean, software-decodable Main-profile HEVC in every exposed mode:

| Mode | Average PSNR | Output bytes |
|------|--------------|--------------|
| CQP | 45.191850 dB | 102758 |
| CBR | 44.463005 dB | 138213 |
| VBR | 40.914833 dB | 92821 |

Each stream had exactly 48 frames, exceeded the 35 dB quality floor, decoded
to the exact expected byte count with FFmpeg's standard HEVC decoder, emitted
one audited MPP packet per input frame, and produced no HEVC parser warnings.
After a fresh GStreamer 1.28 vendor-enabled VA scan, `vah265enc` registered
with NV12-only sink caps and produced 48 Main-profile frames at 45.310424 dB.

Normal and full-driver ASan/UBSan app gates pass for all four paths. The
sanitizer object gate also covers hidden-by-default capability behavior,
HEVC-only entrypoint exposure, block-size attributes, and encoder context
creation/destruction.

## CTU contract root cause

The first FFmpeg probe exposed a capability/MPP mismatch. Without usable
`VAConfigAttribEncHEVCFeatures` and `VAConfigAttribEncHEVCBlockSizes`, FFmpeg
guessed 32x32 CTUs while RK3588 MPP encoded with its native 64x64 LCU. The
result decoded but the standard parser reported `cu_qp_delta -72 outside the
valid range`, so it was not an interoperable success.

The driver now advertises the native contract instead of allowing a guess:

- minimum and maximum coding-tree block: 64x64;
- minimum luma coding block: 8x8;
- transform blocks: 4x4 through 32x32;
- optional HEVC feature bits remain unadvertised.

FFmpeg then submits 20 CTUs for 320x240, matching MPP. The gate requires every
FFmpeg mode and GStreamer to select `va_ctu=64` in addition to rejecting parser
warnings, so this regression now fails directly rather than relying only on
quality output.

## Kernel and librga interpretation

This confirms the booted 6.18.40 forward-port can sustain independent H.264
and HEVC RKVENC2 contexts while the shipping H.264/VP9 decode matrix runs. The
96-frame three-way overlap gate completed both encoders and all decode cases,
and the default shipping conformance gate remained green. It adds application-
level evidence for the already-validated RKVENC2 hardening.

It is not additional proof of the P010 librga fix: this encoder path is NV12
and does not invoke the 10-bit RGA conversion path. P010/Main10 correctness is
covered separately by the Main10 AFBC/P010 finding, where the fixed kernel and
librga pair are byte-exact.

## Boundary

The encoder remains experimental and hidden by default. It accepts progressive
NV12, HEVC Main 8-bit 4:2:0, CQP/CBR/VBR, MPP-generated headers, and one
full-frame slice. It rejects tiles, scaling lists, weighted prediction,
B-frames, PCM, and multi-slice input. P010 encode, RGA input conversion,
application-packed headers, WebRTC/browser integration, and long-duration
encode soak remain open.
