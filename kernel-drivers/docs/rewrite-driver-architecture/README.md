# Rewrite-driver architecture: a kernel-driver learning guide

This is a beginner-oriented, source-level tour of two Linux drivers for the
Rockchip RK3588. It assumes that you can read C, but it does not assume that you
already know how a platform driver, an ioctl, DMA, an IOMMU, an interrupt, a
workqueue, or a reference count fit together. Those terms are introduced at
the point where the driver needs them.

The guide describes the **as-built implementation** first. It also names the
next architecture explicitly, because the two must not be confused: the
current code has clear session/job/import ownership, but shared MPP recovery
and per-task RGA execution still live in broader objects than the design now
calls for. The [design chapter](04-design-lessons.md#61-as-built-strengths-and-remaining-ownership-debt)
and [ownership-refactor plan](../rewrite-ownership-refactor-plan.md) distinguish
implemented objects from proposed ones.

## What “rewrite kernel” means

The project often says **rewrite kernel** as shorthand. Linux itself was not
rewritten. The kernel is an otherwise normal Linux kernel in which two
Rockchip vendor-driver stacks are replaced:

| Replacement driver | Device file kept compatible | Hardware controlled |
|--------------------|-----------------------------|---------------------|
| `mpp-rewrite` | `/dev/mpp_service` | RK3588 RKVENC2 encoders, RKVDEC2 decoders, and the separate VPU981/VSI AV1 decoder |
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
historical Rockchip hardware block or legacy ioctl must be supported. The track
name “clean-room” means an independent implementation rather than a BSP source
port; the exact provenance boundary is documented in
[rewrite drivers](../rewrite-drivers.md#what-clean-room-does-and-does-not-mean-here).

## Current status

This guide describes the maintained sources checked on 2026-08-04:

| Kernel branch | Commit |
|---------------|--------|
| `rk3588-rewrite-6.18` | `19634f4eebba` on `v6.18.42` |
| `rk3588-rewrite-mainline` | `b296374b7520` on `v7.2-rc6` |

The commits contain byte-identical rewrite driver, Kconfig, ABI, and shared
MPP-uAPI sources. The two implementation files are:

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
| Driver code | MPP and RGA implementations on both kernel branches, including the source-only RKMPP AV1 backend | The same driver design is maintained on the 6.18 and current-mainline tracks. Source parity is not hardware parity. |
| ABI coverage | MPP covers the observed RK3588 RKVENC2/RKVDEC2/VPU981 contract; RGA covers a broad current `librga`/FFmpeg/GStreamer subset and explicitly rejects recognized unsafe or unimplemented paths | Expected current requests can be parsed and represented; an explicit rejection is preferable to silently misprogramming hardware. |
| In-source tests | 92 MPP and 152 RGA KUnit cases, 244 total | Pure logic such as parsing, bounds, routing, register emission, IRQ policy, and race-state transitions has executable coverage without requiring the board. |
| Build evidence | On 2026-08-04 the KUnit-enabled normal clean-archive profile passed at 6.18 `19634f4eebba` and mainline `b296374b7520`, building both IOMMU providers, both rewrite objects, and the ROCK 5B DTB without warnings. The 305-signal fixture audit and the 92+152 manifest check also passed on both. Range comparison maps 384/384 retained 6.18 commits and 310/310 mainline commits exactly; the only omitted 6.18 commit was a libbpf fix already upstream. Test-disabled, memory, race, and ABI-mutation evidence remains attached to earlier tips. | The current production and test code compiles on both bases. It does not prove boot, KUnit execution, or hardware behavior. |
| Latest recovery work | Generation-aware timeout/fault ownership, stricter CCU recovery, close/remove handoffs, and fail-closed MPP containment when a reset cannot prove that DMA stopped | The code has a defined terminal branch for dangerous recovery failures instead of assuming reset always works. |
| Architecture maturity | Session/job/import ownership, exact active-slot claims, provider callback drains, fail-closed reset handling, and per-execution DMA mapping exist. Explicit MPP cluster/activation owners, RGA task-execution/acquire-set owners, sealed register/command plans, and one transition engine per active object do not. | The current architecture is auditable but still relies on cross-path conventions at its most complicated shared-hardware boundaries. The proposed object graph is a refactor target, not a description of current types. |
| Hardware evidence | Boot `#29` (`g8042f13c5459`, 2026-08-02) passed exact 89/89 MPP plus 150/150 RGA with live lockdep and no fatal signatures. It predates the August review fixes and the current 92+152 manifest. Package `#30` carries the main review repair, is installed but unbooted, and predates both later tip commits. | KUnit is real board evidence rather than unexecuted scaffold, but the current sources have no boot, AV1, or media-conformance proof. |
| Published alpha packages | Existing published rewrite package composites predate the current source tips | Those packages must not be treated as evidence for the code described here. |

The practical hardware scope is deliberately narrower than every name a
userspace library can advertise:

| Path | Rewrite scope |
|------|---------------|
| H.264/H.265 encode and decode | Required RKVENC2/RKVDEC2 paths |
| VP9 decode | Required decoder-parity path, still awaiting current-tip hardware evidence |
| AV1 through RKMPP | Implemented in source through the separate VPU981 core, VSI-IOMMU provider, and AFBC auxiliary path; no rewrite-kernel hardware result exists |
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
runtime baseline. The rewrite is best described as **advanced bring-up with an
explicit but not yet fully factored ownership model**, not production-ready
hardware enablement.

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
| [5. Observability and testing](05-observability-and-testing.md) | Debug counters, the 244-case KUnit split, the evidence ladder, build gates, and remaining hardware validation |
| [6. Source reading and review](06-source-reading-and-review.md) | Suggested source-reading order, review checklist, expanded glossary, and the final invariant |

Developers without kernel experience should read chapters 0 and 1, then the MPP
or RGA chapter, followed by chapter 4. Chapters 5 and 6 are useful when testing
or reviewing changes. If a term is unfamiliar, the
[glossary](06-source-reading-and-review.md#12-glossary) is available without
having to scroll through the implementation chapters.

[Next: kernel development primer →](00-kernel-development-primer.md)
