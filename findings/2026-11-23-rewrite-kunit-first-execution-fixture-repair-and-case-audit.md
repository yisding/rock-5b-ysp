# Rewrite KUnit suites executed for the first time: seventeen fixture failures repaired and five cases removed

> Scope: the in-driver KUnit suites of both clean-room rewrite kernel lines
> (`rk_mpp_rewrite`, `rockchip-rga-rewrite`) and the YSP manifest and source
> audits that pin them
> Source: `rk3588-rewrite-6.18@94b3d97d6a12` (was `a6fa1f545507`) on
> `v6.18.64` and `rk3588-rewrite-mainline@1bcfb8514376` (was `b153bd919515`)
> on `v7.4-rc3`; `drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c` and
> `drivers/video/rockchip/rga-rewrite/rga_rewrite.c`
> Date: 2026-11-23
> Trust: MEASURED under QEMU emulation (arm64 `virt`, TCG), SOURCE-INSPECTED,
> FIX-RUNTIME-VERIFIED in that emulation only, PARTIAL. No board boot, no
> package and no hardware result. The compound board gate is still open, and
> one lockdep report from production locking is recorded here and not fixed.

## Result

The [2026-11-22 review](2026-11-22-rewrite-6-18-64-7-4-rc3-rebase-and-driver-review.md)
left the suites compiled but never run, with a list of fixtures it predicted
would fail. Both suites can be run without a board: the tree's own `kunit.py`
builds a minimal arm64 kernel with the two drivers and both test symbols, and
QEMU boots it on the `virt` machine. No RK3588 device probes there, and the
cases only touch their own fixtures.
[`rewrite-kunit-qemu.sh`](../kernel-drivers/tests/rewrite-kunit-qemu.sh) is the
tracked form of that run.

At the 2026-11-22 tip the result was **251 of 268**, with four NULL
dereferences in the KUnit thread:

| Suite | Passed | Failed | Kernel reports in the run |
| --- | ---: | ---: | --- |
| `rk_mpp_rewrite` | 105 | 7 | 4 oopses, 1 workqueue warning |
| `rockchip-rga-rewrite` | 146 | 10 | 1 driver `WARN_ON_ONCE`, 2 debug-object warnings |

All seventeen failures were fixtures that had fallen behind the driver. None
was a driver defect. Four commits on each line repair them, stop the fixtures
leaking, and remove five cases an audit found redundant. The manifest is now
**111 MPP + 152 RGA = 263**, and on the 6.18 tip all 263 pass:

| Configuration (6.18 tip, QEMU) | Result |
| --- | --- |
| `PROVE_LOCKING`, `DEBUG_OBJECTS` (work, timers, free), `DEBUG_ATOMIC_SLEEP`, `DEBUG_LIST` | 111/111 and 152/152; one lockdep report, described below |
| The above plus generic KASAN and kmemleak | 111/111 and 152/152; no KASAN report; kmemleak empty after two scans |

The mainline tip passes the first configuration with the same single report.

### What failed and why

Nine of the seventeen failing cases were among the review's predictions. Eight
were not.

**MPP, seven failing cases and one warning.**

- `rk_mpp_reg_offsets_kunit` and `rk_mpp_reg_offset_dma_bounds_kunit` oopsed.
  Neither initialised the job's activation, which `rk_mpp_job_reject_reg()`
  and the exact-end notice now read. Not predicted.
- `rk_mpp_batch_session_switch_split_kunit` and
  `rk_mpp_batch_session_snapshot_kunit` oopsed. Their sessions had no service,
  and `rk_mpp_job_release()` proves the dispatch lease under
  `session->srv->sched_lock`. Not predicted.
- `rk_mpp_rkvdec2_link_table_ownership_kunit` asserted the prelink pointer on
  node 2. Reservation always keeps that node spare and no job stages it; the
  third job reuses node 0. Predicted.
- `rk_mpp_hw_take_active_if_kunit` seeded a watchdog deadline before the first
  install. `rk_mpp_activation_install_locked()` refuses an activation that is
  not pristine, so nothing was installed and the case ran on an empty slot.
  Not predicted. The case now asserts the refusal, then installs.
- `rk_mpp_session_poll_irq_nonslice_kunit` reaped a finished job whose register
  builder was still open, so readback returned `-EPERM`. Predicted.
- `rk_mpp_reset_session_hw_active_import_kunit` reported `ok` but tripped the
  workqueue warning: its bare service never initialised `sched_work`.
  Predicted.

