# Upstreaming decisions — Mesa / Panfrost

This package holds the Mali-G610 Mesa/Panfrost transfer investigation — the
`u_blitter` TXF precision fix, the blit-based transfer enablement stack, the
Valhall varying erratum, and the related uncached-readback and libmali
findings — and this file records its upstream submission disposition as
decided 2026-07-29; cross-package ordering and coupling constraints live in
the central [upstreaming ledger](../../docs/upstreaming-ledger.md), and every
dated claim below must be re-verified before acting on it.

## Decision list

| ID | Item | Artifact | Upstream target | Decision | Priority | Gates / prerequisites |
|---|---|---|---|---|---|---|
| MESA-1 | panfrost: clear shader image mask on trailing unbinds | Mesa MR !42563, branch `yding:panfrost-transfer-blit` @ `833101f35ed` | Mesa MR !42563 | IN-FLIGHT | P1 | — |
| MESA-2 | u_blitter: use fragment position for unscaled TXF blits (shared Gallium fix) | Mesa MR !42679, branch `yding:u-blitter-txf-fragcoord` @ `6509025064f`; cleanup archive `patches/u_blitter-review2-txf-fragcoord-cleanups.patch` | Mesa MR !42679 | IN-FLIGHT | P1 | — |
| MESA-3 | panfrost: enable blit-based texture transfers (arch>=6 fragcoord opt-in + Joshua Watt's `PIPE_TEXTURE_TRANSFER_BLIT` enablement + allocation-only TexImage guard) | Mesa MR !42613, branch `yding:panfrost-blit-transfers` @ `8875a22856d` | Mesa MR !42613 | IN-FLIGHT | P2 | MESA-2 (!42679) rebased and its selected CI rerun, then regenerate !42613 from !42679's tip — !42679 is not an ancestor of !42613, so this ordering is mandatory; fold in the three should-fix items in the same regeneration (hoist the allocation-only guard into `st_TexSubImage`, share one `arch >= 6` predicate between the two gates, sync the G52/G57 CI expectation files with the G610 `glx-copy-sub-buffer` drop) |
| MESA-4 | u_tests: wide unscaled format-changing blit precision test + panfrost `glsl_type` singleton reference | Mesa MR !42614, branch `yding:panfrost-blit-transfers-test` @ `4c23f1db1f9` | Mesa MR !42614 | IN-FLIGHT | P3 | — |
| MESA-5 | Mali-G610 varying-erratum characterization: size/aspect predicate data, PanVK and ARM-blob cross-checks for MR !43161 | Findings 2026-07-22 / 2026-07-24 plus reproducers `interp_probe/triangle_matrix_probe.c`, `exact_offset_scan2d.c`, `mr43161_size_repro.sh`, `tiny_interp_probe.c`, `vk_interp_probe.c` | Mesa MR !43161 discussion (and !42679) | SUBMIT-NOW | P1 | — |
| MESA-6 | Fixed-clock, single-context A/B cost of the MR !43161 all-blit depth-bias workaround | `findings/2026-07-28-mesa-blit-benchmark-timing-boundary.md` plus `reproducers/blit_workaround_bench.c` and `run_blit_workaround_bench.py` | Mesa MR !43161 discussion | SUBMIT-NOW | P2 | — |
| MESA-7 | MR !43161 benchmark override: remove the size/aspect gate and add `PAN_BLIT_DEPTH_BIAS` test controls | `patches/mr43161-benchmark-override.patch` (applies to MR !43161 commit `647256dc2ae`; local branch `benchmark/mr43161-all-blits` @ `6000414f9ea`) | Mesa — patch on someone else's MR | NEVER | P3 | — |
| MESA-8 | Archived panfrost BLIT+COMPUTE transfer-mode advertising patch | `patches/0001-panfrost-advertise-transfer-blit-and-compute.patch` | Mesa — none intended | NEVER | P3 | — |
| MESA-9 | panfrost: lower `textureQueryLevels` on Valhall (arch >= 9) | Local commit `a59b9dfcac1` on branch `panfrost-texture-blit` (pushed to `github.com/yisding/mesa`); documented in `docs/texture-query-levels.md` | Mesa MR, panfrost label | SUBMIT-AFTER-GATE | P2 | Run piglit `arb_texture_query_levels` (all 16 fs/vs x baselevel/maxlevel/miptree/nomips, afbcp- and plain) on the ROCK 5B G610 and record the pass artifact — current validation is UNVERIFIED; rebase `a59b9dfcac1` from Mesa main `feeb6209135` (2026-01-27) onto current main and re-verify the Valhall descriptor offsets and intrinsic registration still apply |
| MESA-10 | mesa,dri: skip zero-sized blits before Gallium | Local branch `zero-sized-blits-gallium` @ `d8cf9625ba5` | Mesa MR, core Mesa/DRI | SUBMIT-NOW | P3 | — |
| MESA-11 | lavapipe: skip zero-sized image blit and resolve regions | Local branch `zero-sized-blits-lavapipe` @ `740be57319d` | Mesa MR, lavapipe | SUBMIT-NOW | P3 | — |
| MESA-12 | core Mesa: `glReadPixels` fallback converts per-pixel straight out of an uncached/WC source map | `findings/2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md` (Bug A), analysis against `fdo/mesa@4c23f1db1f9` `read_rgba_pixels()` in `src/mesa/main/readpix.c` | Mesa GitLab issue against core readpixels, optionally with a patch | SUBMIT-AFTER-GATE | P2 | Determine at runtime (MESA_DEBUG/apitrace) the exact condition in `st_ReadPixels` that rejects the blit fast path for BGRA-from-import, as the finding's filing notes require before filing Bug A |
| MESA-13 | panfrost: imported linear buffers are CPU-read through a direct uncached map instead of a cached staging blit | `findings/2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md` (Bug B), analysis of `panfrost_ptr_map()` in `src/gallium/drivers/panfrost/pan_resource.c` and `src/panfrost/lib/kmod/panthor_kmod.c:471` | Mesa GitLab issue, panfrost label | SUBMIT-NOW | P2 | — |
| MESA-14 | PanVK: install zero-valued depth bias on internal meta draws to dodge the Valhall varying erratum | No patch held; measured basis in `findings/2026-07-22-mali-varying-depth-bias-erratum-workaround.md` and `reproducers/interp_probe/vk_interp_probe.c` | Mesa MR, panvk | HOLD | P3 | MR !43161's GL-side workaround predicate is merged or agreed, so the PanVK meta-draw version can mirror it instead of inventing a second policy |
| MESA-15 | panfrost: `GALLIUM_TESTS` aborts in `util_test_constant_buffer` via `panfrost_emit_const_buf` (resource-backed constant buffers) | Observed during the !42614 test work; recorded in `docs/mr-review-findings.md` (`pan_cmdstream.c:1633`) | Mesa GitLab issue, panfrost label — or one sentence in the !42614 description | SUBMIT-NOW | P3 | — |
| MESA-16 | libmali GBM path: `DRM_IOCTL_SET_VERSION` NULL-derefs `drm_setversion`, then `rockchip_drm_lastclose` deadlocks `drm_global_mutex` | `docs/arm-mali-blob-stack.md` "Runtime Results (measured 2026-07-08)"; guarded reproducer under `reproducers/interp_probe/` | Radxa/Rockchip BSP kernel (GitHub issue) if vendor-only, or dri-devel/drm-misc if mainline reproduces | SUBMIT-AFTER-GATE | P3 | Reproduce (or clear) the `DRM_IOCTL_SET_VERSION` NULL-deref on the 6.18.40 forward-port kernel / mainline rockchip-drm to decide whether the target is the Radxa 5.10 BSP or DRM core |
| MESA-17 | Superseded transfer-avoidance directions: COMPUTE-only transfer cap, and routing pure-integer format-changing transfers off the blit | Local branches/commits `9d7f561cd9d` (COMPUTE cap + `is_compute_copy_faster`) and `panfrost-transfer-targeted-fallback` @ `6a292503585` | Mesa — none | NEVER | P3 | — |

## Rationale and evidence

### MESA-1 — panfrost: clear shader image mask on trailing unbinds

Trailing image unbinds clear resources but leave stale `image_mask` bits, so
the next u_blitter draw null-derefs in `util_image_to_sampler_view()`; board
reproduction on 2026-07-06 crashed piglit `pbo-getteximage -auto` and passed
after the mask clear. The MR carries `Reviewed-by: Iago Toral Quiroga` and
`Fixes: 72ff66c3d73`, pipeline 1697832 is green on selected x86/arm64 build
plus G610 GL/piglit, and it is independent of the rest of the stack — the
only action left is to re-verify state and ask a maintainer to assign it to
Marge. State is 18 days stale as of 2026-07-29 (last live-checked 2026-07-11
via `glab api`); re-verify before acting since it may already have merged.

- Evidence: [README.md](./README.md), [docs/mr-review-findings.md](./docs/mr-review-findings.md), [docs/validation.md](./docs/validation.md), [status.md](../../status.md), [docs/status-ledger.md](../../docs/status-ledger.md)
- Coupled with: MESA-3

### MESA-2 — u_blitter: use fragment position for unscaled TXF blits (shared Gallium fix)

The load-bearing MR in the four-MR stack, with an explicit open action to
rebase, rerun its selected CI, then regenerate !42613 from its tip, since
the duplicated u_blitter commit is not an ancestor of !42613. As of
2026-07-11 the MR reported `need_rebase` while pipeline 1700107 stayed
green for selected x86 build, clang, llvmpipe and softpipe (ARM not
selected — the flag defaults off until Panfrost opts in). Two review risks
belong in the same push: a maintainer's parallel `nir_blit_helpers.c` work
may force re-authoring in NIR against `nir_load_pixel_coord`, and the
commit messages need the measurement-first rewording flagged since the
2026-07-06 review. Evidence: a board-measured probe battery, a u_test
failing 40884 texels unfixed and passing fixed, zero dEQP failures across
1097 tests.

- Evidence: [README.md](./README.md), [docs/mr-review-findings.md](./docs/mr-review-findings.md), [docs/blit-precision.md](./docs/blit-precision.md), [patches/u_blitter-review2-txf-fragcoord-cleanups.patch](./patches/u_blitter-review2-txf-fragcoord-cleanups.patch), [../../findings/2026-07-08-blit-precision-nir-migration.md](../../findings/2026-07-08-blit-precision-nir-migration.md), [status.md](../../status.md)
- Coupled with: MESA-3, MESA-4, MESA-10

### MESA-3 — panfrost: enable blit-based texture transfers

Delivers the user-visible win — GPU-side detile/swizzle instead of CPU
readback — and retires the local fork delta over MR !38433, but it is
gated on MESA-2's rebase since reviewers asked that !42613 be regenerated
from !42679's tip. Rerun pipeline 1700162 passed all four selected G610
shards after two force-pushes, and it carries the cherry-picked
`a9d6caeeb53` enablement with Joshua Watt's authorship preserved. Three
should-fix items belong in the same regeneration: hoist the allocation-only
guard into `st_TexSubImage`, share one predicate between the two
`arch >= 6` gates, and sync the G52/G57 CI expectation files with the G610
`glx-copy-sub-buffer` drop. Two 2026-07-06 residuals (a large-tex
shader-version reach, a gl-2.1-pbo polygon-stipple mismatch) still need a
no-BLIT baseline comparison before they can be called non-blockers.

- Evidence: [README.md](./README.md), [docs/mr-review-findings.md](./docs/mr-review-findings.md), [docs/validation.md](./docs/validation.md), [docs/rebuild-and-test.md](./docs/rebuild-and-test.md), [status.md](../../status.md)
- Coupled with: MESA-1, MESA-2, MESA-4

### MESA-4 — u_tests: wide unscaled format-changing blit precision test + glsl_type singleton reference

The regression test that makes the series defensible, plus the `glsl_type`
singleton fix without which `GALLIUM_TESTS` crashes in `glsl_array_type` on
Panfrost; it only exercises the fixed path after the driver opt-in, so it
stays last and moves only when MESA-3 moves. It is open and stacked on
!42613, with rerun pipeline 1700163 passing all four selected G610 shards,
and it was verified live in both directions on the board (pass on the fixed
path, exactly 40884 wrong texels with `use_txf_fragcoord` flipped off in
gdb). Two nit-level items to fold in on the next push: document the 16307
(< 16384) size choice and NULL-check `wide_blit_create_tex` / guard
`max_texture_array_layers >= 2`. The commit message currently oversells "so
the gallium unit tests can run" and should disclose the pre-existing
`util_test_constant_buffer` abort tracked as MESA-15.

- Evidence: [README.md](./README.md), [docs/mr-review-findings.md](./docs/mr-review-findings.md), [reproducers/README.md](./reproducers/README.md), [status.md](../../status.md)
- Coupled with: MESA-2, MESA-3, MESA-15

### MESA-5 — Mali-G610 varying-erratum characterization for MR !43161

The highest-leverage contribution available right now, and it is a comment,
not a patch: MR !43161 is choosing a size/aspect cutoff for the
internal-blitter depth-bias workaround, and the board data shows the
proposed cutoffs (1000 and 500) both miss measured failures while some
higher-aspect cases pass, so no clean non-power-of-two TEX-safe predicate
follows from the data. The only clean bit-exact exemption through 4096x4096
is both dimensions power-of-two; cross-checks show the same drift
bit-for-bit on ARM's proprietary blob and on PanVK with no Gallium/u_blitter
anywhere, and the zero-valued depth-bias workaround fixes GL raw varyings,
GL ordinary TEX-nearest, and Vulkan. Recommend the simple hardware-scoped
predicate (Panfrost internal fullscreen blitter, `arch >= 9 && arch < 11`)
and offer the size gate only as a compromise; check the MR notes via
`glab api` first and post only the delta, since it is not recorded here
whether any of this was already posted.

- Evidence: [../../findings/2026-07-24-mali-oblong-triangle-matrix.md](../../findings/2026-07-24-mali-oblong-triangle-matrix.md), [../../findings/2026-07-24-mali-blit-workaround-size-results.md](../../findings/2026-07-24-mali-blit-workaround-size-results.md), [../../findings/2026-07-22-mali-varying-depth-bias-erratum-workaround.md](../../findings/2026-07-22-mali-varying-depth-bias-erratum-workaround.md), [docs/arm-mali-blob-stack.md](./docs/arm-mali-blob-stack.md), [reproducers/interp_probe/README.md](./reproducers/interp_probe/README.md), [README.md](./README.md)
- Coupled with: MESA-6, MESA-14

### MESA-6 — Fixed-clock, single-context A/B cost of the MR !43161 workaround

Contributes the only surviving measurement of the cost !43161 itself asks
about: forcing the workaround on every internal blit costs +0.50%
completion-side (95% interval +0.34%..+0.73%) and +0.62% end-to-end wall
time on the affected R32UI 12288x1 workload, measured 2026-07-28 with an
off/off A/A control whose interval includes zero, an independent same-batch
control at +0.451%, all 6480 samples non-disjoint, and all 242 GPU clock
checks at exactly 500 MHz. The comment must carry the same caveats as the
finding: it is a workload-specific microbenchmark and not a universal
slowdown, `GL_TIME_ELAPSED_EXT` was rejected as a decision signal because of
Panfrost's 32 live-FBO-batch limit, and two biases (a context-position
effect and a count-order effect) had to be removed before the result
resolved. Contribute as measurement data only — the harness lives in this
repo and its driver-side toggle (MESA-7) is not upstreamable as written.

