# packaging/ — the deploy hub

Everything that turns this repo's kernel + userspace work into installable
artifacts. If you just want codecs working, start with the delivery-model
chooser in [`../install.md`](../install.md); this page is for people **building,
shipping, or operating** the artifacts.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Choose and operate an install path: combined kernel, DKMS, codec udev rule, GDM greeter ACL package, local debs, or PPA packages. |
| Developer focus | Keep deploy artifacts reproducible and auditable: DKMS source staging, udev policy, PPA source packages, rollback, binary publishing, and package boundaries. |
| Owns | Packaging docs for `codec-udev/`, `gdm-hwenc/`, `dkms/`, `ppa/`, and the operations runbook for the rkmpp FFmpeg stack. |
| Depends on | Kernel-driver artifacts, userspace libraries, FFmpeg/GRD package sources, and the status gates recorded in [`../status.md`](../status.md). |
| Current state | Combined-kernel delivery is hardware-validated; DKMS is compile-tested only. The recreated system PPA publishes MPP, librga, codec access, FFmpeg 8.0.3, GRD, co-installable FFmpeg 6.1, and the forward-port kernel; four dedicated PPAs publish both FFmpeg 8.1 tracks and both rewrite kernels. The local maximum-mainline profiles build and package but remain unbooted. Optional GDM upload and board migration/kernel gates remain pending. See [../status.md](../status.md). |

## The four delivery channels

| # | Channel | Lives in | What it delivers | Status |
|---|---------|----------|------------------|--------|
| 1 | **Combined Armbian kernel** (`=y`) | [`../kernel-drivers/scripts/`](../kernel-drivers/scripts/README.md) + [`../kernel-drivers/patches/`](../kernel-drivers/patches/README.md) | Kernel debs with the vendor MPP + RGA drivers built in | Hardware-validated (see [`../status.md`](../status.md)) |
| 2 | **DKMS on a stock kernel** | [`dkms/`](dkms/README.md) | `rk_vcodec.ko` + `rga3.ko` rebuilt on every kernel update, + a boot-time DT overlay | Compile-tested on 6.18; overlay dtc-validated, **not boot-validated** |
| 3 | **Local `.debs`** | [`codec-udev/`](codec-udev/README.md), [`gdm-hwenc/`](gdm-hwenc/README.md), `dkms/build-deb.sh` | The udev/ACL rules and the DKMS deb, built on demand | Built + installed on the dev board |
| 4 | **Launchpad PPA** | [`ppa/`](ppa/README.md) | MPP + librga + FFmpeg RKMPP/RKRGA + published GRD and staged GDM packages; co-installable forward-port and alpha kernels | All intended main/dedicated sources and binaries are public. The forward-port kernel `…20260723~rk1` was installed from this PPA, booted, and passed the full conformance set plus root gates 2026-07-24; optional GDM and the alpha-kernel board gates remain pending. |

