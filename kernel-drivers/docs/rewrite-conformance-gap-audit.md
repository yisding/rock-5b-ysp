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
| Compiled or stale KUnit was treated as current green KUnit | The build profiles enabled both suites, but nothing read the booted results; an unrelated older report could also be combined with newer suite logs. | [`rewrite-kunit-log-check.sh`](../tests/rewrite-kunit-log-check.sh) requires exactly 86 MPP and 120 RGA cases, with no failure or skip, and the profile runner persists a structured report. The evidence audit requires the report whose run ID matches every selected rewrite-candidate suite. |
| Userspace success could hide a kernel warning | Main suites saved only a dmesg tail; they did not compare or gate new messages. | All five suite wrappers now capture before/after dmesg, isolate new lines across ordinary growth or ring wrap, and reject KASAN/KCSAN/UBSAN/KFENCE, Oops/BUG/WARNING, lockdep/RCU/hung-task, DMA-API, and MPP/RGA/IOMMU fault signatures. The evidence audit requires a clean `dmesg-scan.tsv` on both profiles. |
| Error and idle counters were under-specified | Timeout/fault checks omitted recovery failure, spurious IRQ, RGA2 config error, and boundary-shadow setup failure; a missing safety counter looked like a zero delta; zero-after checks covered only imports. | Default forbidden deltas now include those safety counters and rewrite audits require every listed counter for each component captured by a suite to be present. Rewrite suites also require `mpp:queued_job_count`, RGA import and boundary-shadow active gauges, and the direct librga userptr-IOMMU active gauge to return to zero. The latter uses `*:active` so both `userptr_iommu` and legacy `route_b` debugfs names work. |
| The direct MPP evidence could be `mpp_info_test` only | Plugin/FFmpeg coverage exercises codecs, but does not prove the official MPP multi-thread, multi-instance, and rate-control paths selected for parity. | Normal evidence audits selecting MPP now require a representative named core matrix on both profiles and a nonempty checksum artifact for every media case. Decode evidence therefore needs `MPP_DUMP_OUTPUTS=1`. `REQUIRE_MPP_CORE_CASES=0` is an explicit relaxation for old/exploratory logs. |
| A claimed RK3588 codec had no selectable case | Pinned MPP advertises VDPU381 AVS2 and the rewrite has the AVS2 translation table, but `mpp-suite.sh` only named H.264/H.265/VP9. | Added `mpi_dec_avs2`, `mpi_dec_mt_avs2`, `mpi_dec_multi_avs2`, and `vpu_api_dec_avs2`; basic AVS2 is in the final core evidence set. An AVS2 stream is still a hardware input requirement. |
| Successful encode did not prove low-delay slice polling | Ordinary encode can complete without `MPP_CMD_POLL_HW_IRQ`, leaving the recently fixed multi-slice path hardware-untested. | Added required H.264/H.265 low-delay CTU-split official-MPP cases. They set `split_mode=2`, `split_out=1`, and a tunable `MPP_ENC_SPLIT_ARG`, traversing slice polling on hardware. Error-terminal behavior still needs deliberate fault injection. |

Device-free parser, dmesg, counter, comparator, case-builder, and evidence-audit
selftests cover the new wiring. They prove that the gates reject bad fixtures;
they are not substitutes for a booted RK3588 run.

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

1. Boot KASAN and KCSAN rewrite kernels, persist the 206-case green KUnit report,
   and run the full paired suite matrix with clean dmesg evidence.
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
