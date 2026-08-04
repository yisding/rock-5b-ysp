# ROCK 5B PPA — support statement

What `ppa:yi-ding/ubuntu-rock-5b` and its forward-port kernel **do** support,
what they **do not**, and how both compare to a Rockchip BSP distribution.

This is the page to read before adding the archive to a board. It is written for
someone deciding whether this stack fits their use, not for someone maintaining
it — the maintenance view is [`../status.md`](../status.md) and
[`../packaging/ppa/`](../packaging/ppa/README.md).

> **What "supported" means here.** This archive is a personal engineering
> project, not a vendor product. A row below says *supported* when this
> repository holds a dated hardware result for it on this board, and *not
> supported* when the capability is absent, deliberately declined, or has no
> runtime evidence at all. §6 states the evidence behind each claim and where it
> stops. Nothing here carries a warranty, a response time, or a security-update
> commitment.

## 1. What it targets

| Axis | Supported | Not supported |
|------|-----------|---------------|
| Board | Radxa **ROCK 5B** (RK3588). The ROCK 5B+ shares the same device-tree include, so it receives the same codec enablement — untested. | Every other RK3588 board, every other Rockchip SoC. The kernel package ships Armbian's whole `rockchip64` DTB set, but codec enablement lands only in `rk3588-rock-5b.dtsi` (§3.3). |
| Distribution | **Armbian's Ubuntu 26.04 "Resolute" image** for ROCK 5B. | Debian-based Armbian, Radxa's own OS images, stock Ubuntu Server/Desktop images, any release other than Resolute. The archive publishes for `resolute` only; the kernel package assumes Armbian's `/boot` layout, `armbianEnv.txt`, and boot-script conventions. |
| Architecture | **arm64** only. | Everything else. The PPA is configured with the `arm64` processor alone; `Architecture: all` packages are built on arm64. |
| Kernel | The archive's own `linux-image-ysp-rockchip64` (§3). | Armbian's stock `current`/`edge`/`vendor` kernels — the userspace works on them, but no codec device nodes exist without a kernel that carries the drivers. The out-of-tree [DKMS channel](../packaging/dkms/README.md) exists for that case and is **not boot-validated**. |

## 2. What the archive publishes

