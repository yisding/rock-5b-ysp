# Rewrite conformance-gap audit — 2026-07-17

This audit asks a narrower question than the driver design review: can the
current validation machinery prove the behavior the RK3588 MPP and RGA rewrite
drivers claim? It compares the 6.18 and mainline rewrite pins with the current
forward-port ABI, pinned Rockchip MPP/librga consumers, debugfs instrumentation,
and the final evidence gate.

## Result

No additional missing live ioctl family was found. The MPP rewrite covers the
forward-port command families used by current MPP, including RCB, session-fd,
and hardware-IRQ polling; its extra error-reference command is a newer
compatibility extension. The RGA rewrite covers the live librga request/import,
version, result, flush, and blit surface. The old RGA2 `0x60xx` blit ioctls
remain dormant under the existing caller audit rather than silently becoming a
new compatibility claim. Raw physical-address RGA import remains an intentional
rewrite rejection, and AV1 remains a separate backend rather than part of the
RKVDEC2 rewrite.

The audit did find six proof gaps. Five are now executable gates in this repo;
one requires more driver instrumentation.

| Gap | Why the old evidence could pass incorrectly | Resolution |
|-----|---------------------------------------------|------------|
| Compiled or stale KUnit was treated as current green KUnit | The build profiles enabled both suites, but nothing read the booted results; an unrelated older report could also be combined with newer suite logs. Exact KTAP later proved insufficient because a fixture warning could disable lockdep while its case still reported `ok`. | [`rewrite-kunit-log-check.sh`](../tests/rewrite-kunit-log-check.sh) requires exactly 84 MPP and 148 RGA cases (the compile-time-owned MPP ABI-layout case was retired from the preceding 85/148 tip), with no failure or skip. It also scans the complete boot KUnit interval with the shared fatal regex and requires live lockdep. The profile runner persists both reports, and the evidence audit requires the run ID matching every selected rewrite-candidate suite. |
| Userspace success could hide a kernel warning | Main suites saved only a dmesg tail; they did not compare or gate new messages. | All five suite wrappers now capture before/after dmesg, isolate new lines across ordinary growth or ring wrap, and reject KASAN/KCSAN/UBSAN/KFENCE, Oops/BUG/WARNING, lockdep/RCU/hung-task, DMA-API, and MPP/RGA/IOMMU fault signatures. The evidence audit requires a clean `dmesg-scan.tsv` on both profiles. |
| Error and idle counters were under-specified | Timeout/fault checks omitted recovery failure, spurious IRQ, RGA2 config error, and boundary-shadow setup failure; a missing safety counter looked like a zero delta; zero-after checks covered only imports. | Default forbidden deltas now include those safety counters and rewrite audits require every listed counter for each component captured by a suite to be present. Rewrite suites also require `mpp:queued_job_count`, RGA import and boundary-shadow active gauges, and the direct librga userptr-IOMMU active gauge to return to zero. The latter uses `*:active` so both `userptr_iommu` and legacy `route_b` debugfs names work. |
| The direct MPP evidence could be `mpp_info_test` only | Plugin/FFmpeg coverage exercises codecs, but does not prove the official MPP multi-thread, multi-instance, and rate-control paths selected for parity. | Normal evidence audits selecting MPP now require a representative named core matrix on both profiles and a nonempty checksum artifact for every media case. Decode evidence therefore needs `MPP_DUMP_OUTPUTS=1`. `REQUIRE_MPP_CORE_CASES=0` is an explicit relaxation for old/exploratory logs. |
| A claimed RK3588 codec had no selectable case | Pinned MPP advertises VDPU381 AVS2 and the rewrite has the AVS2 translation table, but `mpp-suite.sh` only named H.264/H.265/VP9. | Added `mpi_dec_avs2`, `mpi_dec_mt_avs2`, `mpi_dec_multi_avs2`, and `vpu_api_dec_avs2`; basic AVS2 is in the final core evidence set. An AVS2 stream is still a hardware input requirement. |
| Successful encode did not prove low-delay slice polling | Ordinary encode can complete without `MPP_CMD_POLL_HW_IRQ`, leaving the recently fixed multi-slice path hardware-untested. | Added required H.264/H.265 low-delay CTU-split official-MPP cases. They use `mpi_enc_mt_test` so callbacks are consumed concurrently, set `split_mode=2`, `split_out=1`, and a safe tunable `MPP_ENC_SPLIT_ARG` (default 120), and traverse slice polling on hardware. Error-terminal behavior still needs deliberate fault injection. |

Device-free parser, dmesg, counter, comparator, case-builder, and evidence-audit
selftests cover the new wiring. They prove that the gates reject bad fixtures;
they are not substitutes for a booted RK3588 run.

## Addendum — 2026-07-22: forward-port RGA bugfixes ported to the rewrite

Auditing the 21 forward-port fixes `0049`–`0069` against the rewrite found that
most are dissolved by the rewrite's architecture (system-IOMMU mapping, per-job
device selection, un-refcounted requests with idempotent IDR retire, plane
handles resolved to IOVA integers, full-validator core containment). Five real
defects remained and were ported to both rewrite tips as
`linux-6.18-rkvenc@8469183da227` (6.18) and `linux@9ff18809b5e0` (mainline):

