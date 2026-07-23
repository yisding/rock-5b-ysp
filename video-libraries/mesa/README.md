# video-libraries/mesa/ — Mali-G610 Mesa/Panfrost transfer investigation

Project vocabulary: [`keywords.md`](keywords.md).


This folder is the **canonical home** for the Mesa-side information learned
while debugging ROCK 5B readback performance and Panfrost texture-transfer
enablement on Mali-G610 MC4. The GNOME Remote Desktop side keeps only a
one-page summary
([`apps/gnome-remote-desktop/docs/mesa-panfrost-transfer.md`](../../apps/gnome-remote-desktop/docs/mesa-panfrost-transfer.md));
every shared figure, asm listing, and validation result is owned here.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Understand the Mesa/Panfrost part of the board-support story, especially why hardware encode matters more than making GRD's software readback path less slow. |
| Developer focus | Preserve the Mali-G610 transfer investigation: BLIT precision failure, COMPUTE correctness, AFBC limitation, benchmark results, dEQP validation, and reproducible probes. |
| Owns | [`blit-precision.md`](./docs/blit-precision.md), [`validation.md`](./docs/validation.md), [`texture-query-levels.md`](./docs/texture-query-levels.md), and [`reproducers/`](reproducers/README.md). |
| Depends on | Local Mesa/Panfrost worktrees and the GRD profiling context that exposed the readback cost. |
| Current state | The `gl_FragCoord` u_blitter fix is upstream as the open 4-MR stack !42563 / !42679 / !42613 / !42614. The 2026-07-11 GitLab check found tips and pipelines unchanged and selected CI evidence still green; !42679 reported `need_rebase`. On 2026-07-22 a maintainer confirmed the varying failure is a hardware erratum and supplied a zero-valued depth-bias workaround, now verified for OpenGL and Vulkan raw varyings plus OpenGL ordinary TEX. See the [dated finding](../../findings/2026-07-22-mali-varying-depth-bias-erratum-workaround.md) and [`status.md`](../../status.md). |

Hardware and software used for the local investigation:

- Radxa ROCK 5B / RK3588
- Mali-G610 MC4
- Mesa 26.2-devel local builds (`/home/yi/Code/fdo/mesa`, remote
  `github.com/yisding/mesa`; upstream-baseline worktree pinned at
  `0983c72a7ed`, 2026-06-29)
- Panfrost/Panthor on the OpenGL ES path
- dEQP GLES3 with surfaceless pbuffer (exact invocation:
  [`validation.md` § dEQP Invocation](./docs/validation.md))

## Files

| Path | One-liner |
|---|---|
| [`docs/fix-walkthrough.md`](./docs/fix-walkthrough.md) | Start here if new to Mesa/C: from-first-principles explainer of the whole series — blits, TXF, varying interpolation, the `gl_FragCoord` fix, each of the four MRs, and why COMPUTE/CPU were rejected |
| [`docs/blit-precision.md`](./docs/blit-precision.md) | Erratum investigation: the measured `LD_VAR_IMM` drift signature, the 2026-07-22 corrected attribution and depth-bias workaround, everything ruled out, the options grid, and the AFBC constraint on COMPUTE |
| [`docs/arm-mali-blob-stack.md`](./docs/arm-mali-blob-stack.md) | Proprietary RK3588/G610 libmali userspace notes: package metadata, GBM/EGL/Vulkan wrapper model, inspected blob hashes, surfaceless extension strings, and runtime verification checklist |
| [`docs/validation.md`](./docs/validation.md) | What was tested: patch shapes, BLIT-vs-COMPUTE timings, GRD readback timings, dEQP reruns, exact dEQP invocation, build checks |
| [`docs/rebuild-and-test.md`](./docs/rebuild-and-test.md) | On-device rebuild + revalidation log: how to drive `scripts/`, the environment gotchas (wiped `/tmp` build state, `mise` python shadowing, glvnd for piglit), and the latest reproducer/dEQP/piglit results |
| [`docs/mr-review-findings.md`](./docs/mr-review-findings.md) | 2026-07-06 structured review of the four open MRs: verdicts (no blockers), should-fix list with proposed patches (G52/G57 expectations, `st_TexSubImage` guard hoist, gate-sync helper, root-cause rewording), live u_test verification both directions, and the stack-topology/rebase-health audit |
| [`docs/texture-query-levels.md`](./docs/texture-query-levels.md) | Separate work product on the same branch: `textureQueryLevels()` for Valhall + the texture-descriptor layout facts (LD_PKA, table 62, word2 lod_count field) |
| [`scripts/`](scripts/README.md) | Rebuild + test entry point: surfaceless Mesa build, runtime env, and the reproducer / dEQP / piglit runners; see [`scripts/README.md`](scripts/README.md) |
| [`reproducers/`](reproducers/README.md) | Texture-transfer reproducers, transfer benchmark, archived BLIT-advertising patch, and the focused [`reproducers/interp_probe/`](reproducers/interp_probe/README.md) raw-varying plus ordinary-TEX proof set |
| [`video-libraries/mesa/patches/0001-panfrost-advertise-transfer-blit-and-compute.patch`](patches/0001-panfrost-advertise-transfer-blit-and-compute.patch) | Archived `format-patch` of the BLIT-advertising commit — the only way to rebuild the failing BLIT configuration once upstream ships a non-BLIT default; reproduction-only, not for merging |

