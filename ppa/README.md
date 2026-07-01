# ppa/ — packaging the whole userspace stack for a Launchpad PPA

The kernel side of this repo ships as Armbian userpatches + standalone `.debs`
([`packaging/`](../packaging/)). The **userspace** side — the MPP + RGA libraries,
a rkmpp-enabled FFmpeg, and gnome-remote-desktop — is packaged as **source
packages for a personal Launchpad PPA**, so Launchpad builds them on its arm64
builders and `apt` installs the whole stack with dependencies resolved.

Everything targets **resolute** (Ubuntu 26.04 base; Armbian's userspace) on
**arm64**. The upload-ready artifacts live at **`~/Code/grd-ppa/`** with a
step-by-step runbook (`UPLOAD.md`); this document is the *why and how they were
built*.

> **Why a PPA and not the local `.debs`?** Early on the codec libs were a
> hand-split `rockchip-codec-libs` deb (an unversioned `librga.so` + a hand-built
> MPP blob — the one non-reproducible piece). The PPA replaces that with the
> **ecosystem-standard** `librockchip-mpp1` / `librga2` packages plus proper
> FFmpeg and GRD source packages, all built reproducibly on Launchpad.

## The five packages

| # | Source | Version | Builds | Upstream / basis |
|---|--------|---------|--------|------------------|
| 1 | `mpp` | `1.5.0-1+rk1` | `librockchip-mpp1`, `-dev`, `librockchip-vpu0`, `rockchip-mpp-demos` | [`tsukumijima/mpp-rockchip`](https://github.com/tsukumijima/mpp-rockchip) `@750e76e` (tracks HermanChen `develop`) |
| 2 | `librga` | `2.2.0-1+rk1` | `librga2` (+ unversioned `librga.so`), `librga-dev` | [`tsukumijima/librga-rockchip`](https://github.com/tsukumijima/librga-rockchip) (JeffyCN lineage) |
| 3 | `ffmpeg` | `7:8.1.2-1+rk1` | `libavcodec62` (+`-extra`), the full Ubuntu `libav*` set, `ffmpeg` — **with `h264_rkmpp`** | Ubuntu's `ffmpeg` source, upstream bumped `8.0.1 → 8.1.2` |
| 4 | `gnome-remote-desktop` | `50.1+rkmpp-2` | `gnome-remote-desktop` (rkmpp encode backend) | our fork vendored as upstream + Ubuntu's `50.0` packaging |
| 5 | `gnome-remote-desktop-gdm-hwenc` | `1.0` | `gnome-remote-desktop-gdm-hwenc` (opt-in greeter ACL) | native; [`packaging/gdm-hwenc/`](../packaging/gdm-hwenc/) |

All are `3.0 (quilt)` except `gdm-hwenc` (`3.0 (native)`). Version convention:
**`+rk1`** sorts above the stock revision; FFmpeg keeps Ubuntu's **epoch `7:`** so
`7:8.1.2-1+rk1` upgrades in place over `7:8.0.1-3ubuntu2`.

## How each was built

### 1–2. `mpp` + `librga` — the codec libraries

Built straight from the **tsukumijima** Debian formulas (clean `debian/`, CI-built,
track a Rockchip-maintained MPP `develop` branch). The only work was making them
build on **resolute / GCC-15**, which promotes several warnings to errors that
older CI toolchains didn't:

```make
# debian/rules — mpp (and similarly librga)
DEB_CFLAGS_MAINT_APPEND = -Wno-error=incompatible-pointer-types \
                          -Wno-error=implicit-function-declaration \
                          -Wno-error=int-conversion -Wno-error=implicit-int
```

`mpp` yields `librockchip_mpp.so.1` (NEEDED: libc/libm only; max `GLIBC_2.38`).
`librga` yields `librga.so.2` **and** ships the unversioned `librga.so` symlink so
it also satisfies the `ffmpeg-rockchip` fork if you build that too. `librga` had no
`debian/source/format`; added `3.0 (quilt)`.

> Both were proven by encoding 60 frames through the built libs with our system
> FFmpeg (`ffprobe`-clean), before packaging.

### 3. `ffmpeg` — upstream FFmpeg 8.1.2 + rkmpp, as an in-place upgrade

The goal was a **drop-in** over Ubuntu's `ffmpeg` so every app gets rkmpp. 8.1.2
and 8.0.1 are both FFmpeg 8.x, so the seven library SONAME majors are identical
(`libavcodec.so.62`, `libavutil.so.60`, …) → ABI-compatible.
The trade-off versus `ffmpeg-rockchip` is documented in
[`../ffmpeg/IMPLEMENTATION-COMPARISON.md`](../ffmpeg/IMPLEMENTATION-COMPARISON.md):
upstream FFmpeg 8.1.2 keeps ABI compatibility but lacks ffmpeg-rockchip's RGA
filters and richer rkmpp encoder controls.

```bash
apt-get source ffmpeg                      # Ubuntu 7:8.0.1-3ubuntu2 (no debian/patches to rebase)
# drop in the official ffmpeg-8.1.2 orig tarball as the new upstream
```
Two `debian/` deltas:
- **`debian/rules`** — add rkmpp to the *shared* config (the "extra" flavour
  already had `version3`; the standard flavour that builds `libavcodec62` did not):
  ```make
  CONFIG += --enable-rkmpp --enable-version3
  ```
- **`debian/control`** — `Build-Depends: … librockchip-mpp-dev [linux-any]`.

License resolves to **GPL-3** (rkmpp's `version3` requirement). The `*.symbols`
files are templated/auto-extending, and 8.1.2 only *adds* symbols within SONAME
62, so the symbol diffs are non-fatal. Builds the full Ubuntu package set.

### 4. `gnome-remote-desktop` — the backend, vendored as upstream

There is no separate "upstream tarball" for our work, so we **vendored our fork
branch as the upstream**:

- `orig` = `git archive` of the `ffmpeg-rkmpp-encode-backend` branch (GRD 50.1 +
  the [encode backend](../gnome-remote-desktop/patches/)).
- Grafted **Ubuntu's `50.0` `debian/`** on top; dropped Ubuntu's three patches
  (all upstream in 50.1); enabled `-Dffmpeg=enabled` and added
  `libavcodec-dev`/`libavutil-dev (>= 7:8.1.2~)` to `Build-Depends` (stock Ubuntu
  builds GRD with the ffmpeg feature *off*); switched fdk-aac on.
- The **backend lives in the `orig`**; only the two runtime changes ride as
  `debian/patches` (`3.0 quilt`): the **upstream-rkmpp fix** and a **revert** of a
  cherry-picked handover-reconnect change that broke GDM→session handover. (That
  revert exists only because the `orig` snapshot happened to include the
  cherry-pick — see the [patches note](../gnome-remote-desktop/patches/README.md).)

### 5. `gnome-remote-desktop-gdm-hwenc` — the greeter ACL

A tiny native package; documented and buildable standalone at
[`packaging/gdm-hwenc/`](../packaging/gdm-hwenc/). Independent of the others
(depends only on `acl`).

## Upload order — respect the build-dep chain

Launchpad does **not** auto-retry a build that fails on a missing build-dep, and
can only use a PPA package as a build-dep **after it has finished publishing**
(minutes to ~1 h each). So upload in waves:

```
Wave A  mpp, librga            (no internal deps)
          └─ wait for librockchip-mpp-dev to publish (arm64)
Wave B  ffmpeg                 (build-deps on librockchip-mpp-dev)
          └─ wait for libavcodec-dev 7:8.1.2-1+rk1 to publish
Wave C  gnome-remote-desktop   (build-deps on libavcodec-dev >= 7:8.1.2~)
Wave D  gnome-remote-desktop-gdm-hwenc   (independent — any time)
```

The full runbook — one-time Launchpad/GPG setup, `debsign`, `dput`, and
per-package confidence notes — is **`~/Code/grd-ppa/UPLOAD.md`**. The staged
artifacts there are **source-only and unsigned**: you sign them with your own GPG
key (registered on Launchpad) and `dput`.

## Install (once published)

```bash
# Wave A/B publish first; then a single apt line pulls the stack + GRD:
sudo apt install librockchip-mpp1 librga2 ffmpeg gnome-remote-desktop
sudo apt install gnome-remote-desktop-gdm-hwenc   # optional: HW-encode the login screen
```

`mpp`/`librga`/`ffmpeg` are useful well beyond GRD (Jellyfin, mpv, …); GRD is just
the first consumer that needed the whole chain at once.

## Status

`mpp` and `librga` were binary-built on resolute (high confidence). `ffmpeg` and
`gnome-remote-desktop` are configure/compile-proven and round-trip-verified as
source packages, but not yet sbuild-tested in a clean chroot. Nothing has been
`dput` — the PPA, GPG key, and upload are the maintainer's to run.
