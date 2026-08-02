# Mainline Rockchip codec fixes

Seven engineering corrections prepared from the 2026-07-30 audit of the
mainline RKVDEC and Verisilicon Hantro drivers.

> **⚠️ Three of the seven are defective and must not be sent as written.**
> A 2026-08-02 adversarial re-read against the mainline source these patches
> target found that `0004` self-deadlocks, `0002` violates the V4L2 format
> contract, and `0005`/`0006` are no-ops carrying `Fixes:` tags for a
> regression that does not exist. The defects are ours, not upstream's, and
> none of them is visible to checkpatch, `git am`, or a `W=1` compile — which
> was the entire validation this series had. Per-patch verdicts are in the
> table below; the mechanisms are in
> [the series self-review](../../../findings/2026-08-02-mainline-codec-fix-series-self-review.md).

| Field | Value |
|-------|-------|
| Mainline base | `3708dd9488440e35a165aee2bb2a1a7b1d0d5777` |
| Prepared branch | `mainline-rkvdec-hantro-fixes-ready` |
| Prepared tip | `c28b6586f74f7fb37c071174b66a445cf4ce0884` |
| Author/sign-off | `Yi Ding <yi.s.ding@gmail.com>` |
| Scope | Current mainline RKVDEC/Hantro only; no maxline or other not-yet-merged driver changes |
| Runtime state | **Not hardware-tested** |
| Series state | **Not sendable as written** — 3 of 7 defective, see above |

## Contents

| Patch | Correction | Verdict (2026-08-02) |
|-------|------------|----------------------|
| `0001-media-rkvdec-keep-TRY_FMT-from-changing-colmv-offset.patch` | Keep capture `TRY_FMT` side-effect free and commit the derived colmv offset only with the actual format. | Correct as written |
| `0002-media-rkvdec-reject-unrepresentable-capture-buffer-s.patch` | Calculate decoded-image plus colmv backing in checked `u64` arithmetic and reject totals that cannot fit `sizeimage`. | **Defective** — returns `-EINVAL` from `TRY_FMT`/`S_FMT` for geometry `rkvdec_enum_framesizes()` advertises, and V4L2 requires adjustment rather than rejection; also duplicates the V4L2 core format table inside the driver. Needs a clamp, and reject-versus-clamp is the rkvdec maintainers' call |
| `0003-media-rkvdec-leave-clock-enables-to-runtime-PM.patch` | Make runtime PM the sole owner of decoder clock enables. | Correct as written |
| `0004-media-hantro-fully-unwind-failed-device-runs.patch` | Balance PM/clocks, request controls, watchdog state, and synchronous AV1 failure completion. | **Defective** — its `cancel_delayed_work_sync()` waits on the watchdog work that re-entered `device_run()`, so it deadlocks against itself, and the same path is hard-IRQ reachable. The rest of the patch is sound |
| `0005-media-rkvdec-set-the-streaming-DMA-mask.patch` | Constrain streaming as well as coherent DMA mappings to the hardware's 32-bit aperture. | **No-op** — the platform streaming mask is already 32-bit; drop the patch, or at minimum its `Fixes:` tag |
| `0006-media-hantro-set-the-streaming-DMA-mask.patch` | Apply the equivalent streaming/coherent DMA constraint to Hantro. | **No-op** — same as `0005` |
| `0007-media-rkvdec-do-not-destroy-the-SRAM-provider-pool.patch` | Leave destruction of the borrowed SRAM `gen_pool` to its provider. | Correct as written |

Patches 0001 and 0002 form one dependent format-handling correction. The
remaining changes are independently applicable to the recorded base; their
numeric order preserves the prepared branch and is not an upstream publication
plan.

`0001`, `0003` and `0007` are self-contained and hold up under review, so they
remain usable independently of what happens to the other four.

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
**They also proved unable to detect any of the three defects recorded above** —
a deadlock, an interface-contract violation, and two patches that change
nothing all pass every check in this list. Treat a green result here as
evidence that the series is well-formed, and nothing more.

The format negotiation boundaries, runtime-PM/clock balance, imported-DMABUF
address aperture, failed-run unwind, and SRAM-provider survival still need
their runtime tests described in the
[driver audit](../../docs/driver-architecture-comparison.md#12-current-mainline-and-maxline-rockchip-codec-audit-2026-07-30).

Two checks that would have caught what the list above missed, for whatever is
prepared next: a `DEBUG_ATOMIC_SLEEP` build with fault injection at the codec
backend's `run()` entry, and `v4l2-compliance` against the format ioctls.

Anything sent from this directory also needs the `Assisted-by:` trailer that
mainline now documents; none of the seven patches carries one, and the local
`Assisted-By:` convention is a different string in a different format. See
[the tool-assisted contribution policy](../../../findings/2026-08-02-mainline-tool-assisted-contribution-policy.md).

## Reconstruct

Use the exact source base:

```bash
git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git checkout 3708dd9488440e35a165aee2bb2a1a7b1d0d5777
git am /path/to/rock-5b-ysp/kernel-drivers/patches/mainline-codec-fixes/0*.patch
```

That base is Torvalds master. Media patches are reviewed against `media/next`,
so anything actually posted needs rebasing onto a freshly fetched media tree
rather than onto this pin.
