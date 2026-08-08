# Forward-port patch catalog — provenance and BSP backport verdicts

The complete per-patch accounting of the maintained forward-port series
[`patches/forward-port-rk3588/`](../patches/forward-port-rk3588/README.md): what
each patch does, where its change *comes from*, and — the question this document
exists to answer — **which fixes should be carried back to the Rockchip BSP**
(`develop-6.1`), because the defect they fix lives in Rockchip's own code, not in
our port.

> **Numbering note (bridge).** This page was compiled 2026-07-22 and uses the
> **pre-cleanup patch numbers** (`0001`–`0072`, with a `0012` gap). On 2026-07-23
> the series was renumbered contiguous `0001`–`0071` (a stray `libbpf` commit at
> old-`0012` was dropped; old N → new N−1 for N ≥ 13). The current numbers,
> titles, and the full old→new map are the authoritative index in the
> [series README](../patches/forward-port-rk3588/README.md). Read the numbers
> below as the pre-cleanup scheme and cite patches by **title**.
>
> **The two schemes collide silently — read this before quoting any number.**
> The exact relation is **catalog N = series patch N−1 for N ≥ 13**; below that
> the two agree (catalog `0001`–`0011` = series `0001`–`0011`) and catalog
> `0012` does not exist. So catalog `0042` is series file
> `rk3588-fwport-0041-…-clear-session-dma-after-reset-destroy`, and catalog
> `0070` is series file `rk3588-fwport-0069-…-reject-re-init-of-an-already-bound`
> — while *series* `0042` and `0070` are completely different patches (catalog
> `0043` and `0071`, both port-introduced bugs carrying the opposite,
> never-backport verdict). The same four digits name a **Tier-1 backport
> candidate** in one scheme and a **do-not-backport** port fix in the other.
>
> **Every document must name its scheme on every list of patch numbers** —
> write "catalog 0042" or "series 0041", never a bare `0042`.
> An unlabelled list mixed across two rows of the same table is how the wrong
> patch gets filed. Citing by **title** is unambiguous in both schemes and is
> the safe default.

Compiled 2026-07-22 from the patch commit messages, the
[BSP audit](./bsp-audit.md), the
[lifetime/ownership audit](../../findings/2026-07-21-forward-port-lifetime-resource-ownership-audit.md),
the [HIGH-port record](../../findings/2026-07-22-bsp-high-current-tip-port.md),
and the per-fix findings linked in each range section. The series README stays
the authoritative *mechanical* description of every patch; this page is the
provenance/backport layer on top and does not repeat full fix mechanics.

## How to read the tables

**Provenance class** — every patch gets exactly one:

| Class | Meaning | BSP relevance |
|-------|---------|---------------|
| `PORT` | Forward-port infrastructure: exists only because the target is mainline 6.18 (compat shims, mainline IOMMU/DMA integration, DT plumbing). | None — the BSP has its own private APIs for the same jobs. |
| `PORT-FIX` | Fixes a defect the forward port itself introduced. | None — the bug does not exist in BSP code. |
| `VENDOR` | Rockchip-authored commit imported from a newer vendor branch (the `develop-5.10` RGA series). | Already Rockchip's; nothing to send back. |
| `BSP-BUG` | A defect we found whose broken code is **also in the pristine Rockchip BSP** (stated in the commit message/finding, or established by byte-identity of the affected file). | **Backport candidate.** |
| `HARDEN` | New validation/diagnostics not present in the BSP, where the underlying weakness exists there too. | Defensive/optional backport. |

**Verification.** Per-fix rows may name a bounded preparation or targeted gate
when it changes backport readiness. The
[forward-port scorecard](./forward-port-status.md) owns accumulated capability
evidence; [status](../../status.md) owns the live public boundary; dated
findings own run detail. This catalog does not maintain package publication or
installed-state rollups.

A backport verdict below is a statement about **where the fix belongs**, not
that it is ready to ship: anything not yet through its runtime gate keeps that
gate as a prerequisite in either tree.

## BSP presence — verified against two vendor trees (2026-07-29)

Until 2026-07-29 this page asserted BSP presence mostly by inference from the
"~87% as-is" figure quoted in the `0059`–`0069` section, and that block carried
no BSP-evidence column at all. An independent diff on 2026-07-29 checked every
defect site against **both** vendor trees at pinned commits:

- `rockchip-linux/kernel` `develop-6.1` @ `b4ef083dc0c3`
- `radxa/kernel` `linux-6.1-stan-rkr5.1` @ `567401fe1718` — the tree that
  actually ships on a Rock 5B, and which this project had never diffed before

**22 of the 23 checked defect signatures are present verbatim in the shipping
Radxa kernel.** The single exception is `0039` (raw physical-import
validation): `linux-6.1-stan-rkr5.1` predates the `dma_map_sg()` conversion,
still uses `rga_mm_map_phys_addr()` → `rga_iommu_map()`, and is **not
affected** — see
[`rga/docs/raw-physical-import-crash.md`](../rga/docs/raw-physical-import-crash.md).

