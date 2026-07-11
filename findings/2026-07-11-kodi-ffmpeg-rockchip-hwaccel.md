# Kodi 22 hardware video on RK3588 via ffmpeg-rockchip-81: MPP runtime, three fork-packaging bugs, and zero-patch decoder selection

> Scope: Kodi (`~/Code/media/xbmc` @ `22.0b1-Piers-96-g5bc2478806`) + the
> `ffmpeg-rockchip-81` fork (`~/Code/ffmpeg/ffmpeg-rockchip-81` branch
> `refactor/section-c` @ `75638e7f0b`) + `ppa:yi-ding/ubuntu-rock-5b`.
> Source: measured on the ROCK 5B builder (Armbian 26.04 resolute, arm64,
> vendor 6.1 kernel, 8 cores / 15 GiB).
> Date: 2026-07-11
> Trust: MEASURED (except the AV1-container item and the not-yet-run Kodi build/playback)

## Goal

Build Kodi so it hardware-decodes on the RK3588 through **our**
`ffmpeg-rockchip-81` forward-port (RKMPP decoders → `AV_PIX_FMT_DRM_PRIME` →
Kodi's DRM PRIME renderer), then ship it via the PPA. Decision (owner):
package **plain Kodi depending on the PPA fork ffmpeg (`libavcodec63`) as the
system ffmpeg**, and validate real playback by stopping `gdm` and running
`kodi-gbm` on tty1.

## The facts

### 1. Kodi needs NO decoder-selection patch — the fork already advertises the hw_config

This was the central design question. Upstream Kodi's
`CDVDVideoCodecDRMPRIME::FindDecoder()`
(`xbmc/cores/VideoPlayer/DVDCodecs/Video/DVDVideoCodecDRMPRIME.cpp`) selects a
decoder in two ways: (a) iterate all decoders for `hints.codec` and take the
first one whose `FindHWConfig()` returns a config, else (b) fall back to the
default software decoder. It does **not** look up `*_rkmpp` by name.

That is fine, because the fork's rkmpp decoders declare an `AVCodecHWConfig`
(`libavcodec/rkmppdec.h`, `rkmpp_dec_hw_configs`):

```c
.pix_fmt     = AV_PIX_FMT_DRM_PRIME,
.methods     = AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX | AV_CODEC_HW_CONFIG_METHOD_INTERNAL,
.device_type = AV_HWDEVICE_TYPE_RKMPP,
```

Kodi's `FindHWConfig()` accepts exactly this — `pix_fmt == DRM_PRIME` (when the
"prime for hw" setting is on) and method `INTERNAL` or `HW_DEVICE_CTX`. So
`FindDecoder()` auto-selects `h264_rkmpp` / `hevc_rkmpp` / `av1_rkmpp`, and
`Open()` then creates the `AV_HWDEVICE_TYPE_RKMPP` device (the fork implements
`libavutil/hwcontext_rkmpp.c`; the type is registered in `hwcontext.c`).

Consequence: **stock Kodi 22 + external ffmpeg-rockchip-81 + the two settings
below = hardware decode.** No `DVDVideoCodecDRMPRIME` patch. This matches how
community builds (LibreELEC, armsurvivors/kodi-rockchip-deb) run unpatched
master. The required runtime settings:

- `videoplayer.useprimedecoder` — "Allow using DRM PRIME decoder"
- `videoplayer.useprimedecoderforhw` — "Allow HW acceleration with DRM PRIME"

Both are hidden until `CDVDVideoCodecDRMPRIME::Register()` finds libdrm support;
they must be enabled for the auto-selection to fire.

Version gate: Kodi 22's `cmake/modules/FindFFMPEG.cmake` requires
libavutil ≥ 59.8.100, libavcodec ≥ 61.3.100 (and matching format/filter/scale/
resample minimums). The fork is **libavcodec 63.2 / libavutil 61.3** (FFmpeg
8.1 line) — it clears the gate. Build with `-DENABLE_INTERNAL_FFMPEG=OFF`.

### 2. MPP runtime was the real decode blocker — wrong MPP fork installed

On this board `h264_rkmpp` decode failed (both the fork ffmpeg and the system
`/usr/bin/ffmpeg`) with:

```
mpp_dec: mpp_parser_init parser h264 is not registered
mpp: error found on mpp initialization
```

