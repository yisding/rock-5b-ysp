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
| Current state | This directory owns stable comparisons, not the moving install recommendation. [`../status.md`](../status.md) tracks the dated forward-port and maximum-mainline state; the kernel scorecard [`../kernel-drivers/docs/forward-port-status.md`](../kernel-drivers/docs/forward-port-status.md) preserves the deeper validation boundary. A successful maximum-mainline build is not evidence that it booted on the board. |

## Kernel and media models in this repository

The version number is only one axis. A useful kernel identity also names the
media API, driver lineage, device-tree shape, delivery path, and validation
scope:

| Name used here | Kernel/base role | Media-driver model | DT/package consequence | Read next |
|----------------|------------------|--------------------|------------------------|-----------|
| Rockchip 6.1 BSP | Downstream donor and architectural reference | Vendor MPP/RGA plus Rockchip's broader downstream subsystem set | Source of the ported implementation and many compatibility assumptions; not the target image by itself | [`bsp/`](bsp/README.md) |
| Armbian 6.18 forward port | Main operating/investigation base | BSP-derived `/dev/mpp_service` and `/dev/rga` carried onto 6.18 | Combined builds convert Armbian's decoder nodes in place; DKMS uses a boot-time overlay; local and PPA combined packages remain distinct delivery/evidence paths | [`docs/vendor-forward-port.md`](docs/vendor-forward-port.md), [`../install.md`](../install.md) |
| Vanilla 6.18 + forward port | Pristine upstream base at the port's original patch target | Same vendor MPP/RGA implementation | Driver patch carries over, but decoder/CCU/IOMMU nodes must be defined inline rather than inherited from Armbian | [`docs/vanilla-kernel.md`](docs/vanilla-kernel.md) |
| Mainline V4L2 | Upstream codec API trajectory | Stateless V4L2 request decode, not Rockchip MPP | Different device ABI, userspace responsibility, and scheduler constraints; cannot be reasoned about as a drop-in MPP implementation | [`docs/mainline-rkvdec-v4l2.md`](docs/mainline-rkvdec-v4l2.md) |
| Clean-room rewrite | Alternative implementation of the existing MPP/RGA public ABI | Repo-designed kernel internals behind compatible device contracts, including RKVENC2, RKVDEC2, RGA2/3, and a source-only VPU981 AV1 backend | Exists on maintained 6.18 and mainline-oriented branches with byte-identical tracked rewrite sources. Current-tip normal builds pass, but hardware qualification is open; the documented cluster/activation/task-execution split is a target, not current code. | [`../kernel-drivers/docs/rewrite-driver-architecture/`](../kernel-drivers/docs/rewrite-driver-architecture/README.md) |
| Maximum-mainline profiles | Pinned integration of upstream plus selected public/WIP RK3588 proposals | Whatever the pinned mainline proposal set provides; not automatically the vendor media stack | Reproducible comparison packages; build success and board/runtime proof remain separate gates | [`../packaging/ppa/kernel-maxline/`](../packaging/ppa/kernel-maxline/README.md) |

### Five labels to attach to every kernel result

| Axis | Example question |
|------|------------------|
| Base and exact source | Which upstream/BSP/Armbian commit and patch series produced it? |
| Media API and implementation | Vendor MPP/RGA, clean-room-compatible rewrite, or mainline V4L2? |
| Device tree | Convert-in-place, complete inline nodes, or overrides of nodes already supplied by newer mainline? |
| Delivery identity | Local Armbian flavor/PHASH, PPA package version, DKMS+overlay, or direct vanilla build? |
| Evidence boundary | Built, packaged, installed, booted, functionally exercised, log-clean, and rollback-tested—which of these actually happened? |

Two kernels with the same `uname -r` prefix can differ on every other axis.
Conversely, the same driver design can be tested on more than one kernel base.
Use [`../docs/system-baseline.md`](../docs/system-baseline.md) for the capture
shape and [`../status.md`](../status.md) for the latest dated result.

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
