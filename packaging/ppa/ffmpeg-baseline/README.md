# ffmpeg upstream-baseline packaging

This is the `debian/` tree for the upstream FFmpeg 8.1.2 **baseline** source
package in `ppa:yi-ding/rock5b-ffmpeg81-upstream`. It is isolated from both
the system FFmpeg 8.0 stack and the FFmpeg 8.1 Rockchip forward port.

Provenance: recovered on 2026-07-07 from the Launchpad source publication of
`ffmpeg 7:8.1.2-1+rk1` (`ffmpeg_8.1.2-1+rk1.debian.tar.xz`, sha256
`88d622f3090478439cebb30d1ded7b966012a21362982d8101b99a7463742b07`, verified
against the `.dsc`). The original tree lived only at
`/home/yi/Code/gnome/grd/grd-ppa/` on the board and was never in git.

Local delta on top of the recovered tree (version `7:8.1.2-1+rk2`):

- `debian/control`: add `frei0r-plugins <!nocheck !pkg.ffmpeg.stage1>` to
  Build-Depends. The FATE tests `fate-filter-frei0r-filter` and
  `fate-filter-frei0r-filter-unaligned`, new in FFmpeg 8.1, load
  `distort0r.so` at runtime; with only `frei0r-plugins-dev` installed the
  arm64 test suite fails (Launchpad build 33366878).

To rebuild the source package: overlay this `debian/` onto the extracted
`ffmpeg_8.1.2.orig.tar.xz` (sha256
`464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c`), reusing
the byte-identical orig tarball already in the PPA, then
`dpkg-buildpackage -S`, `debsign`, and `dput` per
[`../README.md`](../README.md). Version `7:8.1.2-1+rk2` still sorts below the
`7:8.1.2+rockchip81+git...` forward-port, preserving the supersede order.
