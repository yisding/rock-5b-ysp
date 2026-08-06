# RK3588 IEP2 deinterlacing

This project records the RK3588 video post-processing/deinterlacing block, how
Rockchip's BSP exposes it, how libmpp selects it, and the state of its Linux
6.18 forward port and validation.

## Current answer

- The RK3588, and therefore the Radxa ROCK 5B, has **IEP2** deinterlacing
  hardware. Rockchip's BSP binds it as `rockchip,iep-v2` and registers MPP
  client type 28 through `/dev/mpp_service`.
- The RK3588 has no documented or BSP-addressable **VDPP** block. RK3528 and
  RK3576 do have explicit VDPP device-tree nodes, clock/reset IDs, and kernel
  compatibles; RK3588 has none of those.
- The 6.18 forward-port source now contains the IEP2 driver, register map,
  binding, Kconfig/Makefile wiring, and RK3588/ROCK 5B DT/IOMMU nodes. The
  driver object, linked MPP archive, and ROCK 5B DTB build successfully.
- The board now boots `6.18.41-video-port-kasan-rockchip64` (`#32`, source
  `g7615b69a744a`) carrying the port. It advertises `DEVICE[28]:IEP2`, binds
  `fdbb0000.iep` to `mpp-iep2` and `fdbb0800.iommu` to `rk_iommu`, and produces
  real deinterlaced I5O2 output under KASAN and lockdep.
- The installed libmpp already contains the IEP2 userspace path. Against the
  pre-port kernel an interlaced decode tried MPP client 28, received `EINVAL`,
  disabled deinterlacing, and continued with the decoded frame. On the port
  that fallback is gone: client 28 is ready and services the request.
- Stock IEP2 output is **not reproducible**, but the cause is Rockchip's test
  harness omitting the dma-buf cache sync around its CPU access, not the driver.
  It is latent on the BSP and only bites here because mainline has no
  `system-uncached` heap, so MPP falls back to a cachable one. Adding the sync
  makes output byte-identical across runs — see the runtime finding.
- IEP2 is smaller than VDPP only in the userspace comparison. The BSP's IEP2
  kernel implementation is actually larger than its VDPP kernel file. The
  detailed guide explains the different register-programming boundary.

## Read next

- [RK3588 IEP2 versus VDPP](docs/rk3588-iep2-vdpp.md) — hardware identity,
  BSP/kernel/userspace flow, code-size accounting, runtime evidence, and a
  forward-port estimate.
- [IEP2 forward-port safety review](docs/forward-port-safety-review.md) — the
  complete task-lifetime, IOMMU fault/remove, probe, userspace ABI, DMA-span,
  fix, negative-audit, and remaining KASAN/runtime record.
- [Keywords](keywords.md) — local terminology and client/device names.
- [`iep2-smoke.sh`](../tests/iep2-smoke.sh) — device-free source/build gate and
  on-board TFF/BFF I5O2 output test with size, nonzero-content, binding, and
  kernel-log checks.
- [RK3588 IEP2 versus VDPP](docs/rk3588-iep2-vdpp.md) — the maintained source
  audit and hardware-identity explanation.

## Evidence state

The hardware identity and BSP integration are source-inspected. The forward
port is compile-, link-, and DTB-validated. A three-part safety review found
and repaired task-work lifetime, fault callback/teardown, clock error-pointer,
raw-address, buffer-span, flag-race, and auxiliary-IOVA defects. KASAN package
`Pcf86-Cc271` has now been booted and exercised: 20 consecutive I5O2 runs
(10 TFF, 10 BFF, 320x240) produced correctly sized, high-entropy output with no
KASAN, UAF, lockdep, IOMMU-fault, or timeout report in the kernel log. The
first-order functional and memory-safety gates therefore pass.

The one defect the run surfaced — non-reproducible output — is root-caused to a
missing dma-buf cache sync in Rockchip's `iep2_test.c`, proven by a three-arm
A/B in the
[runtime finding](../../findings/2026-08-03-rk3588-iep2-nondeterministic-output.md).
It is not a forward-port regression and does not belong in the driver.

Every remaining runtime gate has since passed: the decoder vproc path, the
1080p span boundary in both directions, I1O1T and its auxiliary mapping, 18
negative cases refused synchronously, per-task address-encoding interpretation,
and ~20,000 tasks of teardown and import-churn stress — with no KASAN, UAF,
lockdep, IOMMU-fault, timeout, or reset report. Only the software timeout path
is unexercised, since provoking it needs fault injection. See the safety review
and the [ioctl-level harnesses](../tests/iep2/README.md).
