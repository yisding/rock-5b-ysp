# kernel-drivers/ — RK3588 media and accelerator kernel work

The kernel-side work for the ROCK 5B: the vendor Rockchip MPP codec, RGA, and
RKNPU accelerator drivers; their RK3588 device tree; the media audit fix series;
and the media clean-room rewrite track. Driver code lives in sibling kernel
trees (`linux-6.18-rkvenc*`, `rockchip-kernel`); this project holds architecture,
patch deliverables, and on-hardware validation. The RKNPU project also crosses
into the tightly coupled proprietary RKNN compiler/runtime because its kernel
ABI cannot be understood usefully in isolation.

Split into five sub-projects — `mpp`, `rga`, `av1`, `iommu`, `rknpu` — each with its own
`README.md` + `keywords.md`. **Shared** driver architecture, uAPI, device tree,
the combined patch series, board scripts, and on-hardware tests stay at this top
level, because one combined patch series and one architecture doc cover mpp+rga
together. Kernel-base topics (what the BSP adds, forward-porting between kernel
versions, the mainline-V4L2 alternative) live in
[`../kernel-versions/`](../kernel-versions/README.md).

## Project brief

| Field | Contents |
|-------|----------|
| Purpose | Explain and validate the RK3588 media and NPU accelerator paths: MPP encode/decode, RGA jobs, and RKNN inference through RKNPU. |
| Developer focus | Accelerator service/submit models, dma-buf/IOMMU lifetime, device-tree wiring, runtime ABIs, forward-port deltas, audits, and rewrite alternatives where applicable. |
| Owns | Shared kernel docs in [`docs/`](docs/how-the-drivers-work.md); the five sub-projects; patch deliverables in [`patches/`](patches/README.md); board scripts in [`scripts/`](scripts/README.md); hardware smoke tests in [`tests/`](tests/README.md). |
| Depends on | Armbian or vanilla 6.18 kernel build inputs, RK3588 device tree, and [`../vendor-libraries/`](../vendor-libraries/README.md). |
| Current state | The forward-port, BSP-audit, DKMS, and rewrite tracks have different evidence boundaries and are not interchangeable kernels. [`../status.md`](../status.md) tracks their latest board result and next gate; [`docs/forward-port-status.md`](docs/forward-port-status.md) is the detailed kernel scorecard. Read those before treating an older green conformance run as an install recommendation. |

## How the kernel package fits

```mermaid
flowchart TB
  app["FFmpeg, GRD, tests"]
  libs["librockchip_mpp / librga"]
  nnapp["RKNN model / C or Python app"]
  rknn["RKNN Toolkit2 / librknnrt"]
  devs["/dev/mpp_service<br/>/dev/rga"]
  npudev["DRM render node<br/>or /dev/rknpu"]
  service["MPP service core<br/>sessions, tasks, IOMMU"]
  codec["rkvenc2 / rkvdec2<br/>VEPU580 + VDPU381"]
  rga["RGA3 + RGA2<br/>2D jobs"]
  npu["RKNPU<br/>memory, queues, IOMMU, PM"]
  dt["RK3588 device tree<br/>clocks, IRQs, IOMMUs, SRAM"]
  hw["ROCK 5B hardware"]

  app --> libs --> devs
  devs --> service --> codec --> hw
  devs --> rga --> hw
  nnapp --> rknn --> npudev --> npu --> hw
  dt -. binds .-> service
  dt -. binds .-> rga
  dt -. binds .-> npu
```

## Sub-projects

| Sub-project | Covers | Scoped docs |
|-------------|--------|-------------|
| [`mpp/`](mpp/README.md) | The MPP service + rkvenc2/rkvdec2 codec cores; multi-core scheduling. | [`multicore-scheduling.md`](mpp/docs/multicore-scheduling.md) |
| [`rga/`](rga/README.md) | The RGA3/RGA2 2D blit/scale/convert driver. | [`userptr-iommu.md`](rga/docs/userptr-iommu.md), [`raw-physical-import-crash.md`](rga/docs/raw-physical-import-crash.md), [`rewrite-5.10-reconciliation.md`](rga/docs/rewrite-5.10-reconciliation.md), [`userspace-consumers.md`](rga/docs/userspace-consumers.md) |
| [`av1/`](av1/README.md) | The RK3588 AV1 decode path and the BSP bugs the AV1 port exposed. | [`av1-rk3588.md`](av1/docs/av1-rk3588.md), [`av1-bsp-audit.md`](av1/docs/av1-bsp-audit.md) |
| [`iommu/`](iommu/README.md) | CCU/IOMMU memory path: the net-new MMU plan and the SOFT/HARD CCU rewrite finding. | [`mpp-ccu-iommu-plan.md`](iommu/docs/mpp-ccu-iommu-plan.md), [`rewrite-hard-ccu-finding.md`](iommu/docs/rewrite-hard-ccu-finding.md) |
| [`rknpu/`](rknpu/README.md) | End-to-end RKNN conversion/runtime and RKNPU memory, submission, multicore, IOMMU, SRAM, PM, and recovery. | [`how-rknpu-works.md`](rknpu/docs/how-rknpu-works.md) |

