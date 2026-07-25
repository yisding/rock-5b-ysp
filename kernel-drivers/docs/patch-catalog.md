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

**Verification** — where hardware proof currently stands (details:
[forward-port status](./forward-port-status.md), series README):

- `0001`–`0058`: **boot-validated** as a whole on debug build `Pd222-C4ad2`
  (full conformance + GStreamer suites green). Individual fixes in the
  `0042`–`0058` tail each also carry their own targeted KASAN/gate evidence on
  the earlier debug builds (`Pb999`, `P63dd`, `P9636`, `P7589`, `P9c12`).
- `0059`–`0069`: per-commit checkpatch-clean, packaged in KASAN/lockdep build
  `Pabd5-C4ad2`, **installed and booted 2026-07-22** (fingerprint-verified)
  with clean boot health, a bit-exact four-codec decode differential, and a
  clean KASAN MPP suite. The targeted hostile-ioctl gates
  (foreign-fd, RCB/request bounds, acquire-fence, missing-plane /
  partial-handle) and the librga/ABI/FFmpeg/GStreamer sweep on that boot are
  still open — see the
  [port record](../../findings/2026-07-22-bsp-high-current-tip-port.md).
- The Published PPA package stops at `0041`; production `Pf558-Cb831` carries
  through `0043`.

A backport verdict below is a statement about **where the fix belongs**, not
that it is ready to ship: anything not yet through its runtime gate keeps that
gate as a prerequisite in either tree.

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
| 0048 | RGA: byte-literal strides for 10-bit rasters (P010/P210, NV15/NV20). | `BSP-BUG` | Conformance finding: "the reference BSP 6.1 tree is byte-identical in this logic — this is stock vendor behavior"; the Jellyfin-known P010 corruption. | **Yes** (pair with 0049) |
| 0049 | RGA: byte-literal 10-bit UV plane offsets in `rga_convert_addr()`. | `BSP-BUG` | Same byte-identical donor function; measured chroma-never-written defect. | **Yes** (pair with 0048) |
| 0050 | RGA2: own MMU page tables through the DMA API (kills the `virt_to_phys()` streaming-sync). | `BSP-BUG` (latent) | Donor has the same illegal DMA-API use; it *works by accident* on stock BSP (identity translation, no swiotlb). | Yes (defensive — latent until the platform diverges) |
| 0051 | RGA2: serve over-4G memory via DMA-API mappings + swiotlb bounce. | `HARDEN` (new capability) | Donor has no equivalent path at all. | Optional — only if over-4G buffers matter to the BSP consumer |
| 0052 | RGA: drop the request's initial reference exactly once (four racing retire paths; KASAN UAF + refcount underflow). | `BSP-BUG` | Lifetime audit: "the same competing retirement puts exist in BSP `rga_job.c`". | **Yes** |
| 0053 | MPP: async worker fails safe on a device-less (orphaned) task instead of a NULL-deref hard lockup. | `BSP-BUG` | Lifetime audit: BSP worker has the same unchecked device dereference. | **Yes (defensive)** — carry the F4 orphan-leak caveat |
| 0054 | MPP: same guard on the synchronous wait/poll path. | `BSP-BUG` | Lifetime audit: BSP generic waiter has the same unchecked dereference. | **Yes (defensive)** — same caveat |
| 0055 | MPP: bounds-check register-translation imports (two unprivileged OOB writes, AV1-R1/AV1-R8). | `BSP-BUG` | Commit: "The BSP donor has the same '>' guard and unchecked copy length." | **Yes** |
| 0056 | MPP: unmap the RCB IOVA before freeing its backing pages (audit F8). | `BSP-BUG` | Commit: "the ordering is unchanged BSP code." | **Yes** |
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

## The BSP backport set

What should go back to Rockchip's `develop-6.1`, in priority order:

**Tier 1 — memory-safety and crash fixes confirmed (or byte-identity-traced)
in BSP code.** 20 patches: `0040`, `0041`, `0042`, `0052`, `0053`+`0054`,
`0055`, `0056`, `0057`, `0058`, and all of `0059`–`0069`. These close
unprivileged-reachable OOB writes (`0055`, `0061`, `0063`), an fd type
confusion (`0060`), a trivial local DoS (`0058`), KASAN-proven
use-after-frees/double-frees (`0040`, `0042`, `0052`, `0057`), a stale IOMMU
mapping over freed pages (`0056`), a sleep-in-atomic (`0065`), and
NULL-deref hard lockups (`0053`/`0054`). Several have deterministic
reproducers in [`kernel-drivers/tests/`](../tests).

**Tier 2 — user-visible correctness.** `0048`+`0049` as a pair: the 10-bit
P010 stride/offset corruption is stock BSP behavior (the corruption Jellyfin
users report on vendor kernels). Also confirm vendor cherry-pick `0038`
(multi-slice encoder hang) is present in `develop-6.1` and pull it if not.

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
  `Plain-language impact:`/`Kernel details:` trailers — deliberately shaped
  for submission. Mind its two known defects (8-file divergence from the
  verified aggregate; the patch-0024 compile defect and its one-line remedy).
  The `0040`–`0058` fixes were authored on the evolved tree and need context
  rebasing onto BSP source.
- **`0053`/`0054` carry a known trade-off**: the fail-safe orphan drop
  introduces the audit's F4 destructorless-leak shape; fold the F4 remediation
  when backporting.
- **Runtime gates travel with the fixes.** `0059`–`0069` have not booted
  anywhere yet (`Pabd5-C4ad2` is packaged, not installed); the targeted
  triggers and codec/RGA regression gate in
  [`cleanup-draft/verification.md`](../patches/cleanup-draft/verification.md)
  apply to a BSP application of the same fixes just as much.
- **Second wave**: the audit's 30 MEDIUM + 30 LOW + 13 cleanup findings are
  equally latent in the BSP and live only in `cleanup-split/`; none are ported
  to the current tip.

### Submission status and priority

Nothing has been submitted to Rockchip, Armbian, or mainline as of
2026-07-22. The [audit's upstreaming note](./bsp-audit.md) records the
submission-target decision (Rockchip BSP vs Armbian vs mainline alongside the
[rewrite drivers](./rewrite-drivers.md)) as awaiting an owner decision; this
catalog is the per-patch inventory that decision needs.

**Which to report immediately** (severity triage, venue, and CVE candidates)
is worked out in
[`findings/2026-07-22-bsp-bug-upstream-submission-priority.md`](../../findings/2026-07-22-bsp-bug-upstream-submission-priority.md):
the unprivileged memory-corruption subset — `0055` (OOB write over a
`work_struct`), `0060` (type confusion), `0070` (double-init UAF of a freed
`mpp_session`), `0052`/`0057`/`0042` (UAF/double-free), and `0058` (DoS) —
clears the report-now bar; `0055`/`0060`/`0070` have standalone unprivileged
PoCs under [`kernel-drivers/tests/`](../tests). Venue is the Rockchip BSP +
Armbian (this code is not in mainline), with CVEs for the OOB/type-confusion/UAF
rows.
