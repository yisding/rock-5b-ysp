# cleanup-split/ — BSP audit cleanup split by issue

This directory is **the reviewable form of the BSP-audit fixes**: the per-file
bundles in [`../cleanup-draft/`](../cleanup-draft/) split into **65 ordered
mailbox patches**, each addressing one issue or one tightly-coupled fix cluster.
Review and apply **this** series; `cleanup-draft/` remains as the per-file
history and the home of the verification record
([`verification.md`](../cleanup-draft/verification.md)). Findings and rationale:
[BSP audit](../../docs/bsp-audit.md).

Every patch commit message contains:

- `Plain-language impact:` what a normal user should understand.
- `Kernel details:` the concrete driver/refcount/bounds/error-path mechanics.

> **⚠️ Runtime gate PENDING** — the runtime codec regression test (encode/decode/transcode plus the targeted triggers listed in `kernel-drivers/patches/cleanup-draft/verification.md`) has **never been run** on a kernel carrying these fixes. Compile status alone is not verification. Do not ship the series without the runtime gate; track it in `status.md` and record the result in `kernel-drivers/patches/cleanup-draft/verification.md` when run.

## History and verification state

Two commits produced this directory (both 2026-07-01):

- **`aa859ad`** — the initial 65-patch drop. Its applied tree was
  **byte-identical** to the corrected `cleanup-draft/` aggregate (re-verified
  2026-07-01: `git am` of the aa859ad series onto the forward-port tip
  `5614909e5803`, then `git diff` against the draft-patches-applied tree —
  empty). So the aa859ad content is exactly what
  [`verification.md`](../cleanup-draft/verification.md) adversarially verified
  and compile-gated.
- **`808f7cb`** "Fix split BSP audit cleanup patches" — regenerated all 65
  patches from a real applied tree (real authorship + `Signed-off-by:`,
  full-width blob index hashes) **and deliberately strengthened several fixes
  beyond the draft**. The applied tree therefore **no longer matches** the
  draft aggregate: **8 files diverge** (verified 2026-07-01, table below).

The 808f7cb strengthenings **postdate the adversarial verification** — the
SAFE verdicts in verification.md cover only the content shared with the draft.
Treat the rows below as the review-priority delta:

| Area | `cleanup-draft/` aggregate | this series (post-`808f7cb`) |
|------|----------------------------|------------------------------|
| `alloc_task` error returns | `rkvdec2_alloc_task` / `rkvdec2_ccu_alloc_task` return `NULL` on task-init failure | return `ERR_PTR(ret)`; `mpp_process_task_default` and `rkvdec2_link_process_task` gained `IS_ERR()` handling so the real errno propagates |
| `SET_SESSION_FD` alloc failure (`mpp_collect_msgs`) | `fdput(f); goto session_switch_done;` (the form verification.md correction #4 records) | `fdput(f); return -ENOMEM;` |
| `mpp_dma_release_fd` | temp-ref lookup, then re-lock + two `kref_put`s (an unlock window between find and release) | lookup factored into a new `mpp_dma_find_buffer_dmabuf_locked()` helper; find + put run under a **single** `list_mutex` hold, one `dma_buf` get/put |
| `rkvdec2_ccu_probe` clk/reset lookup | log-and-continue on any failure | non-`-ENOENT` errors are fatal (`dev_err_probe` + return) |
| rkvdec2 probe unwind | — | error paths (`err_free_rcb`, `rkvdec2_probe_default` irq failure) additionally call `rkvdec2_link_remove()` |
| `rkvenc_core_probe` `failed:` path | — | frees the RCB buffer via `rkvenc2_free_rcbbuf()` — **source of the 0024 compile defect below** |
| `mpp_service_probe` worker threads | `kthread_run` failure logged, probe continues | failure is fatal (`goto fail_register`) |
| rga3 headers | dead-helper prototypes retained | `rga_virtual_memory_check` / `rga_dma_memory_check` / `rga_user_memory_check` prototypes removed together with their dead helpers (`0042`/`0049`) |

### ❌ Known defect: the current series does not compile (verified 2026-07-01)

`808f7cb`'s revision of **`0024`** added a call to `rkvenc2_free_rcbbuf()` in
`rkvenc_core_probe()`'s `failed:` label, but that function is `static` and
defined ~90 lines *later* in `mpp_rkvenc2.c`, with no forward declaration —
`-Werror=implicit-function-declaration` kills the build at `mpp_rkvenc2.o`
(the aa859ad version of 0024 did not have the call and matched the
compile-gated draft tree). Remedy: regenerate `0024` with a file-scope

```c
static int rkvenc2_free_rcbbuf(struct platform_device *pdev, struct rkvenc_dev *enc);
```

above `rkvenc_core_probe()`. **TODO:** fold the fix into a regenerated series.
With exactly that one-line shim, the rest was verified 2026-07-01 to compile
with **0 errors** and link both modules (out-of-tree build using the
[`packaging/dkms/`](../../../packaging/dkms/) Kbuilds against the installed
`6.18.37-current-rockchip64` headers, devfreq re-guard applied), up to the
**expected** modpost `exported twice` clash — the running combined kernel
carries the drivers `=y`, so an OOT link against it can never complete
([`packaging/dkms/README.md`](../../../packaging/dkms/README.md) caveat 1).

### Verification scoreboard

| Check | Status |
|-------|--------|
| `git am` of all 65 onto forward-port tip `5614909e5803` | ✅ clean (verified 2026-07-01) |
| Applied tree vs corrected `cleanup-draft/` aggregate | ⚠️ diverges in 8 files — deliberate `808f7cb` strengthenings (table above) |
| Adversarial review ([`verification.md`](../cleanup-draft/verification.md)) | ✅ for the content shared with the draft; ⚠️ **not re-run** for the `808f7cb` delta |
| Compile | ❌ fails at `0024` (missing forward declaration); 0 errors elsewhere with the one-line shim (2026-07-01) |
| Runtime codec regression | ⏳ **pending** — see the warning above and [`status.md`](../../../status.md) |

## Apply

From the forward-ported kernel tree
([source-tree pins](../../../docs/source-trees.md) §1 — `v6.18` + the two
`kernel-drivers/patches/rk3588-rkvenc2-*.patch`):

```bash
YSP=/path/to/rock-5b-ysp          # this repo's checkout
cd /path/to/linux-6.18-rkvenc     # the forward-ported tree
git am "$YSP"/kernel-drivers/patches/cleanup-split/*.patch
```

Then compile-check (in-tree form; the OOT form is the `packaging/dkms/`
Kbuilds):

```bash
make ARCH=arm64 drivers/video/rockchip/
```

…which currently **fails at 0024** (defect above) until the forward
declaration is added. After a successful build, the **runtime regression** is
the real gate — [`../../tests/`](../../tests/) plus the targeted triggers in
[`verification.md`](../cleanup-draft/verification.md) §How to apply the safe set.

## Review notes — do not cherry-pick past these

- **`0007` is intentionally cross-file and must never be split or dropped
  while taking later rkvenc2 patches.** It changes the
  `mpp_dma_find_buffer_fd()` reference contract and updates all known callers
  **including `mpp_rkvenc2.c`** — it is the split-series embodiment of
  verification.md's `mpp_iommu` + `mpp_rkvenc2` **atomic pair** (iommu side
  alone → leaked ref per JPEGE task; rkvenc2 side alone → premature ref drop →
  UAF/double-free). If you take any of `0019`–`0024` from the index table
  below, take `0007` too.
