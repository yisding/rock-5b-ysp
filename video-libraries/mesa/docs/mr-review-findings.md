# MR review findings — the four-MR blit-transfer stack

Structured review of the open upstream stack, performed 2026-07-06 with four
parallel review agents plus git-level stack checks. Scope and method:

- **!42563** `833101f35ed` — static review of the unbind fix + gallium
  cross-driver comparison (two independent passes).
- **!42679** `6509025064f` — deep static review of the shared `u_blitter`
  change: coordinate-math coverage matrix over every reachable parameter
  combination, predicate/threading audit, shader-generator audit.
- **!42613** `8875a22856d` — per-commit review incl. the full fragcoord
  exactness chain (rasterizer preload → NIR lowering → TGSI declaration) and
  st/mesa case analysis.
- **!42614** `4c23f1db1f9` — static review **plus live runs on the G610**:
  built the tip in `.codex-tmp/build-g610-debug`, ran the new u_test (pass),
  then flipped `use_txf_fragcoord` off in gdb and re-ran (fail with exactly
  the commit message's 40884 wrong texels). Both directions verified.
- Stack-wide: patch-id comparison of the duplicated u_blitter commit,
  ancestry checks, `git merge-tree` against origin/main, trailer hygiene.

## Verdict summary

| MR | Verdict | Blockers | Should-fix | Nits |
|---|---|---|---|---|
| !42563 unbind fix | Ship as-is | 0 | 0 (2 follow-up patches, out of MR scope) | 2 |
| !42679 u_blitter fragcoord | No blockers | 0 | 3 (1 latent code, 2 message) | 5 |
| !42613 panfrost enablement | No blockers | 0 | 3 (1 CI risk, 1 residual hazard, 1 hardening) | 3 |
| !42614 u_tests + glsl_type | No blockers, test verified both directions | 0 | 1 (message/comment wording) | 2 |

No finding invalidates the current CI-green state. The highest-priority
items before the next force-push: **!42613-SF1** (G52/G57 expectations),
**!42679-S2 / !42614-M1** (root-cause wording, now contradicted by the
[probe evidence](./blit-precision.md)), and **!42613-SF2** (residual
staging-alloc hazard).

## !42563 — `panfrost: clear shader image mask on trailing unbinds`

**Ship as-is.** Verified: `BITFIELD64_RANGE(start_slot, count +
unbind_num_trailing_slots)` exactly matches the release loop's half-open
range for every unbind shape, including the `count=0, trailing=N` shape that
u_threaded_context produces for *all* NULL image unbinds
(`u_threaded_context.c:2015-2018`) — meaning the old bug fired on
essentially every image unbind under tc. The fix converges on the iris
pattern (`iris_state.c:3402-3403`). `Fixes: 72ff66c3d73` is precisely the
commit that introduced the asymmetry. Sibling bind functions
(sampler views, shader buffers, vertex buffers) were audited: no
same-pattern latent bug. The NULL-deref claim was verified end-to-end
(`panfrost_emit_images` → `util_image_to_sampler_view` →
`u_helpers.c:538` dereference).

### Follow-up patches (pre-existing, do not fold into the MR)

**F1 — `image_mask` is `uint32_t` but the driver advertises 64 image slots.**
`pan_context.h:193` vs `max_shader_images = PIPE_MAX_SHADER_IMAGES` (= 64)
at `pan_screen.c:599`. Benign today only because st/mesa clamps to 32 per
stage; a non-GL frontend (rusticl) honoring 64 would silently lose bits ≥ 32
in `SET_BIT` (`pan_context.c:287`). `pan_cmdstream.c` already uses
`uint64_t image_mask` locals (2049, 2250, 2310), so 64-bit was the intent.

```diff
--- a/src/gallium/drivers/panfrost/pan_context.h
+++ b/src/gallium/drivers/panfrost/pan_context.h
@@ -190,7 +190,7 @@
    struct pipe_image_view images[MESA_SHADER_STAGES][PIPE_MAX_SHADER_IMAGES];
-   uint32_t image_mask[MESA_SHADER_STAGES];
+   uint64_t image_mask[MESA_SHADER_STAGES];
```

plus `util_last_bit` → `util_last_bit64` at `pan_cmdstream.c:990` and
`pan_cmdstream.h:290`, and `BITFIELD_BIT(i)` → `BITFIELD64_BIT(i)` at
`pan_cmdstream.c:1000`. (Alternative: clamp `max_shader_images` to 32.)

**F2 — signed-shift nit.** `pan_cmdstream.c:2116` tests the mask with
`(1 << i)` — UB at `i == 31` and inconsistent with the `uint64_t` local.
Use `BITFIELD64_BIT(i)`.

### Nits

- Commit-message tense mismatch: "releases resources … but only *cleared*."
- Body line at 82 chars (target ~72-75).

## !42679 — `u_blitter: use fragment position for unscaled TXF blits`

**No blockers.** The full coverage matrix was verified correct: scale ±1 on
each axis with zero/nonzero offsets (all arithmetic exact in f32 up to 2^22,
real max 16384-32768); the `scale_y*(layer+0.25)` encode / SSG+abs decode
for every sign/layer combination including layer 0 with negative scale (the
0.25 bias guarantees SSG never sees ±0) and 3D half-integer slices; flips
land on exact texel centers so `TRUNC ≡ FLOOR` everywhere; scissored and
single-triangle modes safe because the attribute is vertex-constant;
per-target swizzles + LOD-in-W verified against tgsi_to_nir; MSAA excluded,
1→N upsample correctly included; the encode decision is co-located with
shader selection and threaded through `do_blits` with **no mismatch window**;
flag-off generated shaders are byte-identical to before; the sysval POSITION
declaration matches what tgsi_to_nir asserts.

### Should-fix

**S1 — the refactored predicate admits `PIPE_BUFFER` (latent).**
`blitter_use_txf_fragcoord()` (`u_blitter.c:969-989`) now excludes only
cubes, so `PIPE_BUFFER` passes — but `util_make_fragment_tex_shader()`
short-circuits `TGSI_TEXTURE_BUFFER` with a raw `ureg_TXF`
(`u_simple_shaders.c:348-351`) *before* the fragcoord decode, while the
getter would still report `use_txf_fragcoord = true` → the draw would pack
the scale/offset encoding into an attribute the shader consumes raw. Not
reachable in-tree (no caller blits from a buffer sampler view, and
`cache_all_shaders` starts at `PIPE_TEXTURE_1D`), but it violates the
commit's own "only the shaders generated here decode that layout"
invariant.

**Maintainer context:** the explicit review direction on 2026-07-05 was to
*drop* the impossible `PIPE_BUFFER` case from this predicate/comment, so
re-adding `target != PIPE_BUFFER` would walk that back. The
maintainer-compatible fix is to pin the invariant where it would break —
one assert at the BUFFER short-circuit in `util_make_fragment_tex_shader`:

```diff
@@ util_make_fragment_tex_shader (u_simple_shaders.c, TGSI_TEXTURE_BUFFER branch)
    if (tex_target == TGSI_TEXTURE_BUFFER) {
+      /* Buffer fetches never go through the render-blit TXF path, so the
+       * fragcoord attribute encoding must not be requested for them. */
+      assert(!use_txf_fragcoord);
       ureg_TXF(ureg, temp, tex_target, tex, sampler);
```

(and align the commit-message target list — see N5.)

**S2 — commit message overclaims a hardware root cause.** Paragraphs 1, 2
and 5 assert mechanisms ("Mali's fixed-function varying unit interpolates
with a ~2^-10 relative error", "a low-precision reciprocal in the
interpolator's setup", "bypasses the varying unit entirely") that the
[reviewer disputes](./blit-precision.md) and that the probe data does not
prove. The measured facts are: width-dependent drift, pow2 extents
bit-exact, reproduces bit-identically on panvk with no u_blitter, mechanism
open. Proposed replacements (measurement-first, mechanism-neutral):

- Paragraph 1, replace from "which is not true everywhere:" through "same
  perspective path).":
  > "which does not hold on all hardware: on Mali-G610, interpolated f32
  > varyings show a width-dependent relative error of about 2^-10. The same
  > drift reproduces with a standalone Vulkan (panvk) probe that uses
  > neither u_blitter nor this shader, so it is a property of varying
  > interpolation on this GPU stack rather than of the blit path; whether it
  > originates in the interpolator itself or in shared coefficient setup is
  > still under investigation."
- Paragraph 2, replace "(a low-precision reciprocal in the interpolator's
  setup is still exact for powers of two)" with "power-of-two extents
  interpolated bit-exactly in every measurement".
