# Rewrite drivers — path to production readiness (validation & fuzzing plan)

What it would take to move `mpp-rewrite` / `rga-rewrite` from *"compiles, KUnit
passes, and it boots"* to a shippable replacement for the forward-port. This is
the plan that closes the gap [`rewrite-drivers.md`](./rewrite-drivers.md) §6 and
[`../../status.md`](../../status.md) track 4 both record as **"No
hardware-validation record yet."**

> **Framing.** The rewrites are code-complete for their targeted userspace
> surface and heavily unit-tested — MPP **53 KUnit cases** and RGA **97 KUnit
> cases** compile at the §6 pins (`5e307d88798f` on 6.18, `9f9b786baec2` on
> mainline). But every one of those tests is **logic-level**:
> the in-tree `ABI.rst` ledgers are explicit that they *"do not drive MMIO, DMA,
> the real CCU register block, or real decoder interrupts."* The remaining risk
> is concentrated exactly where a from-scratch driver is weakest and where unit
> tests can't reach: real hardware register/IRQ/DMA behaviour, the
> hand-rolled concurrency model, and the large body of **recovery code that has
> never executed**. This plan is ordered by risk, not by convenience.

## What already exists vs. what this plan adds

The support repo already carries most of the *functional-parity* harness. Do not
rebuild it — extend it. The columns below are honest about the boundary.

| Capability | Status in repo | This plan |
|---|---|---|
| Clean cross-kernel build gate | ✅ [`kernel-drivers/tests/rewrite-build-gate.sh`](../tests/rewrite-build-gate.sh) | reuse as the pre-merge gate |
| Non-submit ABI probe + log diff | ✅ [`kernel-drivers/tests/abi-probe.sh`](../tests/abi-probe.sh), [`kernel-drivers/tests/abi-replay.sh`](../tests/abi-replay.sh), including optional dma-heap-backed MPP translate/release, RGA dma-buf import/release, and raw RGA physical-address import observation with an opt-in rewrite reject assertion | reuse; extend to bit-exact output (below) |
| Consumer conformance (MPP / librga / GStreamer / FFmpeg) | ✅ `*-suite.sh` + external [`kernel-drivers/tests/rewrite-conformance.md`](../tests/rewrite-conformance.md), including opt-in GStreamer display/KMS-capture, AV1, and legacy advertised-decode diagnostic cases | reuse; wire the pass/fail gate |
| Differential rewrite-vs-forward-port | ⚠️ GStreamer generated decode/transcode, FFmpeg transcode, MPP official-test media outputs, and the maintained direct RGA smoke paths, including RKNN/RKNPU-style preprocessing, now have `artifacts.tsv` byte-count/SHA-256 comparison paths; broad official librga sample binaries still mostly report pass/fail/timing | extend artifact capture only where official sample outputs matter for remaining gaps |
| Per-core scheduler / timing counters | ✅ debugfs `rk_mpp_rewrite/`, `rk_rga_rewrite/` plus [`debugfs-counter-check.sh`](../tests/debugfs-counter-check.sh) | reuse as assertion hooks throughout |
| KASAN + lockdep + ramoops debug kernel | ✅ [`debug-kernel.md`](./debug-kernel.md) | reuse for every phase |
| **KCSAN race kernel** | ❌ deliberately **off** in `debug-kernel.md` | **add** — a separate build (§3) |
| **Fault injection & recovery** | ❌ (suites only *detect* faults, never *inject*) | **add** — the recovery matrix (§4) |
| **Fuzzing (syzkaller / structure-aware)** | ❌ absent | **add** (§5) |
| **Rewrite-specific security/ABI audit** | ❌ ([`bsp-audit.md`](./bsp-audit.md) is the *forward-port*) | **add** (§6) |
| Production-readiness gate / definition of done | ❌ | **add** (§7) |

---

## 1. Instrumented kernels

Three builds; the sanitizers do not usefully coexist.

- **Kernel A — memory/logic.** The existing [`debug-kernel.md`](./debug-kernel.md)
  build *is* this: KASAN(inline) + UBSAN + `DMA_API_DEBUG(_SG)` + `DEBUG_SG` +
  `DEBUG_LIST` + lockdep (`PROVE_LOCKING`) + `DEBUG_ATOMIC_SLEEP` +
  `PAGE_OWNER`/`PAGE_POISONING`, with ramoops so an IOMMU-fault oops survives the
  reboot. Add `CONFIG_KUNIT=y` + both `*_REWRITE_KUNIT_TEST=y` so the 146 unit
  cases run under KASAN as the very first gate. Add `FAULT_INJECTION` +
  `FAILSLAB` + `FAIL_PAGE_ALLOC` + `FUNCTION_ERROR_INJECTION` for §4.
