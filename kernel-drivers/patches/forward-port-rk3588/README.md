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

Exported with `git format-patch v6.18.64..rk3588-video-6.18` from the kernel
worktree at `../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport` (branch
`rk3588-video-6.18`). This checked-in export is the contiguous `0001`–`0107`
snapshot ending at `9fb65e963624`, which the fork's `rk3588-video-6.18`
branch points at.

On 2026-11-22 the branch was rebased from `v6.18` (`7d0a66e4bb908`) onto
`v6.18.64` (`fd7cfd39c8859`), so every commit ID below changed. The table rows
were remapped by exact number-and-title match. Patch `0005` lost one hunk that
stable now carries and gained the three-argument VSI `attach_dev`; all other
`0001`–`0097` diffs are unchanged. The pre-rebase tip `e7ff978398825` is kept as
`ysp-backup/rk3588-video-6.18-before-6.18.64-20261119`, locally and on the
`linux-rock5b` fork. See the
[6.18.64 finding](../../../findings/2026-11-22-forward-port-6-18-64-rebase-and-driver-review.md). W16 owns the moving branch;
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
| `0001` | video: rockchip: RK3588 vendor MPP (rkvenc2/rkvdec2) + RGA3/RGA2 drivers | `cb4b0bbc86a7` | — |
| `0002` | arm64: dts: rockchip: rk3588: VEPU580 encoder, rkvdec2 decoder, RGA3 nodes | `4f347bfc0f0f` | — |

### 0003–0016 — Mainline forward-port integration

Everything that exists only because the target is mainline 6.18 (IOMMU/DMA provider hooks, Verisilicon AV1 provider, DT, port-fix hardening). Not BSP-relevant.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0003` | media: rockchip: mpp: route iommu fault handling through provider hooks | `677c87e04e65` | — |
| `0004` | media: rockchip: mpp: add mpp_iommu_shared_domain CCU helper | `ba16214c75f5` | — |
| `0005` | iommu: add Verisilicon IOMMU provider and Rockchip provider media hooks | `4dcc5f88200a` | — |
| `0006` | video: rockchip: mpp: forward-port MPP core and rkvdec2/rkvenc2 to 6.18 | `e56c8710edaf` | — |
| `0007` | video: rockchip: mpp: add RKMPP AV1 decoder | `459612c8c556` | — |
| `0008` | video: rockchip: rga: depend on ROCKCHIP_IOMMU and harden version string | `4db853665e1c` | — |
| `0009` | arm64: dts: rockchip: rk3588: add decoder/AV1 IOMMUs, SRAM and node wiring | `6943ec0f3c79` | — |
| `0010` | video: rockchip: mpp: convert rkvenc2 CCU attach to shared-domain helper | `04c338b2cf9b` | — |
| `0011` | video: rockchip: mpp: harden CCU shared-domain RCB windows and reset paths | `2e1724292013` | — |
| `0012` | iommu: rockchip: restore large DMA segment support | `d6cadcdf80d3` | `0013` |
| `0013` | video: rockchip: rga: keep IOVAs below 32-bit wrap guard | `1171faab4735` | `0014` |
| `0014` | media: rockchip: harden IOMMU forward port | `f4170037e398` | `0015` |
| `0015` | media: rockchip: rga3: map scattered userptr through IOMMU | `b60cd8fa7d17` | `0016` |
| `0016` | media: rockchip: keep rkvenc RCB SRAM optional | `1e06af718c31` | `0017` |

### 0017–0036 — Vendor develop-5.10 RGA reconciliation

Rockchip-authored RGA fixes cherry-picked from develop-5.10 (batching, request lifetime, shadow_page, CSC/scale correctness). Already Rockchip's.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0017` | video: rockchip: rga: add RK3588 low-voltage workarounds | `25550819d837` | `0018` |
| `0018` | video: rockchip: rga3: support hardware batching | `ff06dd07f041` | `0019` |
| `0019` | video: rockchip: rga3: fix RGA2/RGA3 slave_mode execution failure after master_mode | `c6db1f3a4cb2` | `0020` |
| `0020` | video: rockchip: rga3: fix request leak when multi-task submit failed | `997fad4b21d9` | `0021` |
| `0021` | video: rockchip: rga3: fix request submit failed when acquire_fence is already signaled | `485088c1405e` | `0022` |
| `0022` | video: rockchip: rga3: fix page fault caused by IOMMU prefetch | `9b25db4995e8` | `0023` |
| `0023` | video: rockchip: rga3: add shadow_page for cache-line unaligned VA | `fc0ed574c2fc` | `0024` |
| `0024` | video: rockchip: rga3: fix cache-line unaligned VA access fault | `8760a394013b` | `0025` |
| `0025` | video: rockchip: rga3: fix VA map size calculation | `f63adff6f2dc` | `0026` |
| `0026` | video: rockchip: rga3: fix return value of rga_mm_lookup_iova() on error | `d95ac691acac` | `0027` |
| `0027` | video: rockchip: rga3: fix bi-linear scale-down coefficient check | `cc6d8327630b` | `0028` |
| `0028` | video: rockchip: rga3: mpi_commit: add protection when scale-up | `f721e3c3099d` | `0029` |
| `0029` | video: rockchip: rga3: enable config_intr and support parse error status | `b8eb33cb3d4b` | `0030` |
| `0030` | video: rockchip: rga3: fix incorrect check in update_LUT mode | `90ee52342f63` | `0031` |
| `0031` | video: rockchip: rga3: keep hardware tables file-local | `bd4f13686ef5` | `0032` |
| `0032` | video: rockchip: rga3: clear tile4x4 chroma bases | `5843d21ffe1f` | `0033` |
| `0033` | video: rockchip: rga3: mpi_commit: restore output_params in rotate 90/270 | `fbf0e30ab644` | `0034` |
| `0034` | video: rockchip: rga3: mpi_commit: fix operator typo (| to ||) in rotate_mode check | `6473c6cbad39` | `0035` |
| `0035` | video: rockchip: rga3: fix R2Y CSC mode bit shift definition | `73dc6913dc33` | `0036` |
| `0036` | video: rockchip: rga3: skip full_csc check for R2Y-709L | `d89d1cf114d6` | `0037` |

