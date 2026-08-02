# Rewrite-driver review round 3: 11 defects, 8 of them holes in fixes already recorded as closed

> Scope: kernel-drivers — `mpp-rewrite` + `rga-rewrite` clean-room drivers
> Source: `~/Code/rock-5b/kernel/linux-6.18-rkvenc` @ `b885391e2af8a` (branch
> `rk3588-rewrite-6.18`); `drivers/video/rockchip/{mpp-rewrite/mpp_rewrite.c,
> rga-rewrite/rga_rewrite.c}` are byte-identical to `rk3588-rewrite-mainline` @
> `d418589299310`, so every fix below mirrors to both trees.
> Oracles: the in-tree `ABI.rst` ledgers, BSP
> `~/Code/rock-5b/kernel/rockchip-kernel/drivers/video/rockchip/{rga3,rga2,mpp}/`,
> `~/Code/rock-5b/rockchip-userspace/librga-fork` (`core/NormalRga.cpp`),
> `Documentation/dev-tools/kunit/style.rst` in the same kernel tree.
> Date: 2026-08-01
> Trust: CODE-INSPECTED, FIX-COMPILE-VERIFIED, PARTIAL — every defect below was
> re-verified in source by the reviewer after the fan-out reported it. All
> eleven defects and four of the five structural items are now fixed on both
> tips (see § Fix status); no booted kernel and no hardware run, so the three
> needs-hardware items remain open.

> **Fixed 2026-08-01.** The series landed as `rk3588-rewrite-6.18`
> `b885391e2af8a..187b0d647e6ce` (14 commits), mirrored byte-identically to
> `rk3588-rewrite-mainline@45554b495e66e`. The warning-fatal clean-archive
> `normal` build gate passes on both tips, the source audit reports 308 signals
> with 0 new and 0 absent on both, and the case manifest is 90 MPP + 152 RGA.
> Two things changed from the plans below during implementation, both recorded
> in § Fix status: §3's encoder register fix rested on a wrong assumption about
> INT_CLR, and §11's errno change was dropped as an undeclared ABI change.
> §14 (the test-file split) is **not** done.

## Result

A ten-slice review of all ~26,100 production lines of both drivers (MPP 1–3804
and 9304–17488; RGA 1–8774 and 20059–25436) produced **11 confirmed defects and
5 structural problems**. Nothing here is a re-report of the 2026-07-24 or
2026-07-29 rounds.

The finding that matters more than any individual defect is the **shape** of
what the round caught. Eight of the eleven are not new code going wrong — they
are *previously recorded, previously closed fixes that were applied to one site
and not to its structural twin*:

| Recorded fix | Where it was applied | Where it was not |
|---|---|---|
| [round 2](2026-07-29-rewrite-driver-review-round-2.md) legacy rot90/270 wire geometry | validators, `rk_rga3_emit_alpha_bitblt()` | `rk_rga3_emit_overlap_bitblt()` (§1) |
| [round 2](2026-07-29-rewrite-driver-review-round-2.md) shared-IRQ unpowered MMIO (`regs_live_count`) | `rga_rewrite.c` (4 refs) | `mpp_rewrite.c` (**0 refs**) (§3) |
| [round 2](2026-07-29-rewrite-driver-review-round-2.md) core-removal import invalidation | written, then orphaned by the [multi-SG rework](2026-07-31-rga-rewrite-multisg-dmabuf-cma-einval.md) | nothing sets the flag any more (§4) |
| [round 2](2026-07-29-rewrite-driver-review-round-2.md) RGA timeout done-salvage | IRQ-thread completion path | recovery path drops the multi-task loop (§6) |
| [DCHS producer-retirement lock](2026-07-30-rewrite-rkvenc-dchs-producer-retirement-race.md) | 5 of 6 completion paths | `rk_mpp_hw_abort_active_recovery_locked()` (§9) |
| explicit-IOVA post-offset revalidation | `rk_mpp_job_translate_reg_image()` | `rk_mpp_job_apply_rcb_info()` runs after it (§2) |
| `kvcalloc` for user-sized page arrays | `rk_rga_import_userptr()` `pages[]` | `rk_rga_userptr_build_extents()` `extents[]` (§8) |
| watchdog restore for a non-owned job | the restore exists and is correct | it re-arms a *fresh* full window (§5) |

The corollary is a process finding: **the findings ledger currently reads as
more complete than the tree is.** A fix recorded as landed is not the same as a
fix applied to every site of its class, and nothing in the current gate checks
the difference. §16 proposes the cheap mechanical guard.

The drivers are otherwise in good shape, and this should be said plainly because
a critique that only lists problems is not calibrated: `checkpatch -f` reports
**0 errors and 9 warnings across MPP's 17,488 lines, 0 errors and 2 warnings
across RGA's 25,436**; there are no module params, no `EXPORT_SYMBOL`, no sysfs;
production duplication is genuinely low (RGA2/RGA3 validators share ~20% of
lines, nearly all structural) and the RGA2↔RGA3 copy-paste cluster a reviewer
expected to find does not exist; the lock hierarchy reconstructed from code —
not from comments — is **acyclic**, with four candidate inversions chased and
all four closed. Most of what ten reviewers were sent hunting for is genuinely
already handled. §15 records the ruled-out list, which is long on purpose.

## Method

Ten parallel reviewers, each given a named line-range slice, an explicit hostile
threat model (unprivileged opener of a chardev that converts user geometry into
bus-master DMA), the [2026-07-24](2026-07-24-rewrite-driver-multi-agent-defect-audit.md)
and [2026-07-29](2026-07-29-rewrite-driver-review-round-2.md) audit findings plus
the eleven `2026-07-30`…`2026-08-01` rewrite findings as the do-not-re-report set,
and a hard rule that a
claim without the ioctl sequence and field values that reach it gets dropped.
Slices: MPP uAPI/parsing, MPP register staging + address translation, MPP job
lifecycle/refcounting, MPP power/reset/CCU/IOMMU recovery, MPP IRQ/AV1/probe/PM,
RGA layout+stride arithmetic, RGA import/dma-buf/userptr/IOVA, RGA
job/fence/IRQ/recovery, RGA emission+ioctl, and one architecture/upstreamability/
test-quality slice. §1 and §7 were each found independently by two reviewers
working different slices; §3 and §5 likewise. Every finding retained below was
then re-read in source by the reviewer before being written here.

---

## The defects

### 1. `rk_rga3_emit_overlap_bitblt()` never un-swaps the 90°/270° destination window

- **Severity**: high — out-of-bounds DMA read *and* write
- **Anchor**: `rga_rewrite.c` `rk_rga3_emit_overlap_bitblt()` (~:22564), WIN0 call
  at ~:22570. Contrast the sibling `rk_rga3_emit_alpha_bitblt()` (~:22499), which
  builds a `rotated_bg` and swaps. Reachability gate `profile->overlap_copy`
  (~:20737). The canvas-orientation swap the validator applies: ~:20640.
  `rk_rga3_emit_read_window()`'s rotate handling: ~:20813-20820.

librga submits 90°/270° with the destination window **pre-swapped** —
`dstActW = rect.height` (`NormalRga.cpp:1052-1054`) — while `vir_w`/`vir_h` stay
in canvas orientation. The 2026-07-29 round fixed the *validators* to normalize
this, and explicitly ruled the emitters correct on the grounds that they re-swap
internally. `rk_rga3_emit_read_window()` does re-swap — but only when
`rotate_flags & RK_RGA3_ROT_BIT_ROT_90` is set *for that window*:

```c
	if (rotate_flags & RK_RGA3_ROT_BIT_ROT_90) {
		hw_src_w = img->act_h;
		hw_src_h = img->act_w;
		if (rotate_dst_size) {
			hw_dst_w = dst_h;
			hw_dst_h = dst_w;
		}
	}
```

The overlap emitter passes WIN0 `&task->dst` raw with **`rotate_flags = 0`** and
`task->dst.act_w, task->dst.act_h` unswapped, so the swap is skipped entirely and
`rotate_dst_size = true` has no effect. WIN1 *is* correct (it carries
`profile->rotate_flags`), so the two layers disagree by a transpose.

