# RK3588 IEP2 runs clean under KASAN; its output non-determinism is a missing dma-buf cache sync in Rockchip's test harness, not the driver

> Scope: kernel-drivers/iep2 — RK3588 IEP2 forward port, first on-board runtime
> Source: `~/Code/rock-5b/kernel/linux-6.18-rkvenc-av1-fwport` @ `7615b69a744a`;
> libmpp `mpp-1.5.0+git20260729.3381fd2c` —
> `mpp/vproc/iep2/test/iep2_test.c` `iep2_run()` (~:303, ~:320-322)
> Date: 2026-08-03
> Trust: MEASURED, ROOT-CAUSED, SOURCE-INSPECTED

## Result

The IEP2 forward port works on hardware. Booted on
`6.18.41-video-port-kasan-rockchip64` (`#32`, `g7615b69a744a`, the reviewed
source), the board advertises `DEVICE[28]:IEP2`, binds `fdbb0000.iep` to
`mpp-iep2` and `fdbb0800.iommu` to `rk_iommu`, and services real I5O2
deinterlacing. The `EINVAL` fallback seen against the pre-port kernel is gone:
the userspace probe log lists clients 1, 3, 12, 13, 18, and 19 as "not ready"
and no longer lists 28.

Twenty consecutive runs (10 TFF + 10 BFF, 320x240, 6-frame input) each emitted
exactly 921600 bytes — the expected `(6-2) * 2 * 115200` for I5O2 — with roughly
88% nonzero content, and TFF and BFF outputs differ, so field order reaches the
hardware. Across all 20 runs the kernel logged **nothing at all**: no KASAN
report, use-after-free, out-of-bounds, lockdep splat, IOMMU fault, bus error,
timeout, or reset-recovery message. This is the first runtime memory-safety
evidence for the repaired driver, on a kernel with `CONFIG_KASAN=y`,
`CONFIG_KASAN_INLINE=y`, `CONFIG_PROVE_LOCKING=y`, and
`CONFIG_DEBUG_ATOMIC_SLEEP=y`.

**Stock output is not reproducible**, for reasons that turned out to lie in
Rockchip's test harness rather than the driver — see Root cause. Ten iterations
reading one byte-identical
input file (`sha256 2a61ee10…`) produced ten different results. Against
iteration 1, other iterations differ in 15.69%, 16.20%, 39.20%, and 18.74% of
their 921600 bytes. The variance is spread across all eight output frames
rather than concentrated in the first, so it is not motion-history warmup
converging after a startup frame. It is also not a frame-ordering artifact:
extracting frames 4 and 5 from two runs and comparing them both directly and
swapped shows all four combinations differ, so the pixel computation itself
varies, not just the order `iep2_test` writes the pair in.

Rockchip's own tooling expects determinism. `iep2_test -v` computes a per-frame
CRC and writes it for their SLT harness to compare against golden values, which
is only meaningful if a given input yields a stable result.

## Root cause

`iep2_test.c` `iep2_run()` touches mmapped dma-bufs with the CPU and never
brackets those accesses with `DMA_BUF_IOCTL_SYNC`, which the dma-buf contract
requires. The loop reads the source frame in with `fread` (~:303), `memset`s
both destinations to zero (~:320-321), runs the hardware (~:322), then reads the
destinations straight back with `crc_data_calc`/`fwrite`. The memset leaves the
whole destination dirty in CPU cache; the hardware then DMA-writes the same
pages; the readback returns a mix of surviving cached zeros and real DMA data,
and which lines survive depends on cache pressure. That is precisely a scattered,
run-varying delta.

Proven by a three-arm A/B on one pinned input pair, all three binaries built
from the same tree with the same flags, differing only in the patch:

| Arm | Change | Unique sha256 (10 TFF / 10 BFF) |
| --- | --- | --- |
| Control | stock `3381fd2c` | 10 / 10 |
| A | `mv_buf` + `md_buf` zeroed in `iep2_init()` | 10 / 10 |
| B | `sync_end` on src+dst before run, `sync_begin` on dst after | **1 / 1** |
| B′ | arm B with arm A reverted | **1 / 1**, same hash as B |

Arm A refutes the uninitialized-motion-history hypothesis outright: zeroing
changed nothing. Arm B′ produces `72ae6213…`, byte-identical to arm B, so the
cache sync alone is the complete and minimal fix and the memset is unnecessary.
`mpp_buffer_sync_end()` resolves through `mpp_dmabuf_sync_end()` to
`DMA_BUF_IOCTL_SYNC`, so the fix is the sanctioned mechanism, not a workaround.

### Why it manifests here and not on the BSP

The harness omission is latent on Rockchip's BSP and only bites on mainline,
because the two kernels offer different heaps. `allocator_dma_heap.c` (~:65)
ranks heaps by preference: `system-uncached` carries `MPP_ALLOC_FLAG_NONE`,
while `system` carries `MPP_ALLOC_FLAG_CACHABLE`. `mpp_buffer_impl.c` (~:485)
derives `uncached` from that flag, and `check_buf_need_sync()` skips the ioctl
entirely for uncached buffers — so on a kernel that provides `system-uncached`,
the missing sync calls are missing no-ops and the harness is accidentally
correct.