### 0037–0057 — Locally-found fixes on the validated tip

Where the BSP-backport value concentrates: lifetime/refcount/OOB fixes found
under KASAN/DMA-debug/hostile-ioctl replay on byte-identical BSP code. The
10-bit entries in this historical range were later proven forward-port
regressions; current `0072`/`0074` restore the BSP byte-stride ABI.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0037` | video: rockchip: mpp: rkvenc2: Fix multi slice err hang issue | `2bd175417b83` | `0038` |
| `0038` | video: rockchip: rga3: validate physical import pages | `ef8de1830726` | `0039` |
| `0039` | video: rockchip: rga3: release session buffers by reference on close | `ed660c114bff` | `0040` |
| `0040` | video: rockchip: mpp: unlink sessions before private teardown | `bef7aabf5cbd` | `0041` |
| `0041` | video: rockchip: mpp: clear session->dma after reset destroy | `adf7db49305b` | `0042` |
| `0042` | video: rockchip: rkvenc2: sample abort flag before task is freed | `ae8736a83b9f` | `0043` |
| `0043` | video: rockchip: rga3: accept legacy RGA2_GET_RESULT ioctl | `8e271ce26afd` | `0044` |
| `0044` | video: rockchip: rga3: validate staged request tasks | `7753241cae8d` | `0045` |
| `0045` | video: rockchip: rga3: accept legacy virtual addresses in task check | `16b2922b4118` | `0046` |
| `0046` | video: rockchip: rga3: report under-4G memory exclusion distinctly | `86d07d3d76cd` | `0047` |
| `0047` | video: rockchip: rga3: program byte-literal strides for 10-bit rasters | `2db0d33e5ef9` | `0048` |
| `0048` | video: rockchip: rga3: derive 10-bit plane offsets byte-literally | `90f06fc2a08a` | `0049` |
| `0049` | video: rockchip: rga3: own RGA2 page tables through the DMA API | `c220440da5f4` | `0050` |
| `0050` | video: rockchip: rga3: serve over-4G memory on RGA2 via DMA-API mapping | `469afe61d50e` | `0051` |
| `0051` | video: rockchip: rga3: drop the request initial reference exactly once | `79fb03973e0d` | `0052` |
| `0052` | video: rockchip: mpp: don't oops when a task's session has no device | `b6d650c735e0` | `0053` |
| `0053` | video: rockchip: mpp: guard the wait-result path against a device-less session | `96dc2d20ae16` | `0054` |
| `0054` | video: rockchip: mpp: bounds-check register-translation imports | `7b7b6546b3ab` | `0055` |
| `0055` | video: rockchip: mpp: unmap RCB IOVA before freeing its pages | `1669cd94ea17` | `0056` |
| `0056` | rga: 0057 — job holds a session reference across its lifetime | `92ecc05282ea` | `0057` |
| `0057` | mpp: 0058 — reject RELEASE_FD on a session with no DMA (client-less NULL deref) | `3aeb068b296c` | `0058` |

### 0058–0068 — BSP-audit HIGH port

Every HIGH finding of the BSP audit still present on the 0057 tip; backport candidates by construction.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0058` | video: rockchip: mpp: handle task message allocation failure | `f76903f0b574` | `0059` |
| `0059` | video: rockchip: mpp: validate session fds before switching | `eee5db9cdab9` | `0060` |
| `0060` | video: rockchip: rkvdec2: bound RCB register indexes | `d6c0c8156698` | `0061` |
| `0061` | video: rockchip: rkvdec2-link: test per-core disable flag | `2fd49be5c457` | `0062` |
| `0062` | video: rockchip: rkvenc2: bound class request arrays | `a045a2a38391` | `0063` |
| `0063` | video: rockchip: rga: balance acquire-fence references | `25509519d567` | `0064` |
| `0064` | video: rockchip: rga: clean shutdown jobs outside irq lock | `af51cdfdaec8` | `0065` |
| `0065` | video: rockchip: rga: reject missing multi-plane handles | `9f17ab3dc39c` | `0066` |
| `0066` | video: rockchip: rga: balance get-buffer error paths | `46008fae0f59` | `0067` |
| `0067` | video: rockchip: rga: unwind partial handle acquisition | `702c73d8fd1d` | `0068` |
| `0068` | video: rockchip: rga: require feature superset | `1c43ca26ecfc` | `0069` |

