# Mali blit workaround size results for Mesa MR !43161

> Scope: shareable summary for the Panfrost/Mali-G610 varying-interpolation
> erratum discussed in Mesa MR !43161; the full technical record is
> [`2026-07-24-mali-oblong-triangle-matrix.md`](2026-07-24-mali-oblong-triangle-matrix.md).
> Source: ROCK 5B / Mali-G610 MC4 / Panfrost system Mesa 26.0.3-1ubuntu1;
> reproducer
> [`mr43161_size_repro.sh`](../video-libraries/mesa/reproducers/interp_probe/mr43161_size_repro.sh);
> performance follow-up
> [`offset_perf_probe.c`](../video-libraries/mesa/reproducers/interp_probe/offset_perf_probe.c);
> independent shader verifier
> [`offset_perf_verify.c`](../video-libraries/mesa/reproducers/interp_probe/offset_perf_verify.c).
> Date: 2026-07-24
> Trust: MEASURED (correctness scans and fixed-clock GPU timing on the board)

## Result

The zero-valued polygon-offset workaround changes the varying-interpolation path.
In the canonical 2D exactness scans through `4096x4096`, baseline and workaround
output are bit-identical only when both destination dimensions are powers of
two, treating `1` as `2^0`. This is a bit-exact statement, not the same as
integer correctness.

The integer/TXF-style condition is weaker: `floor(v.xy)` must still select the
current destination pixel. For the canonical Panfrost fullscreen-style blit
triangle, a full baseline scan of every integer size from `1x1` through
`500x500` passed that integer-bin test. Follow-up runs expanded the same
canonical scan through `1024x1024` with the same result and then through
`1500x1500`, which finds the first known `1xN` failure boundary:

```text
FULL-GRID-FLOOR-SUMMARY max=500 path=baseline cases=250000 pixels=15687562500 failing_cases=0
FULL-GRID-FLOOR-SUMMARY max=1024 path=baseline cases=1048576 pixels=275415040000 failing_cases=0
FULL-GRID-FLOOR-SUMMARY max=1500 path=baseline cases=2250000 pixels=1267313062500 failing_cases=2 first_failure=1x1480 last_failure=1x1490
FULL-GRID-FLOOR-SUMMARY max=2080 path=baseline cases=4326400 pixels=4683934777600 failing_cases=85 first_failure=2080x1 last_failure=2x2080 most_square_failure=2x2080 most_square_failure_aspect=1040.000000
```

The two `1500` failures are both `1xN` edge cases. Extending the canonical scan
through `2080x2080` found 85 integer-bin failures total; the follow-up line
scan accounts for all of them as `2080x1`, sparse `1xH` failures starting at
`1x1480`, and `2x2080`. No canonical integer-bin failures were found through
`2080x2080` where both dimensions are at least `3`. That also means the
directional rectangle `W <= 2079, H <= 1479` is clean for this canonical
orientation. The transpose is not clean, because `1x1480` already fails.

This does not prove that arbitrary triangle topologies are safe below
`1480x1480`; the full 256-case topology matrix was only run at selected sizes.
The scan is evidence for the fullscreen-style triangle used by the Panfrost
internal blit path, not for every possible application triangle.

These integer-grid scans also do not validate ordinary non-integer `texture()`
coordinates. The separate TEX probe shows the same hardware issue can affect
normalized nearest-filtered TEX at larger sizes (`12288x1` and `16307x1`), so
the integer proof should not be reused as a general floating-point TEX safety
proof. In GL, color framebuffer blits can request `GL_NEAREST` or `GL_LINEAR`;
integer/depth/stencil cases require nearest-style behavior. The local TEX probe
uses normalized floating-point coordinates with `texture()` and `GL_NEAREST` so
the oracle stays exact. A bitwise coordinate difference only becomes a visible
nearest-TEX error when it crosses a texel-selection boundary; with linear
filtering, the same drift changes blend weights and possibly the contributing
texels. Non-power-of-two sizes are therefore not automatically wrong, but we do
not have a reliable non-power-of-two safe predicate for TEX. The only clean
bit-exact exemption observed so far is both dimensions powers of two.

## Boundary checks

The `1xN` / `Nx1` integer-bin rerun on Panfrost found no integer failures in the
800s or 900s. The likely confusion there was aspect ratio, not dimension.

| Scan | First baseline integer-bin failure | Baseline failing cases through 4096 | Workaround integer-bin failures |
|---|---:|---:|---:|
| `Nx1` | `2080x1` | 667 | 0 |
| `1xN` | `1x1480` | 1334 | 0 |
| `Nx2` | `2947x2` | 158 | 0 |
| `2xN` | `2x2080` | 637 | 0 |

