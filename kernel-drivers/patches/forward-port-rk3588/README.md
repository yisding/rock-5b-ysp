# forward-port-rk3588/

The **single** RK3588 MPP/RGA/AV1 forward-port patch series for Armbian
`rockchip64-current` / Linux 6.18, exported from branch **`rk3588-video-6.18`**
(the one canonical forward-port branch).

> **Provenance and BSP-backport verdicts** — per-patch class (`PORT` / `VENDOR` /
> `BSP-BUG` / …) and which fixes to carry back to Rockchip's `develop-6.1` — live
> in the [patch catalog](../../docs/patch-catalog.md). This README is the
> mechanical index; reference a patch by its **title** (stable across renumbering),
> not by its sequence number.

## Reference patches by title, not number

The sequence numbers here are just apply order. They are **not stable** — a
renumber (dropping/reordering a patch) shifts them. Cite a patch by its title or
commit (both in the index below); the number is only a locator for the file in
this directory. Dated `findings/` keep the numbers that were current when they
were written — resolve any older number through the **renumber map** at the end.

## 2026-07-23 cleanup

- **One branch.** The old `av1` / non-`av1` split is gone: AV1 (the RKMPP AV1
  decoder + Verisilicon IOMMU provider) is baked into the single line. The
  canonical branch is `rk3588-video-6.18`; the stale `rkvenc-fwport-*`,
  `*-route-b`, `*-rga-abi-fixes*`, `*-procfs-fix`, and `*-iommu-debug` branches
  are retired.
- **Directory renamed** from `forward-port-rk3588-av1/` (dropped the `-av1`);
  file prefix `rk3588-av1-fwport-` → `rk3588-fwport-`.
- **Renumbered contiguous `0001`–`0071`.** A stray `tools: libbpf: make kallsyms
  helpers const-correct` commit that had been sitting at old-`0012` (never part
  of the video forward-port; it was always excluded from the export, leaving a
  gap) was dropped from the branch. The resulting driver/DT tree is
  **byte-identical** to the previously validated tip `4401383a6d9b5` — only
  `tools/lib/bpf/libbpf.c` differs — so the booted `#8` validation still holds.
- Renumber rule: old `0001`–`0011` unchanged; old `0013`–`0072` → new
  `0001`-shifted-down-by-one (i.e. **old N → new N−1 for N ≥ 13**); old `0012`
  removed. Every patch's prior number is in the **Was** column below.

## Source

Exported with `git format-patch 7d0a66e4bb908..rk3588-video-6.18` from the kernel
worktree at `../kernel/linux-6.18-rkvenc-av1-fwport` (branch `rk3588-video-6.18`,
tip `39750d2e3b60`). Backup of the pre-cleanup tip: tag
`backup/pre-reorg-20260723` (`4401383a6d9b5`). Generated fallback/official `.deb`
files in the external build workspace are intentionally not tracked here — only
the `git format-patch` text is source material.

## The series, by campaign group

The order is the campaign order the series was built in: import base → mainline
integration → vendor RGA reconciliation → locally-found fixes → BSP-audit HIGH
port → the forward-port follow-ups. Full mechanics per patch are in the commit
messages; provenance/backport is in the [catalog](../../docs/patch-catalog.md).

### 0001–0002 — Import base

Vendor RK3588 MPP/RGA driver import + RK3588 device tree.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0001` | video: rockchip: RK3588 vendor MPP (rkvenc2/rkvdec2) + RGA3/RGA2 drivers | `924f4232546d` | — |
| `0002` | arm64: dts: rockchip: rk3588: VEPU580 encoder, rkvdec2 decoder, RGA3 nodes | `5614909e5803` | — |

### 0003–0016 — Mainline forward-port integration

Everything that exists only because the target is mainline 6.18 (IOMMU/DMA provider hooks, Verisilicon AV1 provider, DT, port-fix hardening). Not BSP-relevant.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0003` | media: rockchip: mpp: route iommu fault handling through provider hooks | `07742fdfbbff` | — |
| `0004` | media: rockchip: mpp: add mpp_iommu_shared_domain CCU helper | `648daa421602` | — |
| `0005` | iommu: add Verisilicon IOMMU provider and Rockchip provider media hooks | `72ad822990fb` | — |
| `0006` | video: rockchip: mpp: forward-port MPP core and rkvdec2/rkvenc2 to 6.18 | `23ff47eab6f6` | — |
| `0007` | video: rockchip: mpp: add RKMPP AV1 decoder | `538d69525532` | — |
| `0008` | video: rockchip: rga: depend on ROCKCHIP_IOMMU and harden version string | `71bcd51ccb43` | — |
| `0009` | arm64: dts: rockchip: rk3588: add decoder/AV1 IOMMUs, SRAM and node wiring | `92e08bc80f54` | — |
| `0010` | video: rockchip: mpp: convert rkvenc2 CCU attach to shared-domain helper | `2dae7f05f528` | — |
| `0011` | video: rockchip: mpp: harden CCU shared-domain RCB windows and reset paths | `5983ccd09a76` | — |
| `0012` | iommu: rockchip: restore large DMA segment support | `b3d577f97260` | `0013` |
| `0013` | video: rockchip: rga: keep IOVAs below 32-bit wrap guard | `27cbfcb3254d` | `0014` |
| `0014` | media: rockchip: harden IOMMU forward port | `890f63905869` | `0015` |
| `0015` | media: rockchip: rga3: map scattered userptr through IOMMU | `f2250adc8ea2` | `0016` |
| `0016` | media: rockchip: keep rkvenc RCB SRAM optional | `1c17825c4099` | `0017` |

