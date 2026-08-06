# video-libraries/mesa/ — Mali-G610 Mesa/Panfrost transfer investigation

Project vocabulary: [`keywords.md`](keywords.md).

This directory owns the Mesa/Panfrost knowledge learned while diagnosing
ROCK 5B readback cost and transfer correctness on Mali-G610 MC4. The
[GRD summary](../../apps/gnome-remote-desktop/docs/mesa-panfrost-transfer.md)
routes here for the shared mechanism, probes, and validation.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Understand the Panfrost transfer path, its correctness boundary, and why improving software readback does not replace hardware encode. |
| Developer focus | The varying-interpolation erratum, exact TXF coordinate design, AFBC constraint, transfer performance, validation, reproducible probes, and maintained review conclusions. |
| Owns | Causal model ([`blit-precision.md`](docs/blit-precision.md)), teaching guide ([`fix-walkthrough.md`](docs/fix-walkthrough.md)), accumulated tests ([`validation.md`](docs/validation.md)), review conclusions ([`mr-review-findings.md`](docs/mr-review-findings.md)), and probes ([`reproducers/`](reproducers/README.md)). |
| Does not own | Live MR heads, mergeability, review, or CI state ([W06](../../status.md#watch-w06)); public support verdict and next proof ([status track 8](../../status.md)). |
| Hardware basis | RK3588 / Mali-G610 MC4; immutable source and run identities remain in the evidence owners. |

## Files

| Path | Role |
|------|------|
| [`docs/fix-walkthrough.md`](docs/fix-walkthrough.md) | From-first-principles explanation of blits, TXF, interpolation, the fragcoord fix, and rejected alternatives |
| [`docs/blit-precision.md`](docs/blit-precision.md) | Canonical erratum investigation, causal chain, ruled-out hypotheses, fix shapes, AFBC boundary, and on-device proof |
| [`docs/validation.md`](docs/validation.md) | Accumulated correctness, performance, dEQP/Piglit, build, CI-classification, and workaround evidence |
| [`docs/mr-review-findings.md`](docs/mr-review-findings.md) | Maintained code-review conclusions at immutable reviewed tips; W06 owns later remote state |
| [`docs/rebuild-and-test.md`](docs/rebuild-and-test.md) | Board rebuild/revalidation runbook and recorded environment traps |
| [`docs/texture-query-levels.md`](docs/texture-query-levels.md) | Separate Valhall `textureQueryLevels()` design and descriptor facts |
| [`docs/arm-mali-blob-stack.md`](docs/arm-mali-blob-stack.md) | Proprietary libmali package/loader inspection and comparison boundary |
| [`scripts/`](scripts/README.md) | Build, environment, reproducer, dEQP, and Piglit entry points |
| [`reproducers/`](reproducers/README.md) | Transfer, raw-varying, ordinary-TEX, GL/Vulkan, and benchmark probes |
| [`patches/0001-panfrost-advertise-transfer-blit-and-compute.patch`](patches/0001-panfrost-advertise-transfer-blit-and-compute.patch) | Archived failing BLIT configuration, for reproduction only |
| [`patches/mr43161-benchmark-override.patch`](patches/mr43161-benchmark-override.patch) | Test-only all-blit and balanced timing control |
| [`patches/u_blitter-review2-txf-fragcoord-cleanups.patch`](patches/u_blitter-review2-txf-fragcoord-cleanups.patch) | Review cleanup candidate tied to the reviewed source shape |

<a id="mr-status"></a>

## Status (last live-state check 2026-07-11; technical validation remains dated below)

This heading is a compatibility route for earlier links. It no longer caches
MR heads, merge status, pipelines, or a force-push diary.

- [W06](../../status.md#watch-w06) is the sole dated cache of the four GitLab
  MRs and their selected CI.
- [Status track 8](../../status.md) owns the public verdict and next proof.
- [Validation](docs/validation.md) owns what the recorded tips proved.
- [MR review findings](docs/mr-review-findings.md) owns code-review conclusions
  at its immutable source pins.
- GitLab remains authoritative for current MR discussions and state.

## Short version

Panfrost historically advertised no Gallium texture-transfer acceleration, so
CPU readback paid detile/swizzle cost. GPU transfer materially improved the
measured GRD-shaped readback, but the sampled BLIT path was not bit-exact for
wide format-changing transfers.

The failure was not a bad TXF instruction. A Mali-G610 erratum makes varying
interpolation drift at some non-power-of-two primitive extents; truncating the
drifted coordinate chooses the wrong texel. `gl_FragCoord` remained exact in
the same probes. A shared `u_blitter` opt-in therefore reconstructs unscaled
TXF coordinates from fragment position and per-draw constant scale/offset.

COMPUTE avoided the varying path and was fast and exact, but cannot write AFBC
destinations. It remains evidence and a useful debug route, not the general
Panfrost transfer policy.

## Key facts to carry forward

- The raw varying drifts without Gallium, `u_blitter`, texture sampling, or
  TXF; equivalent GL and Vulkan probes rule out a Mesa-only explanation.
- Drift depends on geometry and is not captured by one reliable aspect-ratio
  cutoff. Power-of-two cases can pass while nearby non-power-of-two cases fail.
- `gl_FragCoord` is exact for the affected internal blit cases, and
  vertex-constant scale/offset data remains exact through interpolation.
- The fragcoord path must stay co-located with shader selection and exclude
  incompatible shader shapes such as MSAA, cube, pack, and override paths.
- The transfer enablement exposed two independent integration bugs: stale
  Panfrost image-mask bits after trailing unbind and allocation-only texture
  upload entering a giant staging path.
- A zero-valued depth-bias state selects an exact varying path on the measured
  G610 in both GL and Vulkan. The microarchitectural reason is not public.
- The all-blit workaround fixed affected integer cases without corrupting
  ordinary controls. Its balanced fixed-clock benchmark resolved a small
  workload-specific cost, not a universal application slowdown.
- COMPUTE is exact and useful for CPU readback but cannot be the blanket answer
  because shader writes cannot produce AFBC payloads.
- A build, a decoded image, a focused reproducer, a CTS subset, selected CI,
  and a live MR merge verdict are different evidence classes.

For exact identities, signals, counts, and confidence boundaries, use
[`blit-precision.md`](docs/blit-precision.md),
[`validation.md`](docs/validation.md), and
[`mr-review-findings.md`](docs/mr-review-findings.md).

## Relation to the GRD work

GRD's software RFX path reads the captured frame back to CPU memory. GPU-side
transfer reduces detile/swizzle cost and makes that fallback less slow; it does
not remove the readback. Hardware encode remains the architectural fix because
it keeps the frame on the GPU/media path.

The GRD-facing contract is summarized in
[`apps/gnome-remote-desktop/docs/mesa-panfrost-transfer.md`](../../apps/gnome-remote-desktop/docs/mesa-panfrost-transfer.md);
the benchmark owner is
[`apps/gnome-remote-desktop/bench`](../../apps/gnome-remote-desktop/bench).
