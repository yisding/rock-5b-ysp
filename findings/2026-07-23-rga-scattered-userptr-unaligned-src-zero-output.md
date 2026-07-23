# RGA scattered-userptr blit silently returns all-zero output for non-16-byte-aligned source offsets

> Scope: forward-port RGA driver (`rga3`/`rga2`) on the `Pc1f8-C9fc5` KASAN+lockdep debug build (`6.18-rkvenc-fwport`, `6.18.38-current-rockchip64 #7`); driver-owned scattered-userptr IOMMU / cache-line-unaligned-VA path
> Source: on-hardware run of `iommu-machinery-fuzz.sh` (root gate) 2026-07-23, then narrowed with `rga-iommu-fuzz` directly; commits `2b52e8174c127` (map scattered userptr through IOMMU), `d54523f5de378` (shadow_page for cache-line unaligned VA), `392db056b2a07` (cache-line unaligned VA fault fix) — all present in the build
> Date: 2026-07-23
> Trust: MEASURED (deterministic, reproduced) / SOURCE-CONFIRMED (root cause) / FIX-COMMITTED (`0072`, compile-verified)

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
- **Artifacts:** `../rockchip-conformance/logs/iommu-machinery/20260723-061645/` (A-rga.log etc.); scratchpad `postboot-val/`. Not committed (raw captures).

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

## Boundary

Root cause is source-confirmed against the register/mapping code and the exact
pass/fail-by-offset signature; the reject fix is **COMPILE-VERIFIED only** —
re-run `iommu-machinery-fuzz` on a rebuilt kernel to confirm misaligned cases now
return `-EINVAL` (the fuzzer treats that as a failure too, since it forces an
unsupported input, so it will not go green — that is expected). Still worth
confirming reproduction on a **non-KASAN production** kernel and whether `rga2`
(its own page-table path) shares the defect. Real-world exposure is narrow —
userptr (not dma-buf) + physically-fragmented + non-16-aligned source.

## Why it matters / follow-up

A valid-looking RGA API call silently produces wrong (zero) pixels with no error
return — the silent failure is the concerning part, more than the narrow trigger.
Distinct from the `0071` `mm_session` UAF (teardown) and the earlier RGA
request/session UAFs (`0052`/`0057`); this is a **data-path correctness** bug in
the scattered-userptr / cache-line-unaligned-VA handling. Root-caused and the
reject fix landed as `0072` (`4401383a6d9b5`). Remaining follow-up: (1) rebuild +
boot and re-run `iommu-machinery-fuzz` to confirm misaligned cases now return
`-EINVAL`; (2) re-run on a **non-KASAN** build to rule out a debug-config
interaction; (3) optional enhancement — support the pixel-aligned-but-not-16
subset via a 16-aligned base + `WIN_ACT_OFF` x-offset (format-aware, job-layer).
Add a status.md watchlist row for (1)/(2).
