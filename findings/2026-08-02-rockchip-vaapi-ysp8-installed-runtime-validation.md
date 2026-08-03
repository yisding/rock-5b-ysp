# rockchip-vaapi ysp8 is installed and green across decode, encode, GStreamer, VLC, mpv, and Firefox; one optional IEP2 probe is noisy

> Scope: installed `rockchip-vaapi` and `rockchip-vaapi-config`
> `1.0.11+ysp8-0ubuntu1~rk1` on a ROCK 5B, including package identity, libva
> initialization, the safe codec/encode/import/concurrency gates, isolated
> Mutter display gates, and the two `rk_vcodec` messages produced during the
> run. This updates status track 14 and coverage areas C15 (hardware codecs and
> RGA), C11 (GPU/display), and C05 (CMA/runtime resources).
>
> Source: installed debs and payloads; native runtime gates from
> `/home/yi/Code/rock-5b/rockchip-vaapi`; fork base
> `main@aee5926aad51e1221c5cd3defea2aa08ff01e57f` with documented local
> modifications; installed MPP, RGA, FFmpeg, libva, GStreamer, VLC, mpv,
> Firefox, Mutter, and kernel packages; source inspection of the matching
> libmpp vproc path and kernel MPP request dispatcher.
>
> Date: 2026-08-02
>
> Trust: **MEASURED** (runtime gates and kernel-log audit) /
> **PACKAGE-VERIFIED** (installed versions, `dpkg -V`, hashes, ELF build ID,
> and deb extraction match) / **CODE-INSPECTED** and **ROOT-CAUSED** (the
> optional IEP2 initialization failure) / **PARTIAL** (the quarantined risky
> vector, long/sanitizer sweeps, sandbox-enabled Firefox, physical HDR, clean
> image, and 512 MiB CMA configuration remain open).

> **Updated 2026-08-02 by** the
> [forward-port small-geometry discriminator](2026-08-02-rga3-forward-port-small-geometry-discriminator.md).
> The single-pass RGA boundary recorded by this installed matrix was later
> closed for the same production forward-port/vendor kernel with 90/90 clean
> runs and 4,320/4,320 byte-compared frames at each affected geometry,
> including explicit exercise of both RGA3 cores. The original silent-write
> finding remains open on the rewrite driver, not on this forward-port stack.

> **Updated 2026-08-02 by** the
> [ysp9 RC validation](2026-08-02-rockchip-vaapi-ysp9-rc-validation.md).
> The previously blocked VP9 show-existing-frame vector now runs as an
> ordinary required case and passes bit-exact normally and under ASan/UBSan.
> The ysp8 safe-subset result below remains the historical installed-package
> record; the release/notes interlock and `check-safe` targets are retired in
> ysp9.

## Result

The installed ysp8 driver and matching config package pass the broad safe
runtime suite without a source-tree libva-driver override. The result covers
bit-exact default and 10-bit decode, intentional software fallbacks, repeated
and concurrent decode, H.264/HEVC encode, imported DMA-BUF/RGB surfaces,
multi-slice input, same-process mixed decode/encode, GStreamer VA decode and
encode, and hardware presentation through installed VLC, mpv, and Firefox inside a
fresh isolated Mutter virtual display.

The application result is materially wider than the earlier package gate:

- VLC passed H.264, HEVC Main, VP9 Profile 0, HEVC Main10, and VP9 Profile 2;
- mpv passed the same five cases, including P010 import and BT.2020/PQ input;
- Firefox 153.0 passed the same five cases and imported both 10-bit planes;
  this Firefox run deliberately disabled the RDD sandbox, so it does not close
  the sandbox-policy gate;
- all hardware encode cases emitted 48 parser-clean, software-decodable
  frames; and
- the kernel audit found no fault, hang, timeout, OOM, IOMMU fault, or RGA
  `no core match` signature.

One pair of kernel messages occurred once during the interlaced H.264 vector:

```text
rk_vcodec: mpp_collect_msgs:1897: session 0 process cmd 100 ret -22
rk_vcodec: mpp_dev_ioctl_common:2027: collect msgs failed -22
```

