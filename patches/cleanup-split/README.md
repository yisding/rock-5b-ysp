# cleanup-split/ — BSP audit cleanup split by issue

This directory is the reviewable split of `patches/cleanup-draft/`.

The original draft bundled fixes per source file.  This series splits those
bundles into **65 ordered mailbox patches**, with each patch addressing one
issue or one tightly-coupled fix cluster.  Every patch commit message contains:

- `Plain-language impact:` what a normal user should understand.
- `Kernel details:` the concrete driver/refcount/bounds/error-path mechanics.

The final tree produced by applying all 65 patches was checked against the
aggregate `cleanup-draft/*.patch` result and is identical.

## Apply

From the forward-ported kernel tree:

```bash
git am /home/yi/Code/rock-5b-ysp/patches/cleanup-split/*.patch
```

Then build and run the same verification recommended for `cleanup-draft/`:

```bash
make ARCH=arm64 drivers/video/rockchip/
```

## Review notes

- `0007` is intentionally cross-file: it changes the
  `mpp_dma_find_buffer_fd()` reference contract and updates all known callers,
  including `mpp_rkvenc2.c`.  Do not split it further.
- `0053` and `0054` are adjacent parts of the RGA acquire-fence fix: `0053`
  balances the fence references and `0054` changes the `-ENOENT` race result.
- `0059` and `0060` are an RGA handle-buffer mini-series: `0059` normalizes
  `rga_mm_get_buffer()` error cleanup and `0060` depends on that idempotent
  cleanup to unwind partial channel acquisition.
- The arm32-only `mpp_iommu_probe()` `WARN_ON(!mapping)` follow-up remains
  intentionally omitted, matching `cleanup-draft/VERIFICATION.md`.

## Patch index

| Range | Area | Contents |
|-------|------|----------|
| `0001`-`0008` | MPP common/IOMMU | message allocation, session fd validation, fd leaks, request bounds, DMA-buffer ref contract, dead dma-buf cache guards |
| `0009`-`0014` | RKVDEC2 core | RCB parsing/index bounds, CCU resource checks, devm MMU mapping, probe unwind, CCU dispatch |
| `0015`-`0018` | RKVDEC2 link | link-table leak, CCU node/pdev refs, per-core disable logic |
| `0019`-`0024` | RKVENC2 | request-array bounds, task cleanup, procfs string bound, CCU refs, probe unwind |
| `0025`-`0029` | MPP service | device_create error handling, worker cleanup, invalid DT-count unwind |
| `0030`-`0035` | MPP cleanup | debug labels/tracing, dead reset code, dead IRQ wrapper |
| `0036`-`0042` | RGA common/debug/dead code | format names, size math, debugfs write bounds, debug dump fixes, dead dma-buf helpers |
| `0043`-`0051` | RGA ioctl/fence/IOMMU | import/request leaks, stack info leak, runtime PM balance, fence seqno race, dead user-memory helper, core sentinel |
| `0052`-`0055` | RGA job | timeout units, acquire-fence refs/race, shutdown sleep-in-atomic fix |
| `0056`-`0062` | RGA MM | physical-address cleanup, missing-plane validation, page-table sizing, buffer ref cleanup, partial-handle unwind, import unmap |
| `0063`-`0065` | RGA policy | resolution diagnostic, rotation calculation hoist, feature superset check |
