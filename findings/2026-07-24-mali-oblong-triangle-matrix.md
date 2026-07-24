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

There are three distinct correctness levels in the results:

| Level | Meaning | What the data says |
|---|---|---|
| Bit-exact baseline-vs-workaround equality | The raw interpolated bits are identical with and without zero-valued polygon offset. | In the canonical 2D exactness scans through `4096x4096`, this was observed only when both destination dimensions are powers of two, treating `1` as `2^0`. One dimension being a power of two is not enough: `4096x3`, `3x4096`, and `4096x4095` differ. |
| Integer/TXF-style correctness | `floor(v.xy)` still lands in the intended source texel/bin, even if the bits differ. | This is weaker than bit-exactness. The canonical fullscreen-style scan found no integer-bin failures in `1x1..1024x1024`; through `2080x2080`, every failure had a `1`- or `2`-pixel side. |
| Ordinary non-integer `texture()` correctness | The interpolated coordinate must remain on the same side of the sampler's texel-selection/filtering boundary. | Integer-bin proofs do not apply. A small coordinate drift can be harmless or visible depending on boundary proximity. The matrix includes real TEX failures (`9350x11`, `12848x14`, `16383x96`, `16383x127`), so there is no reliable non-power-of-two TEX-safe predicate from the current data. |

The important consequence is that "both dimensions are powers of two" is the
only clean bit-exact exemption observed so far. It is not the same thing as a
complete TEX safety predicate: many non-power sizes are correct in the tested
set, but we do not know a dimension/aspect rule that separates all correct TEX
cases from failing TEX cases.

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
| `exact_offset_scan2d --main-results` | One command reproduces the baseline-vs-zero-offset bit-equality result with full surfaces: both-dimension power-of-two controls match bit-for-bit, while `4096x3`, `3x4096`, `4096x4095`, `4095x4095`, `4095x383`, and `4095x341` differ. The `diff` field is the baseline-vs-zero-offset bit comparison. |
| `exact_offset_scan2d --full-grid-floor --max 500` | Full-pixel baseline integer-bin scan for every size from `1x1` through `500x500`: 250,000 sizes / 15,687,562,500 baseline pixels tested, 0 integer-bin failures. |
| `exact_offset_scan2d --full-grid-floor --max 1024` | Full-pixel baseline integer-bin scan for every size from `1x1` through `1024x1024`: 1,048,576 sizes / 275,415,040,000 baseline pixels tested, 0 integer-bin failures. |
| `exact_offset_scan2d --full-grid-floor --max 1500` | Full-pixel baseline integer-bin scan through `1500x1500`: 2,250,000 sizes / 1,267,313,062,500 baseline pixels tested, 2 failing cases (`1x1480`, `1x1490`), both fixed by zero-offset. |
| `exact_offset_scan2d --full-grid-floor --max 2080` | Full-pixel baseline integer-bin scan through `2080x2080`: 4,326,400 sizes / 4,683,934,777,600 baseline pixels tested, 85 failing cases. The line scan accounts for all failures as `2080x1`, sparse `1xH` failures starting at `1x1480`, and `2x2080`; no canonical failures were found where both dimensions are at least `3`. |
| `exact_offset_scan2d --full-grid-floor --max 16384 --aspect-band 50 100` | Canonical full-pixel baseline integer-bin scan for every size through `16384x16384` with aspect ratio `50..100`: 2,685,006 sizes / 5,405,732,710,480 baseline pixels tested, 0 integer-bin failures. This only covers the canonical fullscreen-style triangle, not the full 256-case topology matrix. |
| `exact_offset_scan2d --sample-grid` | Top-right sample for every `WxH` pair through `4096x4096`: 1,690/16,777,216 baseline samples cross an integer bin; zero-offset has 0 integer-bin failures. The closest-to-square top-right integer-bin failure is still very oblong, `2x2929` (`aspect=1464.5`), and there are 0 top-right integer-bin failures where both dimensions are non-powers of two. |
| `exact_offset_scan2d --sample-major-pow2` | Top-right sample for every pair where `max(W,H)` is a power of two through `4096`: the larger-dimension power-of-two predicate is not an exactness guarantee. 16,012/16,369 samples are non-exact; only the weaker integer-bin condition passes for every baseline and offset sample. |
| `exact_offset_scan2d --case 4096 3`, `--case 3 4096`, `--case 4096 4095`, `--case 4096 4096` | Full-surface controls confirm the sampled result: `4096x3`, `3x4096`, and `4096x4095` are broadly non-exact with no integer-bin failures, while `4096x4096` is fully exact. |
| `10000x15` | Broad 128/256 baseline-only failure. |
| `10000x16` | Pass despite `aspect=625.000`. |
| `8191x1` | 112/256 baseline-only failures. |
| `8191x16`, `8191x32`, `8191x96` | Pass, including `aspect=511.938` at `8191x16`. |
| `16383x1` | 112/256 baseline-only failures. |
| `16383x127` | Both dimensions non-power; full 256-case matrix finds 8 oversized baseline-only failures at `aspect=129.000`, and zero-offset fixes all failures. This is the lowest measured integer/TEX failure aspect so far. |
| `exact_offset_scan2d --case 16383 127`, `--case 127 16383` | The canonical BL/CCW fullscreen-style triangle is direction-sensitive here: wide `16383x127` has `baseline_floor_bad=0`, while tall `127x16383` has `baseline_floor_bad=44704`; zero-offset is still integer-bin clean. |
| `16383x96` | Oversized-only 8/256 baseline-only failure at `aspect=170.656`. |
| `16383x100`, `16383x104`, `16383x112`, `16383x128` | Pass. |
| `10923x683`, `10923x341`, `10923x171`, `10923x85`, `10923x43`, `10923x21` | Odd long dimension about one third from `8192` to `16384`; low/mid-aspect oversized raw-varying matrices pass from `aspect=15.993` through `520.143`. |
| `10923x11` | Same odd far-from-power long dimension enters the broad integer-bin failure class at `aspect=993.000`; all selected failures are baseline-only and zero-offset fixes them. |

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
That path maps the destination rectangle with viewport/scissor and then draws a
fullscreen-style primitive; if the conditions are not met, it falls back to
ordinary `util_blitter_draw_rectangle()` geometry. Therefore the canonical
fullscreen scan is evidence for the Panfrost internal fullscreen blit path, not
for every possible app triangle or every fallback rectangle topology.

