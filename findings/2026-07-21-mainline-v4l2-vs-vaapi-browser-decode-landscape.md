# Mainline AV1/V4L2 vs VA-API, and why Firefox's only Rockchip hardware-decode route is VA-API

> Scope: how mainline Linux exposes RK3588 hardware decode (esp. AV1), which
> apps consume it, whether a VA-API path to it exists, and — given Firefox
> "uses ffmpeg" — why Firefox can reach neither the mainline V4L2 decoders nor
> the ffmpeg rkmpp wrapper decoders, leaving VA-API as its only route. Companion
> to the [AV1 bitstream-reconstruction finding](2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md).
> Source: web research against primary sources (Mozilla Bugzilla, FFmpeg
> mailing list + `libavcodec/rkmppdec.c`, kernel linux-media patchwork/LWN,
> Chromium groups) — cited at the end; plus Firefox media-decode architecture
> Date: 2026-07-21 (external state — re-verify before relying)
> Trust: SOURCE-INSPECTED (claims tied to the named primary sources) /
> INFERRED (the architectural conclusions and the per-browser matrix)

## Result

Mainline Linux does **not** expose Rockchip hardware decode through VA-API at
all — the mainline route for these SoCs is the **V4L2 stateless request API**,
consumed by V4L2-native clients (Chromium's own decoder, GStreamer, ffmpeg's
request-API hwaccels). VA-API is the API of GPU-integrated decoders
(Intel/AMD/NVIDIA), not ARM stateless VPUs. Two consequences land on Firefox
specifically, and both point the same way: **Firefox's only viable
hardware-decode path on RK3588 — on either the BSP or a mainline kernel — is
VA-API, i.e. the `rockchip-vaapi` MPP bridge.** It can ride neither the
mainline V4L2 decoders (wrong flavor, no request-API support) nor ffmpeg's
rkmpp wrapper decoders (not a hwaccel; Firefox has no code to select them).

## 1. Mainline's route is V4L2 stateless, not VA-API

- **RK3588 AV1 decoder** — a *dedicated* AV1 IP block, separate from rkvdec2 —
  merged to mainline **Linux v6.5** (2023), Collabora / Benjamin Gaignard, via
  the V4L2 stateless AV1 request-API uAPI; 8/10-bit to 8K, film grain/scaling
  via the post-processor, NV12/P010 output.
- **rkvdec2 (H.264/H.265)** — merged much later, **Linux 7.0** (early 2026),
  Collabora (VDPU381 on RK3588). **VP9 on rkvdec2 and 8K multicore are still
  future work.**
- Interface throughout: **V4L2 stateless request API**. No mainline VA-API
  driver for Rockchip exists or is planned.

## 2. The consumers are direct V4L2 clients — VA-API is absent

- **Chromium** has its own native `V4L2VideoDecoder` (stateless request API,
  no ffmpeg). AV1 works but is **ChromeOS-only upstream**; desktop Linux needs
  out-of-tree patches (Jianfeng Liu's Chromium v123 patches, Apr 2024, still
  reported AV1 artifacts).
- **GStreamer** `v4l2slav1dec` works (1.24+) — the most reliable mainline AV1
  path today.
- **FFmpeg** upstreamed V4L2 **request-API hwaccels** for MPEG-2/H.264/HEVC
  (Kwiboo/Jonas Karlman, 2024); **VP9/AV1 were planned, not yet upstream**.

## 3. A VA-API→V4L2-stateless shim would make AV1 *easy* — but none reaches it

The only way VA-API apps could use the mainline decoder is a VA-API→V4L2-
stateless shim. Two exist, neither reaching AV1 or rkvdec2:

- `bootlin/libva-v4l2-request`: MPEG-2/H.264/HEVC only, Allwinner/Hantro,
  stalled.
- `mxsrc/libva-v4l2`: MPEG-2/H.264/VP8/VP9, RK3399 (hantro/rockchip), **no
  AV1, no rkvdec2/RK3588**.

**Key inversion** (ties to the [AV1-hardness finding](2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md)):
a VA-API→V4L2-stateless AV1 shim would be *far easier* than our VA-API→MPP
bridge, because it is **stateless→stateless** — V4L2's stateless AV1 controls
take the same parsed frame-header parameters VA-API provides, so it is
struct→control mapping with **no OBU reconstruction**. AV1's difficulty is
specific to the stateless-API→*stateful*-decoder (MPP) path; on a stateless
backend it dissolves. But that shim needs the mainline kernel, doesn't exist
for AV1 yet, and the ecosystem is going straight to V4L2 clients, bypassing
VA-API.

## 4. Firefox cannot ride the mainline V4L2 route

- Firefox has **no native V4L2 decoder**; it decodes via FFmpeg (or VA-API).
- The V4L2 path Firefox shipped (Bug 1833354, RESOLVED FIXED, Fx116, ~2023) is
  **stateful V4L2-M2M via ffmpeg `*_v4l2m2m` wrapper decoders** (H.264-mainly,
  Raspberry-Pi-shaped), DRM-PRIME zero-copy.