Root cause: the **installed** `librockchip-mpp1 1.5.0-1+rk1` is HermanChen
commit `750e76e` (2026-01-21 develop), which does not register the software
parsers. The PPA's `librockchip-mpp1
1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1` is commit **`1375813c` = tag
1.0.12**, which does. Built `1375813c` locally (`-DBUILD_TEST=OFF` — the test
tree hits a GCC 15 `enum/int` error, harmless warning in the core lib) and the
fork decode passed. Installing the PPA MPP fixed it board-wide:

- `h264_rkmpp`: 90 frames, exit 0, ~16× realtime
- `hevc_rkmpp`: 90 frames, exit 0

So the fix is simply: **use the PPA MPP (`1375813c`), not the board's stock
`750e76e`.**

### 3. AV1 hardware decode works from in-band streams, not from mp4/mkv (fork bug)

`av1_rkmpp` decodes an **IVF** AV1 stream (60 frames, ~7.7×) but fails on the
same stream muxed in **mp4 or mkv**:

```
av1d_codec: read_uncompressed_header No sequence header available.
```

The fork's `av1_rkmpp` does not forward the container's out-of-band sequence
header (mp4 `av1C` / mkv `CodecPrivate`) to MPP. Note the decoder table
(`DEFINE_RKMPP_DECODER`) gives h264/hevc an `mp4toannexb` bsf but av1 gets
`NULL`. h264/hevc — the bulk of real content — are unaffected. **Follow-up:**
teach `av1_rkmpp` to feed extradata (an av1 bsf, or send the `av1C` OBUs), then
re-test in Kodi. Tracked on the status watchlist.

### 4. Three real fork-packaging bugs blocked the PPA `ffmpeg` build (all fixed)

The PPA `ffmpeg` source *is* `ffmpeg-rockchip-81` with the full Debian surface
(`libavcodec63` … + `-dev`). Its arm64 build had been failing. Each Launchpad
attempt exposed one bug; all three are now fixed in
[`packaging/ppa/ffmpeg/`](../packaging/ppa/ffmpeg/README.md):

| Rev | Bug | Failing stage | Fix |
|-----|-----|---------------|-----|
| `~rk4` | rkmpp decoders set a static `pix_fmts` array while also flagging `AV_CODEC_CAP_HARDWARE`; `libavcodec/tests/avcodec.c:225` forbids a video decoder setting `pix_fmts` | FATE `libavcodec-avcodec` | quilt patch `0001-rkmppdec-do-not-advertise-decoder-pix_fmts.patch` — drop the array (it is metadata only; output format is negotiated at runtime via `ff_get_format`, and upstream's own rkmpp decoder sets nothing) |
| `~rk4` | `debian/ffmpeg.install` installs `RELEASE_NOTES`, which the fork does not ship (it has `RELEASE` + `Changelog`) | `dh_install` (missing files) | drop the `RELEASE_NOTES` line |
| `~rk5` | `debian/control` marked `ffmpeg-doc` `Architecture: arm64`; its content is the doxygen HTML built only in the arch-indep pass, which the arch builder skips | `dh_install` (missing `doc/doxy/html/*`) | `ffmpeg-doc` → `Architecture: all` (matches the baseline) |

The FATE patch is the right fix, not a test skip: the static array is
unreferenced by any decode logic, so removing it makes the decoders match
upstream, keeps the DRM_PRIME hw_config Kodi relies on, and lets the full FATE
suite run. Validated end-to-end locally: a full arch+indep build emits every
deb — `libavcodec63` (carries `av1_rkmpp`), the rest of the `libav*63`,
`ffmpeg`, and `ffmpeg-doc_..._all.deb` — with FATE passing. `~rk5` is uploaded
and building; the current published state is on the status watchlist.

### 5. Build-environment gotchas on this box

- **linuxbrew `pkg-config` shadows the system one.** `/home/linuxbrew/.linuxbrew/bin/pkg-config`
  does not search the system multiarch `.pc` dir, so ffmpeg configure failed on
  `lilv-0 not found` and Kodi's cmake would fail the same way. Fix: prepend
  `/usr/bin` to `PATH` for these builds. (Launchpad's clean chroot is unaffected.)
- **`/tmp` is a 7.8 GiB tmpfs** — too small for building ffmpeg (and far too
  small for Kodi). Build under **`/home/yi/rock5b-build`** on the nvme (261 GiB
  free); set `TMPDIR` there too.
- The signing key `ed25519/8F3025C4AA2228E6` (fingerprint
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`) is present and agent-cached, so
  `debsign` is non-interactive.

## Why it matters / follow-up

- Kodi build recipe and settings: [`apps/kodi/`](../apps/kodi/README.md).
- The decoder-selection analysis is the reason no Kodi fork is needed; keep it
  if a future Kodi release changes `FindHWConfig`/`FindDecoder`.
- Open follow-ups (also on the [status watchlist](../status.md)): `av1_rkmpp`
  container-extradata bug; confirm `~rk5` builds+publishes; the actual Kodi
  build + tty1 playback validation.