- Evidence: [../../findings/2026-07-28-mesa-blit-benchmark-timing-boundary.md](../../findings/2026-07-28-mesa-blit-benchmark-timing-boundary.md), [../../findings/2026-07-27-mesa-all-blit-workaround-benchmark-results.md](../../findings/2026-07-27-mesa-all-blit-workaround-benchmark-results.md), [../../findings/2026-07-27-mali-blit-workaround-performance-benchmark-plan.md](../../findings/2026-07-27-mali-blit-workaround-performance-benchmark-plan.md), [reproducers/README.md](./reproducers/README.md), [../../docs/source-trees.md](../../docs/source-trees.md), [README.md](./README.md)
- Coupled with: MESA-5, MESA-7

### MESA-7 — MR !43161 benchmark override patch

Not a submission unit: it deliberately deletes another author's temporary
size/aspect gate to force an all-V9–V10 policy and adds test-only
`PAN_BLIT_DEPTH_BIAS` env control, including a dynamic mid-context mode,
purely so the harness can do a balanced A/B in one EGL context. Submitting
it would mean proposing instrumentation and a policy change under someone
else's MR; the useful product — the measurement — is submitted separately
as MESA-6, and this patch's real job is reproducibility, keeping the exact
measured driver (public commit `647256dc2ae`) rebuildable. One conditional
carve-out: if !43161's reviewers ask for reproducible A/B measurement, offer
just the static off|on env knob with the gate removal and dynamic mode
dropped, but do not upstream it unasked.