<a id="mr-status"></a>

## Status (last live-state check 2026-07-11; technical validation remains dated below)

Current upstream stack:

| MR | Branch / tip | Contents | CI status at last check |
|---|---|---|---|
| [!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563) `panfrost: clear shader image mask on trailing unbinds` | `panfrost-transfer-blit` / `833101f35ed` | Independent Panfrost shader-image unbind bugfix; carries `Reviewed-by: Iago Toral Quiroga` and `Fixes: 72ff66c3d73`. | Pipeline 1697832: selected x86/arm64 build and G610 GL/piglit jobs green. |
| [!42679](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42679) `u_blitter: use fragment position for unscaled TXF blits` | `u-blitter-txf-fragcoord` / `6509025064f` | Shared `u_blitter` opt-in: use `gl_FragCoord` plus the blit affine for single-sample unscaled TXF blits; excludes MSAA, cube, pack, and override-shader paths. | Pipeline 1700107: selected x86 build, clang, llvmpipe, and softpipe jobs green. ARM hardware is intentionally not the useful signal here because the flag defaults off until Panfrost opts in. |
| [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613) `panfrost: enable blit-based texture transfers` | `panfrost-blit-transfers` / `8875a22856d` | Reviewed !42563 unbind prerequisite, !42679 u_blitter fix, `9600bae512d` Panfrost opt-in (`use_txf_fragcoord = arch >= 6`), `87d458819b0` `st_TexImage` allocation-only guard, Joshua Watt's `a9d6caeeb53` `PIPE_TEXTURE_TRANSFER_BLIT` enablement, and `8875a22856d` G610 expectation cleanup for `glx-copy-sub-buffer`. | First pipeline 1700108 was red for classified reasons; pipeline 1700150 got the crash/assert roots green but exposed the stale `glx-copy-sub-buffer` expectation; force-pushed again and rerun pipeline 1700162 passed all four selected G610 shards. |
| [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614) `panfrost: add a Gallium test for wide blit precision` | `panfrost-blit-transfers-test` / `4c23f1db1f9` | Corrected !42613 stack plus `458eaee08ac` Panfrost `glsl_type` singleton lifetime for Gallium tests and `4c23f1db1f9` wide non-pow2 unscaled format-changing blit u_test. Depends on !42613 because the test only exercises the fixed path on Panfrost after the driver opt-in. | First pipeline 1700109 inherited the !42613 failures; pipeline 1700149 was superseded by the expectation cleanup; rerun pipeline 1700163 passed all four selected G610 shards. |

Follow-up branches exist for the separate no-zero-sized-blit constraint, but
no MRs have been opened for them yet:

| Branch | Tip | Scope |
|---|---|---|
| `zero-sized-blits-gallium` | `d8cf9625ba5` `mesa,dri: skip zero-sized blits before Gallium` | Skips empty GL/DRI copy rectangles in `dri2_blit_image`, `glCopyImageSubData`, and `glCopyTexSubImage*` before constructing Gallium blits. |
| `zero-sized-blits-lavapipe` | `740be57319d` `lavapipe: skip zero-sized image blit and resolve regions` | Skips empty Vulkan blit/resolve regions before lavapipe builds `pipe_blit_info` for llvmpipe/softpipe. |

