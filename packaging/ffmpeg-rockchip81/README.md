# ffmpeg-rockchip81 local deb

Builds a self-contained runtime `.deb` from the local
`ffmpeg-rockchip-81` forward-port tree.

The package intentionally does not replace distro `ffmpeg` or the distro
`libav*` ABI. It installs the forward-port commands under
`/opt/ffmpeg-rockchip-81/bin/` and exposes non-shadowing convenience links:

```bash
ffmpeg-rockchip81
ffprobe-rockchip81
ffplay-rockchip81
```

Build:

```bash
bash packaging/ffmpeg-rockchip81/build-deb.sh
```

The default source is
`$WORKSPACE_ROOT/ffmpeg/ffmpeg-rockchip-81`, where `WORKSPACE_ROOT` defaults to
`$ROCK5B_WORKSPACE` and that grouped root defaults to the sibling `rock-5b`
workspace.

Useful overrides:

```bash
FFSRC=/path/to/ffmpeg-rockchip-81 JOBS=4 bash packaging/ffmpeg-rockchip81/build-deb.sh
bash packaging/ffmpeg-rockchip81/build-deb.sh clean
bash packaging/ffmpeg-rockchip81/build-deb.sh --help
```

The build output in `build/` is disposable and must not be committed.

## Validation Notes

The 2026-07-06 build from `ffmpeg-rockchip-81` commit `75638e7f0b17` compiled
and packaged successfully. Feature registration, H.264 RKMPP encode, and
software-source RKMPP `hwupload` -> `scale_rkrga` -> HEVC RKMPP encode were
validated on the ROCK 5B.

Known failures from that run are documented in
[`../../findings/2026-07-06-ffmpeg-rockchip81-package-validation.md`](../../findings/2026-07-06-ffmpeg-rockchip81-package-validation.md):
the default sandbox hides codec device nodes, installed-MPP rkmpp decode fails
with `parser h264 is not registered`, direct software-frame input to
`scale_rkrga` is the wrong command shape, and local MPP demo binaries do not
match the installed MPP library.

Follow-up root-cause testing built `~/Code/rock-5b/rockchip-userspace/mpp-rockchip`
tag `1.0.12` from source. That build's `rockchip_mpp.pc` advertises
`Version: 1.3.10`, includes the missing H.264 parser registration symbols, and
makes the packaged FFmpeg binary pass the H.264 RKMPP decode smoke when selected
with `LD_LIBRARY_PATH`.