This is not a ysp8 decode failure. The printed command is hexadecimal, so
`cmd 100` means `0x100`, `MPP_CMD_INIT_CLIENT_TYPE`. libmpp tried to create an
optional IEP2 deinterlacing context because `/dev/mpp_service` exists, the
kernel advertised no IEP2 subdevice at client type 28, and the request returned
`EINVAL`. MPP then disabled deinterlacing and continued; the triggering clip
decoded bit-exact. The cleanup belongs in libmpp's vproc capability selection,
not in `rockchip-vaapi`.

## Exact installed stack

### Board and kernel

| Item | Measured identity |
|---|---|
| Board/userspace | Radxa ROCK 5B; Armbian 26.5.1 Resolute / Ubuntu 26.04 |
| Running kernel | `Linux 6.18.41-ysp-rockchip64 #1 SMP PREEMPT Thu, 09 Jul 2026 ...` |
| Kernel package | `linux-image-ysp-rockchip64 6.18.41+rk3588av1fwport20260802-0ubuntu1~rk1` |
| `/boot/vmlinuz-6.18.41-ysp-rockchip64` SHA-256 | `e7ab611dd5be3cd41149599fd3a057895c29c3e528f9ceda33b8c44873c23436` |
| `/sys/kernel/notes` SHA-256 | `20acca6b5e2e69b565f2d39e478cd78723424d14ff6bc9ba08b7189a7c673489` |
| CMA | boot parameter `cma=256M`; `CmaTotal: 262144 kB` |

The repository's risky-vector guard expects the same `uname -r` but notes hash
`6388dd294ff782a438a3a1e03d2c21f033998566d048cc6feecdd315aa2250f8`.
That mismatch is why the risky VP9 vector was not run. Matching the release
string alone is not sufficient authorization to cross that guard.

This host also has 256 MiB CMA, while the project configuration calls for 512
MiB when 4K video and GPU composition overlap. `CmaFree` was 248200 kB near the
start and was observed at 6800 kB and 3256 kB later in the suite. Those are
dynamic snapshots, not proof of a leak, and no tested allocation failed; they
do show that this successful run does not validate the intended 512 MiB
production margin.

### Installed userspace

| Component | Installed identity |
|---|---|
| `rockchip-vaapi` | `1.0.11+ysp8-0ubuntu1~rk1` arm64 |
| `rockchip-vaapi-config` | `1.0.11+ysp8-0ubuntu1~rk1` all |
| `librockchip-mpp1` | `1.5.0+git20260730.ad325345+ds-0ubuntu1~rk1` |
| `librga2` | `2.2.0+git20260725.26a50ef-0ubuntu1~rk1` |
| `libva2` | `2.23.0-1ubuntu1` |
| FFmpeg package | `7:8.0.3+rockchip+git20260729.33a651a55b-0ubuntu1~rk1`; `/usr/bin/ffmpeg` reports `8.0.3-0ubuntu1~rk1` with VAAPI |
| GStreamer | `gstreamer1.0-plugins-bad 1.28.2-1ubuntu1.1`; `gst-launch-1.0 1.28.2` |
| VLC | `3.0.23-1` |
| mpv | `0.41.0-2ubuntu4`, using runtime FFmpeg 8.0.3 |
| Firefox | `153.0.1+build2-0ubuntu0.26.04.1~mt1` |
| Mutter | `50.1` |

Both ysp8 packages were installed at the end of the run and `dpkg -V` returned
no changes. The config package sets the Rockchip libva driver name and path and
the GStreamer override used by the packaged deployment.

### Driver artifact proof

| Artifact | SHA-256 / identity |
|---|---|
| ysp8 driver deb | `370ee5ad94155592dc50c85f523d70d88f3ceb9c92860a5268342f1521b3c574` |
| ysp8 config deb | `a404c74843688753dcab661b9d2cae077002f072ad7c8ada31357f2b6cde5c11` |
| installed `rockchip_drv_video.so` | `7fd9a7ba637f06e9bbbda90680adb8ada4d32ca831515a133cd637d31b59a732` |
| driver extracted from ysp8 deb | `7fd9a7ba637f06e9bbbda90680adb8ada4d32ca831515a133cd637d31b59a732` |
| installed driver ELF build ID | `a0deb45ef39a0b40db87ec185b3e3ea9a825f3cb` |

