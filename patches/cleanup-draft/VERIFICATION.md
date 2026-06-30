# Verification of the cleanup-draft patches

The `cleanup-draft/` patches are fixes for the BSP audit findings (`docs/11`),
originally **machine-generated**. Every hunk was put through an **adversarial
review**: independent verifiers read the *real* source (callers, locks,
refcount/fence balance, error paths) and were told to **try to break each fix** —
to find where a "fix" introduces a *new* bug — rather than trust that it compiles.
The cautionary tale: during the audit's own assembly, one fix once
**double-applied a `kref_put`** — a use-after-free that **compiled clean**. "It
builds" is not verification.

The first review found **2 rejects + 1 hold + 3 incomplete fixes** (two of which
compiled clean and would have shipped real regressions). Those have now been
**corrected**, and the corrections were **re-verified** by a second adversarial
pass. This doc records the final state.

## Verdict table (after corrections)

| Patch | Verdict | Notes |
|-------|---------|-------|
| `mpp_common` | ✅ APPLY | `:250` kzalloc guard **+ the `:1580` `SET_SESSION_FD` companion NULL-guard** (the earlier incompleteness, now closed). |
| `mpp_iommu` | ✅ APPLY **(corrected)** | was a REJECT — the `find_buffer_fd` +1 contract is now honored by **all 3 callers**. **Must apply together with `mpp_rkvenc2.patch`** (see below). |
| `mpp_rkvdec2` | ✅ APPLY | OOB reg-index bounded one consistent way (`RKVDEC_REG_NUM`=360). |
| `mpp_rkvdec2_link` | ✅ APPLY | `:2587` wrong-core fix correct. (Pre-existing `attach_ccu` success-path `pdev` leak still open — see Residuals.) |
| `mpp_rkvenc2` | ✅ APPLY | The `rkvenc_alloc_task` hunk is safe (idempotent free). **Now also carries the `bs_buf` ref-drop — must apply together with `mpp_iommu.patch`.** |
| `mpp_service` | ✅ APPLY **(corrected)** | the `:426` taskqueue-count cleanup was a HOLD (OOB read) — now clamps `taskqueue_cnt=0` before the cleanup goto, so the loop is empty and `class_destroy` still runs. |
| `rga_common` | ✅ APPLY **(corrected)** | `size_cal` `int`→`s64` **+ a `w/h ≤ 65535` upper bound** (closes the residual `s64` overflow the earlier fix left open). |
| `rga_debugger` | ✅ APPLY | `buf[-1]` guard applied uniformly across all four write handlers. |
| `rga_dma_buf` | ✅ APPLY | −58 deletion verified reachability-dead (0 callers). |
| `rga_drv` | ✅ APPLY **(corrected)** | was a partial REJECT (hunk D1) — `rga_ioctl_import_buffer` now has a success-path `goto` so it no longer frees the buffers it just imported. |
| `rga_fence` | ✅ APPLY | seqno lock correct. |
| `rga_iommu` | ✅ APPLY | −33 deletion verified dead; `another_index < 0` fix correct. |
| `rga_job` | ✅ APPLY **(corrected)** | J3 sleep-in-atomic fix correct; J2 fence-balance **+ the `:572` acquire-fence put** (the residual leak, now closed). |
| `rga_mm` | ✅ APPLY | M4+M5+M6 are interdependent — apply together (the patch ships all three). |
| `rga_policy` | ✅ APPLY | `:351` superset test correct. |

**All 15 patches now APPLY** (the rejected one was corrected; `rejected/` is gone).

## Corrections applied (and re-verified SAFE)

