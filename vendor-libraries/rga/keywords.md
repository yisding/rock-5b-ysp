# vendor-libraries/rga — keywords

`librga` terms. Cross-cutting vocabulary is in [`../../glossary.md`](../../glossary.md).

- **librga** — the userspace RGA library apps link for `scale_rkrga` / `vpp_rkrga`;
  ships as `librga.so`.
- **im2d** — librga's modern "image 2D" API surface (the `im*` calls).
- **P010 / P210** — 10-bit 4:2:0 / 4:2:2 pixel formats; the RKRGA legacy path needs
  librga to copy 10-bit layout fields to the ioctl.
- **is_10b_compact / is_10b_endian** — the 10-bit layout flags older librga dropped
  before the ioctl; the fix restores them. See
  [`docs/librga-p010-p210-rkrga.md`](docs/librga-p010-p210-rkrga.md).
- **buffer import** — wrapping a dma-buf fd or a virtual-address buffer into an RGA
  handle.
- **core profile** — librga's per-request choice of RGA core/format path.
- **librga-src** — the dev-box patched tree (`github.com/yisding/librga` @ `a632217`);
  its P010/P210 fix is exported in [`patches/`](patches/).
