# kernel-versions/ — the kernel bases and moving between them

What the different kernel bases are (Armbian 6.18, the Rockchip 6.1 BSP, and
mainline/vanilla), what the Rockchip BSP adds on top of stock Linux, and how the
drivers are forward-ported between versions. The kernel source lives in the
sibling trees (`linux-6.18-rkvenc*`, `rockchip-kernel`, `radxa-kernel`); this
project holds the base-level explanation and the forward-port narrative.

The concrete driver work — MPP/RGA architecture, patches, scripts, tests — is in
[`../kernel-drivers/`](../kernel-drivers/README.md). The resync **playbook**
(`resyncing.md`) is driver maintenance and lives there.

## Project brief

| Field | Contents |
|-------|----------|
| Purpose | Understand which kernel a build targets, what the BSP overlay adds, and why the port uses the vendor MPP stack instead of mainline V4L2. |
| Developer focus | The 6.1-BSP → 6.18 forward-port deltas, adversarial review of the glue, the mainline V4L2 `rkvdec` trajectory, and the pinned maximum-mainline comparison build. |
| Owns | The `bsp/` subtree and the base-level docs below; the concrete maximum-mainline build artifacts live under packaging and are linked from this front door. |
| Depends on | Nothing in-repo; upstream Armbian, Rockchip BSP, and mainline kernel trees. |
| Current state | Target base is Armbian `rockchip64-current` 6.18. The July 4 build remains the validated baseline; the maintained 6.18.38 forward-port has newer KASAN-verified fixes but incomplete production conformance. See [`../status.md`](../status.md) and the kernel scorecard [`../kernel-drivers/docs/forward-port-status.md`](../kernel-drivers/docs/forward-port-status.md). |

## Files

| Path | One-liner |
|------|-----------|
| [`bsp/`](bsp/README.md) | What the Rockchip 6.1 BSP kernel adds vs stock Linux — area-by-area (SoC, firmware/boot, media/RGA, camera/ISP, display, memory/dma-buf, GPU/NPU, storage, connectivity, common behavior, userspace ABI), with diagrams. |
| [`docs/vendor-forward-port.md`](docs/vendor-forward-port.md) | What changed carrying the 6.1 BSP MPP/RGA drivers to 6.18. |
| [`docs/forward-port-review-log.md`](docs/forward-port-review-log.md) | Adversarial review of the forward-port glue. |
| [`docs/vanilla-kernel.md`](docs/vanilla-kernel.md) | Applying the port to a non-Armbian/mainline kernel; owner of the "why vendor MPP, not mainline V4L2" rationale. |
| [`docs/mainline-rkvdec-v4l2.md`](docs/mainline-rkvdec-v4l2.md) | How the mainline V4L2 `rkvdec` decoder (the other stack) works, and the `rk3588-rewrite-mainline` branch. |
| [`docs/pvtm-opp-binning-plan.md`](docs/pvtm-opp-binning-plan.md) | Two-track plan (vendor straight port + mainline-ready series) for the RK3588 per-die CPU voltage binning mainline lacks. Design only; nothing started. |
| [`../packaging/ppa/kernel-maxline/`](../packaging/ppa/kernel-maxline/README.md) | Pinned upstream 7.2-rc3 `public`/`wip` maximum-mainline integrations, board-support comparison, reproducible packages, compile evidence, and the still-open boot/hardware boundary. |

Vocabulary specific to this project is in [`keywords.md`](keywords.md).
