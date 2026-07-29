# GRD AVC full-range BT.709 is package-verified; the live A/B stopped at handover

> **Closed 2026-07-29 by**
> [`Full-range BT.709 signaling fixes the muted GRD AVC colors after a clean reboot`](2026-07-29-grd-fullrange-bt709-fixes-muted-colors.md).
> The clean activation reached the client and the visual verdict was positive;
> this file retains the source, package, metadata, and failed-handover evidence
> from the preceding attempt.

> Scope: `apps/gnome-remote-desktop`, the packaged FFmpeg/RKMPP encode path, and
> the GDM-to-user RDP handover
> Source: GNOME Remote Desktop `release/50.2-rkmpp@cf60b4d9d2c5`,
> `src/shaders/grd-avc-dual-view.comp` `rgb_to_{y,u,v}()` and
> `src/grd-encode-session-ffmpeg.c` `create_encoder()`; booted ROCK 5B package
> and journal evidence
> Date: 2026-07-28
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PACKAGE-VERIFIED, MEASURED, PARTIAL

## Result

The GRD RKMPP path has a real color-metadata mismatch:

- the AVC Vulkan shader emits full-range BT.709-style YUV values, matching the
  [MS-RDPEGFX color-conversion contract](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/954d7546-6873-4466-95c8-20a7569c43e5);
- the release FFmpeg backend sets `AVCOL_RANGE_MPEG` and does not set a matrix;
  and
- a one-variable package changes those fields to `AVCOL_RANGE_JPEG` and
  `AVCOL_SPC_BT709`.

The experimental package compiled, passed package inspection, installed, and
matched its staged daemon byte-for-byte. A standalone one-frame Rockchip VPU
encode also proved that the proposed fields survive into H.264 metadata:
`ffprobe` changed from default/unspecified limited-range metadata to
`color_range=pc` and `color_space=bt709`.

The live visual A/B did **not** run. Installing the package restarted the system
GRD daemon while the old user handover daemon remained alive. Manually
restarting `gnome-remote-desktop-handover.service` inside that existing remote
session then broke the session handover. Subsequent clients authenticated at
GDM but returned to the greeter before the user encoder was created. The
experimental color fields were therefore never exercised by a post-login
client, and this run says nothing yet about whether they improve, worsen, or
leave the muted-color symptom unchanged.

The experimental package remains installed for a clean post-reboot test:

```text
gnome-remote-desktop
50.2+rkmpp+git20260721.13.cf60b4d+fullrange709-0ubuntu1~exp1
```

The runnable `.deb`, debug symbols, `.buildinfo`, and `.changes` are preserved
locally under the gitignored
`packaging/ppa/out/grd-fullrange709-exp1/`. The reconstructible text evidence is
committed in the
[`findings/evidence/2026-07-28-grd-avc-fullrange709/`](evidence/2026-07-28-grd-avc-fullrange709/README.md)
bundle.

## Why the source is mismatched

Microsoft specifies the AVC420 payload as an H.264 YUV420p Annex B stream whose
color conversion is the MS-RDPEGFX section 3.3.8.3.1 conversion. That conversion
is explicitly full-range BT.709, with Y, U, and V clamped to `0...255`.

The release shader implements:

```c
Y = (  54R + 183G +  18B) >> 8
U = ((-29R -  99G + 128B) >> 8) + 128
V = ((128R - 116G -  12B) >> 8) + 128
```

Those coefficients produce full-range values: black maps to Y=0, white to
Y=254, and neutral chroma to 128. There is no studio-range `+16` luma offset or
219/224 scaling.

Immediately before opening `h264_rkmpp`, however, the release backend contains:

```c
self->avctx->profile = AV_PROFILE_H264_HIGH;
self->avctx->color_range = AVCOL_RANGE_MPEG;
self->avctx->thread_count = 1;
```

The experiment replaces the range and adds the matrix:

```c
self->avctx->color_range = AVCOL_RANGE_JPEG;
self->avctx->colorspace = AVCOL_SPC_BT709;
```

The exact package delta is
[`fullrange-bt709.patch`](evidence/2026-07-28-grd-avc-fullrange709/fullrange-bt709.patch).

## Package and VPU verification