Validation bounded `dst.act_h` against **`vir_w`**; WIN0 then walks
`y_offset + act_h` rows down a surface only `vir_h` rows tall. Worked case:
`dst.vir_w = 8128, vir_h = 32, act_w = 16, act_h = 8128, y_offset = 1`,
`rd_mode = FBC` — validation passes (`0 + 8128 ≤ 8128`, `1 + 16 ≤ 32`), and the
FBC header walk at the driver's own programmed stride
(`WIN0_VIR_STRIDE = ALIGN(vir_w,16)>>2`) reaches `508 × 8128 = 4,129,024` bytes
against an import of `1,056,640` — ~3 MB past the mapping. The FBC *encoder*
writes the same header array (`wr_mode == 1`), so this is a write overrun too.
Per BSP `rga3_reg_info.c:1409` ("the output w/h are bound to the dst_act_w/h of
win0") there is no separate WR size register to contradict it.

Reachable: `overlap_copy` requires `!alpha_blend && (src.yrgb == dst.yrgb ||
(dst_mode == 1 && (x_offset || y_offset)))`. The in-place sub-case cannot reach
ROT_90 (`rk_rga_in_place_bitblt_allowed()` demands mirror-only there), so the
FBC-destination-with-offset route is the one that reaches it — and RGA2 rejects
the task (`dst.rd_mode` non-raster, ~:20469), so `rk_rga_task_hw_type_mask()`
yields RGA3-only and the job is *guaranteed* onto the buggy emitter. Git confirms
the ordering: `a08534870bd10` (which added the `rotated_bg` un-swap) is an
ancestor of `7bbd0b5617027` (which added the overlap emitter) — the newer
emitter copied the layout without the fixup. `grep overlap_copy` over the KUnit
region returns **nothing**; the path has zero test coverage.

Guards checked and ruled out: `rk_rga3_check_scale()` (~:7771) documents that it
assumes WIN0 is always 1:1 and never inspects its absolute geometry;
`rk_rga3_pack_pair()` only enforces the 13-bit register field, which 8144
satisfies; `rk_rga3_validate_raster_strides()` returns 0 immediately for FBC;
nothing anywhere rejects ROT_90 with an FBC destination.

**Fix plan.** Mirror the sibling exactly — this is a five-line change with a
known-good model in the same file:

```c
static int rk_rga3_emit_overlap_bitblt(...)
{
	struct rga_img_info_t rotated_dst;
	const struct rga_img_info_t *bg = &task->dst;
	u32 bg_dst_w = task->dst.act_w;
	u32 bg_dst_h = task->dst.act_h;
	...
	if (profile->rotate_flags & RK_RGA3_ROT_BIT_ROT_90) {
		rotated_dst = task->dst;
		rotated_dst.act_w = task->dst.act_h;
		rotated_dst.act_h = task->dst.act_w;
		bg = &rotated_dst;
		bg_dst_w = task->dst.act_h;
		bg_dst_h = task->dst.act_w;
	}
	ret = rk_rga3_emit_read_window(job, bg, ..., 0, bg_dst_w, bg_dst_h,
				       RK_RGA3_WIN0_RD_CTRL_OFFSET, true,
				       task->yuv2rgb_mode, true);
```

Note the WIN1 call must keep passing `task->dst.act_w/act_h` as its `dst_w`/
`dst_h` — those are the *scaling target*, and WIN1 carries `rotate_flags` so
`rk_rga3_emit_read_window()` swaps them itself. Only WIN0's background geometry
is wrong.

Prefer this over factoring the swap into `rk_rga3_emit_read_window()`: the two
emitters pass different things for a reason (WIN0 is a background read at 1:1,
WIN1 is the scaled source), and a shared helper would have to grow a mode flag
that reintroduces the same choice at each call site.

**Tests to add** (this is where the round-2 fix's real gap was — the emitters had
no coverage): a KUnit case building a 90° FBC-destination overlap task in faithful
librga wire form and pinning `WIN0_ACT_SIZE`, `WIN0_SRC_SIZE`, and `WIN0_DST_SIZE`
to canvas-oriented values; plus the 270° mirror. Register these as real cases, not
by the pattern in §13.

---

### 2. `rk_mpp_job_apply_rcb_info()` runs after the address revalidation it defeats

- **Severity**: high — post-validation write of a hardware address register at a
  user-chosen index
- **Anchor**: `mpp_rewrite.c` `rk_mpp_execute_jobs()` ordering (~:15764 translate,
  ~:15777 apply RCB, ~:15783 submit); the revalidation and its comment inside
  `rk_mpp_job_translate_reg_image()` (~:10391-10404);
  `rk_mpp_job_apply_rcb_info()` (~:9885-9924); `rk_mpp_job_store_rcb_info()`
  (~:9499) which copies `{u32 index; u32 size;}` pairs from userspace with **no**
  validation of `index`.

The driver deliberately added a post-offset revalidation pass:

```c
	/*
	 * Offsets are applied after fd translation for BSP ABI compatibility.
	 * Revalidate the final address-table values so an optional zero fd plus
	 * a later offset cannot become an unretained literal DMA address.
	 */
	if (rk_mpp_job_has_reg_image(job)) {
		ret = rk_mpp_job_validate_explicit_iovas(job);
```

`rk_mpp_job_apply_rcb_info()` then runs **after** the whole of
`translate_reg_image()`, and writes `image->regs[desc->index] =
lower_32_bits(rcb_iova)`. Every other post-validation writer uses a fixed,
kernel-chosen index — `prepare_ccu_regs` (13/28/32), `dchs_patch` (193),
`rkvenc_fixup_slice_flush` (216). This is the only one whose index comes from
userspace, and `desc->index` is bounded only by `>= RK_MPP_MAX_REG_IMAGE_BYTES/4`
(32768), then by the client region size two calls deeper. For RKVDEC that is
`0x5a0/4 = 360` — i.e. *every* word of the register file.

Two consequences. (a) `RK_MPP_RKVDEC_REG_FMT` is word 9 and selects which
address table was validated; rewriting it after validation makes the hardware
run a different codec's table than the one checked, and the tables genuinely
differ (VP9 contains words 160/162, H265 does not — verified against BSP
`trans_tbl_vp9d`/`trans_tbl_h265d`), so a raw attacker literal reaches
`rk_mpp_job_write_regs()`. (b) `desc->index` can name a validated frame-buffer
base, replacing its checked IOVA with `hw->rcb_iova + rcb_offset` where
`rcb_offset` is the running sum of user-supplied `desc->size` — a user-chosen
offset into the 1 MiB `dmam_alloc_coherent()` RCB scratch.

The BSP has the same unvalidated `task->reg[reg_idx] = dec->rcb_iova +
rcb_offset` (`mpp_rkvdec2.c:340-366`), so (b) is a reproduced BSP hazard. (a) is
rewrite-specific: it silently voids a mitigation this driver added and documents
in a comment five lines away.

**Fix plan** — three changes, all small, do all three:

1. **Reorder.** Move `rk_mpp_job_apply_rcb_info()` to *inside*
   `rk_mpp_job_translate_reg_image()`, immediately after
   `rk_mpp_job_apply_reg_offsets()` and **before** the
   `rk_mpp_job_validate_explicit_iovas()` revalidation. That makes the
   revalidation authoritative over every writer by construction rather than by
   inspection, which is the property the comment claims. `execute_jobs` then
   drops its separate call; keep the `RK_MPP_DEBUG_RCB_FAIL` debug-event record
   by threading the failure class out, or by recording it at the new site.
2. **Validate the index at store time.** In `rk_mpp_job_store_rcb_info()`, reject
   any `desc->index` that names a register in the client's *address* table —
   RCB scratch pointers are not frame-buffer bases, and no legitimate caller
   aims one at word 9 or at a translated address word. Reuse the existing
   per-client `rk_mpp_reg_layout_for_type()` table walk that
   `validate_explicit_table()` already has.
3. **Bound against the right layout.** The `continue` at ~:9906 uses the generic
   32768-word ceiling, but the effective bound is the client region size, enforced
   deeper by `rk_mpp_job_ensure_region_bytes()` which returns `-ENOMEM` rather
   than skipping. Because `session->rcb_descs` is sticky (~:9523) and re-seeded
   into every new job (~:10691), one out-of-range descriptor **permanently
   denies service to that session**. The BSP `continue`s here
   (`mpp_rkvdec2.c:352-355`). Bound the `continue` against the client region word
   count so a benign out-of-range entry is skipped, matching the BSP.

**Test to add**: a KUnit case staging `SET_RCB_INFO{index=9}` plus a translated
address table, asserting the job is rejected (after fix 2) and that word 9 is
unchanged after `translate_reg_image()` returns (after fix 1).

---

### 3. The MPP interrupt handlers have no power gate; RGA's `regs_live_count` fix was never carried across

- **Severity**: high (design gap); the individual trigger is **needs-hardware**
- **Anchor**: `grep -c regs_live` → **`rga_rewrite.c`: 4, `mpp_rewrite.c`: 0**.
  `rk_mpp_hw_irq()` (~:15269) tests only `recovery_failed`.
  `rk_mpp_hw_assert_powered()` exists (~:1669) and is called at eight sites —
  none in a handler. RGA's model: counter at `rga_rewrite.c:1349`, incremented
  under `job_lock` in `rk_rga_hw_power_on_internal()` (~:1842), decremented
  under `job_lock` *before* `clk_bulk_disable_unprepare()` in
  `rk_rga_hw_power_off()` (~:1867), checked at the top of the hard handler
  (~:23156).

The [2026-07-29 round](2026-07-29-rewrite-driver-review-round-2.md) gave RGA exactly this, with a comment naming the hazard:
"A peer on the shared level line (the RGA3 IOMMU) can refire after this core's
clocks are gated… reading its registers would stall the bus." MPP has the same
exposure and none of the mechanism. Two reviewers reached it independently, via
two different delivery windows:

- **`IRQF_ONESHOT` unmask.** `rk_mpp_rkvdec2_thread()` calls
  `rk_mpp_hw_power_off()` (~:14528) while still inside the threaded handler; the
  thread returns, genirq unmasks, and any re-asserted interrupt re-enters
  `rk_mpp_rkvdec2_irq()` → `readl_relaxed(hw->regs[0] + INT_STA_BASE)` on a
  clock-gated register file. The [2026-08-01 self-reset finding](2026-08-01-rkvdec-self-reset-and-iommu-restore-gaps.md) records that this
  hardware self-resets on `err_mask` bits 4/5/7 and that `sw_softreset_rdy` is a
  *post*-reset status — a second assertion after the ack is what the TRM predicts.
  The rkvenc2 variant is worse: its top half does `writel(status, INT_CLR)` — a
  write-1-clear of a *stale snapshot* (~:14099) — where rkvdec2 and AV1 both do
  `writel(0, ...)` and zero the whole status register. A slice-done bit set
  between the read and the clear survives, keeping the level line asserted with
  no reset pulse to clear it (`INT_DONE` is not in `RESET_MASK`).
- **`enable_irq()` replay.** Every recovery path is disable → reset → power_off →
  **enable**: `rk_mpp_hw_recover_active` (~:12787/:12790), `abort_active`
  (~:12866/:12869), `abort_job` (~:12254/:12273),
  `abort_active_recovery_locked` (~:12910/:12914), the rkvenc2 and AV1 submit
  unwinds (~:13938/:13940, ~:15116/:15119). `__enable_irq()` calls
  `irq_startup(desc, IRQ_RESEND, …)`, so an interrupt latched while the line was
  lazily disabled is software-replayed *after* the power-off.

Either way the outcome is bad in both branches: a garbage read wakes the thread
for a job that no longer exists, and a zero read returns `IRQ_NONE` on a still-
asserted level line until `note_interrupt()` hits 100,000 unhandled and prints
`irq NN: nobody cared`, killing that core's interrupt for the boot.

The driver already implements the correct discipline for the *auxiliary* IRQ —
`rk_mpp_hw_deactivate_aux_irqs()` (~:15238) masks the level source while clocks
are alive, publishes `aux_irqs_active = false`, and `synchronize_irq()`s, and
`rk_mpp_hw_aux_irq()` re-checks the flag (~:15260). The primary IRQ has no
equivalent.

**Fix plan** — port the RGA mechanism rather than inventing a second one:

1. Add `unsigned int regs_live_count` to `struct rk_mpp_hw`, guarded by the
   existing `hw->lock` spinlock (which the top halves already take).
   `atomic_t power_count` is *not* usable for this: the whole point is that the
   decrement and the clock gating must be atomic with respect to a handler
   holding the lock, and an atomic counter gives no such barrier.
2. `rk_mpp_hw_power_on()`: increment under `hw->lock` after
   `clk_bulk_prepare_enable()` succeeds.
3. `rk_mpp_hw_power_off()`: decrement under `hw->lock` **before**
   `clk_bulk_disable_unprepare()`, exactly as `rk_rga_hw_power_off()` does, so
   taking the lock proves no handler is mid-read.
4. `rk_mpp_hw_irq()`: return `IRQ_NONE` when the count is zero, before
   dispatching to `hw->match->ops->irq`. One gate at the dispatcher covers all
   three backends and is the right altitude — per-path fixes would have to be
   repeated at every enable site.
5. Independently, fix the rkvenc2 top half to clear the full status register
   (`writel(0, INT_CLR)`) rather than write-1-clearing a stale snapshot, so a
   late bit cannot hold the line asserted. Check this against the BSP first —
   BSP registers with `IRQF_SHARED` and no `IRQF_ONESHOT`, so it services the
   late assertion while still powered and the asymmetry never bites it; confirm
   the register is genuinely W1C-with-zero-harmless before changing it.

Steps 1–4 are mechanical and should land as one commit. Step 5 is a separate
commit because it needs the register-semantics check.

**Verification**: the counter to watch on a board is
`/sys/kernel/debug/rk_mpp_rewrite/state` `spurious_irq_count` under a slice-split
encode loop, plus `dmesg | grep "nobody cared"` on the rkvenc SPIs.

---

### 4. RGA's `mapping_invalidated` net is dead code, and three KUnit cases assert a state production cannot produce

- **Severity**: medium — lost defence-in-depth plus **false green test coverage**
- **Anchor**: the only production writer is `rga_rewrite.c:2606`, inside the
  `RK_RGA_IMPORT_DMABUF` branch of `rk_rga_import_detach_map_locked()`. That
  function returns at ~:2588 when `import->map_hw` is NULL. The **only**
  production assignment to `map_hw` is ~:24409, in `rk_rga_import_userptr()`.
  (The writers at ~:11989/:12001 are inside the KUnit region.) Dead readers:
  ~:3259, ~:3860, ~:4752, ~:4844, ~:6194. The test asserting it: ~:14768.

The [2026-07-31 multi-SG rework](2026-07-31-rga-rewrite-multisg-dmabuf-cma-einval.md) removed the persistent DMA-BUF attachment;
`rk_rga_import_dmabuf_object()` now sets only `dmabuf`, `size`, `fd` and a
placeholder `iova`, never `map_hw`. So for every DMA-BUF import the entire
invalidation block is unreachable, and the USERPTR branch never sets the flag.
Consequences: `rk_rga_pending_job_has_invalidated_import()` always returns false,
so `rk_rga_abort_invalidated_pending_acquire_jobs()` at ~:25152 is a no-op — the
round-2 core-removal safety net is gone; and the KUnit case hand-constructs a
DMA-BUF import with `map_hw` set, a state production can no longer reach, so it
is green while covering nothing.

Traced whether removing the net opens a live hole: `rk_rga_hw_remove()` still
aborts by core mask (~:25147) and by hw (~:25150) before detaching, and a
surviving pending job re-maps on its new core through `rk_rga_job_map_import()`
because `map_hw` is NULL. So this is not currently exploitable.

**Fix plan** — decide, then make the code say what was decided. Two coherent
options; recommend (a):

- **(a) Delete it.** If per-job mapping genuinely subsumes the net, remove the
  `mapping_invalidated` field, the five dead readers,
  `rk_rga_pending_job_has_invalidated_import()`,
  `rk_rga_abort_invalidated_pending_acquire_jobs()` and its call site, and the
  three KUnit cases. Record in `ABI.rst` and in the round-2 finding that the net
  was retired by the multi-SG rework and why it is no longer needed. This is the
  honest outcome if the analysis above holds.
- **(b) Revive it.** If the userptr side still needs it (a userptr import's
  persistent mapping *is* torn down on core removal, §5 of the ruled-out list
  notwithstanding), set the flag in the USERPTR branch too and keep the readers.
  Then the KUnit fixtures must be rebuilt around a userptr import, since the
  DMA-BUF shape they use is unreachable.

Do not leave it as-is. A dead flag with five live-looking readers and three green
tests is worse than either resolution, because the next reader will trust it.

**Guard against recurrence**: this is the class the `rewrite-kunit-source-audit`
should catch. A signal for "production writers of a field referenced by KUnit
assertions" would have flagged it the day the rework landed.

---

### 5. Any session can indefinitely postpone another session's hardware watchdog

- **Severity**: medium — unprivileged denial of service against a shared core
- **Anchor**: `rk_mpp_hw_abort_job()` — `rk_mpp_hw_cancel_timeout_sync(hw)` at
  ~:12191 is unconditional and runs **before** `active_owned` is computed at
  ~:12198; the restore is at ~:12209. `rk_mpp_hw_schedule_timeout()` (~:12297)
  ends with `mod_delayed_work(system_wq, &hw->timeout_work,
  msecs_to_jiffies(RK_MPP_WORK_TIMEOUT_MS))` — 500 ms, always fresh. Driven from
  `rk_mpp_session_abort_jobs()` (~:15314) and thus from `MPP_CMD_RESET_SESSION`
  and from `close()`.

The cancel must precede `run_lock` (the timeout worker takes `run_lock`), so it
necessarily clears the watchdog slot for whatever job owns the core. The restore
exists and the comment correctly explains why. What the restore does not do is
carry the *remaining* deadline — `hw->timeout_job`/`timeout_generation` hold no
absolute expiry anywhere. So each abort pushes the victim's deadline out by a
full 500 ms.

Attack: session A pins itself to a specific core (one `MPP_CMD_TRANS_FD_TO_IOVA`
sets `session->explicit_map_dev`, after which `rk_mpp_hw_get_for_map()` matches
`hw->dev == dev` deterministically — no load-balancing luck needed), submits a
job that never completes, and loops `MPP_CMD_RESET_SESSION` above 2 Hz. The
wedged core's watchdog never fires, `rk_mpp_hw_recover_active()` never runs, and
every session's queued jobs for that core starve, since
`rk_mpp_scheduler_take_job()` requires `rk_mpp_hw_is_idle()`.

**Fix plan.** Give the watchdog an absolute deadline:

1. Add `unsigned long timeout_deadline` (jiffies) to `struct rk_mpp_hw`, written
   under `hw->lock` alongside `timeout_job`/`timeout_generation`.
2. Set it to `jiffies + msecs_to_jiffies(RK_MPP_WORK_TIMEOUT_MS)` only when
   `schedule_timeout()` is arming a *new* job (the `job != hw->timeout_job`
   branch that already exists).
3. When re-arming an existing job, queue for `timeout_deadline - jiffies`,
   clamped to a small floor (say 1 jiffy) so a deadline already in the past fires
   promptly rather than wrapping.

That keeps the round-2 property the comment defends (the victim never silently
loses its watchdog) while removing the postponement. It is ~10 lines and entirely
inside `rk_mpp_hw_schedule_timeout()` plus one struct field.

**Test to add**: a KUnit case arming a watchdog, advancing `jiffies` partway,
calling the abort-restore path, and asserting the re-queued delay is the
*remainder* and not `RK_MPP_WORK_TIMEOUT_MS`.

---

### 6. The RGA timeout done-salvage completes a multi-task request as success after running one task

- **Severity**: medium — silent wrong result to userspace
- **Anchor**: `rk_rga_hw_recover_active()` `done` branch ~:23326-23343, then
  `rk_rga_job_complete_queued(job, result)` ~:23354. Contrast the IRQ thread at
  ~:23212, which calls `rk_rga_job_advance_task()` and requeues.
  `rk_rga_job_advance_task()` itself: ~:6401.

The round-2 salvage fix is correct as far as it goes: when the blit finished
while the watchdog held the IRQ line masked, report what the hardware did rather
than `-EBUSY`. But it computes `result = rk_rga_irq_completion_result(...)` — **0**
on a clean DONE — and hands it straight to `rk_rga_job_complete_queued()` without
ever consulting `job->current_task` / `job->task_count`. `grep` confirms ~:6408
inside `rk_rga_job_advance_task()` is the only increment of `current_task`, and
it is reached only from `rk_rga_irq_thread`.

So `rk_rga_job_complete()` sets `job->result = 0`, `smp_store_release(&job->done,
true)` and `rk_rga_fence_signal(job->release_fence, 0)` with no
`dma_fence_set_error()`. Userspace gets ioctl success (sync) or a cleanly
signalled out-fence (async) for a request whose tasks *i+1…N-1* never ran, over
a destination holding a partially composed frame.

Trigger: any `task_num >= 2` request where the blit completes inside the window
`rk_rga_hw_recover_active()` opens itself — `rk_rga_hw_disable_irq()` at ~:23290
masks the line, so a DONE raised after that mask but before the status readback at
~:23313 leaves `job->irq_seen` false and the recover predicate at ~:23303 holding.

**Fix plan.** Mirror the IRQ-thread structure inside the recovery path. The
sequencing constraint is that the recovery reset must still run — the salvage
comment says so explicitly ("the recovery reset below still clears the latch") —
so the requeue has to happen *after* the reset and power-off, exactly where the
IRQ thread does it:

```c
	rk_rga_job_note_hw_done(job);
	reset_ret = rk_rga_hw_reset_for_recovery(hw);
	rk_rga_job_release_mappings_powered(job, hw);
	rk_rga_hw_power_off(hw);

	if (rk_rga_job_advance_task(job, result)) {
		dispatch_session = READ_ONCE(job->session);
		if (dispatch_session &&
		    rk_rga_session_begin_job_dispatch(dispatch_session)) {
			rk_rga_job_release_hw(job);
			requeued = true;
		} else {
			result = -EFAULT;
		}
	}
	if (!requeued)
		rk_rga_job_complete_queued(job, result);
```

with the same `requeued` handling after `mutex_unlock(&hw->run_lock)` that the
IRQ thread has. Factor the shared tail into a helper called from both sites
rather than copying it — copying it is how this defect happened in the first
place, and a third copy is a third chance to drift.

**Test to add**: a two-task job, force the recovery path with a latched DONE, and
assert the job requeues at `current_task == 1` rather than completing.

---

### 7. RGA2 quantize bypasses color-key validation entirely

- **Severity**: medium — unvalidated register program of a bus-mastering engine
- **Anchor**: the `else if` validator chain in `rk_rga2_validate_bitblt()`
  ~:20432-20460 (quantize at ~:20436 precedes color-key at ~:20440);
  `profile->color_key = uses_color_key;` assigned unconditionally at ~:20491;
  `rk_rga2_validate_quantize()` ~:8533-8569.

`rk_rga2_validate_quantize()` excludes `PD_mode`, `global_alpha_en`, `rop_code`,
`alpha_rop_mode`, format mismatch, non-raster `rd_mode`, `act` mismatch, rotate,
`interp`, `yuv2rgb_mode`, `full_csc`, mosaic, OSD and gauss — but **not**
`color_key_min`/`color_key_max`, and not `src_trans_mode`. Its siblings do carry
the exclusion: `rk_rga2_validate_alpha_bitmap()` rejects
`rop_code || color_key_min || color_key_max` (~:8595).

So a task with `alpha_rop_flag = BIT(8)` (quantize) and a non-zero color key
takes the quantize arm, never runs `rk_rga2_validate_color_key()` — and with it
never enforces the constraints that make the color-key register program legal
(`alpha_rop_flag == ENABLE|PD_ENABLE|CAL_MODE|REAL_COLOR`, `alpha_rop_mode ==
0x11`, `PD_mode == ALPHA_BLEND_SRC`, and crucially `src_trans_mode ∈ {0x1e,
0x1f}`) — yet `profile->color_key` is still set. The emitter re-runs the same
validator, gets the same accepting answer, and writes `ALPHA_CTRL1` (src factor
ONE / dst factor ZERO) with blend-enable clear, plus `SRC_TRANS_ENABLE`/
`SRC_TRANS_MODE` from an entirely arbitrary `src_trans_mode`, plus the quantize
registers. RGA3 rejects the task (`alpha_rop_flag & BIT(8)`, ~:20600), so it is
guaranteed onto RGA2.

Every other pairing in that chain is closed — `alpha_bitmap+quantize`,
`gauss+quantize`, `osd+quantize`, `rop+quantize` are rejected by quantize's own
exclusions; `osd+color_key` and `gauss+color_key` by color-key's. This is the one
hole, created by chain precedence plus the unconditional assignment.

Bounded: every field involved is `FIELD_PREP`-masked into mode/blend bits, so no
address or size corruption was demonstrable. Realistic outcomes are
`RK_RGA2_INT_CONFIG_ERR`, wrong pixels, or an engine stall that burns the
watchdog — which, given §5, is not free.

**Fix plan.** Add the missing exclusion to `rk_rga2_validate_quantize()`:

```c
	if (task->color_key_min || task->color_key_max)
		return -EOPNOTSUPP;
```

That is the minimal, in-house-style fix and matches the sibling validators.
Then make the chain structurally safe rather than relying on every future
validator remembering: change `profile->color_key = uses_color_key;` to
`profile->color_key = uses_color_key && validated_color_key;` where
`validated_color_key` is set only in the arm that actually ran
`rk_rga2_validate_color_key()`. The `else if` chain is fine as a dispatch
mechanism; the bug is that a profile bit is derived from the *request* rather
than from which validator approved it. Audit the other `profile->*` assignments
around ~:20491 for the same shape while there.

**Test to add**: a KUnit case with `alpha_rop_flag = BIT(8)` and
`color_key_min = 1`, asserting `-EOPNOTSUPP`.

---

### 8. `kcalloc()` for a user-sized per-page array warns above `MAX_PAGE_ORDER`

- **Severity**: medium — unprivileged kernel taint; DoS under `panic_on_warn`
- **Anchor**: `rk_rga_userptr_build_extents()` ~:3664:
  `extents = kcalloc(import->page_count, sizeof(*extents), GFP_KERNEL);`
  Contrast `rk_rga_import_userptr()` ~:24348-24355.

The sibling allocation, for an array **half the size**, carries this comment:

> The page count comes from an unbounded u32 buffer size and is sized before
> anything is pinned, so a bogus size costs the caller nothing and must not turn
> into a huge contiguous kernel allocation: a 4 GiB request alone asks for an
> 8 MiB array, past `MAX_PAGE_ORDER`, which would warn rather than fail cleanly.
> Let it fall back to vmalloc.

`struct rk_rga_userptr_extent` is 16 bytes on arm64 (`struct page *` + two `u32`)
versus 8 for `struct page *`, so `build_extents` hits the ceiling at *half* the
buffer size the commented one does. A ~1 GiB userptr import gives
`262145 × 16 = 4,194,320` bytes → order 11, against this build's
`CONFIG_ARCH_FORCE_MAX_ORDER=10`, so `__alloc_frozen_pages_noprof()` fires
`WARN_ON_ONCE_GFP(order > MAX_PAGE_ORDER, gfp)` — `GFP_KERNEL` carries no
`__GFP_NOWARN`. `memory_parm.size` is `__u32`, so the ceiling is 16 MiB → order
12. The pin must succeed first, so the caller needs ~1 GiB of populated writable
memory; that is the only precondition beyond opening `/dev/rga`.

**Fix plan.** One-line change plus its matching free:

- `rga_rewrite.c:3664`: `kcalloc` → `kvcalloc`.
- `rga_rewrite.c:2653`: `kfree(import->userptr_extents)` → `kvfree(...)`.

Then sweep for the class rather than fixing the instance: `grep -n
'k[zm]*alloc\|kcalloc\|kmalloc_array'` over both drivers and check every hit
whose count derives from a user-supplied length. This is the third time a
user-sized allocation has needed the `kv*` treatment; a one-time audit is
cheaper than a fourth finding.

---

### 9. `rk_mpp_hw_abort_active_recovery_locked()` completes an RKVENC job without the DCHS lifecycle lock

- **Severity**: medium — `lockdep` splat; reopens part of the 2026-07-30 race
- **Anchor**: `mpp_rewrite.c` ~:12883-12919, in particular the
  `rk_mpp_hw_stop_active()` / `rk_mpp_hw_power_off()` / `rk_mpp_job_complete()`
  sequence at ~:12904-12911. The assert it trips:
  `rk_mpp_rkvenc2_dchs_release()` ~:10335-10336. Contrast the sibling
  `rk_mpp_hw_abort_active()` ~:12856.

Every other path that completes or resets an RKVENC job takes
`rk_mpp_rkvenc2_dchs_lifecycle_lock(job)` first — `abort_job` (~:12226),
`recover_active` (~:12683), `abort_active` (~:12856), `rkvenc2_thread` (~:14160),
`rkvenc2_submit` (~:13895). This one takes it nowhere, yet performs exactly the
three operations the lock is documented (~:505-507) to serialize against a
consumer's patch-through-START window.

Two consequences: (a) `rk_mpp_rkvenc2_dchs_release()` opens with
`if (job->rkvenc_dchs_active) lockdep_assert_held(&srv->rkvenc_dchs_lifecycle_lock);`
so any `CONFIG_PROVE_LOCKING` build splats here — which matters directly, because
the current KUnit gate wants a live-lockdep boot; (b) it retires a producer core's
DCHS entry and resets/powers it off while a consumer job on the sibling core can
sit between `rk_mpp_rkvenc2_dchs_patch()` (~:10316) and its START write (~:13918),
the precise interval the [2026-07-30 finding](2026-07-30-rewrite-rkvenc-dchs-producer-retirement-race.md) closed.

Reachable on RK3588 because `rk_mpp_hw_remove()` takes
`rkvenc_ccu->ccu_recovery_lock` and calls `rk_mpp_hw_abort_ccu_dependents(ccu)`,
which loops **every** core whose `ccu_node` is that CCU — both `rkvenc0` and
`rkvenc1` set `rockchip,ccu = <&rkvenc_ccu>` in `rk3588-base.dtsi` — so the
sibling core that is *not* being removed goes through this path too. Root-only
(unbind / `rmmod`), which is what holds it at medium.

**Fix plan.** Take the lock exactly as `rk_mpp_hw_abort_active()` does:

```c
	mutex_lock(&hw->run_lock);
	job = rk_mpp_hw_take_active_job(hw, NULL);
	if (job) {
		bool dchs_locked = rk_mpp_rkvenc2_dchs_lifecycle_lock(job);

		stop_ret = rk_mpp_hw_stop_active(hw);
		...
		rk_mpp_rkvenc2_dchs_lifecycle_unlock(job, dchs_locked);
	}
```

Check the ordering against the reconstructed hierarchy before committing:
`ccu_recovery_lock → run_lock → rkvenc_dchs_lifecycle_lock` is the established
order and this respects it, but the `goto out_unlock` path must unlock the DCHS
lock too, and the existing `WARN_ON_ONCE(!restore_active_job())` branch inside
that block sets `job = NULL` — so capture the lock state before that assignment.

While in this function, fix the reference leak in the same branch: the failed-
restore path sets `job = NULL` so the trailing `rk_mpp_job_put(job)` is a no-op,
leaking the reference detached from the active slot. `rk_mpp_hw_abort_job()`
handles the identical situation correctly (~:12247-12252) with an explicit
`rk_mpp_job_get()` and conditional put — copy that. The same leak exists at
`rk_mpp_rkvdec2_drain_ccu_done_jobs()` ~:12581 (which holds **two** references
there and drops neither) and at `rk_mpp_hw_abort_active()` ~:12864. All three are
`WARN_ON_ONCE` defensive branches, so this is low-severity cleanup that belongs
in one commit with the lock fix.

---

### 10. AV1 AFBC header and payload size models disagree inside one function

- **Severity**: medium; **needs-hardware**
- **Anchor**: `mpp_rewrite.c` `rk_mpp_av1_afbc_required_span()` ~:14552-14578 vs
  the header sizing at ~:14663-14670; the only extent check at ~:14682-14691.

The payload model states the AFBC block grid is
`ALIGN(padded_width,16) × ALIGN(padded_height,16) / 256` blocks, implying a header
of `ALIGN(w,16)*ALIGN(h,16)/16`. The header term — carried verbatim from BSP
`mpp_av1dec.c:559-560` — instead uses the **unpadded** height plus a fixed 28 and
the **unaligned** width. `vir_top + vir_bottom` can reach 30 > 28, and
`padded_width` need not be 16-aligned, so the two disagree in the unsafe
direction. At `width=3840, height=2160, vir_left=1, vir_top=vir_bottom=15`:
header `ALIGN(3841*2188/16, 64) = 525,248` vs the payload model's
`3856*2192/16 = 528,352` — a 3,104-byte shortfall. `payload_base` is placed at
`binding->offset + header_size`, and `required_span = header_size + payload_size`
is the only thing compared against `dmabuf->size`.

The BSP has no extent check at all, so this is a defect in a rewrite-*added*
guard, not a BSP regression. Note the countervailing evidence: a second reviewer
independently worked the same arithmetic across both bit depths and concluded the
overlap stays inside `required_span`. The two analyses disagree, which is exactly
why this needs silicon rather than more reading.

**Fix plan.** Do **not** patch the arithmetic blind — the header layout is a
hardware property and the BSP formula is the only known-good oracle. Instead:

1. Make the two models explicit and consistent *within the function*: compute
   `header_size` from the same `padded_width`/`padded_height` the payload model
   uses, then take `max()` of that and the BSP formula for the span check. That
   is fail-safe in the direction that matters (a larger required span rejects
   more, never less) and does not change what is programmed to hardware.
2. Add a `WARN_ONCE` when the two models differ by more than a block row, so a
   board run tells us which one the hardware agrees with.
3. Close it properly once a board has run AV1 with `vir_top + vir_bottom > 28`
   under KASAN with a tightly-sized destination buffer.

---

### 11. Mixed dma-buf + userptr requests are hard-rejected, undeclared in `ABI.rst`

- **Severity**: medium — silent compatibility regression against the BSP
- **Anchor**: `rk_rga_check_alias_provenance()` ~:3778-3816, the
  `return -EOPNOTSUPP` at ~:3812; called from `rk_rga_resolve_handle_locked()`
  (~:3267) and `rk_rga_resolve_direct_img()` (~:3973, :3995, :4017).

The loop rejects any type mismatch anywhere in the accumulated `imports[]` array,
and that array is shared across **all** tasks of a request — so a request whose
task 0 is all-dma-buf and task 1 is all-userptr also fails. The vendor BSP has no
such restriction (`rga_mm_get_buffer()` handles each buffer independently), and
librga exposes both families side by side (`importbuffer_fd` /
`importbuffer_virtualaddr` / `wrapbuffer_fd`), so "V4L2 mmap source → malloc'd
destination" is an ordinary call. `grep` over `ABI.rst` for `provenance`,
`mixed`, `virtual address`, `userptr` finds nothing; `ABI.rst:304` in fact says
requests are built "from dma-buf fds or user virtual addresses". On the modern
path the `-EOPNOTSUPP` is then laundered to `-EFAULT` by
`rk_rga_request_ioctl_ret()`, so userspace cannot even tell why.

The in-code comment (~:3805-3811) shows this is a deliberate fail-closed choice
because DMA-BUF hides `struct page` from importers, and that reasoning is sound.

**Fix plan** — this one is a decision, not a patch. Ranked:

1. **Narrow the rejection to what is actually unsafe.** The hazard is *alias
   detection* across provenance domains, not coexistence. Two imports of
   different types that cannot alias (different tasks, or non-overlapping roles)
   need no cross-domain comparison. Reject only when a dma-buf and a userptr
   import are used as source and destination of the *same* task, where undetected
   aliasing would matter. That restores the common librga patterns.
2. **If (1) is too risky without hardware**, at minimum: declare the restriction
   in `ABI.rst` with the reasoning, and stop laundering the errno so userspace
   gets `-EOPNOTSUPP` and can fall back. A documented restriction is defensible;
   an undocumented one that reports `-EFAULT` is not.

Do (2) unconditionally and immediately; schedule (1) behind a librga
compatibility run.

---

## Structural problems

### 12. `MODULE_AUTHOR("OpenAI")`, with no human author anywhere

`mpp_rewrite.c:17486`, `rga_rewrite.c:25435`. Nobody can sign DCO clause (a) for
wholesale AI-generated code, and this collides directly with §13. Whatever the
eventual distribution path — even DKMS — the tree needs a named human copyright
steward who can certify origin. This is a prerequisite for any provenance
conversation, not a cleanup item.

### 13. The "clean-room" label is contradicted by the code's own comments

`rewrite-drivers.md:8-9` says the BSP `.c` files "are not used at all". The code
cites them by function and filename as its derivation source in ~30 comments —
"BSP `rga2_reg_info.c` derives `alpha_zero_key` from…" (~:22095), "BSP contract
(`rkvdec2_soft_ccu_enqueue`)" (~:11219), "BSP `rkvenc2_check_split_task()` FIXUP"
(~:10123), "BSP `rga_hw_config.c` `rga3_data`" (~:7754). 12 BSP mentions in MPP,
18 in RGA. `grep -cw TRM` returns **0 in both files**, so there is no independent-
derivation trail to point a challenger at. MPP's fd-translation tables are
element-for-element identical to the vendor's (`rk_mpp_rkvdec_h264d_regs[]`
~:1471 ≡ `trans_tbl_h264d[]` in BSP `mpp_rkvdec2.c:93-98`, all four tables) with
no derivation comment at the definition site.

