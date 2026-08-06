# Rewrite RGA librga failures: SWIOTLB segments, fd-zero fences, and sample status

> Scope: clean-room RGA rewrite and the official librga conformance wrapper
> Source: `rk3588-rewrite-6.18@19634f4eebba`, suite run
> `20260805-084559-librga-suite`, fixed source
> `rk3588-rewrite-6.18@37ae7459656b` and
> `rk3588-rewrite-mainline@02bf372dac70`, exact-tip KASAN package
> `P27bb-Cad24`
> Date: 2026-08-05
> Trust: **MEASURED** / **SOURCE-INSPECTED** / **SOURCE-CONFIRMED** /
> **ROOT-CAUSED** / **FIX-COMPILE-VERIFIED** / **PACKAGE-BUILD-VERIFIED** /
> **PARTIAL**

## Result

The first current-tip hardware run materially improves the rewrite evidence but
does not close RGA qualification. Booted KASAN kernel
`6.18.42-video-rewrite-kasan-rockchip64 #2 g19634f4eebba` passed the exact
ordered **92 MPP + 152 RGA** KUnit manifest with live lockdep and a clean
full-interval fatal scan. The official MPP suite then passed all 12 required
cases. The librga suite exposed two independent driver compatibility defects
and one evidence-wrapper defect.

The raw librga summary reports only 1/34 required cases passing, but that number
is not a valid functional count. Official librga samples have two incompatible
process-status conventions: some return failed `IM_STATUS` value zero after
printing a fatal diagnostic, while successful samples commonly return
`IM_STATUS_SUCCESS`, numeric value one. The old wrapper handled only the first
case, so genuine successes such as FBC, tile, alpha, and core-selection demos
were recorded as status `1` failures.

Three measured details separate the real kernel defects from that accounting
noise:

1. The maintained `ysp_librga_smoke` passed its initial imported-handle copy and
   11 subsequent IM2D/dma-buf operations. This runtime-verifies the earlier
   handle-plane ABI repair on `19634f4eebba`. It then failed the legacy RGB
   resize before scheduling.
2. Official malloc/userptr cases produced 17 new RGA2
   `swiotlb buffer is full` lines. Requested mappings were 416 KiB, 1 MiB, or
   2 MiB even when only 4, 44, or 140 of 32,768 pool slots were in use. This is
   a per-mapping-size failure, not pool exhaustion.
3. The final `reject dma-buf remap ... segment 281 is not adjacent` line was
   emitted for a normal RGA2 internal-MMU fallback. The associated DRM
   allocator demo passed, so the line described an intermediate routing
   decision rather than a rejected job.

## Root cause

`rk_rga_map_userptr_sgt()` used `sg_alloc_table_from_pages()`, which merges
physically adjacent pinned pages into scatterlist entries up to `UINT_MAX`.
RGA2 has a 32-bit DMA mask on this system, so high-memory pages are bounced
through SWIOTLB. Linux limits one SWIOTLB mapping to `IO_TLB_SEGSIZE` (128)
2-KiB slots, or 256 KiB here; a single merged 416-KiB, 1-MiB, or 2-MiB entry
therefore fails regardless of free pool capacity. `dma_max_mapping_size()`
already reports this backend limit.

The legacy RGB failure has a separate ABI cause. A direct rerun with
`ROCKCHIP_RGA_LOG=1` showed a zero-initialized legacy request with
`in_fence_fd=0`. The rewrite treated every nonnegative fd as a real sync-file
and attempted to import stdin, producing `-EINVAL`. Rockchip's source of record
copies the field but tests `request->acquire_fence_fd > 0` before importing a
legacy acquire fence in `drivers/video/rockchip/rga3/rga_job.c`. For legacy
BLIT ioctls, zero is therefore the established absent-fence sentinel. Modern
REQUEST ioctls retain ordinary fd-zero semantics.

The misleading dma-buf diagnostic came from calling
`rk_rga_check_dma_sgt(..., log_errors=true)` before attempting the RGA2
multi-SG fallback. A discontinuous mapping is expected input to that fallback,
so logging it as rejected before the fallback succeeds is incorrect.

## Fix

Byte-identical commits `37ae7459656b` (6.18) and `02bf372dac70` (mainline):

- cap USERPTR scatterlist entries with
  `sg_alloc_table_from_pages_segment(..., dma_max_mapping_size(dev), ...)` so
  every entry is mappable by the selected DMA backend;