- Paragraph 5, replace "it is produced from the rasterizer's integer pixel
  index and bypasses the varying unit entirely" with "across the same widths
  it was measured bit-exact (0/16307 errors), as expected for a value whose
  integer part is the rasterizer's pixel index rather than an interpolated
  varying."
- `u_blitter.h:104-105`: replace "For hardware whose varying interpolation
  is too imprecise to address texels exactly in wide unscaled blits, but
  whose fragment position is exact." with "For drivers where interpolated
  varyings do not reliably reproduce exact texel coordinates in wide
  unscaled blits, while the fragment position does."
- Same treatment applies to the `pan_context.c:1207-1213` comment in
  !42613's opt-in commit.

**S3 — pre-empt the "nearest samples should be centered" review point.**
The code already does the right thing; the message should say so. For
scale +1, `src = (px − dst_x1) + src_x1 + 0.5` — every truncated value is
exactly a half-integer with a half-texel margin on both sides, never on a
tie-break boundary. Proposed sentence after the `offset' = offset +
0.5 * scale` paragraph:

> "The computed source coordinate always lands exactly on a texel center
> (k + 0.5, exact in f32), so the truncation has a half-texel margin on both
> sides and never sits on a tie-break boundary — addressing the general
> requirement that nearest-filtered fetches be centered inside texels."

