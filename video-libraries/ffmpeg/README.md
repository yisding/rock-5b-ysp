# video-libraries/ffmpeg/ — ffmpeg-rockchip build against vendor MPP + RGA

How to build [`ffmpeg-rockchip`](https://github.com/nyanmisaka/ffmpeg-rockchip)
against the vendor **MPP** + **RGA** libraries so you get `h264_rkmpp` /
`hevc_rkmpp` HW decode+encode and the `scale_rkrga` filter.

Project vocabulary (incl. `ffmpeg-rockchip` upstream vs the `ffmpeg-rockchip-81`
8.1.2 port): [`keywords.md`](keywords.md).

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Build or install an FFmpeg that can decode, encode, scale, and transcode through the RK3588 hardware stack. |
| Developer focus | Understand how FFmpeg packets, frames, DRM PRIME descriptors, rkmpp codecs, and rkrga filters map onto `librockchip_mpp`, `librga`, and the kernel devices. |
| Owns | The FFmpeg build recipe, companion docs in [`docs/`](docs/how-ffmpeg-works.md), pkg-config examples, and exported patch series in [`patches/`](patches/README.md). |
| Depends on | Working kernel nodes from [`kernel-drivers/README.md`](../../kernel-drivers/README.md), staged or packaged libraries from [`vendor-libraries/README.md`](../../vendor-libraries/README.md), and the codec udev rule for non-root use. |
| Current state | The original `ffmpeg-rockchip` build path is hardware-validated. `ffmpeg-rockchip-81` main at `be367abfe6` builds, passes focused codec-registration FATE, and is the source of the pending PPA upload; broader feature/encode/RGA-smoke validation was recorded at the earlier `75638e7f0b17` snapshot. See [`status.md`](../../status.md). |

## Files

| Path | One-liner |
|------|-----------|
| [`docs/how-ffmpeg-works.md`](docs/how-ffmpeg-works.md) | FFmpeg's demux -> decode -> filter -> encode -> mux model and where MPP/RGA plug in. |
| [`docs/implementation-comparison.md`](docs/implementation-comparison.md) | Upstream FFmpeg 8.1.2 (ABI-friendly codec bridge used by the GRD package) vs ffmpeg-rockchip (full Rockchip CLI pipeline: RKMPP hwcontext + RGA filters + richer encoder controls); hwframe model, option surface, AV1 paths. |
| [`docs/fix-candidates.md`](docs/fix-candidates.md) | The 14 rebase-cleanup fix groups worth backporting to NyanMisaka's fork, and the small V4L2 pieces that may go to FFmpeg upstream. |
| [`docs/review-learnings.md`](docs/review-learnings.md) | Reusable review traps from hardening the `ffmpeg-rockchip-81` rebase: V4L2 fallback, RKMPP AFBC/DRM, and RKRGA capability. |
| [`docs/rebase-notes.md`](docs/rebase-notes.md) | Tree pins reconciled, how the fork was replayed onto FFmpeg master, and the submission ledger. |
| [`docs/jellyfin-ffmpeg-patch-survey.md`](docs/jellyfin-ffmpeg-patch-survey.md) | 2026-07-11 comparison against Jellyfin FFmpeg 8.1.2: Rockchip sync status, correctness patches to apply directly, and sidecar-only patches. |
| [`docs/submission-plan.md`](docs/submission-plan.md) | 2026-07-02 full-branch targeting: which of the ~35 logical patches go to nyanmisaka's fork, which to FFmpeg upstream, and which stay here. |
| [`patches/`](patches/README.md) | The exported 28-patch `git format-patch` series behind fix-candidates + submission-plan (`.patch` files + apply instructions). |

See also [`vendor-libraries/rga/docs/librga-p010-p210-rkrga.md`](../../vendor-libraries/rga/docs/librga-p010-p210-rkrga.md)
(owned by vendor-libraries/rga) for the RKRGA P010/P210 investigation: Jellyfin
usage, BSP kernel layout flags, older librga breakage, and nyanmisaka's patched
librga fix.

**Which tree is current:** this README's recipe builds the nyanmisaka fork at
`40c412dacc` (2026-04-23) — the tree the kernel-port validation used. Since
then the whole stack was rebased onto FFmpeg master and given 28 review-fix
commits: **`github.com/yisding/ffmpeg-rockchip-81`** (nyanmisaka upstream:
`github.com/nyanmisaka/ffmpeg-rockchip`). If you are building fresh today,
prefer the rebased tree: it carries the documented fix groups
([`docs/fix-candidates.md`](docs/fix-candidates.md)), no longer needs
`--disable-vulkan`, and is the tree behind the current package at main
`be367abfe6`. The earlier `75638e7f0b17` snapshot remains the broader local
package-validation point, while `6cf02ab253` remains the 28-patch
review series captured under [`patches/`](patches/README.md).

This needs **no system install and no sudo to build** — everything goes into an
isolated staging prefix; only *running* it needs device access (root, or the udev
rule).

## Dependencies

| Lib | Where it comes from | Form |
|-----|---------------------|------|
| `librockchip_mpp` (`>= 1.3.9`) | build `rockchip-linux/mpp` (the same userspace the codec tests use); the build dir has `librockchip_mpp.so.1` | built from source |
| `librga` | we linked the **prebuilt** aarch64 `.so` from `airockchip/librga` (`libs/Linux/gcc-aarch64/librga.so` + `include/`); **buildable source** is at `tsukumijima/librga-rockchip` (JeffyCN lineage, Apache-2.0) | prebuilt for convenience; source available (see [gotchas](../../docs/gotchas.md)) |
| `libdrm` | distro (`libdrm-dev`) | distro |
| meson/ninja/cmake | distro | distro (no `nasm` needed on arm64) |

`configure` requires, via pkg-config: `rockchip_mpp` with `rockchip/rk_mpi.h`
(symbol `mpp_create`), and `librga` with `rga/RgaApi.h` (`c_RkRgaBlit`) +
`rga/im2d.h` (`querystring`).

## Build MPP (the first input)

The `<mpp-build>` consumed below — and the `mpi_enc_test`/`mpi_dec_test`
binaries the [`kernel-drivers/tests/README.md`](../../kernel-drivers/tests/README.md) smoke tests run — come from a
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
| `test/mpi_enc_test`, `test/mpi_dec_test` | The standalone codec smoke-test binaries [`kernel-drivers/tests/README.md`](../../kernel-drivers/tests/README.md) uses. |
| `rockchip_mpp.pc` | pkg-config `Version:` is **1.3.9** even on the 2026 `develop` tree — MPP's `.pc` version is decoupled from its release tags (the same source packaged in the PPA is tagged 1.5.0). Satisfies the fork's `>= 1.3.9` check. |

(`build/linux/aarch64/make-Makefiles.bash` in the MPP tree is the vendor
cross-compile recipe; on the ROCK 5B itself the native build above is all you
need.) Alternative to building at all: install `librockchip-mpp-dev` from the
PPA packaging work — [`packaging/ppa/README.md`](../../packaging/ppa/README.md).

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

- **`--disable-vulkan` is required for this 40c412d-era fork only** (its
  `vulkan_av1.c` uses provisional MESA Vulkan-AV1 types that modern headers
  dropped); the rebased `ffmpeg-rockchip-81` tree builds with Vulkan on —
  [`docs/rebase-notes.md`](docs/rebase-notes.md) §3 scopes the flag to the
  `40c412dacc` era.
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

See [`kernel-drivers/tests/transcode-test.sh`](../../kernel-drivers/tests/transcode-test.sh) for the full
two-way test. Note `scale_rkrga` keeps aspect ratio by default (add
`:force_original_aspect_ratio=disable` for exact dimensions) — canonical
statement in [`docs/implementation-comparison.md`](docs/implementation-comparison.md) §5.

**Player caveat:** the rkmpp decoders (both trees) are standalone `AVCodec`s,
*not* `AVHWAccel`s, so generic "enable hwaccel" switches don't find them. mpv
needs `--hwdec=rkmpp` / `--vd=h264_rkmpp`; VLC 3.x cannot use them at
all. Canonical write-up: [`packaging/README.md`](../../packaging/README.md)
§Operations runbook.

## Building librga from source, or avoiding it

We linked airockchip's prebuilt `.so` for convenience, but librga is open source
despite looking like a vendor drop. If you want a from-source userspace, build it
from the JeffyCN lineage and stage *that* `.so`/headers into `$STAGE` instead of
the prebuilt — the lineage, licence, and buildable-mirror detail live in
[gotchas](../../docs/gotchas.md).

For RKRGA `P010`/`P210`, use a patched source build rather than an unknown
prebuilt: older legacy `c_RkRgaBlit()` paths can drop the 10-bit layout flags.
The detailed compatibility note is
[`vendor-libraries/rga/docs/librga-p010-p210-rkrga.md`](../../vendor-libraries/rga/docs/librga-p010-p210-rkrga.md).

To find out what version a prebuilt `librga.so` actually is (the
[`librga.pc.example`](pkgconfig/librga.pc.example)'s `1.10.6` must match the staged
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
only. See [gotchas](../../docs/gotchas.md) and
[vanilla-kernel guide](../../kernel-versions/docs/vanilla-kernel.md).