- Evidence: [patches/mr43161-benchmark-override.patch](./patches/mr43161-benchmark-override.patch), [README.md](./README.md), [reproducers/README.md](./reproducers/README.md), [../../docs/source-trees.md](../../docs/source-trees.md), [../../findings/2026-07-28-mesa-blit-benchmark-timing-boundary.md](../../findings/2026-07-28-mesa-blit-benchmark-timing-boundary.md)
- Coupled with: MESA-6

### MESA-8 — Archived panfrost BLIT+COMPUTE transfer-mode advertising patch

Reproduction-only by design: it exists solely so the failing BLIT
configuration can be rebuilt once upstream ships a non-BLIT default, and it
is superseded upstream by !42613, which cherry-picks Joshua Watt's real
enablement commit with authorship preserved. Its COMPUTE half is
additionally a rejected direction (see MESA-17). Keep it tracked, never
submit it.

- Evidence: [patches/0001-panfrost-advertise-transfer-blit-and-compute.patch](./patches/0001-panfrost-advertise-transfer-blit-and-compute.patch), [README.md](./README.md), [reproducers/README.md](./reproducers/README.md)

### MESA-9 — panfrost: lower textureQueryLevels on Valhall

A clean, self-contained feature never offered upstream: `nir_texop_query_levels`
reaches the Bifrost/Valhall backend unlowered and aborts the compiler, which
is why `panfrost-g610-fails.txt` carries 16 crash entries across the full
{afbcp-,plain} x {fs,vs} x {baselevel,maxlevel,miptree,nomips} cross product.
The fix is 56 insertions across 5 files — a new `load_texture_levels_pan`
NIR intrinsic, lowering for both constant and dynamic texture-index paths,
and `va_emit_load_texture_levels()` codegen reading the texture descriptor —
and it deletes 16 CI expectation lines. Two gates precede submission: run
piglit `arb_texture_query_levels` on the board and record the pass artifact,
since current validation is UNVERIFIED with no surviving run artifacts; and
rebase the branch from Mesa main `feeb6209135` (2026-01-27) onto current
main and re-verify the Valhall descriptor offsets still apply.

