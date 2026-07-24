# Mali oblong-triangle matrix for MR !43161

> Scope: Mesa Panfrost/Mali-G610 varying-interpolation erratum, especially the
> "very oblong" blit workaround discussed in Mesa MR
> [!43161](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/43161).
> Source: MR !43161 discussion read 2026-07-24; local runs of
> [`triangle_matrix_probe.c`](../video-libraries/mesa/reproducers/interp_probe/triangle_matrix_probe.c)
> and
> [`exact_offset_scan.c`](../video-libraries/mesa/reproducers/interp_probe/exact_offset_scan.c)
> /
> [`exact_offset_scan2d.c`](../video-libraries/mesa/reproducers/interp_probe/exact_offset_scan2d.c)
> were on ROCK 5B / Mali-G610 MC4 / Panfrost system Mesa 26.0.3-1ubuntu1.
> Date: 2026-07-24
> Trust: MEASURED / CONFIRMED (MR discussion) / INFERRED (Mesa cutoff
> implications)

## Result

`triangle_matrix_probe.c` now sweeps the triangle choices we needed to separate:
wide vs tall target, exact half-rectangle vs oversized full-target triangle, all
four right-angle corners, both windings, both long-axis coordinate directions,
raw-varying readback, normalized ordinary `texture()` readback, and baseline vs
zero-valued polygon offset. It also has `--all-sizes` for the known
MR/local-boundary sizes and `--coord-long` for scaled-coordinate stress.

On this G610, there are two observed affected classes:

| Class | Triangles affected | Sample paths affected | Workaround |
|---|---|---|---|
| Broad oblong class, e.g. `12288x1`, `12848x14`, `9350x11`, `16307x15` | Every tested baseline triangle: wide/tall, exact/oversized, all corners, both windings, both coordinate directions | Both raw varying and normalized ordinary `texture()` | `GL_POLYGON_OFFSET_FILL` with zero factor/units fixes every case |
| `16307` transition band, sampled at `short=16`, `33`, `34`, `40`, `48`, `56`, `60`, `62`, `63` | Exact triangles pass; only oversized baseline triangles fail, and only specific corner/winding pairs fail | Both raw varying and normalized ordinary `texture()` for each failing pair | Same zero polygon-offset state fixes every case |

For the `16307` transition band, `--fail-only` at `short=16` and `short=33`
printed the same failing oversized corner/winding pairs:

| Axis | Failing oversized baseline corner/winding pairs |
|---|---|
| wide | `bl/cw`, `br/ccw`, `br/cw`, `tr/ccw` |
| tall | `bl/ccw`, `tl/ccw`, `tl/cw`, `tr/cw` |

For each row above, both `ramp=forward|reverse` and
`sample=varying|tex` fail. Every `offset=polygon-offset` case passes.

The power-of-two controls pass: `8192x1`, `16384x1`, `16384x16`, and
`16384x96` pass all 256 matrix cases. Aspect ratio is therefore not the exact
hardware predicate.

Additional testing after the first matrix pass made the predicate problem
sharper:

| Case | Result |
|---|---|
| `2080x1` | 96/256 fail; every failure is baseline-only and offset fixes all. |
| `2047x1`, `2047x1 --coord-long 6141`, `2048x1 --coord-long 6144`, `4096x1 --coord-long 12288` | Pass; source-coordinate range alone did not trigger failures when the destination extent stayed in a passing family. |
| `exact_offset_scan 1..4096` | Bitwise baseline-vs-offset equality, baseline exactness, and offset exactness all occur only for `1`, `2`, and powers of two through `4096`; non-powers differ from width `3`. The weaker integer-bin condition still passes for baseline at 3429/4096 widths and for offset at all 4096 widths. |
| `exact_offset_scan2d --lines --pow2` | Full 2D line scans preserve the same exactness set (`1`, `2`, powers of two) for `Wx1`, `1xH`, `Wx2`, and `2xH`; all 169 power-of-two `WxH` combinations through `4096x4096` are fully bit-exact baseline-vs-offset and exact-vs-expected. |
| `exact_offset_scan2d --sample-grid` | Top-right sample for every `WxH` pair through `4096x4096`: 1,690/16,777,216 baseline samples cross an integer bin; zero-offset has 0 integer-bin failures. |
| `exact_offset_scan2d --sample-major-pow2` | Top-right sample for every pair where `max(W,H)` is a power of two through `4096`: the larger-dimension power-of-two predicate is not an exactness guarantee. 16,012/16,369 samples are non-exact; only the weaker integer-bin condition passes for every baseline and offset sample. |
| `exact_offset_scan2d --case 4096 3`, `--case 3 4096`, `--case 4096 4095`, `--case 4096 4096` | Full-surface controls confirm the sampled result: `4096x3`, `3x4096`, and `4096x4095` are broadly non-exact with no integer-bin failures, while `4096x4096` is fully exact. |
| `10000x15` | Broad 128/256 baseline-only failure. |
| `10000x16` | Pass despite `aspect=625.000`. |
| `8191x1` | 112/256 baseline-only failures. |
| `8191x16`, `8191x32`, `8191x96` | Pass, including `aspect=511.938` at `8191x16`. |
| `16383x1` | 112/256 baseline-only failures. |
| `16383x96` | Oversized-only 8/256 baseline-only failure at `aspect=170.656`. |
| `16383x100`, `16383x104`, `16383x112`, `16383x128` | Pass. |

The scaled-coordinate TEX cases need care: even-integer scales can put ordinary
nearest samples exactly on tie boundaries and produce non-erratum differences
even on llvmpipe. For scaled-coordinate stress, raw-varying checks and
odd-integer scales are the clean signals.

## MR !43161 context

MR !43161 currently applies the Panfrost workaround to `pan_blitter.c` for
architectures below 11 when:

```c
MAX2(width, height) / MIN2(width, height) >= 1000
```

The discussion already showed `1000` is too high: Eric Guo reported OpenCL CTS
failures at `14 x 12848` (`aspect=917.714`) and `11 x 9350` (`aspect=850.000`),
and Kusma suggested trying a lower value around `500`.

Our local matrix confirms both MR discussion sizes fail across the broad class:

| Size | Matrix result |
|---|---|
| `12848x14` and `14x12848` | 128/256 fail: every baseline option fails, every zero-offset option passes |
| `9350x11` and `11x9350` | 128/256 fail: every baseline option fails, every zero-offset option passes |

The local aspect scans also show `1000` misses measured G610 failures:

| Long extent | Failing canonical short extents | First passing canonical short extent |
|---:|---|---:|
| 9350 | `1..15` (`aspect` down to `623.333`) | `16` (`584.375`) |
| 12288 | `1..16` (`aspect` down to `768.000`) | `17` (`722.824`) |
| 12848 | `1..15` (`aspect` down to `856.533`) | `16` (`803.000`) |

If the Mesa draw uses an oversized/fullscreen-style path for the transition
bands, then even `500` is not sufficient for all measured local failures:
`16307x63` (`aspect=258.841`) and `16383x96` (`aspect=170.656`) still fail in
oversized-only classes, while adjacent larger short sides pass. If Mesa emits
exact half-rectangle triangles for those paths, those transition-band failures
may not be reachable by that specific blit geometry. That is a Mesa-topology
question, not a hardware triangle question.

## Predicate recommendation

The right Mesa predicate for MR !43161 is the path/hardware predicate, not a
numeric aspect threshold:

```c
needs_workaround = scr->dev.arch >= 9 && scr->dev.arch < 11;
```

