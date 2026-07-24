# Mali blit workaround size results for Mesa MR !43161

> Scope: shareable summary for the Panfrost/Mali-G610 varying-interpolation
> erratum discussed in Mesa MR !43161. Data is from ROCK 5B / Mali-G610 MC4 /
> Panfrost system Mesa 26.0.3-1ubuntu1 on 2026-07-24. Focused reproducer:
> [`mr43161_size_repro.sh`](../video-libraries/mesa/reproducers/interp_probe/mr43161_size_repro.sh).

## Result

The zero-valued polygon-offset workaround changes the varying-interpolation path.
In the measured scans, baseline and workaround output are bit-identical only
when both destination dimensions are powers of two, treating `1` as `2^0`.
This is a bit-exact statement, not the same as integer correctness.

The integer/TXF-style condition is weaker: `floor(v.xy)` must still select the
current destination pixel. A full baseline scan of every integer size from
`1x1` through `500x500` passed that integer-bin test, and a follow-up run
expanded the same canonical fullscreen-triangle scan through `1024x1024` with
the same result:

```text
FULL-GRID-FLOOR-SUMMARY max=500 path=baseline cases=250000 pixels=15687562500 failing_cases=0
FULL-GRID-FLOOR-SUMMARY max=1024 path=baseline cases=1048576 pixels=275415040000 failing_cases=0
```

That validates the canonical integer-coordinate fullscreen-triangle blit through
`1024x1024`. It does not validate ordinary non-integer `texture()` coordinates.
The separate TEX probe shows the same hardware issue can affect normalized
nearest-filtered TEX at larger sizes (`12288x1` and `16307x1`), so the integer
proof should not be reused as a general floating-point TEX safety proof.

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
| `16383x127` | 129.000 | selected oversized raw-varying integer-bin failure; workaround passes |
| `16384x96` | 170.667 | power-of-two control passes |
| `16383x100`, `16383x104`, `16383x112`, `16383x128` | 163.830 down to 127.992 | sampled/full checks passed |

The safest conclusion is that we do not know an exact aspect-ratio boundary.
The measured field is jagged enough that `1000`, `500`, or a lower threshold is
a policy compromise, not the hardware predicate. The robust predicate remains:
apply the workaround on the affected Panfrost fullscreen/blit path for affected
Valhall generations, rather than trying to derive safety from dimensions or
aspect ratio.

## Reproducer

Run the focused wrapper on the affected machine:

```bash
cd video-libraries/mesa/reproducers/interp_probe
MESA_LOADER_DRIVER_OVERRIDE=panfrost EGL_PLATFORM=surfaceless ./mr43161_size_repro.sh
```

By default the wrapper runs the exhaustive `1x1..1024x1024` integer-bin scan.
Use `./mr43161_size_repro.sh --quick` to skip it, or
`./mr43161_size_repro.sh --sweep 500` to reproduce only the original
`1x1..500x500` run.

Measured wall-clock on this board:

- direct `1x1..500x500` integer-bin scan: `real 2.72s`
- direct `1x1..1024x1024` integer-bin scan: `real 28.99s`
- full default wrapper, including exactness/aspect/TEX cases: about `56s`

Expected on ROCK 5B / Mali-G610 MC4 / Panfrost:

- `exact_offset_scan2d --main-results` reports bit-identical output only for
  both-dimension power-of-two cases.
- `exact_offset_scan2d --full-grid-floor --max 1024` reports
  `failing_cases=0`.
- `exact_offset_scan2d --case 2080 1` and `--case 1 1480` show the first
  `Nx1`/`1xN` baseline integer-bin failures; the preceding `2079x1` and
  `1x1479` cases pass.
- `triangle_matrix_probe` reports baseline-only failures for `9350x11`,
  `12848x14`, `16383x96`, and the selected `16383x127` oversized case.
- `tex_interp_probe 12288 baseline` fails while
  `tex_interp_probe 12288 polygon-offset` passes, showing why the integer
  full-grid result is not a floating-point TEX proof.
