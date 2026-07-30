# External Packaging Workspaces

Last full workspace audit: 2026-07-09. Individual source-pin rows were rechecked
later where noted by their linked project/source records; this page inventories
workspace disposition rather than duplicating those projects' current state.

This repo is the source of truth for authored packaging, scripts, patch series,
and reproducibility manifests. Sibling `~/Code` directories are allowed to hold
upstream checkouts, build worktrees, caches, generated source packages, local
`.deb`s, test media, and board backups, but those artifacts must not become
implicit source.

## Policy

- Track text source in `rock-5b-ysp`: Debian packaging, shell/Python scripts,
  patch series, config fragments, manifests, and docs.
- Do not track generated package output: `.deb`, `.ddeb`, `.dsc`, `.changes`,
  `.buildinfo`, `.orig.tar.*`, `.debian.tar.*`, kernel `.ko`, DTB/DTBO, images,
  raw board backups, or source-package work directories.
- If a generated binary is hard to reproduce and worth preserving, publish it
  outside this source repo, with a checksum and provenance note here.
- Do not vendor whole upstream source trees into this repo. Record the path,
  commit, dirty delta, or patch set needed to reconstruct them.

## Canonical Source Locations

| Area | Canonical source in this repo | External inputs used to build/export |
|------|-------------------------------|--------------------------------------|
| Armbian kernel build scripts | [`../kernel-drivers/scripts/`](../kernel-drivers/scripts/README.md) | `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/armbian-build` clone and caches |
| Non-AV1 validated kernel patch pair | [`../kernel-drivers/patches/`](../kernel-drivers/patches/README.md) | `linux-6.18-rkvenc*` development trees |
| AV1/RK3588 forward-port patch series | [`../kernel-drivers/patches/forward-port-rk3588/`](../kernel-drivers/patches/forward-port-rk3588/README.md) | `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/forward-port/patches/` |
| Debug Armbian config | [`../kernel-drivers/scripts/debug-kernel/config-rock5b-debug-kernel.conf.sh`](../kernel-drivers/scripts/debug-kernel/config-rock5b-debug-kernel.conf.sh) | formerly only in `armbian-build/userpatches/` |
| PPA source packaging | [`ppa/`](ppa/README.md) | upstream/checkouts named by `ppa/build-source-packages.sh` |
| Local native packages | [`codec-udev/`](codec-udev/README.md), [`gdm-hwenc/`](gdm-hwenc/README.md), [`dkms/`](dkms/README.md) | generated `.deb`s are rebuild output only |
| Conformance/test harness source | [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md) and `../kernel-drivers/tests/conformance/` | `/home/yi/Code/rock-5b/rockchip-conformance` deployed bundle |

## External Workspace Disposition