- Evidence: [docs/texture-query-levels.md](./docs/texture-query-levels.md), [docs/rebuild-and-test.md](./docs/rebuild-and-test.md), [README.md](./README.md)

### MESA-10 — mesa,dri: skip zero-sized blits before Gallium

Built 2026-07-05 as the direct consequence of a maintainer decision on
!42679 — empty blits are not u_blitter's problem, so callers must skip them
— and then never MR'd, leaving that review thread half-answered. It skips
empty copy rectangles in `dri2_blit_image`, `glCopyImageSubData` and
`glCopyTexSubImage*` before a Gallium blit is constructed, preserving API
no-op semantics while keeping the non-empty-destination invariant !42679's
fragcoord path now asserts. Sequence it with or just after !42679 so the
assert and the caller-side skip land coherently; the repo records the
branch as built, not separately test-validated, so the MR should lean on
upstream CI and note the change is a pure early-out.

- Evidence: [README.md](./README.md)
- Coupled with: MESA-2, MESA-11

### MESA-11 — lavapipe: skip zero-sized image blit and resolve regions

The Vulkan-side sibling of MESA-10 from the same 2026-07-05 maintainer
exchange: skip empty blit and resolve regions before lavapipe builds
`pipe_blit_info` for llvmpipe/softpipe. It is a different component with a
different reviewer set, so it is its own review thread rather than a commit
in MESA-10's MR. Lavapipe is a software driver whose evidence class is
upstream CI (llvmpipe/softpipe jobs, already green for !42679's selected
set), so no board evidence is owed and nothing blocks it.

