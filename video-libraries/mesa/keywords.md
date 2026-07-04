# video-libraries/mesa — keywords

Mesa/Panfrost transfer terms. Cross-cutting vocabulary is in
[`../../glossary.md`](../../glossary.md).

- **Panfrost / panvk** — Mesa's open-source GL(ES) / Vulkan drivers for Mali GPUs
  (here Mali-G610). The GRD backend does RGB→NV12 on panvk.
- **Mali-G610** — the RK3588 GPU; the transfer/precision work targets its
  Valhall/Bifrost path.
- **AFBC** — Arm FrameBuffer Compression. Compute shaders **cannot write AFBC
  destinations**, which is why COMPUTE-only texture transfer was rejected in review.
- **u_blitter** — Mesa's shared blit helper; the `gl_FragCoord` fix for unscaled
  TXF blits is shared across ~10 drivers (MR !42679).
- **BLIT vs COMPUTE transfer** — the two texture-transfer directions; BLIT was
  selected on-device. See [`docs/blit-precision.md`](docs/blit-precision.md).
- **gl_FragCoord / TXF** — the fragment-position fix for unscaled texel fetch blits
  (the on-device-selected correction).
- **MR stack** — the 4-MR upstream series (!42563 → !42679 → !42613 → !42614);
  state is tracked in the [`../../status.md`](../../status.md) watchlist.