This is scoped by where MR !43161 installs it:
`panfrost_blitter_draw_rectangle()` only overrides `u_blitter`'s draw-rectangle
hook for `arch >= 9`, and the special path only reaches
`scr->vtbl.draw_fullscreen()` for `depth == 0.0f` and `num_instances == 1`.
Within that Panfrost internal fullscreen blitter path, zero-valued polygon
offset is the correctness-safe state. The measured failure field is jagged:
`9350x15`, `10000x15`, `12288x16`, `12848x15`, `16307x63`, and `16383x96`
fail, but `8191x16`, `10000x16`, `12288x17`, `12848x16`, `16383x100`, and the
power-of-two controls pass. Thresholds such as `1000` and `500` therefore encode
the current sample set, not the hardware condition. A larger-dimension
power-of-two exception is also not a valid exactness predicate: `4096x3`,
`3x4096`, and `4096x4095` are non-exact even though the larger dimension is
power-of-two. The stronger observed exactness rule through `4096x4096` remains
both dimensions powers of two.

If maintainers require a size gate to reduce state churn, the measured
conservative fallback is:

```c
unsigned width = x2 - x1;
unsigned height = abs(y2 - y1);
unsigned major = MAX2(width, height);
unsigned minor = MIN2(width, height);

needs_workaround =
   scr->dev.arch >= 9 && scr->dev.arch < 11 &&
   major >= 2048 &&
   !util_is_power_of_two_or_zero(major) &&
   major >= 128 * minor;
```

That fallback catches every measured failure above, catches Eric Guo's
MR-reported G310 cases, skips the measured power-of-two controls, and
intentionally applies the workaround to some measured-passing non-power-of-two
cases (`8191x16`, `10000x16`). Treat it as a compromise if the arch/path-only
predicate is rejected, not as the exact hardware predicate.

## Evidence and reproduction

- Identity: ROCK 5B / Mali-G610 MC4 / `GL_RENDERER=Mali-G610 MC4 (Panfrost)` /
  `GL_VERSION=OpenGL ES 3.1 Mesa 26.0.3-1ubuntu1`.
- Build:

```bash
cd video-libraries/mesa/reproducers/interp_probe
env PATH=/usr/sbin:/usr/bin:/sbin:/bin cc -O2 -Wall -Wextra -Werror \
  -o triangle_matrix_probe triangle_matrix_probe.c -lEGL -lGLESv2 -lm
```

- Automatic known-size suite:

```text
$ ./triangle_matrix_probe --all-sizes
CASE 1/18 power-of-two control
SUMMARY long=8192 short=1 aspect=8192.000 tests=256 failed=0
CASE 2/18 MR !43161 G310 failure
SUMMARY long=9350 short=11 aspect=850.000 tests=256 failed=128
...
CASE 15/18 16307 last tested oversized-only fail
SUMMARY long=16307 short=63 aspect=258.841 tests=256 failed=32
CASE 16/18 16307 pass boundary
SUMMARY long=16307 short=64 aspect=254.797 tests=256 failed=0
CASE 17/18 power-of-two control
SUMMARY long=16384 short=1 aspect=16384.000 tests=256 failed=0
CASE 18/18 power-of-two control
SUMMARY long=16384 short=16 aspect=1024.000 tests=256 failed=0
```

- Full broad-class matrix:

```text
$ ./triangle_matrix_probe --summary-only --long 12288 --short 1
SUMMARY long=12288 short=1 aspect=12288.000 tests=256 failed=128
FAIL axis wide=64 tall=64
FAIL shape exact=64 oversized=64
FAIL corner bl=32 br=32 tl=32 tr=32
FAIL winding ccw=64 cw=64
FAIL ramp forward=64 reverse=64
FAIL sample varying=64 tex=64
FAIL offset baseline=128 polygon-offset=0
```

- MR discussion sizes:

```text
$ ./triangle_matrix_probe --summary-only --long 12848 --short 14
SUMMARY long=12848 short=14 aspect=917.714 tests=256 failed=128
FAIL offset baseline=128 polygon-offset=0

$ ./triangle_matrix_probe --summary-only --long 9350 --short 11
SUMMARY long=9350 short=11 aspect=850.000 tests=256 failed=128
FAIL offset baseline=128 polygon-offset=0
```

- `16307` transition checks:

```text
$ ./triangle_matrix_probe --summary-only --long 16307 --short 15
SUMMARY long=16307 short=15 aspect=1087.133 tests=256 failed=128

$ ./triangle_matrix_probe --fail-only --long 16307 --short 16
SUMMARY long=16307 short=16 aspect=1019.188 tests=256 failed=32
FAIL shape exact=0 oversized=32
FAIL offset baseline=32 polygon-offset=0

$ ./triangle_matrix_probe --fail-only --long 16307 --short 33
SUMMARY long=16307 short=33 aspect=494.152 tests=256 failed=32
FAIL shape exact=0 oversized=32
FAIL offset baseline=32 polygon-offset=0

$ ./triangle_matrix_probe --summary-only --long 16307 --short 63
SUMMARY long=16307 short=63 aspect=258.841 tests=256 failed=32

$ ./triangle_matrix_probe --summary-only --long 16307 --short 64
SUMMARY long=16307 short=64 aspect=254.797 tests=256 failed=0
```

- Power-of-two controls:

```text
$ ./triangle_matrix_probe --summary-only --long 16384 --short 1
SUMMARY long=16384 short=1 aspect=16384.000 tests=256 failed=0

$ ./triangle_matrix_probe --summary-only --long 16384 --short 16
SUMMARY long=16384 short=16 aspect=1024.000 tests=256 failed=0
```

- Exact baseline-vs-offset scan:

```text
$ ./exact_offset_scan 4096
SUMMARY max_width=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3429 offset_floor_pass=4096
same-as-offset widths: 1-2,4,8,16,32,64,128,256,512,1024,2048,4096
baseline-exact widths: 1-2,4,8,16,32,64,128,256,512,1024,2048,4096
offset-exact widths: 1-2,4,8,16,32,64,128,256,512,1024,2048,4096
offset-floor-pass widths: 1-4096

$ ./exact_offset_scan --details 2081
2080,2079,2080,1350,32,0,1,0,0
SUMMARY max_width=2081 same_as_offset=12 baseline_exact=12 offset_exact=12 baseline_floor_pass=2080 offset_floor_pass=2081
```

- 2D exact/sampled scans:

```text
$ ./exact_offset_scan2d --max 4096 --lines --pow2
LINE-SUMMARY Wx1 max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3429 offset_floor_pass=4096 floor_failing_cases=667
LINE-SUMMARY 1xH max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=2762 offset_floor_pass=4096 floor_failing_cases=1334
LINE-SUMMARY Wx2 max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3938 offset_floor_pass=4096 floor_failing_cases=158
LINE-SUMMARY 2xH max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3459 offset_floor_pass=4096 floor_failing_cases=637
POW2-SUMMARY max=4096 cases=169 same_as_offset=169 baseline_exact=169 offset_exact=169 baseline_floor_pass=169 offset_floor_pass=169 nonexact_cases=0

$ ./exact_offset_scan2d --max 4096 --sample-grid --progress 1024
SAMPLE-GRID-SUMMARY max=4096 sample=top-right pairs=16777216 same_as_offset=108346 baseline_exact=7976 offset_exact=5119056 baseline_floor_pass=16775526 offset_floor_pass=16777216 same_pred_mismatch=108177 baseline_exact_pred_mismatch=7807 offset_exact_pred_mismatch=5118887 baseline_floor_failures=1690 offset_floor_failures=0 baseline_floor_fail_width_range=1..4095 baseline_floor_fail_height_range=1..4095 baseline_floor_fail_first=2080x1 baseline_floor_fail_last=1x4095 baseline_floor_fail_h1=666 baseline_floor_fail_w1=697

$ ./exact_offset_scan2d --max 4096 --sample-major-pow2 --progress 0
SAMPLE-MAJOR-POW2-SUMMARY max=4096 sample=top-right pairs=16369 both_pow2_pairs=169 same_as_offset=507 baseline_exact=401 offset_exact=9181 baseline_floor_pass=16369 offset_floor_pass=16369 nonexact_cases=16012 same_pred_mismatch=338 baseline_exact_pred_mismatch=232 offset_exact_pred_mismatch=9012 baseline_floor_failures=0 offset_floor_failures=0

$ ./exact_offset_scan2d --max 4096 --case 4096 3 --progress 0
CASE size=4096x3 pixels=12288 diff=12288 baseline_exact_bad=12288 offset_exact_bad=6144 baseline_floor_bad=0 offset_floor_bad=0 first_diff=(0,0) baseline_first_exact_bad=(0,0) offset_first_exact_bad=(0,0)

$ ./exact_offset_scan2d --max 4096 --case 3 4096 --progress 0
CASE size=3x4096 pixels=12288 diff=12288 baseline_exact_bad=12288 offset_exact_bad=6144 baseline_floor_bad=0 offset_floor_bad=0 first_diff=(0,0) baseline_first_exact_bad=(0,0) offset_first_exact_bad=(0,0)

$ ./exact_offset_scan2d --max 4096 --case 4096 4095 --progress 0
CASE size=4096x4095 pixels=16773120 diff=15985407 baseline_exact_bad=13627392 offset_exact_bad=15459841 baseline_floor_bad=0 offset_floor_bad=0 first_diff=(0,0) baseline_first_exact_bad=(0,0) offset_first_exact_bad=(0,0)

$ ./exact_offset_scan2d --max 4096 --case 4096 4096 --progress 0
CASE size=4096x4096 pixels=16777216 diff=0 baseline_exact_bad=0 offset_exact_bad=0 baseline_floor_bad=0 offset_floor_bad=0
```

