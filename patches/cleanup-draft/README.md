# cleanup-draft/ — machine-generated BSP cleanup patches (REVIEW BEFORE USE)

Per-file draft fixes for the issues in [`docs/11-bsp-audit.md`](../../docs/11-bsp-audit.md),
produced by the multi-agent audit. They apply on top of the forward-port
(`../`) and target the **shipped `mpp/` + `rga3/` driver code**.

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

```bash
cd <linux-6.18-rkvenc>             # the forward-ported tree
git checkout -b bsp-cleanup
git apply --reject patches/cleanup-draft/mpp_iommu.patch   # one file at a time
# read the diff, sanity-check each hunk against docs/11, build:
make ARCH=arm64 drivers/video/rockchip/
```

Apply, review, and keep only the hunks you're confident in. The audit report is
the durable artifact; these patches are scaffolding to act on it.
