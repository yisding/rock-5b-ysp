# Multi-agent defect audit of the rewrite drivers: 17 confirmed, 4 refuted, all fixed

> Scope: kernel-drivers — `mpp-rewrite` + `rga-rewrite` clean-room drivers
> Source: `~/Code/rock-5b/kernel/linux-6.18-rkvenc` @ `185d4dcec1100` (branch
> `rk3588-rewrite-6.18`); fixes land as `c540d63a8a9be..d3a4d4812e9ed`, cherry-picked
> to `~/Code/rock-5b/kernel/linux` @ `7afd5ec514f0b..fc329e693da0c` (`rk3588-rewrite-mainline`).
> Oracles: `drivers/video/rockchip/{rga3,mpp}/` in the same tree, the in-tree
> `ABI.rst` ledgers, and `~/Code/rock-5b/rockchip-userspace/librga-fork`.
> Date: 2026-07-24
> Trust: CODE-INSPECTED, COMPILE-VERIFIED — no booted kernel, no hardware run

## Result

A 38-agent audit (14 subsystem-scoped finders, then one independent adversarial
refuter per finding) over the ~23k lines of production code in the two rewrite
drivers produced **24 candidate defects; 20 survived refutation, deduplicating to
17 distinct defects. All 17 are fixed** across 12 commits, split by defect class.

The refutation pass is the part worth keeping. It did not merely filter — in
several cases it *confirmed the defect while destroying the finder's reachability
argument*, which changed what the fix had to cover:

- The headline session use-after-free was reported against the IRQ-thread
  completion path. That path is **fenced**: `rk_rga_hw_abort_session_jobs()` calls
  `rk_rga_hw_disable_irq()` → `disable_irq()` → `synchronize_irq()`, which waits
  for the threaded handler to return. The genuinely unfenced racer is the
  pending-acquire worker on `system_highpri_wq`, which `rk_rga_release()` queues
  and never flushes, and which the `dispatching_jobs` counter stops covering once
  `session->closing` is set. Same fix, different reason, and the reason is what
  tells you the KUnit coverage cannot reach it.
- The route-B userptr bug was reported with the wrong bounce predicate (the finder
  claimed any non-cache-line-aligned length). The real trigger is
  `dma_kmalloc_size_aligned()` failing for the *tail* segment — a glibc-typical
  16-byte tail on a page-multiple malloc — which flips the whole list to
  `iommu_dma_map_sg_swiotlb()`. That also resolves the "UNRESOLVED" note in
  [`kernel-drivers/rga/docs/userptr-iommu.md`](../kernel-drivers/rga/docs/userptr-iommu.md):
  the hardware DIAG showing `first=0xdffff010 … end=0xdfc7900f` is exactly a
  16-byte tail segment, so route B in production is being reached *through* the
  bounce path.
- Four claims were refuted outright (below).

Two of the 17 are **regressions this repo introduced**, not latent gaps: the
route-B SWIOTLB defect was created by `0d71ded1690c9` deleting
`rk_rga_reset_sgt_dma_state()` and its pre-remap unmap, which
[`kernel-drivers/patches/rga-userptr-iommu/architecture.md`](../kernel-drivers/patches/rga-userptr-iommu/architecture.md)
still describes as part of the coherency model and which the forward-port sibling
`rk3588-fwport-0015` still implements. The RGA3 compact-10-bit destination
`x_offset` was left unconverted by `185d4dcec110`, which fixed the stride half of
the same arithmetic.

### The 17 defects

**RGA — lifetime (`c540d63a8a9be`)**

1. `rk_rga_job_unlink_session()` woke `session->job_wait` after dropping
   `session->job_lock`; `rk_rga_release()` evaluates `rk_rga_session_jobs_empty()`
   under that lock and `kfree()`s immediately. `wait_event()` checks its predicate
   *before* touching the waitqueue, so the free can happen inside the two-statement
   gap. Unprivileged, via `RGA_BLIT_ASYNC` with an unsignaled acquire fence + `close()`.
2. Same shape in `rk_rga_session_end_job_dispatch()` against the dispatches-idle wait.
3. Same shape in `rk_rga_hw_put()` vs `rk_rga_hw_remove()` + devres free. Needs a
   surviving `job->cmd_hw` reference, which `rk_rga_job_complete()` does not drop.

**RGA — recovery (`3f3356835d25d`)**

4. A stale timeout worker reset the *next* task of a multi-task job, because the
   match was by job pointer and a re-dispatched job keeps its pointer. The sibling
   `mpp-rewrite` already had the generation guard; RGA did not, despite both being
   touched by the same `1fe46df86f1ca` hardening commit.

**RGA — DMA (`5fdb7fae9044e`)**

5. Route B kept the SWIOTLB-bounced DMA-API mapping alive, so cache maintenance
   targeted the bounce buffer and `dma_unmap_sgtable()`'s copy-back overwrote the
   device's output with a pre-job snapshot.

