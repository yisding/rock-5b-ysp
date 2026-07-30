# RGA scattered-userptr blit silently returns all-zero output for non-16-byte-aligned source offsets

> Scope: forward-port RGA driver (`rga3`/`rga2`) on the `Pc1f8-C9fc5` KASAN+lockdep debug build (`6.18-rkvenc-fwport`, `6.18.38-current-rockchip64 #7`); driver-owned scattered-userptr IOMMU / cache-line-unaligned-VA path
> Source: on-hardware run of `iommu-machinery-fuzz.sh` (root gate) 2026-07-23, then narrowed with `rga-iommu-fuzz` directly; commits `2b52e8174c127` (map scattered userptr through IOMMU), `d54523f5de378` (shadow_page for cache-line unaligned VA), `392db056b2a07` (cache-line unaligned VA fault fix) — all present in the build
> Date: 2026-07-23
> Trust: MEASURED (deterministic, reproduced) / SOURCE-CONFIRMED (root cause) / FIX-RUNTIME-VERIFIED (`0072`, booted KASAN `#8` @ `4401383a6d9b5`)

## Result

An RGA blit whose **source is a scattered (physically-fragmented) userptr** returns
**all-zero output** unless the source byte offset is a multiple of 16. The blit
completes with **no error, no IOMMU fault, and no KASAN report** — silent data
corruption. Deterministic:

```
rga-iommu-fuzz -o copy -t both -v   (RGBA_8888 copy over swept offsets)
  src_off ∈ {0,16,32,48,...}  → ok           (correct pixels)
  src_off = 1..15, 17..31, ... → MISMATCH     (got=00 want=a5, "at byte 0")
  tally: 0 failures at src_off=0; every failing case has src_off % 16 != 0
```

This is **not** the scatter/IOMMU-remap being broadly broken and **not** a
regression from the `0071` teardown fix. The identical op on a **contiguous**
userptr with the same unaligned offset returns the correct data (the fuzzer's
differential reference, `b=a5`), so the fill / librga / op / offset handling are
all correct — only the driver-owned scattered + sub-16-byte-aligned-source path
produces zeros. The failing intersection is narrow: **userptr (not dma-buf) +
fragmented pages + source offset not 16-byte aligned.** RGA3 requires 16-byte
(4-pixel RGBA) source alignment; the `shadow_page`/unaligned-VA handling that is
supposed to absorb an unaligned head works for the contiguous case but yields a
zero head (and zero output) on the scattered path.

## Evidence and reproduction

- **Identity:** ROCK 5B, `Pc1f8-C9fc5` (`6.18-rkvenc-fwport`, KASAN+lockdep); `rga3` ×2 + `rga2` probed; `/dev/rga` via `video` group.
- **First surfaced:** the very first on-hardware run of the `iommu-machinery-fuzz` root gate (previously always skipped for lack of `sudo`); phase A `rga-iommu-fuzz: PASS=20 FAIL=300`, concurrent `PASS=36 FAIL=540`.
- **Narrowing:** ran `rga-iommu-fuzz -n 64 -o copy -t both -v` → passes exactly at `src_off` ∈ {0,16,32,48}, fails at all others; `-t src` and `-t dst` both fail identically at `src_off≥1`; `--no-boundary-sweep` still fails at non-16-aligned offsets.
- **Oracle:** copy is deterministic; ABSOLUTE `got=00 want=a5` and DIFFERENTIAL scattered(`a=00`) vs contiguous(`b=a5`).
- **Pass/fail signal:** exit non-zero + first-diff report; kernel-log delta clean (`no IOMMU/DMA faults`, 0 KASAN). Board stayed up throughout.
- **Artifacts:** `../rock-5b/rockchip-conformance/logs/iommu-machinery/20260723-061645/` (A-rga.log etc.); scratchpad `postboot-val/`. Not committed (raw captures).

## Root cause (source-confirmed)

RGA3 fetches the source window from a **16-byte-aligned base** — the low 4 bits of
`bRGA3_WIN0_Y_BASE` (`rga3_reg_info.c:397`) are dropped. The scattered-userptr
`shadow_page` path (`rga_mm.c`):

1. L1 cache line is 64 B (`dma_get_cache_alignment()=64`), so `need_head` fires
   for any non-64-aligned offset — every offset 1..63 takes a shadow (`:106`).
2. In `shadow_head` mode it maps page-aligned and keeps `real_offset =
   virt_addr->offset` (`:815`), so `buffer->offset = real_offset` (`:903`) and the
   source base becomes `iova + real_offset` (`rga_mm_lookup_iova`, `:1319`) — the
   **full sub-page byte offset lands in the base**.
3. `rga_shadow_sync_data(to_shadow)` copies the data to `shadow[offset]` for
   `len` (`:162`), leaving `shadow[0..offset)` **zero**.