Verified live against the Launchpad API on **2026-08-04**; publication state can
change without an edit here, so re-read
[`status.md` W05](../status.md#watch-w05) before trusting a version string.

| Source package | Version | What it is |
|----------------|---------|------------|
| `linux-rockchip64-ysp` | `6.18.42+rk3588av1fwport20260803-0ubuntu1~rk1` | The forward-port kernel: image, DTB, and headers packages. Release string `6.18.42-ysp-rockchip64`. |
| `mpp` | `1.5.0+git20260730.ad325345+ds-0ubuntu1~rk1` | `librockchip_mpp` — the vendor codec library that talks to `/dev/mpp_service`. |
| `librga` | `2.2.0+git20260725.26a50ef-0ubuntu1~rk1` | `librga2` — the 2D blit/scale/convert library for `/dev/rga`. |
| `ffmpeg` | `7:8.0.3+rockchip+git20260729.33a651a55b-0ubuntu1~rk1` | Ubuntu's FFmpeg 8.0 packaging plus the RKMPP/RKRGA forward port. Keeps Resolute's ABI family (`libavcodec62`, `libavutil60`, …), so it **replaces** the distro FFmpeg rather than colliding with it. |
| `rockchip-vaapi` | `1.0.11+ysp12-0ubuntu1~rk1` | VA-API driver over MPP/RGA, for applications that cannot select the RKMPP codecs directly (browsers, VLC, GStreamer `va`). |
| `gnome-remote-desktop` | `50.2+rkmpp+git20260729.15.c4ef3c9-0ubuntu1~rk2` | GNOME Remote Desktop with a hardware RKMPP encode backend. |
| `rk3588-codec-udev` | `1.1` | The `video`-group udev rule for `/dev/mpp_service`, `/dev/rga`, and `/dev/dma_heap/*`. Required on every path. |
| `ffmpeg-rockchip` | `6.1+git20260423.40c412dacc-0ubuntu1~rk1` | nyanmisaka's FFmpeg 6.1 Rockchip fork as co-installable `/opt` tools. Does not touch system FFmpeg. |
| `plymouth` | `24.004.60+git20250831.4a3c171d-0ubuntu8.1~rk1` | Ubuntu's exact Resolute source plus one upstream commit that fixes an incomplete-CSI parser loop able to hang boot on a serial console. |

Four sibling archives exist for incompatible lines — FFmpeg 8.1 (upstream and
Rockchip), and the experimental clean-room rewrite kernels. **Do not add them
for ordinary use;** they are comparison and research targets, described in
[`packaging/ppa/`](../packaging/ppa/README.md) § PPA Layout.

```mermaid
flowchart TB
  apps["Applications<br/>mpv, FFmpeg CLI, GNOME Remote Desktop, browsers, VLC"]
  va["libva + rockchip-vaapi<br/>(PPA)"]
  ffm["FFmpeg 8.0.3 + RKMPP/RKRGA<br/>(PPA, replaces Ubuntu's)"]
  libs["librockchip_mpp + librga<br/>(PPA)"]
  udev["rk3588-codec-udev<br/>(PPA)"]
  nodes["/dev/mpp_service · /dev/rga · /dev/dma_heap/*"]
  kern["linux-image-ysp-rockchip64<br/>(PPA) — MPP, RGA, AV1, IEP2 built in"]
  ubu["Ubuntu 26.04 archive + Armbian image<br/>Mesa/Panfrost, PipeWire, GNOME, firmware"]
  hw["RK3588: VEPU580 ×2 · VDPU381 ×2 · AV1 · RGA3 ×2 + RGA2 · IEP2"]

  apps --> va --> libs
  apps --> ffm --> libs
  libs --> nodes
  udev -. grants access .-> nodes
  nodes --> kern --> hw
  ubu -. everything else .-> apps
```

## 3. What the forward-port kernel supports

### 3.1 Accelerator blocks

| Block | State | Notes |
|-------|-------|-------|
| **H.264 decode** | Supported | VDPU381, two cores behind the CCU. Bit-exact against software reference in the repo's decode differential. |
| **HEVC (H.265) decode** | Supported | Same cores. Main and Main10. |
| **VP9 decode** | Supported | Same cores; bit-exact as of 2026-07-04. |
| **AV1 decode** | Supported | The separate Verisilicon AV1 block, driven through an upstream-style VSI IOMMU provider this port adds. Bit-exact on hardware 2026-07-04. |
| **AVS2 decode** | Present, untested | VDPU381 covers it and the driver registers the cases, but no AVS2 asset exists in this repo's harness, so there is no result. |
| **H.264 encode** | Supported | VEPU580, two cores with CCU/DCHS. PSNR-gated in the FFmpeg suite. |
| **HEVC encode** | Supported | Same cores. Main profile, NV12 input, RK3588's CTU64 contract. |
| **RGA 2D** | Supported | Both RGA3 cores plus RGA2: scale, crop, rotate, colour convert, blit. |
| **10-bit paths** | Supported, paired | P010/P210/NV15 raster **and** TILE strides plus plane offsets. The kernel and `librga` must be installed **as a pair** — a mismatched pair is silently wrong on the 10-bit TILE path. |
| **IEP2 deinterlacing** | New, narrow evidence | The hardware deinterlacer, added in the `20260803` kernel and confirmed working standalone on that kernel on 2026-08-04. It is **not** reachable through VA-API (§5), and libmpp's decoder-internal use of it is deliberately disabled by the VA-API driver. |

Encoder **B-frames and P010 encode input are permanent hardware/MPP walls**, not
open work. They are not coming.

### 3.2 What the kernel does *not* carry

| Capability | Why |
|------------|-----|
| **JPEG encode / decode (hardware)** | RK3588 has the blocks; this port deliberately left `mpp_jpgdec.c`/`mpp_jpgenc.c` behind. Visible consequence: the GStreamer suite's JPEG cases fail as expected diagnostics and libmpp logs benign `client N driver is not ready!` probes. Mainline's own Hantro V4L2 JPEG driver is enabled as a module and is a separate, unrelated path. |
| **VP8 hardware decode** | Its VPU block is not ported. FFmpeg still advertises a `vp8_rkmpp` decoder; there is no evidence it works on this kernel, so treat it as unsupported. |
| **NPU (RKNPU / RKNN / RKLLM)** | The 8,598-line vendor NPU driver is not ported. Scoped, not started — see the [RKNPU scoping finding](../findings/2026-07-24-rknpu-forward-port-scoping.md). No NPU inference of any kind runs on this kernel. |
| **Camera: MIPI CSI, CIF, ISP, ISPP, AIISP, VPSS** | Not ported. No sensor pipeline. |
| **HDMI input / capture (HDMI-RX)** | Not ported. |
| **VDPP post-processor** | RK3588 does not have one; the BSP driver binds VDPP on RK3528/RK3576 instead. Not a gap. |
| **Legacy VPU1/VPU2, RKVDEC-v1, RKVENC-v1** | Silicon absent on RK3588. Not a gap. |
| **Per-die CPU voltage binning (PVTM/eFuse OPP)** | Substituted with a stub that returns `-EOPNOTSUPP`, so the CPU runs mainline's worst-die voltage table. On this board that is **37.5–87.5 mV higher than the die's entitlement on nine of ten non-trivial CPU OPPs** (measured, [W22](../status.md#watch-w22)). A power/thermal cost, not a correctness one. |
| **Codec devfreq, system monitor, DMC coupling** | Codec-core dynamic frequency scaling is compiled out; the thermal/voltage coupling shims return "not available" and mainline thermal cooling substitutes. |

The whole-board picture — Wi-Fi, GPIO, suspend/resume, USB, display outputs,
audio, storage — is **not** claimed by this archive at all; it is whatever the
Armbian image provides. [`support-coverage.md`](support-coverage.md) inventories
which of those areas this repository has evidence for (many: none).

### 3.3 Board scope, precisely

The MPP service, both encoder cores, both decoder cores, the AV1 block, and
IEP2 are declared `status = "disabled"` in `rk3588-base.dtsi` and enabled only in
`rk3588-rock-5b.dtsi`, which `rk3588-rock-5b.dts` and `rk3588-rock-5b-plus.dts`
include. On any other RK3588 board's DTB the codec nodes stay disabled and no
codec device appears. The RGA nodes *are* enabled in the shared base file, so
`/dev/rga` would come up more widely — untested, and not a supported
configuration.

### 3.4 How the kernel package behaves on the board

- **Co-installable names, one boot slot.** The binaries are
  `linux-image-ysp-rockchip64`, `linux-dtb-ysp-rockchip64`, and
  `linux-headers-ysp-rockchip64`, so they never replace Armbian's own kernel
  packages. But installing repoints `/boot/Image` and `/boot/dtb` at the YSP
  kernel — **it becomes the booted kernel.** Removing it repoints them at the
  highest remaining kernel in `/boot`, or removes the dangling links if there is
  none.
- **No boot menu.** Armbian's ROCK 5B U-Boot flow has no kernel picker; keeping
  a second kernel under `/boot` does not make it selectable after a failed boot.
  Prepare a rescue path *before* installing —
  [`install.md` §3](../install.md) is the runbook.
- **Successive builds of the same version replace each other.** The package
  name and release string are stable across rebuilds, so a newer upload
  overwrites a known-good install of the same version.
- **Never install the DKMS package on this kernel.** The drivers are built in
  (`=y`); the out-of-tree build fails `modpost` with `exported twice`.

## 4. Device access is not automatic

No kernel path makes the device nodes usable without root. `rk3588-codec-udev`
installs the rule, and **the user must be in the `video` group**. The
`dma_heap` grant matters as much as the codec node: RKMPP allocates its buffers
there, so an otherwise-correct setup dies at MPP init without it.

The GDM login greeter is deliberately excluded — hardware-encoding the greeter
needs the separate opt-in
[`gdm-hwenc`](../packaging/gdm-hwenc/README.md) package, which widens codec
access to the whole `gdm` group and is not published.

## 5. What the userspace stack supports

| Component | Supported | Boundary |
|-----------|-----------|----------|
| **FFmpeg 8.0.3 (`+rockchip`)** | `h264_rkmpp` / `hevc_rkmpp` decode and encode, `vp9_rkmpp` and `av1_rkmpp` decode, `scale_rkrga` and the zero-copy decode→RGA→encode transcode path. | Replaces Ubuntu's FFmpeg in place (same ABI family). Not co-installable with the FFmpeg 8.1 archives. |
| **Player selection** | `mpv --hwdec=rkmpp` or `--vd=h264_rkmpp`; `ffmpeg -c:v h264_rkmpp`. | The RKMPP decoders are **standalone AVCodecs, not `AVHWAccel`** — a generic "enable hardware decoding" toggle will not find them, and **VLC 3.x cannot select them at all**. |
| **`rockchip-vaapi`** | Default: H.264, HEVC Main, and VP9 Profile 0 decode. Opt-in (documented environment switch): HEVC Main10, VP9 Profile 2, and H.264/HEVC encode. | **No deinterlacing** — the driver advertises no `VAEntrypointVideoProc`. **No AV1** through VA-API. 10-bit below 68 pixels wide is [permanently declined](../video-libraries/vaapi/README.md#declined-narrow-afbc-10-bit-below-68-pixels). Picture size is capped at 8192×8192. Chromium and sandbox-enabled Firefox are unproven. |

> **Interlaced H.264: fixed in `ysp12`, upgrade if you installed `ysp10`.** The
> published kernel enables IEP2 for the first time, which un-masked a
> long-standing defect: the driver never opted out of MPP's decoder-internal
> deinterlacer, which emits two frames per field pair with synthesized
> timestamps and cannot route through VA-API decode's 1:1 surface contract. On
> `ysp10` that made interlaced H.264 fail with `internal decoding error`;
> progressive content was unaffected. **`ysp12` disables that path and restores
> all 17 pinned conformance vectors to bit-exact on kernel `6.18.42`**
> (re-run 2026-08-04 on the installed package). `ysp11` was prepared with the
> picture-size change only, and was superseded before publication. Detail:
> [the regression finding](../findings/2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md).
| **`librga`** | 8-bit and 10-bit blit/scale/convert on both RGA3 cores and RGA2. | RGA3 will not accept a visible width below 68; RGA2 cannot read AFBC; over-4G buffers with ≥1 MiB exporter chunks fall back with `EOPNOTSUPP` rather than corrupting. Must match the kernel (§3.1). |
| **GNOME Remote Desktop** | RDP with hardware H.264 encode, full-range BT.709 signalling, bounded encode recovery. | Reconnect replay, sustained focus/resume, and compressed-audio interoperability remain unproven. Needs the PipeWire audio stack, not standalone PulseAudio. |

Not in the archive at all: **Kodi** (no source published, no build evidence),
any NPU runtime, any camera stack, and any browser package — browsers use the
distro build plus `rockchip-vaapi`, which the install script does **not** pull
in; install it explicitly if you want browser decode.

## 6. Evidence behind the claims

This is the part a support statement usually omits. Read it as the boundary of
every "supported" above.

| Claim | Strongest evidence | Date | What is still open |
|-------|--------------------|------|--------------------|
| The codec/RGA stack works end to end from a PPA install | Kernel `…20260723~rk1` (patch tail `0001`–`0071`) was installed from the PPA, booted, and passed the full conformance set plus root gates. | 2026-07-24 | That exact version is **superseded and no longer in the archive**. The pass does not transfer to a newer tail. |
| The currently Published kernel boots and decodes | `6.18.42-ysp-rockchip64` was installed and booted; **17/17 pinned VA-API conformance vectors are bit-exact** on it with the installed `ysp12` driver, including the interlaced `CABREF3_Sand_D.264` through VA-API. | 2026-08-04 | Only the tier-1 gate set ran. The 163-vector HEVC sweep, encode/10-bit gates, GStreamer suite, ABI replay, display gates, and both soaks did **not**. One 352x288 TFF clip is the whole interlaced guard. |
| AV1 decode is bit-exact | Hardware decode differential on the AV1 forward-port build. | 2026-07-04 | AV1 from MP4/MKV containers has not been re-tested since the extradata fix. |
| Rollback works | The operator has repeatedly used the documented SD rescue path and the exact `kernel-revert.sh` commands successfully ([dated finding](../findings/2026-08-04-forward-port-sd-rescue-rollback-used.md)). | 2026-08-04 | This is user-reported operational evidence without a retained identity/log bundle or an independent second-reader replay. Automatic boot fallback, clean migration, and stale-package cleanup are separate open gates. |
| Clean migration from an earlier test stack | The `clean-install-system-stack.sh` transaction is written and simulated. | — | The exact transaction has not passed a board gate. |

Two consequences worth stating plainly:

1. **The kernel that `apt` installs today has less validation behind it than the
   superseded July kernel that passed full conformance.** That is the normal
   state of a moving patch series, not an anomaly — but it means "the PPA kernel
   passed conformance" is a claim about a version you can no longer install.
2. **Rollback has an operator-validated SD rescue path.** The remaining package
   gates are the full current-kernel campaign and clean migration/cleanup, not
   whether the documented recovery mechanism works.

## 7. Compared with a Rockchip BSP distribution

"BSP distribution" here means an OS image built on Rockchip's downstream
`develop-6.1` kernel — Radxa's own Debian/Ubuntu images, or Armbian's `vendor`
branch, which *is* the BSP. That kernel is a product tree: measured against
stock Linux 6.1 it changes about **5,939 files and adds ~3.5M lines**.

### 7.1 Area by area

| Area | Rockchip BSP distribution | This PPA + forward-port kernel |
|------|---------------------------|-------------------------------|
| Kernel base | Linux **6.1** vendor branch, diverged from stable | Linux **6.18** LTS (projected EOL Dec 2028), Armbian `rockchip64-current`, mainline IOMMU/DMA/DRM cores |
| Distro userspace | Vendor image, often pinned and slow-moving | **Ubuntu 26.04** archive with its ordinary security updates; only FFmpeg, GNOME Remote Desktop, and Plymouth are replaced, the rest is added alongside |
| Video decode | H.264, HEVC, VP9, AVS2, AV1, **JPEG** | H.264, HEVC, VP9, AV1 (AVS2 present but untested). **No JPEG.** |
| Video encode | H.264, HEVC, **JPEG** | H.264, HEVC. **No JPEG.** |
| Deinterlacing | IEP2, long-standing | IEP2, added 2026-08-03, narrow evidence, not exposed through VA-API |
| 2D / RGA | RGA3 + RGA2 | RGA3 + RGA2, **plus 20 vendor RGA commits the 6.1 BSP never received** (§7.2) |
| Camera / ISP | Full sensor, CIF, CSI, ISP, ISPP, AIISP, VPSS stack | **None** |
| HDMI input | Supported | **None** |
| NPU | RKNPU driver + RKNN runtime | **None** |
| GPU | Vendor **Mali blob** kernel driver + matching proprietary userspace | Upstream **Mesa/Panfrost**, plus four open Mesa MRs from this project fixing a G610 blit-precision erratum |
| CPU power | Per-die PVTM/eFuse voltage binning, codec devfreq, system-monitor thermal coupling | Worst-die voltage table (+37.5–87.5 mV on 9/10 OPPs on this die), no codec devfreq |
| Peripherals | Large product inventory: Wi-Fi modules, touch, SerDes, CAN, LTE, vendor storage, Thunder Boot | Whatever mainline/Armbian provides |
| Userspace ABI | `/dev/mpp_service`, `/dev/rga`, RKNPU ioctls | **Same `/dev/mpp_service` and `/dev/rga` ABI** — vendor libmpp/librga run unmodified. No RKNPU. |
| Security/correctness posture | Vendor code as shipped | 25 defect fixes in code byte-identical to the BSP's, several unprivileged-reachable (§7.2) |
| Validation | Vendor-internal | Public: conformance harness, KASAN/lockdep/DMA-debug builds, bit-exact PSNR gates, ABI replay, IOMMU fuzzer, dated findings |

### 7.2 Where this stack is ahead of the BSP

The forward port is **≈90% Rockchip-authored code** (34,382 lines carried
verbatim from `develop-6.1`, 1,175 cherry-picked from `develop-5.10`, 3,978
ours). The 10% is where the advantage lives.

- **Twenty vendor RGA commits the 6.1 BSP never got.** Rockchip kept developing
  RGA on `develop-5.10` through June 2026 — hardware batching, RK3588
  low-voltage workarounds, `shadow_page` for cache-line-unaligned addresses,
  request-lifetime and IOMMU-prefetch fixes, CSC/scale/rotate/tile corrections.
  None of it reached `develop-6.1` or `develop-6.6`. **Anyone running the 6.1
  BSP is missing these.**
- **Twenty-five fixes for defects in Rockchip's own code** — 14 patches classed
  `BSP-BUG` plus an 11-patch audit port (`0058`–`0068`) — found under KASAN,
  lockdep, DMA-debug, and hostile-ioctl replay against code byte-identical to the
  BSP, so they are latent there too:
  - *Memory corruption / use-after-free*: register-translation OOB write over a
    `work_struct`; `SET_SESSION_FD` type confusion; a double
    `INIT_CLIENT_TYPE` that frees and then reads an `mpp_session`; RGA request
    double-drop; job-versus-session-close UAF; `RESET_SESSION` double-free.
    **Several are reachable by any process in the `video` group** — that is,
    by any user allowed to decode video.
  - *NULL-deref / hard lock*: client-less `RELEASE_FD`, and a device-less
    session on the wait-result path — the proven root cause of a VP9
    `show_existing_frame` board hard-lock.
  - *Bounds*: RCB register indexes, class request arrays, staged request tasks,
    physical import pages, multi-plane handles.
- **10-bit is actually correct.** The stock BSP misprograms P010/P210/NV15
  raster strides and plane offsets; this port computes them in bytes, in both
  RASTER and TILE layouts, and pairs the kernel with a matching `librga`.
- **AV1 on a mainline IOMMU.** The BSP has an AV1 MPP backend but **no VSI
  IOMMU driver at all**. This port adds the upstream-style Verisilicon IOMMU
  provider so AV1 decode works against the 6.18 IOMMU core rather than the
  vendor's private one.
- **Fail-closed hardening the BSP lacks**: RGA3 rejects a 16-misaligned IOMMU
  window base instead of silently returning zero pixels; the RGA2 page-table
  builder refuses above-4G entries with `EOPNOTSUPP` instead of programming a
  truncated page and bus-erroring.
- **A supported distro underneath.** Ubuntu 26.04 with archive security
  updates and an LTS kernel base, rather than a frozen vendor image on a 6.1
  branch — plus an open GPU stack that receives upstream Mesa fixes instead of
  a blob tied to specific userspace.
- **Public evidence.** Every claim above has a dated finding, a named test, and
  a reproduction path in this repository.

### 7.3 Where the BSP is ahead

Honest and unambiguous — if any of these matter, the BSP image is the better
choice:

- **Camera and ISP.** If you need MIPI CSI sensors, the ISP pipeline, or
  HDMI input capture, this stack has nothing.
- **NPU.** RKNN/RKLLM inference needs the vendor kernel driver. Not here.
- **Hardware JPEG.** Thumbnailing and MJPEG pipelines lose their accelerator.
- **CPU power efficiency.** Per-die voltage binning is real and measured: this
  board's silicon is entitled to 37.5–87.5 mV below what it will actually run
  at here on nine of ten non-trivial OPPs. Codec-core devfreq is also absent.
- **Peripheral breadth.** Wi-Fi modules, touch controllers, SerDes, CAN, LTE,
  vendor storage, and product boot/suspend behaviour are a vendor-kernel
  strength.
- **Someone to ask.** Rockchip and Radxa support their combination. Nobody
  supports this one.

### 7.4 The ABI is the same

The vendor MPP and RGA userspace ABIs are unchanged: `include/uapi/linux/rk-mpp.h`
and `rga.h` are byte-identical between Rockchip's 6.1 and 6.6 branches, and this
port preserves them. Vendor `libmpp`/`librga` builds, and applications written
against them, run without modification. Migrating between a BSP image and this
one is a kernel and distro decision, not an application-rewrite decision.

## 8. Known traps

| Trap | What happens | Where it is owned |
|------|--------------|-------------------|
| Kernel and `librga` installed separately | 10-bit TILE output is wrong by ~20% with no error | [W13](../status.md#watch-w13) |
| DKMS package on this kernel | Build fails `modpost … exported twice` | [`packaging/dkms/`](../packaging/dkms/README.md) |
| Missing `video` group or udev rule | MPP init fails even for a group peer, because `dma_heap` is denied | [`packaging/codec-udev/`](../packaging/codec-udev/README.md) |
| Intermittent Plymouth boot stall | Boot never reaches `sysinit.target`; needs a power cycle | [W20](../status.md#watch-w20) — mitigate with `plymouth.enable=0` |
| A third-party `ffmpeg` earlier in `PATH` | An FFmpeg build without the backpressure fix deadlocks `rkmpp` transcodes and looks like a kernel bug | [W21](../status.md#watch-w21) |
| VLC 3.x "hardware decoding" | Silently stays on software | §5 |
| Interlaced H.264 through VA-API on `ysp10` | `internal decoding error` once the kernel enables IEP2 | §5 — fixed in `ysp12`; upgrade rather than pin |

## 9. Installing

```bash
# clean Resolute system, no earlier test packages:
bash packaging/ppa/install-system-stack.sh

# machine already carrying FFmpeg 8.1 / rewrite-kernel / private test packages:
bash packaging/ppa/clean-install-system-stack.sh
```

Both scripts refuse a non-arm64 or non-Resolute host, keep the existing Armbian
kernel installed as a recovery option, and add the user to `video`. Neither
installs `rockchip-vaapi`; add it explicitly for browser and VLC decode.

**Prepare recovery before rebooting into the new kernel** —
[`install.md` §3](../install.md) is the runbook, and §6 above is why that
matters more here than on a distro kernel.

## 10. Boundary

- This page states **scope and support posture**. Dated validation state is
  [`status.md`](../status.md) (tracks 1, 9, and 14); live archive publication is
  [W05](../status.md#watch-w05); package-by-package detail is
  [`packaging/ppa/`](../packaging/ppa/README.md).
- Version strings and publication states in §2 were read from Launchpad on
  2026-08-04 and go stale silently. Re-read rather than trust.
- The BSP comparison rests on `rockchip-linux/kernel develop-6.1@b4ef083dc0c3`
  measured 2026-07-24, and on the area inventory in
  [`kernel-versions/bsp/`](../kernel-versions/bsp/README.md). It compares
  *kernels and what a distribution built on them can do* — it is not a
  benchmark, and no side-by-side performance measurement exists.
- What this repository has **not** assessed about the board at all is inventoried
  in [`support-coverage.md`](support-coverage.md). An area absent from this page
  is untested, not implicitly working.