**RGA — command emission (`fc9ba31376df9`)**

6. `rk_rga2_image_offsets()` added compact 10-bit `x_offset` as bytes, not
   `x * 10 / 8` — Y/UV base 20% short for every non-zero crop.
7. `rk_rga3_emit_wr()` had the same gap on the compact 10-bit destination path.
8. RGA2 color key never programmed `MODE_CTRL` alpha-zero-key (bit 5), which the
   driver's own validator proves userspace sets.
9. RGA2 vertical bicubic scale-up missing the 1996-pixel line-buffer clamp.

**RGA — capability parity (`2deb9f36cd921`)**

10. No 1/8x..8x scale-range gate, so RGA3 was programmed for ratios only RGA2E can
    perform (librga's `imcheck` permits up to 16x).
11. No 68x2 minimum window, so a plain 64x64 `imcopy` was dispatched to RGA3
    outside its declared input/output range.

**RGA — uAPI (`0f875c754f916`)**

12. Legacy `RGA_BLIT_ASYNC` replied out of the kernel-mutated `job->tasks`,
    disclosing resolved DMA/IOVA addresses and racing the dispatcher that rewrites
    those same fields.

**MPP (`fdcd18b95c4d8`, `13ccdc1c57d39`, `6cced13d24b85`, `c54612469e407`, `83d02ac522389`, `d3a4d4812e9ed`)**

13. The queued-job abort sweep parked jobs on `job->sched_link` — the very member
    whose emptiness is the ownership predicate for the queue reference — letting a
    concurrent `rk_mpp_job_dequeue()` drop a reference it does not own (UAF, plus a
    permanent negative skew in the counters that drive core selection).
14. `rk_mpp_hw_abort_job()` disarmed the core's watchdog before checking ownership,
    silently voiding an unrelated session's 500 ms software timeout for the rest of
    that job's life.
15. `rk_mpp_rkvenc2_submit()`'s error tail gated clocks and dropped the last job
    reference without draining the hard IRQ — MMIO on a powered-off aperture, and
    sleeping dma-buf teardown from hardirq context.
16. `MPP_CMD_TRANS_FD_TO_IOVA` did `copy_to_user()` under the device-global
    `srv->hw_lock` — an unprivileged stall of all codec submission and completion.
17. `rk_mpp_rkvdec2_release_link_table()` wrote the CCU `WORK` register after
    terminal power drain (hard-CCU mode only; no DT here selects it).
18. Missing the BSP's VEPU580 H.264 slice-flush erratum fixup.

(17 distinct defects; the list numbers 18 because items 1–2 are one commit-level fix.)

### Refuted

- **Module unload frees `rk_rga_fence_ops` under live sync_file fds.** `.owner =
  THIS_MODULE` on the misc device holds a module reference; the trigger cannot occur.
- **`MPP_CMD_SET_RCB_INFO` on a client-less session bypasses the RKVENC 4-entry cap.**
  Mechanism real, but not reachable to a consequence.
- **`start_ccu_job` re-programs from a stale powered-cores snapshot.** Every entry
  shares `job->hw`'s IOMMU domain; fails on reachability.
- **`rk_mpp_hw_remove()` sleeps forever skipping its own active job.** Could not
  close reachability of the required unqueue.

### Two pre-existing KUnit fixture bugs, fixed en route

`rk_rga_mixed_task_core_handoff_kunit()` calls `rk_rga_job_release_hw()` →
`rk_rga_hw_put()` → `wake_up()` on a `wait_queue_head` that was never initialised,
which oopses in `__wake_up_common()` on `head.next == NULL`. Two more fixtures have
the same hole. **This strongly suggests the 232-case KUnit suite has never actually
been executed in this tree** — worth settling before treating a green run as evidence.

## Evidence and reproduction

- **Identity:** code-only. `~/Code/rock-5b/kernel/linux-6.18-rkvenc` @ `185d4dcec1100`
  (clean) and `~/Code/rock-5b/kernel/linux` @ `d5165caeddb70`. Rewrite sources were
  byte-identical between the two before and after; verified with `cmp` both times.
- **Detection:** production regions only — `rga_rewrite.c` 1–7913 and 18473–23583,
  `mpp_rewrite.c` 1–3302 and 7877–13927. The embedded KUnit blocks were excluded
  from the hunt and every finder was told to reject a "defect" living in them.
- **Exercise:** the three clean-source profiles, run against a `git ls-files` copy
  of the working tree rather than a `git archive` of HEAD, so uncommitted fixes
  were actually compiled:
  ```
  REWRITE_BUILD_PROFILES='normal memory race' bash kernel-drivers/tests/rewrite-build-gate.sh 6.18
  ```
  Equivalent config matrix: `ROCKCHIP_MPP_REWRITE` + `ROCKCHIP_RGA_REWRITE` with
  both KUnit suites, `ROCKCHIP_IOMMU`, targets `rockchip-iommu.o`, both rewrite
  objects, and `rockchip/rk3588-rock-5b.dtb`.
- **Pass/fail signal:** all three profiles completed with **zero** `warning:` lines.
  Mainline (`v7.2-rc2` base) built clean in the `normal` profile with rewrite KUnit
  enabled. Every one of the 12 intermediate commits was compiled individually — all
  clean, so the series is bisectable.
- **Artifacts:** none retained; scratch build trees were removed. The 12 commits and
  their messages are the durable record.

One real defect surfaced *only* in the KUnit-enabled build: the MPP KUnit block
calls `rk_mpp_job_rkvenc_fixup_slice_flush()` before its definition. The in-tree
`.config` has `ROCKCHIP_MPP_SERVICE=y` (forward-port) and no `ROCKCHIP_MPP_REWRITE`,
so an ordinary in-tree object build silently skips ~4.5k lines of MPP test code.
**Do not treat an in-tree `mpp_rewrite.o` build as coverage of that file.**

## Boundary

This is a **source-level audit with a compile gate, and nothing more.**

- **No KUnit suite was executed and no hardware ran.** The 232 cases were compiled,
  not run — and per the fixture bugs above, there is reason to doubt they have ever
  run in this tree.
- Several fixes change **emitted register values** (10-bit offsets on both cores,
  RGA2 color-key bit 5) or **core routing** (RGA3 scale/window gates). None is
  validated against the forward-port oracle on real silicon. The byte-exact
  differential comparison in
  [`rewrite-validation-plan.md`](../kernel-drivers/docs/rewrite-validation-plan.md)
  is the settling run.
- Two fixes carry **open hardware questions** the refuters explicitly could not
  close from source:
  - Compact 10-bit `WR_Y_BASE` bias is now 5-byte granular (`x/4*5`). If the RGA3
    write master requires a wider-aligned base, the fix trades a wrong column for a
    misaligned write, and the correct answer is to reject those offsets or route
    them through `OVLP_OFF` as the BSP does. Probe `x_offset = 64` (→ 80, 16-byte
    aligned) first, then `x_offset = 4` (→ 5).
  - Whether RGA2 `MODE_CTRL` bit 5 suppresses writes for keyed pixels or only zeroes
    their alpha. The register-level divergence from the BSP is certain; the
    pixel-level symptom is not.
- The **68x2 gate is a deliberate behaviour change with a known cost**: small blits
  that RGA3 serves today move to RGA2, which on a kernel without dma32 heaps can
  turn a working system-heap blit into "no core match" — the failure this repo
  already root-caused for the forward port in
  [`2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md`](2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md).
  It was taken knowingly, to match the vendor capability table.
- The route-B fix leaves `dma_sync_sgtable_*()` being called on a table that is no
  longer DMA-mapped. It works and the forward-port sibling has the same property,
  but it is formally outside the DMA API contract; `CONFIG_DMA_API_DEBUG` would
  flag it. That option is off in this tree.
- **Refuted ≠ absent.** Four claims were dropped for unproven reachability, not
  proven safety.

## Why it matters / follow-up

The rewrite's §6 validation row remains a code/ABI-ledger record, not proof from a
booted kernel — these fixes do not change that, they change what a first booted run
should be looking for. Concrete next actions, in order:

1. **Run the KUnit suite at all.** Build `P4052`-style debug debs from the new tip
   and capture a booted 232-case report. Settle whether the suite has ever executed;
   the three repaired fixtures are the discriminating test.
2. **Re-run the packaged build gate from the committed tip** (`bash
   kernel-drivers/tests/rewrite-build-gate.sh all`) so the recorded green run is
   against `git archive`, not the working-tree copy used here.
3. **Differential-compare the emission fixes** against the forward-port oracle for:
   cropped compact NV15/NV20 on RGA2 (forced `core = BIT(2)`), compact 10-bit RGA3
   destination offsets at `x_offset` 64 and 4, and `imcolorkey` in both normal and
   inverted modes on RGA2.
4. **Re-baseline the small-blit core-match behaviour** with
   `kernel-drivers/tests/rga-core-match-test` at dim 64 and confirm rewrite and
   forward-port now agree.
5. The recovery, abort-sweep, and hardirq fixes are exactly the paths
   `rewrite-recovery-stress.sh` with `RECOVERY_CASES='unbind reset'` exercises under
   KASAN + `DEBUG_LIST` + `PROVE_LOCKING`. That run is the one that can show the
   pre-fix UAFs and must be clean after.

Update [`kernel-drivers/docs/rewrite-drivers.md`](../kernel-drivers/docs/rewrite-drivers.md)
§6 pins when the next validated build lands; the pins there still name
`185d4dcec110` / `d5165caeddb7`.
