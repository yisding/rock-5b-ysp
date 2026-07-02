# packaging/ — the deploy hub

Everything that turns this repo's kernel + userspace work into installable
artifacts. If you just want codecs working, start with the delivery-model
chooser in [`../install.md`](../install.md); this page is for people **building,
shipping, or operating** the artifacts.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Choose and operate an install path: combined kernel, DKMS, codec udev rule, GDM greeter ACL package, local debs, or future PPA packages. |
| Developer focus | Keep deploy artifacts reproducible and auditable: DKMS source staging, udev policy, PPA source packages, rollback, binary publishing, and package boundaries. |
| Owns | Packaging docs for `codec-udev/`, `gdm-hwenc/`, `dkms/`, `ppa/`, and the operations runbook for the rkmpp FFmpeg stack. |
| Depends on | Kernel-driver artifacts, userspace libraries, FFmpeg/GRD package sources, and the status gates recorded in [`../status.md`](../status.md). |
| Current state | Combined-kernel delivery is hardware-validated; DKMS is compile-tested only; PPA source packages built locally but have not been uploaded. |

## The four delivery channels

| # | Channel | Lives in | What it delivers | Status |
|---|---------|----------|------------------|--------|
| 1 | **Combined Armbian kernel** (`=y`) | [`../kernel-drivers/scripts/`](../kernel-drivers/scripts/README.md) + [`../kernel-drivers/patches/`](../kernel-drivers/patches/README.md) | Kernel debs with the vendor MPP + RGA drivers built in | Hardware-validated (see [`../status.md`](../status.md)) |
| 2 | **DKMS on a stock kernel** | [`dkms/`](dkms/README.md) | `rk_vcodec.ko` + `rga3.ko` rebuilt on every kernel update, + a boot-time DT overlay | Compile-tested on 6.18; overlay dtc-validated, **not boot-validated** |
| 3 | **Local `.debs`** | [`codec-udev/`](codec-udev/README.md), [`gdm-hwenc/`](gdm-hwenc/README.md), `dkms/build-deb.sh` | The udev/ACL rules and the DKMS deb, built on demand | Built + installed on the dev board |
| 4 | **Launchpad PPA** (userspace) | [`ppa/`](ppa/README.md) | MPP + librga + FFmpeg 8.1.2+rkmpp + GRD as source packages Launchpad builds | Local arm64 binary builds succeeded 2026-06-30; **nothing `dput` yet** |

> **Hard rule: channels 1 and 2 are mutually exclusive.** On a kernel that
> already has the drivers `=y` (the combined kernel), the DKMS build fails
> `modpost` with `'…' exported twice` — the module's exports clash with
> vmlinux. Pick one kernel-side channel. Details:
> [`dkms/README.md`](dkms/README.md) caveat 1.

> **The udev rule is needed in *all* cases.** No kernel channel makes
> `/dev/mpp_service` + `/dev/dma_heap/*` + `/dev/rga` usable without root —
> that is [`codec-udev/`](codec-udev/README.md)'s job (or the same rule via the
> other two ship methods it documents). Without the dma-heap grant the encoder
> dies at MPP init even as root's group peer — see
> [`../docs/gotchas.md`](../docs/gotchas.md).

## Directory index (hub contract)

| Path | One-liner |
|------|-----------|
| [`codec-udev/`](codec-udev/README.md) | `rk3588-codec-udev` deb: the `video`-group udev rule for `mpp_service`/`dma_heap`/`rga` (canonical rule: [`../kernel-drivers/scripts/99-rockchip-codec.rules`](../kernel-drivers/scripts/99-rockchip-codec.rules), copied at build time) |
| [`dkms/`](dkms/README.md) | `rk3588-vcodec-dkms` deb: out-of-tree DKMS build of the vendor drivers + boot-time DT overlay, for **stock** kernels |
| [`gdm-hwenc/`](gdm-hwenc/README.md) | `gnome-remote-desktop-gdm-hwenc` deb: opt-in `setfacl g:gdm` udev rule so the **GDM greeter** hardware-encodes too |
| [`ppa/`](ppa/README.md) | The five Launchpad source packages (mpp, librga, ffmpeg, GRD, gdm-hwenc): design, build notes, upload waves. *(Moved here from `ppa/` 2026-07.)* |

## Operations runbook — running the rkmpp FFmpeg stack

Recorded from operating the drop-in FFmpeg `8.1.2+rkmpp1` local debs on the
dev board (source: the `~/Code/grd-debs` deployment, 2026-06-30); the same
mechanics apply to the PPA's `7:8.1.2-1+rk1` set.

### Pin, or Ubuntu will silently take it back

The rkmpp FFmpeg keeps Ubuntu's epoch (`7:`) and a version above stock
(`7:8.1.2…` > `7:8.0.1-3ubuntu2`), so it upgrades in place — but a **future
Ubuntu `7:8.1.x`** would sort above it and supersede it on a routine
`apt upgrade`. Hold the seven runtime libs (+ the codec libs):

```bash
sudo apt-mark hold libavutil60 libavcodec62 libavformat62 libavdevice62 \
                   libavfilter11 libswscale9 libswresample6
# plus the codec libs of whichever era you installed:
#   PPA:        librockchip-mpp1 librga2
#   local-deb:  rockchip-codec-libs
```

