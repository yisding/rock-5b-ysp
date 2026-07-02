# ffmpeg/

How to build [`ffmpeg-rockchip`](https://github.com/nyanmisaka/ffmpeg-rockchip)
against the vendor **MPP** + **RGA** libraries so you get `h264_rkmpp` /
`hevc_rkmpp` HW decode+encode and the `scale_rkrga` filter.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Build or install an FFmpeg that can decode, encode, scale, and transcode through the RK3588 hardware stack. |
| Developer focus | Understand how FFmpeg packets, frames, DRM PRIME descriptors, rkmpp codecs, and rkrga filters map onto `librockchip_mpp`, `librga`, and the kernel devices. |
| Owns | The FFmpeg build recipe, companion docs in [`docs/`](docs/how-ffmpeg-works.md), pkg-config examples, and exported patch series in [`patches/`](patches/README.md). |
| Depends on | Working kernel nodes from [`../kernel-drivers/`](../kernel-drivers/README.md), staged or packaged libraries from [`../userspace-libraries/`](../userspace-libraries/README.md), and the codec udev rule for non-root use. |
| Current state | The original `ffmpeg-rockchip` build path is hardware-validated; the rebased `ffmpeg-rockchip-81` tree and 9-patch fix series are documented but not what is installed on the board. See [`../status.md`](../status.md). |

Companion docs:

- [`docs/how-ffmpeg-works.md`](docs/how-ffmpeg-works.md) explains FFmpeg's demux ->
  decode -> filter -> encode -> mux model and where MPP/RGA plug in.
- [`docs/implementation-comparison.md`](docs/implementation-comparison.md) compares
  upstream FFmpeg 8.1.2 with ffmpeg-rockchip. Short version: ffmpeg-rockchip is
  the full Rockchip CLI pipeline (RKMPP hwcontext + RGA filters + richer encoder
  controls); upstream FFmpeg 8.1.2 is the ABI-friendly codec bridge used by the
  GRD package and needs application-side workarounds for quality and IDR.
- [`docs/fix-candidates.md`](docs/fix-candidates.md) records the 2026 rebase cleanup fixes
  worth backporting to NyanMisaka's fork, and separates the small V4L2 pieces
  that may be worth proposing to FFmpeg upstream.
- [`docs/rebase-notes.md`](docs/rebase-notes.md) reconciles all the tree pins, records how
  the fork was replayed onto FFmpeg master, and holds the submission ledger.
- [`patches/`](patches/README.md) is the exported fix series behind
  [`docs/fix-candidates.md`](docs/fix-candidates.md) (`git format-patch` files + apply instructions).

**Which tree is current:** this README's recipe builds the nyanmisaka fork at
`40c412dacc` (2026-04-23) — the tree the kernel-port validation used. Since
then the whole stack was rebased onto FFmpeg master and given 9 review-fix
commits: **`github.com/yisding/ffmpeg-rockchip-81`**, branch `main`
(nyanmisaka upstream: `github.com/nyanmisaka/ffmpeg-rockchip`). If you are
building fresh today, prefer the rebased tree — it carries the 14 documented
fix groups ([`docs/fix-candidates.md`](docs/fix-candidates.md)) and no longer needs
`--disable-vulkan`. See [`docs/rebase-notes.md`](docs/rebase-notes.md) §3 for what is
actually installed/running on the board.

This needs **no system install and no sudo to build** — everything goes into an
isolated staging prefix; only *running* it needs device access (root, or the udev
rule).

## Dependencies

| Lib | Where it comes from | Form |
|-----|---------------------|------|
| `librockchip_mpp` (`>= 1.3.9`) | build `rockchip-linux/mpp` (the same userspace the codec tests use); the build dir has `librockchip_mpp.so.1` | built from source |
| `librga` | we linked the **prebuilt** aarch64 `.so` from `airockchip/librga` (`libs/Linux/gcc-aarch64/librga.so` + `include/`); **buildable source** is at `tsukumijima/librga-rockchip` (JeffyCN lineage, Apache-2.0) | prebuilt for convenience; source available (see [gotchas](../docs/gotchas.md)) |
| `libdrm` | distro (`libdrm-dev`) | distro |
| meson/ninja/cmake | distro | distro (no `nasm` needed on arm64) |

`configure` requires, via pkg-config: `rockchip_mpp` with `rockchip/rk_mpi.h`
(symbol `mpp_create`), and `librga` with `rga/RgaApi.h` (`c_RkRgaBlit`) +
`rga/im2d.h` (`querystring`).

## Build MPP (the first input)

The `<mpp-build>` consumed below — and the `mpi_enc_test`/`mpi_dec_test`
binaries the [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md) smoke tests run — come from a
plain native CMake build of `rockchip-linux/mpp`. The build actually used
(reconstructed 2026-07-01 from the dev-box `build_native/CMakeCache.txt`:
`develop` branch @ `c2c1ee502b3a`, 2026-03-09, Release, system gcc, all
defaults — `BUILD_SHARED_LIBS=ON`, `BUILD_TEST=ON`):

```bash
git clone https://github.com/rockchip-linux/mpp.git && cd mpp   # develop is the default branch
mkdir build_native && cd build_native
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j"$(nproc)"
```

Outputs (all relative to `build_native/` = `<mpp-build>`):

| Artifact | Notes |
|----------|-------|
| `mpp/librockchip_mpp.so*` | SONAME `librockchip_mpp.so.1`; on this build the real file is `.so.0` with `.so.1 -> .so.0` and `.so -> .so.1` symlinks — hence the `cp -P` below. |
| `test/mpi_enc_test`, `test/mpi_dec_test` | The standalone codec smoke-test binaries [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md) uses. |
| `rockchip_mpp.pc` | pkg-config `Version:` is **1.3.9** even on the 2026 `develop` tree — MPP's `.pc` version is decoupled from its release tags (the same source packaged in the PPA is tagged 1.5.0). Satisfies the fork's `>= 1.3.9` check. |

(`build/linux/aarch64/make-Makefiles.bash` in the MPP tree is the vendor
cross-compile recipe; on the ROCK 5B itself the native build above is all you
need.) Alternative to building at all: install `librockchip-mpp-dev` from the
PPA packaging work — [`../packaging/ppa/`](../packaging/ppa/README.md).

## Stage the deps

Create a prefix (e.g. `~/ffmpeg-stack`) with the header *layout* ffmpeg-rockchip
expects:

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

- **`--disable-vulkan` is required** *for this 40c412d-era fork* — its
  `vulkan_av1.c` uses provisional *MESA* Vulkan-AV1 types that modern Vulkan
  headers replaced with *KHR* ones, and it fails to compile. Unrelated to the
  rk codecs. The rebased `ffmpeg-rockchip-81` tree builds with Vulkan enabled
  ([`docs/rebase-notes.md`](docs/rebase-notes.md) §3).
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

See [`../kernel-drivers/tests/transcode-test.sh`](../kernel-drivers/tests/transcode-test.sh) for the full
two-way test. Note `scale_rkrga` keeps aspect ratio by default — add
`:force_original_aspect_ratio=disable` for exact dimensions.

**Player caveat:** the rkmpp decoders (both trees) are standalone `AVCodec`s,
*not* `AVHWAccel`s, so generic "enable hwaccel" switches don't find them. mpv
needs `--hwdec=rkmpp` / `--vd=h264_rkmpp`; VLC 3.x cannot use them at
all. Canonical write-up: [`../packaging/README.md`](../packaging/README.md)
§Operations runbook.

## Building librga from source, or avoiding it

We linked airockchip's prebuilt `.so` for convenience, but librga is open source.
If you want a from-source userspace, build it from the **JeffyCN lineage**
(`tsukumijima/librga-rockchip` — a buildable mirror of
`JeffyCN/mirrors:linux-rga-multi`, Apache-2.0, CMake/Meson + Debian packages) and
stage *that* `.so`/headers into `$STAGE` instead.

To find out what version a prebuilt `librga.so` actually is (the
[`librga.pc.example`](librga.pc.example)'s `1.10.6` must match the staged
binary, and airockchip drops carry no version in the filename):

```bash
strings librga.so | grep 'rga_api version'   # -> "rga_api version 1.10.6_[3]"
```

(Verified 2026-07-01 against the staged airockchip `.so`.) At runtime, librga
logs the same string via the `im2d` API's `querystring()` — the symbol
ffmpeg-rockchip's `configure` probes for.

Or drop RGA entirely: `rkrga` is optional — `h264_rkmpp` / `hevc_rkmpp`
decode+encode work without it (you lose HW scale/CSC). The fully-mainline path is
the **V4L2** RGA driver (RGA2 merged ~6.12; RGA3 under review) — subset features
only. See [gotchas](../docs/gotchas.md) and
[vanilla-kernel guide](../kernel-drivers/docs/vanilla-kernel.md).
