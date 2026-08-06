# Get started with the ROCK 5B hardware-video PPA

This guide is for a new user who wants hardware video acceleration on a Radxa
ROCK 5B without building the kernel or media libraries from source. It starts
with the normal installation path, then shows how to prove that MPV, FFmpeg,
Chrome, or GNOME Remote Desktop is actually using the RK3588 media hardware.

> [!WARNING]
> **Installing this PPA's kernel can leave the board unbootable.** Before the
> kernel install below, [confirm that the system is supported](#confirm-the-system-is-supported)
> and prepare the tested [recovery and rollback](#recovery-and-rollback) path.
> Keeping an old kernel package installed is not, by itself, a recovery method.
> You accept the risk of an unbootable or bricked board and data loss; the
> project author is not responsible if that happens.

> This is a personal engineering project, not a Radxa, Rockchip, Armbian, or
> Ubuntu product. There is no warranty, response-time promise, or guaranteed
> security-update schedule.

## 1. Add the PPA and install the base stack

Add the public archive:

```bash
sudo apt update
sudo apt install software-properties-common
sudo add-apt-repository ppa:yi-ding/ubuntu-rock-5b
sudo apt update
```

Install the smallest useful base for normal hardware-video use:

```bash
sudo apt install \
  linux-image-ysp-rockchip64 linux-dtb-ysp-rockchip64 \
  rk3588-codec-udev librockchip-mpp1 librga2 ffmpeg
sudo usermod -aG video "$USER"
sudo reboot
```

These packages have separate jobs:

| Package | Why a new user wants it |
|---------|-------------------------|
| `linux-image-ysp-rockchip64` and `linux-dtb-ysp-rockchip64` | Provide the RK3588 codec, AV1, and RGA kernel drivers. This is the part that makes the hardware appear. |
| `rk3588-codec-udev` | Lets members of the `video` group open the codec, RGA, and DMA-heap devices without running applications as root. |
| `librockchip-mpp1` | Provides Rockchip's codec runtime used by FFmpeg, VA-API, and Remote Desktop. |
| `librga2` | Provides hardware scale, crop, rotate, blit, and colour conversion. |
| `ffmpeg` | Provides the normal FFmpeg 8 command and libraries with RKMPP codecs and RKRGA filters. Applications linked to the system FFmpeg use this package too. |

The kernel and `librga2` should be upgraded together. The PPA treats them as a
tested pair, including its 10-bit buffer-layout handling.

Adding a PPA is not a one-time per-package choice. While it remains enabled,
newer PPA versions of already installed Ubuntu packages can become normal APT
upgrade candidates. Do not add the sibling FFmpeg 8.1 or experimental rewrite
PPAs unless you are deliberately testing those separate tracks.

### Verify the base after reboot

Run:

```bash
uname -r
id -nG

for node in /dev/mpp_service /dev/rga /dev/dma_heap/system; do
  printf '%-28s ' "$node"
  if test -r "$node" && test -w "$node"; then
    echo OK
  else
    echo NOT-READY
  fi
done

apt-cache policy \
  linux-image-ysp-rockchip64 librockchip-mpp1 librga2 ffmpeg
```

Look for all of the following:

- `uname -r` ends in `ysp-rockchip64`;
- `id -nG` includes `video`;
- all three device checks print `OK`; and
- APT shows the installed packages coming from
  `ppa.launchpadcontent.net/yi-ding/ubuntu-rock-5b`.

If any of those checks fail, fix the base before debugging a player or browser.

## 2. Choose a starting path

You do not need every package in the archive.

| What you want to do | Start with |
|---------------------|------------|
| Play video locally or build FFmpeg pipelines | The base stack, plus Ubuntu's `mpv`; add `rockchip-mpp-demos` for diagnosis. |
| Use an application that speaks VA-API, including a compatible Google Chrome build | The base stack, plus `rockchip-vaapi`, `rockchip-vaapi-config`, and `vainfo`. |
| Host a GNOME RDP desktop with hardware H.264 encode | The base stack, plus `gnome-remote-desktop` and `pipewire-audio`. |
| Compile software against MPP or RGA | Add `librockchip-mpp-dev` and/or `librga-dev`. |
| Build an external kernel module | Add `linux-headers-ysp-rockchip64`. Most users do not need headers. |

The next three sections show how to verify the application path, not just that a
package is installed.

## 3. Path A: FFmpeg and MPV

Install a player and the optional MPP diagnostic programs:

```bash
sudo apt install mpv rockchip-mpp-demos
```

First confirm that the commands and codec library are the expected builds:

```bash
ffmpeg -hide_banner -decoders | grep -E 'h264_rkmpp|hevc_rkmpp|vp9_rkmpp|av1_rkmpp'
ffmpeg -hide_banner -encoders | grep -E 'h264_rkmpp|hevc_rkmpp'
ffmpeg -hide_banner -filters  | grep rkrga
mpp_info_test
```

The FFmpeg output should list all four decoders, both encoders, and RKRGA
filters. `mpp_info_test` confirms that the packaged MPP program and library can
start, but it does not submit a video job to the hardware.

### Prove that MPV is decoding on the hardware

Use a known-good, local H.264 file first. Set its path and check its codec:

```bash
VIDEO=/path/to/a-known-good-720p-h264-file.mp4
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height \
  -of default=noprint_wrappers=1 "$VIDEO"
```

Then force the Rockchip decoder instead of relying on a generic automatic
hardware-decoding setting:

```bash
mpv --vd=h264_rkmpp --msg-level=vd=debug "$VIDEO"
```

For an HEVC file, use `--vd=hevc_rkmpp`. While the video is still playing, open
another terminal and check that MPV has the MPP device open:

```bash
pid=$(pgrep -n mpv)
ls -l "/proc/$pid/fd" | grep -E 'mpp_service|dma_heap'
```

The terminal or MPV's on-screen statistics should name `h264_rkmpp`, and the
file-descriptor check should show the MPP service or a DMA heap. That is much
stronger evidence than smooth playback alone.

Some MPV builds also list `rkmpp` in `mpv --hwdec=help`; on those builds,
`mpv --hwdec=rkmpp "$VIDEO"` is convenient. The explicit `--vd=` form is the
clearer first test because the RKMPP decoders are named FFmpeg codecs.

### Exercise decode, RGA, and encode together

With the same H.264 input, this command hardware-decodes it, scales it to
1280×720 with RGA, and hardware-encodes HEVC:

```bash
ffmpeg -hide_banner -y \
  -hwaccel rkmpp -hwaccel_output_format drm_prime \
  -i "$VIDEO" \
  -vf 'scale_rkrga=w=1280:h=720:format=nv12' \
  -c:v hevc_rkmpp -b:v 4M -an ./rk-test.mp4

ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,nb_frames \
  -of default=noprint_wrappers=1 ./rk-test.mp4
```

A successful, non-empty HEVC 1280×720 output proves substantially more than the
capability list: one command used MPP decode, librga/RGA, and MPP encode.

## 4. Path B: VA-API and Google Chrome

Install the VA-API bridge and make it the normal VA-API driver for future login
sessions:

```bash
sudo apt install rockchip-vaapi rockchip-vaapi-config vainfo
```

Log out and back in, or reboot. Then check the driver directly:

```bash
LIBVA_DRIVER_NAME=rockchip \
  vainfo --display drm --device /dev/dri/renderD128
```

The output should name the Rockchip driver and show decode entries for H.264,
HEVC, and VP9. AV1 is available through direct MPP/FFmpeg, but not through this
VA-API driver.

### Install a compatible Chrome package

The browser testing in this repository uses Google's directly distributed
Chrome package, not XtraDeb Chromium. Download only from
[Google's official Chrome page](https://www.google.com/chrome/), save the file
as `$HOME/Downloads/google-chrome.deb`, and check it before installation:

```bash
CHROME_DEB="$HOME/Downloads/google-chrome.deb"
dpkg-deb -f "$CHROME_DEB" Architecture
sudo apt install "$CHROME_DEB"
```

The architecture check **must** print `arm64`. Google's Linux download choices
can change; if its official page does not offer an ARM64 Debian package, skip
this path rather than installing the common `amd64` package or using an
unofficial repack.

Start Chrome normally:

```bash
google-chrome-stable
```

Do not disable Chrome's sandbox merely to make a demo work. In Chrome:

1. Open `chrome://gpu` and find the video-acceleration information. Video
   decode should be hardware accelerated and H.264/HEVC/VP9 profiles should be
   present.
2. Play an unencrypted, known-good 720p H.264 or VP9 video.
3. Open `chrome://media-internals`, select the active player, and look for
   `VaapiVideoDecoder` in the decoder name or event log.

`VaapiVideoDecoder` is the most useful browser-side signal that the hardware
path was selected. If `chrome://gpu` has no profiles, return to the `vainfo`
check. If `vainfo` works but Chrome does not, the Chrome build or its sandbox is
the likely boundary; installing another random Chromium package will not fix a
browser compiled without libva support.

## 5. Path C: GNOME Remote Desktop

This path uses hardware **encoding on the ROCK 5B**. Video decoding happens on
the remote RDP client, so a successful server check will refer to
`h264_rkmpp` encode, not hardware decode.

Install the patched service and the native PipeWire audio stack:

```bash
sudo apt install gnome-remote-desktop pipewire-audio
```

Log out and back in, then open GNOME **Settings → System → Remote Desktop**.
Enable Desktop Sharing or Remote Login as appropriate and set the credentials
there. The exact labels can vary slightly with the GNOME Settings version.

Connect from another machine with an RDP client that can negotiate AVC420. The
Microsoft clients and FreeRDP builds with OpenH264 support are useful starting
points. Move windows or play a video so the session produces many frames, then
check the server:

```bash
journalctl --user -b \
  -u gnome-remote-desktop.service \
  -u gnome-remote-desktop-handover.service \
  -g 'HWAccel.FFmpeg'
```

Look for messages like:

```text
Initialized FFmpeg/rkmpp encode backend (encoder "h264_rkmpp")
Created h264_rkmpp encode session
```

For a second, process-level check while the connection is active:

```bash
pid=$(pgrep -n -f 'gnome-remote-desktop')
ps -T -p "$pid" | grep mpp_h264e
ls -l "/proc/$pid/fd" | grep -E 'mpp_service|dma_heap'
```

An `mpp_h264e` thread plus an open media device shows that the live RDP process
is using the RKMPP encoder. If the backend initializes but no encode session is
created, check the client: a client that negotiates only the older RFX path
will make GNOME Remote Desktop encode in software even when the hardware backend
is healthy.

This package supports hardware encode for a logged-in user session. Hardware
encode at the GDM login screen is not part of the published PPA setup.

## 6. Packages most people can skip

The package chooser in [section 2](#2-choose-a-starting-path) is the canonical
map. Development headers, kernel headers, MPP demos, the co-installable FFmpeg
6.1 comparison tools, and the unrelated Plymouth repair are optional; do not
install them merely because they share the archive. In particular, do not
install the separate codec DKMS experiment on the YSP kernel: its drivers are
already built in.

The repository also has full-stack install and migration helpers under
[`packaging/ppa/`](../packaging/ppa/README.md). They are useful for maintainers
and existing experimental installs; the manual package choices above are easier
to understand on a new system.

## 7. What is not supported

Treat the following as out of scope, absent, or not qualified:

- systems outside the [qualified board, OS, architecture, and kernel
  boundary](#confirm-the-system-is-supported);
- MIPI camera, CIF, ISP, ISPP, AIISP, VPSS, and HDMI-input capture;
- the RKNPU/RKNN/RKLLM NPU stack;
- MPP hardware JPEG and VP8; AVS2 is present in driver code but unverified;
- encoder B-frames or P010 input to the hardware encoder;
- AV1 or video-processing/deinterlacing through VA-API;
- Kodi from this PPA—no Kodi package is published;
- direct named RKMPP decoding in VLC 3.x; a working VA-API route is required
  instead;
- XtraDeb Chromium hardware decode in the tested build, which was compiled
  without libva, or an arbitrary browser repack;
- Firefox VA-API with its normal sandbox, which has not been qualified here;
- Chrome's GPU sandbox as a security-qualified configuration. Functional
  decode signals do not constitute a browser security review;
- GNOME Remote Desktop hardware encode at the GDM login screen;
- a clean migration from every older experimental PPA combination; and
- whole-board behavior such as Wi-Fi variants, suspend/resume, every USB port,
  audio device, storage device, or display output. Those remain owned by the
  underlying Armbian image and are not guaranteed by a media PPA.

The BSP is the better choice when camera/ISP, NPU, hardware JPEG, per-die CPU
voltage tuning, or broad vendor peripheral coverage matters more than this
newer-kernel media stack.

## 8. Troubleshooting, recovery, and support

### Confirm the system is supported

Before diagnosing an application—or before installing if you followed the
warning at the top—confirm that the board matches the only qualified target:

| Requirement | Supported target |
|-------------|------------------|
| Board | Radxa **ROCK 5B** with an RK3588. ROCK 5B+ receives the same codec device-tree settings but has not been tested. |
| Operating system | **Armbian's Ubuntu 26.04 Resolute** image. |
| Architecture | **arm64**. |
| Kernel | The PPA's `linux-image-ysp-rockchip64`; the normal Armbian kernel does not expose the codec devices used by this guide. |

Check the running system:

```bash
dpkg --print-architecture
. /etc/os-release
printf '%s\n' "${UBUNTU_CODENAME:-$VERSION_CODENAME}"
tr -d '\0' </proc/device-tree/model
printf '\n'
```

The first two answers should be `arm64` and `resolute`, and the model should
identify a Radxa ROCK 5B. Packages in this PPA have not been qualified on
another board, Ubuntu release, Debian image, or Radxa OS.

The intended media scope is:

- H.264, HEVC, VP9, and AV1 hardware decode through MPP/FFmpeg;
- H.264 and HEVC hardware encode;
- RGA hardware scaling and colour conversion;
- H.264, HEVC, and VP9 decode through the optional VA-API bridge; and
- H.264 hardware encode for a GNOME Remote Desktop user session.

If the system does not match the table, stop. A failure on another system is
not evidence of a package defect in this supported configuration.

### Recovery and rollback

Installing `linux-image-ysp-rockchip64` changes which kernel Armbian boots.
ROCK 5B's normal Armbian boot flow does not provide a kernel-selection menu, so
keeping the old kernel package installed is not enough if the new kernel fails
before login.

Before installing the kernel, complete the canonical
[recovery and rollback runbook](../install.md#3-prepare-recovery-and-capture-the-old-baseline).
It owns the baseline capture, retained-package, SD-rescue, switch, reinstall,
and verification commands. Do not shorten that preparation to a copied command
fragment here: the recovery path is only useful when it has been exercised far
enough to mount and repair the installed system.

Do not install the PPA kernel until that recovery path is real. A copied
configuration file by itself is not a recovery method.

### Common problems

Start with the earliest failed layer:

| Symptom | First check |
|---------|-------------|
| `uname -r` does not contain `ysp-rockchip64` | The PPA kernel was not selected at boot. Use the [recovery runbook](#recovery-and-rollback) rather than manually rewriting `/boot` links. |
| Device exists but a normal user cannot open it | Confirm `rk3588-codec-udev` is installed, `id -nG` contains `video`, and a completely new login session was started after `usermod`. |
| FFmpeg does not list `*_rkmpp` | Check `command -v ffmpeg`, `ffmpeg -version`, and `apt-cache policy ffmpeg`; a private FFmpeg earlier in `PATH` may be taking precedence. |
| MPV plays but you cannot tell which decoder it used | Force `--vd=h264_rkmpp` or `--vd=hevc_rkmpp`, then inspect the MPV process's open descriptors. |
| `vainfo` works but Chrome stays on software | Check that the Chrome `.deb` is `arm64`, then inspect `chrome://gpu` and `chrome://media-internals`. Browser build and sandbox behavior are separate from driver health. |
| GRD loads the backend but creates no hardware session | Use a client with AVC420 support and generate motion. An RFX-only connection takes the software path. |

### Collect a useful report

For a useful support report, collect:

```bash
uname -a
id
apt-cache policy \
  linux-image-ysp-rockchip64 librockchip-mpp1 librga2 ffmpeg \
  rockchip-vaapi gnome-remote-desktop
ls -l /dev/mpp_service /dev/rga /dev/dma_heap/system
journalctl -k -b -p warning..alert --no-pager
```

### Ask for help

Questions and support requests are welcome as
[GitHub issues](https://github.com/yisding/rock-5b-ysp/issues/new). Include:

- the exact board model and Armbian image;
- `uname -r` and the relevant `apt-cache policy` output;
- the command or application you ran and what you expected;
- the smallest relevant terminal or journal excerpt; and
- whether you prepared the recovery path before installing the kernel.

Remove passwords, tokens, private URLs, and unrelated logs before posting.

For maintainers and readers who want the implementation and evidence detail,
continue with the [current status](../status.md), the
[PPA packaging notes](../packaging/ppa/README.md), the
[kernel validation record](../kernel-drivers/docs/forward-port-status.md), or
the [whole-board coverage inventory](support-coverage.md).