- Evidence: [README.md](./README.md)
- Coupled with: MESA-10

### MESA-12 — core Mesa: glReadPixels fallback converts per-pixel from an uncached source map

A real, generic upstream performance cliff nobody has reported: when
`st_ReadPixels` rejects its blit fast path and falls to `read_rgba_pixels`,
per-pixel conversion out of an uncached/write-combined source map costs
~100-300 ns per access with no burst or prefetch, turning a multi-megapixel
frame into seconds to minutes at 100% CPU. Build-id-matched gdb captures of
gnome-remote-desktop show the thread stuck at the same PC in `convert_ubyte`
for 5+ minutes of CPU per frame, and Mesa already ships
`util/format/streaming-load-memcpy.h` for exactly this case, so the fix is a
bulk cached-bounce copy before conversion — a fix that benefits any driver
mapping the readback source uncached. Before filing, identify at runtime
(MESA_DEBUG/apitrace) the exact condition that rejects the blit path for
BGRA-from-import, as the finding's own pre-filing gate requires.

- Evidence: [../../findings/2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md](../../findings/2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md), [../../findings/README.md](../../findings/README.md)
- Coupled with: MESA-13

### MESA-13 — panfrost: imported linear buffers are read through a direct uncached map

The driver half of the same cliff, with the cleanest source story:
`panfrost_ptr_map()` takes the cached staging-texture path only for
AFBC/AFRC, so linear imports fall through to a direct map of the imported
BO, and on panthor that BO is uncached by the driver's own admission at
`panthor_kmod.c:471`. Fix options are already worked out — route
imported-linear CPU readback through a cached staging blit like AFBC/AFRC
does, or honour `DMA_BUF_IOCTL_SYNC` and map cached when the exporter
supports coherent CPU access. This repo already ships the consumer-side
proof that the cliff is real, since the GNOME Remote Desktop patch set works
around it with a cached `glCopyTexSubImage2D` copy; nothing gates the
report, so file it as a panfrost issue and cross-link MESA-12.

