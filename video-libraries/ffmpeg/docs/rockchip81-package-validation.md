# ffmpeg-rockchip-81 package build and on-board validation

Record of building the `ffmpeg-rockchip-81` forward-port into a local runtime
package and smoke-validating it on the ROCK 5B, plus the MPP root cause behind
the one decode failure. Companion to [`rebase-notes.md`](rebase-notes.md) §3
(which snapshot this validation pins to) and
[`review-learnings.md`](review-learnings.md) (the code-review lessons from the
same tree).

> Scope: local package build from `ffmpeg-rockchip-81` branch
> `refactor/section-c` at `75638e7f0b17` into `packaging/ffmpeg-rockchip81/`,
> plus on-board smoke validation.
> Runtime: ROCK 5B, `Linux rock-5b 6.18.38-current-rockchip64 #16`, system
> `librockchip-mpp1 1.5.0-1+rk1`, `librga2 2.2.0-1+rk1`.
> Date: 2026-07-06.
> Trust: MEASURED for command results; INFERRED where noted.

## What passed

The forward-port tree compiled cleanly from a fresh clone and produced a local
runtime package:

```text
packaging/ffmpeg-rockchip81/build/ffmpeg-rockchip81_8.0.git+rockchip81+git20260703.75638e7f0b17-1_arm64.deb
sha256: 0456b45b8d9ce160b08e03031461b2a176bd73eee9e9db862fc874cc4775d648
```

The built binary reports:

```text
ffmpeg version git-2026-07-03-75638e7f0b
configuration: --enable-rkmpp --enable-rkrga --enable-version3 --enable-libdrm
libavcodec 63.2.100
```

Feature registration passed:

- `rkmpp` appears in `-hwaccels`.
- Decoders include `av1_rkmpp`, `h264_rkmpp`, `hevc_rkmpp`, `vp8_rkmpp`,
  `vp9_rkmpp`, and legacy MPEG/H.263/MJPEG rkmpp decoders.
- Encoders include `h264_rkmpp`, `hevc_rkmpp`, and `mjpeg_rkmpp`.
- Filters include `scale_rkrga`, `vpp_rkrga`, and `overlay_rkrga`.

Runtime smoke passed:

- H.264 RKMPP encode from `lavfi` software frames produced 60 frames:
  `/tmp/ffmpeg-rockchip81-smoke/h264-rkmpp.h264`.
- RKMPP hwupload plus RGA scale plus HEVC RKMPP encode produced a valid
  640x360 HEVC MP4 with 60 packets:
  `/tmp/ffmpeg-rockchip81-smoke/rkmpp-hwupload-rkrga-hevc.mp4`.
- After the MPP root-cause pass below, the same FFmpeg binary also decoded the
  H.264 RKMPP test stream successfully when run against a matching from-source
  MPP runtime.

So the package is compile-, feature-, encode-, hwupload-,
H.264-decode-with-source-MPP-, and RGA-smoke validated. The four documented
failures below are what remains.

## Failure 1: sandbox `/dev` is not usable for codec/RGA validation

Inside the default command sandbox, `/dev` was a small tmpfs with `nodev`; it
did not expose `/dev/mpp_service`, `/dev/rga`, `/dev/dma_heap/*`, or `/dev/dri`.
Sysfs still showed the kernel drivers:

```text
/sys/class/mpp_class/mpp_service
/sys/class/misc/rga
/sys/module/rga3
/sys/module/rk_vcodec
```

The real device nodes were visible only in the unsandboxed run:

```text
crw-rw----+ 1 root video 244, 0 /dev/mpp_service
crw-rw----+ 1 root video  10, 261 /dev/rga
/dev/dma_heap/{default_cma_region,reserved,system}
```

Impact: any default-sandbox failure that says the devices are absent is not a
kernel or FFmpeg result. Hardware validation must run outside the sandbox, on
the board, or through a runner with the real device namespace.

## Failure 2: RKMPP decode fails against the installed MPP runtime

`h264_rkmpp` decode failed against a stream produced by the same package's
`h264_rkmpp` encoder:

```text
mpp_dec: mpp_parser_init parser h264 is not registered
mpp_dec: mpp_dec_init could not init parser
Failed to init MPP context: -1
Error while opening decoder: Generic error in an external library
```

The same failure reproduced with the newly built packaged binary, the existing
`ffmpeg-rockchip-81` build, and the installed system `ffmpeg 7:8.1.2-1+rk1`.

Root cause is the installed `/usr` MPP userspace library, not the FFmpeg
forward-port or the kernel:

- The runtime selected by normal `pkg-config rockchip_mpp` is
  `/usr/lib/aarch64-linux-gnu/librockchip_mpp.so.1` from
  `librockchip-mpp1 1.5.0-1+rk1`; its pkg-config metadata advertises
  `Version: 1.3.9`.
