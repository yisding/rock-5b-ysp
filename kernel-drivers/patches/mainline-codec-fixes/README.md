# Mainline Rockchip codec fixes

Seven engineering corrections prepared from the 2026-07-30 audit of the
mainline RKVDEC and Verisilicon Hantro drivers.

| Field | Value |
|-------|-------|
| Mainline base | `3708dd9488440e35a165aee2bb2a1a7b1d0d5777` |
| Prepared branch | `mainline-rkvdec-hantro-fixes-ready` |
| Prepared tip | `c28b6586f74f7fb37c071174b66a445cf4ce0884` |
| Author/sign-off | `Yi Ding <yi.s.ding@gmail.com>` |
| Scope | Current mainline RKVDEC/Hantro only; no maxline or other not-yet-merged driver changes |
| Runtime state | **Not hardware-tested** |

## Contents

| Patch | Correction |
|-------|------------|
| `0001-media-rkvdec-keep-TRY_FMT-from-changing-colmv-offset.patch` | Keep capture `TRY_FMT` side-effect free and commit the derived colmv offset only with the actual format. |
| `0002-media-rkvdec-reject-unrepresentable-capture-buffer-s.patch` | Calculate decoded-image plus colmv backing in checked `u64` arithmetic and reject totals that cannot fit `sizeimage`. |
| `0003-media-rkvdec-leave-clock-enables-to-runtime-PM.patch` | Make runtime PM the sole owner of decoder clock enables. |
| `0004-media-hantro-fully-unwind-failed-device-runs.patch` | Balance PM/clocks, request controls, watchdog state, and synchronous AV1 failure completion. |
| `0005-media-rkvdec-set-the-streaming-DMA-mask.patch` | Constrain streaming as well as coherent DMA mappings to the hardware's 32-bit aperture. |
| `0006-media-hantro-set-the-streaming-DMA-mask.patch` | Apply the equivalent streaming/coherent DMA constraint to Hantro. |
| `0007-media-rkvdec-do-not-destroy-the-SRAM-provider-pool.patch` | Leave destruction of the borrowed SRAM `gen_pool` to its provider. |

Patches 0001 and 0002 form one dependent format-handling correction. The
remaining changes are independently applicable to the recorded base; their
numeric order preserves the prepared branch and is not an upstream publication
plan.

## Validation

The prepared tip and the exported patch files passed:

- `scripts/checkpatch.pl --strict --show-types` with zero errors, warnings, or
  checks for every commit and exported patch;
- a clean-index application check: 0001 then 0002 apply to the recorded base,
  and each remaining patch applies independently to that base; and
- an arm64 `defconfig` compile with `COMPILE_TEST=y`,
  `VIDEO_ROCKCHIP_VDEC=m`, `VIDEO_HANTRO=m`,
  `VIDEO_HANTRO_ROCKCHIP=y`, and `W=1`; both aggregate objects
  `rockchip-vdec.o` and `hantro-vpu.o` built successfully.

These checks prove source shape and compile integration, not hardware behavior.
The format negotiation boundaries, runtime-PM/clock balance, imported-DMABUF
address aperture, failed-run unwind, and SRAM-provider survival still need
their runtime tests described in the
[driver audit](../../docs/driver-architecture-comparison.md#12-current-mainline-and-maxline-rockchip-codec-audit-2026-07-30).

## Reconstruct

Use the exact source base:

```bash
git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git checkout 3708dd9488440e35a165aee2bb2a1a7b1d0d5777
git am /path/to/rock-5b-ysp/kernel-drivers/patches/mainline-codec-fixes/0*.patch
```
