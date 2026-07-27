# Rewrite-driver architecture: a kernel-driver learning guide

This is a beginner-oriented tour of two Linux drivers for the Rockchip RK3588.
It assumes that you can read C, but it does not assume that you already know
how a platform driver, an ioctl, DMA, an IOMMU, an interrupt, a workqueue, or a
reference count fit together. Those terms are introduced at the point where
the driver needs them.

## What “rewrite kernel” means

The project often says **rewrite kernel** as shorthand. Linux itself was not
rewritten. The kernel is an otherwise normal Linux kernel in which two
Rockchip vendor-driver stacks are replaced:

| Replacement driver | Device file kept compatible | Hardware controlled |
|--------------------|-----------------------------|---------------------|
| `mpp-rewrite` | `/dev/mpp_service` | RK3588 RKVENC2 video encoders and RKVDEC2 video decoders |
| `rga-rewrite` | `/dev/rga` | RK3588 RGA2 and RGA3 2D image engines |

Applications still call the same userspace libraries. FFmpeg or GStreamer
calls `librockchip_mpp` for video work or `librga` for image work; the library
opens the familiar device file and sends the familiar ioctls. The change is
below that device-file boundary:

```text
application
  -> FFmpeg / GStreamer / direct test
  -> librockchip_mpp or librga
  -> ioctl on /dev/mpp_service or /dev/rga
  -> rewrite driver
  -> RK3588 hardware
```

The forward-port kernel takes the opposite approach: it carries the existing
Rockchip BSP drivers into a newer kernel with small compatibility changes. The
rewrite starts again from the documented userspace contract and uses public
kernel APIs. Only one implementation may own each hardware/device-file family
in a build. The comparison profiles select the forward-port pair or rewrite
pair; they cannot A/B the same device node during one boot.

That distinction explains the project goals:

- **Compatibility:** keep current Rockchip Linux media applications working
  without changing their device-file ABI.
- **Safety:** make buffer, job, hardware, interrupt, timeout, and teardown
  ownership explicit.
- **Maintainability:** use public Linux driver APIs instead of private BSP
  helpers.
- **Learning:** provide a smaller conceptual model for studying asynchronous
  DMA drivers.

It also explains what this is not. It is not an upstream submission, not a new
userspace API, not a rewrite of the codec libraries, and not a claim that every
historical Rockchip hardware block or legacy ioctl must be supported.

## Current status

This guide describes the sources committed on 2026-07-27:

| Kernel branch | Commit |
|---------------|--------|
| `rk3588-rewrite-6.18` | `835b19f81d2b` |
| `rk3588-rewrite-mainline` | `79a804a26e00` |

The commits contain byte-identical rewrite driver and ABI sources:

```text
drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c
drivers/video/rockchip/mpp-rewrite/ABI.rst
drivers/video/rockchip/rga-rewrite/rga_rewrite.c
drivers/video/rockchip/rga-rewrite/ABI.rst
```

The surrounding kernel and device-tree integration differ. The current
evidence is:

| Area | What exists now | What that proves |
|------|-----------------|------------------|
| Driver code | MPP and RGA implementations on both kernel branches | The same driver design is maintained on the 6.18 and current-mainline tracks. |
| ABI coverage | MPP covers the observed RK3588 RKVENC2/RKVDEC2 contract; RGA covers a broad current `librga`/FFmpeg/GStreamer subset and explicitly rejects recognized unsafe or unimplemented paths | Expected current requests can be parsed and represented; an explicit rejection is preferable to silently misprogramming hardware. |
| In-source tests | 85 MPP and 148 RGA KUnit cases, 233 total | Pure logic such as parsing, bounds, routing, register emission, IRQ policy, and race-state transitions has executable coverage without requiring the board. |
| Build evidence | On 2026-07-27 the normal clean-archive profile passed without compiler warnings at both cited tips; historical normal, memory-safety, and race profiles passed at the preceding defect-audit tips | Both current branches build the IOMMU provider, KUnit-enabled rewrite objects, and ROCK 5B DTB. A build is not hardware proof. |
| Latest recovery work | Generation-aware timeout/fault ownership, stricter CCU recovery, close/remove handoffs, and fail-closed MPP containment when a reset cannot prove that DMA stopped | The code has a defined terminal branch for dangerous recovery failures instead of assuming reset always works. |
| Bootable debug image | Historical Armbian KASAN/lockdep images package both rewrites and their KUnit suites; package-config inspection confirms all four rewrite/KUnit symbols | Packaging is proven for earlier tips. The current final-fixture/isolation tips have not yet been packaged or booted. |
| Hardware evidence | Build `#6` passes 85/85 MPP plus 148/148 RGA and binds RGA2 plus both RGA3 cores, but exposes the final two capped stack-fixture reports; their fix and KUnit/live-service isolation are compile-verified only | KUnit is real board evidence rather than unexecuted scaffold, but a warning-clean current-tip boot and media conformance are still required. |
| Published alpha packages | Existing published rewrite package composites predate the current source tips | Those packages must not be treated as evidence for the code described here. |

