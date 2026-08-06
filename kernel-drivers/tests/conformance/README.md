# Rockchip driver conformance bundle

This directory is the tracked definition of the reusable RK3588 driver test
matrix. The same standard cases run against vendor BSP, forward-port, and
rewrite targets; instrumentation such as KASAN or KCSAN is a separate axis.
Target- or configuration-specific safety tests are declared explicitly instead
of being hidden in profile-name conditionals.

[`TESTS.tsv`](TESTS.tsv) is the ordered test catalog. [`targets/`](targets/)
defines driver implementations and [`configurations/`](configurations/)
defines build instrumentation. The first-class entry point is
[`../run-conformance.sh`](../run-conformance.sh):

```bash
# On the board, autodetect both axes and run the standard set.
sudo bash kernel-drivers/tests/run-conformance.sh

# Inspect exactly what would run; this does not touch the board.
bash kernel-drivers/tests/run-conformance.sh \
  --target bsp --configuration production --plan

# Run the same standard set on every implementation.
sudo bash kernel-drivers/tests/run-conformance.sh --target bsp
sudo bash kernel-drivers/tests/run-conformance.sh --target forward-port
sudo bash kernel-drivers/tests/run-conformance.sh --target rewrite

# The standard set still runs under sanitizers; add compatible focused tests.
sudo bash kernel-drivers/tests/run-conformance.sh \
  --target forward-port --configuration kasan \
  --include reset-session-kasan,ioctl-fuzz-kasan
sudo bash kernel-drivers/tests/run-conformance.sh \
  --target rewrite --configuration kcsan \
  --include iommu-stress,recovery-stress,reset-contention
```

Production profile IDs retain the target name (`bsp`, `forward-port`,
`rewrite`). Instrumented runs append the configuration
(`forward-port-kasan`, `rewrite-kcsan`) so results never overwrite or get used
as production performance evidence. `--only` is the focused-debugging path;
the harness fails closed when a requested test is incompatible with the chosen
matrix cell. `--compare-to PROFILE` compares every selected catalog row marked
comparable. Sanitizer configurations disable timing thresholds unless the
caller deliberately sets `PERF_MAX_RATIO`.

With neither selector supplied, the harness reads
`/boot/config-$(uname -r)` and autodetects both axes. Rewrite Kconfig selects
the rewrite target. For vendor-driver Kconfig, kernel series 5.10, 6.1, and 6.6
select BSP; every other series selects forward-port. `CONFIG_KASAN=y` selects
KASAN, `CONFIG_KCSAN=y` selects KCSAN, and neither selects production. The
descriptors own these predicates so autodetection and the standard
`matrix-identity` row cannot drift. Explicit selectors remain supported and
are verified against the same predicates before consumer workloads run.

Set `CONFORMANCE_KERNEL_CONFIG` and `CONFORMANCE_KERNEL_RELEASE` to inspect a
different boot artifact. `--target auto` and `--configuration auto` explicitly
request detection of either axis. If a config is missing, contradictory, or
matches more than one descriptor, the harness fails instead of guessing.
Device-free `--validate` deliberately defaults to rewrite/production; an
off-board `--plan` should provide both selectors or the two identity overrides.

The bundle also owns pinned external sources, assets, and generated logs. The
suite defaults use installed MPP and librga; pinned copies remain reconstructible
for explicit legacy comparisons. It is independent of any one kernel tree and
can be copied or mounted on the RK3588 target.

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

`TESTS.tsv`
: Ordered registry of standard and opt-in tests, their target/configuration
  selectors, execution type, comparator eligibility, and purpose. Add a row
  here when a maintained test joins the harness.

`targets/*.env`
: One descriptor per driver implementation. A target may set policy such as
  rewrite counter requirements and kernel-series identity, but it does not
  encode sanitizer state.

`configurations/*.env`
: One descriptor per instrumentation shape. Configuration suffixes create
  distinct profile/log identities and declare whether performance comparison is
  meaningful.

`sources/jeffycn-gstreamer-rockchip`
: JeffyCN's `gstreamer-rockchip` branch from `JeffyCN/mirrors`. This is the
  most important extra integration target beyond FFmpeg because it exercises MPP
  through GStreamer state changes, buffer pools, caps negotiation, dmabuf
  passing, encoder/decoder elements, and optional RGA-backed conversions.

`sources/rockchip-mpp`
: Pinned Rockchip MPP source for an explicit legacy comparison. Normal
  conformance uses the matching official test binaries installed under
  `/usr/bin`.

`sources/airockchip-librga`
: Official IM2D sample source plus a pinned prebuilt librga retained for an
  explicit legacy comparison. Normal sample builds and runs use installed
  librga.

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
: Per-profile logs created by the helper scripts. Each harness run writes a
  timestamped `conformance-plan.tsv` alongside the suite result directories so
  the exact selection can be reconstructed.