- Evidence: [../../findings/2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md](../../findings/2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md), [../../findings/README.md](../../findings/README.md), [../../apps/gnome-remote-desktop/patches/README.md](../../apps/gnome-remote-desktop/patches/README.md)
- Coupled with: MESA-12, GRD-5

### MESA-14 — PanVK: install zero-valued depth bias on internal meta draws

The erratum is not GL-specific: PanVK reproduces the drift bit-for-bit on a
stack with no Gallium, no u_blitter and no GL state tracker, and
`depthBiasEnable = VK_TRUE` with all-zero factors makes it exact at 12288
and 16307 via the same `mali_depth_stencil::depth_bias_enable` bit, so
internal u_blitter and PanVK meta draws must both install the safe
rasterizer state themselves. No PanVK patch exists yet because the right
shape depends on what !43161 settles on for the GL blitter predicate
(path-scoped versus size-gated); writing a PanVK version before that would
likely be redone. Revisit once !43161 merges or its predicate is agreed —
the correctness evidence is already in hand, so only the patch and a
PanVK-side test would remain.

- Evidence: [../../findings/2026-07-22-mali-varying-depth-bias-erratum-workaround.md](../../findings/2026-07-22-mali-varying-depth-bias-erratum-workaround.md), [reproducers/interp_probe/README.md](./reproducers/interp_probe/README.md), [docs/blit-precision.md](./docs/blit-precision.md)
- Coupled with: MESA-5

