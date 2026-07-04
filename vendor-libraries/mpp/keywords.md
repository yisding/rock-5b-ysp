# vendor-libraries/mpp — keywords

`librockchip_mpp` terms. Cross-cutting vocabulary is in
[`../../glossary.md`](../../glossary.md).

- **librockchip_mpp** — the userspace MPP library apps link for `h264_rkmpp` /
  `hevc_rkmpp` and the `mpi_*_test` tools; ships as `librockchip_mpp.so.1`.
- **MPI** — the Media Process Interface, libmpp's public API surface.
- **MPP context** — the per-session object holding codec state, task queues, and
  frame pools. See [`docs/mpp-library-architecture.md`](docs/mpp-library-architecture.md).
- **HAL** — the hardware-abstraction layer inside libmpp that builds the
  register tables the kernel runs (the kernel does not parse streams).
- **KMPP** — Rockchip's newer kernel-MPP path; the kernel-shared-object boundary is
  reverse-engineered in [`docs/mpp-kmpp-reverse-engineering.md`](docs/mpp-kmpp-reverse-engineering.md).
- **register generation** — libmpp turns H.264/HEVC streams into hardware-specific
  register recipes; why ABI compatibility matters as much as driver probing.