FFmpeg provided the libva initialization probe because `vainfo` is not
installed. libva 1.23 requested `rockchip`, opened the installed driver path,
found `__vaDriverInit_1_20`, received success, and reported vendor
`Rockchip MPP VA-API Driver 0.1`. FFmpeg listed VAAPI as an available hardware
device.

The binary provenance is exact; the source provenance is not yet a clean-commit
reproduction. The local fork and `fork/main` both point at
`aee5926aad51e1221c5cd3defea2aa08ff01e57f` (`hevc: add packetized Main10
failure reducer`, 2026-07-31), while original upstream remains
`e8c64dd...`. The ysp8 package was built from a modified worktree over that
commit. Modified tracked files included CI, `.gitignore`, the main and Firefox
READMEs, Debian changelog, development/roadmap/testing docs, `src/log.c`, and
display/test scripts. There were no untracked source files. Therefore the
installed payload is auditable and matched, but `aee5926` by itself does not
recreate it.

## Runtime gate matrix

### Safe pinned conformance

The guarded safe suite produced 16 expected outcomes:

- 13 hardware VA decodes were bit-exact;
- H.264 constrained-baseline, HEVC Main10 narrow geometry, and hidden VP9
  Profile 2 exercised their intentional software-fallback paths; and
- `vp90-2-10-show-existing-frame2.webm` remained blocked by the kernel-notes
  fingerprint guard.

The harness correctly summarized this as `SAFE SUBSET GREEN; FULL GATE STILL
BLOCKED`. The blocked result is a preserved safety boundary, not a failed
decode.

### Synthetic, lifecycle, and concurrency

| Gate | Result |
|---|---|
| H.264 reference/B-frame matrix | Six combinations bit-exact |
| 4K H.264 | Bit-exact |
| VP9 repeatability | Five exact repeats |
| VP8 | Intentional software fallback |
| External-buffer lifecycle | 12 contexts, 1440 frames; pool and worker lifecycle green |
| Concurrent decode | Two contexts, 240 frames; peak workers 2 |

### Ten-bit decode and throughput

| Case | Result |
|---|---|
| Generated HEVC Main10 | 320x240, 48 frames, P010 bit-exact |
| Pinned Toshiba HEVC Main10 | 416x240, 256 frames, P010 bit-exact |
| HDR HEVC Main10 | 320x240, 24 frames, P010 bit-exact; BT.2020/PQ metadata preserved at input |
| Generated VP9 Profile 2 | 48 visible frames, bit-exact |
| Official VP9 Profile 2 | 10 displayed / 11 decoded, bit-exact |
| Narrow HEVC Main10 | 64-pixel case refused before hardware submission; 48 frames software-decoded; zero RGA submission |
| HEVC Main10 throughput | 1920x1080, 240 visible/decoded, 110.40 fps |
| VP9 Profile 2 throughput | 1920x1080, 240 visible/254 decoded, 187.30 fps |

Both throughput paths exceed 60 fps and use the AFBC-to-RGA P010 path. This
installed matrix originally had only one small-geometry pass, so it did not by
itself close the separately recorded rewrite-driver dropped-write defect. The
later [dedicated forward-port discriminator](2026-08-02-rga3-forward-port-small-geometry-discriminator.md)
does: 90/90 clean runs at both 320x240 and 416x240, with explicit coverage of
both RGA3 cores. The rewrite-driver mechanism remains open separately.

### GStreamer VA decode

With the packaged GStreamer/libva override, the readback gate passed:

| Codec | Frames | Result |
|---|---:|---|
| H.264 | 10 | Exact |
| VP9 Profile 0 | 1 | Exact |
| VP9 Profile 2 | 11 | Exact |
| HEVC Main10 | 256 | Exact |

### Encode

All cases produced 48 parser-clean frames and decoded successfully in software.