- Expanded predicate probes:

```text
$ ./triangle_matrix_probe --summary-only --long 2080 --short 1
SUMMARY long=2080 short=1 aspect=2080.000 tests=256 failed=96
FAIL offset baseline=96 polygon-offset=0

$ ./triangle_matrix_probe --summary-only --long 10000 --short 15
SUMMARY long=10000 short=15 aspect=666.667 tests=256 failed=128
FAIL offset baseline=128 polygon-offset=0

$ ./triangle_matrix_probe --summary-only --long 10000 --short 16
SUMMARY long=10000 short=16 aspect=625.000 tests=256 failed=0

$ ./triangle_matrix_probe --summary-only --long 16383 --short 96
SUMMARY long=16383 short=96 aspect=170.656 tests=256 failed=8
FAIL shape exact=0 oversized=8
FAIL offset baseline=8 polygon-offset=0

$ ./triangle_matrix_probe --summary-only --long 16383 --short 100
SUMMARY long=16383 short=100 aspect=163.830 tests=256 failed=0

$ ./triangle_matrix_probe --summary-only --long 16384 --short 96
SUMMARY long=16384 short=96 aspect=170.667 tests=256 failed=0
```

The sandbox llvmpipe control also passed the full `12288x1` matrix:

```text
GL_RENDERER=llvmpipe (LLVM 21.1.8, 128 bits)
SUMMARY long=12288 short=1 aspect=12288.000 tests=256 failed=0
```

## Boundary

This is a G610/Panfrost measurement, plus MR discussion evidence for two G310
OpenCL CTS failures. It is not an affected-product list for all Valhall
revisions. It establishes which GL triangle shapes in the local matrix are
affected, but it does not prove which shape Mesa's current `pan_blitter` emits
for every blit/scale path. The `16307` and `16383` transition bands show why
that distinction matters.

The scan mode is intentionally canonical (`oversized`, `bl`, `ccw`, both axes,
both ramps, both sample modes, both offset states). Full 256-case matrices were
run for the specific sizes listed above, not for every short extent in every
scan range.

## Why it matters / follow-up

For MR !43161, a cutoff of `1000` misses confirmed discussion cases and measured
G610 cases. `500` also misses measured oversized/fullscreen-style failures. The
recommended upstream change is to remove the size threshold inside the
arch-9/10 Panfrost fullscreen blitter path and rely on the already-scoped
internal path as the predicate. If that is considered too broad, use the
conservative fallback predicate above and state clearly that it is an
engineering compromise, not the discovered hardware boundary.