Two review-driven clarifications matter for future edits:

- A zero-sized blit is a valid API no-op in places like `glCopyImageSubData`,
  but it is not useful work for `u_blitter`; no fragments are rasterized, so the
  right invariant is that empty boxes are skipped before Gallium render blits.
- `PIPE_BUFFER` can appear in Mesa texture/buffer-object code, but it cannot
  reach this `u_blitter` render-blit TXF path. Buffer copies go through buffer
  copy/resource paths, not through a sampled render blit to a pipe surface, so
  `blitter_target_supports_txf()` intentionally only reasons about texture
  targets and cube exclusion.

The transfer series lifecycle (MR
[!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563) began
as the COMPUTE experiment and is now the reviewed unbind bugfix; the shared
`gl_FragCoord` fix later moved to !42679):

| Date | Event |
|---|---|
| 2025-11-13 | Joshua Watt authors the transfer-mode enablement (BLIT) in MR [!38433](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/38433) (`03184158582`, Reviewed-by Erik Faye-Lund). All local transfer work is based on it. Not yet on upstream main as of `0983c72a7ed` (2026-06-29). |
| 2026-06-30 | Local retest of the BLIT path on G610 finds the integer-readback corruption; root cause isolated to varying interpolation ([`blit-precision.md`](./docs/blit-precision.md)). Local commits: mask fix + BLIT enable (`950d19686d8` + `e8cf2ae6daa`). |
| 2026-07-01 | MR direction switched to COMPUTE-only; rebased series `37ce0f3111d` (mask fix, now carrying `Reviewed-by: Iago Toral Quiroga`) + `9d7f561cd9d` (COMPUTE cap + `is_compute_copy_faster`, benchmark numbers in the commit message) on branch `panfrost-transfer-blit-update`. |
| 2026-07-01 | **Maintainer review rejects COMPUTE-only**: "Compute isn't the right solution. We can't write AFBC that way." The objection is correct — Panfrost cannot write AFBC payloads from shaders; see [`blit-precision.md` § The AFBC Constraint](./docs/blit-precision.md). |
| 2026-07-01 | Remaining viable directions staged as local branches: `panfrost-transfer-fragcoord-blit` (fix the sampled blit's coordinate via `gl_FragCoord` + blit affine; rebased to `2f6e8a6afcc` "u_blitter: use fragment position for unscaled TXF blits", opt-in `use_txf_fragcoord` flag) and `panfrost-transfer-targeted-fallback` (rebased to `6a292503585`: keep BLIT, route pure-integer format-changing transfers away from the blit in `st_cb_readpixels.c`/`st_cb_texture.c`). |
| 2026-07-01 | **On-device verification selects the fragcoord branch** ([`blit-precision.md` § On-Device Verification](./docs/blit-precision.md)): (1) `repro_blit_float.c` (`RG32F -> RGBA32F` readback) corrupts 96.1% on the targeted-fallback build — its pure-integer gate is under-inclusive, **disqualifying B1**; (2) `probe_const.c` shows constant smooth varyings are bit-exact at every magnitude, clearing the fragcoord branch's scale/offset-through-varying design risk; (3) `repro_blit_off.c` shows subregion readbacks exact at offsets up to 16000; (4) `repro_afbc.c` finds **no pre-existing corruption** in the system Mesa 26.0.3 driver via the AFBC CPU-map staging path. |
| 2026-07-01 | MR discussions re-checked from the board via authenticated `glab api` (web UI remains bot-blocked; unauthenticated API returns 401 on notes). Both MRs still open. Reviewer asks to fold into the next series: add kusma's `Fixes: 72ff66c3d73` tag to the unbind fix (already R-b Iago), cherry-pick Joshua Watt's enablement commit for author credit, and validate the dEQP/CTS list from Iago's comment. Suggested MR shape: (1) unbind fix, (2) `u_blitter` fragcoord fix with probe evidence, (3) cherry-picked BLIT enablement + `use_txf_fragcoord` one-liner. Known gap to disclose: wide (>~1250 px) TXF blits of *array* textures stay on the lossy path (gate is 1D/2D/RECT); constants-exact + scale=+-1 make an array extension a feasible follow-up. |
| 2026-07-01 | **MR branch rebuilt locally as the fragcoord series** (local `panfrost-transfer-blit-update`, tip `7fedfca1204` (messages finalized: patch 3 documents the system-driver `glBlitFramebuffer` corruption; Co-Authored-By trailers dropped; tree byte-identical to validated `993410a8f25`), **not yet pushed** to `yding:panfrost-transfer-blit`): (1) unbind fix (R-b Iago, Fixes tag), (2) `u_blitter: use fragment position for unscaled TXF blits`, (3) `panfrost: use fragment position for blitter TXF coordinates`, (4) cherry-picked Joshua Watt `panfrost: Enable hardware texture conversion` (authorship preserved, per-kusma), (5) `panfrost: hold a glsl_type singleton reference` (GALLIUM_TESTS crashed in `glsl_array_type` otherwise), (6) `u_tests: add a wide unscaled format-changing blit test` (16307x4, unflipped+flipped; proven: fail on unfixed path with 40884 wrong texels, pass on fixed). Testing surfaced and fixed a real bug: flipped blits broke under panfrost's integer pixel-center position convention; final shader computes `src = floor(pos)*scale + (offset + 0.5*scale)`. New root-cause refinement: drift only for **non-power-of-two** primitive extents (8192/16384 exact; 5000..16307 non-pow2 drift). Full probe battery green; perf unchanged (16307x1 ~0.179 ms, 4096x1024 ~71 ms A/B-equal vs old branch). Known separate issue: `util_test_constant_buffer` asserts in `panfrost_emit_const_buf` (pre-existing, resource-backed const buffers). |

| 2026-07-01 | **Array-layer readback regression found and fixed; final series tip `2e50c2622aa` (7 commits)**. `repro_blit_array.c` showed wide non-pow2 ReadPixels from a 2D-array layer corrupt (15672/16307) with BLIT transfers on, vs exact CPU path before — a regression no dEQP/piglit case covers. Fixed by new commit `u_blitter: blit single array layers through a layer view with use_txf_fragcoord` (single-layer array blits sample a 1D/2D view of the layer, `pipe_caps.sampler_view_target`-gated); probe now 0/16307. u_tests gained an array-layer pass. dEQP rerun on the final series: **zero failures** (MR-comment list 24/25 + known pre-existing `acos` QualityWarning; `fbo.blit.*` 629/641 + 12 NotSupported; `pbo.*` 54/54; `fbo.color.tex2darray.*` 36/36; earlier full battery: `cases2` 16/16, `precision.abs` 24/24, `basic_teximage2d` 98/98). Scissored wide blits exact (`repro_blit_scissor.c`). Remaining disclosed limitation: multi-layer array + 3D blits keep the old lossy path. Piglit still unrun locally. |

| 2026-07-01 | **Fragcoord mechanism generalized to arrays and 3D; MSAA bug found and fixed; final tip `628e599172c` (6 commits)**. Extending array support exposed that the earlier revision's draw-side gate did not exclude MSAA sources — every MSAA resolve was corrupted (`fbo.msaa.*` **62/70 Fail** -> 0 Fail after gating on `nr_samples <= 1`). Final mechanism covers 1D/2D/RECT + 1D/2D arrays (single- and multi-layer) + 3D via a sign-bits/layer/offsets attribute (all per-draw constants, bit-exact through the interpolator); the interim single-layer-view commit was dropped as superseded. Final dEQP matrix: **zero failures across 1097 tests** (incl. fbo.msaa 66/70+4 NS, fbo.color.tex2darray 36/36, fbo.color.tex3d 36/36, basic_teximage3d 98/98). u_tests case has seven checks; negative control fails all seven (per-pass sensitivity proven; 3D render targets confirmed working on panfrost). Probes and perf unchanged. |

| 2026-07-01 | **Pushed as a three-MR stack** (later split to four — see the 2026-07-03 row): [!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563) reduced + retitled to the already-reviewed unbind fix (`833101f35ed`, force-pushed to `yding:panfrost-transfer-blit`); [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613) "panfrost: enable blit-based texture transfers" = u_blitter fragcoord fix + panfrost opt-in + Joshua Watt's enablement (tip `51cb29834d1`, `yding:panfrost-blit-transfers`, depends on !42563); [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614) "u_tests: add a wide unscaled format-changing blit test" = glsl_type singleton + test (tip `628e599172c`, `yding:panfrost-blit-transfers-test`, depends on !42613). All opened with `allow_collaboration`, label `panfrost`. |

| 2026-07-02 | **Structured self-review of !42613 found 3 real bugs + cleanups; series revised and force-pushed** (!42613 tip `51cb29834d1` -> `486b6f7002f`, !42614 tip `628e599172c` -> `e9125bd526f`; revision notes posted on both MRs, !42613 description updated). Bugs: (1) the draw-side fragcoord repacking also fired for ZS<->color pack shaders and `fs_override` shaders that read the attribute raw — the encoding decision now lives in `util_blitter_blit_generic` beside shader selection and is threaded through `do_blits` to the draw; (2) `texture_transfer_modes` was enabled for **Midgard** while the precision fix only engaged on Bifrost+ — both now gate on `arch >= 6` (Midgard's position input rides the same lossy varying unit, so the fragcoord path is unverified there); (3) zero-area `glCopyImageSubData` boxes reached `scale = 0/0 = NaN` and tripped the debug assert. Cleanups: POSITION declared sysval-or-input per `fs_position_is_sysval` (documented flag, no implicit sysval contract); attribute encoding simplified from sign-bits + 6-op integer decode to `scale_x` / `scale_y*(layer+0.25)` with a 2-op decode (SSG + abs); dead `get_texcoords()` work skipped in the fragcoord path; predicate duplication collapsed to the same cube exclusion as `util_blitter_blit_with_txf`. Revalidation on `git-e9125bd526`: full probe battery 0 mismatches (flips 0/130456 across all 4 orientations), u_tests 7/7 checks, `fbo.msaa.*` 66P/4NS/0F, `precision.abs` 24/24, bench 16307x1 ~0.58 ms median (noreadpixcache, matches prior BLIT numbers). **Caveat:** the rebuilt local dEQP (`/tmp/deqp-gles-ci`) now fails 26 `pbo.*` + 34 `fbo.blit.default_framebuffer.*` cases with **zero-pixel image difference vs a negative comparison threshold** (-9.3e-10) — reproduced bit-identically on the unpatched build and on the shipped 26.0.3 driver; failure sets diffed and identical, i.e. a test-harness artifact, not a driver regression. |

| 2026-07-03 | **Reviewer-requested split into a four-MR stack.** The shared `u_blitter` change is shared code across ~10 drivers, so on review it was isolated into its own [!42679](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42679) "u_blitter: use fragment position for unscaled TXF blits". [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613) is correspondingly reduced to the Panfrost-only pieces: the `use_txf_fragcoord = arch >= 6` opt-in plus Joshua Watt's `PIPE_TEXTURE_TRANSFER_BLIT` enablement, both arch-gated together. Final canonical stack: !42563 (unbind bugfix) -> !42679 (shared blitter fragcoord fix) -> !42613 (panfrost opt-in + BLIT enablement, depends on !42679) -> !42614 (u_tests case + glsl_type singleton, depends on !42613). A second `/code-review` round of behaviour-preserving `u_blitter` cleanups landed the same day ([`video-libraries/mesa/patches/u_blitter-review2-txf-fragcoord-cleanups.patch`](patches/u_blitter-review2-txf-fragcoord-cleanups.patch)); MR-by-MR breakdown in [`docs/fix-walkthrough.md` § 6](./docs/fix-walkthrough.md). |
| 2026-07-05 | **Maintainer follow-up on empty blits accepted: do not handle them in `u_blitter`.** The earlier self-review workaround for `0/0` scale in empty `glCopyImageSubData` boxes was removed from !42679. A zero-sized API copy is a no-op, but a zero-sized render blit makes no sense for `u_blitter`, whose fragcoord path now asserts non-empty destination axes. Minimal follow-up branches were built but not MR'd: `zero-sized-blits-gallium` (`d8cf9625ba5`) skips empty GL/DRI copy rectangles before Gallium, and `zero-sized-blits-lavapipe` (`740be57319d`) skips empty Vulkan blit/resolve regions before lavapipe builds `pipe_blit_info`. |
| 2026-07-05 | **`PIPE_BUFFER` was removed from both the TXF-fragcoord predicate and comment.** `PIPE_BUFFER` is a real target in other Mesa paths (TBOs, PBO/SSBO helpers, buffer resources), but not in this `u_blitter` render-blit TXF path: buffer copies route through resource/buffer-copy machinery rather than rendering a sampled blit to a pipe surface. Keeping it in the predicate implied a false upstream expectation. |
| 2026-07-06 | **First targeted Panfrost-enablement G610 pipelines were red.** !42563 selected x86/arm64 build + G610 GL/piglit jobs are green. !42679 selected x86 build + clang + llvmpipe + softpipe jobs are green; no ARM hardware job was selected there because the shared flag defaults off and Panfrost does not exercise the new path until !42613. !42613 shared dependencies were green but all selected G610 GL/piglit shards failed. !42614, stacked on !42613, also had selected G610 failures. The visible failure sets were transfer/readback-heavy: dEQP `packed_pixels.pbo_rectangle.*`, `dEQP-GLES3.functional.pbo.*`, `KHR-GLES31.core.texture_buffer.texture_buffer_operations_framebuffer_readback`, piglit `pbo-getteximage`, `gettextureimage-targets`, `cubemap-getteximage-pbo`, `max-texture-size`, and `large-tex`; several logs also showed `panfrost_resource_setup: Assertion valid failed` or `DRM_IOCTL_PANTHOR_BO_CREATE failed (err=12)`. Manual `glab api` fallback worked for playing jobs after `ci_run_n_monitor.sh` token issues, but it also taught one CI gotcha: if the helper is not doing the cancel step, non-target automatic jobs can fan out after dependencies finish (e.g. freedreno/zink on !42614) and must be canceled explicitly. |
| 2026-07-06 | **G610 red jobs classified after local repro on the board.** The main crash root cause is stack integration, not the `gl_FragCoord` fix itself: pushed `panfrost-blit-transfers` / `panfrost-blit-transfers-test` do not contain `37ce0f3111d` (`panfrost: clear shader image mask on trailing unbinds`); `git branch --contains 37ce0f3111d` only lists older experimental branches. That explains why prior end-to-end testing, including Piglit, could pass: it ran on the earlier fragcoord/targeted branches that still carried the unbind fix, while the later review split lost it from the pushed Panfrost branches. Without the fix, trailing image unbinds clear resources but leave stale `image_mask` bits; the next u_blitter draw can dereference a null image resource in `util_image_to_sampler_view()`. Local proof: `pbo-getteximage -auto` crashed with that backtrace and passed after applying the one-line mask clear. |
| 2026-07-06 | **Second G610 root cause: allocation-only `glTexImage*` still entered the BLIT upload path.** `max-texture-size -auto -fbo` aborts in `panfrost_resource_setup` because `st_TexImage(..., pixels = NULL)` calls `st_TexSubImage`, and the new BLIT transfer path allocates a huge staging texture before finding there is no client data. Local gdb showed a 16384x16384 `PIPE_FORMAT_R32G32B32A32_FLOAT` staging source with `pixels = NULL`. Temporarily disabling Panfrost BLIT transfers makes the exact command pass; guarding the `st_TexSubImage` call with `if (pixels || unpack->BufferObj)` also makes it pass while preserving valid PBO offset-zero uploads. After the image-mask and state-tracker guards, local `pbo-getteximage`, `cubemap-getteximage-pbo`, `arb_direct_state_access-gettextureimage-targets -fbo`, `mesa_pack_invert-readpixels`, `object-namespace-pollution glGetTexImage`, `getteximage-targets RECT -fbo`, and `max-texture-size -fbo` pass. Residuals are now non-crash signals: `large-tex -auto -fbo` reaches a later `#version 420` shader compile despite Panfrost exposing only GL 3.1, and `gl-2.1-pbo -auto -fbo` fails `test_polygon_stip` with a black-vs-white probe mismatch; both need no-BLIT baseline comparison before treating them as MR blockers. |
| 2026-07-06 | **MRs force-pushed with the classified fixes.** !42613 was rebuilt to `a9d6caeeb53` as !42563 -> !42679 -> Panfrost opt-in -> `st/mesa: skip TexSubImage for allocation-only TexImage` -> Joshua Watt's BLIT enablement. !42614 was rebuilt to `60eb35d6ee1` on that corrected stack; its two unique commits are content-unchanged. MR descriptions were updated with the G610 root-cause notes. Local corrected-stack smoke passed `ninja -C .codex-tmp/build-g610-debug`, `pbo-getteximage -auto`, and `max-texture-size -auto -fbo`. Pipeline 1700150 (!42613) later exposed the stale expectation recorded below; pipeline 1700149 (!42614) was superseded before final G610 results. |
| 2026-07-06 | **Rerun exposed one stale G610 expectation, not another transfer crash.** In pipeline 1700150, !42613 had `panfrost-g610-gl` 1/2 and 2/2 green plus `panfrost-g610-piglit` 1/2 green; `panfrost-g610-piglit` 2/2 failed only because `glx@glx-copy-sub-buffer` was still listed in `src/panfrost/ci/panfrost-g610-fails.txt` but passed twice (`UnexpectedImprovement(Pass)`). The transfer/readback crash set was gone from that shard. !42613 was force-pushed again to `8875a22856d` with `panfrost/ci: drop fixed G610 glx-copy-sub-buffer fail`; !42614 was rebuilt to `4c23f1db1f9`. Final selected reruns 1700162 (!42613) and 1700163 (!42614) then passed all four targeted G610 shards on each branch. Manual API job starting still fans out unrelated freedreno/zink/other-ARM jobs after dependencies finish, so those must be canceled when not using the helper's cancel logic. |
| 2026-07-06 | **Structured review of all four open MRs** ([`docs/mr-review-findings.md`](./docs/mr-review-findings.md)): no blockers anywhere; the !42614 u_test was verified live in both directions on the G610 (pass on the fixed path, fail with exactly the commit message's 40884 wrong texels with `use_txf_fragcoord` flipped off in gdb). Should-fix before the next force-push: G52/G57 still carry the `glx@glx-copy-sub-buffer,Fail` expectation the G610 commit drops (UnexpectedPass risk on full pipelines); the allocation-only guard belongs in `st_TexSubImage` (a direct NULL-pixels `glTexSubImage` still reaches the huge staging alloc); the two `arch >= 6` gates should share a predicate; and the commit messages' hardware-mechanism claims need the measurement-first rewording now that the probe evidence contradicts them. Stack topology: the duplicated u_blitter commit has identical patch-ids (no drift) but !42679 is not an ancestor of !42613 — regenerate !42613 from !42679's tip at the next update. `git merge-tree` vs origin/main: zero conflicts, zero upstream churn on the stack's source files. |
| 2026-07-22 | **Maintainer diagnosis and workaround verified across GL and Vulkan.** Kusma confirmed the varying failure as a hardware erratum and identified `GL_POLYGON_OFFSET_FILL` with factor/units zero as a workaround. On G610 it changes Valhall's `depth_bias_enable` descriptor bit without numerically moving depth and makes the raw varying exact at 12288/16307. PanVK's equivalent `depthBiasEnable = VK_TRUE` with all three values zero reaches the same bit and also makes both widths exact (11744/15672 wrong → 0). A normalized-coordinate OpenGL `texture()`/TEX-nearest probe also passes, proving the effect is not specific to f32-to-integer conversion or TXF. Exact hardware internals remain inferred; internal `u_blitter` and PanVK meta draws must install the safe rasterizer state themselves. |

Neither !38433 nor the new stack had merged upstream as of the last check
(2026-07-06, via `glab api`; all `state: opened`).

## Short version

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
4. A confirmed Mali-G610 hardware erratum corrupts varying interpolation at
   some non-power-of-two widths — with a `~2^-10` signature at the widths
   involved here.
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
The problem is that the hardware erratum has already corrupted the
interpolation result before it is used as an integer texel address.

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

## Key facts to carry forward

This list is a **summary**; the canonical, evidence-carrying copies live in
[`blit-precision.md`](./docs/blit-precision.md) and [`validation.md`](./docs/validation.md).

- The original corruption was exposed by a sampled BLIT path needing an exact
  integer texel coordinate, but the underlying hardware erratum is broader:
  the raw varying fails without any texture operation, and normalized
  non-integer coordinates can select wrong texels through ordinary TEX-nearest.
- The failing dEQP symptom was in shader precision tests, but the shader math
  was not the underlying bug. The precision tests happened to read back a very
  wide one-row integer buffer through a format-changing blit.
- The important repro size was `W=16307`; BLIT returned wrong texels for
  `15672 / 16307` samples.
- Example drift: `i=1024` sampled texel `1023`; `i=8192` sampled `8185`;
  `i=16306` sampled `16293`.
- `gl_FragCoord.x` was exact in the same probe: `0 / 16307` floor mismatches.
  (Both counts re-verified on the board 2026-07-01 — see
  [`reproducers/interp_probe/README.md`](reproducers/interp_probe/README.md).)
- The minimal reproducer is `tiny_interp_probe.c` (2026-07-06): pure varying
  interpolation with no u_blitter/texture/TXF/filtering still drifts
  (`12288 x 1`: 11744/12288 wrong, relative error `9.74e-4`), the
  `gl_FragCoord` control is bit-exact, every power-of-two width tested is
  exact, and the error is width-dependent (`2^-12` at 2080, `2^-14` at 16383,
  ~`2^-10` at 12288/16307) — the drift is in the varying path itself, not in
  u_blitter's use of it
  ([`reproducers/interp_probe/README.md`](reproducers/interp_probe/README.md)).
- The maintainer-provided workaround (2026-07-22) enables polygon-offset fill
  with factor/units zero. It makes the raw varying and the new
  `tex_interp_probe.c` ordinary-TEX case exact at 12288 and 16307. Mesa source
  maps that enable to Valhall's `depth_bias_enable` descriptor bit while the
  zero parameters leave depth unchanged; the microarchitectural reason that
  this selects the unaffected path is not public.
- A Vulkan port of the probe (`vk_interp_probe.c`, 2026-07-06) reproduces the
  drift **bit-for-bit on panvk** — Mesa's Vulkan driver for Mali, a stack
  with no Gallium, no u_blitter, and no GL state tracker anywhere
  (11744/12288 bad, first at x=529, last-pixel v=12275.5312 — identical
  numbers to the GL probe). panvk reports Vulkan 1.4 conformance
  (apiVersion 1.4.335), and the same binary passes on llvmpipe, so the
  checker is sound. The "u_blitter misuses varyings" hypothesis is
  untenable: u_blitter does not exist in that stack. The drift also persists
  bit-identically on the corrected !42614 stack — the fix reroutes blit TXF
  coordinates around varyings; it does not repair varying interpolation
  ([`reproducers/interp_probe/README.md`](reproducers/interp_probe/README.md)).
- The Vulkan A/B mode (2026-07-22) confirms the API-equivalent workaround:
  `depthBiasEnable = VK_TRUE` with constant factor, clamp, and slope factor
  zero makes the PanVK varying exact at 12288 and 16307. PanVK maps this state
  to the same Valhall descriptor bit, and both llvmpipe modes pass.
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
  plus the `PIPE_TEXTURE_TRANSFER_BLIT` enabler; exposure is narrow (failing
  widths sparse below ~4300, smallest measured 2080, pow2 extents exact),
  which is why it went unreported.
- Panfrost's own FB preload shaders already use the exact pixel index
  (`nir_load_pixel_coord`, `pan_fb_nir.c`) instead of varyings — internal
  precedent for the fragcoord approach.
- The only remaining dEQP warning in the MR rerun was
  `dEQP-GLES3.functional.shaders.builtin_functions.precision.acos.mediump_fragment.vec2`,
  and it reproduced in a clean run, so it was not introduced by the transfer
  change.

## Relation to the GRD work

The GRD software path is slow because it has to bring the captured frame back
to CPU memory for software RFX encoding. A GPU-side transfer path makes that
software fallback less bad by moving detile/swizzle work to the GPU. It does
not change the larger conclusion of this repo: hardware encode is the real fix
because it removes the GPU-to-CPU readback from the hot path.

The GRD-facing summary is
[`apps/gnome-remote-desktop/docs/mesa-panfrost-transfer.md`](../../apps/gnome-remote-desktop/docs/mesa-panfrost-transfer.md);
the benchmark that produced the 19.92 ms → 11.01 ms readback numbers is
[`apps/gnome-remote-desktop/bench`](../../apps/gnome-remote-desktop/bench).