### 0069 — Full-exercise follow-up

MPP INIT_CLIENT_TYPE double-init UAF (-EBUSY re-init guard), found by fuzzing the audit kernel.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0069` | video: rockchip: mpp: reject re-init of an already-bound session | `d8c5ffe7c8f9` | `0070` |

### 0070–0071 — Forward-port regression / robustness

Our own port's issues found by the root-gate ladder: the mm_session debugfs UAF regression, and the RGA3 unaligned-userptr reject. Not BSP-latent.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0070` | video: rockchip: rga: don't drop mm->lock during session-release teardown | `2e2d96bbcb98` | `0071` |
| `0071` | video: rockchip: rga3: reject 16-misaligned IOMMU window base | `21312f2bd4c2` | `0072` |

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
| `0072` | video: rockchip: rga3: honor the legacy byte-stride ABI for 10-bit rasters | `723da68494b1` | — |
| `0073` | video: rockchip: rga: reject above-4G RGA2 MMU page-table entries | `8ddd7dc66561` | — |

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
| `0074` | video: rockchip: rga: derive 10-bit UV plane offsets byte-literally | `cc5bcd6112a0` | — |

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
| `0075` | video: rockchip: rkvenc2: reserve a slice fifo slot for the terminal record | `1c449f68aacd` | — |

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
| `0076` | video: rockchip: mpp: bound user register requests and translations | `4f2fc65fe96b` | — |
| `0077` | video: rockchip: mpp: fix IOMMU cookie typing and buffer-release ordering | `649d1eb022a2` | — |
| `0078` | video: rockchip: rkvenc2/rkvdec2-link: fix window wrap, atomic clocks, WARN | `9ba9f3599860` | — |
| `0079` | video: rockchip: rga: fix job/buffer lifetime, locking and import validation | `6fc8553ec759` | — |

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
| `0080` | media: rockchip: rga: honor mapped SG contracts | `b6b303fc39b3` | — |

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
| `0081` | video: rockchip: mpp: fix session-switch lifetime, index refetch and msgs leak | `d42ac4e0678f` | — |
| `0082` | video: rockchip: mpp: make MPP_CMD_RELEASE_FD give back only what it took | `307591a62c1e` | — |
| `0083` | video: rockchip: rkvenc2: don't write through an unallocated class buffer | `eb3231d30619` | — |
| `0084` | video: rockchip: rkvdec2: sync-cancel the timeout work and clear cur_task | `6f2a6c8b457f` | — |
| `0085` | video: rockchip: rga: authenticate the ioctl boundary and own imports properly | `78425663ebfd` | — |
| `0086` | video: rockchip: rga: authenticate RGA_IOC_RELEASE_BUFFER | `aa380255c676` | — |
| `0087` | video: rockchip: fix defects found reviewing the previous five commits | `ebaf167c4454` | — |

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
| `0088` | video: rockchip: add RK3588 IEP2 deinterlacing | `1504c5f5f10b` | — |
| `0089` | video: rockchip: harden IEP2 lifetimes and DMA bounds | `4e44ace21c7b` | — |

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
| `0090` | video: rockchip: rga: snapshot job task lists | `fbd4a9ab0106` | — |
| `0091` | iommu: rockchip: quiesce MPP fault callbacks on clear | `342a19c9b803` | — |
| `0092` | video: rockchip: rkvdec2: quiesce failed tasks before retire | `598c7a522886` | — |