For bit-exact equality on those same line scans, the matching sizes were only:

```text
1-2,4,8,16,32,64,128,256,512,1024,2048,4096
```

Selected full-surface 2D cases match that rule:

| Size | Bit-identical baseline vs workaround? | Integer-bin safe without workaround? |
|---|---|---|
| `1024x2048`, `2048x2048`, `4096x4096` | yes | yes |
| `4096x3`, `3x4096`, `4096x4095` | no | yes |
| `4095x4095`, `4095x383`, `4095x341` | no | yes |

So "one dimension is a power of two" is not enough for bit-exact equality.

## Aspect-ratio evidence

Aspect ratio is not a clean predicate. We have failures at high ratios, failures
down in the 100s for oversized/fullscreen-style triangles, and nearby passes.

| Case | Aspect | Result |
|---|---:|---|
| `9350x11` / `11x9350` | 850.000 | full 256-case matrix: 128 baseline-only failures; workaround passes |
| `12848x14` / `14x12848` | 917.714 | full 256-case matrix: 128 baseline-only failures; workaround passes |
| `16383x96` | 170.656 | full 256-case matrix: 8 oversized baseline-only failures; workaround passes |
| `16383x127` | 129.000 | full 256-case matrix: 8 oversized baseline-only failures; workaround passes |
| `16384x96` | 170.667 | power-of-two control passes |
| canonical `25..50` aspect band through `16384x16384` | 25.000 to 50.000 | 5,370,014 size pairs / 21,622,855,556,080 fragments: 0 integer-bin failures |
| canonical `50..100` aspect band through `16384x16384` | 50.000 to 100.000 | 2,685,006 size pairs / 5,405,732,710,480 fragments: 0 integer-bin failures |
| `16383x100`, `16383x104`, `16383x112`, `16383x128` | 163.830 down to 127.992 | sampled/full checks passed |

The `16383x127` result is topology-sensitive. The canonical BL/CCW
fullscreen-style probe passes as wide (`16383x127`, `baseline_floor_bad=0`) but
fails when transposed (`127x16383`, `baseline_floor_bad=44704`). The full matrix
finds the failing oversized orientations in both axes. This is the lowest
measured full-matrix failing aspect ratio so far.

For Mesa MR !43161, the relevant special path is the Panfrost blitter rectangle
override: on the affected path it maps the destination rectangle through
viewport/scissor and calls the driver's fullscreen draw hook. That is why the
fullscreen-style triangle scans are directly relevant to the workaround. Paths
that fall back to ordinary `u_blitter` rectangle drawing have different geometry
and are not proven by the canonical sweep.

The safest conclusion is that we do not know an exact aspect-ratio boundary.
The canonical `25..50` and `50..100` aspect-band scans through `16Kx16K` did
not find integer-bin failures, but the measured field is jagged enough that
`1000`, `500`, `100`, or a lower threshold is still a policy compromise, not
the hardware predicate. The robust predicate remains: apply the workaround on
the affected Panfrost fullscreen/blit path for affected Valhall generations,
rather than trying to derive safety from dimensions or aspect ratio.

## Performance

The performance follow-up was measured and independently rerun on 2026-07-27
with the GPU fixed at `500 MHz`
(`min_freq=max_freq=cur_freq=500000000`). For the policy question "what happens
if we enable the workaround on every affected Panfrost fullscreen blit?", the
answer remains: **workaround-enabled blits were about 0.5% slower**. Across the
original seven sizes, the first run's median central estimate was `+0.49%` and
the clean-source rerun's was `+0.48%`. Excluding the setup-dominated `1x1`
case, the rerun ranged from `+0.40%` to `+0.73%` with a `+0.50%` median.

That half-percent result is small but more precise than the initial
`simple_ondemand` runs. With the governor free to move between 300 MHz and
1 GHz, the tiny cases changed sign and some paired spreads were unusably wide.
Those unlocked-clock numbers were rejected. Even at a fixed clock, `1x1`,
`16x16`, and `64x64` have wide per-block spreads and changed sign on rerun.
They measure submission/setup noise more than useful fragment work and should
not be treated as size-specific constants.

[`offset_perf_probe.c`](../video-libraries/mesa/reproducers/interp_probe/offset_perf_probe.c)
measures a cache-warm fullscreen `texelFetch` blit with three paths:

1. interpolated-varying baseline;
2. the same shader and geometry with zero-valued polygon offset enabled; and
3. a direct `gl_FragCoord.xy` source-coordinate control.