Within that Panfrost internal fullscreen blitter path, zero-valued polygon
offset is the correctness-safe state. The measured failure field is jagged:
`9350x15`, `10000x15`, `12288x16`, `12848x15`, `16307x63`, `16383x96`, and
`16383x127` fail, but `8191x16`, `10000x16`, `12288x17`, `12848x16`,
`16383x100`, and the power-of-two controls pass. Thresholds such as `1000` and
`500` therefore encode the current sample set, not the hardware condition. A
canonical scan of aspect ratios `50..100` through `16384x16384` found no
integer-bin failures, but that is not a full-topology proof and does not make
`100` a hardware boundary. A larger-dimension power-of-two exception is also
not a valid exactness predicate:
`4096x3`, `3x4096`, and `4096x4095` are non-exact even though the larger
dimension is power-of-two. The stronger observed bit-exact rule through
`4096x4096` remains both dimensions powers of two, but that rule should not be
mistaken for a non-integer TEX safe predicate for all non-power cases.

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
$ ./exact_offset_scan2d --main-results --progress 0
MAIN-RESULT-PREDICATE suite_expected_same_as_offset=both_dimensions_are_powers_of_two
MAIN-RESULT label=both-pow2-max size=4096x4096 aspect=1.000000 expected=same observed=same verdict=PASS same_as_offset=1 baseline_exact=1 offset_exact=1 baseline_floor=1 offset_floor=1 diff=0 baseline_exact_bad=0 offset_exact_bad=0 baseline_floor_bad=0 offset_floor_bad=0
MAIN-RESULT label=one-dim-pow2-tall size=3x4096 aspect=1365.333333 expected=different observed=different verdict=PASS same_as_offset=0 baseline_exact=0 offset_exact=0 baseline_floor=1 offset_floor=1 diff=12288 baseline_exact_bad=12288 offset_exact_bad=6144 baseline_floor_bad=0 offset_floor_bad=0 first_diff=(0,0) baseline_first_exact_bad=(0,0) offset_first_exact_bad=(0,0)
MAIN-RESULT label=both-nonpow2-near-square size=4095x4095 aspect=1.000000 expected=different observed=different verdict=PASS same_as_offset=0 baseline_exact=0 offset_exact=0 baseline_floor=1 offset_floor=1 diff=16769025 baseline_exact_bad=16769025 offset_exact_bad=16768514 baseline_floor_bad=0 offset_floor_bad=0 first_diff=(0,0) baseline_first_exact_bad=(0,0) offset_first_exact_bad=(0,0)
MAIN-RESULT label=both-nonpow2-aspect-10 size=4095x383 aspect=10.691906 expected=different observed=different verdict=PASS same_as_offset=0 baseline_exact=0 offset_exact=0 baseline_floor=1 offset_floor=1 diff=1568385 baseline_exact_bad=1568385 offset_exact_bad=1357021 baseline_floor_bad=0 offset_floor_bad=0 first_diff=(0,0) baseline_first_exact_bad=(0,0) offset_first_exact_bad=(0,0)
MAIN-RESULT-SUMMARY cases=9 passed=9 failed=0 same=3 different=6

