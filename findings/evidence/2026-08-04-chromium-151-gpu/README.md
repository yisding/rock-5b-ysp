# Chromium 151 `chrome://gpu` export

Supports the promoted
[Chromium 151 boundary](../../../video-libraries/vaapi/docs/validation.md#consumer-and-sandbox-conclusions)
and the live
[Google Chrome retained-export diagnosis](../../2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md).

## Contents

| File | Origin | SHA-256 |
|------|--------|----------|
| `about-gpu-2026-08-05T04-07-12-065Z.txt` | User-exported `chrome://gpu` report from installed Chromium 151 on GNOME Wayland; exported 2026-08-05 04:06:54 UTC / 2026-08-04 local | `c9471a8a120ee48b595c4f1774ae82d89860892ba6fb22a4b9dbd4030a122c75` |
| `about-gpu-2026-08-05T04-23-57-006Z.txt` | User-exported `chrome://gpu` report from Google Chrome 151 on the same GNOME Wayland host; exported 2026-08-05 04:22:21 UTC / 2026-08-04 local | `2df477cf3281fd39a846019b2734c76623845c6d37f79ba2439eb5c58b50ce2a` |
| `media-internals-operator-records-2026-08-05.txt` | Operator-transcribed `chrome://media-internals` selections for green-before H.264, 384x240 VP9 software selection, and 640x480 VP9 VA-API selection, plus the correct-after H.264 observation | `c789359fa3da3ecb1ba6c9345bd1ea04c666d39625acb9dde2981da2d715be4d` |
| `gpu-process-sandbox-probe-2026-08-05.txt` | Stock-launch command lines, `chrome://gpu` sandbox result/warning, and a live read-only `/proc` probe of the Google Chrome GPU process | `c02203adf86af183cc3be29eabd8efe5690d56687b2f3696977abf7524fd694e` |

The Chromium report is 38,507 bytes and 876 lines; the Google Chrome report is
38,425 bytes and 879 lines. Both preserve the complete graphics feature status,
command line, ANGLE/Panfrost identity, workarounds, video-acceleration table
and GPU log messages. They contain capability enumeration, not playback
traces. The discriminating result is the profile table: Chromium exposes only
VP8 from Hantro V4L2, while Google Chrome exposes rockchip-vaapi's H.264,
VP9 Profile 0 and HEVC Main rows. The companion operator transcript is not a
complete Media Internals export; it preserves the exact decoder-selection
records supplied during the live browser tests. The sandbox probe is a
point-in-time live-process measurement; its PID is not stable across launches.

## Companion host probes

The finding records the interpreted output. Re-run the device half with:

```bash
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video1 --all
v4l2-ctl -d /dev/video1 --list-formats-out
v4l2-ctl -d /dev/video1 --list-formats-ext
```

Re-run the focused installed-binary discriminator with:

```bash
for pattern in libva.so.2 vaGetDisplayDRM vaInitialize VaapiWrapper \
  VaapiVideoDecoder V4L2StatefulVideoDecoder; do
  printf '%s: ' "$pattern"
  rg -a -o "$pattern" /usr/lib/chromium/chromium | wc -l
done
```

The raw v4l2/binary command output was not separately captured; the device and
package are live-state dependencies and must be re-queried when Chromium or the
kernel changes.
