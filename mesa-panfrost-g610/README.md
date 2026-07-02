# Mesa/Panfrost Notes For Mali-G610

This folder is the **canonical home** for the Mesa-side information learned
while debugging ROCK 5B readback performance and Panfrost texture-transfer
enablement on Mali-G610 MC4. The GNOME Remote Desktop side keeps only a
one-page summary
([`../gnome-remote-desktop/docs/mesa-panfrost-transfer.md`](../gnome-remote-desktop/docs/mesa-panfrost-transfer.md));
every shared figure, asm listing, and validation result is owned here.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Understand the Mesa/Panfrost part of the board-support story, especially why hardware encode matters more than making GRD's software readback path less slow. |
| Developer focus | Preserve the Mali-G610 transfer investigation: BLIT precision failure, COMPUTE correctness, AFBC limitation, benchmark results, dEQP validation, and reproducible probes. |
| Owns | [`blit-precision.md`](./docs/blit-precision.md), [`validation.md`](./docs/validation.md), [`texture-query-levels.md`](./docs/texture-query-levels.md), and [`reproducers/`](reproducers/README.md). |
| Depends on | Local Mesa/Panfrost worktrees and the GRD profiling context that exposed the readback cost. |
| Current state | The COMPUTE-only direction was rejected upstream (cannot write AFBC). On-device verification 2026-07-01 then **disqualified the targeted integer fallback** (the drift also corrupts non-integer format changes — `repro_blit_float.c`) and **selected the `gl_FragCoord` u_blitter fix** (`panfrost-transfer-fragcoord-blit`, `2f6e8a6afcc`) as the upstream direction. See [`../status.md`](../status.md). |

Hardware and software used for the local investigation:

- Radxa ROCK 5B / RK3588
- Mali-G610 MC4
- Mesa 26.2-devel local builds (`/home/yi/Code/mesa`, remote
  `github.com/yisding/mesa`; upstream-baseline worktree pinned at
  `0983c72a7ed`, 2026-06-29)
- Panfrost/Panthor on the OpenGL ES path
- dEQP GLES3 with surfaceless pbuffer (exact invocation:
  [`validation.md` § dEQP Invocation](./docs/validation.md))

## Folder Map

| File | One-liner |
|---|---|
| [`blit-precision.md`](./docs/blit-precision.md) | Root cause: why sampled-BLIT transfers are not bit-exact on G610 (`LD_VAR_IMM` ~2^-10 drift), everything ruled out, the options grid, and the AFBC constraint on COMPUTE |
| [`validation.md`](./docs/validation.md) | What was tested for MR !42563: patch shapes, BLIT-vs-COMPUTE timings, GRD readback timings, dEQP reruns, exact dEQP invocation, build checks |
| [`texture-query-levels.md`](./docs/texture-query-levels.md) | Separate work product on the same branch: `textureQueryLevels()` for Valhall + the texture-descriptor layout facts (LD_PKA, table 62, word2 lod_count field) |
| [`reproducers/`](reproducers/) | Standalone GBM/EGL C probes + benchmark; see [`reproducers/README.md`](reproducers/README.md) |
| [`reproducers/0001-panfrost-advertise-transfer-blit-and-compute.patch`](reproducers/0001-panfrost-advertise-transfer-blit-and-compute.patch) | Archived `format-patch` of the BLIT-advertising commit — the only way to rebuild the failing BLIT configuration once upstream ships a non-BLIT default; reproduction-only, not for merging |

## Status (verified 2026-07-01 against the local Mesa tree)

Mesa MR
[!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563)
("panfrost: enable compute-based texture transfers") lifecycle:

| Date | Event |
|---|---|
| 2025-11-13 | Joshua Watt authors the transfer-mode enablement (BLIT) in MR [!38433](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/38433) (`03184158582`, Reviewed-by Erik Faye-Lund). All local transfer work is based on it. Not yet on upstream main as of `0983c72a7ed` (2026-06-29). |
| 2026-06-30 | Local retest of the BLIT path on G610 finds the integer-readback corruption; root cause isolated to varying interpolation ([`blit-precision.md`](./docs/blit-precision.md)). Local commits: mask fix + BLIT enable (`950d19686d8` + `e8cf2ae6daa`). |
| 2026-07-01 | MR direction switched to COMPUTE-only; rebased series `37ce0f3111d` (mask fix, now carrying `Reviewed-by: Iago Toral Quiroga`) + `9d7f561cd9d` (COMPUTE cap + `is_compute_copy_faster`, benchmark numbers in the commit message) on branch `panfrost-transfer-blit-update`. |
| 2026-07-01 | **Maintainer review rejects COMPUTE-only**: "Compute isn't the right solution. We can't write AFBC that way." The objection is correct — Panfrost cannot write AFBC payloads from shaders; see [`blit-precision.md` § The AFBC Constraint](./docs/blit-precision.md). |
| 2026-07-01 | Remaining viable directions staged as local branches: `panfrost-transfer-fragcoord-blit` (fix the sampled blit's coordinate via `gl_FragCoord` + blit affine; rebased to `2f6e8a6afcc` "u_blitter: use fragment position for unscaled TXF blits", opt-in `use_txf_fragcoord` flag) and `panfrost-transfer-targeted-fallback` (rebased to `6a292503585`: keep BLIT, route pure-integer format-changing transfers away from the blit in `st_cb_readpixels.c`/`st_cb_texture.c`). |
| 2026-07-01 | **On-device verification selects the fragcoord branch** ([`blit-precision.md` § On-Device Verification](./docs/blit-precision.md)): (1) `repro_blit_float.c` (`RG32F -> RGBA32F` readback) corrupts 96.1% on the targeted-fallback build — its pure-integer gate is under-inclusive, **disqualifying B1**; (2) `probe_const.c` shows constant smooth varyings are bit-exact at every magnitude, clearing the fragcoord branch's scale/offset-through-varying design risk; (3) `repro_blit_off.c` shows subregion readbacks exact at offsets up to 16000; (4) `repro_afbc.c` finds **no pre-existing corruption** in shipped drivers via the AFBC CPU-map staging path. |
| 2026-07-01 | MR discussions re-checked from the board via authenticated `glab api` (web UI remains bot-blocked; unauthenticated API returns 401 on notes). Both MRs still open. Reviewer asks to fold into the next series: add kusma's `Fixes: 72ff66c3d73` tag to the unbind fix (already R-b Iago), cherry-pick Joshua Watt's enablement commit for author credit, and validate the dEQP/CTS list from Iago's comment. Suggested MR shape: (1) unbind fix, (2) `u_blitter` fragcoord fix with probe evidence, (3) cherry-picked BLIT enablement + `use_txf_fragcoord` one-liner. Known gap to disclose: wide (>~1250 px) TXF blits of *array* textures stay on the lossy path (gate is 1D/2D/RECT); constants-exact + scale=+-1 make an array extension a feasible follow-up. |
| 2026-07-01 | **MR branch rebuilt locally as the fragcoord series** (local `panfrost-transfer-blit-update`, tip `7fedfca1204` (messages finalized: patch 3 documents the shipped-driver `glBlitFramebuffer` corruption; Co-Authored-By trailers dropped; tree byte-identical to validated `993410a8f25`), **not yet pushed** to `yding:panfrost-transfer-blit`): (1) unbind fix (R-b Iago, Fixes tag), (2) `u_blitter: use fragment position for unscaled TXF blits`, (3) `panfrost: use fragment position for blitter TXF coordinates`, (4) cherry-picked Joshua Watt `panfrost: Enable hardware texture conversion` (authorship preserved, per-kusma), (5) `panfrost: hold a glsl_type singleton reference` (GALLIUM_TESTS crashed in `glsl_array_type` otherwise), (6) `u_tests: add a wide unscaled format-changing blit test` (16307x4, unflipped+flipped; proven: fail on unfixed path with 40884 wrong texels, pass on fixed). Testing surfaced and fixed a real bug: flipped blits broke under panfrost's integer pixel-center position convention; final shader computes `src = floor(pos)*scale + (offset + 0.5*scale)`. New root-cause refinement: drift only for **non-power-of-two** primitive extents (8192/16384 exact; 5000..16307 non-pow2 drift). Full probe battery green; perf unchanged (16307x1 ~0.179 ms, 4096x1024 ~71 ms A/B-equal vs old branch). Known separate issue: `util_test_constant_buffer` asserts in `panfrost_emit_const_buf` (pre-existing, resource-backed const buffers). |

| 2026-07-01 | **Array-layer readback regression found and fixed; final series tip `2e50c2622aa` (7 commits)**. `repro_blit_array.c` showed wide non-pow2 ReadPixels from a 2D-array layer corrupt (15672/16307) with BLIT transfers on, vs exact CPU path before — a regression no dEQP/piglit case covers. Fixed by new commit `u_blitter: blit single array layers through a layer view with use_txf_fragcoord` (single-layer array blits sample a 1D/2D view of the layer, `pipe_caps.sampler_view_target`-gated); probe now 0/16307. u_tests gained an array-layer pass. dEQP rerun on the final series: **zero failures** (MR-comment list 24/25 + known pre-existing `acos` QualityWarning; `fbo.blit.*` 629/641 + 12 NotSupported; `pbo.*` 54/54; `fbo.color.tex2darray.*` 36/36; earlier full battery: `cases2` 16/16, `precision.abs` 24/24, `basic_teximage2d` 98/98). Scissored wide blits exact (`repro_blit_scissor.c`). Remaining disclosed limitation: multi-layer array + 3D blits keep the old lossy path. Piglit still unrun locally. |

| 2026-07-01 | **Fragcoord mechanism generalized to arrays and 3D; MSAA bug found and fixed; final tip `628e599172c` (6 commits)**. Extending array support exposed that the earlier revision's draw-side gate did not exclude MSAA sources — every MSAA resolve was corrupted (`fbo.msaa.*` **62/70 Fail** -> 0 Fail after gating on `nr_samples <= 1`). Final mechanism covers 1D/2D/RECT + 1D/2D arrays (single- and multi-layer) + 3D via a sign-bits/layer/offsets attribute (all per-draw constants, bit-exact through the interpolator); the interim single-layer-view commit was dropped as superseded. Final dEQP matrix: **zero failures across 1097 tests** (incl. fbo.msaa 66/70+4 NS, fbo.color.tex2darray 36/36, fbo.color.tex3d 36/36, basic_teximage3d 98/98). u_tests case has seven checks; negative control fails all seven (per-pass sensitivity proven; 3D render targets confirmed working on panfrost). Probes and perf unchanged. |

| 2026-07-01 | **Pushed as a three-MR stack**: [!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563) reduced + retitled to the already-reviewed unbind fix (`833101f35ed`, force-pushed to `yding:panfrost-transfer-blit`); [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613) "panfrost: enable blit-based texture transfers" = u_blitter fragcoord fix + panfrost opt-in + Joshua Watt's enablement (tip `51cb29834d1`, `yding:panfrost-blit-transfers`, depends on !42563); [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614) "u_tests: add a wide unscaled format-changing blit test" = glsl_type singleton + test (tip `628e599172c`, `yding:panfrost-blit-transfers-test`, depends on !42613). All opened with `allow_collaboration`, label `panfrost`. |

Neither !38433 nor the new stack had merged upstream as of the last check
(2026-07-01, via `glab api`; all `state: opened`).

## Short Version

Panfrost historically advertised no Gallium texture-transfer acceleration:

```c
caps->texture_transfer_modes = 0;
```

For GRD, that meant `glReadPixels` on the software path spent most of a frame
in CPU-side detile/swizzle work. `MESA_COMPUTE_PBO=1` proved that moving that
work to the GPU helped: the 1080p `GL_BGRA` readback benchmark went from about
19.9 ms to about 11.0 ms.

The original upstream direction (!38433) was to enable the sampled BLIT
transfer path, but local testing on Mali-G610 found that BLIT is not bit-exact
for some integer format-changing transfers. The problematic path is:

1. Mesa state tracker expands an integer renderbuffer/readback through a
   staging resource.
2. `u_blitter` emits a fragment shader that reads interpolated texture
   coordinates.
3. The shader truncates those coordinates and performs `TEX_FETCH`/TXF.
4. Mali-G610's `LD_VAR_IMM` varying interpolation drifts by about `2^-10`.
5. Truncation turns that coordinate drift into wrong texel selection.

The exact key instruction sequence from the generated blit fragment shader
(captured with `BIFROST_MESA_DEBUG=shaders` — see
[`blit-precision.md` § How The Disassembly Was Captured](./docs/blit-precision.md)):

```asm
LD_VAR_IMM.slot0.v4.f32.center.store.wait0 @r0:r1:r2:r3, r61^, table:0x1, index:0x0
F32_TO_S32.rtz.discard r2, r3^
F32_TO_S32.rtz r1, r1^
F32_TO_S32.rtz r0, r0^
TEX_FETCH.slot1.reserved.32.2d.texel_offset.wait0126 @r0:r1:r2:r3, @r0:r1:r2, [r4^:r5^]
```

The compiler did not obviously choose the wrong operation. The generated code
loads an interpolated f32 coordinate, truncates it, then does a texel fetch.
The problem is that the interpolation result is not precise enough for an
integer texel address.

The MR's second direction was:

```c
caps->texture_transfer_modes = PIPE_TEXTURE_TRANSFER_COMPUTE;
```

COMPUTE avoids the varying unit entirely by using integer invocation
coordinates, and on the measured G610 cases it was also slightly faster than
BLIT. It fixes correctness — but it is **not the final upstream answer**: a
blanket COMPUTE preference cannot write AFBC destinations (maintainer
rejection, 2026-07-01; see Status above and the AFBC section of
[`blit-precision.md`](./docs/blit-precision.md)). The surviving candidates keep BLIT
and either fix its coordinate source (`gl_FragCoord`) or route only the risky
integer format-changing cases elsewhere.

## Key Facts To Carry Forward

This list is a **summary**; the canonical, evidence-carrying copies live in
[`blit-precision.md`](./docs/blit-precision.md) and [`validation.md`](./docs/validation.md).

- The failure is specific to sampled BLIT paths that need an exact integer
  texel coordinate after interpolation and truncation.
- The failing dEQP symptom was in shader precision tests, but the shader math
  was not the underlying bug. The precision tests happened to read back a very
  wide one-row integer buffer through a format-changing blit.
- The important repro size was `W=16307`; BLIT returned wrong texels for
  `15672 / 16307` samples.
- Example drift: `i=1024` sampled texel `1023`; `i=8192` sampled `8185`;
  `i=16306` sampled `16293`.
- `gl_FragCoord.x` was exact in the same probe: `0 / 16307` floor mismatches.
  (Both counts re-verified on the board 2026-07-01 — see
  [`reproducers/README.md`](reproducers/README.md).)
- `noperspective` is not an exact escape on Mali-G610; Panfrost lowers it
  through the same perspective machinery
  (`pan_nir_lower_noperspective.c`), and GLSL ES rejects the qualifier
  outright, so it is not even reachable from the ES reproducers.
- A derivative-based reconstruction was worse: `16187 / 16307` mismatches;
  `gl_FragCoord.w` is exactly 1.0 and carries no correction term.
- `PAN_MESA_DEBUG=nofp16` did not matter; the issue is not ordinary fp16 ALU
  lowering.
- `PAN_MESA_DEBUG=linear`, `PAN_MESA_DEBUG=sync`, `ST_DEBUG=noreadpixcache`,
  single-triangle blits, and TXF toggles did not make BLIT correct.
- Compute transfer avoids `LD_VAR_IMM`, uses integer invocation IDs, and fixed
  the readback/precision failures in local testing — but compute cannot write
  AFBC, so COMPUTE-only was rejected upstream as the general fix.
- The drift is **format-agnostic**: a wide `RG32F -> RGBA32F` float readback
  corrupts identically (96.1%, first mismatch at x=623). Integer formats were
  only where dEQP could detect it bit-exactly. This is what disqualified the
  "avoid blit only for pure-integer format changes" workaround
  (`repro_blit_float.c`, 2026-07-01).
- A smooth varying that is **constant across the primitive** interpolates
  **bit-exactly** at every magnitude tested (1.0 … 16306.5) — only varyings
  that actually vary accumulate the ~2^-10 error (`probe_const.c`,
  2026-07-01). This is why the fragcoord fix can pass the blit
  `scale`/`offset` through an ordinary attribute.
- The fragcoord branch is verified exact for subregion readbacks with source
  offsets up to 16000 (`repro_blit_off.c`, 2026-07-01).
- Shipped drivers **are** corrupted via direct wide non-pow2 unscaled
  blits: plain `glBlitFramebuffer` of 16307x2 RG32UI on Mesa 26.0.3 returns
  29498/32614 wrong texels in all four orientations (`repro_blit_flip.c`).
  The AFBC CPU-map staging-blit path, by contrast, is clean
  (`repro_afbc.c`). So the series is a bugfix for an already-reachable path
  plus the `PIPE_TEXTURE_TRANSFER_BLIT` enabler; exposure is narrow (drift
  onset 3000-5000 px, pow2 extents exact), which is why it went unreported.
- Panfrost's own FB preload shaders already use the exact pixel index
  (`nir_load_pixel_coord`, `pan_fb_nir.c`) instead of varyings — internal
  precedent for the fragcoord approach.
- The only remaining dEQP warning in the MR rerun was
  `dEQP-GLES3.functional.shaders.builtin_functions.precision.acos.mediump_fragment.vec2`,
  and it reproduced in a clean run, so it was not introduced by the transfer
  change.

## Relation To The GRD Work

The GRD software path is slow because it has to bring the captured frame back
to CPU memory for software RFX encoding. A GPU-side transfer path makes that
software fallback less bad by moving detile/swizzle work to the GPU. It does
not change the larger conclusion of this repo: hardware encode is the real fix
because it removes the GPU-to-CPU readback from the hot path.

The GRD-facing summary is
[`../gnome-remote-desktop/docs/mesa-panfrost-transfer.md`](../gnome-remote-desktop/docs/mesa-panfrost-transfer.md);
the benchmark that produced the 19.92 ms → 11.01 ms readback numbers is
[`../gnome-remote-desktop/bench/`](../gnome-remote-desktop/bench/).
