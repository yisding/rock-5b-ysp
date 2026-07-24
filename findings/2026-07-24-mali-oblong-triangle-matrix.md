# Mali oblong-triangle matrix for MR !43161

> Scope: Mesa Panfrost/Mali-G610 varying-interpolation erratum, especially the
> "very oblong" blit workaround discussed in Mesa MR
> [!43161](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/43161).
> Source: MR !43161 discussion read 2026-07-24; local
> [`triangle_matrix_probe.c`](../video-libraries/mesa/reproducers/interp_probe/triangle_matrix_probe.c)
> runs on ROCK 5B / Mali-G610 MC4 / Panfrost system Mesa 26.0.3-1ubuntu1.
> Date: 2026-07-24
> Trust: MEASURED / CONFIRMED (MR discussion) / INFERRED (Mesa cutoff
> implications)

## Result

`triangle_matrix_probe.c` now sweeps the triangle choices we needed to separate:
wide vs tall target, exact half-rectangle vs oversized full-target triangle, all
four right-angle corners, both windings, both long-axis coordinate directions,
raw-varying readback, normalized ordinary `texture()` readback, and baseline vs
zero-valued polygon offset.

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

The power-of-two controls pass: both `16384x1` and `16384x16` pass all 256
matrix cases despite aspects `16384` and `1024`. Aspect ratio is therefore not
the exact hardware predicate.

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

If the Mesa draw uses oversized triangles for the `16307` transition band, then
even `500` is not sufficient for all measured local failures: `16307x63`
(`aspect=258.841`) still fails in the oversized-only class, while `16307x64`
passes all 256 matrix cases. If Mesa emits exact half-rectangle triangles for
that path, the transition-band failures may not be reachable by the current MR's
specific blit geometry. That is a Mesa-topology question, not a hardware
triangle question.

## Evidence and reproduction

- Identity: ROCK 5B / Mali-G610 MC4 / `GL_RENDERER=Mali-G610 MC4 (Panfrost)` /
  `GL_VERSION=OpenGL ES 3.1 Mesa 26.0.3-1ubuntu1`.
- Build:

```bash
cd video-libraries/mesa/reproducers/interp_probe
env PATH=/usr/sbin:/usr/bin:/sbin:/bin cc -O2 -Wall -Wextra -Werror \
  -o triangle_matrix_probe triangle_matrix_probe.c -lEGL -lGLESv2 -lm
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

The sandbox llvmpipe control also passed the full `12288x1` matrix:

```text
GL_RENDERER=llvmpipe (LLVM 21.1.8, 128 bits)
SUMMARY long=12288 short=1 aspect=12288.000 tests=256 failed=0
```

## Boundary

This is a G610/Panfrost measurement, not an affected-product list for all
Valhall revisions. It establishes which GL triangle shapes in the local matrix
are affected, but it does not prove which shape Mesa's current `pan_blitter`
emits for every blit/scale path. The `16307` transition band shows why that
distinction matters.

The scan mode is intentionally canonical (`oversized`, `bl`, `ccw`, both axes,
both ramps, both sample modes, both offset states). Full 256-case matrices were
run for the specific sizes listed above, not for every short extent in every
scan range.

## Why it matters / follow-up

For MR !43161, a cutoff of `1000` misses confirmed discussion cases and measured
G610 cases. A lower cutoff may be enough for the exact Mesa blit triangles, but
the hardware matrix shows that oversized triangles can fail well below
`aspect=500` at `long=16307`. The next useful discriminator is to confirm the
actual primitive topology used by `pan_blitter` for the OpenCL CTS failing blits
and for scaled blits, then choose the Mesa predicate from that reachable set.
