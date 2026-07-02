# cleanup-draft/ — per-file history + verification record (apply via ../cleanup-split/)

> **Review/apply via [`../cleanup-split/`](../cleanup-split/).** This directory
> is the **per-file history and the verification record** of the BSP-audit
> fixes: the original machine-generated bundles plus
> [`verification.md`](verification.md), the adversarial-review verdicts. The
> one-issue-per-patch series in `cleanup-split/` supersedes these bundles for
> review and application (and has since been strengthened beyond them — see its
> README's divergence table).

Per-file draft fixes for the issues in [BSP audit](../../docs/bsp-audit.md),
produced by the multi-agent audit. They apply on top of the forward-port
(`../`) and target the **shipped `mpp/` + `rga3/` driver code**.

> **✅ Adversarially verified + corrected — read [`verification.md`](verification.md) first.**
> Every hunk was reviewed against the real source (verifiers told to *try to
> break* the fix). The review found 2 rejects + 1 hold + 3 incomplete fixes (two
> rejects *compiled clean* — "it builds" is not verification); plus **5
> pre-existing bugs beyond the audit's findings**. **All are now fixed and
> re-verified SAFE**, so all 15 patches apply. **One footgun:** `mpp_iommu.patch`
> and `mpp_rkvenc2.patch` are an **atomic pair** (apply both or neither — see
> verification.md). Runtime regression is still the final gate.

> **⚠️ Runtime gate PENDING** — the runtime codec regression test (encode/decode/transcode plus the targeted triggers listed in `kernel-drivers/patches/cleanup-draft/verification.md`) has **never been run** on a kernel carrying these fixes. Compile status alone is not verification. Do not ship the series without the runtime gate; track it in `status.md` and record the result in `kernel-drivers/patches/cleanup-draft/verification.md` when run.

## ⚠️ These are a draft, not merge-ready

- **Machine-generated**, adversarially-LLM-verified, and **compile-tested on
  arm64** (`make ARCH=arm64 drivers/video/rockchip/` → 0 errors) — but **not
  human-merge-reviewed**.
- During assembly, one ambiguous text-match doubled a `kref_put` in
  `mpp_dma_release()` and introduced a **use-after-free**; it compiled fine and
  was caught/reverted by hand. So: **review every hunk**, especially anything
  touching refcounts, bounds, or user input, before applying.
- One arm32-only edit (`CONFIG_ARM_DMA_USE_IOMMU`, `mpp_iommu.c` `WARN_ON(!mapping)`)
  was intentionally **left unapplied** — untestable on the arm64 target.

## What's here

15 per-file patches (`mpp_*.patch`, `rga_*.patch`), each bundling that file's
verified fixes. Severity/rationale per finding is in `kernel-drivers/docs/bsp-audit.md`.
Start review with the **HIGH** items (type-confusion on `SET_SESSION_FD`, OOB
writes via user-controlled register indices, a buffer overflow, refcount/fence
leaks, a sleep-in-atomic, two logic bugs).

| Patch | Target file | Bundles (full hunk→finding map: [BSP audit §Per-patch map](../../docs/bsp-audit.md#per-patch-hunk--finding-map); verdicts: [verification.md](verification.md)) |
|-------|-------------|------------------------------------------------------------------|
| `mpp_common.patch` | `mpp/mpp_common.c` | kzalloc null-deref guard, `SET_SESSION_FD` type-confusion + fd leaks, register-request clamp, copy-length check |
| `mpp_iommu.patch` | `mpp/mpp_iommu.c` | `find_buffer_fd` +1 ref contract, dead `CONFIG_DMABUF_CACHE` guards — **atomic pair with `mpp_rkvenc2.patch`** |
| `mpp_rkvdec2.patch` | `mpp/mpp_rkvdec2.c` | OOB reg-index write bound (`RKVDEC_REG_NUM`), ERR_PTR/devm/probe-unwind fixes, RCB leak |
| `mpp_rkvdec2_link.patch` | `mpp/mpp_rkvdec2_link.c` | link-table leak, `of_node`/`pdev` refs, wrong-core `disable` fix, dead CRU code, debug labels |
| `mpp_rkvenc2.patch` | `mpp/mpp_rkvenc2.c` | request-array overflow bounds, `free_task` leak, procfs `%8.8s`, dead IRQ wrapper, `mpp_dev_remove` — **atomic pair with `mpp_iommu.patch`** |
| `mpp_service.patch` | `mpp/mpp_service.c` | `device_create` check, taskqueue/resetgroup count unwind, `kthread_run` ERR_PTR, fail_register cleanup |
| `rga_common.patch` | `rga3/rga_common.c` | swapped 10-bit 4:2:0 format names, `size_cal` `int`→`s64` + 65535 dim bound |
| `rga_debugger.patch` | `rga3/rga_debugger.c` | `buf[-1]` empty-write guard in all four write handlers, dump format string, `task_count` race, `size<=0` leak |
| `rga_dma_buf.patch` | `rga3/rga_dma_buf.c` | delete dead `rga_virtual_memory_check` / `rga_dma_memory_check` helpers |
| `rga_drv.patch` | `rga3/rga_drv.c` | import orphan + success-path fix, errno-in-u32, request ref leak, version-ioctl infoleak, `pm_runtime` balance |
| `rga_fence.patch` | `rga3/rga_fence.c` | serialize the unlocked `++seqno` |
| `rga_iommu.patch` | `rga3/rga_iommu.c` | delete dead `rga_user_memory_check`, `another_index < 0` sentinel fix |
| `rga_job.patch` | `rga3/rga_job.c` | jiffies-vs-ms timeout units, scheduler race, sleep-in-atomic fix, acquire-fence puts |
| `rga_mm.patch` | `rga3/rga_mm.c` | NULL-plane deref, element-size page-table alloc, `rga_mm_get_buffer` kref/out-param, channel unwind (**M4+M5+M6 trio — never split**), idr leak |
| `rga_policy.patch` | `rga3/rga_policy.c` | resolution-range log, `need_swap` hoist, feature-**superset** check |

## Suggested workflow

These patches are `git show`-style single-commit slices (all 15 carved from
commit `56e403e`), so `git am` / `git apply` work per file. **Heads-up:** the
path `kernel-drivers/patches/cleanup-draft/…` only exists in *this* repo (`rock-5b-ysp`), not
inside the kernel tree — so apply with an **absolute path** (or `git apply
--directory`), otherwise `git apply` reports "No such file or directory".

```bash
YSP=/path/to/rock-5b-ysp           # this repo's checkout
cd /path/to/linux-6.18-rkvenc      # the forward-ported tree
git checkout -b bsp-cleanup

# Absolute path to the patch (it lives in the rock-5b-ysp checkout, not here):
git apply --reject "$YSP"/kernel-drivers/patches/cleanup-draft/mpp_iommu.patch
#   …or, to keep the commit message:
git am "$YSP"/kernel-drivers/patches/cleanup-draft/mpp_iommu.patch

# read the diff, sanity-check each hunk against kernel-drivers/docs/bsp-audit.md, build:
make ARCH=arm64 drivers/video/rockchip/
```

Equivalently, run `git apply` from the **rock-5b-ysp** checkout and aim it at the
kernel worktree:

```bash
cd "$YSP"
git --git-dir=/path/to/linux-6.18-rkvenc/.git \
    --work-tree=/path/to/linux-6.18-rkvenc \
    apply --reject kernel-drivers/patches/cleanup-draft/mpp_iommu.patch
```

Apply, review, and keep only the hunks you're confident in — **subject to the
atomicity constraints in [`verification.md`](verification.md)**: per-hunk
cherry-picking must never separate `mpp_iommu.patch` from `mpp_rkvenc2.patch`
(the atomic pair) nor split `rga_mm.patch`'s interdependent M4+M5+M6 trio —
dropping one half of a balanced refcount change is how you manufacture a
UAF/double-free out of two individually-plausible diffs. The audit report is
the durable artifact; these patches are scaffolding to act on it.
