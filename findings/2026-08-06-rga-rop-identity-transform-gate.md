# RGA rewrite's ROP gate mistook librga's identity cosine for rotation

> Scope: clean-room RGA rewrite; official librga ROP sample on ROCK 5B
> Source: `rk3588-rewrite-6.18@f96c1e74c83b`, `rk3588-rewrite-mainline@c25518d37ff3`; BSP `develop-6.1@b4ef083dc0c3`; `rga_rewrite.c` `rk_rga2_validate_rop()` / `rk_rga2_decode_transform()`
> Date: 2026-08-06
> Trust: MEASURED, SOURCE-INSPECTED, ROOT-CAUSED, SOURCE-CONFIRMED, FIX-COMPILE-VERIFIED, PARTIAL

## Result

The official `rga_rop_demo` failure was a rewrite validation defect, not an
unsupported RGA2 operation.  Installed librga submitted the identity tuple
`rotate_mode=0`, `sina=0`, `cosa=65536`; `65536` is 1.0 in the legacy 16.16
fixed-point transform encoding.  The ROP-specific validator rejected any
nonzero raw `sina` or `cosa`, before the common bitblit transform decoder could
recognize the request as identity.

The BSP does not have this gate.  Its RGA2 conversion recognizes the canonical
fixed-point rotation tuples, and its bitblit register generator programs source
rotation/mirroring and ROP controls independently.  A controlled GDB replay on
the rewrite boot changed only the inactive identity fields to zero; the official
sample then reached hardware completion and printed its success marker.  That
differential rules out the opcode, image layout, and basic ROP emitter as the
cause of the observed rejection.

The fix removes the raw global-transform rejection from
`rk_rga2_validate_rop()`.  The existing common decoder now handles both the
librga identity tuple and genuine supported RGA2 rotate/mirror tuples before
the emitter writes the independent source-transform and ROP registers.  Nested
`src.rotate_mode` and `dst.rotate_mode` remain rejected: the BSP's RGA2 rotation
programming uses the top-level tuple, not those per-image fields.

The existing ROP KUnit case now contains two positive register vectors:

- the exact librga identity tuple, with zero source rotate/mirror register bits;
- a 90-degree ROP request in librga's pre-swapped destination-window wire form,
  with source rotate mode 1, a normalized 32x64 destination, and the ROP AND
  controls present in the same command buffer.

Both maintained rewrite trees are byte-identical for the tracked sources.  The
source-debt audit reported 306 known signals, zero new signals, and zero missing
baseline entries for each tree.  The unchanged KUnit manifest matched both
trees.  The warning-fatal clean-source normal build gate passed the RGA/MPP
rewrite objects, both IOMMU providers, and ROCK 5B DTB at both fix commits.

## Remaining BSP ROP boundary

This change closes identity and ordinary global rotate/mirror admission only.
The BSP source exposes a broader ROP surface that the rewrite still deliberately
rejects: its 256-entry ROP lookup table, ROP modes 0/1/2 including two-word ROP4,
pattern/mask programming, and source-pipeline combinations such as scaling or
CSC.  BSP source acceptance is not pixel-correctness proof for those feature
cross-products, so they remain outside the rewrite allowlist pending focused
content tests.

## Evidence and reproduction

- **Failing run:** `kernel-drivers/tests/run-librga-suite.sh` output under
  `/home/yi/Code/rock-5b/build/rockchip-conformance/logs/rewrite-kasan/20260806-101424-librga-suite`; `rga_rop_demo` returned the harness's `log-fail` result.
- **Wire capture:** the second legacy blit request contained
  `render_mode=0`, `rotate_mode=0`, `sina=0`, `cosa=65536` and ROP AND.
- **Differential:** under GDB, zeroing only the identity `sina/cosa` fields let
  the official sample complete on the same boot.  The sample checks terminal
  status, not output pixels.
- **Source comparison:** rewrite `rk_rga2_validate_rop()` and
  `rk_rga2_decode_transform()` versus BSP `rga_cmd_to_rga2_cmd()`,
  `RGA2_set_reg_src_info()`, `RGA2_set_reg_rop_info()`, and
  `rga2_gen_reg_info()`.
- **Build command:**
  `REWRITE_BUILD_PROFILES=normal bash kernel-drivers/tests/rewrite-build-gate.sh all`
  with ccache and `REWRITE_BUILD_TMP_ROOT` directed under
  `../rock-5b/build/rewrite-rop-transform-gate`.
- **Build signal:** `[6.18/normal] PASS` at `f96c1e74c83b` and
  `[mainline/normal] PASS` at `c25518d37ff3`, exit 0.

## Boundary

The new KUnit vectors prove admission and command generation, and the clean
build proves integration with both maintained kernel contexts.  They do not
prove ROP-plus-rotation pixel correctness, DMA/IRQ behavior, or a sanitizer-clean
boot.  The fix has not yet been packaged, booted, or run through the official
librga suite.  The next hardware gate is an exact-content ROP identity test plus
90/180/270-degree ROP outputs on a kernel containing `f96c1e74c83b`, followed by
the ordinary fatal dmesg and rewrite counter checks.
