# librga's palette demo does not provide a kernel conformance signal

> Scope: official librga palette sample and the ROCK 5B RGA conformance matrix
> Source: librga `cc39281812cb` (1.10.6_[3]) and `2cffdf6f332c` (1.10.5_[11]), `im2d_impl.cpp` `generate_color_palette_req()` / `rga_generate_csc_config()`; BSP `b4ef083dc0c3` `rga_job_assign()`; rewrite `f96c1e74c83b` `rk_rga_hw_finish_job_locked()`
> Date: 2026-08-06
> Trust: MEASURED, SOURCE-INSPECTED, ROOT-CAUSED, DESIGN, PARTIAL

## Result

`rga_palette_demo` is not a valid required or diagnostic kernel-conformance
case. The sample was added with librga 1.10.5 on 2025-07-29. That release emits
the expected apply controls for its eight-bit index image:
`render_mode=COLOR_PALETTE`, `palette_mode=3`, and `yuv2rgb_mode=0`. Librga
1.10.6's unified CSC pass instead treats the YCbCr400 index buffer as an
ordinary YUV image and adds `yuv2rgb_mode=1`, although color-palette lookup does
not perform source CSC. The BSP's specialized palette register path ignores
that field; the rewrite rejects the internally inconsistent request.

Captured 1.10.5 and 1.10.6 LUT-update requests were byte-identical. Their
palette-apply requests were also byte-identical except for the single
`yuv2rgb_mode` byte (`0` in 1.10.5, `1` in 1.10.6). This makes the immediate
1.10.6 rejection a librga regression, not missing palette hardware support.

Librga 1.10.5 was still not a robust reference transaction. Both releases
build one request containing source, destination, and LUT state, submit it
synchronously as `UPDATE_PALETTE_TABLE`, then reuse the same request as a
separate `COLOR_PALETTE` ioctl. The apply therefore retains an unnecessary LUT
`pat` channel, `fading.g=0xff`, and any LUT-related mapping state. The BSP
palette emitter ignores those inactive controls, but its memory path still
interprets and maps the retained channel.

More importantly, the LUT is hardware state belonging to one RGA2 instance,
while the two ioctls carry the default `core=0` and are scheduled
independently. The BSP policy chooses an eligible core from current load for
each job. The rewrite likewise releases the selected hardware and queues the
next task for a fresh selection. Ordering therefore does not guarantee that
the apply uses the RGA2 instance whose LUT was updated. A normalized apply
request completed on the 2026-08-06 rewrite boot but returned first-pixel bytes
that did not match LUT entry 1, demonstrating why ioctl success is insufficient
evidence for this stateful operation.

The sample itself checks only the returned `IM_STATUS`, prints the first pixel,
and declares success without comparing the destination against the LUT. It
also omits release of the LUT handle and buffer. A BSP `running success!` line
therefore proves API completion, not correct palette output.

Before 1.10.5 the exact demo did not exist. Older palette generation supported
the BPP1/2/4/8 formats, but did not map `RK_FORMAT_YCbCr_400` to the eight-bit
palette mode. Replaying this demo's call against that code would leave the
zero-initialized `palette_mode=0`, which describes one-bit rather than
eight-bit indices.

## Deferred fix

A proper fix starts in librga:

1. Exempt `IM_COLOR_PALETTE` from generic CSC generation.
2. Build clean, distinct LUT-update and palette-apply requests instead of
   mutating and reusing one request object; the apply should contain source and
   destination only.
3. Submit the dependency with same-core semantics: either pin both operations
   to one concrete RGA2 instance or use one sequential job whose kernel
   implementation retains the selected core across the stateful pair.
4. Make the sample compare destination pixels with the selected LUT entries
   and release the LUT resources.

Until that userspace and scheduling contract exists, the conformance harness
keeps the demo out of both default classes. The rewrite continues to reject the
malformed CSC combination rather than silently accepting it. An explicit
`RGA_REQUIRED_CASES=rga_palette_demo` remains available for a focused
compatibility experiment.

## Evidence

- **Failing run:**
  `/home/yi/Code/rock-5b/build/rockchip-conformance/logs/rewrite-kasan/20260806-101424-librga-suite`;
  installed librga 1.10.6_[3] returned the harness's `log-fail` result.
- **Request captures:** the run's `palette-isolation/request-{staged,installed}.bin`
  differ only at byte 275; `update-{staged,installed}.bin` are identical.
- **Typed request:** the staged 1.10.5 apply contains LUT handle 3 in `pat`,
  `palette_mode=3`, `yuv2rgb_mode=0`, and `core=0`.
- **Source comparison:** librga `generate_color_palette_req()` and
  `rga_generate_csc_config()`; BSP `rga_job_assign()`,
  `RGA2_set_reg_color_palette()`, and
  `RGA2_set_reg_update_palette_table()`; rewrite
  `rk_rga_hw_finish_job_locked()`.
- **Harness change:** `kernel-drivers/tests/librga-suite.sh` excludes the demo
  from required and diagnostic defaults and its device-free case-list selftest
  prevents accidental reintroduction.

## Boundary

This finding does not establish that RGA2 palette hardware is defective. It
does not contain an exact-content run of a corrected same-core request pair on
the BSP and rewrite kernels. The stale apply fields are proven unnecessary to
the BSP register emitter, but their standalone pixel effect was not isolated
from the core-selection problem. The exclusion is a conformance-quality
decision, not a claim that no existing single-core or lightly loaded product
can use librga palette operations successfully.