The kernel work runs on three tracks across those sub-projects:

| Track | What it is | Read next |
|-------|------------|-----------|
| Forward-port | Rockchip 6.1 BSP MPP + RGA drivers carried to Linux 6.18, AV1 decode included. One maintained series carries the port: 75 files, contiguous `0001`–`0075`. The frozen two-patch pair is the superseded July 4 import kept for DKMS and provenance. Scope boundary — ported/unported blocks, deliberate non-support decisions, and where we are ahead of the BSP — in [`docs/forward-port-scope.md`](docs/forward-port-scope.md). | [`patches/`](patches/README.md), [`docs/forward-port-scope.md`](docs/forward-port-scope.md), [`docs/patch-catalog.md`](docs/patch-catalog.md), [`../kernel-versions/docs/vendor-forward-port.md`](../kernel-versions/docs/vendor-forward-port.md), [`docs/vendor-delta.md`](docs/vendor-delta.md), [`docs/bsp-6.1-6.6-comparison.md`](docs/bsp-6.1-6.6-comparison.md) |
| Audit fixes | A reviewable 65-patch correctness/security cleanup series on top of the forward-port. | [`docs/bsp-audit.md`](docs/bsp-audit.md), [`patches/cleanup-split/`](patches/cleanup-split/README.md) |
| Rewrite drivers | Public-API-only reimplementations of `/dev/mpp_service` and `/dev/rga`, as a learning + upstreamable-design track. | [`docs/driver-architecture-comparison.md`](docs/driver-architecture-comparison.md), [`docs/rewrite-driver-architecture/`](docs/rewrite-driver-architecture/README.md), [`docs/rewrite-drivers.md`](docs/rewrite-drivers.md) |

## User path

If your goal is "make hardware codecs work on my board", do not start by reading
patch internals.

1. Read [`../status.md`](../status.md) tracks 1, 3, 4, and 9. A dated pass proves
   that exact run; it does not supersede a later incident or an open rollback
   gate.
2. Choose a delivery path in [`../install.md`](../install.md), and complete its
   recovery preparation before modifying `/boot`.
3. Use [`../packaging/ppa/kernel-forward-port/`](../packaging/ppa/kernel-forward-port/README.md)
   for the prebuilt path, [`scripts/`](scripts/README.md) for a newer/debug
   combined build, or [`../packaging/dkms/`](../packaging/dkms/README.md) only
   within the validation limits shown in the status dashboard.
4. Install the device-node rule from
   [`scripts/99-rockchip-codec.rules`](scripts/99-rockchip-codec.rules) or
   [`../packaging/codec-udev/`](../packaging/codec-udev/README.md).
5. Run [`scripts/validate-combined.sh`](scripts/validate-combined.sh) and then the
   on-hardware tests in [`tests/`](tests/README.md).
6. Move up to FFmpeg or GRD through
   [`../video-libraries/ffmpeg/`](../video-libraries/ffmpeg/README.md) or
   [`../apps/gnome-remote-desktop/`](../apps/gnome-remote-desktop/README.md).

## Developer path

Read in this order when changing or reviewing kernel behavior:

| Question | Canonical doc |
|----------|---------------|
| What does each driver layer do? | [`docs/how-the-drivers-work.md`](docs/how-the-drivers-work.md) |
| What has debugging established about the video *hardware* itself — gating, resets, interrupts, and why some failures leave no trace? | [`docs/rk3588-video-hardware-behaviour.md`](docs/rk3588-video-hardware-behaviour.md) |
| How do the BSP-derived and rewrite MPP/RGA architectures differ, and what are their pros and cons? | [`docs/driver-architecture-comparison.md`](docs/driver-architecture-comparison.md) |
| How are the rewrite drivers structured, synchronized, and made safe to tear down? | [`docs/rewrite-driver-architecture/`](docs/rewrite-driver-architecture/README.md) |
| How do the rewrite drivers use KUnit, and how is a booted result judged? | [`docs/rewrite-kunit.md`](docs/rewrite-kunit.md) |
| How should the rewrite KUnit suites be reduced and made fixture-safe? | [`docs/rewrite-kunit-rationalization-plan.md`](docs/rewrite-kunit-rationalization-plan.md) |
| How do the rewrite IRQ paths become minimal hard handlers (RT-nesting clean)? | [`docs/rewrite-minimal-hard-irq-plan.md`](docs/rewrite-minimal-hard-irq-plan.md) |
| How are these drivers tested — what's proven per track, and what's left? | [`docs/validation-index.md`](docs/validation-index.md) (entry point / coverage matrix) |
| How do I build any of the four local kernel flavors? | [`docs/kernel-builds.md`](docs/kernel-builds.md) |
| How is a newly built or booted kernel validated, end to end? | [`docs/kernel-validation-runbook.md`](docs/kernel-validation-runbook.md) |
| How do I reproduce the GRD/RKMPP system-heap scatterlist oops, and what do I do if it fires? | [`docs/grd-sg-corruption-repro-plan.md`](docs/grd-sg-corruption-repro-plan.md) |
| How does an RKNN model become a three-core RKNPU job? | [`rknpu/docs/how-rknpu-works.md`](rknpu/docs/how-rknpu-works.md) |
| What ioctl ABI does userspace depend on? | [`docs/dev-uapis.md`](docs/dev-uapis.md) |
| Which parts of that ABI are dead/dormant — safe to not special-case? | [`docs/abi-dormancy.md`](docs/abi-dormancy.md) |
| What was changed during the forward-port? | [`../kernel-versions/docs/vendor-forward-port.md`](../kernel-versions/docs/vendor-forward-port.md) |
| What did we port, what did we leave behind, and what do we add over the BSP? | [`docs/forward-port-scope.md`](docs/forward-port-scope.md) |
| What does each forward-port patch do, and which fixes belong back in the BSP? | [`docs/patch-catalog.md`](docs/patch-catalog.md) |
| How much code is vendor vs local? | [`docs/vendor-delta.md`](docs/vendor-delta.md) |
| How does the forward port compare with Rockchip's 6.1 and 6.6 BSP media drivers? | [`docs/bsp-6.1-6.6-comparison.md`](docs/bsp-6.1-6.6-comparison.md) |
| How were the applicable later Rockchip 5.10 RGA fixes adapted to the rewrite? | [`rga/docs/rewrite-5.10-reconciliation.md`](rga/docs/rewrite-5.10-reconciliation.md) |
| How are RK3588 nodes, IRQs, IOMMUs, aliases, and SRAM wired? | [`docs/device-tree.md`](docs/device-tree.md) |
| How does Armbian packaging apply the DT safely? | [`../packaging/docs/armbian-packaging.md`](../packaging/docs/armbian-packaging.md) |
| How do Kbuild, ccache, Docker, config changes, and clean rebuilds interact? | [`docs/kernel-build-ccache.md`](docs/kernel-build-ccache.md) |
| What changes on vanilla mainline? | [`../kernel-versions/docs/vanilla-kernel.md`](../kernel-versions/docs/vanilla-kernel.md) |
| What are the known traps? | [`../docs/gotchas.md`](../docs/gotchas.md) |
| What did the BSP audit find? | [`docs/bsp-audit.md`](docs/bsp-audit.md) |
| What did adversarial review find in our forward-port glue? | [`../kernel-versions/docs/forward-port-review-log.md`](../kernel-versions/docs/forward-port-review-log.md) |
| What is the net-new CCU MMU/IOMMU plan? | [`iommu/docs/mpp-ccu-iommu-plan.md`](iommu/docs/mpp-ccu-iommu-plan.md) |
| What is the RK3588 AV1 path, and why is it separate from RKVDEC2? | [`av1/docs/av1-rk3588.md`](av1/docs/av1-rk3588.md) |
| Why is RK3588 multi-core decode hard, and where would a scheduler live? | [`mpp/docs/multicore-scheduling.md`](mpp/docs/multicore-scheduling.md) |
| How does the mainline V4L2 `rkvdec` decoder work (the other stack)? | [`../kernel-versions/docs/mainline-rkvdec-v4l2.md`](../kernel-versions/docs/mainline-rkvdec-v4l2.md) |
| How do we resync to a new kernel or BSP? | [`docs/resyncing.md`](docs/resyncing.md) |
| How do we validate the rewrite drivers to production readiness? | [`docs/rewrite-validation-plan.md`](docs/rewrite-validation-plan.md) |
| Which conformance gaps were found after the forward-port reconciliation? | [`docs/rewrite-conformance-gap-audit.md`](docs/rewrite-conformance-gap-audit.md) |

## Shared files

