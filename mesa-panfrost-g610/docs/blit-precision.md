# BLIT Precision Root Cause

This is the detailed chain from "Panfrost should enable texture transfers" to
"the sampled BLIT path cannot be trusted with integer texel addresses on
Mali-G610" — and what that leaves as viable fixes. Status and dated MR
lifecycle live in [`README.md` § Status](../README.md).

## Starting Point

The first attempted change was:

```c
caps->texture_transfer_modes = PIPE_TEXTURE_TRANSFER_BLIT;
```

(the direction of Joshua Watt's MR !38433; the exact local commit is archived
as
[`reproducers/0001-panfrost-advertise-transfer-blit-and-compute.patch`](../reproducers/0001-panfrost-advertise-transfer-blit-and-compute.patch)).

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
[`reproducers/repro_blit.c`](../reproducers/repro_blit.c) builds an `R32G32_UINT`
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
one named `TTN1` (TGSI-to-NIR) with `textures_used_by_txf` set. The raw dump
this listing came from survives on the dev box as
`/home/yi/Code/mesa/.codex-tmp/bi_asm.txt` (header records
`GL_RENDERER=Mali-G610 MC4 (Panfrost)`, build `git-82d387ae89`).

`PAN_MESA_DEBUG` is a *different* variable — driver-level toggles
(`nofp16`, `linear`, `sync`, ...) used in the ruled-out table below; it does
not dump compiler output.

## Interpolation Probe

[`reproducers/probe_interp.c`](../reproducers/probe_interp.c) isolates interpolation
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

## What The `2^-10` Means

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

This is a hardware precision property, not a Panfrost software bug: the
fixed-function varying interpolator computes the perspective correction (the
`1/w` reciprocal inside `LD_VAR`) at roughly `2^-10` relative precision, even
for `highp`/f32 varyings.

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
ES context (see [`reproducers/README.md`](../reproducers/README.md)).

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
| Pixel-center mismatch | Refuted. The error grows with coordinate magnitude (−0.18 at i=256 → −13.2 at i=16306); a center mismatch would be a constant half-pixel shift, and `gl_FragCoord` (which does get the +0.5) is exact. |
| AFBC or modifier layout, `PAN_MESA_DEBUG=linear` | Still failed. |
| Missing fence, `PAN_MESA_DEBUG=sync` | Still failed. |
| Readpixels cache, `ST_DEBUG=noreadpixcache` | Still failed. |
| Diagonal split / single triangle | Still failed. One big quad does not help either: the vertex values are still ~16000, so the interpolated magnitude (and the error) stays large regardless of triangle size. |
| TXF path toggles (`util_blitter_blit_with_txf` selection) | Still failed. |
| `gl_FragCoord.w` correction | `gl_FragCoord.w` is exactly `1.0` — it does not carry the interpolation error, so `interp / w` fails identically (15672/16307). |
| `dFdx` reconstruction | Worse: `16187 / 16307` mismatches. Mali's derivatives are themselves coarse/quantized. |

The `dFdx`/reconstruction probe lives in
[`reproducers/probe_wcorr.c`](../reproducers/probe_wcorr.c). The name is historical:
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

**4. Shipped drivers ARE corrupted via direct wide blits (the AFBC CPU-map
path is clean).** `repro_afbc.c` probes the AFBC CPU-map staging blit
(`pan_blit_to_staging`) via a wide RGBA8 FBO readback in the matching
format, incl. `PAN_MESA_DEBUG=forcepack`: clean on the unfixed Mesa 26.0.3
system driver. But `repro_blit_flip.c` later showed that a *direct* wide
non-pow2 unscaled `glBlitFramebuffer` **is corrupt on shipped drivers**:
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

For Mali-G610, sampled BLIT texture transfers are unsafe for **any** wide
format-changing path that derives texel addresses from interpolated varyings
— integer formats were merely where dEQP could detect it bit-exactly
(`repro_blit_float.c` shows the identical failure on floats). There is no
local Panfrost compiler toggle that makes `LD_VAR_IMM` exact.

The exact-coordinate escapes are COMPUTE (measured safe and fast, but cannot
write AFBC, so it cannot be the blanket answer — maintainer-rejected) and
`gl_FragCoord` (exact everywhere, verified including large offsets and
constants). **The selected upstream direction (2026-07-01) is the
`gl_FragCoord` blit rewrite (A1), branch `panfrost-transfer-fragcoord-blit`
(`2f6e8a6afcc`)**; the state-tracker fallback (B1) was disqualified by the
float counter-example above, and any compute route (B2) would additionally
need to prove layout-awareness. See [`README.md` § Status](../README.md) for
the MR shape and remaining test plan.