### Exact rollback to stock Ubuntu FFmpeg

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
in place). The PPA build *does* produce the full `-dev` set
(seven `-dev` debs in the 2026-06-30 local build), so via the PPA the `-dev`
packages upgrade instead of vanishing.

### Player caveat — rkmpp decoders are standalone AVCodecs *(canonical copy)*

The rkmpp decoders are standalone decoders, **not an `AVHWAccel`** — generic
"enable hardware decoding" toggles will not find them; players must select the
decoder explicitly:

- **mpv**: `mpv --vid=auto --hwdec=rkmpp` or `--vd=h264_rkmpp`
- **VLC 3.x**: cannot use them — it does not expose per-decoder selection.
- **ffmpeg CLI**: `-c:v h264_rkmpp` before the input for decode; as the encoder
  name for encode.

(Referenced from [`../ffmpeg/README.md`](../ffmpeg/README.md); this is the
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
   `~/Code/grd-debs`): `50.1+rkmpp.rk1` vendoring **ffmpeg-rockchip 6.1**
   (libavcodec 60, fixed-QP `qp_init`, rkrga filters) and `50.1+rkmpp.main1`
   vendoring **mainline 8.1.2** (libavcodec 62, VBR) — each loading its FFmpeg
   from a private dir via `LD_LIBRARY_PATH` in the systemd unit, fully
   independent of the system FFmpeg. The **isolation-vs-drop-in trade-off**:
   flavours can't break other apps but help only GRD and double the
   maintenance; the encoder-behaviour difference between the two is the
   ffmpeg-rockchip-vs-upstream comparison in
   [`../ffmpeg/docs/implementation-comparison.md`](../ffmpeg/docs/implementation-comparison.md).
4. **Final: system-wide ABI drop-in + PPA.** Upstream FFmpeg 8.1.2 with
   `--enable-rkmpp` has the same seven SONAME majors as Ubuntu's 8.0.1, so it
   replaces the system libs in place — first as local `+rkmpp1` debs, then as
   the [`ppa/`](ppa/README.md) source packages so Launchpad builds them
   reproducibly.

## Binary policy

**No built binaries in git, ever.** Verified: `git ls-files | grep -E
'\.(deb|ko|dtbo|so)$'` is empty; the on-disk `.deb`s in `codec-udev/` and
`gdm-hwenc/` and the whole `dkms/build/` staging tree are build residue covered
by the per-subdir `.gitignore`s (the root [`../.gitignore`](../.gitignore)
points here).

- Commit the **source** (`root/DEBIAN/*`, `build-deb.sh`, `dkms.conf`,
  Kbuilds, overlay `.dts`); build artifacts on demand.
- Built `.deb`s intended for others are published as **GitHub Releases
  assets** on [`yisding/rock-5b-ysp`](https://github.com/yisding/rock-5b-ysp),
  tagged with the kernel `PHASH` (see [`../install.md`](../install.md)) or the
  package version, with `sha256sum`s in the release notes, and linked from
  this README. *(None published yet — TODO when the first release is cut.)*
- `dkms/build/` is disposable output: `bash dkms/build-deb.sh clean` removes it.
- [`../kernel-drivers/scripts/99-rockchip-codec.rules`](../kernel-drivers/scripts/99-rockchip-codec.rules)
  stays the **single canonical** udev rule; `codec-udev/build-deb.sh` copies it
  at build time (the copy under `codec-udev/root/…` is gitignored). For
  reference, the substance of the rule:

  ```udev
  KERNEL=="mpp_service", GROUP="video", MODE="0660"
  KERNEL=="rga",         GROUP="video", MODE="0660"
  KERNEL=="iep",         GROUP="video", MODE="0660"   # BSP-only node; not created by this port
  SUBSYSTEM=="dma_heap",  GROUP="video", MODE="0660"  # REQUIRED — see codec-udev/README.md
  ```

## Still only on the dev box (import plan)

The five PPA source packages' full `debian/` trees, `.dsc`/orig tarballs, and
the `UPLOAD.md` signing/dput runbook live in the **unversioned** `~/Code/grd-ppa/`
— a fresh clone of this repo cannot rebuild the PPA packages from
[`ppa/README.md`](ppa/README.md)'s quoted fragments alone. **Plan:** import the
five `debian/` trees + `UPLOAD.md` into `ppa/` (source-only — orig tarballs are
fetched or `git archive`d per the recipes there). Tracked in
[`../status.md`](../status.md); described in detail in
[`ppa/README.md`](ppa/README.md) §Import plan.

## See also

- [`../install.md`](../install.md) — the end-to-end chooser + quickstart.
- [`armbian-packaging.md`](./docs/armbian-packaging.md) — the
  Armbian `media-0001` conflict and the convert-in-place DT trick that both
  kernel channels rely on.
- [`../kernel-drivers/docs/resyncing.md`](../kernel-drivers/docs/resyncing.md) — the kernel-bump
  checklist; `dkms/` is a second consumer of every resync fix.
- [`../glossary.md`](../glossary.md) — IEP, PHASH, "combined kernel" vs
  "DKMS", and the rest of the vocabulary used above.