| Fix | Site | Forward-port analogue |
|-----|------|-----------------------|
| First-job `rk_rga_job_put(NULL)` deref (pre-existing crash, not a port) | `rk_rga_job_put()` gains a NULL guard; `rk_rga_hw_schedule_timeout()` puts a NULL previous-timeout job on every first arm | — |
| 10-bit semi-planar chroma offset inside the Y plane | `rk_rga_img_layout()` derives Y/UV byte sizes from `compact_mode` (×10/8 compact, ×2 incompact) | `0049` |
| Multi-entry dma-buf imports >64 KiB spuriously rejected | `rk_rga_hw_probe()` sets a 4 GiB `dma_set_max_seg_size` | `0050` sub-item |
| Import reference released twice on plane-arithmetic failure | `rk_rga_materialize_img_import()` resolves all plane addresses before appending the import to `imports[]` | `0067` class |
| Acquire-callback vs abort UAF (session-close race) | `rk_rga_job_cancel_acquire_callbacks()` reports the zero-crossing; abort queues the acquire work only when its own decrement crossed zero | `0052` class |

The two new RGA KUnit cases (`rk_rga_layout_yuv10_kunit`,
`rk_rga_acquire_abort_queues_last_kunit`) raised the RGA suite to 122 and the
booted-report requirement to 208 at these tips. **Both tips are now superseded**
— see the 2026-07-23 addendum below for the current `1fe46df`/`ec9a4a06`
recovery-hardening tips, updated case counts, and the clean-source gate run.
Both armbian packaging branches predate these tips and pick the fixes up on
their next rebuild from tip, per gate 1 below.

## Addendum — 2026-07-23: recovery hardening + clean-source gates re-run

The rewrite drivers were hardened one commit further, to
`linux-6.18-rkvenc@1fe46df86f1ca` (branch `rk3588-rewrite-6.18`) and
`linux@ec9a4a06ecf12` (branch `rk3588-rewrite-mainline`); the two rewrite
sources remain byte-identical across the branches. The single
`media: rockchip: harden rewrite driver recovery` commit is a large churn
(~9,000 insertions / ~4,900 deletions across both `.c` files, restructuring the
import/extent bookkeeping and recovery paths). Its KUnit surface changed: MPP
went 86 → **85** and RGA went 122 → **147**, then **148** when the shared-IRQ
policy gained a dedicated case (booted-report requirement
85 + 147 = **232**). The repo gates were updated to match in the same-day repo
commit `77ebbca` (`rewrite-kunit-log-check.sh`, `rewrite-evidence-audit.sh` now
require `rk_mpp_rewrite:85 rockchip-rga-rewrite:148`); the prose counts of 208/122
elsewhere are historical.

The `normal`/`memory`/`race` clean-source build gates
([`rewrite-build-gate.sh`](../tests/rewrite-build-gate.sh)) **were re-executed at
these tips on 2026-07-23 and all six pass clean** (no compiler warnings under
`FAIL_ON_WARNING=1`): 6.18 `1fe46df86f1ca` normal/memory/race and mainline
`ec9a4a06ecf12` normal/memory/race, each building the Rockchip IOMMU provider,
both rewrite objects with KUnit, and the Rock 5B DTB from a clean `git archive`.
This closes the "clean-source gates not re-executed" caveat above. A KASAN
rewrite image **at this tip was also built** on 2026-07-23 — Armbian debug build
`P3695-C9fc5` (`CONFIG_KASAN=y`, `ROCKCHIP_MPP_REWRITE`/`RGA_REWRITE=y`, vendor
MPP/RGA off), confirmed to carry the `0239` recovery-hardening commit by the
symbols `rk_rga_dmabuf_extent_cmp` and `rk_rga_get_map_hw_for_import` in its
`System.map` (both introduced by `1fe46df`, absent in parent `8469183`). **The
booted KUnit run and every hardware gate in the next section remain open** — that
image has not been installed, booted, or run on the ROCK 5B (no captured
then-current 232-case KUnit report or hardware evidence), so this large recovery-hardening
churn is *only* compile- and unit-scaffold proven, never exercised on hardware.

## Remaining gaps and hardware gates

### RGA fence cleanup is not directly observable

`rk_rga_rewrite/release_fence_count` is a cumulative allocation counter. It is
useful as positive proof that the direct librga async/fence cases traversed the
release-fence path, but it is not an outstanding-reference gauge and must not be
required to return to zero. The driver needs a separate active-fence counter,
incremented at allocation and decremented from the fence release callback, before
the conformance runner can directly assert fence cleanup. Until then, use the
async/fence artifacts plus KASAN/KMEMLEAK, process-fd baselines, and close/reset
stress; do not mislabel the cumulative counter as a leak gauge.

### Required board runs

The following cannot be closed by repository selftests:

1. Boot KASAN and KCSAN rewrite kernels, persist the 232-case green KUnit report
   (84 MPP + 148 RGA at the current tip), and run the full paired suite matrix
   with clean dmesg evidence.
2. Supply an AVS2 elementary stream and record forward-port/rewrite
   `mpi_dec_avs2` output parity.
3. Run both low-delay slice encode cases and deliberately inject a terminal
   RKVENC error while slice polling is active; prove the waiter returns and the
   next job completes.
4. Exercise timeout, matched IOMMU fault, reset failure/quarantine, kill/close,
   and explicit unbind/rebind around a known-active workload. The current
   recovery harness validates orchestration but cannot manufacture every
   hardware fault deterministically.
5. Boot the opt-in HARD-CCU mode separately and require both decoder-core start
   counters during multi-instance H.264/H.265/VP9/AVS2 runs. The shipped SOFT
   mode does not prove HARD descriptor ownership, peer IRQ, or coordinator-wide
   recovery.
6. Complete the 72-hour multi-instance sanitizer/lockdep/DMA-debug soak. All
   live import, queued-job, userptr-IOMMU, and boundary-shadow gauges must return
   to zero at idle; cumulative job/fence counters should merely stop changing.

The normal-mode [`rewrite-evidence-audit.sh`](../tests/rewrite-evidence-audit.sh)
is intentionally expected to fail until these booted artifacts exist. Its
`--selftest` proves only the audit logic.