Docs and artifacts owned at this top level (sub-project-scoped docs are indexed in
each sub-project's `README.md`).

| Path | One-liner |
|------|-----------|
| [`docs/forward-port-status.md`](docs/forward-port-status.md) | Project-local scorecard for the kernel forward-port (distinct from the whole-project [`../status.md`](../status.md)). |
| [`docs/how-the-drivers-work.md`](docs/how-the-drivers-work.md) | What each MPP/RGA driver layer does end to end. |
| [`docs/driver-architecture-comparison.md`](docs/driver-architecture-comparison.md) | Chart-based comparison of BSP-derived and rewrite MPP/RGA ownership, scheduling, DMA/IOMMU, recovery, teardown, and architectural pros/cons. |
| [`docs/dev-uapis.md`](docs/dev-uapis.md) | The `/dev/mpp_service` + `/dev/rga` ioctl ABI userspace depends on. |
| [`docs/abi-dormancy.md`](docs/abi-dormancy.md) | Which of that ABI is actually exercised vs defined-but-dead (batch server, RGA2 `0x60xx`, dead flags/config) — zero-caller evidence, so the rewrite doesn't support phantom ABI. |
| [`docs/device-tree.md`](docs/device-tree.md) | RK3588 node/IRQ/IOMMU/alias/SRAM wiring and DT glossary. |
| [`docs/vendor-delta.md`](docs/vendor-delta.md) | How much of the tree is vendor code vs local glue. |
| [`docs/bsp-6.1-6.6-comparison.md`](docs/bsp-6.1-6.6-comparison.md) | Direct pinned comparison of the baseline/current forward ports with Rockchip's 6.1 and 6.6 MPP/RGA trees. |
| [`rga/docs/raw-physical-import-crash.md`](rga/docs/raw-physical-import-crash.md) | Root cause, BSP branch history, kernel hardening, test containment, and reboot gate for the raw-physical RGA import crash found on 2026-07-16. |
| [`docs/bsp-audit.md`](docs/bsp-audit.md) | Multi-agent audit findings and the draft cleanup series. |
| [`docs/resyncing.md`](docs/resyncing.md) | Playbook for resyncing to a newer kernel or BSP. |
| [`docs/rewrite-driver-architecture/`](docs/rewrite-driver-architecture/README.md) | Chaptered source-level MPP/RGA rewrite architecture and kernel-driver learning guide. [`docs/rewrite-driver-architecture.md`](docs/rewrite-driver-architecture.md) is a forwarding stub keeping the pre-split path alive for old links. |
| [`docs/kernel-builds.md`](docs/kernel-builds.md) | The unified map of the four local kernel flavors and the single `build-kernel.sh` entry point. |
| [`docs/rewrite-drivers.md`](docs/rewrite-drivers.md) | Public-API-only clean-room reimplementation track. |
| [`docs/rewrite-kunit.md`](docs/rewrite-kunit.md) | How the embedded MPP/RGA KUnit suites are built, booted, parsed, log-gated, rerun, and preserved as YSP evidence. |
| [`docs/rewrite-kunit-rationalization-plan.md`](docs/rewrite-kunit-rationalization-plan.md) | Staged plan to retain high-value KUnit contracts while removing production-singleton fixtures, hardening cleanup, relocating redundant checks, and consolidating repeated vectors. |
| [`docs/rewrite-minimal-hard-irq-plan.md`](docs/rewrite-minimal-hard-irq-plan.md) | Staged plan to reduce every hard IRQ handler to claim/ack/stage, move slice/fence/wake work to threads, and re-enable PROVE_RAW_LOCK_NESTING as the per-boot enforcement. |
| [`docs/rewrite-validation-plan.md`](docs/rewrite-validation-plan.md) | What it would take to make the rewrite drivers production-ready. |
| [`docs/rewrite-conformance-gap-audit.md`](docs/rewrite-conformance-gap-audit.md) | 2026-07-17 audit of claimed ABI/codec coverage, booted evidence, counter/lifetime assertions, and remaining hardware gates. |
| [`docs/debug-kernel.md`](docs/debug-kernel.md) | Capture a crash / run the KASAN debug kernel. |
| [`patches/`](patches/README.md) | The maintained forward-port series, the superseded frozen base patches, debug-only DT patch, and the reviewable audit-fix series. |
| [`scripts/`](scripts/README.md) | Combined-kernel build/install/validate wrappers and the codec udev rule. |
| [`tests/`](tests/README.md) | On-hardware decode/encode/transcode smoke tests, plus the rewrite build gate and conformance suites. |
| [`mpp/`](mpp/README.md) · [`rga/`](rga/README.md) · [`av1/`](av1/README.md) · [`iommu/`](iommu/README.md) · [`rknpu/`](rknpu/README.md) | The five kernel-driver sub-projects. |
| [`../packaging/dkms/`](../packaging/dkms/README.md) | DKMS delivery channel for the same driver source. |