- Symbol/string inspection of the installed library found H.264 HAL symbols
  such as `hal_api_h264d` and `vdpu*_h264d_*`, but not the H.264 parser API
  object/registration symbols (`mpp_h264d`, `h264d_parse`,
  `mpp_parser_api_register_mpp_h264d_wrapper`, `mpp_singleton_add_mpp_h264d`).
- The local `mpp-rockchip` source is tag `1.0.12` at `1375813c`; its pkg-config
  template advertises `Version: 1.3.10`. A clean `/tmp` build of that source
  produced `librockchip_mpp.so.1` with the missing parser registration symbols
  and `mpp_sgln_base_add`.
- Re-running the same packaged FFmpeg binary with
  `LD_LIBRARY_PATH=/tmp/mpp-rockchip-1.0.12-build2/mpp` decoded the H.264 RKMPP
  stream to `null` successfully:

```text
mpp version: 1375813c author: Herman Chen 2026-05-29 docs: Update 1.0.12 CHANGELOG.md
Input stream #0:0 (video): 14 packets read; 5 frames decoded; 0 decode errors
```

Impact: full FFmpeg decode/transcode validation is blocked only for the
installed-MPP runtime. With a matching `mpp-rockchip` runtime the H.264 RKMPP
decode smoke passes; the remaining item is to package or install the matching
MPP runtime and rerun the full decode/RGA transcode suite.

## Failure 3: direct software-frame input to `scale_rkrga` is invalid

This command shape failed:

```bash
ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30 \
  -vf 'scale_rkrga=w=640:h=360:format=nv12' \
  -c:v hevc_rkmpp out.mp4
```

Error:

```text
Impossible to convert between the formats supported by the filter
'graph -1 input from stream 0:0' and the filter 'auto_scale_0'
...
auto_scale_0 -> Parsed_scale_rkrga_0:
  src: ... software pixel formats ...
  dst: drm_prime
Error reinitializing filters: Function not implemented
```

This is a command-shape failure, not a package regression. The RGA filters in
this fork operate on `drm_prime` hardware frames. They work when frames are
already RKMPP/RGA hardware frames, or when software frames are explicitly
uploaded through the RKMPP hwcontext. The corrected software-source smoke
passed:

```bash
ffmpeg -init_hw_device rkmpp=rk -filter_hw_device rk \
  -f lavfi -i testsrc2=size=1280x720:rate=30 \
  -frames:v 60 \
  -vf 'format=nv12,hwupload,scale_rkrga=w=640:h=360:format=nv12' \
  -c:v hevc_rkmpp -b:v 2M out.mp4
```

Impact: docs and ad-hoc tests must not present `scale_rkrga` as accepting normal
software frames directly.

## Failure 4: local MPP demo binaries do not match the installed MPP library

The local conformance MPP demo binaries failed with an ABI mismatch before they
could serve as an independent decoder/encoder comparison:

```text
/home/yi/Code/rock-5b/rockchip-conformance/out/mpp/bin/mpi_dec_test:
  undefined symbol: mpp_sgln_base_add
/home/yi/Code/rock-5b/rockchip-conformance/out/mpp/bin/mpi_enc_test:
  undefined symbol: mpp_sgln_base_add
```

Root cause:

- The demo binaries have `NEEDED librockchip_mpp.so.1` but no `RPATH`/`RUNPATH`,
  so the loader selected the installed `/usr` library, which lacks
  `mpp_sgln_base_add`.
- The matching local library at
  `/home/yi/Code/rock-5b/rockchip-conformance/out/mpp/lib/librockchip_mpp.so.1` exports
  `mpp_sgln_base_add` and the decoder parser registration symbols. Running the
  demos with `LD_LIBRARY_PATH` pointed at it removes the undefined-symbol
  failure and reaches normal argument/runtime checks.
- That conformance library reports MPP commit `c2c1ee5`, so it is not the exact
  current `1.0.12` source build, but it is already newer/different than the
  installed `/usr` library ABI.

Impact: use a matching `LD_LIBRARY_PATH` for those demos, rebuild them against
the installed MPP, or do not use them as evidence for the packaged FFmpeg until
the runtime mismatch is fixed.

## Fixed during packaging

The first assembled `.deb` had group-writable package directories because the
builder used `chmod -R u+rwX,go+rX "$PKGROOT"`. The builder now normalizes
package-root permissions with `chmod -R u=rwX,go=rX "$PKGROOT"`, and the final
archive shows normal `0755` directories and executable modes.

## Next validation step

For full forward-port validation, package or otherwise select the matching
`mpp-rockchip` runtime, then rerun the FFmpeg suite with the packaged binary.
The minimum required pass set is:

- `h264_rkmpp` decode to null,
- `hevc_rkmpp` decode to null,
- `h264_rkmpp -> scale_rkrga -> hevc_rkmpp`,
- `hevc_rkmpp -> scale_rkrga -> h264_rkmpp`.

Until that passes, the package is compile-, feature-, encode-, hwupload-,
H.264-decode-with-source-MPP-, and RGA-smoke validated, but not full
installed-runtime decode/transcode validated.
