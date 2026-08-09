# Rewrite-driver architecture: a kernel-driver learning guide

Beginner-oriented, source-level tour of the RK3588 MPP and RGA rewrite drivers.
It assumes C familiarity, but introduces platform drivers, ioctls, DMA, IOMMUs,
interrupts, workqueues, and references where the implementation needs them.

This is a teaching guide, not a status ledger. It explains the as-built
ownership model and the distinct target architecture. The
[design chapter](04-design-lessons.md#61-as-built-strengths-and-remaining-ownership-debt)
and [ownership-refactor plan](../rewrite-ownership-refactor-plan.md) distinguish
implemented objects from proposed ones.

## What “rewrite kernel” means

Linux itself was not rewritten. Two Rockchip vendor-driver stacks are replaced
while keeping their userspace device-file contracts:

| Replacement driver | Compatible device file | Hardware |
|--------------------|------------------------|----------|
| `mpp-rewrite` | `/dev/mpp_service` | RK3588 RKVENC2, RKVDEC2, and separate VPU981/VSI AV1 decoder |
| `rga-rewrite` | `/dev/rga` | RK3588 RGA2 and RGA3 image engines |

The boundary is:

```text
application
  -> FFmpeg / GStreamer / direct test
  -> librockchip_mpp or librga
  -> ioctl on /dev/mpp_service or /dev/rga
  -> rewrite driver
  -> RK3588 hardware
```

The forward-port carries BSP drivers into a newer kernel with compatibility and
safety changes. The rewrite starts from the observed userspace contract and
public kernel APIs. Only one implementation may own each hardware/device-file
family in a build, so comparison requires separate boots.

The project goals are stable:

- **Compatibility:** preserve the supported Rockchip Linux media ABI.
- **Safety:** make buffer, job, hardware, interrupt, timeout, and teardown
  ownership explicit.
- **Maintainability:** use public Linux driver APIs instead of private BSP
  helpers.
- **Learning:** expose a tractable model of asynchronous DMA drivers.

This is not an upstream submission, new userspace API, codec-library rewrite,
or promise to support every historical Rockchip block and ioctl. “Clean-room”
means an independent implementation rather than a BSP source port; the exact
provenance boundary lives in
[rewrite drivers](../rewrite-drivers.md#what-clean-room-does-and-does-not-mean-here).

## Current status

Mutable qualification state deliberately lives outside this teaching guide:

| Question | Owner |
|----------|-------|
| What can users rely on now, and what one proof is next? | [`status.md` track 4](../../../status.md#dashboard) |
| Which exact source/package and accumulated results support that boundary? | [`rewrite-drivers.md` §6](../rewrite-drivers.md#6-status--citable-location) |
| Which immutable snapshots make citations reproducible? | [source map §8](../../../docs/source-trees.md#8-rewrite-driver-tree) |
| What must be proven before production use? | [rewrite validation plan](../rewrite-validation-plan.md) |
| How are build, KUnit, consumer, differential, and hostile gates run? | [rewrite conformance entry](../../tests/conformance.md) |

The source-level model in these chapters uses four primary implementation
files:

```text
drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c
drivers/video/rockchip/mpp-rewrite/ABI.rst
drivers/video/rockchip/rga-rewrite/rga_rewrite.c
drivers/video/rockchip/rga-rewrite/ABI.rst
```

Surrounding kernel and device-tree integration differs across kernel lines.
The durable architectural boundary is:

| Area | Teaching scope |
|------|----------------|
| Driver objects | service/session/job/import/hardware ownership, scheduling, completion, recovery, and teardown |
| ABI | supported MPP/RGA command and request shapes plus explicit unsafe or unimplemented rejections |
| In-source tests | how pure parsing, bounds, routing, register emission, IRQ policy, and race-state transitions are modeled |
| Hardware evidence | why compilation and KUnit cannot establish real pixels, bitstreams, IRQ wiring, DMA behavior, or reset effectiveness |
| Target ownership | the MPP cluster owns topology and hard-CCU reset-pulse validation, and a refcounted cluster lease owns member-core power holds; Phase 3A–G establish retained activation identity, exact slot/dispatch ownership, fresh retry successors, and typed retry-predecessor proof; Phase 3H gives the active claim token its exact job reference, retires recovered terminals on typed core or group/core proof, and transfers restore refusal into a reboot-bound service quarantine owner. Phase 3I retires exact clean claims only after immutable `NOT_PUBLISHED`, `IRQ_ACCEPTED`, or `CCU_DONE_ACCEPTED` observation; RKVDEC bus-idle status is advisory and recovered proof remains separate. `RECLAIMABLE`, resource drain, final outcome arbitration, RGA task-execution/acquire-set objects, and cluster admission/coordinator-power/full-recovery authority remain refactor goals rather than current behavior claims |

The practical design scope includes RKVENC2/RKVDEC2 H.264/H.265, decoder-parity
VP9, the separate VPU981/VSI AV1 path, and the Linux librga/FFmpeg/GStreamer
RGA operations admitted by the ABI ledger. Older codec blocks, raw physical
imports, and unsupported legacy/RGA2-Pro modes stay outside the profile or are
rejected rather than accepted without a safe ownership and command-emission
model. The maintained project evidence owns which of those paths have hardware
proof.

## Chapters

| Chapter | What it covers |
|---------|----------------|
| [0. Kernel development primer](00-kernel-development-primer.md) | Kernel versus userspace, execution contexts, locks/references, address spaces/DMA, uAPI, hardware access, kernel C, error handling, source navigation, and a safe first-change workflow |
| [1. Ownership and Linux driver foundations](01-foundations.md) | One submission, service/session/job/hardware lifetimes, trust boundaries, platform/misc devices, probe, power, IRQ contexts, and public APIs |
| [2. MPP rewrite driver](02-mpp-driver.md) | Message collection, register jobs, DMA-BUF translation, scheduling, backends, completion, recovery, isolation, and locks |
| [3. RGA rewrite driver](03-rga-driver.md) | Requests, imports/mappings, USERPTR, layout validation, fences, core selection, command emission, completion, close, and removal |
| [4. Design and error-path lessons](04-design-lessons.md) | Ownership tables, asynchronous edges, completion claims, recovery state machines, topology, errors, unwind patterns, and target objects |
| [5. Observability and testing](05-observability-and-testing.md) | Debug counters, evidence levels, KUnit's role, and hardware-proof boundaries |
| [6. Source reading and review](06-source-reading-and-review.md) | Source-reading order, review checklist, glossary, and final invariant |

Developers new to kernel work should read chapters 0 and 1, then the MPP or RGA
chapter, followed by chapter 4. Chapters 5 and 6 support testing and review.
The [glossary](06-source-reading-and-review.md#12-glossary) is available
independently.

[Next: kernel development primer →](00-kernel-development-primer.md)
