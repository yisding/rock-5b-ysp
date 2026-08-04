# kernel-drivers/av1 — keywords

AV1-decode terms. Cross-cutting vocabulary is in [`../../glossary.md`](../../glossary.md).

- **AV1** — the AOMedia Video 1 codec. On RK3588 the AV1 decoder is a distinct
  block from RKVDEC2 (H.264/H.265/VP9); see [`docs/av1-rk3588.md`](docs/av1-rk3588.md).
- **RKVDEC2 vs AV1 decoder** — why the AV1 path is separate and not folded into the
  validated rkvdec2 driver.
- **av1-fwport** — the historical `linux-6.18-rkvenc-av1-fwport` sibling tree
  where the AV1 forward-port began; the backend now belongs to the maintained
  forward-port line.
- **RKMPP AV1 port** — the forward-port work whose bring-up surfaced BSP bugs
  cataloged in [`docs/av1-bsp-audit.md`](docs/av1-bsp-audit.md).
- **AV1 rewrite assessment** — the original bounded plan, implemented source
  shape, and open hardware proof for the separate `MPP_DEVICE_AV1DEC` backend,
  including sparse register classes, 103 built-in fd translations, VSI-IOMMU
  fault integration, checked AFBC programming, and differential validation; see
  [`docs/av1-rewrite-assessment.md`](docs/av1-rewrite-assessment.md).
