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
| Current state | The COMPUTE-only direction was rejected upstream because it cannot write AFBC; surviving directions are local branches under active development. See [`../status.md`](../status.md). |

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
| 2026-07-01 | Remaining viable directions staged as local branches (**under active development** — re-check the tree before citing): `panfrost-transfer-fragcoord-blit` (fix the sampled blit's coordinate via `gl_FragCoord` + blit affine; at time of writing carried `2d79844bd29` "u_blitter: use fragment position for unscaled TXF blits" touching `u_blitter.c`/`u_simple_shaders.c` + re-enabling BLIT in `pan_screen.c`) and `panfrost-transfer-targeted-fallback` (`b475b5914de`: keep BLIT, route pure-integer format-changing transfers away from the blit in `st_cb_readpixels.c`/`st_cb_texture.c`). |

Neither !38433 nor !42563 had merged upstream as of the last local fetch
(main `0983c72a7ed`, 2026-06-29). UNVERIFIED beyond that date: the GitLab MR
pages could not be re-checked from the board on 2026-07-01 (anti-bot
interstitial).

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
