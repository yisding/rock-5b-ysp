# Blit-precision fix: the TGSI→NIR migration and doing it with pixel_coord

> Scope: Mesa `u_blitter` / `u_simple_shaders` blit fragment-shader generation —
> the follow-up to the merged wide-blit precision fix (!42679) that reworks it in
> NIR so the TXF coordinate comes from `pixel_coord`.
> Source: MR review discussion + inspection of a maintainer diff introducing
> `src/gallium/auxiliary/nir/nir_blit_helpers.c` (`nir_make_blit_frag_shader`)
> and deleting the TGSI `util_make_fragment_tex_shader`.
> Precision mechanism, reproducer, and the merged fix are in
> [`../video-libraries/mesa/docs/blit-precision.md`](../video-libraries/mesa/docs/blit-precision.md)
> and [`../video-libraries/mesa/docs/mr-review-findings.md`](../video-libraries/mesa/docs/mr-review-findings.md);
> the ARM-blob cross-check (drift is hardware) is in
> [`../video-libraries/mesa/docs/arm-mali-blob-stack.md`](../video-libraries/mesa/docs/arm-mali-blob-stack.md).
> Date: 2026-07-08.
> Trust: CODE-INSPECTED (the diff) / DESIGN (the proposed unified fix); the
> precision numbers it builds on are MEASURED (cross-refs above).

## The fact

The clean home for the wide-blit precision fix is **NIR, not TGSI**, and the
reason is IR vocabulary, not taste. Two `u_blitter` fetch modes need fixing
together, and both stop relying on the interpolated coordinate varying.

### Why NIR, and why the original fix was TGSI

- The bug: `u_blitter` bakes the source coordinate into a varying that ramps
  `0→W` and lets the interpolator reconstruct it. Mali's varying interpolation
  carries ~10 fractional bits **relative** to magnitude, so the delivered value
  has ≈`2^-10` relative error. TXF needs the integer texel index (absolute error
  < 0.5), which fails once the coordinate exceeds ~512 px. (Full mechanism in
  `blit-precision.md`.)
- The cure is the rasterizer's exact integer pixel index. **NIR has it as a
  first-class intrinsic** — `nir_load_pixel_coord` (`SYSTEM_VALUE_PIXEL_COORD`,
  `uvec2`). **TGSI does not**: its only fragment-position primitive is float
  `TGSI_SEMANTIC_POSITION` (= `gl_FragCoord`, `x+0.5`). To express an integer
  pixel index natively in TGSI you would have to **add a new TGSI
  semantic/opcode** and teach `ureg`, `tgsi_to_nir`, the dumpers, and the
  validator about it — growing a legacy IR that everything already lowers out
  of. The maintainer's objection ("I don't want us to add new TGSI opcodes") is
  exactly this.
- The merged **!42679 landed in TGSI anyway** for good reasons, not by mistake:
  the blit shaders already lived in `u_blitter`/`u_simple_shaders` as `ureg`
  (TGSI), and exactness was reachable **without** a new opcode by declaring the
  float `POSITION` and leaning on the existing downstream lowering
  `nir_lower_frag_coord_to_pixel_coord → u2f32(load_pixel_coord) →
  BI_PRELOAD_POSITION_XY`. That is a surgical, arch-gateable, easily-reviewed
  fix — correctness first, in place. It already used `pixel_coord`, just
  *indirectly* and still through a `u2f32` float round-trip.

So "do it in NIR" = stop borrowing `pixel_coord` through a downstream pass on a
float-authored TGSI shader; author the shader in NIR and use `load_pixel_coord`
directly — integer end to end, no new IR surface.

### What the maintainer's diff does (and does not do)

The diff adds `nir_blit_helpers.c::nir_make_blit_frag_shader` (a `nir_builder`
generator) and rewires `blitter_get_fs_texfetch_col` to it, deleting the TGSI
`util_make_fragment_tex_shader`. **This is the enabling refactor — not the
precision fix.** As written it still reads the coordinate from an interpolated
input and truncates it:

```c
nir_variable *in_var = ... nir_var_shader_in, VARYING_SLOT_VAR0 ...;  // interpolated
nir_def *coord = nir_load_deref(&b, in_deref);
if (use_txf) { coord = nir_f2i32(&b, nir_ftrunc(&b, coord)); ... }    // no pixel_coord
```