The practical hardware scope is deliberately narrower than every name a
userspace library can advertise:

| Path | Rewrite scope |
|------|---------------|
| H.264/H.265 encode and decode | Required RKVENC2/RKVDEC2 paths |
| VP9 decode | Required decoder-parity path, still awaiting current-tip hardware evidence |
| AV1 through RKMPP | Not in this rewrite; RK3588 AV1 uses a separate hardware block, IOMMU, and backend |
| Older VDPU/VPU and JPEG blocks | Outside the current ROCK 5B rewrite profile |
| RGA | Current Linux `librga`, FFmpeg, GStreamer, RKNN/RKNPU preprocessing, and common display-shaped operations covered by the ABI ledger |
| Raw physical imports and unsupported legacy/RGA2-Pro modes | Rejected rather than accepted without safe ownership and command-emission support |

The image and hardware-evidence rows are the important boundary. KUnit can
prove that a function rejects an overflowing address or that only one simulated
completion path wins. It cannot prove that a register recipe makes real silicon
produce the correct pixels, that an interrupt arrives, or that a reset stops a
wedged DMA engine. Those claims require installing and booting the current-tip
image on a ROCK 5B, followed by the differential and fault-injection gates in
the [rewrite validation plan](../rewrite-validation-plan.md).

Until that evidence exists, the hardware-validated forward port remains the
runtime baseline. The rewrite is best described as **advanced bring-up with a
detailed safety architecture**, not production-ready hardware enablement.

Use [rewrite drivers](../rewrite-drivers.md) for the command-by-command ABI
ledger, [device tree](../device-tree.md) for the RK3588 hardware wiring, and
the [rewrite validation plan](../rewrite-validation-plan.md) for the
production qualification plan. This guide focuses on how the driver code is
organized and why.

## Chapters

| Chapter | What it covers |
|---------|----------------|
| [0. Kernel development primer](00-kernel-development-primer.md) | Kernel versus userspace, execution contexts, locks and references, address spaces and DMA, uAPI, hardware access, kernel C idioms, error handling, source navigation, and a safe first-change workflow |
| [1. Ownership and Linux driver foundations](01-foundations.md) | One complete submission, service/session/job/hardware lifetimes, trust boundaries, platform and misc devices, probe, power, IRQ contexts, and public APIs |
| [2. MPP rewrite driver](02-mpp-driver.md) | Message collection, register jobs, DMA-BUF translation, scheduling, encoder/decoder backends, completion, recovery, isolation, and locks |
| [3. RGA rewrite driver](03-rga-driver.md) | Semantic image requests, imports and mappings, USERPTR, layout validation, fences, core selection, command emission, completion, close, and removal |
| [4. Design and error-path lessons](04-design-lessons.md) | Cross-driver comparison, ownership tables, asynchronous edges, completion claims, recovery state machines, topology, errors, and unwind patterns |
| [5. Observability and testing](05-observability-and-testing.md) | Debug counters, the 233-case KUnit split, the evidence ladder, build gates, and remaining hardware validation |
| [6. Source reading and review](06-source-reading-and-review.md) | Suggested source-reading order, review checklist, expanded glossary, and the final invariant |

Developers without kernel experience should read chapters 0 and 1, then the MPP
or RGA chapter, followed by chapter 4. Chapters 5 and 6 are useful when testing
or reviewing changes. If a term is unfamiliar, the
[glossary](06-source-reading-and-review.md#12-glossary) is available without
having to scroll through the implementation chapters.

[Next: kernel development primer →](00-kernel-development-primer.md)
