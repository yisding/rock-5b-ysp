# Rewrite lines rebased to Linux 6.18.64 and 7.4-rc3 with twenty driver-review fix commits

> Scope: both clean-room rewrite kernel lines (`rk3588-rewrite-6.18`,
> `rk3588-rewrite-mainline`), their MPP and RGA drivers, and the Rockchip IOMMU
> provider hook they call
> Source: Linux `v6.18.64@fd7cfd39c8859` and `v7.4-rc3@aebb72744764`; tips
> `rk3588-rewrite-6.18@a6fa1f545507` (was `7c38fc4ffaba` on `v6.18.51`) and
> `rk3588-rewrite-mainline@b153bd919515` (was `12a6a61b76ac` on `v7.3-rc2`)
> Date: 2026-11-22
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED. KUnit was compiled but not run, and
> there is no boot or hardware result for anything here. Nothing was packaged
> or uploaded. The ids above are the reference for this record; it does not
> track what the `linux-rock5b` fork holds (see [Result](#result)).

## Result

Both rewrite lines moved to their current upstream and then took twenty fix
commits from a full review of the driver surface. The review confirmed sixteen
findings, and every one of them now has a fix on both lines; one (F9) is fixed
only in part.

| Line | Was | Now | Local range | Rebase |
| --- | --- | --- | ---: | --- |
| Rewrite 6.18 | `v6.18.51` | **`v6.18.64`** | 445 replayed + 1 compile fix + 20 review commits = 466 | 1 conflict, 1 compile-only break |
| Rewrite mainline | `v7.3-rc2` | **`v7.4-rc3`** | 370 replayed + 20 review commits = 390 | 1 conflict |

**6.18 rebase.** All 445 commits replayed onto `v6.18.64`. The one conflict
was in `rk_iommu_enable()`: stable `08003cc005c8`
("iommu/rockchip: disable fetch dte time limit", upstream `8d4346ecd495`)
performs the `RK_MMU_AUTO_GATING` write the rewrite's provider commit also
added, so the rewrite's duplicate write and `#define` were dropped. This is the
same collision the [forward-port line](2026-11-22-forward-port-6-18-64-rebase-and-driver-review.md)
hit in patch `0005`. Stable `1b2f849cd572` ("iommu/rockchip: Clear stale page
faults before enabling stall") merged underneath without conflict.

The rebase then reported success on a tree that did not build. Stable
`11dfe2896ea2` (upstream `fd714986e4e4`) gave `attach_dev` a third
`struct iommu_domain *old` argument, and `vsi-iommu.c` is a file the series
adds, so nothing conflicted. New commit `9f59bfd5f3b7` ("iommu/vsi: take the old
domain in attach_dev callbacks") adds the argument to both VSI attach callbacks,
as the mainline branch already had. Only the compile caught it.

**Mainline rebase.** All 370 commits replayed onto `v7.4-rc3` with one conflict
in `rk_iommu_probe()`: upstream converted the `iommu->bases` allocation to
`devm_kzalloc_objs()`. The resolution takes upstream's allocation form and keeps
the rewrite's `rk_iommu_resolve_shared_domain_owner()` call and early
`platform_set_drvdata()`. No compile fix was needed. The `v7.4-rc3` tag was
fetched at depth 1, so upstream changes on that side were read from tree diffs,
not history.

Before the review commits, the rewrite payload (`mpp-rewrite/`, `rga-rewrite/`
and `include/uapi/linux/rk-mpp.h`) was byte-identical across both rebases and
between the two lines. After them it is again identical between the two tips:
tree objects `mpp-rewrite@abe53581756a`, `rga-rewrite@7f4edd6753ed`,
`rk-mpp.h@3e92b10c3e5a`.

The prior tips are preserved as branches
`ysp-backup/rk3588-rewrite-6.18-before-6.18.64-20261122` (`7c38fc4ffaba`) and
`ysp-backup/rk3588-rewrite-mainline-before-7.4-rc3-20261122` (`12a6a61b76ac`).
Those two ids are also what the `linux-rock5b` fork's `rk3588-rewrite-6.18` and
`rk3588-rewrite-mainline` held before this pass.

**Fork state.** When this record was written, neither the new tips nor the two
`-20261122` backup branches had been sent to the fork. That is a statement
about one moment, and this file is not updated when a push happens. Read the
fork's state from the fork: a branch there carries this work exactly when
`git ls-remote` on it prints the tip id above. Both branches were rebased, so
they do not fast-forward from the 2026-09-13 heads.

**Commit ids.** The first sixteen commits (seventeen on 6.18, counting the VSI
compile fix) were message-reworded once after they were written, to change the
attribution trailer to the kernel's form (see [Gates](#gates)). That changed
the id of every commit in the range, the four later ones included because
they sit on top, and both tips. It changed nothing else: each commit kept its
tree, author, dates and subject, and the tip trees are `2557cc03a5bb`
(mainline) and `a620521369fa` (6.18) before and after. The ids in this file are
the post-reword ones. Ids recorded by the first revision of this file
(repository commit `d02ebc0`) no longer name a commit on either branch.

## Driver review

The review ran against a frozen snapshot of the rebased tips. 23 range readers
covered every line of `mpp_rewrite.c` and `rga_rewrite.c`, KUnit regions
included. Eight cross-cutting reviewers then read the same code by concern:
the MPP and RGA userspace boundaries, MPP and RGA concurrency, lifetime and
power management, IOMMU and device tree, parity with the forward-port fixes,
and hardware programming. Every finding the reviewers ranked above low was
handed to two independent refuters, with a tie-break when they disagreed.
Sixteen findings survived and one was rejected. The survivors keep their review
numbers, F1 to F17 with no F11.

Two of the fixed defects are kernel memory-safety defects that a
`/dev/mpp_service` or `/dev/rga` user could reach: a job lifetime error on the
encoder completion path, and unbounded recursion in the RGA dispatcher. Two
more leave DMA untranslated after a reset if an unmeasured hardware premise
holds. The forward-port review of the same day found nothing in that class,
which is a fair measure of how much less runtime this code has had.

### Fixed

Commit ids are the ones on the final branches; the 6.18 ids differ because the
series was cherry-picked there. `git range-diff` shows eighteen commits
identical and the two provider commits differing only by context and one
forward declaration (below).

The fixes landed in two passes. Twelve commits and their four follow-ups came
first. F10, F13, F14 and F17 were written and build-clean at the same time but
could not be committed then (see the hook note under [Gates](#gates)); they
were re-read against the moved tip, applied with line offsets only, and
committed afterwards in the order F17, F13, F10, F14.

| Item | Mainline | 6.18 | Defect | Reach |
| --- | --- | --- | --- | --- |
| F1 | `80f3383b592e` | `a31d85a68943` | Four RKVENC2 completion paths released the DCHS lifecycle mutex through the job after the call that can drop the job's last reference. The lock helper now returns the mutex, which lives in the service. | unprivileged; every hardware encode completion |
| F2 | `6ff7ec809ab8` | `bb814aed53a0` | The RGA2-to-RGA3 reroute branch of `rk_rga_hw_dispatch()` called itself instead of continuing its loop, so stack depth grew with each consecutive rerouted job. | unprivileged, where an RGA2 DMA-BUF mapping fails with `-EIO` |
| F3 | `47882baa895a`, `a3e101eacd66` | `058f7c39d799`, `2f80f488c7f5` | After a recovery reset the Rockchip-provider "refresh" was only a TLB zap. It never rewrote `DTE_ADDR` or the interrupt mask, never re-enabled paging and could not fail, while autosuspend and cluster power leases keep the MMU resumed between jobs. New export `rockchip_iommu_restore()` runs the provider's disable-then-enable sequence; RKVDEC2 and RKVENC2 call it after every driver reset, and a failure quarantines the core. | unprivileged, conditional on a reset clearing the embedded MMU (unmeasured) |
| F4 | `a4a0f7f46ae9` | `c4d6bf6224b6` | Same defect on RGA3: `rk_rga_hw_refresh_iommu()` was a void TLB zap, and the next queued job can start before the supplier MMU is runtime-suspended. It now calls `rockchip_iommu_restore()`; a failed restore quarantines the core but still retires the recovered job, because the reset did stop DMA. | unprivileged, same hardware premise |
| F5 | `9628337ec52f` | `c31d0cbc7c96` | Address validation ran on the job's register image, but only the caller's `SET_REG_WRITE` spans reach MMIO and a core's register file is not cleared between jobs. An address register or format selector left out of every span kept the previous job's value. The driver now programs every kernel-validated word no span carried. | unprivileged; another session's DMA buffers in the same codec domain, not kernel memory |
| F6 | `615ff6503f9b` | `12116b24e7f1` | Session close and `RESET_SESSION` completed every job not on hardware regardless of who owned it, so a job in flight to completion, in dispatch, or in a queue sweep could be completed twice. Whoever unqueued a job now owns its completion until it reaches hardware. No new state. | unprivileged; also an abrupt process exit |
| F7 | `799e96ecef84` | `58490b99833f` | A non-blocking buffered `POLL_HW_IRQ` could copy out the final slice record and still return `-EAGAIN`, so a caller that retried lost the end-of-frame record. The final record now stays queued until the job is complete. | unprivileged, own session only |
| F8 | `09669ae5e20e` | `a2ddadcda83e` | RGA2 validation enforced none of the RGA2E limits `ABI.rst` documents: the 2x2 floor, the 4096x4096 destination, and the 1/16x..16x scale range. Out-of-range work was programmed, and large destinations could be load-balanced onto RGA2. No out-of-bounds DMA was involved. | unprivileged; also ordinary >4K work under load |
| F9 | `92909b4216b3` | `829e05e84693` | **Partly fixed.** Close and `RESET_SESSION` pulsed the reset lines of a healthy mid-frame engine. They now wait for the frame on every core (see F12). The timeout, IOMMU-fault and error-IRQ paths still pulse with no engine-level stop; see below. | unprivileged |
| F10 | `8b6a11879984` | `00d05f80afe9` | `rk_rga_add_userptr_shadow()` allocated the USERPTR boundary shadow page without `__GFP_ZERO` and only the imported window is filled, but the whole page is device-addressable. It is now allocated zeroed. Whether an engine ever reads the slack was not established. Adds one KUnit case. | none on a shipped configuration: `init_on_alloc` already zeroes the page |
| F12 | `36b107ee45c0` | `8bfeaf4689b9` | AV1 recovery is terminal by design, so closing or resetting a session mid-frame removed hardware AV1 for every user until reboot. Close and reset now wait up to 1 s for the frame to retire through its IRQ or watchdog, and reset only if it does neither. | unprivileged |
| F13 | `d4af2f9b385d` | `7f68dcce4c90` | `rk_mpp_hw_shutdown()` reset only the owner core and retired a hard-CCU job on a core-only proof, though the coordinator may be running the descriptor on a peer. New `rk_mpp_hw_shutdown_hard_ccu()` puts a coordinator stage in front of the per-core abort, as remove and recovery have: stop the chain, abort the dependents on the group proof, then retire the shutting-down core's own job under the same lock. A failed stop feeds the existing retry loop. Extends one KUnit case, adds none. | shutdown or kexec with a hard-CCU decode in flight; latent on ROCK 5B, which selects soft CCU |
| F14 | `b153bd919515` | `a6fa1f545507` | An RGA2 line-only interrupt was acknowledged with the full clear mask, so a completion or error that latched during the handler was cleared unseen and the job waited out the watchdog. The line-only branch now strobes only the two line clears; the completion and spurious paths keep the full mask. Rests on the unverified assumption that the clear bits are independent write-1 strobes. Adds one KUnit case. | an RGA2 job that requests line interrupts; fail-safe, the job times out |
| F15 | `24ada6c9089c` | `79e74494c414` | Already-admitted asynchronous RGA work that became runnable while its core was system-suspended completed with `-ENODEV` or `-EBUSY` instead of waiting. It now parks on the core and runs at resume; a failed resume fails it with `-EIO` behind a new `resume_failed` flag. | a system suspend with async RGA work in flight |
| F16 | — | — | Closed by the F6 commit, which rewrote the file-release KUnit fixture: the activation is now initialised and the path no longer reaches the completion call that needed a full service. | KUnit only |
| F17 | `60c4652507ac` | `68de73450fe9` | `rk_mpp_cluster_recovery_result_kunit` and `rk_mpp_cluster_reset_group_kunit` never initialised `hw->regs_lock`, which every reset transaction now takes to revoke the register lease. Under `PROVE_LOCKING` the first acquisition should turn lockdep off for the rest of the boot and fail the compound KUnit gate. Four `raw_spin_lock_init()` calls, plus assertions on the reset epoch each revocation records. Changes two cases, adds none. | KUnit only |

Each first-pass fix was then reviewed by an agent that had not written it. Four
came back clean and four with notes that are recorded below. Three needed
changes, which produced four follow-up commits:

| Follow-up | Mainline | 6.18 | Change |
| --- | --- | --- | --- |
| F3 | `8948a6d31a91` | `9b2013062f60` | The first F3 commit also ran the full restore on the idle IOMMU-fault path, where no reset had happened; in hard-CCU mode that could cycle an MMU through paging-off under a peer's live DMA. The restore now runs only behind a driver reset, and the idle-fault path keeps the old flush. |
| F3 | `66eb3bf7169a` | `563d4b972dcd` | A restore failure isolates the whole IOMMU group, which on ROCK 5B is both decoder cores, until reboot. Each provider handshake is a single 1 ms poll, so `rockchip_iommu_restore()` now makes two passes before it reports an error. |
| F5 | `a439db6a5575` | `d22d4965cf37` | AV1 word 321 selects AFBC output but was not in an address table, so it was not owned. It now is, together with geometry words 4, 8 and 503 when the image selects AFBC. |
| F7 | `83efa82fac11` | `228079480654` | The F7 commit left `rk_mpp_job_pop_rkvenc_slice()` with no caller outside the KUnit block, which is an unused-function warning when the KUnit option is off. Marked `__maybe_unused`. |

The 6.18 port of the provider commit needed one adaptation. That tree defines
`rk_iommu_from_dev_checked()` below `rk_iommu_ops`, so `058f7c39d799` adds a
forward declaration ahead of `rockchip_iommu_restore()` and says so in its
message. The first 6.18 cherry-pick failed to build without it; the port was
redone so that no 6.18 commit is left unbuildable.

The four second-pass fixes were reviewed the same way after they landed. All
four verdicts were clean, with nits only, so they have no follow-up commits;
the nits are under [Reported but not changed](#reported-but-not-changed).

### Contract of `rockchip_iommu_restore()`

`int rockchip_iommu_restore(struct device *dev)` takes the **master** device,
not the MMU. It is declared in `include/soc/rockchip/rockchip_iommu.h` with an
`-ENODEV` stub.

- It sleeps, and it manages the MMU's own clocks.
- Hardware is touched only under `pm_runtime_get_if_in_use()` on the MMU. If
  the MMU is not in use it returns 0, because runtime resume will program it.
- The caller must already have stopped the master's DMA and released its reset
  lines, and must serialize against domain attach and detach on that IOMMU
  group. MPP takes `dma_group_lock` for this; the RGA3 MMUs are single-device
  groups.
- It programs only the MMU of `dev`. A second MMU that shares the domain
  through `rockchip,shared-domain-owner` needs its own call.
- 0 means translation is restored, the MMU is not runtime-active, or `dev` is on
  the identity domain. `-ENODEV` means `dev` is not served by this provider. Any
  other error means the MMU must be assumed not translating.

### Behaviour changes

No UAPI layout changed. Both `ABI.rst` ledgers were updated in the first-pass
commits that changed behaviour, and
[rewrite-drivers](../kernel-drivers/docs/rewrite-drivers.md) carries the
maintained summary. The four second-pass commits touch only `mpp_rewrite.c` and
`rga_rewrite.c`, so neither ledger mentions the last three items below.

- **Close and `RESET_SESSION` can block.** On every MPP core they wait up to
  1 s per on-hardware job, uninterruptibly and with no lock held, before
  falling back to the old reset. A job the scheduler worker had already taken
  is cancelled but may complete a moment after the call returns.
- **Sparse register spans.** The format selector, every register of the
  selected and custom address tables, RKVENC2 DCHS word 193, and the AV1 AFBC
  decision words always follow the job's own image, as zero where the image
  does not reach. No job is newly rejected. For libmpp the only new MMIO is
  RKVDEC words 198 and 199 written as zero on each decode.
- **Restore failure is a new quarantine cause** on RKVDEC2, RKVENC2 and RGA3.
  `iommu_refresh_count` now counts real restores.
- **Non-blocking slice polls** return success with bit 31 only when the
  completion was consumed in the same call.
- **RGA2E envelope.** Windows below 2x2, RGA2 destination windows above
  4096x4096, and per-axis ratios beyond 16x are refused for RGA2. A large
  `BITBLT` destination becomes RGA3-only; RGA2-only operations of that size
  fail. This matches the vendor table, not a measured hardware limit.
- **Suspend parks work** instead of failing it.
- **Hard-CCU shutdown stops the coordinator first.** Dependents now complete
  with `-ESHUTDOWN` and the shutdown transition. A coordinator that can be
  neither stopped nor isolated holds shutdown in the existing retry loop,
  where the old code would have released the job. An invalid cluster falls
  back to the per-core abort. Soft-CCU clusters, direct cores and an idle
  coordinator are unchanged.
- **An RGA2 line-only interrupt leaves completion and error flags latched**,
  so the level interrupt fires again and the ordinary completion path handles
  them.
- **USERPTR shadow pages start zeroed** whatever `init_on_alloc` says.

### Gates

- **Build.** `W=1` over `rockchip-iommu.o`, `vsi-iommu.o`, `mpp_rewrite.o`,
  `rga_rewrite.o` and the ROCK 5B DTB, both KUnit options `=y`, native gcc 15.2:
  zero warnings on both final tips, and after each of the four second-pass
  commits on mainline. `rewrite-build-gate.sh all` printed
  `[6.18/normal] PASS: clean rewrite object build at a6fa1f545507` and
  `[mainline/normal] PASS: clean rewrite object build at b153bd919515`. Only the
  `normal` profile ran. A by-hand `W=1` build of mainline with both KUnit
  options off was warning-free after the first sixteen commits and was not
  repeated after the last four. The gate's `test-disabled`, `memory` and `race`
  profiles and the ABI-mutation gate were not rerun at all.
- **Trailer.** Every commit carries exactly one
  `Assisted-by: Claude:claude-fable-5-2` and no `Signed-off-by`. That is the
  kernel's `AGENT_NAME:MODEL_VERSION` form, not this repository's
  `Assisted-By:` form (see the
  [contribution-policy finding](2026-08-02-mainline-tool-assisted-contribution-policy.md)).
  The first sixteen commits were written with the repository form and reworded
  on both branches; the tip trees are unchanged by the reword.
- **checkpatch.** `--strict` finds no code-style problem on either line. The
  two lines disagree about the trailer, because they carry different
  `scripts/checkpatch.pl`:
  - 6.18 (21 commits): one `Missing Signed-off-by` error per commit, and one
    75-column commit-description warning on the VSI compile fix
    `9f59bfd5f3b7`, which quotes a compiler error line. Its checkpatch knows
    the `Assisted-by` form and accepts the trailer.
  - Mainline (20 commits): two errors and one warning per commit. Besides the
    missing `Signed-off-by` they are `Unrecognized email address:
    'Claude:claude-fable-5-2'` and `Non-standard signature: Assisted-by:`. The
    `checkpatch.pl` at `v7.4-rc3` in this checkout has no `Assisted-by` entry
    in its signature tags, and the branch does not modify that script.

  So the trailer is settled as far as the policy document goes, but mainline
  checkpatch is not quiet about it. Changing that means a different trailer or
  a checkpatch change, and is a decision for the owner.
- **KUnit manifest.** Seven cases were added and none removed, so the manifest
  is now **112 MPP + 156 RGA = 268** (was 109 + 152 = 261). The first pass
  added `rk_mpp_job_write_regs_owned_words_kunit`,
  `rk_mpp_session_poll_irq_nonblock_last_kunit`,
  `rk_mpp_hw_abort_defers_to_frame_kunit`,
  `rk_rga2_envelope_backend_mask_kunit` and
  `rk_rga_queue_on_suspended_hw_kunit`; the second added
  `rk_rga2_line_irq_ack_kunit` and `rk_rga_userptr_shadow_zeroed_kunit`. They
  land mid-list, so the manifest was regenerated and later ordinals shift.
  `kunit-manifest-check.sh` returns 0 against both tips.
- **Source audits.** Ownership passes at **2,326 signals/tree** (the baseline
  before this pass held 2,312). The first sixteen commits took it to 2,321: 30
  new and 21 absent, each absent one paired with a new one from a changed line.
  F13 took it to 2,326: seven new and two absent, five of the new ones in
  `rk_mpp_hw_shutdown_hard_ccu()` and two replacing reworded lines in
  `rk_mpp_hw_abort_ccu_dependents()` and `rk_mpp_hw_shutdown()`. Fixture debt
  passes at **313/tree** (was 306): six signals from the first pass, and one
  `manual-list-link` where F13's extended case lists the coordinator the way
  the fixture already lists both cores. The writer inventory is unchanged at
  118. Cross-tree identity passes. The ownership and writer baselines pin
  both tip ids, so any further rewrite of either branch needs a re-pin.
- **Audit script edit.** The ownership audit hard-codes owner allowlists that
  `--update-baseline` cannot change. Two new accessors were added to them after
  reading both: `rk_mpp_job_outcome_finalized_locked()` is a read-only check
  under `session->lock`, the lock the flag is set under, and
  `rk_mpp_job_write_owned_word()` is called only beneath the already-listed
  `rk_mpp_job_write_regs()` and reads the same selected core.

The kernel repository's pre-commit hook compares the staged KUnit case array
with this repository's manifest. It refused every commit that touched a driver
file after the first new case landed, which is why F10, F13, F14 and F17 waited
for a second pass. The manifest now matches both tips, so the hook passes
again. Regenerate it before any commit that adds a case.
`kunit-manifest-check.sh --regenerate <tree>` prints to stdout: capture it to a
scratch file and copy that over the manifest, because the script reads its
suite list from the file a direct redirection would truncate.

### Reported but not changed

Recorded so the next pass does not re-derive them.

**Nits from the second-pass reviews.** None blocked a commit and none was
acted on.

- **F10.** The new case cannot fail on a kernel with `init_on_alloc`, which is
  every configuration the driver ships in, so it proves nothing until it runs
  without it. Its fixture leaves `view.rga` NULL.
- **F13.** The extended case covers only the idle-coordinator gate, not the
  stop-and-retire branch. `remove()` still retires its own core's hard-CCU job
  on a core-only proof after the coordinator stop; the review of the first
  pass reported that and F13 did not change it.
- **F14.** The commit message's last paragraph says a late flag left latched on
  the completion path "could be charged to the next activation". It could not:
  `rk_rga2_execution_publish_and_start()` clears the full mask before every
  start. The code is right and the stated reason is imprecise. The message was
  left alone because rewording it moves both tips and the baseline pins again.
- **F17.** There is still no shared helper that initialises a fixture's
  hardware object, so the next lock a production path starts taking can be
  missed the same way. The new reset-epoch expectations (1, then 2) are read
  from the code, not observed.

**Left open on purpose.**

- **F9 remainder.** Timeout, IOMMU-fault, encoder error-IRQ, remove, shutdown,
  and an abort whose wait expired still assert the CRU reset with no
  engine-level stop. The vendor RKVENC2 safe-clear and RKVDEC2
  soft-reset-plus-bus-idle steps were not added, because they are new MMIO on
  paths that could not be booted. They need a hardware A/B, with a handshake
  failure treated as unproven quiescence. Remove and shutdown could take the
  same bounded wait as close with no MMIO at all.
- **Decoder self-reset path.** A status outside `err_mask`, such as the
  bus-error bit, completes the job with no driver reset and so no restore. If
  that self-reset clears the MMU, the next job inside the autosuspend window is
  unprotected. `ABI.rst` now states this. The
  [2026-08-01 finding](2026-08-01-rkvdec-self-reset-and-iommu-restore-gaps.md)
  says to measure before widening the mask.
- **RGA probe-time reset.** `rk_rga_hw_probe()` pulses the same reset lines with
  no restore afterwards. The supplier MMU is dropped only asynchronously after
  probe, so a job routed to a newly probed core can beat it.
- **Parked RGA work holds its release fence unsignalled across the sleep.** If
  that fence gates a device that drains before suspending, such as a KMS
  `IN_FENCE_FD`, that device's suspend can block. No known client chains RGA
  fences into KMS. `ABI.rst` does not say this yet.
- **AV1 L2 cache block.** A job with no write span in the cache class inherits
  the block's state, and only IRQ completion clears it; the timeout and reset
  paths do not.
- **Other kernel-patched words** (soft-CCU words 13, 28 and 32, the RKVENC
  slice-split fix-up) still reach hardware only inside a span. Omitting them
  affects only the caller's own job.
- **F7 concurrent pollers.** Two threads polling one session can still see
  success with bit 31 in a call that did not consume the completion.

**Reported at low confidence and not adversarially verified.** Driver code:

- AV1 AFBC geometry from caller registers can reach an unconditional
  `WARN_ONCE` in `rk_mpp_av1_afbc_required_span()`. Make it a one-shot message
  or a counter.
- The MPP ioctl can return `-ERESTARTSYS` after control commands earlier in the
  same batch have run; the restart guard counts only submissions and poll
  progress. The RGA synchronous acquire-fence wait has the same shape after the
  legacy path has closed the caller's acquire fd. Reviewers disagreed on
  whether `REQUEST_SUBMIT` is affected.
- `rk_mpp_hw_timeout_work()` does not compare the activation's watchdog
  deadline with `jiffies`, so a worker that started late can time out the next
  job.
- `rk_rga_job_queue_on_hw()` dispatches on a core after handing its only
  reference to the job (unbind race). `rk_rga_hw_remove()` and shutdown cancel
  the fault work without draining `iommu_fault_events`, leaking the references
  each event holds.
- The RGA3 hard IRQ overwrites per-activation status on re-entry instead of
  accumulating it, so an error followed by frame-done can be reported as
  success.
- `rk_mpp_hw_suspend()`'s busy check misses a job the scheduler has dequeued
  but not installed. This is the MPP analogue of F15.
- `rk_iommu_zap_iova()` and `rk_iommu_flush_iotlb_all()` gate on
  `pm_runtime_get_if_in_use()`, which is false while the MMU is powered with a
  zero usage count; `vsi-iommu` uses `get_if_active`. RKVENC2 submit also lacks
  the pre-start flush that RKVDEC has.
- The failed-reroute exit of `rk_rga_hw_dispatch()` returns without draining the
  queue. A one-line `continue`, sibling of F2.
- `/dev/mpp_service` is registered before procfs creation, which can fail
  (modular builds only).
- Soft-CCU decoder cores are reset without the `CORE_IDLE`/`CORE_ERR` bracket on
  the unbind, shutdown and CCU-dependent abort paths.
- Explicit-IOVA session affinity clears only when the whole import list is
  empty, not when the last explicit mapping goes as `ABI.rst` says.
- `rk_rga2_execution_publish_and_start()` dereferences the pre-interrupt
  pointer before its NULL guard (latent).

KUnit fixtures, all read rather than run. Several predict a failed or noisy
first boot of the suite at these tips, independent of driver behaviour. F17,
which was the first of these, is fixed; the rest are not:

- `rk_mpp_session_poll_irq_nonslice_kunit` expects success from a job whose
  register builder was never sealed. Two readers reached this independently.
- `rk_mpp_rkvdec2_link_table_ownership_kunit` asserts a next pointer on a node
  that is never staged.
- `rk_mpp_hw_prepare_active_retry_kunit` lacks `hw->srv`, `hw->match` and an
  initialised `ccu_recovery_lock`, so a regression would oops instead of fail.
  It and two other cases use `KUNIT_ASSERT_*` while holding `run_lock`.
- `rk_mpp_reset_session_hw_active_import_kunit` still uses a bare service whose
  `sched_work` was never initialised. The F6 commit rewrote the three sibling
  fixtures with the same lag.
- RGA multi-task emitter fixtures check `cmd_ready` on the retired first
  execution; `rk_rga_legacy_blit_sync_wait_kunit` expects storage release from
  a `RETIRED` execution; `rk_rga3_multitask_emit_clears_stale_regs_kunit` calls
  the emitter without a published plan; two pending-acquire cases race the
  worker's final put; and the direct-emitter fixtures leak every task plan they
  build, which lands in the kmemleak gate.

**Rejected or already known.** The one rejected finding was `spinlock_t`
`hw->lock` nested inside raw `regs_lock` in the hard-IRQ lease helpers. The
code facts are right, but it is the documented, deferred `PREEMPT_RT` limitation
and no shipped configuration reaches it. Not re-reported because the
[2026-08-02 adversarial review](../kernel-drivers/docs/rewrite-driver-adversarial-review-2026-08-02.md)
already records them: unbounded per-session job, import and request admission
in both drivers, and MPP imports that outlive an unbind of their DMA device.

### Forward-port parity

Each defect the forward-port review fixed or reported the same day was checked
against the rewrite.

| Forward-port item | Rewrite verdict |
| --- | --- |
| `0098` compat record size | Does not apply. The record is a fixed 24 bytes with a `u64` pointer, and compat uses the native handler in both drivers. |
| `0099` stale IRQ status on timeout | Does not apply. The IRQ record is epoch- and generation-tagged and cleared on every claim. |
| `0100` worker stops draining | MPP does not apply. RGA has one analogous branch: the failed-reroute exit above. |
| `0101` unbind under live sessions | Does not apply. Both removes abort work, retry until DMA is stopped and wait for refcounted references. |
| `0102` register-buffer leak | Does not apply. One job-release function frees every region. |
| `0103` device node before init | The lock and list defect does not apply. The procfs ordering item above is the residue. |
| `0104` palette-mode shift | Does not apply. The value is range-checked before the shift. |
| `0105` uninitialised version copy | Does not apply. Whole-struct copy of zero-initialised state with no padding. |
| `0106`/`0107` translation lost after reset | **Applied, in a stronger form**: F3 and F4. The forward-port at least re-enabled after reset; the rewrite only zapped the TLB. |
| Encoder input cache maintenance | The same untested hypothesis applies equally. No new evidence. |
| Shared domain, raw addresses | Largely does not apply. Raw IOVAs and offsets are validated against the session's retained imports. The domain is still shared per codec, and F5 was a way around that validation. |
| RGA offset admission | Does not apply. Offset plus active size is bounded per axis. |
| Unbounded per-session allocation | Applies; already recorded as open. |
| Legacy RGA2 MMU ring | Does not apply. Page tables are per-execution allocations. |
| RKVDEC2 secondary-core probe window | Does not apply. A core is listed only at the end of probe. |
| RKVENC2 IRQ before `hw_info`, IEP2 IRQ clearing | Does not apply. Hard IRQs are gated on the register lease, and there is no IEP2 backend. |
| One-way `RESET_SESSION`, counter underflow | Does not apply. |

## Boundary

- **Nothing ran.** No kernel from either tip was booted. KUnit was compiled but
  not executed: `qemu-system-aarch64` is not installed on the build host, and
  the suites depend on `ARCH_ROCKCHIP`. Every fix, every new and rewritten
  KUnit case, and every race this finding describes is argued from the code.
  None of the original defects was reproduced. That includes the seven new
  cases, the extended abort-dependents case, the F17 epoch assertions, and the
  F13 and F14 hardware behaviour.
- **No package exists for these tips.** No composite was rebuilt on a fresh
  Armbian layer, nothing was uploaded, and the published rewrite alphas are
  still the 2026-09-13 ones on `v6.18.51` and `v7.3-rc2`.
- **The MMU premise is unmeasured.** Whether the reset pulse clears the
  embedded MMU on vdec, venc or RGA3 has never been read back. The restore is
  correct either way, but it adds a disable-then-enable on a live MMU after
  every recovery reset, and a poll that times out twice now quarantines the
  core. For the shared vdec group that is both decoder cores until reboot,
  where the old code would have carried on.
- **Three fixes trade a failure for a wait.** Close and reset can block for
  1 s; the completion-owner rule means a lost completion would stall an RKVDEC
  session instead of being rescued by the abort; and resume can now start a
  parked RGA job from a PM callback. None has been exercised.
- **Hard-CCU paths** were read by the range readers but only skimmed by the
  cross-cutting reviewers, and `dma-iommu.c` and parts of `vsi-iommu.c` were
  not reviewed. The cross-cutting reviewers did not read KUnit regions.
- The gate ran one build profile of four per line.

**Next gate.** Fix or accept the fixture items predicted to fail. Rerun the
three build profiles the gate skipped. Build a composite for each tip and boot
the 6.18 one under KASAN and lockdep, requiring all 268 cases and a fatal-free
interval. With that kernel, read `DTE_ADDR`, `STATUS` and `INT_MASK` of the vdec
and RGA3 MMUs after a reset pulse and after the restore, then run the
reset-contention gate watching `iommu_refresh_count` and
`recovery_failure_count`, a close and `RESET_SESSION` loop against active decode
and encode with the warning scan on, and a suspend cycle with asynchronous RGA
work in flight.
