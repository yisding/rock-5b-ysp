# Rewrite KUnit fixture audit: 2 boot oopses fixed, full 232-case sweep, latent hazard inventory

> Scope: mpp-rewrite + rga-rewrite KUnit suites (both kernel trees)
> Source: linux-6.18-rkvenc @ e5867fa31ed2b / linux (mainline) @ f950cb7cc7140 —
> `mpp_rewrite.c`, `rga_rewrite.c` test regions
> Date: 2026-07-29
> Trust: source-audit; boot-verified only for the two original oopses (fix boot pending)

## Result

The 2026-07-29 first boot of `6.18.40-video-rewrite-kasan-rockchip64 #14` hit
two KUnit NULL derefs, both **fixture bugs, not driver bugs** — driver code
gained new back-pointer dereferences and older fixtures never initialize those
pointers:

- `rk_mpp_reset_session_hw_active_import_kunit`: fixture `hw` lacked
  `hw.srv`; `rk_mpp_hw_abort_job()` now ends with an idle-dispatch kick that
  reads `hw->srv->queued_jobs`. KASAN read at NULL+0x348 ==
  `offsetof(struct rk_mpp_service, queued_jobs)` (confirmed via
  `pahole -C rk_mpp_service /sys/kernel/btf/vmlinux`).
- `rk_rga_userptr_shadow_copy_kunit`: stack view lacked `.rga`;
  `rk_rga_userptr_view_copy()` now does
  `atomic64_add(..., &view->rga->shadow_copy_to_bytes)`. KASAN write at
  NULL+0x490 == `offsetof(struct rk_rga_service, shadow_copy_to_bytes)`.
  Production always sets both pointers (probe sets `hw->srv`; view creation
  copies `import->rga`), so no driver change is warranted.

A 9-agent audit of **all 232 cases** (84 MPP + 148 RGA) then traced every
fixture against the reachable dereferences of its production callees. No
further reachable NULL deref, uninitialized-lock acquisition, DEBUG_OBJECTS
trip, or double-free of KUnit-managed memory was found. Six additional gaps
were fixed in the same commit because they are the same class one evolution
step away, or are already racy/fragile:

- `rk_mpp_session_abort_jobs_kunit`, `rk_mpp_reset_session_public_cleanup_kunit`:
  same `hw->srv` gap, benign only while no fixture job is the hw's active job.
- `rk_rga_last_hw_remove_pending_acquire_kunit`: hw on `rga->hw_list` with
  uninitialized `job_queue`/`job_lock`/`run_lock`/`idle`/`refs` — any mid-test
  ASSERT failure would crash the `rk_rga_release` cleanup action (lockdep +
  KASAN on the zeroed list) instead of reporting the failure.
- `rk_rga_legacy_blit_async_acquire_kunit`,
  `rk_rga_request_submit_async_acquire_kunit`: release fence signals before
  `acquire_work` unlinks the job from the **on-stack** session — the import
  refcount EXPECTs raced the worker and the worker could touch the dead stack
  frame after test return (intermittent KASAN stack-out-of-scope). Fixed by
  `flush_workqueue(system_highpri_wq)` after the fence wait.
- `rk_rga_request_config_ioctl_acquire_kunit`: config ioctl closes
  `acquire_fd` in-kernel but the tracked close action stayed registered —
  teardown would close a reused fd number (boot KUnit kthreads share the init
  files table). Fixed with `kunit_remove_action`.

## Latent hazards left as-is (audit near-miss inventory)

Not bugs today; each is one driver evolution or fixture tweak from a crash.
Check this list first when a future rewrite KUnit boot oopses:

- **Back-pointers left NULL, currently unread on the exercised path**:
  `session.srv` (MPP set_err_ref_hack, store_codec_info, explicit-iova
  validation), `job.session`/`job.hw` (MPP reg-offset tests; RGA emit/hw_type
  family ~40 fixtures), `hw->rga` (RGA abort/queue/dispatch tests — guarded
  only by `removing`/`recovery_failed` flags short-circuiting before the
  `scheduled/dispatched_job_count` accounting), `session.rga` (RGA
  import-ioctl error tests — every exercised case errors out before
  `rk_rga_import_one` touches it).
- **Deep-path guards carried by generation/pointer mismatch**: MPP + RGA
  iommu-fault and timeout tests reach `recover_active` only through the
  mismatch early-return; a matching generation would run the deep path onto
  NULL `session`/`srv`/`match`/`regs`.
- **`_locked` helpers with no lockdep assert**: several fixtures never init
  the corresponding lock (`srv->lock` MPP core_identity, `ccu->lock` MPP
  link_table_ccu_ref, `hw.job_lock` RGA priority_enqueue); adding
  `lockdep_assert_held` to those helpers will trip them.
- **`srv.sched_work` never `INIT_WORK`'d** in MPP abort-path fixtures; safe
  while `queued_jobs` is empty at the kick.
- **Fake pointers that must stay compare-only**: `batch.cur_job = 0x1` (MPP
  init_trans_table), `pages[0] = (struct page *)import` (RGA kunit imports),
  fake `(struct device *)&token` devs (RGA iova_import_identity).
- **kunit-managed buffers that must not be krealloc'd**: MPP
  reg_offset_dma_bounds `reg_image.regs` stays safe only below the preset
  `reg_bytes`.
- 32-word RGA2 `cmd[]` buffers in six librga emit tests would overflow if ever
  pointed at the RGA3 emitter (writes to word 46).

## Boundary

Static audit only: reachability was traced by hand/agent, not exercised by a
KUnit run — the fix commit has not yet been boot-verified (rewrite-debug
rebuild in progress when this was written). The audit covered fixture-vs-callee
state, not assertion correctness (a test asserting the wrong value would pass
the audit). Line numbers are from linux-6.18-rkvenc @ e5867fa31ed2b; the
mainline mirror drifts.

## Exercise

- Oops triage: `journalctl -k -b 0 | grep -n "KASAN\|kunit"`, then match the
  KASAN NULL+offset against `pahole -C <struct> /sys/kernel/btf/vmlinux`.
- Compile gate: `kernel-drivers/tests/rewrite-build-gate.sh all`.
- Boot verification: next rewrite-debug boot must show
  `pass:84` / `pass:148` and `ok 1 rk_mpp_rewrite`, `ok 2 rockchip-rga-rewrite`
  (`rewrite-kunit-log-check.sh`).
