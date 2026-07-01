# Reproducers

These are the standalone C programs used while debugging Panfrost texture
transfers on ROCK 5B / Mali-G610. They use GBM/EGL and GLES 3.x directly, so run
them on the board with a Mesa build that includes Panfrost.

## Build

```bash
cc -O2 -o repro_blit repro_blit.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o probe_interp probe_interp.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o probe_wcorr probe_wcorr.c -lEGL -lGLESv2 -lgbm -lm
cc -O2 -o bench_transfer bench_transfer.c -lEGL -lGLESv2 -lgbm -lm
```

If testing a local Mesa build, point the loader at the built DRI target, for
example:

```bash
export LD_LIBRARY_PATH=/path/to/mesa/build/src/egl:/path/to/mesa/build/src/gbm:/path/to/mesa/build/src/gallium/targets/dril
export LIBGL_DRIVERS_PATH=/path/to/mesa/build/src/gallium/targets/dril
export EGL_PLATFORM=surfaceless
```

The programs default to `/dev/dri/renderD128`. `repro_blit.c` and
`bench_transfer.c` also honor:

```bash
REPRO_NODE=/dev/dri/renderD128
```

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

## `probe_interp.c`

Interpolation precision probe.

It renders a `W x 1` quad with a varying that runs from `0` to `W` across the
quad and writes the interpolated f32 bit pattern to an integer render target.

Modes:

```text
0 = smooth/perspective varying
1 = noperspective varying
2 = gl_FragCoord.x
```

Run:

```bash
./probe_interp 16307 0
./probe_interp 16307 1
./probe_interp 16307 2
```

Observed result:

```text
smooth varying: floor(interp) != i : 15672 / 16307
gl_FragCoord.x: floor(interp) != i : 0 / 16307
```

This isolates the problem to the varying path. `gl_FragCoord.x` is exact.

## `probe_wcorr.c`

Shader-side recovery probe.

This checks whether the fragment shader can recover an exact coordinate using
local information such as derivatives. It could not; the derivative-based
candidate was worse than using the raw varying:

```text
raw floor(tc)!=i        : 15672 / 16307
dFdx reconstruction     : 16187 / 16307
```

The file name is historical. Earlier variants also checked whether
`gl_FragCoord.w` carried a useful correction term.

## `bench_transfer.c`

Microbenchmark for the same `RG32UI -> RGBA32UI` readback shape.

Run BLIT and COMPUTE on a branch that can select both paths. In the local
experiments, the default path selected BLIT while `MESA_COMPUTE_PBO=1` forced
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

Recorded medians are in [`../validation.md`](../validation.md).

## `mr42563-comment-failures.txt`

The exact dEQP cases from the MR comment that were rerun locally after switching
the MR direction to COMPUTE.
