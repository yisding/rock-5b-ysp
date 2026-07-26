# Rewrite KUnit failures were stale fixtures plus six driver-contract defects

> Scope: clean-room MPP/RGA rewrite drivers on the ROCK 5B
> Source: `linux-6.18-rkvenc@5a55fa4743b2` failing boot; fixes at `c5faabf9d00b` in `mpp_rewrite.c` and `rga_rewrite.c`
> Date: 2026-07-26
> Trust: MEASURED / CODE-INSPECTED / ROOT-CAUSED / FIX-COMPILE-VERIFIED / PARTIAL

## Result

The first complete boot of the 232-case rewrite KUnit set disproved the earlier
assumption that a KUnit-enabled compile was sufficient evidence. Debug build
`P3565-Cad24` on the ROCK 5B ran all 85 MPP and 147 RGA cases, but only 77 MPP
and 126 RGA cases passed. The KUnit interval in `journalctl -k -b` also contained
eight Oopses, nine KASAN reports (eight null dereferences and one
stack-out-of-bounds), five debug-object-on-stack warnings, two refcount
warnings, and three paired IRQ/preemption-imbalance reports.

The 29 failed assertions were not one defect class:

| Class | Root cause | Intended behavior and fix |
|-------|------------|---------------------------|
| MPP ABI expectation | `MPP_CMD_QUERY_BASE` and `MPP_CMD_QUERY_HW_SUPPORT` are the same ABI value, so the test simultaneously expected one input to be both valid and invalid. | Assert the alias explicitly and test command-bound behavior with a value that is actually outside the query range. |
| MPP simulated hardware | Scheduling, CCU, abort, and reset fixtures left `job->hw`, core membership, terminal-reset state, or `batch.jobs` uninitialized. Production recovery then followed those fake pointers or tried to reset a device with no reset backend. | Construct the minimum complete topology and mark deliberately reset-less fake hardware terminally stopped. This keeps each test on the state transition it claims to exercise. |
| MPP asynchronous-object lifetime | Stack `work_struct` and `delayed_work` objects used the normal initializer and were not destroyed before the test stack disappeared. | Use `INIT_WORK_ONSTACK()` / `INIT_DELAYED_WORK_ONSTACK()` and the matching destroy helpers. |
| MPP reference lifetime | Session-abort fixtures acquired and released an `rk_mpp_hw` whose reference count began at zero. | Initialize the fake hardware reference and completion just as probe-created hardware is initialized. |
| MPP DCHS expectation | The test expected monotonically increasing TXIDs even after TXID 1 became free. | Preserve the allocator's lowest-free-ID contract; the next allocation after releasing an unrelated job gets TXID 1. |
| RGA acquire-fence handling | Fence fd 0 was incorrectly treated as absent, and the fd recorder trusted an implicit production-sized array. The direct small-array test exposed a real stack overwrite. | Treat every non-negative fd as valid and pass the destination capacity through the recorder/getter chain. Production supplies `RGA_TASK_NUM_MAX + 1`; focused tests supply their actual array size. |
| RGA validation outputs | `rk_rga_job_hw_type_mask()` could return an error without clearing its output, making the observable result depend on caller stack contents. Several stride fixtures also asked a routing helper to accept geometrically invalid canvases. | Zero the mask before validation; invalid geometry returns `-EINVAL` with a deterministic zero mask. Use valid minimum-size canvases when testing only backend selection. |
| RGA format geometry | The semiplanar validator applied 4:2:0 vertical-evenness rules to 4:2:2 P210. | Keep vertical alignment for 4:2:0; 4:2:2 requires chroma alignment horizontally but permits arbitrary scanline `y` and height. |
| RGA feature routing | OSD, alpha-bitmap, quantize, Gaussian, and related feature bits were collapsed into generic ROP classification; legal Y4/Y8 dither flags were then rejected by the general RGA2 path. | Classify those features independently and allow the documented dither-only flag subset without enabling unrelated ROP combinations. |
| RGA rotated destination validation | RGA2 register emission swaps destination dimensions for 90-degree rotation, and validation accidentally treated those hardware-register dimensions as the userspace memory canvas. | Validate the original destination allocation/canvas, then transform dimensions only for command emission. |
| RGA stale profile fixtures | Palette crop, GStreamer RGB888 rotation, RKNN minimum dimensions, full-CSC routing, AFBC offsets/height and pixel-swap, alpha-YUV routing, and translated aligned-size expectations predated current validators or register recipes. | Make each fixture internally valid and update expected registers to the current documented ABI. These changes do not weaken the validators. |

Commit `c5faabf9d00b` applies those changes to
`rk3588-rewrite-6.18`; byte-identical source was replayed as
`39475996a7a82` on `rk3588-rewrite-mainline`. All six clean-source
`normal`, `memory`, and `race` profiles passed with warnings fatal, each building
the Rockchip IOMMU provider, both KUnit-enabled rewrite objects, and the ROCK 5B
DTB. Bootable KASAN/lockdep package `P3b08-Cad24` also built with the four
rewrite/KUnit config symbols present.

## Boundary

The repaired package has not yet been installed or booted. Compile success and
package inspection do not prove that the 232 cases now pass or that their kernel
log interval is sanitizer- and warning-clean. The closing gate is a boot of
`P3b08-Cad24`, an exact 85/85 MPP plus 147/147 RGA result check with zero skips,
and a journal scan covering the complete two-suite interval. Hardware
codec/RGA conformance remains a separate rewrite-validation gate.