RGA therefore reads from `(iova + offset) & ~0xf`. When `offset % 16 == 0` that
equals the data start (correct — offsets 0/16/32/48 pass); when `offset % 16 != 0`
it lands in the shadow's zero head → all-zero output. The contiguous path is
unaffected only because the fuzzer fills the whole buffer with the pattern, so a
real page's pre-offset bytes are also `a5`; the shadow's zeroed head is what makes
the misaligned fetch visible.

## Fix (committed `4401383a6d9b5`, compile-verified)

Reject rather than corrupt: `rga_mm_get_buffer_info()` (RGA_IOMMU case) now
returns `-EINVAL` when the resolved IOMMU base is not 16-byte aligned, turning
the **silent all-zero output into a clear error**. This is the correct behavior
for the unsupported cases and is low-risk — aligned userptr and dma-buf always
resolve to a `>=`page-aligned base, so the normal path is untouched. Committed as
forward-port `0072`.

Why *reject* and not the "align base + push residual into `WIN0_ACT_OFF`"
approach first proposed here: the residual can be **sub-pixel**. For RGBA_8888
(4 bytes/pixel) only 4-byte-multiple offsets are valid pixel positions, so of the
failing offsets only the pixel-aligned-but-not-16 subset (4, 8, 12, …) is even
expressible as a whole-pixel window offset; 1/2/3-byte offsets are fundamentally
unrepresentable and must be rejected. A base whose data spans multiple pages also
cannot be relocated to a 16-aligned position (page-granular IOMMU mapping keeps
the offset). So full support would (a) only help a quarter of the cases and (b)
be a format-aware change in the well-tested job/geometry layer — deferred as a
possible follow-up; the reject fully closes the silent-corruption severity.

## BSP comparison (forward-port-introduced, nothing to backport)

The Rockchip BSP does **not** have this path. The three commits that build it —
`2b52e8174c127` (map scattered userptr through IOMMU), `d54523f5de378` (shadow_page
for cache-line unaligned VA), `392db056b2a07` (cache-line unaligned VA fault fix) —
are **absent from the BSP tree** (`git cat-file -e` → absent). BSP `rga_mm.c` has
no `shadow_page`, no `map_offset=0`/`real_offset` split, and no base-alignment
guard, though it computes the base identically (`rga_mm_lookup_iova = iova +
offset`) and maps a scattered userptr with plain `rga_dma_map_sgt`. Without a
shadow there is **no zeroed head**, so the BSP cannot produce the all-zero output;
its behavior for a cache-line-unaligned userptr is what the forward-port commit
`392db056b2a07` is named for — an **access fault** (or a `dma_map_sg` swiotlb
bounce) — i.e. fault/bounce, not silent corruption. The bug is a side effect of
the forward-port `shadow_page` optimization that replaced that fault/bounce path.
This is why `0072` is `FWPORT-ROBUSTNESS`, not a BSP backport.

## Boundary

Root cause is source-confirmed against the register/mapping code and the exact
pass/fail-by-offset signature; the reject fix is now **RUNTIME-VERIFIED** on a
booted KASAN `#8` build (`av1-fwport@4401383a6d9b5`, tail `0001`–`0072`, built
2026-07-23 07:39): `rga-iommu-fuzz` shows the driver rejecting a non-16-aligned
IOMMU base (`-EINVAL`; kernel log `Can't get src buffer info from handle` →
`submit failed`) rather than returning zero output
([validation run](./2026-07-23-forward-port-current-tip-full-validation-run.md)).
The fuzzer's oracle was corrected to **expect** that reject (a reject on a
non-16-aligned base is a pass), so `iommu-machinery-fuzz` now goes green on the
fixed kernel. Still worth confirming on a **non-KASAN production** kernel and
whether `rga2` (its own page-table path) shares the defect. Real-world exposure
is narrow — userptr (not dma-buf) + non-16-aligned source (the corruption hits
the shadow-head path, which any non-cache-aligned userptr takes, contiguous or
fragmented).

## Why it matters / follow-up

A valid-looking RGA API call silently produces wrong (zero) pixels with no error
return — the silent failure is the concerning part, more than the narrow trigger.
Distinct from the `0071` `mm_session` UAF (teardown) and the earlier RGA
request/session UAFs (`0052`/`0057`); this is a **data-path correctness** bug in
the scattered-userptr / cache-line-unaligned-VA handling. Root-caused and the
reject fix landed as `0072` (`4401383a6d9b5`) and is **runtime-verified** (above).
Remaining follow-up: (1) re-run on a **non-KASAN** production build to rule out a
debug-config interaction and for perf; (2) optional enhancement — support the
pixel-aligned-but-not-16 subset via a 16-aligned base + `WIN_ACT_OFF` x-offset
(format-aware, job-layer). Note the reject is *precise*, not collateral: any
`offset % 16 != 0` necessarily also misses cache-line alignment, so it always
coincides with an unowned shadow head — the reject set equals the corrupt set, so
no previously-working caller is broken.