The code itself is defensible: after subtracting UAPI-header-forced identifiers,
the shared-identifier intersection with the vendor RGA implementation collapses to
one explicitly-attributed macro name and three filename citations — no vendor
accessor macros, no copied function names, no copied comment prose.

**Fix plan.** Change the claim, not the code. Adopt the accurate and stronger
wording — *"independent implementation written against the BSP source as a
behavioral reference; no vendor expression copied; derivations attributed
inline"* — in `rewrite-drivers.md`, `driver-architecture-comparison.md` and
`status.md`. Then add derivation comments at the register-map and translation-
table *definition* sites (the scattered comments already model the right form),
and cite TRM sections wherever a constant came from the TRM rather than the BSP.
A reviewer who finds an attributed derivation is reading a defensible
reimplementation; one who finds the phrase "clean-room" above
`rga_rewrite.c:22095` stops reading.

### 14. KUnit blocks are inlined mid-file, against the convention in this same kernel tree

`Documentation/dev-tools/kunit/style.rst:205-208` prescribes
`tests/<suite>_kunit.c` alongside the code under test, with
`<kunit/visibility.h>` for static access. Both drivers instead carry
`#if IS_ENABLED(CONFIG_..._KUNIT_TEST)` bodies of **5,499 lines (31.4% of MPP)**
and **11,284 lines (44.4% of RGA)** in the middle of the production file, which
bisects production into two ranges and forces forward-declaration blocks both
inside the test region (MPP ~:3808-3858) and after it (RGA ~:20059-20065). One
test-only member has leaked into a production struct (`rga_rewrite.c:1350-1352`).

