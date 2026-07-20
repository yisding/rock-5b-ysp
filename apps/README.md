# apps/ — applications on the codec stack

Real applications driven by the RK3588 hardware-video stack.

| Project | Covers | Entry |
|---------|--------|-------|
| [`gnome-remote-desktop/`](gnome-remote-desktop/README.md) | The hardware H.264 RDP backend: design, zero-copy capture path, profiling, testing, the 17-patch investigation series, and the GDM greeter ACL. | [`gnome-remote-desktop/`](gnome-remote-desktop/README.md) |
| [`kodi/`](kodi/README.md) | Hardware video **decode** in Kodi 22 via `ffmpeg-rockchip-81` (RKMPP → DRM PRIME): why stock Kodi needs no patch, the build recipe, and the tty1 test. | [`kodi/`](kodi/README.md) |

Jellyfin is not a project in this repo yet; FFmpeg/Jellyfin-relevant codec notes
live under [`../video-libraries/ffmpeg/`](../video-libraries/ffmpeg/README.md).

State rollup: [`../status.md`](../status.md). Cross-cutting vocabulary:
[`../glossary.md`](../glossary.md).