- Rockchip's mainline decoders are **stateless (request API)**, not M2M
  stateful — the wrong flavor. Firefox has **no v4l2-request support and it is
  not planned** (a contributor on that bug: *"ffmpeg doesn't support
  v4l2-requests codecs as far as I know"*; listed as an open limitation).

## 5. Firefox cannot use the ffmpeg rkmpp wrapper decoders either

"Firefox uses ffmpeg" ≠ "Firefox can use any ffmpeg decoder." ffmpeg has two
hardware mechanisms:

- **hwaccel** (`AVHWAccel`): acceleration bolted onto the *standard* software
  decoder via `get_format` + `hw_device_ctx` (VA-API, VDPAU, NVDEC…).
- **wrapper decoder**: a standalone `AVCodec` selected *by name*
  (`h264_rkmpp`, `h264_v4l2m2m`, `h264_qsv`…). `avcodec_find_decoder(H264)`
  returns software `h264`, never these.

**rkmpp is a wrapper decoder, not a hwaccel** (upstream `libavcodec/rkmppdec.c`
registers `h264_rkmpp` etc., DRM-PRIME output since 2017; the capable version
is the out-of-tree nyanmisaka fork; `-hwaccel rkmpp` is CLI sugar that swaps in
the wrapper decoder, not an `AVHWAccel`).

Firefox's `FFmpegVideoDecoder` knows exactly two hardware routes: the **VA-API
hwaccel** path (built in), and **one hand-written wrapper-decoder path** for
`*_v4l2m2m` (Bug 1833354). Everything else uses `avcodec_find_decoder(id)` —
the default software decoder. It never enumerates or selects arbitrary named
wrapper decoders, so **no Firefox code path would ever pick `h264_rkmpp`**.
Using rkmpp would require a bespoke Firefox integration analogous to the
v4l2m2m one; nobody wrote it. (And if it did, rkmpp opening `/dev/mpp_service`
inside the RDD sandbox hits the same seccomp wall as the VA-API bridge — magic
`'v'` ioctl.)

## 6. Why VA-API is the adapter Firefox needs — the per-browser matrix

There are two ways to get MPP into Firefox: teach Firefox about rkmpp (a
wrapper decoder — per-codec Firefox patches, forever) or **re-present MPP as
VA-API** (a hwaccel Firefox already speaks — zero Firefox changes).
`rockchip-vaapi` is exactly that adapter: it turns wrapper-decoder-world MPP,
which Firefox won't select, into hwaccel-world VA-API, which Firefox uses out
of the box. The community answer to "hardware decode in Firefox on RK3588" is
universally rockchip-vaapi, not rkmpp-in-Firefox.

| Route | Chromium | Firefox |
|-------|----------|---------|
| **VA-API hwaccel** (rockchip-vaapi / MPP, BSP or mainline) | ✅ | ✅ **its only native mechanism on Rockchip** |
| **Mainline V4L2 stateless** | ✅ native `V4L2VideoDecoder` (+Linux patches) | ❌ only stateful M2M; no request-API; not planned |
| **`libv4l-rkmpp` shim** (BSP) | ✅ (needs Chromium patches) | ❌ FFmpeg v4l2m2m does raw ioctls, bypasses libv4l2 |
| **ffmpeg rkmpp wrapper decoders** | n/a (no ffmpeg) | ❌ not a hwaccel; no selection code |

## Consequences for the roadmap

- **Firefox is the app that most needs the VA-API road.** Chromium has options
  (VA-API bridge *or* mainline V4L2); Firefox has only VA-API on Rockchip. This
  independently reinforces the `rockchip-vaapi` fork-and-renovate plan (track
  14): it is the *only* thing that gives Firefox hardware decode at all.
- **AV1-in-Firefox on this board is blocked on the hard MPP-bridge OBU
  reconstruction** — there is no V4L2 shortcut for Firefox the way there
  conceptually is for Chromium. Correctly scoped out of driver v1.
- **The clean AV1 path is mainline/maxline (track 13) + a direct V4L2 client
  (Chromium/GStreamer/ffmpeg)**, or a not-yet-built stateless VA shim — not the
  MPP bridge.

## Caveats

External, moving state as of 2026-07-21: Mozilla *could* add v4l2-request
support (raised, deferred); ffmpeg *will* likely add request-API VP9/AV1; if
both land, Firefox-on-mainline-V4L2 becomes possible. Re-verify before relying.

## Sources

- FFmpeg `libavcodec/rkmppdec.c` (upstream rkmpp wrapper decoders, DRM-PRIME)
  and the 2017 rkmpp patch; `nyanmisaka/ffmpeg-rockchip` (capable fork).
- FFmpeg-devel: V4L2 Request-API hwaccels for MPEG-2/H.264/HEVC (Aug 2024;
  VP9/AV1 planned).
- Mozilla Bug 1833354 (V4L2-M2M via ffmpeg, RESOLVED FIXED Fx116), Bug 1783005
  (meta ffmpeg/V4L video), Bug 1210727 (VA-API meta).
- Kernel: AV1 stateless decoder for RK3588 (LWN 928877; Gaignard/Collabora v7
  series, linux-media); RK3588/RK3576 H.264/H.265 rkvdec2 in mainline (Linux
  7.0; CNX Software / LinuxGizmos, Feb 2026).
- Chromium-dev "V4L2 AV1 decoding on rk3588 linux platform" (Jianfeng Liu);
  `bootlin/libva-v4l2-request`, `mxsrc/libva-v4l2`.
- Armbian forum: rockchip-vaapi is the community HW-decode answer for Firefox
  on RK3588.
