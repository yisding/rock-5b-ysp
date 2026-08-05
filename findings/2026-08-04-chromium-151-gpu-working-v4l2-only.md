# Chromium 151 closes the ANGLE startup blocker but the installed arm64 package exposes only Hantro V4L2 VP8, not rockchip-vaapi

> Scope: supersede the Chromium 150 GPU-process boundary, identify the hardware
> decoder behind Chromium 151's `chrome://gpu` capability table, and bound the
> work required to make `rockchip-vaapi` reachable.
> Source: user-exported Chromium GPU report
> [`evidence/2026-08-04-chromium-151-gpu/`](evidence/2026-08-04-chromium-151-gpu/README.md),
> SHA-256 `c9471a8a120ee48b595c4f1774ae82d89860892ba6fb22a4b9dbd4030a122c75`;
> installed `chromium 151.0.7922.71-1xtradeb1.2604.1`; installed binary
> `/usr/lib/chromium/chromium`; booted `6.18.42-ysp-rockchip64`;
> `/dev/video1` queried with `v4l2-ctl`; Chromium mixed VA-API/V4L2 change
> [`c825d027`](https://chromium.googlesource.com/chromium/src/media/+/c825d027f6ddb95a17c61750cc02b9b75e472f06)
> and current
> [`media_switches`](https://chromium.googlesource.com/chromium/src/+/HEAD/media/base/media_switches.cc).
> Date: 2026-08-04 local / 2026-08-05 UTC export timestamp
> Trust: **MEASURED** (`chrome://gpu`, package, device and binary inspection) +
> **CONFIG-INSPECTED** (launcher flags and udev node alias) +
> **SOURCE-INSPECTED** (current Chromium mixed-backend selection) +
> **INFERRED** (the exact unpublished XtraDeb GN argument set; its observable
> binary/capability shape is consistent with V4L2 enabled and VA-API omitted)

## Result

The old Chromium blocker is closed. Chromium 151 starts a healthy out-of-process
GPU process on GNOME Wayland and Mali-G610/Panfrost through ANGLE OpenGL:

**Package-specific follow-up:** This finding remains correct for the installed
XtraDeb Chromium binary. Google Chrome 151 is built differently, loads
`rockchip-vaapi`, and exposed a later retained-pre-decode-export bug; see the
[Google Chrome stable-export finding](2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md).

| Signal | Exported result |
|--------|-----------------|
| Compositing / rasterization / OpenGL / WebGL / WebGPU | Hardware accelerated |
| Ozone | Wayland |
| GL implementation | `gl=egl-angle,angle=opengl` |
| Renderer | `ANGLE (Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 Mesa 26.0.3-1ubuntu1)` |
| GPU process crash count | 0 |
| Video decode headline | Hardware accelerated |
| Advertised decode table | **VP8 only**, 48x48 through 3840x2160 |
| GPU sandbox | **false** |

Chromium 150's earlier `Could not create a backing OpenGL context` result is a
historical result for that build, not the current boundary. The lone exported
`eglCreateContext: Requested version is not supported` log is nonfatal: the
same report already records an active ANGLE/Panfrost context and zero GPU
crashes.

The new blocker is the **Chromium package build**, before any
`rockchip-vaapi` runtime or sandbox question. The installed arm64 binary exposes
the kernel V4L2 decoder, not libva.

## The VP8 profile is `/dev/video1`, not rockchip-vaapi

The host has a real stateless V4L2 decoder:

```text
/dev/video1
  driver: hantro-vpu
  card: rockchip,rk3328-vpu-dec
  output/compressed formats: MG2S (MPEG-2 Parsed Slice Data), VP8F (VP8 Frame)
  capture format: NV12
```

Udev aliases that node as `/dev/video-dec1`, and Chromium launches with
`--enable-features=AcceleratedVideoDecoder`. Chromium does not expose MPEG-2 as
a normal web-video decode profile, leaving exactly the observed VP8 row. The
48x48 minimum in `chrome://gpu` also matches the V4L2 device's current 48x48
format.

`rockchip-vaapi` cannot be the source of that row: it advertises H.264,
HEVC and VP9 decode, with experimental HEVC Main10 and VP9 Profile 2, and does
not advertise VP8.

This corrects the maintained statement that the current BSP-shaped kernel has
no kernel V4L2 codec device. It has a limited Hantro MPEG-2/VP8 decoder and a
separate VEPU121 encoder; the main RK3588 H.264/HEVC/VP9 decode path still lives
behind `/dev/mpp_service` on this stack.

## The installed Chromium binary does not carry the VA-API implementation

Focused binary inspection produced:

```text
libva.so.2:                 0
vaGetDisplayDRM:            0
vaInitialize:               0
VaapiWrapper:               0
VaapiVideoDecoder:          1
V4L2StatefulVideoDecoder:   2
```

The isolated `VaapiVideoDecoder` text is not sufficient evidence that the
implementation is linked; Chromium uses backend names in common logging and
selection code. The absence of the libva stub/library names and core entrypoints,
together with the V4L2-only capability table, is consistent with an arm64 build
using `use_v4l2_codec=true` and `use_vaapi=false`. The exact XtraDeb build
arguments were not recovered, so that last assignment remains inferred rather
than package-source proof.

No runtime flag can load `rockchip-vaapi` when the libva implementation is not
in the binary.

## Chromium 151 can now carry both backends

Upstream changed this boundary on 2026-07-13. Commit `c825d027` removed the
old GN/preprocessor/sandbox assumption that VA-API and V4L2 were mutually
exclusive and introduced runtime selection. In a mixed build:

- `use_vaapi=true use_v4l2_codec=true` compiles both;
- VA-API is the default backend; and
- `--enable-features=PreferV4L2VideoAcceleration` selects V4L2.

The next package does not need to sacrifice the already-advertised Hantro VP8
path. Build Chromium 151 with both backends plus the existing proprietary-codec
settings:

```text
use_vaapi=true
use_v4l2_codec=true
proprietary_codecs=true
ffmpeg_branding="Chrome"
```

The first Rockchip VA-API probe will likely also need
`VaapiIgnoreDriverChecks`, whose upstream purpose is to bypass the non-Intel
VA-driver blacklist for manual qualification. Do not enable
`PreferV4L2VideoAcceleration` during that gate.

## Next gate

1. Recover or rebuild the XtraDeb source package with both GN backends and
   verify the produced binary contains the libva stubs/entrypoints.
2. Launch on the already-green Wayland/ANGLE path with
   `LIBVA_DRIVER_NAME=rockchip`, `AcceleratedVideoDecoder`, and
   `VaapiIgnoreDriverChecks`; keep `PreferV4L2VideoAcceleration` disabled.
3. Require `chrome://gpu` to enumerate the driver's default H.264, HEVC Main
   and VP9 Profile 0 profiles instead of the V4L2-only VP8 row.
4. Play pinned H.264/HEVC/VP9 files and require `GpuVideoDecoder` in
   `chrome://media-internals`, driver frame/export markers, MPP activity,
   correct presentation, and no software fallback.
5. Flip `PreferV4L2VideoAcceleration` and require the existing VP8 capability
   to remain available as the mixed-build A/B control.
6. Only after the unsandboxed functional path works, enable the GPU sandbox
   and measure the broker/seccomp policy needed for `/dev/mpp_service`,
   `/dev/rga`, DMA heaps and their ioctl families.

## Boundary

- **No video was played for this finding.** `chrome://gpu` proves capability
  enumeration, not that a VP8 frame reached Hantro or that any content used
  `GpuVideoDecoder`.
- **No Chromium VA-API code ran.** The finding identifies why it could not run
  in the installed package; it is not an application result for
  `rockchip-vaapi`.
- **The GPU sandbox is disabled.** That removes it as the immediate reason for
  the current V4L2-only table but leaves a production security/integration
  gate after the mixed package is functional.
- **Encode remains software-only in the export.** The host's `/dev/video2`
  VEPU121 presence is not evidence that Chromium can or did use it.