- **Kernel B — race.** A *separate* build with `KCSAN=y` + lockdep. `debug-kernel.md`
  §3 turns KCSAN off on purpose (it conflicts with KASAN and adds noise), so the
  race pass needs its own kernel. This is the build that finds the
  IRQ-vs-timeout-vs-close-vs-completion data races the recovery code is full of.
- **Kernel C — production.** No sanitizers. The only build on which
  perf/latency/soak numbers mean anything (`debug-kernel.md` §8).

## 2. The oracle: differential testing against the forward-port

The rewrite is ABI-compatible with the vendor forward-port, so **the
forward-port is the golden reference** — the single strongest technique for a
rewrite. Kconfig makes the two tracks mutually exclusive per device node
(`rewrite-drivers.md` head), so A/B in one kernel is impossible: use the existing
`PROFILE=rewrite` / `PROFILE=forward-port` **dual-boot** flow
([`kernel-drivers/tests/rewrite-conformance.md`](../tests/rewrite-conformance.md) "Expanded conformance bundle"), keeping
`assets/` and command lines identical across the two boots.

**The gap to keep closing:** `abi-replay.sh` diffs *normalised ABI logs* rather
than the **pixels/bitstream**. It now includes the non-submit dma-buf allocator
handoff visible to current GStreamer/KMS paths, but the broad official librga
sample binaries are still mostly pass/fail/timing because many samples hard-code their own
`/data`-style input/output conventions. The GStreamer generated
decode/transcode wrapper now caches shared H.264/H.265 inputs plus generated
VP9 IVF input, and can opt into generated AV1 IVF diagnostics for the separate
AV1 backend gap plus generated VP8/H.263/MPEG diagnostics for advertised legacy
decoder caps, then compares `artifacts.tsv` byte counts plus SHA-256s, with
the comparator requiring manifests by default. The FFmpeg suite does the same for
encoded bitstreams, the MPP suite records official-test decode/encode outputs in
`artifacts.tsv` when those media cases produce files, and `librga-suite.sh`
adds the required `ysp_librga_smoke` case to dump deterministic direct RGA
destination buffers for rewrite-vs-forward-port comparison. Extend that
byte-exact discipline to additional official librga sample outputs only where a
remaining userspace-visible gap needs it:

`debugfs-counter-check.sh` can now require positive `started_job_count` /
`hw_total_ns` deltas for selected rewrite MPP/RGA runs while failing positive
timeout, IOMMU-fault, or IRQ-error deltas. This makes the performance gate
harder to satisfy with a userspace-only pass that never reaches the rewrite
hardware completion path.

- **RGA** is deterministic pixel math → expect **bit-exact** destination buffers.
  The in-repo `ysp_librga_smoke` path now writes destination dumps for direct
  im2d copy/resize/fill, dma-buf import/copy, RKNN/RKNPU-style
  RGB/NV12/NV21 preprocessing, legacy GStreamer-shaped `c_RkRgaBlit()`
  conversions, Gaussian matrix, forced-core, pre-intr, and async fence-chain
  cases. A one-pixel CSC or stride error is invisible to a
  pass/fail gate but caught instantly here. Add official-sample artifact dumps
  later only for sample coverage that exposes a new current-userspace behavior.
- **VDEC** decode is bit-exact per bitstream → compare decoded YUV through the
  MPP suite with `MPP_DUMP_OUTPUTS=1`.
- **VENC** encode is bit-exact only vs the *vendor encoder* at identical config
  (never vs a software encoder) — compare rewrite-VENC output to
  forward-port-VENC output for the same input+params, not PSNR against source.

## 3. Phase map

Ordered by risk. Each phase names the existing script to lean on and the
net-new work.

| Phase | Goal | Lean on | Net-new |
|---|---|---|---|
| **P1 Smoke** | silicon actually moves; happy path per backend | `rewrite-smoke.sh`, `abi-probe.sh` | confirm IRQ completion via `started_job_count`/`hw_total_ns` advancing |
| **P2 Conformance** | real consumers pass; unsupported → clean `-EOPNOTSUPP` | `mpp-suite.sh`, `librga-suite.sh`, `gstreamer-suite.sh`, `ffmpeg-suite.sh` + `-compare.sh` | wire pass/fail as a gate; KCOV/gcov coverage map to find cold paths |
| **P3 Differential-exact** | byte-identical output vs forward-port | dual-boot `PROFILE=` flow | §2 buffer/bitstream hashing |
| **P4 Concurrency/race** | no data races under load | debugfs per-core counters | Kernel B (KCSAN); N-thread/M-proc storms; PM-cycling |
| **P5 Fault injection** | every recovery path executes and recovers | Kernel A + `FAULT_INJECTION` | §4 recovery matrix |
| **P6 Fuzzing** | ioctl surface hardened | KCOV | §5 syzkaller + structure-aware |
| **P7 Security/ABI audit** | human review of the copy/overflow/lifetime surface | `bsp-audit.md` method | §6 checklist |

