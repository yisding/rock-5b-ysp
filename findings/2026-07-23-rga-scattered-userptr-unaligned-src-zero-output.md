# RGA scattered-userptr blit silently returns all-zero output for non-16-byte-aligned source offsets

> Scope: forward-port RGA driver (`rga3`/`rga2`) on the `Pc1f8-C9fc5` KASAN+lockdep debug build (`6.18-rkvenc-fwport`, `6.18.38-current-rockchip64 #7`); driver-owned scattered-userptr IOMMU / cache-line-unaligned-VA path
> Source: on-hardware run of `iommu-machinery-fuzz.sh` (root gate) 2026-07-23, then narrowed with `rga-iommu-fuzz` directly; commits `2b52e8174c127` (map scattered userptr through IOMMU), `d54523f5de378` (shadow_page for cache-line unaligned VA), `392db056b2a07` (cache-line unaligned VA fault fix) — all present in the build
> Date: 2026-07-23
> Trust: MEASURED (deterministic, reproduced) / SOURCE-CONFIRMED (root cause) / DESIGN (proposed fix, untested)

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

## Proposed fix (design, untested)

Keep the RGA source base 16-byte aligned and move the residual into the window
offset: program `yrgb_addr = iova + (real_offset & ~0xf)` and add
`(real_offset & 0xf)` (converted to pixels) to the source `WIN0_ACT_OFF` x-offset
(`rga3_reg_info.c:404`). Alternative: extend the **source** shadow copy down to the
16-aligned boundary (`offset & ~0xf`) so the aligned-down read hits real data —
safe for reads, but the write-back region for a **destination** shadow must not be
extended. The base-alignment fix is cleaner and covers both directions.

## Boundary

Root cause is source-confirmed against the register/mapping code and the exact
pass/fail-by-offset signature; the **fix is unimplemented and untested**. Still
worth confirming: reproduction on a **non-KASAN production** kernel (rule out any
debug-config interaction) and whether `rga2` (which has its own page-table path)
shares the defect. Real-world exposure is narrow — userptr (not dma-buf) +
physically-fragmented + non-16-aligned source — which is why it went unnoticed
until the fuzzer forced it; the concern is the silent zero output with no error.

## Why it matters / follow-up

A valid-looking RGA API call silently produces wrong (zero) pixels with no error
return — the silent failure is the concerning part, more than the narrow trigger.
Distinct from the `0071` `mm_session` UAF (teardown) and the earlier RGA
request/session UAFs (`0052`/`0057`); this is a **data-path correctness** bug in
the scattered-userptr / cache-line-unaligned-VA handling. Follow-up: (1) re-run
`rga-iommu-fuzz` on a non-KASAN build to confirm it is not a debug-config
artifact; (2) source-trace the `shadow_page` head handling in `rga_dma_buf.c` /
`rga_mm.c` for the scattered multi-segment case against the 16-byte source
requirement; (3) decide whether the driver should correctly handle or explicitly
reject a non-16-aligned scattered userptr source instead of returning zeros. Add
a status.md watchlist row.
