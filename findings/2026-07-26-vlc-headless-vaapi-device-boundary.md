# VLC headless playback cannot prove rockchip-vaapi hardware decode

> Date: 2026-07-26. Scope: stock VLC 3.0.23 on the ROCK 5B current login.
>
> Trust: **MEASURED** / **ENVIRONMENT-BOUNDARY**.

> **Partly superseded 2026-07-28 by**
> [the shipping-stack gates finding](2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md).
> The measurement here stands: headless VLC does not load the driver, and this
> run proves nothing about hardware decode. The inference that a display session
> was the *only* missing piece does not. Repeating it in a real GNOME session
> showed VLC still falling back, because `vaDeriveImage` and
> `vaAcquireBufferHandle` were unimplemented in `rockchip-vaapi`. With those
> implemented, unpatched VLC hardware-decodes H.264 and HEVC Main.

VLC is built with libva and ships both `libvaapi_plugin.so` and
`libvaapi_drm_plugin.so`. With `--avcodec-hw=vaapi`, libavcodec enumerates and
tries the VAAPI H.264 output format. Under `--vout dummy`, VLC then reports
`no hw decoder modules matched`, tries VDPAU, and falls back to software
YUV420P. `RK_VAAPI_LOG` is never created, proving the local driver did not
load; the MPP library's startup warnings are not hardware-decode evidence.

The login has no Wayland or X11 socket. VLC's dummy vout does not provide the
decoder-device object required by its VAAPI module, even though the module is
installed and linked correctly. The next valid gate must run in a real
Wayland/X11 or DRM-capable display session and require driver frame/audit
markers. Headless playback exit status alone must not be counted as a pass.

This corrects the older estimate that VLC necessarily needed codec-wrapper
patching. With the renovated VAAPI driver, the immediate work is display-device
integration and measurement; source changes are not yet demonstrated as
necessary.