The project already knows this: `rewrite-kunit-rationalization-plan.md:70`
diagnoses it and `:270-283` prescribes the `mpp_rewrite.c` + `_internal.h` +
`_test.c` split. None of it exists in the tree. Function-size and nesting
discipline are fine (longest production function 247 lines; max nesting 8) — file
length is not the problem, *placement* is.

**Fix plan.** Execute the existing plan, one driver at a time, as a pure code-
motion commit with **no** logic changes, so the diff is reviewable by construction
and `rewrite-kunit-source-audit.py` can confirm the signal count is unchanged.
Do RGA first: it has the larger test block and the worse forward-declaration
situation. Gate the move behind a build of both KUnit-enabled objects plus the
warning-fatal clean-archive profile.

### 15. Test-count pinning has started distorting test structure

`rga_rewrite.c:12872`, verbatim:

```c
	/* Keep the established 148-case boot manifest while extending coverage. */
	rk_rga2_mmu_sgt_kunit(test);
	rk_rga2_mmu_plane_layout_kunit(test);
	rk_rga2_mmu_emit_kunit(test);
```

Three test functions called from inside `rk_rga_iova_span_kunit()` instead of
being registered as cases, so that `rewrite-kunit-log-check.sh`'s exact-148
manifest keeps matching. A regression in RGA2 MMU code will now misattribute in
KTAP to an unrelated case — and the incentive generalises to every future
contributor.

