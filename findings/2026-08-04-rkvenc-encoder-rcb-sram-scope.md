# RK3588 encoder RCB is reachable only by >4096-wide H.264, so the absent encoder SRAM costs almost nothing

promoted → [`../kernel-drivers/mpp/docs/rcb-sram.md`](../kernel-drivers/mpp/docs/rcb-sram.md) (2026-08-04)

The maintained RCB/SRAM guide preserves the source pins, reachability gates,
buffer-size calculation, DDR fallback mechanism, evidence boundary, and the
reason no ordinary RK3588 encode benefits from encoder SRAM.