**P2 coverage note.** Run the consumer suites under KCOV and diff a `gcov` map:
the rewrite is ~26k lines and the "Recognized But Unsupported" / recovery
branches will be *cold*. Those cold lines are precisely the P4/P5/P6 targets —
don't fuzz uniformly, fuzz what conformance didn't reach.

## 4. Fault injection & recovery matrix (net-new, highest value)

The ABI ledgers advertise a large body of recovery machinery. On real hardware
**none of it has run** — these are the branches most likely to deadlock, leak, or
UAF. Drive each trigger deliberately (Kernel A, KASAN on) and assert the outcome
via the debugfs counters that were added for exactly this purpose.

| Trigger | How to induce | Assert (debugfs + behaviour) |
|---|---|---|
| **Job timeout** | wedge HW or shrink the 500 ms (MPP) / 1000 ms (RGA) window | `timeout_count++`, reset pulse, PM/clock released, `-ETIMEDOUT`/`-EBUSY` returned, next job dispatches, fence signalled |
| **IOMMU fault** | submit deliberately bad IOVAs / unmapped register fd | `iommu_fault_count++`, job `-EIO`, `iommu_refresh_count++` (post-reset domain flush), device still usable, ramoops clean |
| **Device unbind under load** | `echo > .../unbind` with jobs queued+active | queued+active jobs complete `-ENODEV`, exported release fences signalled, **no UAF (KASAN)** |
| **close() / RESET_SESSION mid-flight** | close fd / reset while a job is active or an acquire fence is pending | session job list drains before imports/requests drop; no orphaned fence; race it under Kernel B |
| **Allocation failure** | `failslab`/`fail_page_alloc` scoped to the driver, hit each site | dma_buf attach, `pin_user_pages`, DMA map, coherent cmd-buffer, CCU link-table node → graceful unwind, no leak (KMEMLEAK), no unsignalled fence |
| **Hard-CCU error/timeout** (opt-in) | enable `rockchip,ccu-mode=2` in DT, wedge a linked task | force-stop→reset→relink→resend→`ZAP_CACHE` path; peer-core power ownership transfers; unrecoverable chain aborts cleanly |
| **RKVENC2 DCHS** | dual-core encoder jobs, kill one mid-handshake | TX/RX id slot cleared on completion/timeout/reset/close/remove |
| **Fence abuse** | acquire fence that never signals / signals error; `user_close_fence` both ways; double-close the fd | correct status propagation; kernel keeps/relinquishes fd per the flag; no refcount imbalance |

The pass criterion for the whole matrix: **correct errno, all fences signalled,
counters move as expected, and the device is still usable for the next job** —
verified across a loop, not once.

## 5. Fuzzing (net-new)

**syzkaller** is the main event; both device nodes are unprivileged ioctl
surfaces (`copy_from_user`: ~11 sites in MPP incl. the ≤128 KB `SET_REG_WRITE`
register image; many in RGA).

- **Descriptions.** Write syzlang for each node.
  - `/dev/mpp_service`: the `MPP_IOC_CFG_V1` message + `mpp_bat_msg` batch
    grammar, all `MPP_CMD_*` subcommands, and the structured register-image blob.
    Exercise the **`compat_ioctl` path** too — MPP routes compat through the
    *same* handler (`rk_mpp_ioctl`), so a 32-bit userspace struct-layout desync is
    a real bug class.
  - `/dev/rga`: all ioctls, the `rga_req` / `rga_user_request` / task structs,
    import via **fd, VA, and physaddr**, and the create/config/submit/cancel
    lifecycle.
- **Structure-aware is mandatory.** Register images and task arrays are
  structured — byte-fuzzing bounces off the parser. Encode layouts in syzlang and
  **seed the corpus from ftrace/strace captures of the P2 consumer runs** so the
  fuzzer mutates valid payloads. Coverage-guided via KCOV, on Kernel A (KASAN).
- **Hardware-fuzzing safety.** A fuzzer *will* emit register spans, strides, and
  IOVAs that could wedge the block or start stray DMA. This is only safe because
  the **IOMMU contains DMA** — keep it on; run on a *sacrificial* board with
  serial console + `panic=10` + ramoops (`debug-kernel.md` §4) + netboot/auto-reboot;
  lean on the drivers' own range checks. Snapshot a known-good boot for fast
  recovery.
