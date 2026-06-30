# cleanup-draft/ — machine-generated BSP cleanup patches (REVIEW BEFORE USE)

Per-file draft fixes for the issues in [`docs/11-bsp-audit.md`](../../docs/11-bsp-audit.md),
produced by the multi-agent audit. They apply on top of the forward-port
(`../`) and target the **shipped `mpp/` + `rga3/` driver code**.

> **✅ Adversarially verified + corrected — read [`VERIFICATION.md`](VERIFICATION.md) first.**
> Every hunk was reviewed against the real source (verifiers told to *try to
> break* the fix). The review found 2 rejects + 1 hold + 3 incomplete fixes (two
> rejects *compiled clean* — "it builds" is not verification); plus **5
> pre-existing bugs beyond the audit's findings**. **All are now fixed and
> re-verified SAFE**, so all 15 patches apply. **One footgun:** `mpp_iommu.patch`
> and `mpp_rkvenc2.patch` are an **atomic pair** (apply both or neither — see
> VERIFICATION.md). Runtime regression is still the final gate.

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
verified fixes. Severity/rationale per finding is in `docs/11-bsp-audit.md`.
Start review with the **HIGH** items (type-confusion on `SET_SESSION_FD`, OOB
writes via user-controlled register indices, a buffer overflow, refcount/fence
leaks, a sleep-in-atomic, two logic bugs).

## Suggested workflow

These patches are `git show`-style single-commit slices (all 15 carved from
commit `56e403e`), so `git am` / `git apply` work per file. **Heads-up:** the
path `patches/cleanup-draft/…` only exists in *this* repo (`rock-5b-ysp`), not
inside the kernel tree — so apply with an **absolute path** (or `git apply
--directory`), otherwise `git apply` reports "No such file or directory".

```bash
cd /path/to/linux-6.18-rkvenc      # the forward-ported tree
git checkout -b bsp-cleanup

# Absolute path to the patch (it lives in the rock-5b-ysp checkout, not here):
git apply --reject /home/yi/Code/rock-5b-ysp/patches/cleanup-draft/mpp_iommu.patch
#   …or, to keep the commit message:
git am /home/yi/Code/rock-5b-ysp/patches/cleanup-draft/mpp_iommu.patch

# read the diff, sanity-check each hunk against docs/11, build:
make ARCH=arm64 drivers/video/rockchip/
```

Equivalently, run `git apply` from the **rock-5b-ysp** checkout and aim it at the
kernel worktree:

```bash
cd /home/yi/Code/rock-5b-ysp
git --git-dir=/path/to/linux-6.18-rkvenc/.git \
    --work-tree=/path/to/linux-6.18-rkvenc \
    apply --reject patches/cleanup-draft/mpp_iommu.patch
```

Apply, review, and keep only the hunks you're confident in. The audit report is
the durable artifact; these patches are scaffolding to act on it.