**Fix plan.** Register the three as real cases and update the manifest to 151.
Then fix the gate so it cannot create this pressure again: `rewrite-kunit-
manifest.tsv` should be a *set* comparison (which named cases ran, which are
missing, which are new) rather than a count assertion. A count is the one thing
about a test suite that carries no information; it is also the thing this gate
currently enforces most strictly. This is the same machinery that produced the
[2026-07-30 false-red](2026-07-30-rewrite-kunit-gate-false-red-harness-defects.md).

Related, and worth folding into the same pass: 19 hand-built partial fixtures
(11 MPP, 8 RGA) still violate the 2026-07-27 containment rule — e.g.
`mpp_rewrite.c:6715-6735` initializes 4 of ~45 `rk_mpp_hw` fields; ~:8547 builds a
session with only its `imports` list, so a future `lockdep_assert_held` in
`rk_mpp_find_import_locked()` oopses it. The compliant model already exists in
the file: `rk_mpp_kunit_alloc_service()` (~:3930) uses the production
`rk_mpp_service_state_init()`. This is the exact class that caused the KUnit boot
oops, and §4 shows what it costs — three green tests asserting an impossible
state.

Honest coverage story, against the "238 cases" headline: sampling 24 cases end to
end gave 10 strong behavioural, 9 moderate, 5 weak-or-tautological (one computes
its expected value *by calling the production packer under test*,
`rga_rewrite.c:10188`). By name classification, ~32/90 MPP and ~33/148 RGA cases
touch lifetime/concurrency/recovery — **roughly a quarter of the suite exercises
the class of code that has produced every real bug in this project's history**,
and even those stop at the MMIO boundary. The genuinely good ones are good: the
acquire-abort races (`rga_rewrite.c:13533`, `:13640`) use real kthreads and
completions, which is rare in driver KUnit.