| # | Site | Was | Correction | Re-verify |
|---|------|-----|------------|-----------|
| 1 | `rga_drv` `rga_ioctl_import_buffer` | 🛑 REJECT — success path fell into `err_release_buffer:` and freed every just-imported buffer | added `goto err_free_external_buffer;` before the label | SAFE — all 3 error paths + `size==0` traced correct |
| 2 | `mpp_iommu` find-contract | 🛑 REJECT — `find` returns +1 but only 1 of 3 callers updated → 2 leaks | `release_fd` drops the temp ref (2nd `kref_put`); `rkvenc2_task_init` drops it via `mpp_dma_release` | SAFE — net `−1`/`net 0` preserved; `kref_get_unless_zero` ⟹ ref≥2 so the first put can't free; `bs_buf` held by the mem_region import ref; exactly 3 callers, all balanced |
| 3 | `mpp_service:426` | ⏸️ HOLD — cleanup loop ran with an oversized count → OOB read | `srv->taskqueue_cnt = 0;` before the goto | SAFE — loop runs 0×, `class_destroy` still runs, no double-destroy |
| 4 | `mpp_common:1580` | incomplete — `SET_SESSION_FD` `get_task_msgs` unguarded | `if (!msgs) { fdput(f); goto session_switch_done; }` | SAFE — deref closed, `fdput` balanced, post-label can't double-add |
| 5 | `rga_job:572` | incomplete — `acquire_fence` leaked on the `-EFAULT` path | `rga_dma_fence_put(acquire_fence);` before the return | SAFE — all 5 exit paths exclusive, one put each |
| 6 | `rga_common` `size_cal` | incomplete — residual `s64` overflow via `uint32_t` dims | `if (w > 65535 || h > 65535) return -EINVAL;` | SAFE — 65535 == the `uint16` dim max, rejects nothing legitimate |

> **⚠️ `mpp_iommu.patch` + `mpp_rkvenc2.patch` are an ATOMIC PAIR — apply both or
> neither.** The `find_buffer_fd` +1 contract change (mpp_iommu) and the
> `rkvenc2_task_init` ref-drop (mpp_rkvenc2) balance each other. Applying
> `mpp_iommu` alone → a leaked ref per JPEGE task; applying `mpp_rkvenc2` alone →
> a premature ref drop → **UAF/double-free**. (`rga_mm`'s M4+M5+M6 trio is the same
> kind of within-patch interdependency, already shipped together.)

## Verification status

| Method | Status |
|--------|--------|
| Adversarial per-finding review (real source) | ✅ done |
| Corrections re-verified (independent adversarial pass) | ✅ **SAFE** — refcount balance traced on every path |
| Patches apply to fwport HEAD | ✅ all 15 apply clean |
| **Compile-gate** (safe set + the devfreq re-guard, OOT build vs 6.18 headers) | ✅ **PASS** — 0 errors, both modules link |
| **Runtime codec regression** (encode/decode/transcode + targeted triggers) | ⏳ pending — needs a kernel/module rebuild + reboot |

## Residual issues still open (pre-existing, the audit missed; NOT fixed here)

The corrections closed the 3 incompletes **and** the `mpp_dma_find_buffer_fd` race
(the mpp_iommu fix). These pre-existing bugs the verification surfaced remain
**open follow-ups** — none is a regression from applying the safe set:

| Site | Bug |
|------|-----|
| `mpp_rkvdec2_link.c:rkvdec2_attach_ccu` | success-path `pdev` (`of_find_device_by_node`) leak — parity gap vs the fixed `rkvenc` analog. |
| `mpp_rkvenc2.c:rkvenc_attach_ccu` | `np` (`of_node`) leak on the `!np \|\| !available` early-return. |
| `mpp_rkvenc2.c:rkvenc_core_probe` | irq-failure path leaves `enc` on `ccu->core_list` while devm frees it → dangling entry. |
| `mpp_rkvdec2.c` core/default probe | error paths don't unwind `mpp_dev_probe()` (pm_runtime / iommu / service). |
| `rga_mm.c:rga_mm_set_mmu_base` | a *malformed* 3-plane request leaves some page-table entries uninitialized — bounded (in-allocation), not OOB. |

## How to apply the safe set

1. Apply all 15 patches — **but `mpp_iommu.patch` and `mpp_rkvenc2.patch` must go
   together** (atomic pair, above), and `rga_mm.patch` ships its M4+M5+M6 trio
   together.
2. Compile-check (`make ARCH=arm64 drivers/video/rockchip/`).
3. Then the **runtime regression** is the real gate: rebuild, reboot, and re-run
   `tests/` (encode + decode + transcode) plus the targeted triggers from the
   verifier notes (the OOB reg-index, `buf[-1]`, a non-mpp fd to `SET_SESSION_FD`,
   `RELEASE_FD` + re-import, an async RGA acquire-fence).
4. The Residual follow-ups above are optional but worth a v2.
