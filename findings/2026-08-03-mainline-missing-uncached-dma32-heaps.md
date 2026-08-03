# Mainline lacks the BSP uncached/dma32 dma-heaps; MPP absorbs it, librga samples do not

> Scope: video-libraries (MPP), vendor-libraries (librga), kernel-drivers/rga —
> consequences of the port not exporting Rockchip's extra dma-heaps
> Source: mpp `1.5.0+git20260729.3381fd2c` — `osal/allocator/allocator_dma_heap.c`
> `dma_heap_init()` (~:113); librga-fork @ `26a50ef` —
> `samples/utils/allocator/dma_alloc.cpp` `dma_buf_alloc()` (~:93);
> kernel `linux-6.18-rkvenc-av1-fwport` @ `7615b69a744a`
> Date: 2026-08-03
> Trust: MEASURED, SOURCE-INSPECTED

## Result

The port exports only `system`, `default_cma_region`, and `reserved` under
`/dev/dma_heap/`. Rockchip's BSP additionally provides `-uncached` and `-dma32`
variants, and `drivers/dma-buf/heaps/` in the port contains no occurrence of
"uncached" at all. Userspace written against the BSP heap names therefore has to
degrade, and the two libraries degrade very differently.

**MPP absorbs it correctly.** `dma_heap_init()` probes every heap, and
`try_flip_flag()` remaps a missing one by flipping the cachable/dma32 qualifier,
copying `src->flags` so the replacement is *relabelled* rather than silently
misdescribed. That is why the `system-uncached` → `system` fallback correctly
marks buffers cachable, which in turn makes `check_buf_need_sync()` stop
short-circuiting and the `DMA_BUF_IOCTL_SYNC` calls real. MPP also never
requests DMA32 internally: `MPP_BUFFER_FLAGS_DMA32` appears only in the public
header and `type_to_flag()`, with no in-tree caller, so the absent `-dma32`
heaps are inert for MPP.

MPP's framework does its own cache maintenance — `mpp_dec_normal.c` (~:440)
syncs the decoder input bitstream, `mpp_enc_hal.c` (~:254) the encoder output,
and the vp9d HALs their probe/count tables. Measured: a 300-frame decode issues
900 `DMA_BUF_IOCTL_SYNC` calls. Decode output is reproducible across 6 runs at
176x144 and 5 runs at 1280x720; encode is reproducible across 5 runs and its
output decodes back at 28.25 dB average PSNR against the source, so the
CPU-write→hardware-read direction is genuinely working rather than
deterministically wrong.

**librga's sample allocator does not.** `dma_buf_alloc()` `open()`s a hardcoded
heap path and returns the error with no fallback, and `dma_alloc.h` (~:26)
hardcodes `/dev/dma_heap/system-uncached-dma32`. Every sample, demo, and the
`im2d_slt` suite that names an uncached or dma32 heap fails at allocation on the
port. Measured before the fix: `system-uncached-dma32` and `system-uncached`
both fail, only plain `system` succeeds.

## Root cause

Heap names are a BSP-only ABI. MPP treats them as a preference list; librga's
sample allocator treats one as a requirement.

## Fix

`samples/utils/allocator/dma_alloc.cpp` — added `dma_heap_open()`, which tries
the requested path and then progressively drops `-dma32` and `-uncached`,
printing what it fell back to and why. Applied to the working tree of
`~/Code/rock-5b/rockchip-userspace/librga-fork`, **uncommitted and not pushed**.

A/B against the stock allocator built from `HEAD`, same test binary:

| Heap requested | Stock | Patched |
| --- | --- | --- |
| `system-uncached-dma32` | fail | OK via `system` |
| `system-uncached` | fail | OK via `system` |
| `system` | OK | OK |
| nonexistent name | fail | fail (no false fallback) |

End to end, `rga_cvtcolor_csc_demo` now reaches and completes its RGA operation
(`rga_api version 1.10.6_[3]`, `running success!`) instead of dying at
allocation; it still exits 1 only because its hardcoded `/data/` sample images
are absent.

Falling back is safe with respect to RGA2's 4G limit because the kernel already
enforces it: `rga2@fdb80000` is the one RGA core in `rk3588-base.dtsi` with no
`iommus` property, and `rga_policy.c` (~:360, ~:493) refuses to schedule RGA2
for over-4G memory and says so, routing to an RGA3 core instead. The failure
mode is a skipped core, not silent corruption.

## Boundary

The fallback changes two properties the caller may care about, which is why it
warns rather than staying quiet: dropping `-uncached` yields cachable memory, so
any CPU access needs `dma_sync_cpu_to_device()`/`dma_sync_device_to_cpu()`
bracketing; dropping `-dma32` may place a buffer above 4G, costing RGA2
eligibility. **Whether each librga sample actually issues those sync calls was
not audited** — the fix makes allocation succeed, it does not make every sample
cache-correct.

`utils.c` `dump_mpp_frame_to_file()` (~:115) takes a CPU pointer and `fwrite`s
with no sync, and utils.c has zero sync calls. It did **not** misbehave across
11 decode runs at two frame sizes, so it is recorded as a latent hazard, not a
reproduced defect; it is likely spared because the CPU only reads and never
dirties those lines. The broader MPP tree has many other unsynced
`mpp_buffer_get_ptr()` sites that were not individually audited — most touch
CPU-only packet/header buffers.

No BSP-kernel comparison was run. RGA3/RGA2 core selection under the fallback
was not exercised with a real over-4G buffer.

## Why it matters

Anything ported from the BSP that names a heap is a portability trap, and the
two libraries show both outcomes. The concrete exposure is Rockchip's own
validation suites: `im2d_slt` cannot allocate at all on the port without this
fix, which — together with [the IEP2 SLT CRC
problem](2026-08-03-rk3588-iep2-nondeterministic-output.md) — means vendor
conformance tooling needs auditing before its results are trusted here.
