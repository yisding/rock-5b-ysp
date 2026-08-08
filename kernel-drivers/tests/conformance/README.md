# RK3588 driver conformance harness

Use this harness to run the same broad driver tests against the Rockchip BSP,
the maintained forward port, and the clean-room rewrite. KASAN and KCSAN are
separate configuration choices, so the standard functional coverage can run on
instrumented kernels too.

The entry point is [`../run-conformance.sh`](../run-conformance.sh). This page
explains how to run it and what its results mean. The detailed per-suite command,
environment-variable, and acceptance reference remains in
[`../conformance.md`](../conformance.md).

## Quick start

Run these commands from the repository root on the ROCK 5B.

```bash
# Resolve the booted kernel and show the test selection. No workload is run.
sudo bash kernel-drivers/tests/run-conformance.sh --plan

# Run the standard conformance set.
sudo bash kernel-drivers/tests/run-conformance.sh
```

The harness normally detects both the driver target and kernel configuration.
The plan should show the expected `target`, `configuration`, and `profile`
before you start a long run.

The runner tests the kernel that is currently booted; it does not install or
reboot kernels. To cover the full matrix, boot each BSP, forward-port, rewrite,
KASAN, and KCSAN image in turn and repeat the same two commands. The shared
standard set stays the same, while compatible target-specific rows are resolved
for that boot.

Use explicit selectors when planning off-board, testing detection itself, or
pinning a CI job to one matrix cell:

```bash
bash kernel-drivers/tests/run-conformance.sh \
  --target forward-port --configuration production --plan

sudo bash kernel-drivers/tests/run-conformance.sh \
  --target rewrite --configuration kcsan
```

Valid targets are `bsp`, `forward-port`, and `rewrite`. Valid configurations
are `production`, `kasan`, and `kcsan`. `auto` may be passed explicitly for
either axis.

## What the standard run tests

The standard set favors tests that can run unchanged across every kernel. It
adds rewrite-only boot checks automatically, but leaves long or destructive
stress tests as explicit opt-ins.

| Test | What it exercises | What a pass establishes |
|------|-------------------|--------------------------|
| `kunit` | Complete booted MPP and RGA rewrite KUnit manifests and their boot-log interval. Rewrite only. | The expected kernel-side lifecycle cases ran without a KUnit failure, skip, fatal boot signature, or disabled lockdep. It does not exercise real media hardware. |
| `system-info` | Running kernel, packages, device nodes, driver ownership, boot artifacts, and relevant board state. | The result is tied to a reconstructible boot and userspace identity. Discovery alone is not a functional pass. |
| `matrix-identity` | Vendor-versus-rewrite Kconfig, kernel series, and KASAN/KCSAN state. | The booted kernel matches the profile under which its logs will be stored. |
| `abi` | Safe MPP and RGA query, import/release, parser, and request-boundary ioctls. | The normalized userspace-visible contract matches the selected driver without submitting arbitrary hardware work. |
| `mpp` | Official MPP information, H.264/H.265/VP9/AVS2 decode, H.264/H.265 encode, multi-thread, multi-instance, slice-polling, rate-control, and legacy API cases when their inputs are available. | Required cases complete, produced artifacts are recorded, and the bounded kernel-log/counter gates are clean. The exact media matrix depends on available assets. |
| `librga` | Official librga copy, fill, resize, conversion, blending, transform, allocator, async/fence, tiled/FBC, and maintained deterministic smoke cases. | Required operations and output checks pass, hardware counters move where required, idle gauges settle, and fatal sample diagnostics cannot be hidden by misleading process statuses. |
| `gstreamer` | MPP/RGA plugin discovery, encode/decode/transcode, buffer pools, DMABuf, caps changes, flush/EOS/restart loops, parallel pipelines, AFBC, and 10-bit paths. | Required pipelines survive real GStreamer state and allocator transitions with expected artifacts and clean bounded kernel evidence. |
| `ffmpeg` | ffmpeg-rockchip RKMPP decode/encode, PSNR checks, RKRGA scale/vpp/overlay, and hardware transcodes. | Required codec/filter paths use the staged Rockchip FFmpeg build, meet correctness checks, record artifacts, and leave clean kernel evidence. |

All rows come from [`TESTS.tsv`](TESTS.tsv). A suite-level pass is more than an
exit code: depending on the target and configuration, the harness also checks
required case results, artifact manifests, debugfs counter deltas, idle gauges,
and a bounded dmesg window.

## How target and configuration detection works

The runner reads `/boot/config-$(uname -r)` before it creates the profile:

