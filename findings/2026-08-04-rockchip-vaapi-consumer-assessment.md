# rockchip-vaapi's durable consumers are Firefox and the standard VA-API framework stacks; Sunshine and OBS are the best unmeasured encode targets

> Scope: identify applications that can consume `rockchip-vaapi` after GNOME
> Remote Desktop's packed-slice-header contract proved incompatible with MPP,
> and choose the next application-level encode gates.
> Source: `rockchip-vaapi main@184d7d4`; this repo
> `main@d5f62d8`; Sunshine
> [`0784774f`](https://github.com/LizardByte/Sunshine/tree/0784774fecb4ffcd7ff1bf1c26bba84af516590e),
> especially `src/platform/linux/vaapi.cpp` and `src/video.cpp`; OBS
> [`88de106c`](https://github.com/obsproject/obs-studio/tree/88de106cff4bcdf2a511e2e3801ffa3de729f6bd),
> especially `plugins/obs-ffmpeg/obs-ffmpeg-vaapi.c`; RustDesk
> [`402ed07b`](https://github.com/rustdesk/rustdesk/tree/402ed07b0ce6b815ed9818d4c9701599e8976e30),
> especially `libs/scrap/src/common/hwcodec.rs`; and NeatVNC
> [`8e0d2260`](https://github.com/any1/neatvnc/tree/8e0d226064d05d8b090747e5876c8e6880798fcb),
> especially `src/enc/h264/ffmpeg-impl.c`.
> Date: 2026-08-04
> Trust: **SOURCE-INSPECTED** (the named upstream application contracts and
> local driver contract) + **MEASURED** (only the previously recorded
> Firefox/VLC/mpv/GStreamer/FFmpeg results) + **INFERRED** (Sunshine, OBS,
> RustDesk and WayVNC compatibility; none was run here)

## Result

The library should remain **decode-first and compatibility-first**. Its value is
not that it exposes every MPP feature. It gives applications and frameworks
that already speak standard VA-API a Rockchip hardware path without teaching
each one the named `*_rkmpp` codecs.

The useful consumer units are therefore:

1. **Firefox**, which consumes VA-API directly and has no usable
   Rockchip-specific libavcodec or stateless-V4L2 fallback on this stack;
2. **GStreamer's standard `va` plugin**, which serves ordinary pipelines,
   WebRTC and downstream GStreamer applications;
3. **libavcodec's generic VA-API codecs**, which serve the FFmpeg CLI, VLC,
   mpv and application integrations including Sunshine and OBS; and
4. **direct VA-API applications**, each of which must be checked against the
   exact driver contract. GRD belongs here, but its packed-slice-header
   requirement makes it an incompatible member rather than a roadmap target.

This changes the priority question from “what replaces GRD?” to “which standard
VA-API consumer gives the strongest application proof?”

| Priority | Consumer | Assessment |
|----------|----------|------------|
| 1 | Firefox decode | Strategic existing consumer; finish the sandbox-enabled installed-package gate |
| 2 | GStreamer `va` | Highest-leverage measured framework consumer; decode, encode and WebRTC already work |
| 3 | libavcodec VA-API | Measured through FFmpeg, VLC and mpv; also the route to the best new encode apps |
| 4 | Sunshine | Best unmeasured H.264 SDR encode target |
| 5 | OBS Studio | Strong predicted fit; the previous YSP `h264_rkmpp`-whitelist estimate is obsolete |
| 6 | RustDesk | Plausible system-memory remote-desktop encode target, with packaging/runtime uncertainty |
| Browser gate | Chromium/Google Chrome/Electron | XtraDeb Chromium 151 omits libva and exposes Hantro VP8; Google Chrome 151 reaches this driver, and its retained-export green-frame bug is fixed and worker-gated in local ysp13 source. Visual replay, package/install and sandbox remain |
| Decline today | WayVNC/NeatVNC | Requires both H.264 Constrained Baseline and VA video processing, neither advertised |
| Prefer RKMPP | Jellyfin, Kodi, HandBrake | Existing direct-RKMPP paths are more capable or cheaper on this board |

## Existing proof already establishes three consumer classes

Installed-package evidence already covers Firefox's direct VA-API decode path,
the stock libavcodec VA-API path through VLC/mpv/FFmpeg, and GStreamer's `va`
decode and encode elements. The GStreamer H.264 encode result reached a real
WebRTC-shaped path through SDP, ICE, DTLS, SRTP and peer decode. Those are
framework-level results: downstream clients do not each require a bespoke
Rockchip codec integration.

Firefox remains the clearest strategic justification for decode. It cannot use
the named `h264_rkmpp`/`hevc_rkmpp` decoders as a hardware-device backend, and
its Linux V4L2 support does not provide a route to the mainline stateless
request API. On this BSP-style kernel, VA-API is its native Rockchip path.

## Sunshine is the first new encode gate

Sunshine's pinned Linux VA-API implementation:

- selects FFmpeg's `h264_vaapi` and `hevc_vaapi` encoders;
- accepts `VAEntrypointEncSlice` when low-power `EncSliceLP` is absent;
- queries rate-control and maximum-slice attributes, with CBR, VBR and CQP
  paths represented; and
- allocates VA surfaces, exports them with
  `VA_EXPORT_SURFACE_WRITE_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS`, and
  imports those layers into EGL for rendering.

That last property avoids the driver's unresolved nonlinear-import boundary.
Sunshine renders into driver-created surfaces instead of handing the driver an
unknown compositor modifier. `rockchip-vaapi` exports a linear NV12 surface as
separate R8 and GR88 layers, which matches this integration shape.

The first gate should be H.264 High, NV12, SDR, CBR and 1080p60. It must verify
GPU-write-to-MPP-read synchronization, forced IDR on initial connection and
reconnect, live bitrate changes, hardware markers, client decode and a soak.
HEVC Main SDR can follow. HEVC Main10/HDR is out: the RK3588 MPP encoder cannot
accept P010 through this backend.

## OBS no longer needs the proposed RKMPP whitelist patch

The older application map assumed OBS would need a small patch to register
`h264_rkmpp`. The pinned OBS source now contains native FFmpeg VA-API H.264 and
HEVC encoders, including texture variants. The path creates an
`AV_HWDEVICE_TYPE_VAAPI` device, defaults H.264 to High, defaults B-frames to
zero, and exports its encode target with the same write-only, separate-layer
VA call as Sunshine.

That aligns with the driver's H.264 High, no-B-frame, linear-NV12 contract and
its R8/GR88 export. It is still a prediction: no OBS package was installed and
no recording or streaming session was run. Qualify the texture path, CBR,
forced keyframes, reconnect, live bitrate changes and client/service interop
after Sunshine, or in parallel if OBS becomes the product goal.

## RustDesk is plausible but less bounded

RustDesk's Linux hardware-codec layer discovers RAM encoders through its
`hwcodec` integration and explicitly recognizes VA-API codec names when
deciding whether live quality changes are supported. This is compatible in
shape with the driver's checked software-frame NV12/I420 upload path, and it
keeps a remote-desktop use case without GRD's native packed-header contract.

The uncertainty is higher than for Sunshine or OBS: RustDesk's bundled
FFmpeg/hwcodec build, arm64 packaging, driver discovery and actual selected
codec have not been established on this image. Treat it as a runtime probe,
not a promised consumer.

## WayVNC is blocked twice

WayVNC's hardware H.264 path is implemented by NeatVNC. The pinned source finds
`h264_vaapi`, but it also:

- hard-codes profile value 578, H.264 Constrained Baseline; and
- constructs `hwmap=...derive_device=vaapi,scale_vaapi=format=nv12...`.

`rockchip-vaapi` exposes H.264 Main/High encode, not Constrained Baseline, and
does not advertise `VAEntrypointVideoProc`, so `scale_vaapi` has no driver
backend. Either blocker is sufficient. WayVNC should not motivate profile or
VPP implementation until its application contract changes or a concrete
deployment makes that work worthwhile.

## Non-priorities

- **GNOME Remote Desktop:** permanently incompatible through its native
  VA-API backend while it requires application-authored packed slice headers.
  Its FFmpeg `h264_rkmpp` path remains the appropriate MPP integration.
- **Chromium/Electron:** Chromium 151 closes the former Panfrost/ANGLE startup
  failure. The XtraDeb arm64 binary enumerates Hantro V4L2 VP8 and omits libva,
  but Google Chrome 151 already enumerates this driver's H.264/VP9/HEVC
  profiles and selected `VaapiVideoDecoder`. Its green Vimeo frame was a
  retained pre-decode export bug, now fixed and hardware-gated in local ysp13
  source. Replay/package/sandbox that path first; a mixed
  `use_vaapi=true use_v4l2_codec=true` XtraDeb build remains distribution
  parity. See the [package finding](2026-08-04-chromium-151-gpu-working-v4l2-only.md)
  and [Google Chrome follow-up](2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md).
- **Jellyfin/Kodi:** the direct RKMPP/DRM PRIME stack is already the native path
  and supports operations this driver does not, notably Rockchip RGA video
  processing and broader 10-bit/HDR workflows.
- **HandBrake:** its bundled FFmpeg and explicit encoder registry make direct
  RKMPP integration more natural than using this driver as an extra bridge.

## Boundary and decision

No new application was installed or run for this finding. Sunshine and OBS are
strong **source-contract matches**, not measured successes. RustDesk is a
lower-confidence candidate. WayVNC is a source-confirmed mismatch against the
current advertised profile/entrypoint set.

Do not add partial packed headers, generic VA video processing or nonlinear
imports speculatively. Sunshine and OBS can exercise the existing exported
driver-owned surface path first. Add a driver capability only when a named
consumer and a failing runtime gate identify it as the next boundary.