### Nits

- **N1 — zero-area blits: state the release-build analysis in the message.**
  The assert precedes the division (good); in release builds an empty box
  would produce NaN attributes but a degenerate quad that rasterizes zero
  fragments — a harmless no-op, same as the varying path. Front-end
  filtering is load-bearing though: GL drops empty blits
  (`main/blit.c:857-858`), but `util_blitter_blit_with_txf`
  (`u_blitter.c:2156-2163`) checks `box.x + box.width > 0`, not
  `> box.x`, so TXF selection alone does not reject empties, and
  `docs/gallium/context.rst` does not document a non-empty requirement for
  `blit`. Proposed message sentence: "Zero-area blits are filtered by
  front-ends before reaching u_blitter; the fragcoord path asserts this. In
  release builds an empty box would produce a degenerate quad that
  rasterizes no fragments, same as before."
- **N2 — naming collision:** static function `blitter_use_txf_fragcoord()`
  vs field `use_txf_fragcoord` vs the locals it feeds; call sites read like
  a variable. Suggest `blitter_wants_txf_fragcoord()`.
- **N3 —** `u_simple_shaders.c:257-258` comment has an awkward line break
  ("The flat attribute carries\n (see blitter_draw_tex):").
- **N4 —** `util_make_fs_blit_zs(PIPE_MASK_ZS)` emits the SSG/FLR/MAD decode
  twice (`u_simple_shaders.c:407/424`). Verified harmless (ureg decl dedupe
  + NIR CSE); not worth restructuring, mention only if a reviewer asks.
- **N5 —** the message's target list ("1D/2D/RECT, their array variants,
  and 3D") no longer matches the cube-only exclusion in code; reword to
  "all non-cube sampled targets" (consistent with the S1 maintainer
  direction).

## !42613 — `panfrost: enable blit-based texture transfers`

**No blockers.** Verified: the complete fragcoord exactness chain on
arch ≥ 6 (`fs_position_is_sysval` and `fs_coord_pixel_center_integer` flip
on the same condition as the opt-in; POSITION sysval →
`nir_lower_frag_coord_to_pixel_coord` → `u2f32(load_pixel_coord)` with no
half-pixel bias → MOV from the preloaded `BI_PRELOAD_POSITION_XY` rasterizer
integer pixel index — exact, bypasses the varying unit; Midgard correctly
excluded because position there is a varying input). The st/mesa guard's
case analysis (PBO-at-offset-0 kept, allocation-only skipped, compressed
paths unaffected, `unpack->BufferObj` NULL-test is the current Mesa idiom).
The cherry-pick is faithful (author field, S-o-b, R-b Erik Faye-Lund
preserved; only the arch gate added, disclosed in a `[Yi: ...]` note;
`Part-of:` correctly dropped). `glx@glx-copy-sub-buffer` appears in no other
G610 expectation file.

### Should-fix

**SF1 — G52/G57 still expect `glx@glx-copy-sub-buffer,Fail` (CI risk).**
`panfrost-g52-fails.txt:280` and `panfrost-g57-fails.txt:2` keep the line
the G610 commit removes. Both boards are arch ≥ 6, so the stack enables
BLIT transfers there too, and their piglit jobs run glx tests — if the test
improves there, those shards go red with `UnexpectedImprovement(Pass)`.
Likely mechanism (worth stating in the message): not the precision fix
(the test window is far below the drift onset) but the readback path flip —
the BLIT cap makes `st_ReadPixels` take the GPU-blit staging path
(`st_cb_readpixels.c:450`) instead of a direct CPU map of the front-buffer
resource. Action: run the full (not selected) pipeline; either drop the
G52/G57 lines too or record why G610 alone improves. Proposed message
addition:

> "glx-copy-sub-buffer probes the front buffer with glReadPixels after
> glXCopySubBufferMESA; PIPE_TEXTURE_TRANSFER_BLIT routes that readback
> through a GPU blit (st_cb_readpixels.c) instead of a direct map of the
> window-system resource, which is what changes on this board. G52/G57 keep
> their Fail expectation pending a pipeline run: <result>."

**SF2 — the staging-alloc hazard is still reachable via NULL-pixels
`glTexSubImage`.** The guard sits in `st_TexImage`
(`st_cb_texture.c:2444`), but the full-size staging resource is created
inside `st_TexSubImage` at `st_cb_texture.c:2323` *before* its NULL check
(2329-2336), and Mesa does not reject NULL-pixels TexSubImage without a PBO
(`main/teximage.c:3787` calls down unconditionally). A direct
`glTexSubImage2D(..., NULL)` on a max-size texture still hits the same
panfrost abort. Proposed fix — hoist the early-out so both entry points are
covered:

```c
@@ st_TexSubImage, after st_invalidate_readpix_cache(st);
+   /* No client data and no unpack PBO: nothing to upload (NULL is only
+    * meaningful as an offset into a PBO). Return before allocating a
+    * full-size staging resource on the blit path.
+    */
+   if (!pixels && !unpack->BufferObj)
+      return;
```

Equivalence verified: the memcpy path requires `pixels`, the PBO path
requires `BufferObj`, the fallback no-ops on NULL; only throttle accounting
and cache flushes are skipped, neither observable for a no-op upload. The
`st_TexImage` guard then becomes redundant but harmless.

**SF3 — the two `arch >= 6` gates are independent literals.** The opt-in
(`pan_context.c:1214`) and the cap (`pan_screen.c:833-834`) live in
different commits and files. Series order is bisection-safe (flag lands
before cap) and the comments cross-reference — but a partial revert of the
opt-in alone would leave BLIT transfers on with lossy TXF coordinates.
Proposed shared predicate:

```c
/* TXF blit coordinates are only bit-exact when gl_FragCoord comes from the
 * rasterizer's integer pixel index (Bifrost+). Both the u_blitter fragcoord
 * opt-in and blit-based texture transfers must gate on this together. */
static inline bool panfrost_has_exact_blit_coords(unsigned arch) { return arch >= 6; }
```

### Nits

- Unwrapped commit bodies: `87d458819b0` (403-char line) and `8875a22856d`
  (241-char line); rewrap at ~72 on the next rebase.
- The retained `Reviewed-by: Erik Faye-Lund` on the modified cherry-pick was
  given for the unconditional version in !38433; the `[Yi: ...]` note
  discloses the change, but expect a reviewer to ask — consider pinging for
  a re-ack.
- `8875a22856d` message cites "the first rerun" with no job link or
  mechanism (folded into SF1's proposed wording).
- **Stale MR-description gap:** "multi-layer array + 3D blits remain on the
  lossy path" is outdated for this revision — current `u_blitter` covers
  1D/2D/RECT, arrays, and 3D (per-layer draws with the layer in the constant
  attribute); only MSAA and never-TXF cubes are excluded. Remove the
  disclosure from the MR description if it is still there.

## !42614 — `panfrost: add a Gallium test for wide blit precision`

**No blockers; the test was verified live in both directions** on the G610
(build `.codex-tmp/build-g610-debug`): `Test(test_unscaled_blit_precision)
= pass` on the fixed path, and with `use_txf_fragcoord` flipped off in gdb,
all seven passes fail with exactly **40884 wrong texels, first at
(6049,0)** — matching the commit message digit-for-digit and the prior
system-Mesa data.

`458eaee08ac` (glsl_type singleton): correct pairing on every create/destroy
failure path, mutex-protected refcount so no panvk double-init hazard,
idiomatic (seven other gallium drivers hold screen-lifetime refs), and
pan_screen is the right place because `GALLIUM_TESTS` runs at screen
creation before any frontend initializes the singleton.

### Findings

**M1 (wording — review-blocking given the reviewer dispute):** the commit
message and the code comment at `u_tests.c:1098-1100` assert "~2^-10
relative" Mali interpolation error "for x > ~1000" and a plane-equation
reciprocal mechanism. Contradicted by the width-dependence data (pow2
widths bit-exact, smallest failing width 2080, sparse/non-monotone below
~4300). Proposed message wording:

> "Measured on Mali-G610, varying interpolation drifts by up to ~2^-10
> (relative) at certain non-power-of-two widths — power-of-two widths are
> bit-exact, and the smallest observed failing width is 2080 — enough for
> TXF truncation to fetch a neighboring texel in wide blits. A Vulkan probe
> on the same hardware reproduces the drift with no u_blitter involved."

and for the code comment: "(observed on Mali-G610, up to ~2^-10 relative at
certain non-power-of-two widths) fetches neighboring texels in wide blits".