| Observed identity | Selection |
|-------------------|-----------|
| Rewrite MPP and RGA Kconfig | `rewrite` |
| Vendor `ROCKCHIP_MPP_SERVICE` and `ROCKCHIP_MULTI_RGA` on 5.10, 6.1, or 6.6 | `bsp` |
| Vendor `ROCKCHIP_MPP_SERVICE` and `ROCKCHIP_MULTI_RGA` on any other kernel series | `forward-port` |
| `CONFIG_KASAN=y` | `kasan` |
| `CONFIG_KCSAN=y` | `kcsan` |
| Neither sanitizer | `production` |

Detection and runtime verification use the same predicates from
[`targets/`](targets/) and [`configurations/`](configurations/). Missing,
contradictory, or multiply matching identities fail instead of being guessed.
Explicit selectors do not bypass `matrix-identity`; a mislabeled run fails
before the consumer suites.

`CONFIG_VIDEO_ROCKCHIP_RGA=m` is the separate mainline V4L2 driver and may
coexist with the vendor target. It is not the vendor multi-RGA identity used by
the `/dev/rga` suites.

For fixture or off-board plans, point detection at another artifact:

```bash
CONFORMANCE_KERNEL_CONFIG=/path/to/kernel.config \
CONFORMANCE_KERNEL_RELEASE=6.18.38-ysp \
bash kernel-drivers/tests/run-conformance.sh --plan
```

## Run more, fewer, or specific tests

First inspect the catalog as resolved for the selected matrix:

```bash
sudo bash kernel-drivers/tests/run-conformance.sh --list
```

The selection options have distinct purposes:

- `--include ID1,ID2` adds compatible opt-in tests to the standard set.
- `--only ID1,ID2` runs only those compatible tests for focused debugging.
- `--skip ID1,ID2` removes tests from the selected set; record why when using
  this for evidence.
- `--continue` runs the remaining selected tests after a failure, then returns
  nonzero at the end.

Examples:

```bash
# Add the optional application-level MPP/RGA consumer.
sudo bash kernel-drivers/tests/run-conformance.sh --include rkmppenc

# Re-run only ABI and MPP after a focused driver change.
sudo bash kernel-drivers/tests/run-conformance.sh --only abi,mpp

# Broad forward-port KASAN run, including compatible safety tests.
sudo bash kernel-drivers/tests/run-conformance.sh \
  --target forward-port --configuration kasan \
  --include rkmppenc,reset-session-kasan,ioctl-fuzz-kasan,iommu-stress \
  --continue

# Broad rewrite KCSAN run, including race and recovery stress.
sudo bash kernel-drivers/tests/run-conformance.sh \
  --target rewrite --configuration kcsan \
  --include rkmppenc,iommu-stress,recovery-stress,reset-contention \
  --continue
```

The opt-in catalog is:

| Test | Compatible matrix | Purpose |
|------|-------------------|---------|
| `rkmppenc` | All targets and configurations | Independent application-level MPP encode and MPP/RGA resize/transcode coverage. |
| `reset-session-kasan` | Forward-port KASAN | Regression coverage for reset-session lifetime faults. |
| `ioctl-fuzz-kasan` | All KASAN targets | Bounded non-submit ioctl mutation plus allocation/unwind fault injection. |
| `iommu-stress` | Forward-port or rewrite under KASAN/KCSAN | Concurrent RGA scatter and decode work with IOMMU correctness and leak oracles. |
| `recovery-stress` | Rewrite under KASAN/KCSAN | Kill/close, reset-opener, and recovery boundaries around live work. |
| `reset-contention` | Rewrite KCSAN | Sibling-core reset contention and race-oriented evidence. |

The harness rejects an explicitly requested test when its target or
configuration is incompatible. This prevents a typo from silently producing a
narrower run than requested.

## Compare two kernels

Run the baseline and candidate with the same userspace, assets, and
configuration. Results are stored by profile, so the two boots do not overwrite
one another.

```bash
# Boot the forward-port production kernel and collect its baseline.
sudo bash kernel-drivers/tests/run-conformance.sh

# Boot the rewrite production kernel, run it, then compare comparable suites.
sudo bash kernel-drivers/tests/run-conformance.sh --compare-to forward-port
```

For sanitizer comparisons, name the matching baseline profile, such as
`forward-port-kasan`. The comparators check shared required cases and, where the
suite supports them, artifact sizes/checksums. Set `PERF_MAX_RATIO` only when a
production timing threshold is meaningful; sanitizer configurations disable
timing failures by default.

## Results and pass criteria