### 0093 — RGA2 USERPTR SWIOTLB segment sizing (2026-08-08)

The first 6.18.43 production conformance run with the matching DTB passed ABI
and MPP, then isolated three RGA2-only official librga failures. High USERPTR
pages reached the 32-bit RGA2 DMA device as merged 2 MiB SG entries, exceeding
SWIOTLB's per-entry mapping limit before hardware start. `0093` sizes both
direct and transient RGA2 USERPTR SG entries from `dma_max_mapping_size()`;
RGA3 and physical-import coalescing are unchanged. The patch is strict-
checkpatch clean and affected-object compile-verified. Exact `0001`–`0096` is
published, installed, and booted: the former 2 MiB rejection is absent, but a
high contiguous USERPTR exposed the follow-on admission gap fixed by `0097`.
The [dated finding](../../../findings/2026-08-08-forward-port-rga2-userptr-swiotlb-segments.md)
owns the original result and correction route.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0093` | video: rockchip: rga3: cap RGA2 USERPTR SG segments | `fed28de191a7` | — |

### 0094 — RGA2 high DMA-BUF staging (2026-08-08)

`0093` can shape driver-owned USERPTR SG tables, but a DMA-BUF importer cannot
split an exporter-owned 1 MiB high-memory entry before SWIOTLB rejects it.
`0094` keeps compatible work on the zero-copy RGA3 path and gives RGA2-only or
explicitly RGA2-pinned work a bounded, job-owned DMA32 staging path after an
exact attachment `-EIO`. Staging is shared by DMA-BUF identity across all
planes/tasks, copies back only after successful quiesced completion, and
exports lifecycle/leak counters. CPU-inaccessible exporters and buffers beyond
the 64 MiB per-job cap still fail closed. The patch is strict-checkpatch and
full-RGA-driver compile-verified and is booted as part of exact `0096`, but its
dedicated DMA-BUF staging and alias gates remain unverified. The
[dated finding](../../../findings/2026-08-08-forward-port-rga2-dmabuf-staging.md)
owns the design boundary and hardware gate.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0094` | video: rockchip: rga3: stage incompatible RGA2 DMA-BUFs | `cb1604a0bce4` | — |

### 0095 — RGA ownership and high DMA-BUF alias closure (2026-08-08)

`0095` supersedes `0094`'s exact-`-EIO` staging trigger. The forward-port RGA2
path otherwise gave each successful transient SWIOTLB mapping a separate alias
image, so every high-address DMA-BUF now uses one bounded, job-shared DMA32
stage keyed by DMA-BUF identity. The patch also closes request/fence/scheduler,
session-handle/import, PM-unwind, pool-rollback, and shutdown ownership gaps
found by the subsequent multi-agent review. Strict checkpatch, production and
async-disabled full-RGA `W=1 WERROR=1` builds, and two final independent source
reviews pass. Exact `0096` is published and booted with partial conformance;
the dedicated ownership and alias-staging proof remains pending. The
[audit finding](../../../findings/2026-08-08-forward-port-rga-mpp-ownership-audit-fixes.md)
owns the complete boundary and verification gate.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0095` | video: rockchip: rga3: harden request and DMA-BUF ownership | `c195150dbdaf` | — |

### 0096 — MPP session and provider fault ownership (2026-08-08)

`0096` serializes MPP session/result/DMA state and turns task admission into a
provider-owned prepare/publish/START/enable-delivery transaction. Rockchip and
VSI providers preserve faults latched after START, reject missing PM supplier
links, and quiesce callbacks consistently. RKVDEC2 hard CCU requests are forced
to soft mode before worker/IRQ selection. Full MPP and IOMMU-directory
`W=1 WERROR=1` builds, strict checkpatch, and independent MPP/integration
reviews pass. Exact `0096` is published and booted; its ordinary MPP suite
passes, while focused ownership, fault-admission, and hard-CCU fallback proof
remain pending.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0096` | video: rockchip: mpp: serialize task and fault ownership | `092c485698f0` | — |

