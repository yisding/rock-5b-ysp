# Verification of the cleanup-draft patches

The `cleanup-draft/` patches are **machine-generated** fixes for the BSP audit
findings (`docs/11`). Before any are applied, every hunk was put through an
**adversarial review**: five independent verifiers each read the *real* source
(callers, locks, refcount/fence balance, error paths) and were told to **try to
break each fix** — to find where a "fix" introduces a *new* bug — rather than
trust that it compiles. The cautionary tale driving this: during the audit's own
assembly, one fix once **double-applied a `kref_put`** — a use-after-free that
**compiled clean**. "It builds" is not verification.

**Result: 2 patches must NOT be applied as written, 1 hunk is on hold, the rest
are safe.** Two of those rejects *compiled clean* and would have shipped real
regressions.

## Verdict table

| Patch | Verdict | Notes |
|-------|---------|-------|
| `mpp_common` | ✅ APPLY | `:250` kzalloc guard is a strict improvement but **incomplete** — also add a NULL check after `get_task_msgs()` on the `SET_SESSION_FD` path (`mpp_common.c:~1580`). |
| `mpp_iommu` | 🛑 **REJECT** | See below. Moved to `rejected/`. |
| `mpp_rkvdec2` | ✅ APPLY | OOB reg-index bounded **one** consistent way (`RKVDEC_REG_NUM`=360 for both the guard and `array_index_nospec`). |
| `mpp_rkvdec2_link` | ✅ APPLY | `:2587` wrong-core fix correct. Pre-existing `attach_ccu` success-path `pdev` leak left unfixed (not a regression). |
| `mpp_rkvenc2` | ✅ APPLY | The `rkvenc_alloc_task` hunk *looks* like the double-`kref_put` trap but is **safe** — `rkvenc_free_class_msg` is idempotent (`kfree(NULL)`+re-NULL). Leave a comment so it stays idempotent. |
| `mpp_service` | ⏸️ APPLY **minus hunk** | `:150` / `:435` (kthread ERR_PTR) / `:445` / `:494` are APPLY. **Drop the `:426` taskqueue-count hunk** (HOLD — its cleanup loop runs with an oversized count → OOB read of `task_queues[]` on a malformed DT). |
| `rga_common` | ✅ APPLY | `size_cal` `int`→`s64` is a strict improvement but **not complete** — a residual `s64` overflow remains reachable only via an adversarial `width≈1.6e9, size=0`. Consider an explicit `w/h` upper bound. |
| `rga_debugger` | ✅ APPLY | `buf[-1]` guard applied uniformly across all four write handlers. |
| `rga_dma_buf` | ✅ APPLY | −58 deletion verified reachability-dead (0 callers). |
| `rga_drv` | ⏸️ APPLY **minus hunk** | D2–D6 are APPLY. **Drop the D1 `rga_ioctl_import_buffer` hunk** (REJECT). |
| `rga_fence` | ✅ APPLY | seqno lock correct (`spin_lock_irqsave`, no nesting). |
| `rga_iommu` | ✅ APPLY | −33 deletion verified dead; `another_index < 0` fix correct. |
| `rga_job` | ✅ APPLY | J2 fence-balance is a strict improvement but leaves **one residual leak** at `rga_job.c:572` (`!user_close_fence` `-EFAULT` path) — add `rga_dma_fence_put(acquire_fence)` there. J3 sleep-in-atomic fix correct. |
| `rga_mm` | ✅ APPLY | M4+M5+M6 are **interdependent** — apply together (M5's idempotent NULLing is what stops M6 from double-`kref_put`-ing). The patch ships all three. `sizeof(*page_table)` fix corrects a 2× over-alloc. |
| `rga_policy` | ✅ APPLY | `:351` "supports ANY"→"supports ALL (superset)" correct; normal ops (`feature==0`) provably unaffected. |

## The two rejects (the catches that justified the review)

### 🛑 `mpp_iommu.patch` — refcount-contract leak at 2 of 3 callers
The fix adds `kref_get_unless_zero` inside `mpp_dma_find_buffer_fd()`, changing
its contract to return **+1 ref** — but only updates one caller
(`mpp_dma_import_fd`). The other two are **not** updated:
- `mpp_dma_release_fd()` (the `RELEASE_FD` ioctl) now does `find`(+1) + one
  `kref_put` → **net zero**: a `TRANS_FD_TO_IOVA` buffer is **never released**
  (IOMMU mapping leaks). `RELEASE_FD` is functionally broken.
- `rkvenc2_task_init()` (the **per-frame encode hot path**) never puts the find
  ref → **one leaked ref per encoded frame**, growing unbounded and permanently
  defeating LRU eviction.

Same root failure mode as the original double-`kref_put` incident — a shared
refcount helper's contract changed without fixing all callers — just in the
*leak* direction the audit's safety note didn't check. **Do not apply.** A correct
rework either drops the extra ref in the two un-updated callers, or adds a
separate `find_and_get` variant used only by `import_fd`.

### 🛑 `rga_drv.patch` hunk D1 — `rga_ioctl_import_buffer` success-path mass-free
The added `err_release_buffer:` cleanup label has **no early `return` on the
success path**, so on success control falls through and **releases every buffer
just imported** (`rga_mm_release_buffer` drops each `kref_init` ref to 0), while
still returning `0`. The ioctl reports "success" with handles that point at
freed/idr-removed buffers → UAF / double-release on first use. (The other five
hunks D2–D6 are clean — apply the patch minus D1, i.e. keep the early `return`
before the label.)

## Verification status

| Method | Status |
|--------|--------|
| Adversarial per-finding review (5 verifiers, real source) | ✅ done — verdicts above |
| Patches apply to the fwport source | ✅ all 15 apply |
| **Compile-gate** (safe set + the devfreq re-guard, OOT build vs 6.18 headers) | ✅ **PASS** — 0 errors, both modules link; fixes confirmed present |
| **Runtime codec regression** (encode/decode/transcode) | ⏳ pending — needs a kernel/module rebuild + reboot |
| Targeted trigger tests (OOB reg-index, `buf[-1]`, SET_SESSION_FD non-mpp fd, …) | ⏳ pending — listed per finding in the verifier notes |

## How to apply the safe set

1. Apply the 12 clean APPLY patches.
2. Apply `rga_drv.patch` **without** its D1 hunk, and `mpp_service.patch`
   **without** its `:426` hunk.
3. **Do not** apply `mpp_iommu.patch` (`rejected/`).
4. Optional follow-ups (not regressions, just incompleteness): the `mpp_common`
   `:1580` companion guard, the `rga_job:572` fence put, the `rga_common` `w/h`
   bound, and the several pre-existing leaks the series leaves behind (noted above).
5. Then the **runtime regression** is the real gate: rebuild, reboot, and re-run
   `tests/` (encode + decode + transcode) plus the targeted triggers.

## Residual & newly-surfaced issues (beyond the 89-finding audit)

The verification didn't just judge the drafts — it surfaced bugs the audit's
three lenses **missed**, and places where an APPLY'd fix is **incomplete**. These
are open follow-ups, ordered by how much they matter; none is a regression *from
applying the safe set* (several are pre-existing).

### Incomplete draft fixes (safe to apply, but don't fully close the bug)
| Site | Gap | Suggested close |
|------|-----|-----------------|
| `mpp_common.c:~1580` (`SET_SESSION_FD` path) | the `:250` `kzalloc`-NULL fix doesn't guard `get_task_msgs()` *here*, so alloc failure still NULL-derefs | `if (!msgs) { fdput(f); goto session_switch_done; }` |
| `rga_job.c:572` (`!user_close_fence` → `-EFAULT`) | `rga_job.patch` J2 balances every fence path **except** this one → `acquire_fence` ref leaks | add `rga_dma_fence_put(acquire_fence);` before the return |
| `rga_common.c:rga_image_size_cal` | the `int`→`s64` fix still overflows `s64` via the `uint32_t memory_parm` path (`width≈1.6e9, size=0`) | bound `w`/`h` (e.g. reject `>65535`), or check `w*h` before `*4` |

### Pre-existing bugs the audit missed (no draft fixes them)
| Site | Bug |
|------|-----|
| `mpp_iommu.c:mpp_dma_find_buffer_fd` | the **race is real** (returns a buffer with no ref; teardown runs under the same mutex) — but the only draft fix is **rejected**, so it remains **open**. Correct fix: take the ref under the lock *and* update all 3 callers (or add a `find_and_get` variant). |
| `mpp_rkvdec2_link.c:rkvdec2_attach_ccu` | **success-path** `pdev` (`of_find_device_by_node`) ref leak — the `rkvenc` analog *is* fixed by `mpp_rkvenc2.patch`, so this is a parity gap. |
| `mpp_rkvenc2.c:rkvenc_attach_ccu` | `np` (`of_node`) leak on the `!np \|\| !available` early-return path. |
| `mpp_rkvenc2.c:rkvenc_core_probe` | the **irq-failure** path leaves `enc` on `ccu->core_list` while devm later frees it → a dangling list entry (potential UAF on a later CCU traversal). The `-EPROBE_DEFER` path (which `mpp_rkvenc2.patch` fixes) is clean; this irq path is not. |
| `mpp_rkvdec2.c` core/default probe | error paths don't unwind `mpp_dev_probe()` (pm_runtime / iommu / service) on failure — broader than the rcb-leak finding the draft *does* fix. |

### Minor / bounded
| Site | Note |
|------|------|
| `rga_mm.c:rga_mm_set_mmu_base` | after the M2 NULL-plane guards, a *malformed* 3-plane request (V plane expected but `handle==0`) leaves some page-table entries uninitialized — bounded **within** the (correctly-sized) allocation, not OOB; only affects an already-invalid request that previously oopsed. |

These came out of the fix-verification, so they belong with it rather than in the
audit's finding tables; a future cleanup pass (or a v2 of these drafts) should
fold in the three "incomplete" closes and tackle the `mpp_iommu` race correctly.