- **Targets** to weight: the copy boundaries; integer overflow on
  width·height·stride and chroma-plane-offset math (RGA already has ~75
  overflow-check sites, MPP ~13 — verify they're *complete*, not just present);
  cross-session fd confusion (`MPP_CMD_SET_SESSION_FD`, import fd, fence fd).

A cheap first pass before syzkaller: a userspace libFuzzer/AFL harness over the
ioctls catches the shallow `copy_from_user`/size-validation bugs in minutes.

## 6. Security / ABI hardening review (net-new, human)

Tool passes don't replace reading these surfaces. Method mirrors
[`bsp-audit.md`](./bsp-audit.md) (which is the *forward-port's* 89-finding audit —
the rewrite is "refcount-disciplined by construction" but has had **no
equivalent adversarial read**).

- Every `copy_from_user`/`copy_to_user`: size validated before use; no **TOCTOU**
  on a user pointer read twice (the V1 `data_ptr`, task arrays).
- **VA-import path** (`rga_rewrite.c`): `pin_user_pages_fast(FOLL_WRITE |
  FOLL_LONGTERM)` ↔ `unpin_user_pages_dirty_lock` balance on **every** error path;
  page-count overflow; `FOLL_LONGTERM` correctness vs CMA/migration.
- **fd / fence lifetime**: `fdget`/`fput`, `dma_buf` get/put, `dma_fence`/`sync_file`
  refcount balance across all early-return error paths.
- **Info leak**: uninitialised struct padding in the readback/query
  `copy_to_user` replies.
- **Lock discipline**: the hand-rolled model (`run_lock`, `sched_lock`, `hw_lock`,
  `fault_lock`, `rkvenc_dchs_lock`, `rkvenc_slice_lock`, `fence_lock`,
  `session_lock`, `job_lock`) — confirm ordering is acyclic (lockdep proves it at
  runtime in P4) and that `fault_lock`/`job_lock` IRQ-context sections never sleep.

## 7. Production-readiness gate (definition of done)

Ship only when **all** hold, each with a dated record in
[`../../status.md`](../../status.md) / [`status.md`](./forward-port-status.md):

1. 151 KUnit cases green **under KASAN**; hardware-in-the-loop kselftests added
   (today's tests never open the device).
2. **Byte-exact** differential parity vs forward-port across the full P2 matrix —
   0 diffs (RGA pixels, VDEC YUV, VENC-vs-VENC bitstream).
3. Full `mpp-suite` / `librga-suite` / `gstreamer-suite` / `ffmpeg-suite` pass via the comparators;
   every unsupported profile returns `-EOPNOTSUPP` with no warning/hang/leak
   (the `tests/rewrite-conformance.md` "expected rewrite result" rule, gated).
4. **72 h+ multi-instance soak**: 0 KASAN / KCSAN / lockdep / KMEMLEAK /
   DMA-debug splats; `import_count` and job counters return to baseline at idle.
5. Every §4 fault scenario recovers cleanly, verified in a loop via debugfs.
6. syzkaller: multi-day run, 0 crashes, coverage plateau that **includes the
   recovery lines**.
7. Perf within an agreed ratio of the forward-port on Kernel C
   (`PERF_MAX_RATIO` in the `-compare.sh` gate; forward-port reference numbers in
   [`../tests/README.md`](../tests/README.md) "Observed results").

Until 1–7 hold, the shipped, hardware-validated stack stays the forward-port.

---

Cross-references: [rewrite-driver track](./rewrite-drivers.md) (what the drivers
implement, §2/§3 ABI ledgers, §6 pins), [`debug-kernel.md`](./debug-kernel.md)
(Kernel A / ramoops), [`kernel-drivers/tests/README.md`](../tests/README.md) (the smoke on-ramp)
and [`kernel-drivers/tests/rewrite-conformance.md`](../tests/rewrite-conformance.md) (the rewrite
build gate + `../rockchip-conformance` bundle), [`bsp-audit.md`](./bsp-audit.md)
(audit method), [`multicore-scheduling.md`](../mpp/docs/multicore-scheduling.md) (the
scheduling behaviour P4 exercises), [`rewrite-hard-ccu-finding.md`](../iommu/docs/rewrite-hard-ccu-finding.md)
(the opt-in HARD-CCU path in the §4 matrix), [kernel status](./forward-port-status.md) /
[`../../status.md`](../../status.md) (where results get recorded).
