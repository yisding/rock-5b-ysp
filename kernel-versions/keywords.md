# kernel-versions — keywords

Terms you most need when reasoning about kernel bases and forward-porting.
Cross-cutting vocabulary lives in [`../glossary.md`](../glossary.md).

- **BSP** — Rockchip's Board Support Package kernel (the 6.1 vendor tree). The
  source of the MPP/RGA drivers this repo forward-ports. What it adds vs stock is
  cataloged in [`bsp/`](bsp/README.md).
- **forward-port** — carrying the 6.1-BSP drivers onto Linux 6.18 with
  compatibility shims and RK3588 bring-up fixes. Narrative:
  [`docs/vendor-forward-port.md`](docs/vendor-forward-port.md).
- **Armbian** — the Debian/Ubuntu-based build framework the ROCK 5B kernel is
  built from (`github.com/armbian/build`); the port ships as *userpatches*
  against it.
- **vanilla / mainline** — a from-upstream kernel without the BSP overlay. The
  trade-offs of running the port there: [`docs/vanilla-kernel.md`](docs/vanilla-kernel.md).
- **V4L2 / mem2mem / Request API** — the mainline codec API, its single-execution
  m2m scheduler, and the per-frame control-submission API. The port deliberately
  does **not** use V4L2 for its shipped path; the mainline `rkvdec` V4L2 decoder
  itself is in [`docs/mainline-rkvdec-v4l2.md`](docs/mainline-rkvdec-v4l2.md).
- **media-0001** — Armbian's backport patch adding the V4L2 `vdec` DT nodes the
  port converts in place. See [`../glossary.md`](../glossary.md).
- **combined kernel vs DKMS** — the two delivery bases: drivers built in (`=y`)
  vs out-of-tree modules on a stock kernel. Chooser: [`../install.md`](../install.md).
- **resync** — updating the port to a newer kernel/BSP. Playbook lives with the
  drivers: [`../kernel-drivers/docs/resyncing.md`](../kernel-drivers/docs/resyncing.md).