- normalize `in_fence_fd == 0` to `-1` only in the kernel-owned legacy BLIT
  task, after preserving the asynchronous reply, and document the ABI rule;
- delay the discontinuous dma-buf diagnostic until the RGA2 internal-MMU
  fallback also fails; and
- extend the existing legacy BLIT KUnit case to cover the fd-zero sentinel
  without changing the 92+152 manifest.

`kernel-drivers/tests/librga-suite.sh` now treats a fatal log as failure
regardless of process status and translates status one to success only when the
same log contains the official sample's explicit terminal `running success!`
message. Its device-free parser regression covers explicit success, fatal
precedence, and refusal to normalize an unexplained status one.

The warning-fatal clean-archive `normal` build passed both fixed commits,
including Rockchip and VSI IOMMU providers, KUnit-enabled MPP/RGA objects, and
the ROCK 5B DTB. Strict checkpatch, shellcheck, the parser unit test, the
305-signal source audit, the manifest check, and cross-tree byte identity also
pass.

## Exact-tip KASAN package build

The 6.18 exact-tip KASAN package build passed with:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  PREFER_DOCKER=yes BASE_TAG=v6.18.42 \
  bash kernel-drivers/scripts/build-kernel.sh rewrite-debug
```

The source range was exactly 385 commits over `v6.18.42`, the source compile
reported 1,465 ccache hits and 55 misses, and the Docker build completed in
47:57. Armbian produced the image, DTB, headers, and libc-development packages
as
`6.18.42-S856a-D6d03-P27bb-Cad24-Hb22f-HK01ba-Vc222-B3ab8-R448a`.
The image embeds release
`6.18.42-video-rewrite-kasan-rockchip64` and source stamp
`g37ae7459656b`. Its packaged config has SHA-256
`8e8fa957ae7e4fa5776116ccf849c7c85486e7cc48ec1fc6ca8b7c8e49aa88b4`
and enables `CONFIG_KASAN`, `CONFIG_KASAN_GENERIC`,
`CONFIG_PROVE_LOCKING`, both rewrite drivers, and both rewrite KUnit suites.

The four package SHA-256 values are:

| Package | SHA-256 |
|---------|---------|
| image | `23a03f6511788e3a2eaff8065ababfa555cebfa5a6c0c64fdf0820b0b82d0e81` |
| DTB | `0fcfde1b5507f2474497763e68fe490e3dfc2f93d76af006478fc2eb17bc258b` |
| headers | `749d48fa429fa056971ecfe9f0819181d9540bc3c74c0a8b9596d156dbdf6c9a` |
| libc development | `996d9371da676479cfebc27682bb91017ff93572ef68d4a0d16fa25815eeb476` |

This is package-build and identity evidence only. None of the runtime gates
below has run on `37ae7459656b`.

**Superseded by the boot result.** `P27bb-Cad24` was installed at 16:42 and did
not boot — no HDMI, no journal, empty pstore — and `37ae7459656b` was reverted.
The legacy fd-zero sentinel described above is correct for userspace but reached
three pending-acquire KUnit cases whose fixtures install a live sync-file on
descriptor zero, because a KUnit case runs in a kthread with an empty file
table. The fixture is now repaired at 6.18 `df22eeef8757` and mainline
`518f59c9f1f8`, which rebuild as `Pc86b-Cad24`. See
[the wedge finding](2026-08-05-rewrite-kunit-fd-zero-boot-wedge.md); the gates
below now apply to that package.

## Boundary and verification gate

The fixes are not runtime-verified. The board run used predecessor
`19634f4eebba`, while the fixed 6.18 tip is now `df22eeef8757`. Install and boot
the built `Pc86b-Cad24` KASAN package from that exact tip, then require:

1. exact ordered 92+152 KUnit with clean outer interval and live lockdep;
2. the full maintained `librga-smoke` including legacy RGB resize;
3. the official librga suite with corrected status classification;
4. no new SWIOTLB mapping failures and no successful RGA2 fallback described
   as a rejected dma-buf remap; and
5. clean debugfs leak/safety counters and the normal fatal dmesg gate.

Until that run, the earlier handle-plane fix is runtime-verified only through
the initial smoke path, while this new source repair has compile and package
identity proof but no runtime proof.
