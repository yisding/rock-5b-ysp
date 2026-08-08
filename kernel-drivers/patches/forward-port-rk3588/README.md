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
worktree at `../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport` (branch
`rk3588-video-6.18`). This checked-in export is the contiguous `0001`–`0093`
snapshot ending at `b54ba6079824`. W16 owns the moving branch;
the forward-port package record owns actual artifacts; the
[scorecard](../../docs/forward-port-status.md) owns accumulated validation.
Backup of the pre-cleanup tip: tag
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

Where the BSP-backport value concentrates: lifetime/refcount/OOB fixes found
under KASAN/DMA-debug/hostile-ioctl replay on byte-identical BSP code. The
10-bit entries in this historical range were later proven forward-port
regressions; current `0072`/`0074` restore the BSP byte-stride ABI.

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
The [stride finding](../../../findings/2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md)
owns the dated validation and decision boundary.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0072` | video: rockchip: rga3: honor the legacy byte-stride ABI for 10-bit rasters | `138f0de2c972` | — |
| `0073` | video: rockchip: rga: reject above-4G RGA2 MMU page-table entries | `79fc616390e5` | — |

### 0074 — 10-bit UV plane offset, the site `0072` missed (2026-07-24)

Running `0072`'s own verification gate on the booted production
`…20260724~rk1` kernel showed **`0072` was incomplete**: it converted the
RGA3 *stride* writer to byte-literal `vir_w` but left the sibling site
`rga_convert_addr()` (`rga_common.c`, from `0049`/`6c7eb3efa3f0`) still
scaling `vir_w` by the pixel depth to derive the **UV plane offset** — so
the depth is double-applied one site over. Tightly sized surfaces still
IOMMU-fault; over-sized ones **succeed and return chroma read from the wrong
offset**, a silent wrong-output bug that made the GStreamer NV12_10 cases
report false greens. `0074` drops the scaling (`y_bytes = vir_w * vir_h`)
and the now-redundant `compact_mode` branch. Compile-verified +
checkpatch-clean at preparation time; the
[UV-offset finding](../../../findings/2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md)
owns the dated hardware evidence.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0074` | video: rockchip: rga: derive 10-bit UV plane offsets byte-literally | `710e6ad12af6` | — |

### 0075 — RKVENC2 slice-FIFO terminal record (2026-07-25)

`rkvenc2_read_slice_len()` ignored `kfifo_in()` at both insertion sites, so a
full 256-entry per-task FIFO silently discarded records — including the
**terminal** one carrying `slice_info.last`. Userspace then drained every
stored record without ever seeing the last flag, the task completed and was
popped, and every later poll returned `-EIO`. `0075` routes both sites through
`rkvenc2_push_slice_len()`, which **reserves the last free slot for the
terminal record** (ordinary records are dropped first) and carries a dropped
record's length into the next stored one, so the stream always terminates and
the byte offsets stay exact. An overflowing frame is therefore still complete
and decodable — only the reported slice boundaries are coarser — so the
condition is counted and logged as a ratelimited warning and deliberately
**not** turned into an error return. Compile-verified (`W=1`) +
checkpatch-clean; **the split_arg=4 hardware gate is still owed**
([slice-FIFO finding](../../../findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md)).

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0075` | video: rockchip: rkvenc2: reserve a slice fifo slot for the terminal record | `12a7da02bea8` | — |

### 0076–0079 — WARN/oops audit sweep (2026-07-29)

A systematic audit for code that can produce a kernel **WARNING or oops** found
**18 distinct defects**, fixed here in four file-grouped patches. Twelve are
reachable by any process that can open `/dev/mpp_service` or `/dev/rga`, and
five of those are unprivileged kernel-heap corruption rather than a splat:
`mpp_check_req()` clamped to the overflow amount instead of the remaining space
(and used a signed offset, so an offset ≥ `0x80000000` bypassed every bound);
the register-translation paths indexed `trans_info[]` with a 10-bit
user-supplied format against a 4-entry array, and used raw user `u16`s as
register indexes; and `rkvenc_update_req()` underflowed a `copy_from_user()`
length to ~4 GiB. The sweep also closes all five previously catalogued but
unfixed vendor-driver defects (D01–D05), whose catalogue is kept in the private
`rock-5b-security` repository.

Two changes are structural rather than a bounds check: `struct mpp_dev_var`
gained `trans_count` (set from `ARRAY_SIZE()` in all 14 `.trans_info =`
initialisers, plus a checked `mpp_get_trans_info()` accessor) because nothing
previously carried the array length; and both translation helpers now take a
register count, since callers pass buffers differing by two orders of magnitude
(360 decoder registers vs the encoder's 23-register `CLASS_BASE` class).

Full defect inventory, bounded validation, and gate disposition are in the
[audit finding](../../../findings/2026-07-29-forward-port-warn-oops-audit-and-fixes.md).

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0076` | video: rockchip: mpp: bound user register requests and translations | `febed97bc459` | — |
| `0077` | video: rockchip: mpp: fix IOMMU cookie typing and buffer-release ordering | `4dba1f42ab2b` | — |
| `0078` | video: rockchip: rkvenc2/rkvdec2-link: fix window wrap, atomic clocks, WARN | `b7883d72b746` | — |
| `0079` | video: rockchip: rga: fix job/buffer lifetime, locking and import validation | `c10074f4474e` | — |

### 0080 — RGA mapped-SG contract repair (2026-07-31)

