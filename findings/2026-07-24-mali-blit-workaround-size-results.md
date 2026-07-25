# Mali blit workaround size results for Mesa MR !43161

> Scope: shareable summary for the Panfrost/Mali-G610 varying-interpolation
> erratum discussed in Mesa MR !43161; the full technical record is
> [`2026-07-24-mali-oblong-triangle-matrix.md`](2026-07-24-mali-oblong-triangle-matrix.md).
> Source: ROCK 5B / Mali-G610 MC4 / Panfrost system Mesa 26.0.3-1ubuntu1;
> reproducer
> [`mr43161_size_repro.sh`](../video-libraries/mesa/reproducers/interp_probe/mr43161_size_repro.sh).
> Date: 2026-07-24
> Trust: MEASURED (bit-exactness and integer-bin scans on the board)

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