### 0017–0036 — Vendor develop-5.10 RGA reconciliation

Rockchip-authored RGA fixes cherry-picked from develop-5.10 (batching, request lifetime, shadow_page, CSC/scale correctness). Already Rockchip's.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0017` | video: rockchip: rga: add RK3588 low-voltage workarounds | `7f6a45e74fd3` | `0018` |
| `0018` | video: rockchip: rga3: support hardware batching | `38e81610a400` | `0019` |
| `0019` | video: rockchip: rga3: fix RGA2/RGA3 slave_mode execution failure after master_mode | `be4fe6f1b7a1` | `0020` |
| `0020` | video: rockchip: rga3: fix request leak when multi-task submit failed | `796571e72b6a` | `0021` |
| `0021` | video: rockchip: rga3: fix request submit failed when acquire_fence is already signaled | `28ab788af387` | `0022` |
| `0022` | video: rockchip: rga3: fix page fault caused by IOMMU prefetch | `f65078016123` | `0023` |
| `0023` | video: rockchip: rga3: add shadow_page for cache-line unaligned VA | `a0160273e9a3` | `0024` |
| `0024` | video: rockchip: rga3: fix cache-line unaligned VA access fault | `c05bc08cecfe` | `0025` |
| `0025` | video: rockchip: rga3: fix VA map size calculation | `522f3e122206` | `0026` |
| `0026` | video: rockchip: rga3: fix return value of rga_mm_lookup_iova() on error | `6d4ab1572f04` | `0027` |
| `0027` | video: rockchip: rga3: fix bi-linear scale-down coefficient check | `a2a5d91a7d78` | `0028` |
| `0028` | video: rockchip: rga3: mpi_commit: add protection when scale-up | `472b7e6ad071` | `0029` |
| `0029` | video: rockchip: rga3: enable config_intr and support parse error status | `7df90e9b89cc` | `0030` |
| `0030` | video: rockchip: rga3: fix incorrect check in update_LUT mode | `8a5423c1eefa` | `0031` |
| `0031` | video: rockchip: rga3: keep hardware tables file-local | `ebeb267cada5` | `0032` |
| `0032` | video: rockchip: rga3: clear tile4x4 chroma bases | `31967d0316b0` | `0033` |
| `0033` | video: rockchip: rga3: mpi_commit: restore output_params in rotate 90/270 | `fec94d803ff4` | `0034` |
| `0034` | video: rockchip: rga3: mpi_commit: fix operator typo (| to ||) in rotate_mode check | `18ad9b2277f9` | `0035` |
| `0035` | video: rockchip: rga3: fix R2Y CSC mode bit shift definition | `f4d15aac4410` | `0036` |
| `0036` | video: rockchip: rga3: skip full_csc check for R2Y-709L | `1ba817a2d753` | `0037` |

### 0037–0057 — Locally-found fixes on the validated tip