| Codec/path | Profile | PSNR |
|---|---|---:|
| H.264 FFmpeg CQP | High | 48.495713 |
| H.264 FFmpeg CBR | High | 46.262560 |
| H.264 FFmpeg VBR | High | 45.158094 |
| H.264 FFmpeg I420 upload | High | 48.495713 |
| H.264 GStreamer | High | 48.644034 |
| HEVC FFmpeg CQP | Main | 45.191850 |
| HEVC FFmpeg CBR | Main | 44.463005 |
| HEVC FFmpeg VBR | Main | 40.914833 |
| HEVC FFmpeg I420 upload | Main | 45.191850 |
| HEVC GStreamer | Main | 45.310424 |

### Imported surfaces, slices, and mixed use

- BGRA DRM PRIME import converted through RGA to NV12 and encoded 48 H.264
  frames at PSNR 37.140921.
- A two-object NV12 DMA-BUF import encoded 48 frames at PSNR 50.683977.
- H.264 and HEVC multi-slice input encoded 12 frames each with four equal-row
  slices per frame.
- One process ran two decoders and two encoders for 120 frames per stream,
  reaching two decode workers and 240 encode packets.
- Concurrent H.264 and HEVC encode while the shipping decode matrix ran also
  passed.

## Application presentation in an isolated Mutter display

The display wrapper started a fresh Mutter 1280x720 virtual monitor using
Panthor/Panfrost and Xwayland. This proves a real compositor/GPU import and
presentation path, but not a physical connector or HDR link.

### VLC 3.0.23

VLC produced 120 frames for each of H.264, HEVC Main, VP9 Profile 0, HEVC
Main10, and VP9 Profile 2. All five selected the Rockchip VA hardware decoder
and completed green.

### mpv 0.41.0

mpv presented 20 frames for each of the same five cases. H.264 logged 20
required repacks and one information change. Main10 logged 20 conversions and
21 exports, and accepted BT.2020/PQ input. This closes the prior "mpv blocked
because the live session has no output" boundary with a virtual display; it
does not prove physical HDR signaling or presentation.

### Firefox 153.0.1

Firefox hardware-decoded and exported all five cases:

| Case | Hardware frames | DMA-BUF exports |
|---|---:|---:|
| H.264 | 706 | 1408 |
| HEVC Main | 802 | 1600 |
| VP9 Profile 0 | 788 | 1576 |
| HEVC Main10 | 781 | 1558 |
| VP9 Profile 2 | 817 | 1634 |

The 10-bit plane imports succeeded, confirming the corrected GR1616 format
through Firefox and Panfrost. The run used the documented one-off RDD sandbox
disable, so it is hardware decode/export/display evidence only. It is **not**
evidence that the packaged Firefox RDD broker/seccomp policy works.

After every media gate was green, the display wrapper exited 1 because the
desktop portal left a runtime `doc` directory. Inspection confirmed it was not
a mount point; removing the empty directory with `rmdir` completed cleanup.
This is a harness cleanup artifact, not an application or codec failure.

## The `rk_vcodec` `cmd 100 ret -22` messages

The warning pair occurred exactly once, while the pinned interlaced H.264 clip
`CABREF3_Sand_D.264` was active. `ffprobe` identifies it as H.264 Main,
352x288, with `field_order=tt`. The same PID logged:

```text
mpp_platform: client ... driver is not ready!
device /dev/mpp_service select in vproc
ioctl set_client failed
mpp_dec_vproc: failed to create context
```

The source path explains the complete behavior:

1. `mpp/codec/mpp_dec.c:mpp_dec_put_frame()` sees the interlaced frame mode and
   calls `dec_vproc_init()`.
2. On failure it disables `enable_deinterlace` and continues with the decoded
   frame; it does not fail the decode.
3. `mpp/vproc/mpp_vproc_dev.c:get_iep_ctx()` chooses `/dev/mpp_service` based
   on the device node's existence.
4. `mpp/vproc/iep2/iep2.c:iep2_init()` sends
   `MPP_CMD_INIT_CLIENT_TYPE` (`0x100`) for `IEP_CLIENT_TYPE` 28.
5. The kernel request dispatcher returns `-EINVAL` because
   `srv->sub_devices[28]` is absent.

The kernel log formats the command with `%x`, which is why `0x100` appears as
`100`. The clip then completed bit-exact. The correct noise reduction is for
libmpp to select vproc only when IEP2 is actually advertised, rather than when
the generic MPP service node merely exists.