**L1 (missing provenance comment):** `#define WIDE_BLIT_WIDTH 16307`
(`u_tests.c:1112`) has no in-code why-this-number. It is load-bearing twice
over: in the reliably-drifting regime on G610, *and* under the 16384 cap so
llvmpipe/softpipe run the test instead of skipping (they pass for the right
reason — the test verifies output correctness, it does not require the
bug). Someone "rounding it up" to 16384 would make the test silently pass on
the unfixed path. Proposed comment:

```c
/* 16307 is the dEQP readback width that exposed the bug, verified to drift
 * on Mali-G610; the drift is width-dependent and power-of-two widths
 * (4096/8192/16384) are bit-exact there, so they would silently pass. Keep
 * the width under 16384 so 16K-limit drivers (llvmpipe, softpipe) run the
 * test instead of skipping. */
```

**L2 (robustness):** `wide_blit_create_tex` results are never NULL-checked
and there is no `max_texture_array_layers >= 2` guard; a driver passing the
2D guards but failing array allocation would crash in `pipe_texture_map`.
Nit-level (consistent with existing u_tests style); a
`if (!src || !dst) { util_report_result(SKIP); goto out; }` is cheap.

**Info:** (a) `GALLIUM_TESTS=1` on panfrost still aborts *after* the new
test in the pre-existing `util_test_constant_buffer` assert
(`pan_cmdstream.c:1633`, resource-backed const buffers) — `458eaee08ac`'s
"so the gallium unit tests can run" slightly oversells; worth one sentence
in the MR. (b) `GALLIUM_TESTS` is referenced nowhere in `.gitlab-ci/` — the
u_tests are not wired into upstream CI, so there is no automatic sw-driver
coverage (and no CI-breakage risk on other drivers either).

## Stack-wide findings

- **Duplicated u_blitter commit — no drift, fragile topology.**
  `6509025064f` (!42679) and `da88f416453` (embedded in !42613/!42614) have
  identical patch-id (`05b1a5b76cf`) and byte-identical messages. But
  !42679's branch is *not* an ancestor of !42613's — both branch off the
  same base, and !42613 embeds a re-created copy. Identical patch-ids mean
  rebases auto-drop the duplicate, but any future edit to the u_blitter
  commit must be made in both places or they drift. Recommend regenerating
  !42613 from !42679's tip at the next natural update so the four branches
  form a true ancestry chain (!42563 is already the identical hash at the
  bottom of !42613/!42614, and !42613 is a true ancestor of !42614).
- **Rebase health: clean.** All four tips share merge-base `114e6ef02d3`
  (~250 commits behind origin/main as of 2026-07-06); `git merge-tree
  --write-tree` against origin/main reports zero conflicts for all four.
  Zero upstream churn on the stack's source files since the base. Only
  `panfrost-g610-fails.txt` changed upstream (Piglit uprev `19b72005ca2`
  removing an unrelated OpenCL line) — no textual conflict, but re-validate
  the CI expectations against the new Piglit after the next rebase; test
  outcomes, not text, are the risk.
- **Trailer hygiene.** No leftover `Co-Authored-By`; Joshua Watt's
  authorship, S-o-b and R-b preserved with the local change disclosed in a
  bracket note. 7 of 8 commits carry `Assisted-by:` trailers (Codex, Claude
  Code) — if the earlier Co-Authored-By drop was meant to remove AI
  attribution entirely, strip these in one reword pass; if `Assisted-by:` is
  the deliberate convention, no action.

## What this changes in the knowledge base

- The "multi-layer array + 3D blits remain lossy" limitation recorded in the
  2026-07-01 ledger rows is obsolete for the current stack revision (see
  !42613 nits); the canonical coverage statement is now "all non-cube
  sampled targets, single-sample".
- The root-cause wording used in the MR commit messages predates the
  [tiny/vk probe evidence](../reproducers/interp_probe/README.md) and needs the S2/M1
  rewording at the next force-push; the docs here already carry the hedged
  version ([`blit-precision.md`](./blit-precision.md)).