**RGA, ten cases.**

- Five multi-task emitter cases (`rk_rga2_rectangle_task_emit_kunit`,
  `rk_rga2_mosaic_task_array_emit_kunit`,
  `rk_rga3_librga_copy_splice_task_kunit`, `rk_rga3_librga_side_border_kunit`,
  `rk_rga3_librga_padding_kunit`) checked `cmd_ready` on the job's embedded
  first execution after the advance helper had made a successor current.
  Predicted as a class.
- `rk_rga3_multitask_emit_clears_stale_regs_kunit` called
  `rk_rga_job_emit_cmd()` without the plan dispatch publishes first and got
  `-EUCLEAN`. Predicted.
- `rk_rga2_mmu_emit_kunit` had no plan, so `rk_rga2_emit_mmu()` returned before
  writing. Not predicted.
- `rk_rga_release_configured_request_kunit` left `sync_mode` at zero, which
  `rk_rga_request_check()` rejects. Not predicted.
- `rk_rga_legacy_blit_sync_wait_kunit` released a `RETIRED` execution; storage
  is released only from `UNINSTALLED` or `RECLAIMABLE`. Predicted.
- `rk_rga_timeout_target_replacement_kunit` expected job refcounts one too low.
  Every typed execution reference pins its job, so the active slot holds one.
  Not predicted.

Three RGA cases also initialised jobs on the stack. A job embeds a work item,
and debug objects warns about an unannotated one. Not predicted.

Two predictions did not show up as failures. The pending-acquire races and the
`rk_mpp_hw_prepare_active_retry_kunit` fixture gaps are real on reading but did
not fire in these runs; both are repaired anyway (see below).

### Leaks

Kmemleak reported **101 objects** after an otherwise passing run, all from RGA
direct-emitter fixtures: 89 task plans and 12 successor executions. The emitter
builds a plan on a job that the fixture never tears down, and the multi-task
cases never free the executions `rk_rga_job_advance_task()` allocates.

A plan built for an execution that is not on hardware is now handed to the
running test through a KUnit action. `rk_rga_emitter_require_plan()`'s existing
KUnit-only rebuild and `rk_rga_job_release_exec_storage()` free through one
helper that knows which owner a plan has. The six multi-task cases free their
successor executions. The owner field and both helpers are compiled only with
the RGA test symbol; a test-disabled `W=1` build is warning-free. After the
change kmemleak reports nothing. The MPP suite never leaked.

### Repairs to cases that reported `ok`

- `rk_mpp_scheduler_session_start_order_kunit` never initialised its two
  session mutexes, and dropping the claim locks one. It reported `ok` in the
  first run only because the earlier oopses had already switched lock debugging
  off.
- `rk_rga_release_pending_acquire_job_kunit` and
  `rk_rga_last_hw_remove_pending_acquire_kunit` asserted import refcounts
  before the acquire worker had dropped the job. They now wait, bounded, for
  the worker's put.
- `rk_rga_acquire_abort_queues_last_kunit` called `kthread_stop()` on threads
  that return by themselves, which is allowed only when nothing stops them.
  The threads now wait to be stopped.
- `rk_mpp_hw_prepare_active_retry_kunit` gets the full service constructor,
  both back-pointers and the coordinator's locks, so a path that starts using
  one fails an expectation instead of dereferencing a zeroed object.

### Case audit