Repeated `mpp_platform: client 1,3,12,13,18,19 driver is not ready!` messages
are related platform-inventory conflict warnings and did not block any tested
path. `mpp_info: unknown version for missing VCS info` is a separate package
build-provenance diagnostic. Neither should be promoted into a kernel runtime
failure without a corresponding failed operation.

### Mainline and maxline do not provide the missing Rockchip driver

Neither inspected mainline nor either pinned maxline profile contains a
Rockchip IEP, IEP2, or VDPP driver:

- current local mainline codec-fix integration
  `c28b6586f74f7fb37c071174b66a445cf4ce0884` (`v7.2-rc5-282`) has no IEP or
  VDPP source, Kconfig symbol, or RK3588 device-tree node;
- maxline public `f12fb0acf7bb923c5958e9430edd0dae93400951`
  (`v7.2-rc3-241`) and maxline WIP
  `74b24e96da6245ef951ec34de481b7b8a2b91d34` contain no IEP/VDPP source or
  binding; the maxline project already records IEP2 as an unpublished TODO;
  and
- the 6.18 forward port intentionally omitted vendor `mpp_iep2.c`,
  `mpp_vdpp.c`, and the standalone `iep/` directory.

All those trees do contain `drivers/media/platform/m2m-deinterlace.c`, and the
maxline config enables `CONFIG_VIDEO_MEM2MEM_DEINTERLACE=m`. That is a generic
V4L2 memory-to-memory driver which performs its work through DMAengine and
registers a `/dev/video*` device. It is not a Rockchip IEP2 driver, does not
register MPP client type 28, and therefore cannot make libmpp's
`MPP_CMD_INIT_CLIENT_TYPE` IEP2 request succeed.

For the present stack, removing the harmless message requires the smaller
libmpp capability-selection fix described above. RK3588 does have IEP2 silicon
and its BSP enables `rockchip,iep-v2`, but the YSP 6.18 port omitted the IEP2
driver and DT/IOMMU nodes; RK3588 has no documented or BSP-addressable VDPP
instance. Actually enabling hardware deinterlacing therefore requires the
vendor IEP2 driver and device-tree port (or a different userspace processing
path). Switching to mainline/maxline or enabling the generic deinterlace module
is not that port. See the maintained
[RK3588 IEP2 guide](../kernel-drivers/iep2/README.md).

## Boundary

- The quarantined risky VP9 vector was not run because the exact kernel-notes
  fingerprint did not match its guard.
- The complete 163-candidate HEVC sweep was not repeated; the earlier exact
  Published MPP/FFmpeg result remains the owner of that evidence.
- Full normal plus ASan/UBSan driver matrices, an installed sanitizer build,
  and the two-hour decode/encode soaks were not repeated.
- Firefox ran with the RDD sandbox disabled. The patched, sandbox-enabled
  package/runtime gate remains open.
- The compositor output was a Mutter virtual monitor. No physical HDR monitor,
  connector metadata, or HDR link was validated.
- The host is configured for 256 MiB CMA rather than the intended 512 MiB for
  4K plus GPU composition.
- This was an in-place package installation, not a clean-image install.
- `vainfo` was unavailable; FFmpeg exercised and logged libva initialization
  instead.
- This matrix's one small-geometry pass did not close the RGA boundary by
  itself; the later repeated forward-port discriminator did. The rewrite
  driver's corrected power/map ordering remains boot-unverified.
- The installed ysp8 payload is exactly matched to the deb, but the package's
  source tree was dirty over `aee5926`; a clean signed source/commit identity
  still needs to be produced.

## Next gate

First make ysp8 reproducible from a clean, pushed source identity and publish
the matching driver/config source and binaries. Then repeat the installed
safe matrix on the intended 512 MiB CMA configuration and run Firefox with the
RDD sandbox enabled. Keep the quarantined VP9 vector behind its exact kernel
fingerprint and validate physical HDR separately. The production forward-port
small-geometry RGA boundary is closed by repeated evidence; runtime-verifying
the rewrite ordering fix is a separate rewrite-track gate.