### 16. RGA gives operators nothing when it rejects a request

RGA production has 121 `-EINVAL` and 221 `-EOPNOTSUPP` return sites, and
`rk_rga_request_ioctl_ret()` (~:24609) collapses all of them to `-EFAULT`. That
collapse is ABI-forced and documented (`ABI.rst:70`), so it is correct. What is
missing is any compensating channel: RGA has **0** `dev_dbg`, **0** debug-event
references (MPP has 56 and an `events` debugfs file), and only aggregate
counters. A librga user whose blit is rejected for any of ~340 distinct causes
gets `-EFAULT` and an incremented counter. Even the vendor driver dumps the
failing request.

**Fix plan.** Port MPP's debug-event ring to RGA — the pattern, the ring
structure, the `trace_mask` gating and the `events` debugfs file all already
exist and are proven in the sibling driver. Record a `REJECT` event carrying the
validator that failed and the offending field at each `return -E*` site in the
validators (a small macro keeps this from being 340 hand-edits). This is the
largest genuine supportability regression against the vendor driver and the
cheapest to close, because none of it is new design.

---

## What was ruled out

Recording this in as much detail as the defects, because a clean slice honestly
reported is what makes the rest of the finding trustworthy, and because
re-deriving these costs more than reading them.

**Locking.** The full hierarchy was reconstructed from code:
`session->explicit_map_lock → srv->hw_lock → session->lock → srv->sched_lock`,
and `ccu->ccu_recovery_lock → hw->run_lock → {ccu->run_lock,
srv->rkvenc_dchs_lifecycle_lock → srv->dma_group_lock → …, hw->reset_domain_lock}`.
**No cycle.** Four candidate inversions chased and closed: `dma_group_lock →
ccu->run_lock` does not exist (queued jobs never have `rkvdec_ccu_started`);
`hw_lock → dma_group_lock` does not exist (register/unregister are called outside
`hw_lock` in both probe and remove); `dchs_lifecycle_lock` self-recursion cannot
happen (`dchs_release` only asserts, never acquires); cross-core `run_lock` is
avoided by `mutex_trylock` at ~:12436 and ~:12473. RGA's hierarchy is likewise
acyclic, with `rga->hw_lock` always taken standalone.

