# RK3588 IEP2 deinterlacing

This project owns the RK3588 video post-processing/deinterlacing model: how
Rockchip exposes IEP2 through MPP client 28, how libmpp selects it, how it
differs from VDPP, and how the Linux forward port is validated.

## Project brief

| Field | Contents |
|-------|----------|
| User outcome | Deinterlace interlaced video through RK3588 IEP2 instead of falling back to undecorated decoded frames. |
| Developer focus | IEP2 versus VDPP identity, MPP task and IOMMU lifetime, field/mode selection, dma-buf cache ownership, failure handling, and test coverage. |
| Owns | The hardware/source model, forward-port safety review, local vocabulary, and IEP2-specific test routes named below. |
| Depends on | The shared MPP service and IOMMU infrastructure, RK3588 DT wiring, compatible libmpp vproc support, and dma-buf access. |
| Evidence boundary | [`docs/forward-port-safety-review.md`](docs/forward-port-safety-review.md) owns accumulated build/runtime/safety evidence; [`../../status.md`](../../status.md) and support-coverage C21 own the public boundary and next proof. |

## Current answer

- RK3588 has IEP2, exposed by the BSP as `rockchip,iep-v2` and MPP client 28.
  No inspected RK3588 source or DT exposes the distinct VDPP block used on
  RK3528/RK3576.
- libmpp already contains the IEP2 vproc path. The kernel decides whether that
  request reaches hardware or is refused so userspace can continue without
  deinterlacing.
- IEP2 input/output buffers are dma-bufs. CPU-written/read test buffers require
  explicit cache synchronization; nondeterministic output without that sync is
  a harness defect, not proof of a hardware or forward-port fault.
- IEP2 and VDPP differ in both hardware identity and programming boundary; the
  maintained source model owns that distinction rather than a versioned result
  copied here.

## Read next

- [`docs/rk3588-iep2-vdpp.md`](docs/rk3588-iep2-vdpp.md) — hardware identity,
  BSP/kernel/userspace flow, code-size accounting, and source evidence.
- [`docs/forward-port-safety-review.md`](docs/forward-port-safety-review.md) —
  task lifetime, IOMMU fault/remove, probe, ABI, span, fix, and accumulated
  runtime evidence.
- [`../tests/iep2-smoke.sh`](../tests/iep2-smoke.sh) — first build/on-board
  TFF/BFF I5O2 gate with output and kernel-log checks.
- [`../tests/iep2/`](../tests/iep2/README.md) — ioctl-level negative, span,
  mode, teardown, and stress harnesses.
- [`keywords.md`](keywords.md) — local terms and client/device names.

## Evidence state

Do not infer present support from the source model or this front door. Use the
[safety review](docs/forward-port-safety-review.md) for exact identities,
workloads, signals, trust, and unexercised paths; use
[`status.md`](../../status.md) for the current public kernel verdict. A source
build, a booted driver, a clean focused run, and production qualification are
separate evidence classes.
