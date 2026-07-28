# BLIT Precision Root Cause and Erratum Update

This is the detailed chain from "Panfrost should enable texture transfers" to
"the sampled BLIT path cannot be trusted with integer texel addresses on
Mali-G610" — and what that leaves as viable fixes. Status and dated MR
lifecycle live in [`README.md` § Status](../README.md).

> **Correction, 2026-07-22:** A Mesa maintainer confirmed that the wide
> non-power-of-two varying drift is a **hardware erratum** and supplied a
> zero-valued polygon-offset workaround. Enabling `GL_POLYGON_OFFSET_FILL`
> with factor and units zero makes the same raw varying exact at 12288 and
> 16307; it also makes a new normalized-coordinate ordinary-`texture()` test
> exact. PanVK's equivalent zero-valued Vulkan depth-bias state makes its
> bit-identical raw-varying failure exact at both widths as well. The
> `~2^-10` values below remain measured failure signatures, but
> they are not evidence of an inherent ten-fractional-bit varying format.
> `gl_FragCoord` reconstruction remains a valid way for !42679 to avoid the
> affected path, not the now-established root cause or the only possible
> workaround. See the
> [dated finding](../../../findings/2026-07-22-mali-varying-depth-bias-erratum-workaround.md).

> **Measurement boundary, 2026-07-27:** Forcing zero-valued depth bias on all
> V9–V10 internal fullscreen blits fixed both affected R32UI geometries in the
> phase-one matrix and left four ordinary controls exact. That is bounded
> functional evidence for MR !43161's broad policy, not a performance result or
> proof of every blit path. GPU devfreq was uncontrolled, the run used KASAN,
> and the batched timer query did not grow with operation count, so no
> per-blit-cost number is valid. See the
> [benchmark result](../../../findings/2026-07-27-mesa-all-blit-workaround-benchmark-results.md).

## Fast re-entry

