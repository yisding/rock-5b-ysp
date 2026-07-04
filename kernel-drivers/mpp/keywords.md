# kernel-drivers/mpp — keywords

MPP service + codec-core terms. Cross-cutting vocabulary is in
[`../../glossary.md`](../../glossary.md).

- **MPP** — Rockchip Media Process Platform; the vendor hardware-codec framework
  reached via `/dev/mpp_service` (not V4L2).
- **mpp_srv / mpp_service** — the shared service DT node and the char device every
  core attaches to (`rockchip,srv`).
- **VEPU580 / `rkvenc2`** — the H.264/H.265 hardware encoder and its driver; two
  cores `fdbd0000`/`fdbe0000`.
- **VDPU381 / `rkvdec2`** — the H.264/H.265/VP9 hardware decoder and its driver;
  two cores plus a real CCU block.
- **DCHS** — dual-core hand-shake: the encoder's *software-only* equivalent of the
  decoder's hardware CCU (the encoder has no CCU register block).
- **link mode** — the decoder's descriptor-table job chaining (hardware walks a
  linked table of task configs); distinct from RCB.
- **soft / hard CCU** — the decoder CCU's two dispatch modes (`rockchip,ccu-mode`):
  soft = driver picks the core (shipped default); hard = CCU hardware dispatches.
- **taskqueue / core-mask** — a cluster's work queue and the DT bitmask naming its
  cores.
- **DPB** — Decoded Picture Buffer; the per-stream reference dependency that
  forbids splitting one decode stream across cores. See
  [`docs/multicore-scheduling.md`](docs/multicore-scheduling.md).