**MPP uAPI parsing — clean.** Every `copy_from_user`/`copy_to_user`/`put_user`
reachable from the parser is size-bounded. No info leak: `trans_fd_to_iova`
`memset`s its buffer, `ensure_region_bytes` zeroes the grown tail after
`krealloc` so `SET_REG_READ` of never-written bytes returns zeros not heap
residue. `POLL_HW_IRQ`'s flexible buffer uses `check_mul_overflow`/
`check_add_overflow` and indexes only the *kernel* copy of `count_max`, so a
racing userspace rewrite cannot move the write. No unbounded `kmalloc`
(`RK_MPP_MAX_JOB_PAYLOAD` 128 KiB, batch caps 64/64/16). Command and flag
classification is dense with a rejecting `default:`, and every flag current
libmpp sends was traced to an allowed class. The missing `compat_ptr()` is inert:
libmpp's `MppReqV1` uses `RK_U64 data_ptr`, 8-byte aligned under AAPCS, so the
userspace record is 24 bytes on arm32 too — the *BSP's* compat path is the one
that no longer matches current userspace, and `ABI.rst:14-17` says so accurately.

**MPP register translation — clean apart from §2.** `check_mul_overflow` on
`index*4`; `check_add_overflow` on every span and every `binding->offset +
user_offset`, then `rk_mpp_import_iova_at_offset()` against `dmabuf->size`. All
built-in table maxima verified inside their regions. Explicit-IOVA resolution
requires strict containment in an import belonging to *this* session and mapped on
*this* device, takes a refcount under `session->lock`, and rejects a non-zero
unmatched literal. The offsets-then-revalidate ordering was specifically attacked
by flipping `regs[9]`/`regs[192]` via `SET_REG_ADDR_OFFSET` — safe, because the
revalidation re-reads the selector after the offsets pass. In-batch TOCTOU is
closed: all `SET_*` requests are materialised during the collect loop and
`execute_jobs` runs once after it.

**MPP hardirq safety — clean.** Every call reachable from `rk_mpp_hw_irq()` and
`rk_mpp_hw_aux_irq()` is atomic-safe. The one real ISR-panic candidate —
`rk_mpp_job_put()` at ~:14116 reaching dma-buf teardown and `kfree` — cannot be
the last put: every dropper of the active-slot reference is preceded by
`disable_irq[_nosync]` + `synchronize_hardirq`, and `take_irq_job` runs only in
the threaded handler which `IRQF_ONESHOT` serialises. The 2026-07-24 class is
genuinely closed. Slice-FIFO arithmetic is masked `GENMASK(5,0)` with an explicit
`kfifo_avail()` check; the five BS register offsets were verified against the BSP
VEPU580 branch.

**MPP probe/remove/PM — clean.** No leak on any probe error path (all devm or
`devm_add_action_or_reset`; the two manual registrations unwind correctly).
`remove` drains the fault worker via `flush_work` inside
`iommu_unregister_fault_handler`, frees IRQs explicitly after rebalancing the
quarantine-skewed depth, and `fops.owner = THIS_MODULE` pins the module against
any open fd. `suspend` fails closed with `-EBUSY` on
`active_job || iommu_fault_pending || queued_job_count || power_count`, checked
twice around provider synchronisation with full rollback. All debugfs `show`
handlers snapshot under the lock that guards mutation, with `mutex_trylock` for
the list walks (the round-1 global-lock DoS stays closed).