The independent
[`offset_perf_verify.c`](../video-libraries/mesa/reproducers/interp_probe/offset_perf_verify.c)
companion fills the `R32UI` source with unique pixel IDs, renders each path once,
and compares every destination pixel. Its default `12288x1` G610 run confirms
that the timed shader choices have the expected correctness split:

```text
baseline mismatches=11744 first=(529,0)
workaround mismatches=0
fragcoord mismatches=0
verdict=PASS
```

An expanded 20-size run checked tiny, non-power-of-two, square, display-sized,
wide, tall, and topology-sensitive targets. Workaround and fragcoord had zero
mismatches in all 20 cases. Baseline was exact for the 13 expected controls:
`1x1`, `17x19`, `64x64`, `255x257`, `256x256`, `1000x1000`, `1920x1080`,
`2560x1440`, `3840x2160`, `2079x1`, `4096x1`, `8192x1`, and `16383x127`.
The other seven reproduced baseline-only corruption:

| Size | Baseline mismatches | Workaround mismatches | Fragcoord mismatches |
|---|---:|---:|---:|
| `2080x1` | 32 | 0 | 0 |
| `1x1480` | 96 | 0 | 0 |
| `12288x1` | 11,744 | 0 | 0 |
| `16307x1` | 15,672 | 0 | 0 |
| `9350x11` | 8,239 | 0 | 0 |
| `11x9350` | 102,850 | 0 | 0 |
| `127x16383` | 44,704 | 0 | 0 |

The verifier's process `verdict` is intentionally `FAIL` for an exact baseline
control because its default pass predicate requires a baseline failure. The
per-path mismatch counts are the relevant result when running control sizes.

Each comparison uses alternating ABBA/BAAB blocks. Every GPU timer batch ends
with `glFinish()` before the next path starts; this is necessary on the
tile-based Mali renderer so deferred fragment work cannot be charged to a
neighboring query. All tabled runs used system Mesa `26.0.3-1ubuntu1`,
reported `GL_RENDERER=Mali-G610 MC4 (Panfrost)`,
`GL_EXT_disjoint_timer_query=yes`, and `disjoint=0`.

The original seven-size comparison reproduced as follows. Values are median
within-block GPU-time changes; negative means faster:

| Size | Workaround first run | Workaround rerun | Fragcoord first run | Fragcoord rerun |
|---|---:|---:|---:|---:|
| `1x1` | `+0.46%` | `-1.07%` | `-3.68%` | `-1.75%` |
| `256x256` | `+0.68%` | `+0.41%` | `-7.30%` | `-6.37%` |
| `512x512` | `+0.59%` | `+0.51%` | `-10.00%` | `-10.11%` |
| `1024x1024` | `+0.20%` | `+0.40%` | `-10.75%` | `-9.26%` |
| `1920x1080` | `+0.36%` | `+0.73%` | `-2.25%` | `-2.02%` |
| `3840x2160` | `+0.61%` | `+0.48%` | `-1.06%` | `-1.33%` |
| `12288x1` | `+0.49%` | `+0.53%` | `-11.46%` | `-11.23%` |
| **Median** | **`+0.49%`** | **`+0.48%`** | — | — |

The expanded rerun added 13 unique sizes. The parenthesized range is
`p10..p90` across paired blocks:

| Size | Draws | Workaround vs baseline | Direct fragcoord vs baseline |
|---|---:|---:|---:|
| `16x16` | 32768 | `-2.86%` (`-10.02%..+7.92%`) | `-1.20%` (`-9.78%..+7.94%`) |
| `64x64` | 16384 | `-5.67%` (`-18.37%..+13.46%`) | `-2.97%` (`-13.90%..+13.37%`) |
| `800x600` | 4096 | `+0.46%` (`-0.43%..+1.27%`) | `-7.66%` (`-8.30%..-6.76%`) |
| `1280x720` | 2048 | `+0.67%` (`-0.48%..+1.94%`) | `-9.71%` (`-11.11%..-7.97%`) |
| `2560x1440` | 512 | `+0.45%` (`+0.03%..+0.63%`) | `-1.04%` (`-1.65%..-0.38%`) |
| `2080x1` | 8192 | `+0.37%` (`-0.41%..+1.43%`) | `-9.86%` (`-11.61%..-9.22%`) |
| `1x1480` | 8192 | `+0.06%` (`-1.02%..+1.30%`) | `-9.84%` (`-10.85%..-7.67%`) |
| `8192x1` | 4096 | `+0.37%` (`-0.70%..+0.70%`) | `-11.12%` (`-11.82%..-10.65%`) |
| `16307x1` | 4096 | `+0.39%` (`+0.17%..+0.78%`) | `-10.79%` (`-11.08%..-10.55%`) |
| `9350x11` | 2048 | `+0.25%` (`-0.72%..+1.79%`) | `+7.20%` (`+5.48%..+10.11%`) |
| `11x9350` | 2048 | `+0.06%` (`-0.95%..+1.56%`) | `+7.10%` (`+6.28%..+7.81%`) |
| `16383x127` | 512 | `+0.33%` (`-1.10%..+1.45%`) | `-1.63%` (`-4.03%..-0.37%`) |
| `127x16383` | 512 | `+0.38%` (`-0.55%..+0.77%`) | `-2.14%` (`-4.58%..-1.32%`) |