The forward port now treats several byte-adjacent mapped DMA entries as one
safe direct-address span and builds RGA2 page tables from the mapped entry
count, DMA lengths, and DMA addresses. Page-aligned real gaps become distinct
RGA2 PTE runs; sub-page gaps, short coverage, overflow, and above-32-bit PTEs
remain fail-closed. This preserves DMA-API/SWIOTLB ownership instead of
reinterpreting exporter pages. The forward-port scorecard owns the current
evidence boundary.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0080` | media: rockchip: rga: honor mapped SG contracts | `14c0456c4108` | — |

### 0081–0087 — ioctl/lifetime audit round 2 and review repairs (2026-08-01)

A second source audit found deterministic and racy memory-safety defects in the
MPP/RGA ioctl boundary and the RKVENC2/RKVDEC2 task lifecycle. The first five
commits repair MPP session/message and static dma-buf reference ownership,
RKVENC2 class-buffer/procfs bounds, RKVDEC2 timeout/`cur_task` lifetime, and
RGA import/request ownership. `0086` closes the sibling unauthenticated RGA
release path. Adversarial review then found three wrong or incomplete fixes and
additional same-shape races; `0087` repairs the RGA import count, orders MPP fd
release last, serializes dma-buf release lookup/check/put, completes timeout and
`cur_task` locking, and restores fd/PTR dma-buf de-duplication.

The [audit finding](../../../findings/2026-08-01-forward-port-uaf-oops-audit-round-2.md)
owns the dated validation boundary and missing discriminators.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0081` | video: rockchip: mpp: fix session-switch lifetime, index refetch and msgs leak | `a88f4fdfccda` | — |
| `0082` | video: rockchip: mpp: make MPP_CMD_RELEASE_FD give back only what it took | `874fbff8ba50` | — |
| `0083` | video: rockchip: rkvenc2: don't write through an unallocated class buffer | `57585821dcef` | — |
| `0084` | video: rockchip: rkvdec2: sync-cancel the timeout work and clear cur_task | `1b4b65b57e7c` | — |
| `0085` | video: rockchip: rga: authenticate the ioctl boundary and own imports properly | `78a4d1a90370` | — |
| `0086` | video: rockchip: rga: authenticate RGA_IOC_RELEASE_BUFFER | `36ec9c956ce1` | — |
| `0087` | video: rockchip: fix defects found reviewing the previous five commits | `5b87d46eefdc` | — |

### 0088–0089 — RK3588 IEP2 import and safety review (2026-08-02)

`0088` adds the vendor-ABI IEP2 deinterlacing driver, binding, and ROCK 5B DT
path. `0089` is the result of three independent lifetime, ABI/DMA-boundary, and
probe/fault/remove reviews. It closes timeout and fault-callback UAFs, rejects
raw or undersized DMA submissions, balances the I1O1T auxiliary mapping, makes
clock/reset failures fatal, and adds exclusive fixed-IOVA reservation. It also
hides unsupported MPP hot-unbind controls; arbitrary DT-overlay removal still
does not have a complete common drain/unpublish contract.

See the
[complete safety review](../../iep2/docs/forward-port-safety-review.md) and the
[production-kernel result](../../../findings/2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md#this-is-not-an-iep2-defect-and-iep2-now-has-production-kernel-evidence).

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0088` | video: rockchip: add RK3588 IEP2 deinterlacing | `6f5bdf5c0a52` | — |
| `0089` | video: rockchip: harden IEP2 lifetimes and DMA bounds | `7615b69a744a` | — |

### 0090–0092 — RGA lifetime and decoder recovery safety (2026-08-04)

These close the known-open RGA job-task borrow, provider fault-callback/token
race, unlocked MPP fault-task reads, soft-CCU retire-before-reset ordering, and
lost concurrent reset requests. RGA jobs now own their task snapshots while
publishing OSD results only into a pinned request. Provider handler removal is
a non-sleeping quiescence barrier, and failed soft-CCU tasks remain live until
reset has stopped hardware access.

The dated production-profile cancellation, recovery, native conformance,
VA-API, bounded-log, and soak campaign is recorded in the
[production finding](../../../findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md).
See also the earlier
[source/fix finding](../../../findings/2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md).

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0090` | video: rockchip: rga: snapshot job task lists | `4081e39e8712` | — |
| `0091` | iommu: rockchip: quiesce MPP fault callbacks on clear | `552a9eea6aab` | — |
| `0092` | video: rockchip: rkvdec2: quiesce failed tasks before retire | `7d53bc7a3adc` | — |

### 0093 — RGA2 USERPTR SWIOTLB segment sizing (2026-08-08)

The first 6.18.43 production conformance run with the matching DTB passed ABI
and MPP, then isolated three RGA2-only official librga failures. High USERPTR
pages reached the 32-bit RGA2 DMA device as merged 2 MiB SG entries, exceeding
SWIOTLB's per-entry mapping limit before hardware start. `0093` sizes both
direct and transient RGA2 USERPTR SG entries from `dma_max_mapping_size()`;
RGA3 and physical-import coalescing are unchanged. The patch is strict-
checkpatch clean and affected-object compile-verified, but not packaged or
booted. The [dated finding](../../../findings/2026-08-08-forward-port-rga2-userptr-swiotlb-segments.md)
owns the measured run and verification gate.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0093` | video: rockchip: rga3: cap RGA2 USERPTR SG segments | `b54ba6079824` | — |

## Renumber map (2026-07-23)

Uniform: **old N → new N** for N ≤ 11; **old N → new N−1** for N ≥ 13; **old 0012
removed** (stray `libbpf` commit). Use the per-row **Was** column above for the
exact prior number of any patch; use this rule to resolve a bare old number in a
dated finding.