**MPP ordering claims verified.** Software ownership *is* published before the
`CFG_DONE` doorbell (`WRITE_ONCE(job->rkvdec_ccu_started, true)` → `wmb()` →
doorbell, ~:3706-3715, with list ownership published one statement earlier), with
no bypass. IOMMU refresh after reset is correct at the two sites that do it —
and **five paths reset without refreshing**: the soft-CCU IRQ error path
(~:14518), the *timeout* branch of `recover_active` (refresh is gated on
`if (iommu_fault)` at ~:12778), `abort_job` (~:12243), `abort_active` /
`abort_active_recovery_locked`, and `drain_ccu_done_jobs`' `ccu_error` reset. That
matters more than the [2026-08-01 self-reset finding](2026-08-01-rkvdec-self-reset-and-iommu-restore-gaps.md)
assumed, because its mitigation argument
("the IRQ thread powers off after every job, so the power cycle restores it for
free") does not hold in the default two-stream configuration: on ROCK 5B
`vdec1_mmu` declares `rockchip,shared-domain-owner = <&vdec0_mmu>`, so
`rk_mpp_rkvdec2_power_on_ccu_cores()`'s domain filter passes and every job holds
a power reference on *every* core of the group — tracing core0 with jobs on both
cores, `power_count` never reaches 0, so the core never runtime-suspends and
rockchip-iommu never re-runs `rk_iommu_enable()`. Consistent with the recorded
measurement of `iommu_refresh_count` moving by 0 across 5,060 resets. **Add this
to that finding**; it does not change its conclusion but it
removes its stated reason for thinking the gap is masked.

**The reset-domain lock holds.** `reset_control_*` appears at six sites; three are
inside `rk_mpp_hw_reset_domain_lock()`, and the `force_stop_ccu()` ones — flagged
"Not covered" in the [sibling-deassert finding](2026-07-31-rkvdec-sibling-reset-deassert-race.md) — are in fact serialized against every
competing writer by `ccu->ccu_recovery_lock`. That note is over-cautious, not a
live hole. No assert/deassert pair is split across an unlock; no
`synchronize_irq`/`disable_irq` under a lock the handler takes; generation
counters are all `u64`, skip 0, and every `==` is additionally gated on non-zero.

**RGA layout arithmetic — clean.** No `u32` wrap exists: every geometry field is
`__u16` and every product is `size_t` under `check_mul_overflow`, with
`RK_RGA_MAX_BYTE_STRIDE = 32768` capping strides independently. The pixel-vs-byte
stride convention is applied uniformly across raster, compact-10-bit, FBC/AFBC,
tile and BPP-palette, verified against BSP `rga3_reg_info.c:350-394` and
`rga2_reg_info.c:743-764`. Offsets are always folded in *after* the extent check.
Three formats were traced end to end from ioctl to the length comparison; the
comparison sites are `rk_rga_materialize_img_import()` ~:3306 and
`rk_rga_resolve_handle_locked()` ~:3264. FBC header-stride formulas over-estimate
or match for all seven format classes. One latent item not worth a section:
`rk_rga_rkfbc_layout()` / `rk_rga_afbc32x8_layout()` (~:2912, ~:2933) size an
import from the header alone with no payload term — currently unreachable because
`rk_rga3_hw_rd_mode()` returns `-EOPNOTSUPP` for those modes and every RGA2 path
rejects non-raster `rd_mode`, so the undersized import is accepted at resolve time
and the job rejected before any DMA. Make them return `-EOPNOTSUPP` outright
rather than leaving a wrong size behind a switch statement.

**RGA import lifetime — clean.** Handle resolution is `idr_find` +
`refcount_inc` entirely under `session->lock`, which `RGA_IOC_RELEASE_BUFFER`
also takes. `dma_buf_get`/`put` and `attach`/`detach` are symmetric on all six
error exits. The userptr shadow's head/tail/collapsed cases were worked by hand —
no over-copy, no wrong page offset. `FOLL_LONGTERM` prevents mid-job remap. sg
validation walks every entry proving byte adjacency with overflow checks, not
just the first. Alias detection is by `struct dma_buf *` and by pinned page
identity, never by fd or handle, with distinct-object aliasing caught at job-map
time via `iommu_iova_to_phys()`. DMA direction is correct including the in-place
src==dst case. Cache maintenance on the Route-B path correctly routes through
`arch_sync_dma_for_*` after `rk_rga_reset_sgt_dma_state()` clears
`SG_DMA_SWIOTLB`. Two hardening gaps noted without sections: `rga->import_lock` is
held across the entire userptr pin-to-IOMMU mapping (a ~1 GiB import serialises
every session's import/release — same class as the round-1 global-lock DoS, and
only the recheck-and-register window needs the lock); and there is no
`account_locked_vm()` / `RLIMIT_MEMLOCK` accounting on `FOLL_LONGTERM` pins,
matching the BSP.

**RGA job/fence/IRQ — clean apart from §6.** All fences share `rga->fence_lock`
and the acquire callback takes no lock, so signalling under it is safe and
deliberate. The `xchg(&waiter->job, NULL)` zero-crossing protocol between callback
and cancel is correct. `fd_install` ordering is exclusive install-or-abort on
every path including the `copy_to_user` failure; no `put_unused_fd` after
`fd_install` is reachable. The timeout worker and IRQ thread cannot both claim a
job (`disable_irq` + `synchronize_irq` precedes `run_lock` everywhere).
`active_job != NULL` under `run_lock` implies powered, so `regs_live_count` cannot
underflow. Session close is airtight: `closing` → `wait_event(dispatches_idle)` →
abort pending-acquire → abort hw jobs → `wait_event(jobs_empty)`, with both
wakeups issued *under* `job_lock`.

**RGA emission — clean apart from §1 and §7.** Every command-buffer write is a
constant or `base + constant`, max RGA2 offset `0x07c` of 32 slots and RGA3
`0x0b8` of 48; the RGA2 full-CSC block that *would* overflow goes to MMIO, not the
command list. The RGA2 internal-MMU page-table build is two-pass count-then-fill
with a capacity re-check, per-PTE 32-bit rejection, and `filled != page_count`
fail-closed. Cross-task state cannot leak: mappings and the MMU table are freed
and NULLed before `advance_task`. The RGA3→RGA2 fallback re-runs both validators
and re-selects hardware per task. Rotate/mirror corner addresses match the BSP
formula-for-formula including the asymmetric packed-420 case; the `- 1` terms
cannot underflow because the alignment rules force the operands ≥ 1. Every RGA2
register-offset collision (`0x028`, `0x030`, `0x060-0x064`) is either write-ordered
correctly or the features are mutually excluded.

**Three items refuted during verification** and recorded so they are not
re-raised: the missing `compat_ptr()` (inert, see above); `RGA_IOC_IMPORT_BUFFER`
returning the last handle rather than 0 (matches the BSP exactly — correct ABI);
and RGA2 `pre_intr_info` being emitted unvalidated (the BSP does the same and
every field is `FIELD_PREP`-masked — ABI parity, not a defect).

---

## Fix status (2026-08-01)

All eleven defects fixed, plus §12, §13, §15 and §16. Series:
`rk3588-rewrite-6.18` `b885391e2af8a..187b0d647e6ce`, mirrored to
`rk3588-rewrite-mainline@45554b495e66e`; the driver sources, Kconfigs and ABI
ledgers are byte-identical between the two tips.

| # | Fixed | Commit (6.18) | Deviation from the plan above |
|---|---|---|---|
| §1 | yes | `89c5a1c636046` | none; new KUnit case pins WIN0 geometry for 90 and 270 |
| §2 | yes | `ffac4bd0175ca` | store-time index validation dropped as redundant — the reorder makes the revalidation authoritative, and a legitimate RCB index is never an address-table word |
| §3 | yes | `239a4ce5c655e` | needed its own `raw_spinlock_t` held **across** the handler, not `hw->lock` sampled before it, since the backends take `hw->lock`. Step 5 was wrong as planned: `INT_CLR` is write-1-to-clear (BSP writes `0xffffffff` on reset), so writing 0 would be a no-op. Replaced with a latch drain in the threaded handler while the clocks are still on. |
| §4 | yes | `63a8f897d62a2` | deleted, as recommended; three KUnit cases went with it |
| §5 | yes | `d62e29d796fee` | deadline keyed to the activation generation, not the job pointer — the drain clears `timeout_job`, so a pointer comparison would treat every restore as a new job |
| §6 | yes | `c074806f608ab` | shared tail factored into `rk_rga_hw_finish_job_locked()`; a failed recovery reset now refuses the requeue and fails `-EIO`, a case the IRQ path cannot reach |
| §7 | yes | `6865662d6b6d4` | audit found a **second** instance of the class: `alpha_bitmap + osd` set `profile->osd` without running the OSD validator. Both fixed, plus the structural cause. |
| §8 | yes | `e20090aa30610` | sweep found two more `kfree` on extent error paths; rest of the class already bounded |
| §9 | yes | `892d42b1f6d11` | unlock needs its own job pointer, since the shared exit clears `job` |
| §10 | yes | `42c7ea2ba4bda` | `max()` guard plus `WARN_ONCE`, as planned; still **needs-hardware** |
| §11 | partial | `42c7ea2ba4bda` | restriction declared in `ABI.rst`. The errno change was **dropped**: `ABI.rst` records the `-EFAULT` normalization as a deliberate BSP-wrapper decision, so changing it is an ABI change that should not ride along in a fix pass. |
| §12 | yes | `c9939daac9846` | `MODULE_AUTHOR` names a human |
| §13 | yes | `c9939daac9846` + ysp `6dc381f` | claim reworded in the code headers and the track page; derivation note added at the rkvdec table definitions |
| §15 | yes | `973c0c08f9a4f` + ysp `87596d3` | manifest is now one row per named case; drift reports name the cases. Writing the checker surfaced a self-inflicted silent-pass — an empty manifest verified nothing — now guarded and covered by the selftest. |
| §16 | yes | `187b0d647e6ce` | ring scoped to rejection diagnostics with four record sites rather than editing ~340 return sites; the highest-value one records both backends' verdicts for "no core matched" |

**§14 (the KUnit test-file split) is not done.** It is an 11,284-line and
5,499-line code motion in a worktree with a concurrent writer, where a conflict
would be unrecoverable for the other party, and it is the one item on this list
with no correctness content. It should be done in a dedicated worktree with no
other writers, as a pure code-motion commit verified by the source audit
reporting an unchanged signal count. Note that §7's fix hit the cost of not
having done it: the new validator test needed a forward declaration because
`rk_rga2_validate_bitblt()` is defined *after* the test block.

Still open and unchanged by this series: the three **needs-hardware** items
(§3's gated-clock stall, §10's AFBC model question, §1's byte-exact FBC header
extent), and the pre-existing `rewrite-evidence-audit.sh --selftest` failure in
its counter-check fixtures, which fails identically before and after.

## Fix sequencing

Land in this order. Each group is one commit per tree, mirrored byte-identically
to `rk3588-rewrite-mainline`, each individually compile-verified so the series
stays bisectable — the same discipline as the 2026-07-24 series.

1. **§1** RGA3 overlap rot90 un-swap + the two emit tests. Highest severity,
   smallest diff, has a known-good sibling to copy.
2. **§8** `kvcalloc`/`kvfree` + the user-sized-allocation sweep. One line plus an
   audit; no behaviour change.
3. **§7** quantize color-key exclusion + the `profile->color_key` derivation fix.
4. **§5** absolute watchdog deadline.
5. **§6** RGA recovery multi-task requeue, factoring the shared tail into a
   helper used by both the IRQ thread and the recovery path.
6. **§2** RCB reorder + index validation + BSP-matching skip. Three changes, one
   commit, because they only make sense together.
7. **§9** DCHS lifecycle lock in `abort_active_recovery_locked`, plus the three
   `WARN_ON_ONCE`-branch reference leaks.
8. **§3** `regs_live_count` port (steps 1–4), then the rkvenc2 W1C fix as a
   separate commit after the register-semantics check.
9. **§4** decide and execute — delete or revive; do not leave it.
10. **§11(2)** declare the provenance restriction in `ABI.rst` and stop laundering
    the errno. **§11(1)** behind a librga run.
11. **§10** the `max()` span guard plus `WARN_ONCE`; real closure needs silicon.

Then the structural work, which is larger and should not block the defect fixes:
**§15** (register the three hidden cases, convert the manifest to a set
comparison, converge the 19 fixtures), **§16** (port the debug-event ring to RGA),
**§14** (the test-file split, RGA first, as pure code motion), **§13** (reword the
provenance claim, add derivation comments), **§12** (name a human author).

## Verification gate

The smallest run that would close the *code* half of this finding:

- `kernel-drivers/tests/rewrite-build-gate.sh` warning-fatal `normal` profile
  green on both tips, compiling both IOMMU providers, both KUnit-enabled objects
  and both ROCK 5B DTBs.
- `rewrite-kunit-source-audit.py` reporting zero new and zero absent signals
  against an updated baseline (the new cases from §1, §2, §5, §6, §7 are
  deliberate additions and must be added to
  `rewrite-kunit-source-audit-baseline.tsv`).
- A boot of the fixed tree with the full manifest completing, **live lockdep**
  (which §9 currently prevents), kmemleak clean, and a fatal-free interval.

Beyond that, three of the eleven are explicitly **needs-hardware** and cannot be
closed by reading: §3 (the gated-clock MMIO stall, watch `spurious_irq_count`
under a slice-split encode loop and `dmesg` for `nobody cared`), §10 (which of
the two AFBC size models the silicon agrees with), and the byte-exact DMA extent
of §1's FBC header walk.

## Boundary

No kernel was booted and no hardware was run for this finding; every claim is
source reading against the pinned tips named in the header, re-verified by the
reviewer after the fan-out reported it. **No fix has been written** — every "fix
plan" above is DESIGN and none has been compiled, let alone run.

Severity ratings assume the stated threat model (unprivileged opener of
`/dev/mpp_service` and `/dev/rga`); on a board where those nodes are root-only,
§5, §8 and the resource-exhaustion items drop substantially, while §1, §2 and §6
do not.

The two reviewers who worked §10 reached **opposite** conclusions from the same
arithmetic; it is recorded as a defect because the two size models inside one
function are demonstrably inconsistent for reachable inputs, but whether that
inconsistency escapes the buffer is unresolved.

This review covered production code only. The 16,780 lines of KUnit blocks were
sampled (24 cases end to end plus name-classification across all 238) for the
purposes of §15, not audited for defects. A defect *inside* a test would not have
been found except where it produced the false coverage in §4.

Coverage is by line range, not by call graph: each reviewer read its assigned
slice plus whatever callers and callees verification required. A defect whose
two halves sit in two slices and whose interaction neither reviewer traced is the
most likely thing this round missed — which is precisely the shape of the eight
sibling-site findings above, so treat the table in §Result as a description of
this codebase's failure mode rather than as a closed list.