$ ./exact_offset_scan2d --max 500 --full-grid-floor --progress 50
FULL-GRID-FLOOR-SUMMARY max=500 path=baseline cases=250000 pixels=15687562500 failing_cases=0 first_failure=0x0 last_failure=0x0 most_square_failure=0x0 most_square_failure_aspect=0.000000

$ ./exact_offset_scan2d --max 1024 --full-grid-floor --progress 128
FULL-GRID-FLOOR-SUMMARY max=1024 path=baseline cases=1048576 pixels=275415040000 failing_cases=0 first_failure=0x0 last_failure=0x0 most_square_failure=0x0 most_square_failure_aspect=0.000000

$ ./exact_offset_scan2d --max 1500 --full-grid-floor --progress 150
FULL-GRID-FLOOR-SUMMARY max=1500 path=baseline cases=2250000 pixels=1267313062500 failing_cases=2 first_failure=1x1480 last_failure=1x1490 most_square_failure=1x1480 most_square_failure_aspect=1480.000000

$ ./exact_offset_scan2d --max 2080 --full-grid-floor --progress 104
FULL-GRID-FLOOR-SUMMARY max=2080 path=baseline cases=4326400 pixels=4683934777600 failing_cases=85 first_failure=2080x1 last_failure=2x2080 most_square_failure=2x2080 most_square_failure_aspect=1040.000000

$ ./exact_offset_scan2d --max 2080 --lines
LINE-SUMMARY Wx1 max=2080 same_as_offset=12 baseline_exact=12 offset_exact=12 baseline_floor_pass=2079 offset_floor_pass=2080 floor_failing_cases=1
LINE-SUMMARY 1xH max=2080 same_as_offset=12 baseline_exact=12 offset_exact=12 baseline_floor_pass=1997 offset_floor_pass=2080 floor_failing_cases=83
LINE-SUMMARY Wx2 max=2080 same_as_offset=12 baseline_exact=12 offset_exact=12 baseline_floor_pass=2080 offset_floor_pass=2080 floor_failing_cases=0
LINE-SUMMARY 2xH max=2080 same_as_offset=12 baseline_exact=12 offset_exact=12 baseline_floor_pass=2079 offset_floor_pass=2080 floor_failing_cases=1

$ ./exact_offset_scan2d --max 16384 --full-grid-floor --aspect-band 50 100 --progress 1024
FULL-GRID-FLOOR-SUMMARY max=16384 path=baseline aspect_min=50.000000 aspect_max=100.000000 cases=2685006 pixels=5405732710480 failing_cases=0 first_failure=0x0 last_failure=0x0 most_square_failure=0x0 most_square_failure_aspect=0.000000
real 439.33