Consequences to flag:

- **Regression risk.** The new function has no fragcoord flag and the call site
  drops !42679's `use_txf_fragcoord` plumbing, so if this replaces the shader
  !42679 made exact, it **reintroduces the drift** — a lateral NIR port at best,
  a precision regression at worst, until the `pixel_coord` swap is added.
- The `interpolation` parameter is passed but never applied
  (`in_var->data.interpolation` is unset) — harmless for a `w=1` blit quad, but
  a dead param on this path.
- `assert(target != PIPE_BUFFER)` removes the old `TGSI_TEXTURE_BUFFER` branch;
  confirm no caller reaches it for buffer textures.

### The unified fix: TXF and TEX together

Both modes are the same affine map `src = scale·dst_pixel + translate`. Instead
of interpolating the *result*, pass the **coefficients** (`scale`, `translate`,
`layer`, `lod`) as **flat** inputs (or a UBO/push-constant) and re-evaluate per
fragment from the exact pixel position:

- **TXF (unscaled, exact):** `ij = nir_load_pixel_coord() + translate_int` →
  `nir_txf`. Pure integer; bit-exact. (`u_blitter` only uses TXF for unscaled
  copies, so `scale == 1`.)
- **TEX (scaled, filtered):** `uv = ffma(load_frag_coord().xy, scale, translate)`
  → `nir_tex`. One float MAD in the ALU (~`2^-24` relative), ~14 bits better
  than the interpolator; a filtered resize is not meant to be bit-exact anyway.

`u_blitter` **already computes this affine map** (its corner texcoords are the
map sampled at the corners); the caller change is to emit `scale`/`translate`/
`layer`/`lod` as flat constants instead of a `0→W` ramp, and the blit VS
collapses to position + flat passthrough. `pixel_coord`/`gl_FragCoord` are
absolute framebuffer coords, so fold the dst-rect origin into `translate`
(`translate = src_origin − dst_origin`, at pixel centers for TEX); normalized vs
RECT units are the same normalization `u_blitter` does today.

### Why fix TXF and TEX together, not TXF alone

Fixing only the integer path does **not** create seams *within* an image (a
given blit uses one shader/path, never both), but it leaves two real problems:

- **Scaled/filtered wide blits stay wrong.** The TEX path carries a normalized
  `0→1` texcoord varying; the same ~`2^-10`-relative interpolation error lands
  it ~`W·2^-10` texels off at the far (`u≈1`) edge — ~3–4 texels for a 4K
  downscale, ~15 at 16K. It shows up as a smooth misregistration/shear that
  grows toward the far edge (a warp, not a seam). Pre-existing bug you'd be
  declining to fix, invisible at small sizes, visibly wrong at large ones.
- **A consistency hazard — the genuinely "weird" one.** `u_blitter` picks TXF vs
  TEX by opaque internal criteria (format, caps, filter, samples). A logically
  identical operation — a 1:1 copy — can route through TXF (now exact) or fall
  back to **TEX-nearest** (still drifted at large coords) with no app-visible
  reason. So "the same" copy comes out crisp in one case and shifted in another
  depending on hidden path selection. That inconsistency across equivalent
  operations reads as weirder than any single-image artifact.

Since both are the same affine-map reconstruction (integer add vs one float MAD),
fixing them together is one extra branch — and it removes the hazard rather than
papering half of it.

## Why it matters / follow-up

- Concrete next step: in `nir_make_blit_frag_shader`'s `use_txf` branch, source
  xy from `nir_load_pixel_coord()` + integer `translate` (and layer/lod from flat
  inputs) instead of the truncated varying; update `u_blitter` to emit the
  coefficients. That single change turns the enabling refactor into *the* fix and
  guarantees no new TGSI opcode is ever needed.
- Verify with the wide-blit precision Gallium test (!42614) through the real
  `u_blitter` path at non-power-of-two widths (12288, 16307): TXF should read
  back bit-identical, TEX error well under a texel — same before/after signature
  captured on G610. `tiny_interp_probe` (`fragcoord` exact vs `varying` drift)
  remains the mechanism check.
- Watch item: whether the NIR migration lands as a lateral port first or with
  the `pixel_coord` swap folded in. Landing the port alone regresses !42679.
