# kernel-drivers/rga — keywords

RGA driver terms. Cross-cutting vocabulary is in [`../../glossary.md`](../../glossary.md).

- **RGA3 / RGA2** — Raster Graphic Acceleration, the 2D engine (scale, color
  convert, rotate, blend). RK3588 has two RGA3 cores + one RGA2 core.
- **`/dev/rga`** — the RGA char device; the `rga3/` driver registers `multi_rga`.
- **multi_rga** — the driver front that multiplexes the three cores and picks a
  per-request core profile.
- **IEP** — Image Enhancement Processor, a *separate* BSP post-processing block.
  **This port ships no IEP driver** and `/dev/iep` does not exist on the board;
  the `KERNEL=="iep"` udev line is a harmless no-op.
- **RGA2_GET_VERSION ret=1** — an intentional ABI quirk recorded in the ledgers;
  see [`../docs/dev-uapis.md`](../docs/dev-uapis.md).
- **core profile** — the per-request selection of which RGA core/format path
  handles a job (importable fd vs virtual-address buffers).
