# ffmpeg/

How to build [`ffmpeg-rockchip`](https://github.com/nyanmisaka/ffmpeg-rockchip)
against the vendor **MPP** + **RGA** libraries so you get `h264_rkmpp` /
`hevc_rkmpp` HW decode+encode and the `scale_rkrga` filter.

This needs **no system install and no sudo to build** — everything goes into an
isolated staging prefix; only *running* it needs device access (root, or the udev
rule).

## Dependencies

| Lib | Where it comes from | Form |
|-----|---------------------|------|
| `librockchip_mpp` (`>= 1.3.9`) | build `rockchip-linux/mpp` (the same userspace the codec tests use); the build dir has `librockchip_mpp.so.1` | built from source |
| `librga` | `airockchip/librga` ships a **prebuilt** aarch64 `.so` at `libs/Linux/gcc-aarch64/librga.so` + headers in `include/` | **prebuilt blob** (see [`docs/06`](../docs/06-gotchas.md)) |
| `libdrm` | distro (`libdrm-dev`) | distro |
| meson/ninja/cmake | distro | distro (no `nasm` needed on arm64) |

`configure` requires, via pkg-config: `rockchip_mpp` with `rockchip/rk_mpi.h`
(symbol `mpp_create`), and `librga` with `rga/RgaApi.h` (`c_RkRgaBlit`) +
`rga/im2d.h` (`querystring`).

## Stage the deps

Create a prefix (e.g. `~/ffmpeg-stack`) with the header *layout* the fork expects:

```bash
STAGE=~/ffmpeg-stack
mkdir -p $STAGE/{include/rockchip,include/rga,lib/pkgconfig}

# MPP: headers under rockchip/, libs (preserve the symlink chain)
cp <mpp-build>/inc/*.h            $STAGE/include/rockchip/    # rk_mpi.h + deps
cp -P <mpp-build>/mpp/librockchip_mpp.so* $STAGE/lib/

# RGA: prebuilt aarch64 .so + headers under rga/
cp <librga>/include/*.h $STAGE/include/rga/
cp <librga>/libs/Linux/gcc-aarch64/librga.so $STAGE/lib/

# pkg-config: copy the *.pc.example here, set prefix=$STAGE
cp rockchip_mpp.pc.example $STAGE/lib/pkgconfig/rockchip_mpp.pc
cp librga.pc.example       $STAGE/lib/pkgconfig/librga.pc
sed -i "s#^prefix=.*#prefix=$STAGE#" $STAGE/lib/pkgconfig/*.pc
```

The two `*.pc.example` files in this directory are the ones we used — they just
point `prefix=` at the staging dir and advertise `-lrockchip_mpp -lm` / `-lrga`.

## Configure + build

```bash
cd ffmpeg-rockchip
PKG_CONFIG_PATH=$STAGE/lib/pkgconfig ./configure \
  --prefix=$STAGE/ffmpeg-install \
  --enable-gpl --enable-version3 \
  --enable-rkmpp --enable-rkrga --enable-libdrm \
  --disable-vulkan \
  --extra-cflags="-I$STAGE/include" \
  --extra-ldflags="-L$STAGE/lib -Wl,-rpath,$STAGE/lib" \
  --disable-doc
make -j"$(nproc)"
```

- **`--disable-vulkan` is required** — the fork's `vulkan_av1.c` uses provisional
  *MESA* Vulkan-AV1 types that modern Vulkan headers replaced with *KHR* ones, and
  it fails to compile. Unrelated to the rk codecs.
- The `-Wl,-rpath,$STAGE/lib` makes the resulting `./ffmpeg` find
  `librockchip_mpp.so.1` + `librga.so` at runtime (verify with `ldd ./ffmpeg`).

## Verify + transcode

```bash
./ffmpeg -hide_banner -decoders | grep rkmpp     # h264_rkmpp, hevc_rkmpp, ...
./ffmpeg -hide_banner -filters  | grep rkrga     # scale_rkrga, vpp_rkrga, overlay_rkrga
# full HW transcode (root or udev rule):
./ffmpeg -hwaccel rkmpp -hwaccel_output_format drm_prime -i in.h264 \
  -vf scale_rkrga=w=1280:h=720:format=nv12 -c:v hevc_rkmpp -b:v 4M out.mp4
```

See `../tests/transcode-test.sh` for the full two-way test. Note
`scale_rkrga` keeps aspect ratio by default — add
`:force_original_aspect_ratio=disable` for exact dimensions.

## Don't want the blob?

`rkrga` is optional: drop `--enable-rkrga` and you still get `h264_rkmpp` /
`hevc_rkmpp` decode+encode (no HW scale/CSC). The fully-open path is the mainline
**V4L2** RGA driver (RGA2 merged ~6.12; RGA3 under review) — subset features only.
See [`docs/06`](../docs/06-gotchas.md) and `docs/05`.