$ ./exact_offset_scan2d --max 4096 --lines --pow2
LINE-SUMMARY Wx1 max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3429 offset_floor_pass=4096 floor_failing_cases=667
LINE-SUMMARY 1xH max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=2762 offset_floor_pass=4096 floor_failing_cases=1334
LINE-SUMMARY Wx2 max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3938 offset_floor_pass=4096 floor_failing_cases=158
LINE-SUMMARY 2xH max=4096 same_as_offset=13 baseline_exact=13 offset_exact=13 baseline_floor_pass=3459 offset_floor_pass=4096 floor_failing_cases=637
POW2-SUMMARY max=4096 cases=169 same_as_offset=169 baseline_exact=169 offset_exact=169 baseline_floor_pass=169 offset_floor_pass=169 nonexact_cases=0

$ ./exact_offset_scan2d --max 4096 --sample-grid --progress 1024
SAMPLE-GRID-SUMMARY max=4096 sample=top-right pairs=16777216 same_as_offset=108346 baseline_exact=7976 offset_exact=5119056 baseline_floor_pass=16775526 offset_floor_pass=16777216 same_pred_mismatch=108177 baseline_exact_pred_mismatch=7807 offset_exact_pred_mismatch=5118887 baseline_floor_failures=1690 offset_floor_failures=0 baseline_floor_fail_width_range=1..4095 baseline_floor_fail_height_range=1..4095 baseline_floor_fail_first=2080x1 baseline_floor_fail_last=1x4095 baseline_floor_fail_most_square=2x2929 baseline_floor_fail_most_square_aspect=1464.500000 baseline_floor_fail_both_nonpow2=0 baseline_floor_fail_both_nonpow2_most_square=0x0 baseline_floor_fail_both_nonpow2_most_square_aspect=0.000000 baseline_floor_fail_both_nonpow2_largest_min=0x0 baseline_floor_fail_both_nonpow2_largest_min_dim=0 baseline_floor_fail_h1=666 baseline_floor_fail_w1=697

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

$ ./triangle_matrix_probe --summary-only --long 16383 --short 127
SUMMARY long=16383 short=127 aspect=129.000 tests=256 failed=8
FAIL axis wide=4 tall=4
FAIL shape exact=0 oversized=8
FAIL corner bl=8 br=0 tl=0 tr=0
FAIL winding ccw=4 cw=4
FAIL ramp forward=4 reverse=4
FAIL sample varying=4 tex=4
FAIL offset baseline=8 polygon-offset=0

$ ./exact_offset_scan2d --max 16383 --case 16383 127 --progress 0
CASE size=16383x127 pixels=2080641 diff=2080641 baseline_exact_bad=2080641 offset_exact_bad=1846802 baseline_floor_bad=0 offset_floor_bad=0

$ ./exact_offset_scan2d --max 16383 --case 127 16383 --progress 0
CASE size=127x16383 pixels=2080641 diff=2080641 baseline_exact_bad=2080641 offset_exact_bad=1846802 baseline_floor_bad=44704 offset_floor_bad=0

$ ./triangle_matrix_probe --summary-only --long 16383 --short 100
SUMMARY long=16383 short=100 aspect=163.830 tests=256 failed=0

$ ./triangle_matrix_probe --summary-only --long 16384 --short 96
SUMMARY long=16384 short=96 aspect=170.667 tests=256 failed=0

$ ./triangle_matrix_probe --fail-only --long 10923 --short 341 \
    --shape oversized --sample varying --offset both
SUMMARY long=10923 short=341 aspect=32.032 tests=64 failed=0

$ ./triangle_matrix_probe --fail-only --long 10923 --short 21 \
    --shape oversized --sample varying --offset both
SUMMARY long=10923 short=21 aspect=520.143 tests=64 failed=0

$ ./triangle_matrix_probe --fail-only --long 10923 --short 11 \
    --shape oversized --sample varying --offset both
SUMMARY long=10923 short=11 aspect=993.000 tests=64 failed=32
FAIL offset baseline=32 polygon-offset=0
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