> **⚑ Hard rule: channels 1 and 2 are mutually exclusive.** Never run DKMS on a
> combined (`=y`) kernel — the build fails `modpost` with `'…' exported twice`.
> Pick one kernel-side channel; the mechanism and expected symptom are owned by
> [`dkms/README.md` § Caveats](dkms/README.md#caveats-read-before-relying-on-it).

> **The udev rule is needed in *all* cases.** No kernel channel makes
> `/dev/mpp_service` + `/dev/dma_heap/*` + `/dev/rga` usable without root —
> that is [`codec-udev/`](codec-udev/README.md)'s job (or the same rule via the
> other two ship methods it documents). Without the dma-heap grant the encoder
> dies at MPP init even as root's group peer — mechanism owned by
> [`codec-udev/README.md`](codec-udev/README.md#why-the-dma-heap-grant-is-required-the-get_group-trap).

## Directory index (hub contract)

| Path | One-liner |
|------|-----------|
| [`codec-udev/`](codec-udev/README.md) | `rk3588-codec-udev` deb: the `video`-group udev rule for `mpp_service`/`dma_heap`/`rga` (canonical rule: [`../kernel-drivers/scripts/99-rockchip-codec.rules`](../kernel-drivers/scripts/99-rockchip-codec.rules), copied at build time) |
| [`dkms/`](dkms/README.md) | `rk3588-vcodec-dkms` deb: out-of-tree DKMS build of the vendor drivers + boot-time DT overlay, for **stock** kernels |
| [`ffmpeg-rockchip81/`](ffmpeg-rockchip81/README.md) | `ffmpeg-rockchip81` deb: self-contained `/opt` runtime package for the local `ffmpeg-rockchip-81` forward-port tree |
| [`gdm-hwenc/`](gdm-hwenc/README.md) | `gnome-remote-desktop-gdm-hwenc` deb: opt-in `setfacl g:gdm` udev rule so the **GDM greeter** hardware-encodes too |
| [`ppa/`](ppa/README.md) | Launchpad packaging and six-archive live state for public MPP/librga/FFmpeg/GRD/kernel packages plus staged GDM, the reproducible export helper, and the dated upload log. |
| [`docs/`](docs/armbian-packaging.md) | The Armbian `media-0001` conflict + the convert-in-place / self-contained DT strategies ([`armbian-packaging.md`](docs/armbian-packaging.md)); and Armbian **patch precedence** — why you can't disable a core patch from userpatches ([`armbian-patch-precedence.md`](docs/armbian-patch-precedence.md)). |
| [`external-workspaces.md`](external-workspaces.md) | Inventory and disposition for packaging/build artifacts in sibling `~/Code` workspaces: what is canonical source here, what is generated output, and what stays outside git. |

## Operations runbook — running the rkmpp FFmpeg stack

Recorded from operating the older drop-in FFmpeg `8.1.2+rkmpp1` local debs on
the dev board (source: the `~/Code/gnome/grd/grd-debs` deployment,
2026-06-30). The same package-management mechanics apply to a PPA install, but
the published dedicated-PPA `ffmpeg-rockchip-81` package has newer library package names
(`libavcodec63`, `libavutil61`, `libavformat63`, `libavfilter12`,
`libavdevice63`, `libswscale10`, `libswresample7`).

### Pin, or Ubuntu will silently take it back

The rkmpp FFmpeg keeps Ubuntu's epoch (`7:`) and a version above stock, so it
upgrades in place — but a future Ubuntu FFmpeg with a higher version can
supersede it on a routine `apt upgrade`. Hold the installed seven runtime libs
(+ the codec libs):

```bash
# Current published dedicated-PPA ffmpeg-rockchip-81 package:
sudo apt-mark hold libavutil61 libavcodec63 libavformat63 libavdevice63 \
                   libavfilter12 libswscale10 libswresample7
# Older local-deb ABI, if that is what you installed:
# sudo apt-mark hold libavutil60 libavcodec62 libavformat62 libavdevice62 \
#                    libavfilter11 libswscale9 libswresample6
# plus the codec libs of whichever era you installed:
#   PPA:        librockchip-mpp1 librga2
#   local-deb:  rockchip-codec-libs
```

### Exact rollback to stock Ubuntu FFmpeg (older libav*62 set)

For the current published `ffmpeg-rockchip-81` package, an ABI-63-to-ABI-62
rollback still needs an on-board transaction test before this runbook prescribes
it. The older local
drop-in set rolled back with:

```bash
sudo apt-mark unhold libavutil60 libavcodec62 libavformat62 libavdevice62 \
                     libavfilter11 libswscale9 libswresample6
sudo apt install --allow-downgrades \
  libavutil60=7:8.0.1-3ubuntu2 libavcodec62=7:8.0.1-3ubuntu2 \
  libavformat62=7:8.0.1-3ubuntu2 libavdevice62=7:8.0.1-3ubuntu2 \
  libavfilter11=7:8.0.1-3ubuntu2 libswscale9=7:8.0.1-3ubuntu2 \
  libswresample6=7:8.0.1-3ubuntu2
```

### What installing removes (local-deb era only)

Installing the **local** `+rkmpp1` runtime debs removed the five installed
FFmpeg `-dev` packages (`libavcodec-dev`, `libavformat-dev`, `libavutil-dev`,
`libswresample-dev`, `libswscale-dev`) — those were build-time headers only;
**no application is removed** (apps depend on the runtime libs, which upgrade
in place). The PPA build produces the full `-dev` set, so via the PPA the
`-dev` packages upgrade instead of vanishing.

### Player caveat — rkmpp decoders are standalone AVCodecs *(canonical copy)*

The rkmpp decoders are standalone decoders, **not an `AVHWAccel`** — generic
"enable hardware decoding" toggles will not find them; players must select the
decoder explicitly:

- **mpv**: `mpv --vid=auto --hwdec=rkmpp` or `--vd=h264_rkmpp`
- **VLC 3.x**: cannot use them — it does not expose per-decoder selection.
- **ffmpeg CLI**: `-c:v h264_rkmpp` before the input for decode; as the encoder
  name for encode.

(Referenced from [`video-libraries/ffmpeg/README.md`](../video-libraries/ffmpeg/README.md); this is the
canonical statement.)

### Verify the stack end-to-end

```bash
ffmpeg -hide_banner -encoders | grep rkmpp     # h264_rkmpp, hevc_rkmpp
ffmpeg -hide_banner -decoders | grep rkmpp     # h264/hevc/vp8/vp9_rkmpp
ffmpeg -f lavfi -i testsrc=size=1280x720:rate=30 -frames:v 60 -c:v h264_rkmpp out.h264
```

Requires the [`codec-udev/`](codec-udev/README.md) rule and `video`-group
membership; deeper tests in [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md).

## History — packaging roads not taken

Four iterations in two days (on-disk artifacts dated 2026-06-29/30), kept here
so nobody re-walks them:

1. **Hand-split codec-libs deb** (`rockchip-codec-libs_1.3.9+grd1`): an
   unversioned `librga.so` (prebuilt airockchip librga 1.10.6) + a hand-built
   MPP 1.3.9 (`rockchip-linux/mpp @c2c1ee5`) in one deb — the one
   **non-reproducible** piece of the early stack. Replaced by the PPA's
   ecosystem-standard `librockchip-mpp1` / `librga2` source packages.
2. **GRD-private bundled ffmpeg-rockchip** (built 2026-06-29): a shared-lib
   ffmpeg-rockchip (fork tip `40c412dacc`, `--enable-shared --enable-rkmpp
   --enable-rkrga --disable-vulkan`) installed under a private prefix
   `/usr/lib/gnome-remote-desktop/ffmpeg-rk`, produced
   `gnome-remote-desktop_50.1+rkmpp1_arm64.deb`. Abandoned within a day: the
   build carried an rpath into dev-box staging directories (not
   redistributable as-is), and a private copy accelerates **only GRD** where
   the drop-in gives every FFmpeg consumer rkmpp.
3. **Two self-contained vendored-FFmpeg GRD flavours** (2026-06-30, in
   `~/Code/gnome/grd/grd-debs`): `50.1+rkmpp.rk1` vendoring **ffmpeg-rockchip 6.1**
   (libavcodec 60, fixed-QP `qp_init`, rkrga filters) and `50.1+rkmpp.main1`
   vendoring **mainline 8.1.2** (libavcodec 62, VBR) — each loading its FFmpeg
   from a private dir via `LD_LIBRARY_PATH` in the systemd unit, fully
   independent of the system FFmpeg. The **isolation-vs-drop-in trade-off**:
   flavours can't break other apps but help only GRD and double the
   maintenance; the encoder-behaviour difference between the two is the
   ffmpeg-rockchip-vs-upstream comparison in
   [`video-libraries/ffmpeg/docs/implementation-comparison.md`](../video-libraries/ffmpeg/docs/implementation-comparison.md).
4. **System-wide ABI drop-in + PPA.** The first PPA design used upstream FFmpeg
   8.1.2 with `--enable-rkmpp`, keeping the same SONAME majors as Ubuntu's
   8.0.1. The current first-wave PPA work keeps the source-package model but
   points FFmpeg at the local `ffmpeg-rockchip-81` forward-port, whose ABI is
   recorded in [`ppa/`](ppa/README.md).

## Binary policy

**No built binaries in git, ever.** Verified: `git ls-files | grep -E
'\.(deb|ko|dtbo|so)$'` is empty; any on-disk `.deb`s in `codec-udev/` or
`gdm-hwenc/`, and the whole `dkms/build/` staging tree, are build residue
covered by the per-subdir `.gitignore`s (the root
[`../.gitignore`](../.gitignore) points here).
The broader artifact policy for sibling build workspaces is tracked in
[`external-workspaces.md`](external-workspaces.md).

- Commit the **source** (`root/DEBIAN/*`, `build-deb.sh`, `dkms.conf`,
  Kbuilds, overlay `.dts`); build artifacts on demand.
- Built `.deb`s intended for others are published as **GitHub Releases
  assets** on [`yisding/rock-5b-ysp`](https://github.com/yisding/rock-5b-ysp),
  tagged with the kernel `PHASH` (see [`../install.md`](../install.md)) or the
  package version, with `sha256sum`s in the release notes, and linked from
  this README. *(None published yet; record the first release here when cut.)*
- `dkms/build/` is disposable output: `bash dkms/build-deb.sh clean` removes it.
- [`../kernel-drivers/scripts/99-rockchip-codec.rules`](../kernel-drivers/scripts/99-rockchip-codec.rules)
  stays the **single canonical** udev rule — read the rule body there, never
  transcribe it. `codec-udev/build-deb.sh` copies it at build time (the copy
  under `codec-udev/root/…` is gitignored); [`codec-udev/README.md`](codec-udev/README.md)
  owns *why* each line is needed (especially the required `dma_heap` grant).

## Remaining PPA gates

The PPA source packaging for `mpp`, `librga`, `ffmpeg`, GRD, the optional
GDM greeter ACL package, and the co-installable forward-port kernel is now in this repo under
[`ppa/`](ppa/README.md), along with the source-export helper and the 2026-07-06
upload log. The main system stack and all four dedicated FFmpeg/kernel tracks
have Published source and binary packages. The remaining gates are the exact
clean-migration board transaction, board install/reboot/revert validation for
[`ppa/kernel-forward-port/`](ppa/kernel-forward-port/README.md), alpha-kernel
hardware validation, and the optional GDM ACL upload.
Generated source packages, orig tarballs, signed `.changes`, `.deb`s, and
Launchpad credentials stay out of git by policy.

## See also

- [`../install.md`](../install.md) — the end-to-end chooser + quickstart.
- [`armbian-packaging.md`](./docs/armbian-packaging.md) — the
  Armbian `media-0001` conflict and the convert-in-place / self-contained DT
  strategies that the kernel channels rely on.
- [`armbian-patch-precedence.md`](./docs/armbian-patch-precedence.md) — the
  patcher mechanics: why an empty userpatch can't disable a core patch on glob
  branches, the workarounds, the ~2-line fix, and series-vs-glob.
- [`../kernel-drivers/docs/resyncing.md`](../kernel-drivers/docs/resyncing.md) — the kernel-bump
  checklist; `dkms/` is a second consumer of every resync fix.
- [`../glossary.md`](../glossary.md) — IEP, PHASH, "combined kernel" vs
  "DKMS", and the rest of the vocabulary used above.