| External path | Current disposition |
|---------------|---------------------|
| `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build` | Scratch workspace, about `44G` at audit time. `armbian-build/cache` and `armbian-build/output` dominate it. Keep outside git. |
| `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/forward-port/patches` | Imported as source text to `kernel-drivers/patches/forward-port-rk3588/`. |
| `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/forward-port/fallback` | Generated fallback `.deb`s. Do not copy into git. |
| `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/forward-port/official-src` | Downloaded official Armbian `.deb`s. Do not copy into git. |
| `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/armbian-build/userpatches/config-rock5b-debug-kernel.conf.sh` | Imported to `kernel-drivers/scripts/debug-kernel/`; the wrapper deploys it back into `userpatches/` at build time. |
| `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/armbian-build/userpatches/customize-image.sh` | Stock Armbian example/template, not project source. Leave outside. |
| `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/ffmpeg-stack` | Legacy test/runtime staging and media, not canonical source. Current test scripts live in `kernel-drivers/tests/`. |
| `/home/yi/Code/rock-5b/ffmpeg/ffmpeg-rockchip-81` | Upstream/fork source checkout pinned by `ppa/build-source-packages.sh`. Its untracked `kernel-drivers/tests/ffmpeg-suite.sh` copy is older than the ysp suite; do not import. |
| `/home/yi/Code/rock-5b/ffmpeg/ffmpeg-ppa` | Old FFmpeg source-package export/build directory with generated package residue. Canonical packaging is `ppa/ffmpeg/` and `ppa/ffmpeg-baseline/`. |
| `/home/yi/Code/rock-5b/gnome/grd/gnome-remote-desktop` | GRD fork checkout used by the PPA helper. The current clean export pin is public branch `yding/release/50.2-rkmpp@c4ef3c96194038e737be0857519ff77227279292`, based on latest GNOME 50 stable commit `18cc5f7`; its final two commits promote the runtime-verified full-range BT.709 AVC signaling fix and retain only the safe, reassigned-user-display part of the June reconnect-timeout cleanup. Historical reconnect, recovery, readback, focus, and audio experiment tips are preserved once in [`../docs/source-trees.md` §5](../docs/source-trees.md#5-gnome-remote-desktop-base) and the [`patches/archive/`](../apps/gnome-remote-desktop/patches/archive/README.md); the exact published `~exp3` source is also recoverable from Launchpad publication `18626586`. Generated build trees stay outside this repo. |
| `/home/yi/Code/rock-5b/gnome/grd/grd-ffmpeg` | Historical GRD backend checkout. Its July 6 dirty tracked-file delta is preserved under `ppa/gnome-remote-desktop/source-deltas/`; it is no longer the default PPA source. Generated shaders/build dirs stay outside. |
| `/home/yi/Code/rock-5b/gnome/grd/grd-pkg` and `/home/yi/Code/rock-5b/gnome/grd/grd-ppa` | Historical local package/source-package exports and generated `.deb`s. Canonical packaging is in `ppa/gnome-remote-desktop/`, `ppa/gdm-hwenc/`, and `gdm-hwenc/`. |
| `/home/yi/Code/rock-5b/gnome/grd/grd-debs` and `/home/yi/Code/rock-5b/gnome/grd/grd-install` | Historical local binary deployments. Keep outside git; packaging history is summarized in `packaging/README.md`. |
| `/home/yi/Code/rock-5b/rockchip-userspace/mpp-rockchip` and `/home/yi/Code/rock-5b/rockchip-userspace/librga-fork` | Upstream/source checkouts pinned by `ppa/build-source-packages.sh`. Their local `debian/` dirs are not the PPA packaging source of truth. |
| `/home/yi/Code/rock-5b/rockchip-conformance` | Deployed test bundle with logs/assets/build output. The tracked skeleton and patches live under `kernel-drivers/tests/conformance/`. |
| `/home/yi/Code/rock-5b/rockchip-vaapi` | Working checkout of the VA-API-over-MPP driver. `origin` is upstream `woodyst/rockchip-vaapi`; `fork` is `git@github.com:yisding/rockchip-vaapi.git`, with the latest recorded public checkpoint at `main@03e6cb6`. Clone that fork to reconstruct the source; keep generated packages and test output outside this repo. The maintained capability/evidence boundary and next gate live in [`../video-libraries/vaapi/`](../video-libraries/vaapi/README.md), while volatile fork state is tracked by [`status.md` W18](../status.md#watch-w18). |
| `/home/yi/Code/rock-5b/ubuntu-rockchip` and `/home/yi/Code/rock-5b/ubuntu-rockchip-settings` | Reference clones of Joshua Riek's archived ubuntu-rockchip image builder (`@38dfb49`) and settings package, surveyed 2026-07-21. Read-only quarry; findings captured in [`findings/2026-07-21-ubuntu-rockchip-piggyback-survey.md`](../findings/2026-07-21-ubuntu-rockchip-piggyback-survey.md). Reconstructible by re-cloning GitHub. |
| `downloads/ubuntu-rockchip-ppa/` in this repo | Downloaded `ppa:jjriek/rockchip-multimedia` source packaging (`.dsc` + debian tarballs, extractions under `x/`), git-ignored. Reconstruction recipe is in the survey finding (Launchpad `getPublishedSources` → `sourceFileUrls`). |
| `downloads/` in this repo | Local downloads, board backups, and build scratch. Ignored by git. Promote only small text findings into `docs/`, `findings/`, or package docs. |
| `packaging/ppa/out/` in this repo | Ignored local source-package output. `artifacts/` may hold upload candidates; `work/` is rebuild scratch. |

## Cleanup Notes

The easiest reclaimable space is generated scratch:

- `packaging/ppa/out/work/` can be deleted after preserving any needed files in
  `packaging/ppa/out/artifacts/`.
- Old Armbian kernel `.deb` sets under
  `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/armbian-build/output/debs/` are
  rebuild output; keep only the versions needed for immediate rollback/testing.
- `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/armbian-build/cache/` is a build
  accelerator, not source.

Do not remove external artifacts silently when they may still be needed for
rollback. Record the package filename, purpose, and checksum here before moving
hard-to-reproduce binaries to a separate artifact repository.
