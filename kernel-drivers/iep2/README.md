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
- The currently booted `6.18.41-ysp-rockchip64` kernel predates that port. It
  still advertises neither IEP2 nor VDPP, so functional output remains gated
  on building, booting, and running the new validation.
- The installed libmpp already contains the IEP2 userspace path. An interlaced
  decode currently tries MPP client 28, receives `EINVAL`, disables
  deinterlacing, and continues with the decoded frame.
- IEP2 is smaller than VDPP only in the userspace comparison. The BSP's IEP2
  kernel implementation is actually larger than its VDPP kernel file. The
  detailed guide explains the different register-programming boundary.

## Read next

- [RK3588 IEP2 versus VDPP](docs/rk3588-iep2-vdpp.md) — hardware identity,
  BSP/kernel/userspace flow, code-size accounting, runtime evidence, and a
  forward-port estimate.
- [Keywords](keywords.md) — local terminology and client/device names.
- [`iep2-smoke.sh`](../tests/iep2-smoke.sh) — device-free source/build gate and
  on-board TFF/BFF I5O2 output test with size, nonzero-content, binding, and
  kernel-log checks.
- [Source-audit finding](../../findings/2026-08-02-rk3588-iep2-vdpp-source-audit.md)
  — dated pins, measurements, and the evidence boundary behind the maintained
  explanation.

## Evidence state

The hardware identity and BSP integration are source-inspected. The forward
port is compile-, link-, and DTB-validated. The negative state of the currently
booted kernel and the installed libmpp probe are measured. No IEP2 output has
yet been produced on the forward-port kernel, so functional deinterlacing
remains unvalidated until the new source is built, booted, and exercised.
