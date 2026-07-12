# Rockchip rewrite conformance bundle

This directory is the tracked seed for the user-space stacks that should be used
to compare the rewrite kernel against the BSP forward-port kernel. The source
checkouts, generated assets, build directories, install prefixes, and logs are
created beside it but ignored by git.

The test method is:

1. Boot the rewrite kernel and run the suite with `PROFILE=rewrite`.
2. Boot the forward-port kernel and run the same suite with `PROFILE=forward-port`.
3. Compare the logs under `logs/rewrite/` and `logs/forward-port/`.

The bundle is not tied to either kernel tree. It should be copied or mounted on
the target RK3588 system and run from there.

## Bootstrap

The tracked [`MANIFEST.tsv`](MANIFEST.tsv) pins every third-party source tree.
Reconstruct the external `sources/` directory from a fresh clone with:

```bash
cd kernel-drivers/tests/conformance
bash scripts/bootstrap-sources.sh
bash scripts/bootstrap-sources.sh verify
```

`bootstrap-sources.sh` clones missing sources, checks out the manifest commits,
and applies repo-owned patches from `patches/<name>/`. It refuses dirty existing
checkouts. The generated `sources/`, `assets/`, `build/`, `out/`, and `logs/`
directories stay untracked by policy.

## Directory layout

`sources/jeffycn-gstreamer-rockchip`
: JeffyCN's `gstreamer-rockchip` branch from `JeffyCN/mirrors`. This is the
  most important extra integration target beyond FFmpeg because it exercises MPP
  through GStreamer state changes, buffer pools, caps negotiation, dmabuf
  passing, encoder/decoder elements, and optional RGA-backed conversions.

`sources/rockchip-mpp`
: Rockchip MPP. Build this to get the official test binaries: `mpp_info_test`,
  `mpi_dec_test`, `mpi_dec_mt_test`, `mpi_dec_multi_test`, `mpi_enc_test`,
  `mpi_enc_mt_test`, `mpi_rc2_test`, and `vpu_api_test`.

`sources/airockchip-librga`
: Official librga repository and IM2D sample suite. The samples cover copy,
  resize, crop, colorspace conversion, fill, alpha blend, async jobs, allocator
  modes, FBC/tile cases, mosaic, ROP, and transform paths.

`sources/mpp-linux-cpp-demo`
: Linux demo combining MPP decode, RGA conversion, DRM/KMS display, and
  threading. This is useful because it chains the engines instead of testing
  them as isolated ioctls.

`sources/rkmediacodec-demo`
: Android RKMediaCodecDemo. Use this only for Android-style validation or when
  checking Android allocator/MediaCodec behavior. The user request called this
  RKMediaCoreDemo; the public Rockchip demo referenced by MPP is
  RKMediaCodecDemo.

`assets/`
: Put input media here. Use the same files for both kernel profiles.

`logs/`
: Per-profile logs created by the helper scripts.

`build/` and `out/`
: Created by build scripts. `build/` holds CMake/Meson build directories;
  `out/` holds locally installed binaries/libraries.

## What to test

Run these in order. Stop on crashes, hangs, WARN/OOPS, refcount splats, IOMMU
fault storms, or leaked fences.

### 1. Driver and device preflight

Run this first on each booted kernel:

```bash
cd /path/to/rockchip-conformance
PROFILE=rewrite ./scripts/collect-system-info.sh
PROFILE=forward-port ./scripts/collect-system-info.sh
```

The cross-project [`system baseline guide`](../../../../docs/system-baseline.md)
defines the captured fields, profile naming, privacy boundary, and which dated
document owns each changing state claim. Its discovery sections also seed the
whole-board [`support coverage inventory`](../../../../docs/support-coverage.md):
CPU/thermal, memory, storage, PCI/USB, address-free network state, DRM
connectors, audio, and camera graphs are recorded when available. Discovery is
not a functional pass; use the inventory row's first-evidence guidance before
changing its coverage state.

Check that `/dev/mpp_service`, `/dev/rga`, dma-heaps, DRM/KMS nodes, RGA
version paths, and MPP proc/debugfs paths look sane. Keep the collected dmesg
tail with every test result.

### 2. MPP official tests

Build:

```bash
./scripts/build-mpp.sh
```

Smoke:

```bash
PROFILE=rewrite ./scripts/run-mpp-smoke.sh
```

Then run codec-specific tests with known-good media from `assets/`. Suggested
minimum matrix:

- H.264 decode, 1080p and 4K, short and long GOP.
- H.265 decode, 1080p and 4K, short and long GOP.
- VP9 or AV1 decode if your userspace stack asks MPP for it on this board.
- H.264 encode from NV12, 1080p and 4K.
- H.265 encode from NV12, 1080p and 4K.
- Multi-instance decode with `mpi_dec_multi_test`.
- Multi-thread encode/decode with `mpi_enc_mt_test` and `mpi_dec_mt_test`.
- Legacy path with `vpu_api_test`.
- Rate-control path with `mpi_rc2_test`.