The build used the native Debian toolchain, not Linuxbrew's `pkg-config`:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
DEB_BUILD_OPTIONS='nocheck parallel=8' \
dpkg-buildpackage -b -us -uc
```

The build completed all 221 Ninja compile/link steps and produced the arm64
package. `nocheck` means package tests were deliberately skipped; this is
compile/package evidence, not a GRD integration-test pass.

The following gates passed:

- local `apt-get -s install` selected only the experimental GRD upgrade;
- `file` reported an ARM aarch64 PIE daemon;
- `ldd` resolved every dependency, including the packaged
  `libavcodec.so.62`;
- Lintian returned success with only the expected long-filename warning;
- the installed and staged daemon SHA-256 values were identical; and
- the experimental `.deb` SHA-256 is
  `a7b58ce94c32748a988be0d444a7ab1a120fcc6e36cde91eb873dbf3de10922d`.

The standalone VPU comparison used the same `/usr/bin/ffmpeg` Rockchip encoder.
The release-equivalent limited/unspecified case decoded as:

```text
pix_fmt=yuv420p
color_range=unknown
color_space=unknown
```

Here `unknown` is the H.264 default limited-range signaling: no full-range flag
or color description was present. With full range plus BT.709, it decoded as:

```text
pix_fmt=yuvj420p
color_range=pc
color_space=bt709
```

The exact commands and complete field output are in
[`h264-metadata.txt`](evidence/2026-07-28-grd-avc-fullrange709/h264-metadata.txt).
This proves FFmpeg/libmpp can carry the two fields into the SPS; it does not
prove that the GRD runtime opened an encoder with them.

## Handover failure: separate from color signaling

The package post-install restarted the system service at 19:51:57:

```text
system GRD PID 613 -> PID 118056
user GRD PID 5704: [DaemonHandover] org.gnome.RemoteDesktop name vanished
```

The existing RDP client and user daemon stayed alive until the explicit user
service restart at 19:54:05. The replacement user daemon reached `RDP server
started`, but a reconnect stalled after GDM updated the remote display to
session 8. The system daemon aborted that handover after 30 seconds; the user
journal recorded no FFmpeg initialization or encode-session creation.

Stopping the prematurely started daemon and reconnecting produced a fresh GDM
client, but the user handover service did not start in the existing session.
Starting it manually made the failure explicit:

```text
20:01:28.533963 [DaemonHandover] Could not get session id
```

`on_handover_object_added()` calls
`grd_get_session_id_from_pid(getpid())`, which calls
`sd_pid_get_session()`. If no session ID is returned, the callback exits before
it can match the system object path `/org/gnome/RemoteDesktop/Rdp/Handovers/session8`.
That is the immediate reason the manually launched daemon could not take the
authenticated client and GDM returned to the password screen.

No `HWAccel.FFmpeg` initialization or `Created h264_rkmpp encode session` line
appeared in either failed post-install attempt. The two color-context
assignments execute later in `create_encoder()`. The handover failure therefore
cannot be evidence for or against the color patch.

## Clean reboot verification gate

Do not manually restart the handover unit again. After a normal board reboot:

1. Confirm the installed version:

   ```bash
   dpkg-query -W -f='${Version}\n' gnome-remote-desktop
   ```

2. Connect through GDM and require a successful transition to the user
   session.
3. Require the user journal to show both:

   ```text
   [HWAccel.FFmpeg] Initialized FFmpeg/rkmpp encode backend
   [HWAccel.FFmpeg] Created h264_rkmpp encode session
   ```

4. Open the bundle's
   [`rdp-color-test.html`](evidence/2026-07-28-grd-avc-fullrange709/rdp-color-test.html)
   at 100% browser zoom. Compare the dark and light ramps for clipping/lift and
   the solid color patches for hue/saturation changes. Treat the fine chroma
   patterns separately: softness there is expected from 4:2:0 subsampling.
5. Preserve a client-side screenshot and the user/system GRD journals. A true
   A/B requires the same chart, client, display/color profile, window size, and
   zoom against the release package.

If the clean reboot still cannot hand over, collect that boot's logs before
changing services. The known-good release package remains locally available at:

```text
packaging/ppa/out/gnome-remote-desktop_50.2+rkmpp+git20260721.13.cf60b4d-0ubuntu1~rk1_arm64.deb
```

Its SHA-256 is
`bd77d67da8dee5b05a1aa9466e1c24822d43ab467f895217cc34542a31be41ce`.
No rollback was performed in this experiment.

## Boundary

- The source mismatch and MPP SPS behavior are established.
- The experimental GRD package is compile- and package-verified and is the
  installed package.
- The visual effect on the macOS RDP client is unverified.
- No GRD runtime bitstream was captured, so the exact SPS emitted from GRD
  remains uninspected.
- The failed handover was caused immediately by missing session identity in the
  manually started daemon; this does not prove whether a clean boot of the same
  package will hand over successfully.
- This experiment does not separate range/matrix behavior from macOS display
  color management, client decoder behavior, or client-side ICC/HDR settings.