Measured on the port: `strace` shows MPP probe `/dev/dma_heap/system-uncached`
and `system-uncached-dma32`, take `ENOENT` on both, and fall back to
`/dev/dma_heap/system`. `/dev/dma_heap/` here holds only `system`,
`default_cma_region`, and `reserved`, and `drivers/dma-buf/heaps/` in the port
registers only `system` and CMA with no occurrence of "uncached" — the uncached
system heap is a Rockchip BSP addition that never landed upstream. The fallback
is therefore cachable, `uncached` is 0, and the sync becomes load-bearing.
`strace` confirms 20 `DMA_BUF_IOCTL_SYNC` calls under the fix, so the arm-B
result is real rather than a timing artifact.

Note this makes the userspace fix strictly correct rather than a mainline-only
workaround: on a BSP kernel the added calls cost nothing, because MPP's own
`check_buf_need_sync()` short-circuits them.

**This is not a kernel defect and should not be fixed in the driver.** The
driver cannot know whether userspace dirtied a buffer, and syncing
unconditionally would flush full frames per task on the dominant
decoder→IEP2→display path, where no CPU ever touches them. `mpp_rkvdec2.c`
likewise has no sync calls and is correct for the same reason. The targeted
`mpp_dma_buf_sync()` in `mpp_rkvenc2.c` (~:1319, ~:2067) is not a counterexample:
there the kernel knows the variable-length valid extent of the bitstream, which
userspace cannot derive. IEP2's destination is a fixed-size frame.

## Fix

Three `mpp_buffer_sync_end()` calls before `IEP_CMD_RUN_SYNC` and two
`mpp_buffer_sync_begin()` calls after, against
`mpp/vproc/iep2/test/iep2_test.c`. Proven to make output reproducible across 10
iterations per field order.

Committed as `8b1e3625` on `ysp/main` in `~/Code/rock-5b/rockchip-userspace/
mpp-rockchip` and pushed to `yisding/mpp`. Not sent upstream to Rockchip. Not
carried by any PPA package: `rockchip-mpp-demos` ships `usr/bin/*` but the cmake
install set does not include `iep2_test`, so the fix reaches only source
consumers of the fork.

## Boundary

The kernel driver's own buffers were never implicated: `mpp_iep2.c`
`iep2_probe()` `memset`s the ROI buffer and `clear_highpage()`s the auxiliary
page.

The defect is in Rockchip's **test harness**, so its blast radius is
CPU-readback consumers — the SLT CRC path, file dumps, software
post-processing. A decode→IEP2→display pipeline that never maps these buffers
for CPU access is likely unaffected, but that was **not** measured. The real
decoder vproc path was not run, so whether libmpp's production IEP2 client has
the same omission is untested.

No BSP-kernel A/B was run. That Rockchip's BSP actually registers
`system-uncached` is inferred from MPP probing for it, not measured on a BSP
kernel — but the mainline half of the comparison is measured, and it is the half
that matters here.

This finding covers the 320x240 I5O2 run only. The remaining runtime gates —
1080p span boundary, decoder vproc path, I1O1T, negative-input rejection,
address-encoding race, and teardown/churn stress — were run afterwards and are
recorded in the
[safety review](../kernel-drivers/iep2/docs/forward-port-safety-review.md).
The software timeout path is still unexercised.

## Evidence and reproduction

- **Identity:** ROCK 5B, `6.18.41-video-port-kasan-rockchip64` `#32`
  `g7615b69a744a`; libmpp/`iep2_test` from
  `mpp-1.5.0+git20260729.3381fd2c+ds`.
- **Exercise:**
  ```sh
  IEP2_TEST=<…>/mpp/vproc/iep2/test/iep2_test \
  BUILD_DIR=~/Code/tmp/iep2-test-2026-08-03/stress \
  IEP2_REQUIRE_DMESG=1 IEP2_LOOPS=10 \
    kernel-drivers/tests/iep2-smoke.sh
  ```
- **Pass/fail signal:** harness exits 0 with per-iteration `PASS` lines and
  `PASS: no new IEP2/IOMMU/timeout/kernel-fatal dmesg signature`; the
  non-determinism is visible as a different sha256 per iteration.
- **Harness note:** this box sets `dmesg_restrict=1`, so the harness's
  `dmesg`-based scan silently degraded and reported nothing. `iep2-smoke.sh`
  now falls back to `journalctl -k` and announces which backend it used, so
  `IEP2_REQUIRE_DMESG=1` is a real gate rather than a no-op.
- **Artifacts:** `~/Code/tmp/iep2-test-2026-08-03/` (not committed).

## Why it matters

The port clears its first functional and memory-safety gates, which moves IEP2
from "builds and boots" to "deinterlaces", and the one defect the run surfaced
is now pinned to vendor userspace rather than the forward port. The earlier
worry that the hardware might be consuming uninitialized memory — an
information-disclosure path into decoded video — is retired: arm A showed the
motion buffers have no bearing on the result.

The live consequence is for validation, not playback. Rockchip's SLT golden-CRC
comparison for IEP2 computes its CRCs from the unsynced readback, so those CRCs
are not reproducible and any golden set derived from them is unsound. Conformance
comparison against IEP2 needs the harness fix first.
