# RK3588 RKVENC RCB/SRAM support is ABI-plumbed but not SRAM-backed in DT

promoted → [`../kernel-drivers/mpp/docs/rcb-sram.md`](../kernel-drivers/mpp/docs/rcb-sram.md) (2026-07-08)

The RKVENC RCB facts (ABI-plumbed but no encoder SRAM in DT; keep encoder RCB
allocation best-effort like the BSP; do not borrow decoder SRAM without TRM
evidence) now live in that doc.