Useful command shapes:

```bash
out/mpp/bin/mpi_dec_test -i assets/sample.h264 -t 7 -n 120 -o logs/rewrite/sample.yuv
out/mpp/bin/mpi_dec_multi_test -i assets/sample.h265 -t 16777220 -n 120 -s 4
out/mpp/bin/mpi_enc_test -i assets/nv12-1920x1080.yuv -w 1920 -h 1080 -f 0 -t 7 -n 120 -o logs/rewrite/out.h264
out/mpp/bin/mpi_enc_mt_test -i assets/nv12-1920x1080.yuv -w 1920 -h 1080 -f 0 -t 16777220 -n 120 -s 4 -o logs/rewrite/out.h265
```

The exact numeric coding and pixel-format values come from MPP. If in doubt,
run a binary with `--help`; it prints the supported formats.

### 3. librga sample suite

Build:

```bash
./scripts/make-librga-pkgconfig.sh
./scripts/build-librga-samples.sh
```

Populate `/data` or rebuild the samples with a different `LOCAL_FILE_PATH`.
The upstream samples expect files like `in0w1280-h720-rgba8888.bin`; see
`sources/airockchip-librga/samples/README.md`.

Smoke:

```bash
PROFILE=rewrite ./scripts/run-librga-smoke.sh
```

Prioritize these samples for the rewrite:

- `copy_demo`: basic bitblit plus FBC/tile cases.
- `resize_demo`: scaling and UV downsampling.
- `cvtcolor_demo`: RGB/YUV conversion and CSC.
- `fill_demo`: solid fills and rectangle-array batching.
- `alpha_demo`: alpha blend, colorkey, OSD, RGBA/YUV composite cases.
- `transform_demo`: rotate, flip, rotate+flip.
- `async_demo`: request/fence handling.
- `allocator_demo`: dma-heap, DRM, malloc/userptr, and physical-contiguous cases.
- `rop_demo`, `mosaic_demo`, `padding_demo`: expected to expose current rewrite
  feature gaps if not implemented.

Run the same sample binaries under both kernels and compare outputs byte-for-byte
where the sample writes deterministic files.

### 4. JeffyCN GStreamer Rockchip plugins

Build MPP first, generate the librga pkg-config shim, then build GStreamer:

```bash
./scripts/build-mpp.sh
./scripts/make-librga-pkgconfig.sh
./scripts/build-gstreamer-rockchip.sh
```

Smoke:

```bash
PROFILE=rewrite ./scripts/run-gstreamer-smoke.sh
```

Then test real pipelines:

- Decode H.264/H.265 to `fakesink`.
- Decode H.264/H.265 to KMS/Wayland display if available.
- Encode raw NV12 to H.264/H.265.
- Transcode decode -> convert/scale -> encode.
- Multi-stream decode and encode in parallel.
- Stop, seek, EOS, restart, and caps renegotiation loops.
- DMABuf zero-copy paths where the sink/source supports it.

These tests are likely to catch bugs that plain FFmpeg misses because GStreamer
changes pipeline state frequently and uses allocator/buffer-pool negotiation.

### 5. Combined Linux demo

Build `sources/mpp-linux-cpp-demo` after installing MPP/librga development files
on the target. It is most useful as a manual display-path test:

```bash
cd sources/mpp-linux-cpp-demo
cmake -S . -B build
cmake --build build -j
./build/mpp_linux_demo
```

Expect this to need local edits or environment setup for compiler paths and
input media. Treat it as an integration smoke test, not as an automated
pass/fail test.

### 6. Android RKMediaCodecDemo

Use this only on an Android image or Android userspace. It should be run once
against each kernel if Android compatibility matters. It is lower priority for a
Linux-only validation plan.

## Result format

For every test run, record:

- Kernel profile: `rewrite` or `forward-port`.
- Kernel commit or image name.
- Userspace source revisions from `MANIFEST.tsv`.
- Exact command line.
- Exit status.
- Output file checksum if applicable.
- `dmesg` tail after the run.
- Any RGA/MPP debugfs or procfs counters that changed.

The comparison target is not just "does it run". The rewrite should match the
forward port for successful cases, fail cleanly for explicitly unsupported RGA
features, and avoid kernel warnings, hangs, use-after-free reports, leaked
fences, or IOMMU fault recovery regressions. Legacy/backend unsupported paths
should normally surface `EOPNOTSUPP`; modern request config/submit failures
match the BSP wrapper and surface `EFAULT` after request-check succeeds.
