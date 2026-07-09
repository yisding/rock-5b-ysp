# Blit-precision fix: the TGSI→NIR migration and doing it with pixel_coord

> Scope: Mesa `u_blitter` / `u_simple_shaders` blit fragment-shader generation —
> the follow-up to the proposed wide-blit precision fix (MR !42679, in review)
> that reworks it in NIR so the TXF coordinate comes from `pixel_coord`.
> Source: MR review discussion + inspection of a maintainer diff introducing
> `src/gallium/auxiliary/nir/nir_blit_helpers.c` (`nir_make_blit_frag_shader`)
> and deleting the TGSI `util_make_fragment_tex_shader`.
> Precision mechanism, reproducer, and the proposed fix are in
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
- NIR has **both** rasterizer-position primitives — `nir_load_pixel_coord`
  (integer `uvec2`) and `nir_load_frag_coord` (float `vec4`, `x+0.5` =
  `gl_FragCoord`) — so the whole blit shader, both fetch modes, is authored in
  one `nir_builder`: **no `tgsi_to_nir` round-trip, and no reliance on the
  `nir_lower_frag_coord_to_pixel_coord` bridge** !42679 leans on. They are the
  same rasterizer position in two forms (on Bifrost+ both resolve to the
  `BI_PRELOAD_POSITION_XY` preload); you just pick the form per branch.
- **!42679 is authored in TGSI** for good reasons, not by mistake:
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

- **It does not carry the precision fix.** The new function has no fragcoord /
  pixel-index path and the call site drops !42679's `use_txf_fragcoord` plumbing,
  so as written it still reads the interpolated coordinate and **leaves the
  wide-blit drift in place** — a pure shader-generation port. (Neither approach
  is landed, so nothing is being "regressed"; the point is that whatever
  supersedes the current `u_blitter` TGSI shader must fold the `pixel_coord`
  reconstruction in — the port alone is not the fix.)
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

The per-path primitive is deliberate — **not `gl_FragCoord` for both**. The copy
path takes the **integer** form (`pixel_coord`) so it is exact with no float; the
resize path takes the **float pixel-center** form (`gl_FragCoord` = `x+0.5`)
because a filtered sample is fractional by nature. You *could* use `gl_FragCoord`
for both and truncate for TXF — it is bit-exact at real sizes (`x+0.5` is exactly
representable to 2^23) and is essentially what !42679 already does for the copy
path — but it leaves the exact path doing a needless float round-trip, exactly
what integer `pixel_coord` removes. And you cannot instead just mark the
coordinate varying `flat`: the coordinate genuinely varies per pixel, so it can't
be one constant; only its *generator* (`scale`, `translate`) is constant, which
is why you ship the generator flat and rebuild the coordinate per fragment.
Mnemonic: **whole-number reads take the whole-number position; fractional reads
take the half-pixel-center position; both come straight from the rasterizer,
never from interpolation.**

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

### Why !42679 is TXF-only (and didn't just use gl_FragCoord for both)

This is not hypothetical: **!42679 *is* the TXF-only fix.** Per
`blit-precision.md` its FS already reconstructs the TXF coordinate with a
flat-coefficient `MAD` from `gl_FragCoord` (in the simplest case at "offset-0"),
so TGSI's vocabulary was never the blocker for using fragcoord. It stopped at TXF
because:

- **Separate code paths.** TXF (unscaled) and TEX (scaled/filtered) are chosen
  independently in `u_blitter` and use *different* shader generators; !42679 only
  touched the unscaled-TXF one. The scaled generator
  (`util_make_fragment_tex_shader`, `use_txf=false`) is untouched.
- **The unscaled case has a shortcut; the scaled case doesn't.** For a 1:1 copy
  the map is a pure integer translation, so `gl_FragCoord` *is* the source texel
  up to a constant offset — a near drop-in. The scaled case needs a fractional
  scale + normalization + routing to a filtered sample: the full reconstruction.
- **No forcing function.** The filtered path tolerates the drift and had no
  failing conformance test, so nothing pushed it.
- **Deeper:** `gl_FragCoord`-on-both is a *float-everywhere* fix; the exact path
  should carry the integer `pixel_coord` (the maintainer's point), which TGSI
  cannot express. Generalizing in TGSI is the same effort as the clean fix but
  leaves the copy path on float — so once you generalize, NIR wins.

Direction-of-change to keep in mind: before !42679 both paths drifted (wide blits
*uniformly* broken); after it, TXF is exact and TEX still drifts — so it **moves
the state into** the path-dependent divergence described above. The NIR unified
fix is therefore also "finishing the job": it closes the TEX gap and merges both
fetch modes onto one mechanism so they can't diverge.

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
  the `pixel_coord` swap folded in. The port alone does not fix the drift — the
  exactness has to live in the shader it generates, not be assumed from elsewhere.

## Direction / ownership (2026-07-08)

Status: **paused, pending the maintainer.** The analysis above is complete, but
the plan is *not* to drive the NIR migration forward from here:

- The NIR blit-generator migration is shared Gallium infrastructure touching
  every driver (the two-blast-radius split above), and the preference is **not to
  land several hundred lines of machine-generated code** into it. That area is
  the maintainer's; the cleaner outcome is for the maintainer to own the NIR
  migration directly.
- If a precision fix is wanted sooner, the targeted, arch-gated TGSI change
  (!42679, in review) is the shippable path and does not depend on the migration.

So: leave !42679 as the in-review targeted fix and **wait to see how the
maintainer wants to approach the NIR work** rather than pushing a large change
into shared code. This section is the "why we stopped here" marker.
