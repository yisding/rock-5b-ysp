# Reproducers

These are the standalone C programs used while debugging Panfrost texture
transfers on ROCK 5B / Mali-G610, plus the archived Mesa patch needed to
rebuild the failing BLIT configuration. Most top-level reproducers use GBM/EGL
and GLES 3.x directly, so run them on the board with a Mesa build that includes
Panfrost. The standalone interpolation probes now live in
[`interp_probe/`](interp_probe/README.md).

| File | One-liner |
|---|---|
| [`0001-panfrost-advertise-transfer-blit-and-compute.patch`](../patches/0001-panfrost-advertise-transfer-blit-and-compute.patch) | `format-patch` archive of the BLIT-advertising commit (`e8cf2ae6daa`); apply to a Mesa tree to reproduce the BLIT failure and the BLIT column of the timing table — reproduction-only, not for merging; full provenance in its annotation block |
| [`u_blitter-review2-txf-fragcoord-cleanups.patch`](../patches/u_blitter-review2-txf-fragcoord-cleanups.patch) | Second `/code-review` round (2026-07-03) of `panfrost-blit-transfers`: two behavior-preserving `u_blitter` cleanups — a shared `blitter_target_supports_txf()` predicate (#2) and threading the chosen `use_txf_fragcoord` out of the four texfetch helpers via an out-param instead of recomputing it in `util_blitter_blit_generic` (#3). Revalidated 0-regression on device (reproducers + dEQP + piglit); see `../docs/rebuild-and-test.md` |
| [`repro_blit.c`](repro_blit.c) | End-to-end failure repro: RG32UI→RGBA32UI `glReadPixels` through the u_blitter TXF staging blit |
| [`repro_blit_off.c`](repro_blit_off.c) | Non-zero-offset variant: subregion readback at `x = X0`, exercising the blit affine's offset term in the fragcoord fix |
| [`repro_blit_float.c`](repro_blit_float.c) | RG32F→RGBA32F float variant — the counter-example that disqualifies the integer-only state-tracker fallback |
| [`repro_blit_flip.c`](repro_blit_flip.c) | Flipped `glBlitFramebuffer` probe (negative scale); caught the pixel-center-convention bug, revealed the power-of-two-extent exactness, and proved the system Mesa 26.0.3 driver corrupts wide non-pow2 blits |
| [`repro_blit_scissor.c`](repro_blit_scissor.c) | Scissored wide identity blit: verifies clipping doesn't shift the fragcoord mapping and untouched texels keep their sentinel |
| [`repro_blit_array.c`](repro_blit_array.c) | 2D-array-layer readback: found the array regression (15672/16307), now exact via the series' single-layer view commit |
| [`interp_probe/`](interp_probe/README.md) | Standalone interpolation probes: historical GBM/GLES, minimal surfaceless raw-varying, normalized-coordinate ordinary-TEX, and Vulkan/panvk variants; includes the zero-valued depth-bias workaround A/B controls |
| [`probe_const.c`](probe_const.c) | Constant-varying exactness probe: shows all-vertices-equal smooth varyings interpolate bit-exactly at every magnitude |
| [`probe_wcorr.c`](probe_wcorr.c) | Shader-side recovery probe: disproves `gl_FragCoord.w` and `dFdx`-based correction |
| [`repro_afbc.c`](repro_afbc.c) | Scoped negative result: the AFBC CPU-map staging path is clean on unfixed drivers (direct wide blits are NOT — see `repro_blit_flip.c`) |
| [`bench_transfer.c`](bench_transfer.c) | BLIT-vs-COMPUTE timing microbenchmark for the same readback shape |
| [`blit_workaround_bench.c`](blit_workaround_bench.c) | Real-API `glBlitFramebuffer` benchmark for the MR !43161 depth-bias workaround: resource-ring correctness, batched-throughput and isolated-latency schedules, separate CPU/GPU/completion timing, count sweeps, percentiles, and `T(N) = A + N*B` fits |
| [`run_blit_workaround_bench.py`](run_blit_workaround_bench.py) | Runs an instrumented Mesa binary in alternating `off/on/on/off` and `on/off/off/on` process blocks, checks the G610 clock around every child, and reports paired fixed-cost and per-blit-slope deltas |
| [`mr42563-comment-failures.txt`](mr42563-comment-failures.txt) | The exact 25 dEQP-GLES3 case names from the MR !42563 review comment, rerun locally after the COMPUTE switch |

The older top-level GL probes load all GL entrypoints via `eglGetProcAddress`
specifically to bypass glvnd and guarantee the locally built Mesa driver is
exercised. The interpolation-probe directory documents its exceptions:
`tiny_interp_probe.c` and `tex_interp_probe.c` link `libGLESv2` directly, and
`vk_interp_probe.c` uses Vulkan/panvk.

## Build

```bash
cc -O2 -o repro_blit repro_blit.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_off repro_blit_off.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_float repro_blit_float.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_flip repro_blit_flip.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_scissor repro_blit_scissor.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_blit_array repro_blit_array.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o probe_const probe_const.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o probe_wcorr probe_wcorr.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o repro_afbc repro_afbc.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o bench_transfer bench_transfer.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -Wall -Wextra -Werror -o blit_workaround_bench \
  blit_workaround_bench.c -lEGL -lGLESv2 -lm
```

Build the interpolation probes from their own directory:

```bash
cd interp_probe
cc -O2 -o probe_interp probe_interp.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o tiny_interp_probe tiny_interp_probe.c -lEGL -lGLESv2 -lm
cc -O2 -o tex_interp_probe tex_interp_probe.c -lEGL -lGLESv2
glslc vk_interp_probe.vert           -o vk_interp_probe.vert.spv
glslc vk_interp_probe.varying.frag   -o vk_interp_probe.varying.frag.spv
glslc vk_interp_probe.fragcoord.frag -o vk_interp_probe.fragcoord.frag.spv
cc -O2 -o vk_interp_probe vk_interp_probe.c -lvulkan -lm
```

If testing a local Mesa build, point the loader at the built DRI target, for
example:

```bash
export LD_LIBRARY_PATH=/path/to/mesa/build/src/egl:/path/to/mesa/build/src/gbm:/path/to/mesa/build/src/gallium/targets/dril
export LIBGL_DRIVERS_PATH=/path/to/mesa/build/src/gallium/targets/dril
export GBM_BACKENDS_PATH=/path/to/mesa/build/src/gbm/backends/dri
export EGL_PLATFORM=surfaceless
```

`GBM_BACKENDS_PATH` is required as well as `LD_LIBRARY_PATH`: the build's
`libgbm` otherwise searches only its configured prefix for `dri_gbm.so`
(`MESA-LOADER: failed to open dri: ... (search paths /usr/local/lib/...gbm)`)
and `gbm_create_device()` fails — observed on the board 2026-07-01 when the
previously used `/usr/local` Mesa prefix had been removed.

The programs default to `/dev/dri/renderD128`. `repro_blit.c` and
`bench_transfer.c` also honor:

```bash
REPRO_NODE=/dev/dri/renderD128
```

(`repro_blit_off.c` and `repro_blit_float.c` honor it too; `probe_wcorr.c`,
`probe_const.c`, and `repro_afbc.c` hardcode `renderD128`. The
`interp_probe/` README documents the interpolation probes' GBM, surfaceless
EGL, and Vulkan device-selection behavior.)

## `0001-panfrost-advertise-transfer-blit-and-compute.patch`

The BLIT-vs-COMPUTE comparison needs a Mesa build whose default transfer path
is the sampled BLIT — a configuration no upstream tree will ship once the MR
lands in any form. This patch is the pristine `git format-patch` export of
local commit `e8cf2ae6daa` ("panfrost: enable blit-based texture transfers",
branch `panfrost-transfer-blit` of `github.com/yisding/mesa`).

- It advertises `PIPE_TEXTURE_TRANSFER_BLIT` **only**; no local commit ever
  advertised `BLIT|COMPUTE`. The COMPUTE side of every comparison was forced
  on the same build with `MESA_COMPUTE_PBO=1`.
- Apply it on top of the shader-image mask fix ("panfrost: clear shader image
  mask on trailing unbinds", `Fixes: 72ff66c3d73`) — local `950d19686d8`, on
  Mesa main `c05334058d5` (2026-06-22). `git apply --check` also passes
  against later 26.2-devel trees that still carry
  `caps->texture_transfer_modes = 0;` (verified 2026-07-01).
- The annotation block between the commit message and the diff (ignored by
  `git am`) records the full provenance and the
  `BIFROST_MESA_DEBUG=shaders` disassembly-capture method behind the asm
  listings in [`../docs/blit-precision.md`](../docs/blit-precision.md).

## `repro_blit.c`

Minimal reproducer for the format-changing integer readback path.

It creates an `RG32UI` texture where `source[i] = {i, i}`, attaches it to an FBO,
then reads it back as `RGBA_INTEGER`/`UNSIGNED_INT`. With the sampled BLIT
transfer path, Mesa stages this through a `u_blitter` TXF shader.

Run:

```bash
./repro_blit 16307
```

Observed BLIT failure on Mali-G610:

```text
W=16307  mismatches=15672 / 16307
i=1024   sampled=1023
i=8192   sampled=8185
i=16306  sampled=16293
```

Expected with COMPUTE or CPU fallback:

```text
mismatches=0/16307
```

## `repro_blit_off.c`

Non-zero-offset variant of `repro_blit` (added 2026-07-01). Same `RG32UI`
texture, but reads back the subregion `glReadPixels(X0, 0, W - X0, 1, ...)`,
so the staging blit runs with `src_x1 = X0`, `dst_x1 = 0` — i.e. a large
`offset` term in the fragcoord fix's `src = gl_FragCoord * scale + offset`
affine, which the original repro (offset 0) never exercised.

Run:

```bash
./repro_blit_off 16307 8000     # W X0
```

Observed on the `panfrost-transfer-fragcoord-blit` branch
(`git-2f6e8a6afc`, 2026-07-01): **0 mismatches at X0 = 1, 623, 8000, 16000**.

## `repro_blit_float.c`

Float variant of `repro_blit` (added 2026-07-01) — **the counter-example that
disqualified the integer-only state-tracker fallback** (local branch
`panfrost-transfer-targeted-fallback`, `6a292503585`).

The interpolation drift affects every wide sampled TXF blit regardless of
format; pure-integer transfers were merely the only case dEQP could detect
bit-exactly. This repro builds an `RG32F` texture with `source[i] = {i, i}`
and reads it back as `GL_RGBA` + `GL_FLOAT` (valid for float color buffers
under `EXT_color_buffer_float`). That is a format-changing
(`RG32F -> RGBA32F` staging) but **non-pure-integer** readback, so the
fallback branch's `util_format_is_pure_integer` gate does not catch it.

Run:

```bash
./repro_blit_float 16307
```

Observed on Mali-G610 (2026-07-01):

```text
targeted-fallback build git-6a29250358:  mismatches=15672/16307 (96.1%)
                                         first_mismatch=623   <- original bug signature
fragcoord build git-2f6e8a6afc:          mismatches=0/16307
```

The integer control (`repro_blit`) passes on both builds, so the fallback's
gate works as written — it is simply under-inclusive. Widening it to "any
format change" would effectively disable the transfer blit, which is why the
fallback direction was dropped rather than patched.

## Interpolation probes

The interpolation-specific reproducers now live in
[`interp_probe/`](interp_probe/README.md): the historical GBM/GLES probe,
the minimal surfaceless GLES probe, the Vulkan/panvk port, and the Vulkan
shader sources. That README is the canonical place for what each probe
isolates, how to build and run it, exit codes, controls, and expected
ROCK 5B / Mali-G610 output.

## `repro_blit_flip.c`

Flipped-blit probe (added 2026-07-01). `glBlitFramebuffer` with flipped
coordinates is an unscaled nearest blit, so u_blitter takes the TXF path
with **scale = -1** on the flipped axis — the one affine case the other
repros never exercise. Renders `{x, y}` into `RG32UI` via `gl_FragCoord`,
blits identity / Y-flip / X-flip / XY-flip, verifies every texel.

Run:

```bash
./repro_blit_flip 16307 8     # W H
```

Two findings came out of this probe (both 2026-07-01, Mali-G610):

1. **Pixel-center-convention bug in the first fragcoord branch.** Panfrost's
   TGSI position system value yields the *integer pixel index*, not
   `x + 0.5`. With a positive scale the missing half texel is hidden by the
   truncating `f2i`; with a negative scale every fetch lands one texel off
   and row/column 0 goes out of bounds (all flip modes returned
   identity-looking/garbage data). Fixed by making the shader
   convention-independent: `src = floor(pos) * scale + (offset + 0.5*scale)`.
2. **The drift only occurs for non-power-of-two primitive extents.**
   Unfixed-path 1-row identity blits: `W=8192` and `W=16384` are bit-exact,
   while `W=5000/7000/8191/8193/12000/16307` all drift (`W=16307`:
   15672/16307 wrong, first at x=623; `W=3000` and below exact — onset
   between 3000 and 5000). The interpolator's plane-equation reciprocal is
   exact for powers of two. Height does not matter (H=2..8 identical). This
   is why common (pow2 or small) blit sizes never showed the bug, and why
   any regression test must use a large non-pow2 width.

Shipped-driver result (Mesa 26.0.3, no series patches): 16307x2 RG32UI
returns **29498/32614 wrong texels** (first at x=1539, fetched 1538) in all
four orientations — the corruption is reachable through plain
`glBlitFramebuffer` today, independent of `texture_transfer_modes`. Verified
on the final series build: all four modes exact at 12000x8 and 16307x2.

## `repro_blit_scissor.c`

Scissored wide-blit probe (added 2026-07-01). `glScissor` applies to
`glBlitFramebuffer`; u_blitter forwards it as scissor state while the
fragcoord path derives source texels purely from fragment position, so
clipping must not shift the mapping. Identity blit of 16307x8 RG32UI with
scissor `(5435,2 8153x4)`, destination pre-filled with a sentinel.

Observed on the series build (2026-07-01): inside scissor **0/32612**
mismatches; outside scissor **0/97844** sentinel overwrites.

## `repro_blit_array.c`

Array-target gating probe (added 2026-07-01). The fragcoord fix is gated to
1D/2D/RECT; array targets stay on the interpolated-varying TXF path. This
reads back a wide `RG32UI` **2D-array layer** (`glFramebufferTextureLayer`)
through the format-changing staging blit.

Observed at W=16307 (2026-07-01):

```text
series build (BLIT transfers on):  15672/16307 corrupt, first at 623
system driver (transfer modes 0):      0/16307 (CPU path, exact)
```

This was a **correctness regression vs. the CPU path** that no dEQP/piglit
case covers. **RESOLVED the same day**, finally by generalizing the
fragcoord mechanism to all single-sample TXF targets (1D/2D/RECT, arrays
single- and multi-layer, 3D) with a sign-bits/layer/offsets attribute
encoding — an interim single-layer-view commit was superseded. After the
fix this probe reports **0/16307**, and the u_tests case grew to seven
checks across 2D/flip/array/3D. Extending the mechanism also exposed a
second bug in the earlier branch revision: the draw-side gate did not
exclude **MSAA** sources (`fbo.msaa.*` 62/70 Fail -> 0 Fail after gating
on `nr_samples <= 1`). The *pre-existing* `glBlitFramebuffer` corruption
from wide array-layer attachments is fixed by the same mechanism.

## `probe_const.c`

Constant-varying exactness probe (added 2026-07-01). The fragcoord u_blitter
fix passes the blit affine (`scale.xy`, `offset.zw`) through the ordinary
smooth-interpolated vertex attribute — the same varying unit that is ~2^-10
lossy for values that vary. This probe answers whether a varying that is
**constant across the primitive** (all vertices equal) survives that path
bit-exactly, even at large magnitudes.

It renders a `W x 1` quad with a smooth `float` varying set to `K` at all
vertices and writes `floatBitsToUint(v_k)` to an `R32UI` target.

Run:

```bash
./probe_const 16307 16000.25    # W K
```

Observed on Mali-G610 (`git-2f6e8a6afc`, 2026-07-01):

```text
K = 1.0, 100.5, 1000.25, 10000.25, 16000.25, 16306.5
bit_mismatches = 0 / 16307 at every K
```

So only varyings that actually *vary* accumulate the ~2^-10 relative error;
per-draw constants are safe through the smooth path at any magnitude. This
removed the one numerical design risk in the fragcoord branch (a large
`offset` from a subregion blit) without needing flat interpolation, and it
means extending the fix to array layers (layer = another per-draw constant)
is numerically safe too.

## `probe_wcorr.c`

Shader-side recovery probe.

This checks whether the fragment shader can recover an exact coordinate using
local information such as derivatives. It could not; the derivative-based
candidate was worse than using the raw varying:

```text
raw floor(tc)!=i        : 15672 / 16307
dFdx reconstruction     : 16187 / 16307
```

The file name is historical. Earlier variants checked whether
`gl_FragCoord.w` carried a useful correction term — it does not:
`gl_FragCoord.w` is exactly `1.0` in this draw, so dividing by it changes
nothing (identical 15672/16307).

## `repro_afbc.c`

Negative-result probe (added 2026-07-01): does the interpolation drift
already corrupt **shipped** drivers through the pre-existing AFBC CPU-map
staging path (`pan_blit_to_staging` in `pan_resource.c`, used because
Panfrost has no software AFBC codec)?

It renders an x-index pattern into a wide `RGBA8` texture with `gl_FragCoord`
(exact), then reads it back with `glReadPixels` in the **matching** format so
the state tracker takes the CPU fallback, which maps the resource — for an
AFBC layout that goes through the u_blitter staging blit.

Run (also try `PAN_MESA_DEBUG=forcepack`):

```bash
./repro_afbc 4096 16     # W H
```

Observed 2026-07-01: **0 mismatches** on both the unfixed system driver
(Mesa 26.0.3) and the fragcoord branch build. So *this particular path* is
clean in the system Mesa 26.0.3 driver (the FBO texture likely never takes an AFBC layout
here, or the map demotes it first). NOTE: this negative result initially led
to a too-broad "system drivers are unaffected" conclusion — later
`repro_blit_flip.c` testing showed direct wide non-pow2 `glBlitFramebuffer`
**is** corrupt on the system Mesa 26.0.3 driver (see that probe's section).

## `bench_transfer.c`

Microbenchmark for the same `RG32UI -> RGBA32UI` readback shape.

Comparative mode needs a build that takes the BLIT path by default — i.e. a
tree with
[`0001-panfrost-advertise-transfer-blit-and-compute.patch`](../patches/0001-panfrost-advertise-transfer-blit-and-compute.patch)
applied. The default path then selects BLIT while `MESA_COMPUTE_PBO=1` forces
COMPUTE:

```bash
ST_DEBUG=noreadpixcache ./bench_transfer 16307 1 80 10
ST_DEBUG=noreadpixcache MESA_COMPUTE_PBO=1 ./bench_transfer 16307 1 80 10
```

Useful dimensions from the local timing pass:

```bash
./bench_transfer 16307 1
./bench_transfer 16000 1
./bench_transfer 16384 1
./bench_transfer 1024 1024
./bench_transfer 4096 256
```

Recorded medians are in [`../docs/validation.md`](../docs/validation.md).

## `blit_workaround_bench.c`

This is the implementation companion to the
[per-blit benchmark plan](../../../findings/2026-07-27-mali-blit-workaround-performance-benchmark-plan.md).
The first six-size A/B run is recorded in the
[benchmark-results finding](../../../findings/2026-07-27-mesa-all-blit-workaround-benchmark-results.md):
the workaround fixed both affected geometries, but the unlocked clocks and a
GPU query that did not scale with operation count left per-blit cost unresolved.
Unlike `offset_perf_probe.c`, every counted operation enters
`glBlitFramebuffer`, rotates through independently initialized `R32UI`
source/destination FBOs, and therefore asks Mesa to save, bind, draw, and
restore its internal blitter state. Initialization, lazy internal-shader
creation, and final full-surface verification are outside the timed regions.

One process measures one driver mode. The test-only Mesa build must consume a
process-start override (the runner defaults to `PAN_BLIT_DEPTH_BIAS=off|on`)
that forces only the internal Panfrost fullscreen-blit workaround decision.
The exact override used by this repository is archived as
[`mr43161-benchmark-override.patch`](../patches/mr43161-benchmark-override.patch)
and applies on top of MR !43161 commit `647256dc2ae`.
The label in this program's output does **not** prove that Mesa honored the
override; the runner therefore requires the patched driver's
`PAN_BLIT_DEPTH_BIAS=<mode>` startup acknowledgement. Before treating timings
as MR !43161 evidence, also use the plan's validation counters and descriptor
trace to prove one internal draw and one workaround decision per API operation,
with only the enable bit changing and factor, units, and clamp remaining zero.

The local instrumented build is branch `benchmark/mr43161-all-blits`, commit
`0c1cf4a71b4`, in `/home/yi/Code/fdo/mesa-mr43161-bench`. It was configured
from MR !43161 commit `647256dc2ae` as a surfaceless, Panfrost-only
debug-optimized build. Rebuild it with the system toolchain and the shared
ccache directory:

```bash
cd /home/yi/Code/fdo/mesa-mr43161-bench
CCACHE_DIR=/home/yi/Code/.ccache \
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  ninja -C build-bench
```

`ccache --show-stats` reported 2,103 hits and 249 misses after the initial
build (89.41% of cacheable calls were hits). Use `meson devenv -C build-bench
env ...` to run against the uninstalled result; that environment supplies the
matching EGL vendor file, Gallium DRI module, GBM backend, and libraries.

For a quick functional smoke on any driver with
`GL_EXT_disjoint_timer_query`:

```bash
EGL_PLATFORM=surfaceless ./blit_workaround_bench \
  --width 64 --height 64 --counts 1,2,4,8 --samples 3 \
  --warmups 1 --ring 2 --schedule both --label smoke
```

For the phase-one G610 matrix, first lock GPU devfreq at 500 MHz as described
in the [plan's machine controls](../../../findings/2026-07-27-mali-blit-workaround-performance-benchmark-plan.md#machine-controls),
pin a CPU, point the loader at the instrumented Mesa build, and run each size
separately. Keep a shared count list for both A/B modes and shorten the list
when a large-size batch would exceed roughly 100 ms:

```bash
./run_blit_workaround_bench.py --blocks 2 --cpu 6 \
  --expect-gpu-hz 500000000 -- \
  --width 1024 --height 1024 --counts 1,2,4,8,16,64 \
  --samples 11 --warmups 2 --ring 4 --schedule both
```

Override names and values are configurable if the Mesa instrumentation uses a
different process option:

```bash
./run_blit_workaround_bench.py \
  --off-env PAN_TEST_BLIT_WA=never --on-env PAN_TEST_BLIT_WA=always -- \
  --width 12288 --height 1 --counts 1,2,4,8,16,64,256,1024
```

Output is CSV-like and intentionally keeps raw evidence:

- `SAMPLE`: one timing attempt and its disjoint flag;
- `POINT`: `p10`, median, and `p90` for CPU submission, GPU query, and
  completion wall time at one operation count;
- `FIT`: fixed intercept, per-blit slope, `R²`, RMS residual, and maximum
  absolute residual, all times in microseconds;
- `CORRECTNESS`: checked pixels and mismatches after the timed work;
- `BLOCK-DELTA`: paired `on - off` fixed/slope results for one ABBA/BAAB
  process block; and
- `DELTA`: median fixed delta, median slope delta, slope percentage, and the
  `p10..p90` slope-delta spread across blocks.

The primary decision signal is the `batched,gpu` slope. `batched,cpu` reports
submission/state cost, `batched,wall` reports end-to-end throughput, and the
three `isolated` rows are synchronization-heavy latency upper bounds. Inspect
the fit residuals; a poor linear fit means the point curve should be reported
instead of the slope. The initial implementation is deliberately phase-one
`R32UI`, 1:1 nearest blits. The plan's other formats, format-changing PBO
readback, scaled/flipped/scissored/layered/MSAA cases, and application frame
pacing remain follow-ups after the driver override and counter gates pass.

## `mr42563-comment-failures.txt`

The exact 25 dEQP cases from the MR !42563 review comment that were rerun
locally after switching the MR direction to COMPUTE (result: 24/25 Pass, 1
pre-existing QualityWarning — [`../docs/validation.md`](../docs/validation.md), which
also records the exact dEQP invocation).

## Rebuild + re-run harness

[`../scripts/`](../scripts) has a one-command rebuild
(`build-mesa-surfaceless.sh`), the runtime env (`mesa-panfrost-env.sh`), and
runners for the reproducers (`run-repro.sh`) and the dEQP cluster
(`run-deqp.sh` + `deqp-gles3-transfer-cases.txt`). The environment gotchas
(wiped `/tmp` build state, `mise` python shadowing) and the latest on-device
results are in [`../docs/rebuild-and-test.md`](../docs/rebuild-and-test.md).