The `9350x11` case was run twice. The first run measured workaround `+0.44%`
and fragcoord `+7.49%`, confirming that the direct-fragcoord slowdown in the
table is reproducible rather than a single noisy block set.

The percentage is the median of the within-block path/baseline GPU-time ratios;
`p10..p90` is descriptive spread, not a confidence interval. The direct
fragcoord control is intentionally simpler than Mesa's full generalized
fragcoord fix: it models the unscaled 2D TXF coordinate source but not Mesa's
scale, sign, layer, and offset reconstruction. Avoiding the varying helped by
about `9-11%` in several square and one-row cases, but the repeated `9350x11`
and transposed `11x9350` results were about `7%` slower. The direct path is
therefore shape-dependent, not universally faster, and none of these values
should be quoted as the expected end-to-end result of MR !42679.

This probe isolates GPU path cost with cache-warm repeated draws. It does not
cover cold-memory transfers, linear/scaled blits, MSAA resolves, every
format/target, or CPU cost from Mesa selecting and binding rasterizer state.
An instrumented MR !43161 build should still run an end-to-end workload before
merge. Within the path that MR changes, however, a roughly half-percent GPU
cost is not a performance reason to retain an unreliable size/aspect gate
instead of applying the correctness workaround to all affected fullscreen
blits.

## Reproducer

Run the focused wrapper on the affected machine:

```bash
cd video-libraries/mesa/reproducers/interp_probe
MESA_LOADER_DRIVER_OVERRIDE=panfrost EGL_PLATFORM=surfaceless ./mr43161_size_repro.sh
```

By default the wrapper runs the exhaustive `1x1..1500x1500` integer-bin scan.
Use `./mr43161_size_repro.sh --quick` to skip it, or
`./mr43161_size_repro.sh --sweep N` to choose any positive sweep size accepted
by the GL implementation and available memory/time. For example,
`./mr43161_size_repro.sh --sweep 500` reproduces only the original
`1x1..500x500` run.

Measured wall-clock on this board:

- direct `1x1..500x500` integer-bin scan: `real 2.72s`
- direct `1x1..1024x1024` integer-bin scan: `real 28.99s`
- direct `1x1..1500x1500` integer-bin scan: `real 113.17s`
- direct `1x1..2080x2080` integer-bin scan: `real 387.57s`
- direct `25..50` aspect-band canonical scan through `16384x16384`:
  `real 1723.64s`
- direct `50..100` aspect-band canonical scan through `16384x16384`:
  `real 439.33s`
- full default wrapper, including exactness/aspect/TEX cases: about 2–3 minutes

Expected on ROCK 5B / Mali-G610 MC4 / Panfrost:

- `exact_offset_scan2d --main-results` reports bit-identical output only for
  both-dimension power-of-two cases.
- `exact_offset_scan2d --full-grid-floor --max 1500` reports the canonical
  integer-grid failure boundary: `failing_cases=2`, first `1x1480`, last
  `1x1490`.
- `exact_offset_scan2d --full-grid-floor --max 2080` reports
  `failing_cases=85`, all accounted for by `2080x1`, sparse `1xH` failures,
  and `2x2080`.
- `exact_offset_scan2d --case 2080 1` and `--case 1 1480` show the first
  `Nx1`/`1xN` baseline integer-bin failures; the preceding `2079x1` and
  `1x1479` cases pass.
- `triangle_matrix_probe` reports baseline-only failures for `9350x11`,
  `12848x14`, `16383x96`, and `16383x127`.
- `tex_interp_probe 12288 baseline` fails while
  `tex_interp_probe 12288 polygon-offset` passes, showing why the integer
  full-grid result is not a floating-point TEX proof.