Seven independent readers each took a slice of the 268 cases and had to name,
per case, the production function reached, the contract pinned, one production
change that would make the case fail, and any other case that would fail under
the same change. The rule was the
[rationalization plan's](../kernel-drivers/docs/rewrite-kunit-rationalization-plan.md):
a case stays only if it uniquely detects a material contract violation at the
lowest safe layer, and a removal needs high confidence and quoted evidence.

The audit found a failing mutation for all but a handful. Five cases were
removed, each checked again by hand before deletion:

| Removed case | Why |
| --- | --- |
| `rk_mpp_support_cmds_kunit` | Calls no driver function. It compares the support tables with a second copy of the same initialisers, so a value is only compared with itself. |
| `rk_rga_fill_hw_type_kunit` | All four assertions are made by `rk_rga_mixed_task_hw_type_kunit`, `rk_rga_task_core_invalid_mask_kunit` and `rk_rga2_rectangle_task_emit_kunit`. |
| `rk_rga2_fill_dst_offset_emit_kunit` | Same colour-fill recipe as the first task of `rk_rga2_rectangle_task_emit_kunit`. Its one unique assertion, the destination stride word, moved there. |
| `rk_rga_request_remove_free_kunit` | The removed, gone and absent outcomes are asserted through the cancel ioctl in `rk_rga_request_create_cancel_ioctl_kunit`. |
| `rk_rga_irq_flags_kunit` | Copies a one-line ternary on its only two inputs; probe evaluates both on every boot. |

Six more were proposed for merging at medium confidence and are **kept**
because each needs an assertion carried into a survivor and none was verified
by a second read: `rk_mpp_job_hw_pin_kunit`,
`rk_rga_gstreamer_legacy_convert_profiles_kunit`,
`rk_rga3_librga_translate_emit_kunit`,
`rk_rga3_librga_rotate_flip_emit_kunit`, `rk_rga_ffmpeg_fbc_profiles_kunit`
and `rk_rga_ffmpeg_alpha_overlay_kunit`.

The audit also listed assertions that cannot fail as written. These are not
repaired:

- `rk_mpp_timeout_target_replacement_kunit`: the "reschedule must not move the
  deadline" check compares two deadlines computed in the same jiffy.
- `rk_mpp_batch_server_wait_detect_kunit`: the third expectation reuses a
  request the second step zeroed.
- `rk_mpp_rcb_invalid_index_kunit`: the out-of-range index is rejected as
  untrusted before the range check it names.
- `rk_rga_session_dispatch_close_handoff_kunit`: the closing branch is never
  reached because `acquires.waiting` is false.
- `rk_rga3_size_and_tile_mode_limits_kunit`: the input-size probe exceeds the
  size mask and is rejected before the input limit.
- `rk_rga_userptr_shadow_zeroed_kunit`: still cannot fail with `init_on_alloc`.
- `rk_rga_debug_event_ring_kunit`: the trace-mask step sets a bit the default
  mask already has.
- Several `rk_mpp_activation_storage_released()` `EXPECT_FALSE` lines in the
  activation cases are false for any production behaviour.

One reader predicted that `rk_rga3_librga_alpha_yuv_emit_kunit` and
`rk_rga3_alpha_yuv10_overlay_emit_kunit` carry a stale FBC chroma-base
expectation and would fail. Both pass in every run, so that prediction is
recorded as wrong.

### The lockdep report that is not a fixture defect

With `PROVE_RAW_LOCK_NESTING`, which arm64 forces on with `PROVE_LOCKING` and
which the debug kernel therefore has, lockdep prints
`BUG: Invalid wait context` at `rk_mpp_irq_register_lease_kunit` and again at
`rk_mpp_iommu_fault_generation_kunit`:

```text
kunit_try_catch is trying to lock:
 (&hw->lock){....}-{3:3}, at: rk_mpp_hw_irq_register_lease_snapshot_locked
1 lock held by kunit_try_catch:
 #0: (&hw->regs_lock){....}-{2:2}, at: rk_mpp_irq_register_lease_kunit
```

`rk_mpp_hw_irq_register_lease_snapshot_locked()` and `rk_mpp_hw_take_irq_job()`
take the `spinlock_t` `hw->lock` while holding the raw `regs_lock`. Both are
driver functions on the interrupt paths, and the fixtures only call them the
way the driver does. The 2026-11-22 review rejected this nesting as a deferred
`PREEMPT_RT` limitation that no shipped configuration reaches. That was wrong
for the qualification configuration: the first report sets `debug_locks` to
zero, so every case after `rk_mpp_irq_register_lease_kunit` (MPP 58 in the new
manifest), and everything else in that boot, runs without lockdep. The compound board gate requires lockdep to stay enabled, so
it cannot go green until the nesting is resolved or the gate's contract
changes. No fix was attempted here; it is a locking-design decision in
production code.

To get lockdep coverage of the rest, the suites were rerun in three filtered
parts that keep the first reporting case out of two of them. 105 MPP cases and
all 152 RGA cases ran with lockdep enabled to the end and no report. Four MPP
cases (`rk_mpp_iommu_*`) ran after the second report and have no lockdep
verdict.

### Commits

| Commit | 6.18 | Mainline |
| --- | --- | --- |
| mpp-rewrite: drop the support-table mirror KUnit case | `cda7dc470fc8` | `b86da98038a4` |
| rga-rewrite: drop four redundant KUnit cases | `f663c8e1773b` | `25355f449a93` |
| mpp-rewrite: repair KUnit fixtures that failed on first run | `23c5827f5912` | `a306e4c3d5a1` |
| rga-rewrite: repair KUnit fixtures and stop them leaking | `94b3d97d6a12` | `1bcfb8514376` |

Both driver files are byte-identical between the two tips: MPP SHA-256
`07d4a76b0b2a6c43683389cafd7aa3e5f109130aeb15a296176f74f6e93858de`, RGA
`4e1304446262fb52066f64f5914c584dcc1ff2fa2c9249d59fdf9ffabd5433f0`. The
commits are local to the two branches named in the header and were not pushed
to the `linux-rock5b` fork.

## Evidence and reproduction

- **Identity:** the two source tips in the header. QEMU 10.2.1
  (`qemu-system-aarch64`, Ubuntu `1:10.2.1+ds-1ubuntu3.3`), `-machine virt
  -cpu max`, TCG. The board itself was the build and emulation host; KVM was
  not used.
- **Exercise:** `bash kernel-drivers/tests/rewrite-kunit-qemu.sh <tree>` for
  the lockdep configuration, and `KUNIT_QEMU_KASAN=1` for KASAN. The kmemleak
  verdict came from the same KASAN kernel with `CONFIG_DEBUG_KMEMLEAK=y`,
  booted without `kunit_shutdown` into a one-file static init that writes
  `scan` to `/sys/kernel/debug/kmemleak` twice and prints the file. That init
  is not tracked.
- **Pass/fail signal:** `# Totals: pass:111 fail:0 skip:0 total:111` and
  `pass:152 fail:0 skip:0 total:152`, plus a console scan for `WARNING:`,
  `BUG:`, `Oops`, `ODEBUG:` and `KASAN:`. A kernel report does not fail a
  KUnit case, so the totals alone are not the signal.
- **Static gates:** checkpatch `--strict` is clean on all four patches.
  `REWRITE_BUILD_PROFILES="normal test-disabled memory race"
  rewrite-build-gate.sh all` printed a `PASS: clean rewrite object build` line
  for each of the four profiles at `94b3d97d6a12` and at `1bcfb8514376`, eight
  in all. That closes the three profiles the 2026-11-22 pass skipped. The
  ABI-mutation gate was not rerun. The manifest, fixture-debt (310
  signals/tree, was 313), ownership (2,326/tree) and writer-inventory (118
  signals) audits pass on both tips.
- **Artifacts:** console logs under
  `../rock-5b/build/kunit-qemu-20261123/` (`base-lockdep.baseline-a6fa1f545507.log`
  for the 251/268 baseline, `run3.log`, `run3-lockdep-part{1,2,3}.log`,
  `debug-run2.log`, `mainline-run1.log`, `kmemleak1.txt` for the 101-object report). That directory
  is disposable build state.

## Boundary

- This is emulation. No kernel from these tips was booted on the board, no
  package exists for them, and no decode, encode or blit ran. The suites never
  touch hardware even on the board, so this run says nothing about the
  drivers' hardware paths.
- The board gate is a compound contract: exact manifest, plus a fatal-free
  boot interval on the debug kernel with lockdep still enabled. The lockdep
  report above means that contract cannot currently be met.
- KASAN and kmemleak results are for the 6.18 tip only. The mainline tip has
  the byte-identical driver files and passed the lockdep configuration; see
  [Mainline run](#mainline-run).
- KCSAN was not run. Timing-dependent cases ran under single-vCPU TCG for the
  lockdep runs and two vCPUs for KASAN; a pass there does not show a race is
  closed, only that it did not fire.
- The audit is a reading. A kept case is one a reader found a failing mutation
  for; none of those mutations was applied and run.

## Mainline run

The mainline tip `1bcfb8514376` (Linux 7.4.0-rc3), exported with `git archive`
because the working tree holds in-tree build output, gave the same result
in the lockdep configuration: 111/111 and 152/152, with the one
`Invalid wait context` report at `rk_mpp_irq_register_lease_kunit` and nothing
else. KASAN and kmemleak were not rerun on mainline.

## Verification gate

Resolve or explicitly accept the `hw->lock`-inside-`regs_lock` nesting first.
Then build a package composite for each tip, boot the 6.18 one under KASAN and
lockdep on the board, and require the 263-case manifest with a fatal-free
interval and lockdep still enabled at the end.