This page owns the causal mechanism and durable option analysis. Live MR state
belongs to [`README.md` § Status](../README.md#mr-status);
dated experiments retain their exact trust and scope in
[`findings/`](../../../findings/README.md#reconstruct-an-investigation).

| Question to recover | Read | Load-bearing fact |
|---------------------|------|-------------------|
| How did a shader-precision test become a blit investigation? | [Starting point](#starting-point) and [reproducer symptom](#reproducer-symptom) | The test's readback expanded RG32UI through a sampled format-changing blit; the CPU fallback was correct and the GPU blit drifted with position. |
| Was the generated fetch shader obviously wrong? | [Generated shader](#the-generated-shader-was-sensible) and [capture method](#how-the-disassembly-was-captured) | `TEX_FETCH` received an already-imprecise coordinate from `LD_VAR_IMM`; instruction selection was not the first failing boundary. |
| What isolated the failing mechanism? | [Interpolation probe](#interpolation-probe), [going lower](#going-lower), and [no-u_blitter proof](#the-probe-frame-contains-no-ublitter-work) | Raw varying interpolation drifts without texture fetch, filtering, format conversion, or `u_blitter`; exact fragment position does not. |
| What did the numeric signature prove—and not prove? | [`2^-10` signature](#what-the-2-10-signature-means) and [`noperspective`](#why-noperspective-did-not-fix-it) | The values fingerprint the measured failure, but the maintainer-confirmed erratum disproves an inherent ten-fractional-bit varying format. |
| Which alternative explanations were eliminated? | [Hypotheses ruled out](#hypotheses-ruled-out) and [Asahi/AGX boundary](#why-asahiagx-was-not-evidence-that-blit-is-safe) | Compiler precision toggles, filtering, synchronization, triangle choice, and another GPU architecture could not license the Mali-G610 path. |
| Why not use COMPUTE or a narrow format fallback? | [Options considered](#options-considered) and [AFBC constraint](#the-afbc-constraint-why-compute-only-was-rejected) | COMPUTE avoids the varying path but cannot write AFBC; integer-only fallback misses the identical float corruption. |
| How does the fragcoord avoidance work? | [Options considered](#options-considered) and [on-device verification](#on-device-verification-2026-07-01) | Exact pixel position plus constant affine scale/offset reconstructs source coordinates without sending a changing texel address through the interpolator. |
| What changed after the root cause was confirmed? | [Erratum/workaround finding](../../../findings/2026-07-22-mali-varying-depth-bias-erratum-workaround.md) and [triangle matrix](../../../findings/2026-07-24-mali-oblong-triangle-matrix.md) | Zero-valued depth bias selects an unaffected measured path; no tested size/aspect cutoff cleanly describes all failures. |
| What is the current correctness/performance boundary? | [Benchmark plan](../../../findings/2026-07-27-mali-blit-workaround-performance-benchmark-plan.md) → [benchmark result](../../../findings/2026-07-27-mesa-all-blit-workaround-benchmark-results.md) | The forced broad policy passed its measured R32UI functional subset, but per-blit cost and broader formats/operations remain open. |

### The causal chain

```text
dEQP precision failure
  -> format-changing sampled readback blit
  -> texel chosen from an interpolated coordinate
  -> raw GL varying probe reproduces the same position-dependent drift
  -> tiny GL and PanVK probes remove u_blitter/TXF/state-tracker explanations
  -> maintainer identifies Mali erratum; zero depth bias repairs raw varying/TEX
  -> geometry matrix rejects simple aspect/size predicates
  -> forced all-blit A/B closes a bounded correctness subset
  -> corrected timing boundary + fixed clocks still needed for cost
```

### Similar results that support different claims

| Do not conflate | Distinction |
|-----------------|-------------|
| dEQP shader-precision failure vs faulty GLSL builtin | The builtin test exposed a wide readback conversion; its rendered shader result was not the corrupt stage. |
| varying erratum vs TXF or `u_blitter` bug | TXF made wrong integer texel selection visible, but pure GL/Vulkan varyings reproduce the failure without it. |
| `~2^-10` failure signature vs hardware precision format | The magnitude describes selected measurements. It does not define the interpolator's architectural format or the erratum's mechanism. |
| `gl_FragCoord` reconstruction vs repairing interpolation | Fragcoord routes specific blit coordinates around the affected varying path; unrelated application varyings remain unchanged. |
| zero-valued depth-bias enable vs moving depth | The descriptor enable bit changes while factor, units, and clamp remain zero; the measured workaround does not numerically bias depth. |
| passing workaround cases vs exact hardware predicate | The matrix proves affected and unaffected geometries, not a complete product/revision/size/aspect rule. |
| functional A/B vs workaround cost | Exact pixels prove correctness for the tested operation. Cost requires a timer that owns deferred tile work, fixed clocks, counters/traces, and a production kernel. |
| fast COMPUTE copy vs blanket transfer solution | COMPUTE timing/correctness cannot erase its AFBC-write limitation. |

## The idea in plain English

**The problem.** To copy or resize an image, the GPU must know, for each
destination pixel, which source pixel to read. Today the driver figures that out
by writing a number on each *corner* of the image and letting the hardware
smoothly fill in all the numbers in between — like stamping "0" on the first
fence post and "5280" on the last, then eyeballing the label on every post
between. A Mali hardware erratum makes that fill-in-between result drift for
some wide, non-power-of-two triangles. At the measured 12k/16k widths the error
is about one part in a thousand; by the far edge it is several whole pixels, so
the GPU reads the wrong source pixels and the copy comes out smeared or shifted.

**The fix.** Stop eyeballing the labels. The GPU already knows *exactly* which
pixel it is drawing — its row and column, an exact whole number it gets for free.
So instead of shipping the coordinate itself, ship the *recipe* for it — "start
here, move this much per pixel" — as one fixed value, and let each pixel work out
its own source location from its own exact position. Exact position + fixed
recipe, computed fresh at each pixel, gives an exact answer. Nothing is guessed,
so nothing drifts. (Same picture: don't eyeball the posts — each already has its
exact distance stamped on it; just announce "your label = your number + 3" and
every post gets it right.)

**Why it works.** The coordinate genuinely changes from pixel to pixel, so it
*can't* be one fixed value — that's why you can't just "turn interpolation off."
But the recipe that produces it (a start and a step) is the same for the whole
copy: a true constant. Constants reach the shader untouched, the exact per-pixel
position is handed to us for free, and one multiply-add per pixel runs at full
arithmetic precision instead of the interpolator's coarse guess. The one lossy
step in the old path is simply deleted.

**Why one idea fixes both copy and resize.** "Which source pixel" is always
`start + step × (my position)`. For an exact 1-to-1 copy the step is 1 and
everything stays whole numbers, so the result is perfect, bit for bit. For a
resize the step is a fraction, so there's a little arithmetic — but done from the
exact position it is still ~1000× more accurate than the old guess, far more than
a resize needs. Same recipe, two settings.

The rest of this doc is the evidence and mechanism behind that summary; the exact
NIR / `u_blitter` implementation is in
[`../../../findings/2026-07-08-blit-precision-nir-migration.md`](../../../findings/2026-07-08-blit-precision-nir-migration.md).

## Starting Point

The first attempted change was:

```c
caps->texture_transfer_modes = PIPE_TEXTURE_TRANSFER_BLIT;
```

(the direction of Joshua Watt's MR !38433; the exact local commit is archived
as
[`video-libraries/mesa/patches/0001-panfrost-advertise-transfer-blit-and-compute.patch`](../patches/0001-panfrost-advertise-transfer-blit-and-compute.patch)).

That made Mesa's state tracker prefer GPU blits for some texture-transfer and
readback paths instead of CPU fallback. CI and MR review pointed at failures in
GLES3 dEQP shader precision cases, especially:

```text
dEQP-GLES3.functional.shaders.builtin_functions.precision.*
```

The surprising part was that these shader precision tests were exposing a
readback path, not a wrong GLSL builtin. Instrumenting `st_ReadPixels` showed the
key shape:

```text
st_ReadPixels: xy=0,0 wh=16307x1 glfmt=GL_RGBA_INTEGER type=GL_UNSIGNED_INT
               rb=r32g32_uint src=r32g32_uint dst=r32g32b32a32_uint
               pbo=0 path: blit dst_xy=0,0
```

The test rendered into an `R32G32_UINT` renderbuffer and read it as
`GL_RGBA_INTEGER` + `GL_UNSIGNED_INT`. Mesa staged this as
`R32G32B32A32_UINT`, then used a `u_blitter` sampled TXF fragment shader to
expand `RG32UI` to `RGBA32UI`.

The CPU fallback was correct. The sampled blit was wrong.

## Reproducer Symptom

The standalone reproducer in
[`video-libraries/mesa/reproducers/repro_blit.c`](../reproducers/repro_blit.c) builds an `R32G32_UINT`
texture with:

```text
source[i] = { i, i }
```

It attaches that texture to an FBO and calls:

```c
glReadPixels(0, 0, W, 1, GL_RGBA_INTEGER, GL_UNSIGNED_INT, dst);
```

That reproduces the same staging-blit path. Any spatial shift shows up as
`dst[i].r != i`.

Observed on ROCK 5B / Mali-G610:

```text
W=16307  mismatches=15672 / 16307 (96.1%)  first_mismatch=623
i=1024   sampled=1023   shift=-1
i=8192   sampled=8185   shift=-7
i=16306  sampled=16293  shift=-13
```

The shift is not constant. It grows with position. The implied scale is around
`0.9992`, approximately `1 - 2^-10`, which points at a relative precision loss
rather than an off-by-half-pixel convention.

## The Generated Shader Was Sensible

The relevant Valhall instruction sequence for the blit fragment shader was:

```asm
LD_VAR_IMM.slot0.v4.f32.center.store.wait0 @r0:r1:r2:r3, r61^, table:0x1, index:0x0
F32_TO_S32.rtz.discard r2, r3^
IADD_IMM.i32 r3, 0x0, #0xFF
CSEL.u32.lt r2, r2^, r3^, r2^, r3^
MKVEC.v2i8 r2, 0x0.b0, r2^.b0, 0x0
MKVEC.v2i8 r2, 0x0.b0, 0x0.b0, r2^
F32_TO_S32.rtz r1, r1^
F32_TO_S32.rtz r0, r0^
IADD_IMM.i32 r3, 0x0, #0x20001800
MOV.i32 r4, r3^
MOV.i32 r5, 0x0
TEX_FETCH.slot1.reserved.32.2d.texel_offset.wait0126 @r0:r1:r2:r3, @r0:r1:r2, [r4^:r5^]
```

That is a plausible lowering of the high-level operation:

1. Load the interpolated coordinate as f32.
2. Truncate to signed integer.
3. Do an integer texel fetch.

The problem is not an obvious `TEX_FETCH` or instruction-selection bug. The
input coordinate arriving from `LD_VAR_IMM` is already imprecise enough that
truncation can select the previous texel.

Note the `LD_VAR_IMM ... .f32.center` form is already the maximum-precision
variant: the perspective divide is internal to the hardware message, so there
is no compiler-emitted reciprocal whose precision could be raised.

### How The Disassembly Was Captured

`BIFROST_MESA_DEBUG=shaders` (flag defined in
`src/panfrost/compiler/bifrost/bi_debug.c`: "Dump shaders in NIR and MIR" —
the dump in fact also includes the final packed Valhall assembly) while
running the failing dEQP case or `repro_blit` against the patched local
build, capturing stderr to a file. The u_blitter TXF fragment shader is the
one named `TTN1` (TGSI-to-NIR) with `textures_used_by_txf` set. The captured
dump header recorded `GL_RENDERER=Mali-G610 MC4 (Panfrost)`, build
`git-82d387ae89`.

`PAN_MESA_DEBUG` is a *different* variable — driver-level toggles
(`nofp16`, `linear`, `sync`, ...) used in the ruled-out table below; it does
not dump compiler output.

## Interpolation Probe

[`video-libraries/mesa/reproducers/interp_probe/probe_interp.c`](../reproducers/interp_probe/probe_interp.c) isolates interpolation
from texture fetch. It renders a `W x 1` quad with a varying that runs from
`0` to `W` across the quad, then writes the interpolated value bit-exactly using
`floatBitsToUint`.

Observed (re-verified on the board 2026-07-01):

```text
mode=SMOOTH W=16307
floor(interp)!=i count = 15672 / 16307   max_rel_err=5.751e-02 (log2=-4.12)
  i=256    interp=256.3209   ideal=256.5    err=-0.1791
  i=16306  interp=16293.2832 ideal=16306.5  err=-13.2168

mode=FRAGCOORD.x W=16307
floor(interp)!=i count = 0 / 16307
  i=16306  interp=16306.5000 ideal=16306.5  err=+0.0000
```

That points at the varying interpolator. `gl_FragCoord.x` is exact because it
is generated from the rasterizer's pixel coordinate instead of loaded through
the varying unit (Panfrost computes it from the exact integer pixel index:
`fs_coord_pixel_center_integer`, `nir_load_pixel_coord + 0.5`).

[`video-libraries/mesa/reproducers/interp_probe/tiny_interp_probe.c`](../reproducers/interp_probe/tiny_interp_probe.c)
(2026-07-06) is the direct answer to the review argument "the hardware docs
say the interpolator is full 32-bit, so this must be u_blitter misusing
varyings". It strips the experiment down to pure varying interpolation — no
`u_blitter`, no texture, no `TXF`, no filtering, no tie-breakers, no
format-changing readback — and still drifts, while `gl_FragCoord.x` through
the identical pipeline is bit-exact. Canonical build/run/output, exit codes,
and the full width sweep live in
[`reproducers/interp_probe/README.md`](../reproducers/interp_probe/README.md);
the headline result on the shipped 26.0.3 driver (verbatim):

```text
$ ./tiny_interp_probe                  # 12288 x 1 varying; exit 2
mode=varying width=12288: floor(v) != x at 11744 of 12288 pixels (first at x=529)
last pixel x=12287: v=12275.5312 expected=12287.5 relative_error=9.741e-04 (0.997 * 2^-10)
```

The width sweep sharpens the empirical claim: every power-of-two width tested
(512-16384) is bit-exact, while non-power-of-two widths show a jagged
width-dependent relative error that quantizes per width (exactly `2^-12` at
`W=2080`, exactly `2^-14` at `W=16383`, ~`2^-10` at `W=12288` and `W=16307`;
smallest `floor()`-failing width `2080`). So "~2^-10" is the signature of
specific widths — including the ones the blit bug was found at — not a
blanket "f32 varyings are only 10-bit" rule. That pattern is consistent with
a full-precision interpolator ALU fed by a plane/coefficient setup that loses
precision for non-power-of-two render-target widths.

A Vulkan port of the probe reproduces the drift **bit-for-bit on panvk** — a
stack with no Gallium, no `u_blitter`, and no GL state tracker anywhere —
while the same binary passes on llvmpipe; verbatim outputs in
[`reproducers/interp_probe/README.md`](../reproducers/interp_probe/README.md).

### Low-Level Tiny-Probe Shader

Captured 2026-07-06 against the **system Mesa 26.0.3** driver, with the bug
reproducing during the capture. (An earlier version of this section showed a
dump from an older attribute-fed probe revision; this is the current
`gl_VertexID` probe.) Capture commands — the dumps themselves are dev-box
artifacts, not in the repo:

```bash
cd ../reproducers/interp_probe
BIFROST_MESA_DEBUG=shaders ./tiny_interp_probe 12288 varying   # compiler dump: NIR + packed Valhall asm
PAN_MESA_DEBUG=trace       ./tiny_interp_probe 12288 varying   # pandecode: decoded command streams + descriptors
PAN_MESA_DEBUG=trace       ./vk_interp_probe   12288 varying   # same for the panvk run
```

`BIFROST_MESA_DEBUG=shaders` is what produces shader dumps on this driver;
`PAN_MESA_DEBUG=trace` is a *different* variable that produces pandecode
command-stream dumps (its other toggles — `nofp16`, `linear`, `sync`, ... —
are used in the ruled-out table below).

The packed Valhall fragment shader for the varying mode, in full — the
varying goes from the load message straight to the blend message with **no
ALU in between**:

```asm
NOP.wait0126
ATEST.wait0 @r60, ^r60, 0x3F800000, atest_datum.w0
LD_VAR_BUF_IMM.f32.slot0.src_f32.center.store.discard @r0, ^r61, index:0x0
MOV.i32 r1, 0x0
MOV.i32 r2, 0x0
MOV.i32.wait r3, 0x0
BLEND.slot1.v4.u32.end @r0:r1:r2:r3, blend_descriptor_0.w0, r60, target:0x0
```

`LD_VAR_BUF_IMM.f32...center` is Valhall v10's buffer-based
interpolated-varying fetch — f32 in, f32 out, sampled at the pixel center —
already the maximum-precision variant of the varying load. The IDVS varying
vertex shader computes `v` with exactly-representable arithmetic (the stored
per-vertex values are `0.0` and `2*width = 24576.0`, both exact in f32) and
ends in a raw `STORE.i32` — no conversion touches the value on its way to
memory. The panvk-compiled fragment shader is instruction-for-instruction
identical (only the blend-descriptor constant source differs). So the shader
cannot be the source of the error; the only remaining variables are the
varying descriptors the driver programs and the fixed-function interpolation
itself.

The pandecode dumps of both the GL and panvk runs — the literal decoded
command streams and descriptors — close most of the descriptor half: the
varying descriptor is plain `Format R32F, Vertex packet, stride 16` with
sane flags (`Preserve subnormals`, no NaN suppression), and — the key
structural fact — **no driver-computed plane-equation coefficients exist
anywhere on Mali**: the hardware derives the interpolation from the raw
per-vertex f32 values plus the rasterizer's barycentrics. There is no
coefficient buffer a driver could have filled imprecisely.

### Going Lower

The feasibility ladder for even-lower-level reproduction, assessed
2026-07-06:

- **Done:** the GL and panvk probes, the instruction-identical
  `LD_VAR_BUF_IMM` fragment shaders, and the `PAN_MESA_DEBUG=trace`
  pandecode command-stream dumps above.
- **Assessed, not built:** a hand-built CSF command stream submitted through
  raw panthor ioctls. That is a mini-driver — roughly 1.5-3k lines covering
  VM/queue setup, the tiler heap, FBD/DCD/IDVS SPD packing, and
  `RUN_IDVS`/`RUN_FRAGMENT`. Crib sources exist in-tree (the panvk CSF
  backend `src/panfrost/vulkan/csf/`, genxml `cs_builder.h`, kraid's
  compute-only hw_runner harness
  `src/panfrost/compiler/kraid/hw_runner/`, and
  `/usr/include/drm/panthor_drm.h` is present on the board), but the
  marginal evidentiary value is modest: the pandecode dumps already expose
  every descriptor byte such a harness would emit.
- **The single most probative remaining runtime step**, if the hardware
  attribution is still disputed: run the ARM-named interpolation reproducers on
  ARM's proprietary blob driver. The stack notes and runbook are now in
  [`arm-mali-blob-stack.md`](./arm-mali-blob-stack.md) and
  [`../reproducers/interp_probe/README-arm-blob.md`](../reproducers/interp_probe/README-arm-blob.md).
  The public RK3588/G610 libmali package advertises a Vulkan 1.3 ICD and the
  inspected GBM blobs expose surfaceless EGL/GL extension strings, but no
  proprietary-driver runtime output has been captured in this repo yet.

One dead end recorded: `BIFROST_MESA_DEBUG=noidvs` breaks Valhall rendering
outright in this driver (`v=0.0` everywhere — tested 2026-07-06), so no
environment knob switches the varying path for an A/B experiment.

## The Probe Frame Contains No u_blitter Work

The tiny probe's frame provably contains no u_blitter or internal-blit work.

Source-level (Mesa 26.0.3): `st_ReadPixels` bails to the CPU fallback before
any blit because panfrost reports `texture_transfer_modes = 0`
(`pan_screen.c:825` → `st_context.c:491-494` → `st_cb_readpixels.c:443`),
and `_mesa_readpixels` reduces to a memcpy since `R32UI` matches
`GL_RED_INTEGER`/`GL_UNSIGNED_INT`. The mapped resource is
`DRM_FORMAT_MOD_LINEAR` (tiling is rejected for height-1 targets at
`pan_resource.c:701`; AFBC has no R32 mode per `pan_afbc.h:498-604`), so
`panfrost_ptr_map` returns a direct CPU pointer after a flush+wait — the
AFBC staging-blit branch is never reached. The draw is a single
`glDrawArrays` with no clear, and tile preload is skipped because a fresh
`glTexStorage2D` image has no valid contents (`pan_job.c:537-542`).

Empirically, on debug builds of the corrected !42613/!42614 stack — which,
unlike shipped 26.0.3, even enable blit-based transfers — gdb breakpoints on
every `util_blitter_*` entry point, `panfrost_blit`, `pan_blit_to_staging`,
and the panfrost preload emitters record **zero hits** for the executed
frame across a full failing run. The only preload descriptors emitted are
the never-executed tiler-OOM contingency FBDs (no "Incremental rendering was
triggered" under `PAN_MESA_DEBUG=sync,perf`).

The same runs reproduce the varying drift bit-identically (11744/12288 bad,
`0.997 * 2^-10`) while the `gl_FragCoord` control reads back exact — which
also confirms the drift persists on the fixed MR stack, as it must: the fix
reroutes u_blitter's TXF coordinates around varyings; it does not (and
does not attempt to) repair varying interpolation. So the 2^-10-class error is
produced in the affected varying-interpolation path — not in u_blitter's TXF
instruction or the readback. The zero-valued depth-bias workaround documented
above proves that the error is conditional, not an inherent precision limit.

## What The `2^-10` Signature Means

For normal texture coordinates, a relative error around `2^-10` is often
tolerable. For an integer texel-address path it is not.

At x around 16000:

```text
16000 * 2^-10 ~= 15.6
```

The observed right-edge error was about 13 texels. After
`F32_TO_S32.rtz`, that turns directly into fetching an earlier texel. This is
why a small relative interpolation error becomes a large integer readback
failure.

This is the measured erratum signature at specific non-power-of-two widths;
the error is width-dependent (`2^-12` at `W=2080`, `2^-14` at `W=16383`,
~`2^-10` at `W=12288`/`W=16307`) and is never seen at power-of-two extents.
The tiny and panvk probes narrowed the failure to the hardware interpolation
setup rather than `u_blitter` or its texture operation. The 2026-07-22
zero-valued depth-bias result then supplied the discriminator the original
investigation lacked: the identical varying becomes exact when the Valhall
depth-bias-enable state bit is set.

## Why `noperspective` Did Not Fix It

Mali does not expose a precise screen-linear varying interpolation instruction.
Panfrost's lowering reflects that — per the comment at the top of
`src/panfrost/compiler/pan_nir_lower_noperspective.c`:

> Mali only provides instructions to fetch varyings with either flat or
> perspective-correct interpolation. This pass lowers noperspective varyings
> to perspective-correct varyings by multiplying by W in the VS and dividing
> by W in the FS.

So `noperspective` travels through the same lossy perspective machinery
(forcing `prefer_persp = false` in the compiler failed the same way). Note
also that the qualifier does not exist in GLSL ES at all — `noperspective` is
a reserved word, which is why `probe_interp` mode=1 fails to compile under an
ES context (see [`video-libraries/mesa/reproducers/interp_probe/README.md`](../reproducers/interp_probe/README.md)).

The useful options in the fragment shader are:

- `LD_VAR_IMM` / `LD_VAR_BUF` style interpolated varying fetches: per-pixel but
  subject to the same perspective interpolation precision.
- `LD_VAR_FLAT`: exact, but constant across the primitive (provoking-vertex
  value; no interpolation).
- `gl_FragCoord`: exact screen-space pixel coordinate, but not a general varying.

An ALU-interpolation route is closed off entirely: Mali has no equivalent of
AGX's `load_coefficients_agx`, so the shader cannot see plane-equation
coefficients or raw per-vertex data and cannot interpolate for itself.

So there is no compiler flag that makes the existing `u_blitter` varying exact.
The fix has to avoid the varying path or rewrite the blit to derive coordinates
from `gl_FragCoord` plus the source/destination affine.

## Hypotheses Ruled Out

These were checked and did not make BLIT correct:

| Hypothesis | Result |
|---|---|
| fp16 lowering / `PAN_MESA_DEBUG=nofp16` | No effect. NIR and asm showed f32 coordinate handling; the loss is in the fixed-function varying interpolation. |
| Explicit `fmul coord, frag_w` | Red herring. The default path has no explicit multiply; the perspective divide is internal to `LD_VAR_IMM`. |
| Pixel-center mismatch | Refuted. The error grows with coordinate magnitude (−0.18 at i=256 → −13.2 at i=16306); a center mismatch would be a constant half-pixel shift, and `gl_FragCoord` (which does get the +0.5) is exact. `tiny_interp_probe.c` has no texture sample at all and compares directly against the pixel-center ideal `x + 0.5`. |
| AFBC or modifier layout, `PAN_MESA_DEBUG=linear` | Still failed. |
| Missing fence, `PAN_MESA_DEBUG=sync` | Still failed. |
| Readpixels cache, `ST_DEBUG=noreadpixcache` | Still failed. |
| Diagonal split / single triangle | Still failed. An earlier `tiny_interp_probe` revision drew the same varying plane as a two-triangle quad and as a single triangle; the results were bit-identical (15672/16307 either way), so this is not a two-triangle seam. |
| TXF path toggles (`util_blitter_blit_with_txf` selection) | Still failed. |
| `gl_FragCoord.w` correction | `gl_FragCoord.w` is exactly `1.0` — it does not carry the interpolation error, so `interp / w` fails identically (15672/16307). |
| `dFdx` reconstruction | Worse: `16187 / 16307` mismatches. Mali's derivatives are themselves coarse/quantized. |

The `dFdx`/reconstruction probe lives in
[`video-libraries/mesa/reproducers/probe_wcorr.c`](../reproducers/probe_wcorr.c). The name is historical:
the final variant records the interpolated coordinate and derivative to test
whether the fragment shader can recover an exact coordinate locally. The
general point: a *relative* error needs an *absolute* reference, and the
fragment shader has none.

## Why Asahi/AGX Was Not Evidence That BLIT Is Safe

Asahi also advertises a BLIT transfer path, and it uses the same high-level
`u_blitter` idea, but AGX does not have the same precision problem.

Source of these claims: reading the in-tree AGX code (verified against the
local Mesa 26.2-devel checkout, 2026-07-01), not reviewer statements:

- `src/gallium/drivers/asahi/agx_pipe.c` advertises
  `caps->texture_transfer_modes = PIPE_TEXTURE_TRANSFER_BLIT`.
- `src/asahi/compiler/agx_nir_lower_interpolation.c` evaluates the varying's
  plane equation in f32 ALU (`nir_ffma` chains on
  `nir_load_coefficients_agx`, explicit f32 `nir_fdiv` for the perspective
  divide) — ~2^-23 relative precision, not ~2^-10.
- The same file interpolates **tile-locally**
  (`nir_umod_imm(b, pixel_coords, 32)`): the variable part is a small tile
  offset (0..31) and the large magnitude lives in the exact per-tile constant
  coefficient, so a ~16000-wide coordinate never flows through a
  low-precision step. That is the "keep the interpolated value small, add
  back a large exact constant" trick, done per tile.

Mali has no equivalent shader-visible coefficient load and no exact
screen-linear varying mode. The full-magnitude coordinate goes through the
fixed-function interpolator, so the relative error becomes visible. No other
in-tree driver is known to trip this.

## Options Considered

There are only two ways to get an exact per-pixel coordinate on Mali — a
compute invocation ID or `gl_FragCoord` — plus the CPU fallback. Combined
with "how much of the sampled blit you avoid", every option is a point in
this grid ("the risky case" = a pure-integer, format-changing
readback/transfer such as `RG32UI -> RGBA32UI`):

| | Avoid blit for ALL transfers | Avoid blit for the risky case only | Fix the blit itself |
|---|---|---|---|
| exact via compute | **B3** COMPUTE-only — *rejected: AFBC* | **B2** `BLIT\|COMPUTE` + state-tracker route | — |
| exact via `gl_FragCoord` | — | — | **A1/A2** u_blitter fix |
| exact via CPU | (that is `modes = 0`, the status quo) | **B1** state-tracker fallback to CPU | — |

- **B3 — COMPUTE-only** (`caps = COMPUTE` + `is_compute_copy_faster`):
  Panfrost-local, exact, fixed every measured failure, no measured transfer
  slowdown ([`validation.md`](validation.md)). **Rejected by maintainer
  review 2026-07-01** — see the AFBC constraint below.
- **B2 — `BLIT | COMPUTE` + route**: keep the blit fast path, detour only
  pure-integer format-changing transfers to compute. Needs a state-tracker
  condition in each covered path, and must stay layout-aware (never write or
  force-convert an AFBC destination through compute).
- **B1 — CPU fallback for the risky case**: same condition, no COMPUTE bit;
  the risky readback lands on `_mesa_readpixels` (CPU). Smallest change,
  slow, covers only the paths where the condition is added. This was the
  stashed `st_cb_readpixels.c` workaround; a fresh variant exists as local
  branch `panfrost-transfer-targeted-fallback` (rebased to `6a292503585`,
  touching `st_cb_readpixels.c` + `st_cb_texture.c`).
  **Disqualified on hardware 2026-07-01**: the drift affects every wide TXF
  blit regardless of format, and a non-integer format-changing readback
  (`RG32F -> RGBA32F`) corrupts identically through B1's gate — see
  [§ On-Device Verification (2026-07-01)](#on-device-verification-2026-07-01)
  below.
- **A1/A2 — rewrite the u_blitter TXF coordinate around `gl_FragCoord`**:
  TXF blits are always **unscaled** (`util_blitter_blit_with_txf` requires
  `!is_scaled`), so fragment→source-texel is a pure translation and
  `coord = scale * gl_FragCoord + offset` is exact. A proof-of-concept that
  sourced the TXF coordinate from `gl_FragCoord` (offset-0) gave
  **0/16307 errors** and passed the failing dEQP case — but it needs the full
  affine plumbed (scale, offset, gl_FragCoord's top-left origin; the PoC
  regresses non-zero-offset and y-flipped blits). A1 gates it behind a new
  screen cap; A2 applies it unconditionally (`gl_FragCoord` is exact
  everywhere). Shared-code change, most subtle, and it mostly benefits
  Mali-class hardware. Local staging branch:
  `panfrost-transfer-fragcoord-blit` — rebased to `2f6e8a6afcc` "u_blitter:
  use fragment position for unscaled TXF blits" (opt-in
  `blitter_context::use_txf_fragcoord` flag; `u_blitter.c` +
  `u_simple_shaders.c`, BLIT re-enabled in `pan_screen.c`, flag set in
  `pan_context.c` when `fs_position_is_sysval`), which plumbs the full
  affine: `scale.xy`/`offset.zw` ride the generated coordinate attribute and
  the FS reconstructs the TXF coordinate with a `MAD` from
  `TGSI_SEMANTIC_POSITION` declared as a system value.
  **Selected as the upstream direction 2026-07-01** after the on-device
  verification below cleared its numerical design risks and disqualified B1.
- **Panfrost NIR pass** — ruled out: a NIR pass cannot recover the exact
  coordinate without the src/dst offset, which only `u_blitter` has; doing it
  anyway needs draw-time blit detection, a shader variant, and a sysval.
  Fragile.
- **AGX-style re-base** (`LD_VAR_FLAT` exact per-primitive base + small
  interpolated delta) — ruled out: precise but requires splitting blits into
  small primitives and emitting both a flat base and a delta from the VS;
  strictly more plumbing than `gl_FragCoord` with no upside.

## Review Followups: Empty Blits And Buffer Targets

Two maintainer-review details are easy to misread because they look like small
defensive checks, but they are really layer-boundary decisions.

**Zero-sized blits.** `glCopyImageSubData` and related API paths can legally
describe zero-sized copy boxes; those are no-ops. That does not mean
`u_blitter` should accept a zero-sized render blit. A render blit with zero
width/height rasterizes no fragments, and the fragcoord path's affine
(`scale = src_extent / dst_extent`) has no meaningful value. The first !42679
revision handled this by substituting scale 1 for degenerate axes; after review
that was removed. The current invariant is: API/front-end code skips empty
regions before building Gallium blits, while `u_blitter` assumes non-empty work
and asserts that the destination axes are not zero in the fragcoord path.

Follow-up branches exist but are not part of the current MR stack:

- `zero-sized-blits-gallium` (`d8cf9625ba5`) skips empty GL/DRI copy rectangles
  in `dri2_blit_image`, `glCopyImageSubData`, and `glCopyTexSubImage*` before
  constructing Gallium blits.
- `zero-sized-blits-lavapipe` (`740be57319d`) skips empty Vulkan blit/resolve
  regions before lavapipe builds `pipe_blit_info` for llvmpipe/softpipe.

**`PIPE_BUFFER`.** `PIPE_BUFFER` is a valid Gallium target in other contexts,
including buffer textures and PBO/SSBO-style helper paths, but it does not reach
this `u_blitter` render-blit TXF path. Buffer copies route through resource or
buffer-copy machinery rather than rendering a sampled blit to a pipe surface.
So `blitter_target_supports_txf()` intentionally reasons only about texture
targets and cube exclusion; mentioning `PIPE_BUFFER` there would document a case
that cannot happen.

## The AFBC Constraint (Why COMPUTE-Only Was Rejected)

Maintainer review comment on MR !42563 (2026-07-01):

```text
Compute isn't the right solution. We can't write AFBC that way.
```

This is correct for Panfrost. AFBC is not just a linear pixel layout: the
driver can calculate AFBC header/body sizes, but it does not know the internal
payload encoding well enough to write arbitrary pixels into it from a shader.
AFBC encode/decode is provided by the Mali texture/render hardware, and for
CPU-visible transfers Panfrost explicitly creates a linear staging resource
and uses GPU blits for `AFBC <-> linear`. In-tree source facts (verified
2026-07-01):

- `src/panfrost/lib/pan_afbc.h` — Panfrost treats AFBC payload encoding as
  opaque and uses GPU blits for `AFBC <-> linear`.
- `pipe_to_pan_bind_flags()` maps `PIPE_BIND_SHADER_IMAGE` to
  `PAN_BIND_STORAGE_IMAGE`.
- `src/panfrost/lib/pan_mod.c` rejects AFBC when `PAN_BIND_STORAGE_IMAGE` is
  present ("No image store", twice, once per AFBC family).
- `src/panfrost/lib/pan_texture.c` (storage-texture emit path): "AFBC and
  AFRC cannot be used in storage operations."
- `panfrost_set_shader_images()` converts AFBC/AFRC resources away from AFBC
  before binding them as shader images.

So compute can be safe where it reads AFBC and writes linear, but a blanket
compute preference for texture transfers would either fail to write AFBC or
force/degrade resources out of AFBC — unacceptable for scanout/shared/
render-target resources. Any surviving compute route must be
destination/layout-aware.

## Mesa Fix Shape (The Tested COMPUTE Candidate)

What was actually built and validated (now evidence, not the final answer):

```c
caps->texture_transfer_modes = PIPE_TEXTURE_TRANSFER_COMPUTE;
```

plus the compute-copy heuristic:

```c
static bool
panfrost_is_compute_copy_faster(struct pipe_screen *pscreen,
                                enum pipe_format src_format,
                                enum pipe_format dst_format,
                                unsigned width, unsigned height,
                                unsigned depth, bool cpu)
{
   if (cpu)
      return (uint64_t)width * height * depth > 64 * 64;
   return false;
}
```

The first patch in MR !42563 fixes shader-image unbind bookkeeping, which the
compute transfer path relies on (and which any compute/shader-image user can
hit). Without that fix, a trailing unbind could leave a stale `image_mask`
bit pointing at a NULL image resource.

The verified Fixes trailer for that first patch is:

```text
Fixes: 72ff66c3d73 ("gallium: add unbind_num_trailing_slots to set_shader_images")
```

## On-Device Verification (2026-07-01)

The probes run on the ROCK 5B (all archived in
[`../reproducers/`](../reproducers/README.md)) settled the choice between the
surviving candidates. Builds: `git-2f6e8a6afc` = fragcoord branch,
`git-6a29250358` = targeted-fallback branch, Mesa 26.0.3 = unfixed system
driver.

**1. The drift is format-agnostic; B1's integer gate is under-inclusive
(disqualifying).** `repro_blit_float.c` reads an `RG32F` FBO
(`source[i] = {i, i}`) back as `GL_RGBA` + `GL_FLOAT` — a format-changing
(`RG32F -> RGBA32F` staging) but non-pure-integer readback, so B1's
`util_format_is_pure_integer` gate does not fire:

```text
targeted-fallback git-6a29250358:  15672 / 16307 corrupt (96.1%), first at x=623
fragcoord         git-2f6e8a6afc:      0 / 16307
```

That is the exact original bug signature. The integer control (`repro_blit`)
passes on both builds, so B1's gate works as written — it is simply too
narrow, and widening it to "any format change" would effectively disable the
transfer blit. B1 is dead as a narrow workaround; only the failure mode dEQP
happened to detect was integer.

**2. Constant varyings interpolate bit-exactly (clears A1's design risk).**
The fragcoord branch passes `scale`/`offset` through the ordinary
smooth-interpolated attribute. `probe_const.c` shows an all-vertices-equal
smooth varying survives interpolation with **0/16307 bit mismatches at every
magnitude tested** (K = 1.0 … 16306.5). Only varyings that actually *vary*
accumulate the ~2^-10 error, so per-draw constants of any magnitude are safe
— no flat-interpolation rework needed, and with exact constants the FS `MAD`
on the exact `gl_FragCoord` makes the whole path exact. This also means a
layer index (another per-draw constant) is numerically safe, so extending
the fix to 1D/2D arrays is a feasible follow-up.

**3. Large source offsets are exact end-to-end.** `repro_blit_off.c` reads a
subregion starting at `x = X0`, driving `offset_x = src_x1` through the new
path: **0 mismatches at X0 = 1, 623, 8000, 16000** on the fragcoord branch.
(The earlier PoC concern about non-zero-offset blits is resolved by the full
affine plumbing; y flips and scissor still need explicit tests.)

**4. The system Mesa 26.0.3 driver IS corrupted via direct wide blits (the AFBC CPU-map
path is clean).** `repro_afbc.c` probes the AFBC CPU-map staging blit
(`pan_blit_to_staging`) via a wide RGBA8 FBO readback in the matching
format, incl. `PAN_MESA_DEBUG=forcepack`: clean on the unfixed Mesa 26.0.3
system driver. But `repro_blit_flip.c` later showed that a *direct* wide
non-pow2 unscaled `glBlitFramebuffer` **is corrupt on the system Mesa 26.0.3 driver**:
16307x2 RG32UI on Mesa 26.0.3 returns 29498/32614 wrong texels (first at
x=1539, fetched 1538) in all four orientations — no transfer-mode cap
involved. So the fragcoord fix is a bugfix for an already-reachable path
*and* the BLIT-transfer enabler. Real-world exposure is narrow (drift onset
between 3000 and 5000 px; pow2 extents exact — see finding 5), which is why
it went unreported.

**5. The drift only occurs for non-power-of-two primitive extents
(2026-07-01, `repro_blit_flip.c`).** Unfixed-path 1-row identity
`glBlitFramebuffer`: widths 8192 and 16384 are **bit-exact**, while
5000/7000/8191/8193/12000/16307 all drift (onset between 3000 and 5000;
height irrelevant). So the "~2^-10 interpolation" is more precisely a
low-precision reciprocal in the interpolator's plane-equation setup that is
exact for power-of-two extents. Consequences: (a) common blit sizes mask the
bug, explaining why wide-blit corruption was never reported; (b) any
regression test must use a large **non-pow2** width — an 8192-wide test can
never fail.

**6. Panfrost's TGSI position system value is the integer pixel index, not
x+0.5.** The first fragcoord branch assumed the half-integer convention and
broke *flipped* blits (negative scale): with scale=+1 the missing half texel
is hidden by the truncating f2i, with scale=-1 every fetch is one texel off
and row/column 0 goes out of bounds. Fixed convention-independently in the
final series: `src = floor(pos) * scale + (offset + 0.5 * scale)` — floor()
yields the integer pixel index under either convention, and the half-texel
bias moves into the constant offset (exact in f32).

Two supporting facts for the upstream pitch, both verified in-tree:

- Panfrost's own FB preload shaders already derive coordinates from the exact
  pixel index (`nir_load_pixel_coord`, `src/panfrost/lib/pan_fb_nir.c`), so
  the fragcoord blit fix makes u_blitter do what Panfrost's internal blit
  machinery already does.
- `blitter_context` already carries opt-in behavior flags
  (`use_index_buffer`, `use_single_triangle`); `use_txf_fragcoord` follows
  that pattern and defaults off, leaving the ten other drivers that advertise
  `TRANSFER_BLIT` untouched.

Upstream-context note: the GitLab web UI is bot-blocked from the board, but
MR discussions are retrievable with the authenticated CLI
(`glab api "projects/176/merge_requests/<iid>/notes"`). From !38433/!42563:
kusma was positive on BLIT enablement in general ("I generally speaking think
this is a good idea"), rejected only compute, supplied the `Fixes:` tag for
the unbind fix, and asked that Joshua Watt's original enablement commit be
cherry-picked for author credit. No prior art for the Mali varying-precision
issue or a u_blitter fragcoord fix was found upstream (web + GitLab issue
search), so the MR description must carry the full justification itself.

## Bottom Line

For Mali-G610, sampled BLIT texture transfers without an avoidance/workaround
can be unsafe on wide paths that derive texel addresses from interpolated
varyings — integer formats were merely where dEQP could detect it bit-exactly
(`repro_blit_float.c` shows the identical failure on floats). There is no
local Panfrost compiler toggle that makes `LD_VAR_IMM` exact.

Three escapes now have different scopes. COMPUTE is measured safe and fast but
cannot write AFBC, so maintainers rejected it as the blanket transfer answer.
The `gl_FragCoord` rewrite is exact across the tested blit shapes and is carried
by the open four-MR transfer stack; it avoids the erratum for those generated
coordinates rather than repairing arbitrary varyings. Zero-valued depth bias
repairs the measured raw-varying and ordinary-TEX cases and is the basis of MR
!43161's internal-blitter workaround.

The 2026-07-27 forced-policy A/B closes only its named R32UI functional subset.
It does **not** quantify recurring cost or validate every format, scaling,
flipping, scissor, layer, or MSAA path. The next decision-grade performance
result needs the corrected work-owning timer/counters, descriptor trace, fixed
GPU/CPU clocks, and an unsanitized kernel. See
[`README.md` § Status](../README.md#mr-status)
for the upstream shape and the
[benchmark result](../../../findings/2026-07-27-mesa-all-blit-workaround-benchmark-results.md)
for the exact open boundary.