`build/` and `out/`
: Created by build scripts. `build/` holds CMake/Meson build directories;
  `out/` holds locally installed binaries/libraries.

`scripts/list-built-binaries.sh`
: Prints the executable files currently staged under `out/`; use it to verify
  which source builds actually produced runnable conformance tools.

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

Use `OUT=/path/to/result` when a surrounding test run needs a deterministic
destination. `./scripts/collect-system-info.sh --selftest` verifies the
root/resume identifier redaction without reading board state or creating a log
directory.

The cross-project [`system baseline guide`](../../../docs/system-baseline.md)
defines the captured fields, profile naming, privacy boundary, and which dated
document owns each changing state claim. Its discovery sections also seed the
whole-board [`support coverage inventory`](../../../docs/support-coverage.md):
CPU/thermal, memory, storage, PCI/USB, address-free network state, DRM
connectors, audio, and camera graphs are recorded when available. The boot
identity section also records any U-Boot version exposed in the live DT, a hash
of the live flattened device tree, resolved `/boot` artifact paths, and MTD/SPI
device identity without reading firmware contents. Those signals can
distinguish artifacts but cannot prove which medium BootROM selected; preserve
UART output and the exact tested firmware image for that claim. Discovery is
not a functional pass; use the inventory row's first-evidence guidance before
changing its coverage state.

Check that `/dev/mpp_service`, `/dev/rga`, dma-heaps, DRM/KMS nodes, RGA
version paths, and MPP proc/debugfs paths look sane. Keep the collected dmesg
tail with every test result.

### 2. MPP official tests

Install the YSP MPP runtime, development, and demo packages. The smoke and full
suite then use `/usr/bin/{mpp_info_test,mpi_dec_test,...}` and the system
dynamic-loader path by default:

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
/usr/bin/mpi_dec_test -i assets/sample.h264 -t 7 -n 120 -o logs/rewrite/sample.yuv
/usr/bin/mpi_dec_multi_test -i assets/sample.h265 -t 16777220 -n 120 -s 4
/usr/bin/mpi_enc_test -i assets/nv12-1920x1080.yuv -w 1920 -h 1080 -f 0 -t 7 -n 120 -o logs/rewrite/out.h264
/usr/bin/mpi_enc_mt_test -i assets/nv12-1920x1080.yuv -w 1920 -h 1080 -f 0 -t 16777220 -n 120 -s 4 -o logs/rewrite/out.h265
```

The exact numeric coding and pixel-format values come from MPP. If in doubt,
run a binary with `--help`; it prints the supported formats.

For a deliberate comparison with the pinned March MPP source, run
`./scripts/build-mpp.sh`, then set `MPP_BIN_DIR="$PWD/out/mpp/bin"` and
`MPP_LIBDIR="$PWD/out/mpp/lib"` explicitly.

### 3. librga sample suite

Build:

```bash
./scripts/build-librga-samples.sh
```

The build resolves `librga.pc` from the installed `librga-dev` package. Populate
the directory named by `RGA_SAMPLE_DATA_DIR`; the patched sample utility no
longer requires the Android-only `/data` path. The upstream samples expect files
such as `in0w1280-h720-rgba8888.bin`; see
`sources/airockchip-librga/samples/README.md`.

For an explicit legacy build, `scripts/make-librga-pkgconfig.sh` can generate
the old source tree's `librga.pc` shim under `out/pkgconfig`; pass that directory
as `PKG_SHIM` instead of relying on it implicitly.

Smoke:

```bash
PROFILE=rewrite ./scripts/run-librga-smoke.sh
```

The smoke default omits `rga_fill_demo` because that official sample hard-codes
the vendor-only `system-uncached-dma32` heap. Set `RGA_CASES` explicitly to add
it on a matching BSP kernel; the maintained `../librga-smoke.sh` covers fill
through the portable allocator path used by the main conformance run.

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

With installed `librockchip-mpp-dev`, `librga-dev`, and the GStreamer
development packages, build only the out-of-tree plugin:

```bash
./scripts/build-gstreamer-rockchip.sh
```

> `scripts/build-gstreamer-rockchip.sh` here is the reduced, self-contained
> variant this bundle needs when copied to the target board; it builds into
> `build/jeffycn-gstreamer-rockchip` with every plugin feature left on `auto`.
> The maintained one is
> [`../build-gstreamer-rockchip.sh`](../build-gstreamer-rockchip.sh), which
> builds into `…-mpp`, pins the feature set, adds the installed-package
> pkg-config preflight, and also builds `gstreamer-event-harness`. They share a
> basename but not a build tree — check which one a command means.

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
- Installed MPP/librga package versions and checksums, plus the plugin/sample
  source revisions from `MANIFEST.tsv`.
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