`radxa` `rkr5.1` is **not** the same code as `develop-6.1`, so any
"BSP-identical" claim must name **which tree**. Measured divergence at those
two pins: `rga_mm.c` 341 changed lines, `mpp_rkvenc2.c` 305, `rga_drv.c` 171.

Trust: CODE-INSPECTED (both pinned trees) / MEASURED (the divergence counts).
Vendor branches move — re-pin before quoting any of this. The full two-tree
diff record is kept in the private `rock-5b-security` repository.

## 0001–0002 — the import base

| # | What it does | Class | Backport |
|---|--------------|-------|----------|
| 0001 | Imports the Rockchip 6.1 BSP MPP (`rk_vcodec`) + RGA (`multi_rga`) drivers onto v6.18 with compat shims. | `PORT` | n/a |
| 0002 | RK3588 device tree: VEPU580 encoder, rkvdec2 decoder, RGA nodes, board enables. | `PORT` | n/a |

## 0003–0017 — mainline integration and its self-inflicted fixes

All fifteen exist because mainline 6.18 lacks the BSP's private IOMMU/DMA
contracts. None fix Rockchip code; none are backport candidates.

| # | What it does | Class |
|---|--------------|-------|
| 0003 | Routes MPP IOMMU fault handling through provider hooks (mainline's `iommu_set_fault_handler()` refuses DMA-cookie domains). | `PORT` |
| 0004 | Adds the `mpp_iommu_shared_domain` CCU helper object (behavior-preserving scaffolding). | `PORT` |
| 0005 | Adds the Verisilicon IOMMU provider + Rockchip provider media hooks mainline does not expose. | `PORT` |
| 0006 | Forward-ports MPP core + rkvdec2/rkvenc2 onto 6.18 IOMMU/DMA APIs. | `PORT` |
| 0007 | Adds the RKMPP AV1 decoder backend driven through the VSI provider. | `PORT` |
| 0008 | RGA Kconfig `ROCKCHIP_IOMMU` dependency + `sizeof()` version-string tidy. | `PORT` |
| 0009 | DT: decoder/AV1 IOMMUs, codec SRAM windows. | `PORT` |
| 0010 | Converts rkvenc2 CCU attach onto the shared-domain helper (mechanical). | `PORT` |
| 0011 | Hardens CCU shared-domain RCB windows (overlap reject, reset verify diagnostics). | `PORT` |
| 0013 | Restores the BSP large-DMA-segment contract in the mainline Rockchip IOMMU provider. | `PORT` |
| 0014 | Caps RGA `bus_dma_limit` below the 32-bit IOVA wrap (mainline-allocator guard). | `PORT-FIX` |
| 0015 | Hardens the IOMMU forward port (span/wrap rejection, PM-guarded MMIO, review-found unwind fixes). | `PORT-FIX` |
| 0016 | Maps scattered pinned userptr through the IOMMU when `dma_map_sg()` is not single-span (fixes a port-introduced rejection). | `PORT-FIX` |
| 0017 | Keeps RKVENC RCB SRAM best-effort at probe, matching BSP behavior the port had regressed. | `PORT-FIX` |

## 0018–0037 — the Rockchip develop-5.10 RGA reconciliation

Every patch in this range is vendor-sourced: seventeen are verbatim
Yu Qiaowei / Yandong Lin cherry-picks (`(cherry picked from commit …)` +
`Change-Id`), and `0032`/`0033` are locally re-authored adaptations that cite
the exact `develop-5.10` commit they carry. Rockchip already owns all of these
fixes — the flow here was vendor → us. **Nothing to backport**; the only
actionable note for a BSP owner is that the 6.1 RGA driver predates this series
and should pull the same commits from `develop-5.10`.

| # | What it does (vendor fix) |
|---|--------------------------|
| 0018 | RK3588 rev 3.2 low-voltage workaround (logic clock, no RGA2 auto-reset). |
| 0019 | RGA3 hardware batching / sequential-job mode. |
| 0020 | Fix slave_mode execution failure after master_mode. |
| 0021 | Fix request leak on multi-task submit failure. |
| 0022 | Fix submit failure when the acquire fence is already signaled. |
| 0023 | Fix IOMMU-prefetch page fault; ALIGN/ALIGN_DOWN misuse. |
| 0024 | Add `shadow_page` for cache-line-unaligned VA mappings. |
| 0025 | Fix cache-line-unaligned VA access fault. |
| 0026 | Fix VA map-size calculation with `shadow_page` at offset 0. |
| 0027 | Fix `rga_mm_lookup_iova()` error return. |
| 0028 | Fix bilinear scale-down coefficient check. |
| 0029 | `mpi_commit`: default interpolation on scale-up. |
| 0030 | Enable `config_intr`, parse error status. |
| 0031 | Fix incorrect check in update_LUT mode. |
| 0032 | Make RGA3 hardware format tables file-local (adapted vendor cleanup). |
| 0033 | Zero tile4x4 chroma bases (adapted vendor fix). |
| 0034 | `mpi_commit`: restore output_params swap for rotate 90/270. |
| 0035 | `mpi_commit`: `\|`→`\|\|` operator typo in rotate_mode check. |
| 0036 | Fix R2Y CSC-mode bit-shift definitions. |
| 0037 | Skip full_csc check for R2Y BT.709-limit on RGA3. |

## 0038–0058 — locally-found fixes on the validated tip

This is where the backport value concentrates. The MPP files and `rga_job.c`
we ported are byte-identical to BSP 6.1 (per the
[lifetime audit](../../findings/2026-07-21-forward-port-lifetime-resource-ownership-audit.md)),
so a lifetime/refcount bug observed here is, unless explicitly traced to the
port, a BSP bug observed through a better test harness (KASAN, DMA-debug,
hostile-ioctl replay) than the BSP ever ran under.

| # | What it does | Class | BSP evidence | Backport |
|---|--------------|-------|--------------|----------|
| 0038 | RKVENC2: terminate multi-slice encode on error IRQ instead of hanging `wait_result`. | `VENDOR` | Rockchip cherry-pick (Yandong Lin). | Verify it is merged in `develop-6.1`; pull it if not. |
| 0039 | RGA: validate raw physical imports (`virt_addr_valid`, overflow checks) before `dma_map_sg()`. | `HARDEN` | Donor accepts any `pfn_valid()` base — same crash surface. | **Yes (defensive)** |
| 0040 | RGA: release session buffers by kref on close instead of force-freeing shared/in-flight buffers. | `BSP-BUG` | Lifetime audit: donor close ignored aggregate krefs. | **Yes** |
| 0041 | MPP: unlink sessions from the procfs-visible service list before freeing private/DMA state. | `BSP-BUG` | Lifetime audit: donor teardown order races procfs readers. | **Yes** |
| 0042 | MPP: NULL `session->dma` after `RESET_SESSION` destroy (deterministic double-free). | `BSP-BUG` | Commit: "present in the upstream Rockchip vendor BSP (develop-6.1)". | **Yes** |
| 0043 | RKVENC2: sample the abort flag before the final task kref drop. | `PORT-FIX` | Commit: "forward-port-introduced"; BSP never reads `task->state` there. | No |
| 0044 | RGA: accept legacy `RGA2_GET_RESULT` as a compat no-op. | `PORT` | Compat gap of the unified forward-port `/dev/rga`; BSP applicability unestablished. | No (unclear) |
| 0045 | RGA: validate staged `REQUEST_CONFIG` descriptors; atomic staged-list replace (fixes a leak); reject reconfig while running. | `HARDEN` | Donor only copies the array. | **Yes (defensive)**, only together with 0046 |
| 0046 | RGA: accept legacy virtual-address blits in the 0045 check (regression fix). | `PORT-FIX` | Regression of 0045, not of BSP code. | Only bundled with 0045 |
| 0047 | RGA: report the RGA2 under-4G exclusion distinctly (`EOPNOTSUPP` + log). | `HARDEN` | Same silent policy failure exists in BSP. | Optional (diagnostics UX) |
| 0048 | RGA: reinterpret 10-bit raster `vir_w` as pixels and scale it to a byte stride; later reverted by current `0072`. | `FWPORT-REGRESSION` | This scaling block was added by the forward port. The BSP kernel consumes byte-unit `vir_w` directly. | **No** — current `0072` restores the BSP ABI |
| 0049 | RGA: reinterpret 10-bit `vir_w` as pixels when deriving the UV plane offset; later reverted by current `0074`. | `FWPORT-REGRESSION` | This depth scaling was added by the forward port. BSP `rga_convert_addr()` uses `vir_w * vir_h` directly. | **No** — current `0074` restores the BSP ABI |
| 0050 | RGA2: own MMU page tables through the DMA API (kills the `virt_to_phys()` streaming-sync). | `BSP-BUG` (latent) | Donor has the same illegal DMA-API use; it *works by accident* on stock BSP (identity translation, no swiotlb). | Yes (defensive — latent until the platform diverges) |
| 0051 | RGA2: serve over-4G memory via DMA-API mappings + swiotlb bounce. | `HARDEN` (new capability) | Donor has no equivalent path at all. | Optional — only if over-4G buffers matter to the BSP consumer |
| 0052 | RGA: drop the request's initial reference exactly once (four racing retire paths; KASAN UAF + refcount underflow). | `BSP-BUG` | Lifetime audit: "the same competing retirement puts exist in BSP `rga_job.c`". | **Yes** |
| 0053 | MPP: async worker fails safe on a device-less (orphaned) task instead of a NULL-deref hard lockup. | `BSP-BUG` | Lifetime audit: BSP worker has the same unchecked device dereference. | **Yes (defensive)** — carry the F4 orphan-leak caveat |
| 0054 | MPP: same guard on the synchronous wait/poll path. | `BSP-BUG` | Lifetime audit: BSP generic waiter has the same unchecked dereference. | **Yes (defensive)** — same caveat |
| 0055 | MPP: bounds-check register-translation imports (two unprivileged OOB writes, AV1-R1/AV1-R8). | `BSP-BUG` | Commit: "The BSP donor has the same '>' guard and unchecked copy length." | **Yes** |
| 0056 | MPP: unmap the RCB IOVA before freeing its backing pages (audit F8). **Root-only** (corrected 2026-07-29): the only callers of `rkvdec2_free_rcbbuf()`/`rkvenc2_free_rcbbuf()` are the probe-failure unwinds and `rkvdec2_remove()` / `rkvenc_remove()` (via `rkvenc_detach_ccu()`) — driver unbind, not an unprivileged path. The patch message already said so ("Reachable on probe-failure unwind and platform remove/unbind"); the triage framing did not. | `BSP-BUG` | Commit: "the ordering is unchanged BSP code." Present at `radxa` `rkr5.1` `mpp_rkvdec2.c:2009`–`2017` (`__free_pages()` before `iommu_unmap()`). | **Yes** |
| 0057 | RGA: a job holds its own session reference for its lifetime (IRQ-thread UAF on `session->tgid`). | `BSP-BUG` | `rga_job.c` is byte-identical to BSP 6.1; the missing reference is donor code. | **Yes** |
| 0058 | MPP: reject `RELEASE_FD` on a session with no DMA session (10-line unprivileged local DoS). | `BSP-BUG` | The unguarded `RELEASE_FD` arm is in byte-identical donor `mpp_common.c`. | **Yes** |

## 0059–0069 — the BSP-audit HIGH port

These eleven patches port, onto the evolved `0058` tip, **every HIGH finding of
the [BSP audit](./bsp-audit.md) still present there**. The audit reviewed the
forward-ported MPP+RGA files, which kept BSP code ~87% as-is; the audit itself
states the defects "are latent in the upstream Rockchip BSP too." Every one is
a backport candidate **by construction**. (Of the audit's 13 distinct HIGH
bugs, two were already gone from the tip: the RKVENC2 core-probe unwind, fixed
by `23ff47eab6f682`, and the duplicated RGA request-submit reference leak,
fixed by `b6ea72cb5f56e` — both of those fixes are themselves BSP-relevant.)

**BSP evidence for this block is no longer inference from "~87% as-is."** The
2026-07-29 two-tree diff above checked these defect sites directly against
`develop-6.1` @ `b4ef083dc0c3` and `radxa` `linux-6.1-stan-rkr5.1` @
`567401fe1718` and found them present verbatim in both — e.g. the `0060`
self-comparing `SET_SESSION_FD` guard sits at `rkr5.1` `mpp_common.c:1582`, the
same line the audit cites.

| # | What it does | Audit finding | Backport |
|---|--------------|---------------|----------|
| 0059 | MPP: handle task-message allocation failure; release the held session fd on `SET_SESSION_FD` alloc failure. | `mpp_common.c:250` | **Yes** |
| 0060 | MPP: require `f_op == &rockchip_mpp_fops` before trusting a foreign fd's `private_data` (`SET_SESSION_FD` type confusion). | `mpp_common.c:1582` | **Yes** |
| 0061 | RKVDEC2: bound the userspace RCB register index (`array_index_nospec`). | `mpp_rkvdec2.c:350/:359` | **Yes** |
| 0062 | RKVDEC2 link: test each iterated core's `disable` flag, not the outer worker device. | `mpp_rkvdec2_link.c:2587` | **Yes** |
| 0063 | RKVENC2: bound class read/write request counts before indexing fixed arrays. | `mpp_rkvenc2.c:958` | **Yes** |
| 0064 | RGA: balance the `sync_file_get_fence()` reference on every acquire-fence exit. | `rga_job.c:991` | **Yes** |
| 0065 | RGA: detach shutdown jobs under `irq_lock`, do sleeping cleanup after unlock (sleep-in-atomic). | `rga_job.c:682` | **Yes** |
| 0066 | RGA: validate required multi-plane handle buffers before building the RGA2 MMU table. | `rga_mm.c:1256` | **Yes** |
| 0067 | RGA: symmetric error ownership in `rga_mm_get_buffer()` (drop ref, clear out-pointer). | `rga_mm.c:1555` | **Yes** |
| 0068 | RGA: idempotent per-channel cleanup; unwind partial handle acquisition. | `rga_mm.c:1776` | **Yes** |
| 0069 | RGA policy: require the core feature mask to be a **superset** of the job's request, not any-overlap. | `rga_policy.c:351` | **Yes** |

## 0070 — the full-exercise follow-up

Found by running the destructive/fuzz ladder on the booted `0059`-`0069`
kernel (`Pabd5-C4ad2`), not by the audit. Same BSP-latent character as the
tier-1 fixes.

| # | What it does | Class | BSP evidence | Backport |
|---|--------------|-------|--------------|----------|
| 0070 | MPP: reject a second `INIT_CLIENT_TYPE` on an already-bound session with `-EBUSY`, closing the `session_link` list_add double-add (`mpp_session_attach_workqueue`) and the `session->dma` leak. | `BSP-BUG` | Unguarded `INIT_CLIENT_TYPE` bind sequence is byte-identical in the Rockchip 6.1 BSP; untouched by `0059`-`0069`. Deterministic unprivileged reproducer. | **Yes** — see [finding](../../findings/2026-07-22-mpp-process-request-list-add-double-add-warn.md) |

## 0071 — forward-port regression fix (our bug, not the BSP's)

Found by running the root-only gate ladder on the booted `0059`-`0070` kernel:
reading `/sys/kernel/debug/rkrga/mm_session` KASAN-faulted and wedged the reader
in unkillable D state. Unlike the tier-1 fixes, this one is **not** BSP-latent —
it is a regression introduced by our own forward-port RGA lifetime rework.

| # | What it does | Class | BSP evidence | Backport |
|---|--------------|-------|--------------|----------|
| 0071 | RGA: in `rga_mm_session_release_buffer()`, free the last buffer reference with `rga_mm_force_releaser_buffer()` (under the held `mm->lock`) instead of `kref_put(rga_mm_kref_release_buffer)`, which dropped and re-acquired `mm->lock` mid-`idr_for_each_entry` and left it owned by an exited/freed `task_struct`; plus a NULL-guard on `dump_buffer->session` in `rga_mm_session_show()`. | `FWPORT-REGRESSION` | Regression from forward-port `bc086cbe03d72c` (RGA lifetime rework); the Rockchip BSP force-releases under the held lock and is **not** affected. | **No** — BSP unaffected; see [finding](../../findings/2026-07-22-rga-mm-session-debugfs-uaf-freed-task-struct.md) |

## 0072 — scattered-userptr 16-byte alignment robustness

Found by the first on-hardware run of the scattered-userptr IOMMU fuzzer (the
`iommu-machinery-fuzz` root gate, never run before). Hardens a forward-port path
against a silent-corruption case rather than fixing a specific commit's mistake.

| # | What it does | Class | BSP evidence | Backport |
|---|--------------|-------|--------------|----------|
| 0072 | RGA3: reject a non-16-byte-aligned IOMMU window base in `rga_mm_get_buffer_info()` with `-EINVAL` instead of silently returning all-zero pixels. RGA3 fetches the base on a 16-byte granularity; the scattered-userptr `shadow_page` path carries the raw sub-page byte offset in the base with a zeroed head, so a non-16-aligned source read the zero head. | `FWPORT-ROBUSTNESS` | Concerns forward-port-only scattered-userptr / `shadow_page` code (not in the BSP); fail-loud, no functional change to aligned userptr or dma-buf. | **No** — forward-port-specific path; see [finding](../../findings/2026-07-23-rga-scattered-userptr-unaligned-src-zero-output.md) |

## Current `0072`–`0094` — outside the 2026-07-22 compilation

This compatibility heading records the range added after the catalog's first
compilation. It is not a moving “current tip” owner.

> **These rows use CURRENT numbering**, unlike everything above, which uses the
> pre-cleanup scheme (this page's `0072` is current `0071`). The 23 patches
> below all landed after this page was compiled on 2026-07-22.

`0072`–`0075` are the 10-bit RGA stride/UV-offset trio and the RKVENC2
slice-FIFO fix. Provenance was subsequently checked: `0072` and `0074` repair
forward-port regressions and restore the BSP kernel's byte-unit `vir_w`
contract, so neither is a BSP backport candidate. They pair with the librga
fork's [im2d pixel-to-byte request translation](../../vendor-libraries/rga/docs/librga-p010-p210-rkrga.md).
`0073` is fail-closed RGA2 hardening; classify the independent `0075` slice-FIFO
fix on its own evidence.

`0076`–`0079` are the [2026-07-29 WARN/oops audit
sweep](../../findings/2026-07-29-forward-port-warn-oops-audit-and-fixes.md).
The linked finding owns the bounded source/validation record; the rows below
retain public provenance and backport disposition.

`0080` is the 2026-07-31 mapped-SG contract reconciliation. Its direct-span
admission check repairs forward-port-only hardening, while its RGA2 page-table
walker corrects vendor code that mixed original SG lengths/counts with mapped
DMA addresses. It was compile-checked at preparation; the scorecard and linked
findings own later hardware evidence and remaining discriminators.

`0081`–`0087` are the 2026-08-01 ioctl/lifetime audit fixes and their
adversarial-review repairs. The audit traces most defect sites to the BSP
import, while the session-fd ordering bug and the original RGA ownership leak
were forward-port regressions. These rows preserve that mixed provenance; the
audit finding and scorecard own validation.

`0088` imports the BSP's RK3588 IEP2 block and board DT enablement into 6.18.
`0089` is its three-way safety-review tail. It contains both adaptations to the
6.18 IOMMU/fault ABI and defects inherited from the BSP-shaped MPP/IEP2 code;
backport only the latter after translating them to the BSP provider ABI. See the
[IEP2 safety review](../iep2/docs/forward-port-safety-review.md).

`0090`–`0092` close the known-open RGA job-task, MPP provider-callback/task,
and decoder recovery lifetime gaps from the 2026-08-01 audit. They passed an
affected-object arm64 `W=1` build at preparation. Their mixed backport boundary
is recorded in the rows below and the
[fix finding](../../findings/2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md);
the [scorecard](./forward-port-status.md) owns accumulated capability evidence.

`0093` repairs the forward-port-only RGA2 over-4-GiB service added by `0050`:
the selected 32-bit DMA backend cannot map a merged multi-megabyte USERPTR SG
entry through SWIOTLB even when the pool has ample free space. The fix shapes
only RGA2-bound USERPTR entries to `dma_max_mapping_size()` and is not a BSP
backport candidate; the BSP has no equivalent over-4-GiB RGA2 bounce path.

`0094` handles the DMA-BUF half that `0093` cannot: the exporter, not RGA,
owns the attachment SG table, so an oversized high-memory entry cannot be
split in place. Compatible work stays on RGA3; RGA2-only work stages
CPU-accessible buffers through a bounded, alias-preserving DMA32 object after
the exact SWIOTLB attachment failure. This is another forward-port capability
repair, not a literal BSP backport. The clean-room rewrite has a separate
recorded design because its job, dispatch, and mapping ownership are different.

| # | What it does | Class | BSP evidence | Backport |
|---|--------------|-------|--------------|----------|
| 0076 | MPP core: fix `mpp_check_req()` clamping to the overflow amount and using a signed offset (two independent bypasses); bound the register-offset translation index, the `trans_info[]` format index, and user-supplied `trans_table[]` register indexes; publish the `RESET_SESSION` DMA teardown under `srv->session_lock`. | `BSP-BUG` | All five sites are vendor code carried unchanged from the BSP import; the bounds and the clamp expression are byte-identical in `develop-6.1`. The `session_lock` half is partly forward-port shaped — `mpp_session_deinit()`'s unlink is ours — so confirm the BSP's procfs exposure before sending that hunk. | **Yes** — the four bounds fixes close unprivileged heap corruption in vendor code |
| 0077 | MPP IOMMU: route the reserve/unreserve IOVA paths through `iommu_dma_get_iova_domain()` and delete the private cookie shadow struct; clear `sgt`/`attach`/`dmabuf` before `dma_buf_detach()` frees them, plus defensive checks in `mpp_dma_buf_sync()`. | Mixed: `PORT-FIX` + `BSP-BUG` | The cookie type-confusion exists **only** because 6.18 made `iova_cookie` a discriminated union arm — the BSP's older headers have no such union, so that half is ours. The release-ordering half is BSP code and BSP-latent. | **Partial** — send the release-ordering fix; the cookie fix is 6.18-only |
| 0078 | rkvenc2/rkvdec2-link: reject wrapped and inverted register windows in `req_over_class()`/`rkvenc_update_req()` and check both previously-discarded call sites; bound the per-class register buffers; hoist the VEPU510 clock cycle out of `mpp_task_run_begin()`'s `preempt_disable()` window; downgrade a reachable `WARN_ON` on an empty link-table list. | `BSP-BUG` | All four are vendor code. The window-wrap arithmetic, the preempt/clk ordering, and the `WARN_ON` are unchanged from the import. Note two are not reachable on RK3588 (VEPU510 is RK3576; the WARN needs HARD-CCU), but both are live for other Rockchip parts built from the same source — which is exactly the BSP's audience. | **Yes** — the window wrap is unprivileged ~4 GiB `copy_from_user` |
| 0079 | RGA: take `irq_lock` in the IOMMU fault handler; reject a negative computed buffer size in `rga_alloc_virt_addr()`; surrender buffer session ownership on release; consume `current_mm` under `request->lock`; dump the request task list under its lock; reject zero-length debugfs writes; validate userptr PFNs before `pfn_to_page()`. | `BSP-BUG`, except the PFN guard | Six of seven are vendor code with the same defect in `develop-6.1`. The PFN guard is on the 6.12+ `follow_pfnmap_start()` adaptation, which is a forward-port rewrite of the BSP's page-table walk — the *missing validation* is common to both, but the code shape is ours, so the BSP needs the equivalent fix rather than this hunk. | **Yes**, with the PFN hunk adapted |
| 0080 | RGA: accept several byte-adjacent mapped entries as one direct span; sum the complete mapped view; and make RGA2 PTE construction walk mapped DMA entries/lengths, preserve page-aligned gaps, and reject unrepresentable boundaries or incomplete coverage. | Mixed: `PORT-FIX` + `BSP-BUG` | The one-span admission helper was introduced by the 6.18 hardening line. The RGA2 walker came from the vendor import and combined `sg_dma_address()` with original `sgl->length`/`orig_nents`, which is not a valid mapped-SG contract. | **Partial** — backport the RGA2 mapped-entry walker; the direct-span helper is forward-port-only |
| 0081 | MPP: repair AV1 `grf_info` NULL handling, snapshot translation indexes across sleeping imports, validate session fds before dropping the prior reference, and recycle failed message batches. | Mixed: `BSP-BUG` + `PORT-FIX` | The AV1 NULL dereference, translation double-fetch, and message leak are BSP-imported. The dangling session-fd ordering was introduced by current-series `0059`. | **Partial** — backport the three BSP-shaped fixes; do not carry the forward-port regression hunk blindly |
| 0082 | MPP: count references handed out by `TRANS_FD_TO_IOVA` so `RELEASE_FD` cannot free a buffer still owned by an in-flight task. | `BSP-BUG` | The unconditional release and shared static/task buffer pool are inherited vendor design. | **Yes** — prevents unprivileged live-DMA unmap and refcount corruption |
| 0083 | RKVENC2: reject writes through unallocated class buffers and terminate the user-controlled eight-byte codec-info field before procfs formatting. | `BSP-BUG` | Both the lazy class allocation and `%8s` over-read sites are unchanged vendor code. | **Yes** — deterministic oops plus kernel-heap disclosure |
| 0084 | RKVDEC2 soft-CCU: synchronize timeout-work cancellation and clear `cur_task` as a task leaves the running list. | `BSP-BUG` | The non-sync cancellation and never-cleared published task pointer are in the vendor soft-CCU path. | **Yes** — closes timeout-work and hard-IRQ use-after-free paths |
| 0085 | RGA: restrict ioctl import types, type-check external lookup, authenticate request ownership, retire blit errors through the kref, and count import ownership. | Mixed: `BSP-BUG` + `PORT-FIX` | The pointer/physical import exposure, global request IDs, raw destructor, and cross-type lookup are BSP-imported. Import ownership repairs the forward-port `0079` session-clearing regression. | **Partial** — backport the ioctl/authentication fixes; adapt ownership to the BSP's release model |
| 0086 | RGA: authenticate `RGA_IOC_RELEASE_BUFFER` against the importing session. | `BSP-BUG` | The global buffer IDR and unchecked release ioctl are vendor code. | **Yes** — sibling unauthenticated-put primitive |
| 0087 | Repair review findings in `0081`–`0085`: owner-only RGA import counting, fd-reference-last message release, serialized MPP release, complete timeout/`cur_task` locking, and fd/PTR de-duplication. | Mixed corrective follow-up | Some corrections repair bugs introduced by `0081`/`0085`; the message-release ordering, split release race, hard-CCU cancellation, and unlocked `cur_task` publication/read are pre-existing same-shape defects. | **Partial** — pair each correction with its owning backport; never backport `0081`–`0085` without this review tail |
| 0088 | Add RK3588 IEP2 vendor-ABI deinterlacing, binding, and ROCK 5B DT enablement. | `PORT` / `VENDOR` | The functional driver and DT description are adapted from `develop-6.1`; the BSP already contains IEP2. | **No** — feature forward port; BSP already has the donor implementation |
| 0089 | Harden IEP2 task/fault/remove lifetime, clock/reset handling, fault recovery, DMA-span validation, raw-address rejection, auxiliary mapping ownership, and fixed-IOVA exclusivity. | Mixed: `BSP-BUG` + `PORT-FIX` | Timeout/current-task, callback teardown, resource-error, raw-address, span-validation, and mapping-ownership shapes descend from vendor code. Generic fault flags, provider synchronization plumbing, and the exclusive IOVA API are 6.18-shaped adaptations. | **Partial** — carry the donor-shaped safety fixes, adapted to the BSP's raw fault-status/provider ABI; do not apply the 6.18 plumbing verbatim |
| 0090 | RGA: give jobs private task-list snapshots and copy OSD results back only while the matching request is kref-pinned and locked. | `VENDOR-BUG` in the later batching line | The inspected `develop-6.1` branch stores one task by value and lacks this exact borrow. The multi-task borrow arrived with Rockchip's later batching import. | **Conditional** — carry into vendor branches that have the multi-task `job->task_list` batching shape; not needed by the inspected older by-value layout |
| 0091 | Rockchip/VSI IOMMU: hold `fault_lock` through provider callbacks so clear is a quiescence barrier; pin generic MPP and RKVENC2 `cur_task` walks with `running_lock`. | Mixed: `PORT-FIX` + `BSP-BUG` | Provider handler/token hooks are forward-port plumbing. The bare generic and RKVENC2 task reads are present in `develop-6.1`; its provider ABI needs a different teardown adaptation. | **Partial** — backport the task locking and provide an ABI-appropriate callback/token quiescence rule |
| 0092 | RKVDEC2: retain failed soft-CCU tasks until reset quiesces DMA, claim reset requests before soft/hard reset so concurrent requests survive, and keep the link-mode fault task walk locked. | `BSP-BUG` | `develop-6.1` has the same retire-before-reset, clear-after-reset, and unlock-before-task-dump shapes. | **Yes**, adapted and runtime-tested on each supported CCU mode |
| 0093 | RGA2: cap direct and transient USERPTR SG entries at the selected DMA backend's maximum mapping size before SWIOTLB bounce. | `PORT-FIX` | The failure is in the forward-port-only over-4-GiB RGA2 service introduced by `0050`; the BSP rejects those high buffers instead of bouncing them. | **No** — forward-port-specific capability repair; see the [6.18.43 finding](../../findings/2026-08-08-forward-port-rga2-userptr-swiotlb-segments.md) |
| 0094 | RGA2: prefer zero-copy RGA3 for high DMA-BUFs, then stage CPU-accessible RGA2-only buffers in shared job-owned DMA32 pages after an exact attachment `-EIO`; copy back only on successful completion and publish lifecycle counters. | `PORT-FIX` | The BSP's RGA2 path requires below-4-GiB inputs and has no equivalent high-DMA-BUF service. The rewrite owns a different reroute/queue lifetime and needs the separately recorded design rather than this patch. | **No** — forward-port-specific capability repair; see the [staging finding](../../findings/2026-08-08-forward-port-rga2-dmabuf-staging.md) |

The `0079` session-ownership fix deliberately does **not** revert
`0071`/catalog-`0072`'s force-free-under-the-held-lock decision: that decision is
still correct, and the ownership test around it is what was wrong. Anyone
backporting to a BSP that lacks `0071` should carry both or neither.

## The BSP backport set

What should go back to Rockchip's `develop-6.1`, in priority order:

**Tier 1 — memory-safety and crash fixes confirmed (or byte-identity-traced)
in BSP code.** 20 patches: `0040`, `0041`, `0042`, `0052`, `0053`+`0054`,
`0055`, `0056`, `0057`, `0058`, and all of `0059`–`0069`. These close
unprivileged-reachable OOB writes (`0055`, `0061`, `0063`), an fd type
confusion (`0060`), a trivial local DoS (`0058`), KASAN-proven
use-after-frees/double-frees (`0042`, `0052`, `0057`), a stale IOMMU
mapping over freed pages (`0056` — **root-only**, driver unbind; see its row),
a sleep-in-atomic (`0065`), and NULL-deref hard lockups (`0053`/`0054`).

> **Corrected 2026-07-29** (source record kept in the private
> `rock-5b-security` repository).
> `0040` was previously named inside the KASAN-proven
> use-after-free/double-free group above. It does not belong there, and it is
> still a Tier-1 backport candidate on a **different** evidence class.
> Its own finding
> ([`2026-07-17-rga-session-close-uaf.md`](../../findings/2026-07-17-rga-session-close-uaf.md))
> records "**Artifacts:** none committed" (:82), says "the **exact faulting
> function is not proven** … attribution of *this* Oops to the force-free path
> is INFERRED" (:88–:92), and concludes "the reported Oops is now better
> treated as either coincidental to the close or a distinct latent bug" (:93–
> :100). The fix itself is **compile-verified only** and "has **not** been
> re-exercised on hardware" (:106). So `0040`'s real class is
> **SOURCE-INSPECTED** (cross-session import de-dup + in-flight job kref vs an
> unconditional force-free) plus one **INFERRED**, artifact-less Oops the
> finding disowns, with a **COMPILE-VERIFIED** fix. No KASAN report, no
> reproducer run against it, no committed artifact.

**Tier 2 — user-visible correctness.** Do **not** backport `0048`+`0049`; they
introduced the pixel-versus-byte ABI drift that current `0072`+`0074` undo.
The BSP kernel already has the restored arithmetic. A P010 failure on a BSP
image must instead be reproduced against that image's exact librga/request
translation before assigning the fault to the kernel. Also confirm vendor
cherry-pick `0038` (multi-slice encoder hang) is present in `develop-6.1` and
pull it if not.

**Tier 3 — defensive hardening, at the BSP owner's option.** `0039`
(physical-import validation), `0045`+`0046` (staged-task validation, taken
only as a pair), `0047` (under-4G diagnostics), `0050` (DMA-API page-table
ownership — latent on stock BSP, real on any platform where
`virt_to_phys() != dma_addr`), `0051` (over-4G RGA2 service — new capability,
not a fix).

**Not applicable to the BSP:** `0001`–`0017` (port infrastructure and its own
fixes), `0018`–`0037` (already Rockchip's), `0043` (port-introduced bug),
`0044` (port-ABI compat, BSP applicability unestablished).

### Mechanics and caveats

- **Use `cleanup-split/` as the mechanical base for the audit HIGHs.** The
  `0059`–`0069` ports are written against the evolved tip (RGA2 bounce
  mappings, DMA-owned page tables); the same fixes exist in
  [`patches/cleanup-split/`](../patches/cleanup-split/README.md) written
  against near-pristine BSP-derived source, in upstream mailbox style with
  `Plain-language impact:`/`Kernel details:` trailers. Mind its two known defects (8-file divergence from the
  verified aggregate; the patch-0024 compile defect and its one-line remedy).
  The `0040`–`0058` fixes were authored on the evolved tree and need context
  rebasing onto BSP source.
- **`0053`/`0054` carry a known trade-off**: the fail-safe orphan drop
  introduces the audit's F4 destructorless-leak shape; fold the F4 remediation
  when backporting.
- **Runtime gates travel with the fixes.** Evidence from the forward-port tree
  does not prove a BSP application. Carry the targeted and codec/RGA regression
  gates in
  [`cleanup-draft/verification.md`](../patches/cleanup-draft/verification.md)
  with any backport; use the scorecard and dated port record for the bounded
  forward-port result.
- **Second wave**: the audit's 30 MEDIUM + 30 LOW + 13 cleanup findings are
  equally latent in the BSP and live only in `cleanup-split/`; none are in the
  recorded `0092` forward-port export.