Where the BSP-backport value concentrates: lifetime/refcount/OOB/10-bit-stride fixes found under KASAN/DMA-debug/hostile-ioctl replay on byte-identical BSP code.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0037` | video: rockchip: mpp: rkvenc2: Fix multi slice err hang issue | `54dc16c5141c` | `0038` |
| `0038` | video: rockchip: rga3: validate physical import pages | `25e630cbcfca` | `0039` |
| `0039` | video: rockchip: rga3: release session buffers by reference on close | `8eeaee24651d` | `0040` |
| `0040` | video: rockchip: mpp: unlink sessions before private teardown | `b1906083e53d` | `0041` |
| `0041` | video: rockchip: mpp: clear session->dma after reset destroy | `a68c39dbb834` | `0042` |
| `0042` | video: rockchip: rkvenc2: sample abort flag before task is freed | `e2a89c172758` | `0043` |
| `0043` | video: rockchip: rga3: accept legacy RGA2_GET_RESULT ioctl | `bb15076cd6fa` | `0044` |
| `0044` | video: rockchip: rga3: validate staged request tasks | `2d6367ad0b05` | `0045` |
| `0045` | video: rockchip: rga3: accept legacy virtual addresses in task check | `7b48a8d5b30d` | `0046` |
| `0046` | video: rockchip: rga3: report under-4G memory exclusion distinctly | `0feb65c7ee16` | `0047` |
| `0047` | video: rockchip: rga3: program byte-literal strides for 10-bit rasters | `4b2beb91521f` | `0048` |
| `0048` | video: rockchip: rga3: derive 10-bit plane offsets byte-literally | `6c7eb3efa3f0` | `0049` |
| `0049` | video: rockchip: rga3: own RGA2 page tables through the DMA API | `c4bf430d907f` | `0050` |
| `0050` | video: rockchip: rga3: serve over-4G memory on RGA2 via DMA-API mapping | `afcd69845942` | `0051` |
| `0051` | video: rockchip: rga3: drop the request initial reference exactly once | `039d880127e7` | `0052` |
| `0052` | video: rockchip: mpp: don't oops when a task's session has no device | `b1de79e7e0f7` | `0053` |
| `0053` | video: rockchip: mpp: guard the wait-result path against a device-less session | `862a7bea0d1d` | `0054` |
| `0054` | video: rockchip: mpp: bounds-check register-translation imports | `897fac51feaf` | `0055` |
| `0055` | video: rockchip: mpp: unmap RCB IOVA before freeing its pages | `b444c0e4df7f` | `0056` |
| `0056` | rga: 0057 — job holds a session reference across its lifetime | `dea09c9d02cd` | `0057` |
| `0057` | mpp: 0058 — reject RELEASE_FD on a session with no DMA (client-less NULL deref) | `09030239b5e4` | `0058` |

### 0058–0068 — BSP-audit HIGH port

Every HIGH finding of the BSP audit still present on the 0057 tip; backport candidates by construction.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0058` | video: rockchip: mpp: handle task message allocation failure | `1fee90f5b9c5` | `0059` |
| `0059` | video: rockchip: mpp: validate session fds before switching | `40871595bbd1` | `0060` |
| `0060` | video: rockchip: rkvdec2: bound RCB register indexes | `f29f87c22034` | `0061` |
| `0061` | video: rockchip: rkvdec2-link: test per-core disable flag | `3595a6f3d6c0` | `0062` |
| `0062` | video: rockchip: rkvenc2: bound class request arrays | `5e8a97d23adc` | `0063` |
| `0063` | video: rockchip: rga: balance acquire-fence references | `a619d9f8a0ae` | `0064` |
| `0064` | video: rockchip: rga: clean shutdown jobs outside irq lock | `d4285d3bd051` | `0065` |
| `0065` | video: rockchip: rga: reject missing multi-plane handles | `3393359f8b66` | `0066` |
| `0066` | video: rockchip: rga: balance get-buffer error paths | `679c4afd5eb6` | `0067` |
| `0067` | video: rockchip: rga: unwind partial handle acquisition | `94d78390e3e7` | `0068` |
| `0068` | video: rockchip: rga: require feature superset | `1960da62f2c7` | `0069` |

### 0069 — Full-exercise follow-up

MPP INIT_CLIENT_TYPE double-init UAF (-EBUSY re-init guard), found by fuzzing the audit kernel.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0069` | video: rockchip: mpp: reject re-init of an already-bound session | `f518b0289588` | `0070` |

### 0070–0071 — Forward-port regression / robustness

Our own port's issues found by the root-gate ladder: the mm_session debugfs UAF regression, and the RGA3 unaligned-userptr reject. Not BSP-latent.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0070` | video: rockchip: rga: don't drop mm->lock during session-release teardown | `20d3b9c86c78` | `0071` |
| `0071` | video: rockchip: rga3: reject 16-misaligned IOMMU window base | `39750d2e3b60` | `0072` |

### 0072–0073 — 10-bit stride convention / RGA2 page-table hardening (2026-07-24)

The GStreamer-suite NV12_10 root cause and its secondary discovery: `0072`
restores the legacy byte-stride ABI for 10-bit rasters on RGA3 (a regression
our own `0048` introduced; pairs with the ysp librga fork's im2d pixel→byte
conversion `c80eea7`, and both P010/NV15 gates plus the tracked
`rga-10bit-legacy-stride-test.c` probe must be re-run on the pair), and
`0073` makes the RGA2 MMU page-table builder fail closed with `-EOPNOTSUPP`
on above-4G entries instead of silently truncating to a hardware bus error.
Compile-verified + checkpatch-clean; booted gates pending the next build
([stride finding](../../../findings/2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md)).

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0072` | video: rockchip: rga3: honor the legacy byte-stride ABI for 10-bit rasters | `138f0de2c972` | — |
| `0073` | video: rockchip: rga: reject above-4G RGA2 MMU page-table entries | `79fc616390e5` | — |

## Renumber map (2026-07-23)

Uniform: **old N → new N** for N ≤ 11; **old N → new N−1** for N ≥ 13; **old 0012
removed** (stray `libbpf` commit). Use the per-row **Was** column above for the
exact prior number of any patch; use this rule to resolve a bare old number in a
dated finding.