- `0053` and `0054` travel as a pair: adjacent parts of the RGA acquire-fence
  fix — `0053` balances the fence references and `0054` changes the `-ENOENT`
  race result.
- `0059` and `0060` travel as a pair: an RGA handle-buffer mini-series —
  `0059` normalizes `rga_mm_get_buffer()` error cleanup and `0060` depends on
  that idempotent cleanup to unwind partial channel acquisition.
- The arm32-only `mpp_iommu_probe()` `WARN_ON(!mapping)` follow-up remains
  intentionally omitted, matching
  [`verification.md`](../cleanup-draft/verification.md) §Known unfixed items.

## Patch index

| Range | Area | Contents |
|-------|------|----------|
| `0001`-`0008` | MPP common/IOMMU | message allocation, session fd validation, fd leaks, request bounds, DMA-buffer ref contract, dead dma-buf cache guards |
| `0009`-`0014` | RKVDEC2 core | RCB parsing/index bounds, CCU resource checks, devm MMU mapping, probe unwind, CCU dispatch |
| `0015`-`0018` | RKVDEC2 link | link-table leak, CCU node/pdev refs, per-core disable logic |
| `0019`-`0024` | RKVENC2 | request-array bounds, task cleanup, procfs string bound, CCU refs, probe unwind — **needs `0007`, see Review notes** |
| `0025`-`0029` | MPP service | device_create error handling, worker cleanup, invalid DT-count unwind |
| `0030`-`0035` | MPP cleanup | debug labels/tracing, dead reset code, dead IRQ wrapper |
| `0036`-`0042` | RGA common/debug/dead code | format names, size math, debugfs write bounds, debug dump fixes, dead dma-buf helpers |
| `0043`-`0051` | RGA ioctl/fence/IOMMU | import/request leaks, stack info leak, runtime PM balance, fence seqno race, dead user-memory helper, core sentinel |
| `0052`-`0055` | RGA job | timeout units, acquire-fence refs/race (`0053`+`0054` pair), shutdown sleep-in-atomic fix |
| `0056`-`0062` | RGA MM | physical-address cleanup, missing-plane validation, page-table sizing, buffer ref cleanup, partial-handle unwind (`0059`+`0060` pair), import unmap |
| `0063`-`0065` | RGA policy | resolution diagnostic, rotation calculation hoist, feature superset check |
