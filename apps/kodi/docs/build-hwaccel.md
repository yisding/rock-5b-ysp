# Building Kodi 22 for RK3588 hardware decode

Recipe to build Kodi against the external `ffmpeg-rockchip-81` fork so it
hardware-decodes through RKMPP → DRM PRIME. Targets a **GBM/DRM console** with
**GLES** (no X11/Wayland desktop needed). Native cmake build — not
`tools/depends`.

> Status: this recipe is derived and prerequisite-validated but the Kodi build
> itself has not been run yet. Update the [status dashboard](../../../status.md)
> and this note when it is.

## 0. Two environment gotchas on the ROCK 5B builder

Both bit the FFmpeg build and will bite Kodi's cmake the same way:

- **Use the system `pkg-config`, not linuxbrew's.** `/home/linuxbrew/.linuxbrew/bin/pkg-config`
  is first in `PATH` and does not search the system multiarch `.pc` dir, so
  cmake/configure "can't find" libdrm/gbm/ffmpeg. Prepend `/usr/bin`:
  `export PATH=/usr/bin:/usr/sbin:/bin:/sbin:$PATH`.
- **Don't build under `/tmp`** — it is a 7.8 GiB tmpfs. Build under the nvme,
  e.g. `/home/yi/rock5b-build/kodi-build`, and set `TMPDIR` there.

## 1. Prerequisites (from the PPA)

```bash
# MPP/librga come from the normal system archive; ABI-63 FFmpeg is isolated.
sudo add-apt-repository -y ppa:yi-ding/ubuntu-rock-5b
sudo add-apt-repository -y ppa:yi-ding/rock5b-ffmpeg81-rockchip
sudo apt update
# good MPP (1375813c) + RGA + the fork FFmpeg dev/runtime (libavcodec63)
sudo apt install -y librockchip-mpp-dev librga-dev \
  libavcodec-dev libavformat-dev libavutil-dev libavfilter-dev \
  libswscale-dev libswresample-dev
```

`pkg-config --modversion libavcodec` must report **63.x** (the fork), and
`ffmpeg -hide_banner -decoders | grep rkmpp` must list `h264_rkmpp` etc. The
board's stock `librockchip-mpp1 1.5.0-1+rk1` (`750e76e`) does **not** register
the MPP parsers — the PPA `1375813c` build is required.

The dedicated FFmpeg archive intentionally supersedes the normal system PPA's
FFmpeg 8.0.3 packages with the ABI-63/61 fork. It is an application test stack,
not the normal desktop stack. Use
[`clean-install-system-stack.sh`](../../../packaging/ppa/clean-install-system-stack.sh)
to return a test machine to the exact FFmpeg-8.0/GRD system package set.

## 2. Kodi build dependencies

```bash
sudo apt build-dep kodi        # Ubuntu's kodi (21.3) deps cover ~all of 22.0
sudo apt install -y libgbm-dev libinput-dev libxkbcommon-dev \
  libdisplay-info-dev libspdlog-dev libfmt-dev rapidjson-dev \
  libflatbuffers-dev flatbuffers-compiler nlohmann-json3-dev \
  libcrossguid-dev libp8-platform-dev libtinyxml2-dev
```

Install the fork `libav*-dev` **before** `apt build-dep kodi` so apt does not
pull Ubuntu's `libavcodec62`; the fork's `libavcodec-dev` (`8.1.2+rockchip81`)
already satisfies Kodi's `libavcodec-dev (>= 7:4.2.2)`. The fork `libavcodec63`
coexists with the distro `libavcodec62` (different SONAME package), so
`gnome-remote-desktop` and other `libavcodec62` consumers keep working.

## 3. Configure + build

```bash
export PATH=/usr/bin:/usr/sbin:/bin:/sbin:$PATH
export TMPDIR=/home/yi/rock5b-build/tmp; mkdir -p "$TMPDIR"
cmake -S ~/Code/rock-5b/media/xbmc -B /home/yi/rock5b-build/kodi-build -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DCORE_PLATFORM_NAME=gbm \
  -DAPP_RENDER_SYSTEM=gles \
  -DENABLE_INTERNAL_FFMPEG=OFF \
  -DENABLE_TESTING=OFF
cmake --build /home/yi/rock5b-build/kodi-build -j$(nproc)   # long (~1–3 h on 8× A76/A55)
```

`-DENABLE_INTERNAL_FFMPEG=OFF` makes `FindFFMPEG.cmake` use the system (fork)
FFmpeg via pkg-config; the gate needs libavcodec ≥ 61.3.100 / libavutil ≥
59.8.100 and the fork's 63.2 / 61.3 clears it. The GBM + GLES combination
compiles `RendererDRMPRIME` / `RendererDRMPRIMEGLES`, which display
`AV_PIX_FMT_DRM_PRIME` frames zero-copy.

## 4. Runtime settings (required)

The DRM PRIME decoder is opt-in. After first launch, enable in
Settings → Player → Videos (or `guisettings.xml`):

- **Allow using DRM PRIME decoder** (`videoplayer.useprimedecoder`)
- **Allow hardware acceleration with DRM PRIME** (`videoplayer.useprimedecoderforhw`)

Without the second one, `FindHWConfig()` returns null and Kodi falls back to
software. See [`decoder-selection.md`](decoder-selection.md).

## 5. Test on tty1 (GBM needs DRM master)

GNOME/`gdm` holds DRM master on this board, so `kodi-gbm` must run from a bare
VT. The user needs to be in the `video` and `input` groups.

```bash
sudo systemctl stop gdm         # release DRM master
# from tty1:
/home/yi/rock5b-build/kodi-build/kodi-gbm
# ... play an H.264/HEVC file, confirm hardware decode ...
sudo systemctl start gdm        # restore the desktop
```

Confirm hardware decode in `~/.kodi/temp/kodi.log`:

- `CDVDVideoCodecDRMPRIME::Open - using decoder Rockchip MPP ... H264 decoder`
- the player/codec info overlay (Ctrl+Shift+O) shows `ff-h264_rkmpp-drm_prime`

## 6. Known limits

- **AV1 from MP4/MKV needed an RKMPP extradata fix.** The fork already queued
  the container extradata, but failed to mark that MPP packet as extra data.
  MPP therefore parsed the four-byte `av1C` header as an OBU and reported
  `No sequence header available`. The forward port now calls
  `mpp_packet_set_extra_data()` before queueing it; the build passes, but the
  RK3588 MP4/MKV playback re-test is still pending. The
  [FFmpeg scorecard](../../../video-libraries/ffmpeg/docs/validation.md)
  distinguishes that application gate from compile and package proof.
- 10-bit (NV15) and AFBC plane routing on RK3588 can need attention (dynamic DRM
  plane selection); validate per-content on the board.