### MESA-15 — panfrost: GALLIUM_TESTS aborts in util_test_constant_buffer

A pre-existing Panfrost bug the !42614 test work surfaced and that nothing
else in the tree tracks: with `GALLIUM_TESTS=1` on panfrost, u_tests abort
in `util_test_constant_buffer` at `panfrost_emit_const_buf`
(`pan_cmdstream.c:1633`) on resource-backed constant buffers, which is why
the glsl_type singleton commit's "so the gallium unit tests can run"
message overstates the result. Report it as a small panfrost issue with the
assert location and reproducer, and add one clarifying sentence to !42614's
description so the commit message stops overselling. Diagnostic depth is
thin — the assert site is known, not the root cause — so file it as an
issue, not a patch.

- Evidence: [docs/mr-review-findings.md](./docs/mr-review-findings.md), [README.md](./README.md)
- Coupled with: MESA-4

### MESA-16 — libmali GBM path: DRM_IOCTL_SET_VERSION NULL-deref and drm_global_mutex deadlock

A genuine unprivileged local denial of service found while cross-checking
the erratum on ARM's proprietary stack: libmali's GBM/EGL bring-up issues
legacy `DRM_IOCTL_SET_VERSION` on the rockchip-drm primary node, NULL-derefs
in `drm_setversion`, and the Oops teardown then deadlocks `drm_global_mutex`
via `rockchip_drm_lastclose`, hanging every later DRM open in unkillable D
state until a power cycle; with a compositor holding DRM master the same
call deadlocks instead of Oopsing. Reproduced twice with full Oops and
hung-task backtraces, but it is not submittable yet because the target is
undetermined — it is pinned to the Radxa 5.10.110-39-rockchip vendor
kernel, and nobody has checked whether the same ioctl path reproduces on the
6.18 forward port or on mainline rockchip-drm. That check decides between a
vendor issue and a real DRM-core report, and the fix would land in the
kernel even though the evidence lives under `video-libraries/mesa/`.

- Evidence: [docs/arm-mali-blob-stack.md](./docs/arm-mali-blob-stack.md), [../../findings/2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md](../../findings/2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md), [reproducers/interp_probe/README.md](./reproducers/interp_probe/README.md)

### MESA-17 — Superseded transfer-avoidance directions

Both alternatives to the fragcoord fix are closed and recording that keeps
them from being re-proposed. COMPUTE-only was rejected upstream on
2026-07-01 ("Compute isn't the right solution. We can't write AFBC that
way"), and the objection is correct since Panfrost cannot write AFBC
payloads from shaders, even though it was slightly faster on the measured
G610 cases. The targeted fallback (keep BLIT, route pure-integer
format-changing transfers elsewhere) was falsified the same day: a wide
RG32F -> RGBA32F readback corrupted 96.1%, showing the pure-integer gate is
under-inclusive and the drift is format-agnostic. Keep both as documented
dead ends; never submit either.

- Evidence: [README.md](./README.md), [docs/blit-precision.md](./docs/blit-precision.md), [reproducers/README.md](./reproducers/README.md)