### 0097 — RGA2 high contiguous USERPTR admission (2026-08-11)

The first exact-`0096` boot removed the original oversized-SG failure but
isolated a prior policy mistake. A multi-megabyte USERPTR backed by physically
contiguous high pages carried `RGA_MEM_PHYSICAL_CONTIGUOUS`; admission treated
that generic property as proof that the buffer had to bypass the RGA2 MMU,
even though a virtual import retains pinned pages and can use the transient
RGA2 remap. Gray256 therefore had no compatible core before mapping or hardware
start.

`0097` recognizes pinned virtual imports during admission, keeps the RGA2 MMU
enabled for a high contiguous USERPTR, and prepares its virtual address rather
than the high physical address. Below-4-GiB contiguous buffers stay direct;
raw high physical imports stay rejected; and high DMA-BUFs retain `0095`
staging. Strict checkpatch and a complete production-config RGA directory
build with `W=1 WERROR=1` pass. Exact Linux 6.18.44 source is signed,
extraction/source/config verified, and accepted as Pending source publication
`18669946`; build and runtime replay remain pending.
The [dated finding](../../../findings/2026-08-11-forward-port-rga2-contiguous-userptr-rejection.md)
owns the measured `0096` failure, root cause, and verification gate.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0097` | video: rockchip: rga3: remap contiguous high USERPTRs | `099be4230613` | — |

### 0098–0107 — Full driver review on Linux 6.18.64 (2026-11-22)

A fresh full read of the MPP, RGA and IOMMU code by six independent reviewers
found no high-severity kernel memory-safety defect reachable from an
unprivileged device user. It did find these ten. `0106`–`0107` close a
plausible fail-open path: after a failed post-reset refresh, the codec MMU could
be left in bypass while tasks still ran. All ten are strict-checkpatch and
production-config `W=1` compile verified, and none is booted. The
[dated finding](../../../findings/2026-11-22-forward-port-6-18-64-rebase-and-driver-review.md)
owns the defects, their reach, and what was reported but deliberately not
changed.

| # | Title | Commit | Was |
|---|-------|--------|-----|
| `0098` | video: rockchip: mpp: parse 32-bit requests with the real record size | `d24a9417a709` | — |
| `0099` | video: rockchip: mpp: do not report a stale IRQ status for a timed-out task | `e8347c3d5ab4` | — |
| `0100` | video: rockchip: mpp: release a failed task's core and keep draining | `b0b4a83553db` | — |
| `0101` | video: rockchip: mpp: suppress sysfs unbind for rkvdec2, rkvenc2 and av1dec | `53360159f99c` | — |
| `0102` | video: rockchip: rkvenc2: free class buffers when the task format is missing | `a3d8ad5ad95a` | — |
| `0103` | video: rockchip: mpp: initialise session state before exposing the node | `f47b1f0fe562` | — |
| `0104` | video: rockchip: rga3: reject palette modes RGA2 cannot encode | `ee5c04a5dd55` | — |
| `0105` | video: rockchip: rga3: zero the hardware-version reply before copying it out | `61f14842809f` | — |
| `0106` | iommu/rockchip: report a paging domain that is not translating | `c93484104ac8` | — |
| `0107` | video: rockchip: mpp: refuse tasks while the MMU is not translating | `9fb65e963624` | — |

## Renumber map (2026-07-23)

Uniform: **old N → new N** for N ≤ 11; **old N → new N−1** for N ≥ 13; **old 0012
removed** (stray `libbpf` commit). Use the per-row **Was** column above for the
exact prior number of any patch; use this rule to resolve a bare old number in a
dated finding.