The default runtime root is
`../rock-5b/build/rockchip-conformance`. Override it with `CONFORMANCE_ROOT`.
Logs are written below:

```text
$CONFORMANCE_ROOT/logs/$PROFILE/
  <run>-conformance-plan.tsv
  <run>-system/
  <run>-matrix-identity.tsv
  <run>-mpp-suite/
  <run>-librga-suite/
  <run>-gstreamer-suite/
  <run>-ffmpeg-suite/
```

Production profile names are `bsp`, `forward-port`, and `rewrite`. Instrumented
profiles append the configuration, for example `forward-port-kasan` and
`rewrite-kcsan`.

A full run passes only when every selected required step passes. With
`--continue`, failures are accumulated but the final status is still nonzero.
When reviewing a run, check:

1. `conformance-plan.tsv` shows the intended matrix and no accidental skips.
2. `matrix-identity.tsv` matches the booted release and Kconfig.
3. Each selected suite's `summary.tsv` contains no failed required case.
4. Required `artifacts.tsv`, counter-delta, and dmesg reports are present and
   clean.
5. A paired claim also has comparator-clean baseline and candidate results.

`--validate` is different: it runs device-free catalog, parser, builder,
comparator, and evidence-audit selftests. It is the harness maintenance gate,
not proof that a kernel works on RK3588 hardware:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
bash kernel-drivers/tests/run-conformance.sh --validate
```

## Prerequisites and runtime bundle

Hardware runs normally need root access, `/dev/mpp_service`, `/dev/rga`, DMA
heaps, readable debugfs/procfs state, and readable dmesg. The standard consumer
suites additionally expect:

- installed matching MPP runtime, development, and official test packages;
- installed `librga-dev` plus built official sample binaries;
- the staged JeffyCN GStreamer Rockchip plugin and event harness;
- a staged ffmpeg-rockchip `ffmpeg` and `ffprobe`;
- shared input media under `$CONFORMANCE_ROOT/assets/` when a case cannot
  generate its own input.

The external runtime bundle deliberately lives outside this repository because
it contains third-party checkouts and generated outputs. The workspace
bootstrap is [`../../scripts/bootstrap-workspaces.sh`](../../scripts/bootstrap-workspaces.sh);
the full build and asset requirements are documented in
[`../conformance.md`](../conformance.md). Run `--plan` before hardware work, but
remember that asset-dependent cases are resolved inside their suites: the
resulting `summary.tsv` is the authoritative record of what actually ran.

## Catalog and helper reference

The maintained harness definition is small:

- [`TESTS.tsv`](TESTS.tsv) declares ordering, compatibility, default selection,
  runner type, comparator eligibility, and purpose.
- [`targets/`](targets/) describes BSP, forward-port, and rewrite identity plus
  target-specific runtime policy.
- [`configurations/`](configurations/) describes production, KASAN, and KCSAN
  identity plus dmesg/performance policy.
- [`MANIFEST.tsv`](MANIFEST.tsv) pins optional third-party source checkouts used
  to reconstruct the external bundle.

The scripts in this directory are lower-level setup and diagnostic helpers;
normal qualification should enter through `run-conformance.sh`:

| Helper | Use |
|--------|-----|
| `scripts/bootstrap-sources.sh` | Clone and verify the source revisions in `MANIFEST.tsv`. |
| `scripts/collect-system-info.sh` | Collect identity directly or selftest its boot-identifier redaction. The standard `system-info` row calls its deployed copy. |
| `scripts/build-mpp.sh` | Build a pinned legacy MPP comparison, not the normal installed-runtime path. |
| `scripts/build-librga-samples.sh` | Build the pinned official librga samples. |
| `scripts/make-librga-pkgconfig.sh` | Generate the explicit pkg-config shim needed by that legacy librga source. |
| `scripts/build-gstreamer-rockchip.sh` | Delegate to the maintained patched builder [`../build-gstreamer-rockchip.sh`](../build-gstreamer-rockchip.sh); kept as a stable entry point so deployed workspaces never rebuild the plugin without the maintained patches. |
| `scripts/run-mpp-smoke.sh` | Direct narrow MPP smoke for setup debugging. |
| `scripts/run-librga-smoke.sh` | Direct narrow official-sample smoke for setup debugging. |
| `scripts/run-gstreamer-smoke.sh` | Direct narrow plugin smoke for setup debugging. |
| `scripts/list-built-binaries.sh` | Show executable files staged under the bundle's `out/` directory. |

Use the direct helpers to diagnose setup problems. Do not substitute their
narrow green result for a catalog-driven conformance pass.
