# ffmpeg-rockchip - PPA source package

Co-installable package for nyanmisaka's FFmpeg 6.1 Rockchip fork.

This is intentionally **not** a replacement for Ubuntu's `ffmpeg` source
package. Ubuntu 26.04 / resolute ships FFmpeg 8.x (`7:8.0.1-3ubuntu2` in the
primary archive), while this fork is based on FFmpeg 6.1 and exposes the older
ABI family (`libavcodec60`, `libavutil58`, `libavfilter9`, ...). Installing it
as the system `ffmpeg` would be a downgrade and would not satisfy normal
resolute `libav*` dependency expectations.

The binary package is named `ffmpeg-rockchip`. It installs private commands
under `/opt/ffmpeg-rockchip/bin/` and exposes non-shadowing links:

```text
/usr/bin/ffmpeg-rockchip
/usr/bin/ffprobe-rockchip
/usr/bin/ffplay-rockchip
```

The packaged binaries were built from the local
`/home/yi/Code/ffmpeg/ffmpeg-rockchip` checkout at commit
`40c412daccf08164493da0de990eb99a8948116b`, exported by
[`../build-source-packages.sh`](../build-source-packages.sh). That path records
provenance; the portable default is
`$WORKSPACE_ROOT/ffmpeg/ffmpeg-rockchip`, with `WORKSPACE_ROOT` defaulting to
the parent of this repository. The source package
name is `ffmpeg-rockchip`, so it can live in the same PPA as the normal
`ffmpeg` baseline and `ffmpeg-rockchip-81` replacement packages without source
or binary package-name collisions.

## Current PPA state

Local source-package validation passed, source `lintian` passed, and a local arm64 binary build produced the expected private tools with RKMPP encoders/decoders and RKRGA filters. The package disables LTO for local/Launchpad resource use and skips upstream FATE tests because this fork segfaults while generating HLS list test data.

The original signed source upload
`6.1+git20260423.40c412dacc-0ubuntu1~rk1` produced successful arm64 build
`33387375` on `bos03-arm64-043`. The recreated main PPA now publishes that
source as publication `18619787` plus its arm64 tool binary. Holding source
publication `18619559` and its copied binary remain Published in
`ubuntu-rock-5b-experimental`, which is not an install target.
