# Rewrite drivers — path to production readiness (validation & fuzzing plan)

What it would take to move `mpp-rewrite` / `rga-rewrite` from source/build and
partial older-tip boot evidence to a shippable replacement for the forward-port. This is
the strategic companion to the operational
[rewrite-conformance runbook](../tests/conformance.md). The current
qualification verdict and next proof belong to
[`status.md` track 4](../../status.md); this page owns the ordered risk model
and definition of done.

> **Framing.** The targeted userspace surface is code-complete and has MPP
> **99 KUnit cases** plus RGA **152 KUnit cases** (**251 total**). Exact green
> booted KTAP is the first qualification rung, not the finish line. These tests
> are primarily **logic/lifecycle evidence**:
> the in-tree `ABI.rst` ledgers are explicit that they *"do not drive MMIO, DMA,
> the real CCU register block, or real decoder interrupts."* The remaining risk
> is concentrated exactly where a from-scratch driver is weakest and where unit
> tests can't reach: real hardware register/IRQ/DMA behaviour, the
> hand-rolled concurrency model, and hostile recovery. This plan is ordered by
> risk, not convenience. Do not copy current commits, package IDs, or pass
> counts into this plan; follow the status row into the dated finding and
> correlated run artifacts.

> **Current source boundary (2026-08-08):** maintained Phase 2 tips
> `e41bdb50a9ab7` / `1c91ffc853f7a` pass warning-fatal KUnit-enabled MPP object
> builds, the 766-signal production ownership audit, and the unchanged
> 306-signal KUnit-debt audit. The preceding reset-domain tips
> `53a7fa1acbc00` / `ba8e11de18a8e` pass the complete clean-archive `normal`,
> `test-disabled`, KASAN/fault-injection `memory`, and KCSAN/lockdep `race`
> profiles. Predecessor 6.18 `19634f4eebba` passes exact
> 92+152 booted KUnit and 12/12 official MPP, but its librga run exposed defects
> fixed only at later tips. No current-tip Phase 2 source has booted. The source
> contains the separate VPU981 AV1 backend, but no rewrite AV1 kernel has passed
> a hardware qualification rung.

## What already exists vs. what this plan adds

The support repo already carries most of the *functional-parity* harness. Do not
rebuild it — extend it. The columns below are honest about the boundary.

| Capability | Status in repo | This plan |
|---|---|---|
| Clean cross-kernel build gate | ✅ [`kernel-drivers/tests/rewrite-build-gate.sh`](../tests/rewrite-build-gate.sh) provides `normal`, `test-disabled`, `memory` (KASAN/fault-injection), and `race` (KCSAN/lockdep) focused object-build profiles, opt-in-default config proof, fixture-debt audit, and ABI mutation check. At the current tips only `normal` and the audit were rerun. | reuse as the pre-merge gate; run the complete profile matrix for handoff, and remember sanitizer profiles are compile coverage only |
| Non-submit ABI probe + log diff | ✅ [`kernel-drivers/tests/abi-probe.sh`](../tests/abi-probe.sh), [`kernel-drivers/tests/abi-replay.sh`](../tests/abi-replay.sh), including optional dma-heap-backed MPP translate/release, RGA dma-buf import/release, and raw RGA physical-address import observation with an opt-in rewrite reject assertion | reuse; extend to bit-exact output (below) |
| Consumer conformance (MPP / librga / GStreamer / FFmpeg) | ✅ `*-suite.sh` + external [`kernel-drivers/tests/conformance.md`](../tests/conformance.md), including the target × configuration catalog and opt-in GStreamer display/KMS-capture, AV1, legacy advertised-decode, sanitizer, and race cases; `run-conformance.sh --validate` also validates MPP/GStreamer case builders, FFmpeg case-list wiring, the direct `librga-smoke.cpp` source, comparators, and evidence-audit rejection paths | reuse; wire the pass/fail gate |
| Differential rewrite-vs-forward-port | ⚠️ GStreamer generated decode/transcode, FFmpeg transcode, MPP official-test media outputs, and the maintained direct RGA smoke paths, including RKNN/RKNPU-style preprocessing plus AFBC16x16 and tile8x8 round-trips, now have `artifacts.tsv` byte-count/SHA-256 comparison paths; broad official librga sample binaries still mostly report pass/fail/timing | extend artifact capture only where official sample outputs matter for remaining gaps |
| Paired evidence audit | ⚠️ [`kernel-drivers/tests/rewrite-evidence-audit.sh`](../tests/rewrite-evidence-audit.sh) now has a device-free selftest and a normal mode that requires paired forward-port/rewrite required-case passes, artifact manifests, counter deltas, and comparator-clean results | use as the §7 evidence gate; normal mode should fail until booted rewrite logs exist |
| Per-core scheduler / timing counters and MPP job diagnostics | ✅ debugfs `rk_mpp_rewrite/`, `rk_rga_rewrite/` plus [`debugfs-counter-check.sh`](../tests/debugfs-counter-check.sh); MPP additionally exposes a correlated live `state`, 64-entry `events` journal, opt-in `trace_mask`, completion/failure/IRQ counters, and [`mpp-debug-capture.sh`](../tests/mpp-debug-capture.sh) for one-reproduction bundles | reuse as assertion hooks throughout; attach the focused bundle to every MPP failure |
| KASAN + lockdep + ramoops debug kernel | ✅ [`debug-kernel.md`](./debug-kernel.md) | reuse for every phase |
| **KCSAN race kernel** | ⚠️ compile-only `race` profile exists in [`rewrite-build-gate.sh`](../tests/rewrite-build-gate.sh); KCSAN is deliberately **off** in `debug-kernel.md` | **add** — a separate booted build (§3) |
| **Fault injection & recovery** | ⚠️ [`../tests/rewrite-recovery-stress.sh`](../tests/rewrite-recovery-stress.sh) now orchestrates kill/close, reset-opener, and opt-in unbind/rebind loops around real workloads, and `run-conformance.sh --validate` checks its config; [`../tests/ioctl-fuzz-smoke.sh`](../tests/ioctl-fuzz-smoke.sh) now has an opt-in `/proc/self/fail-nth` mode for syscall-local allocation/usercopy failures in non-submit ioctls; synthetic hardware timeout/IOMMU fault injection has not run | finish the recovery matrix (§4) |
| **Fuzzing (syzkaller / structure-aware)** | ⚠️ bounded non-submit ioctl mutator added as [`../tests/ioctl-fuzz-smoke.sh`](../tests/ioctl-fuzz-smoke.sh), including debug-kernel `IOCTL_FUZZ_FAIL_NTH_MAX` sweeps; a draft syzlang description plus its ABI-constant and `make descriptions` compile checks exist for parser/import/version paths but are kept in the private `rock-5b-security` repository; the RGA3 userptr-IOMMU fuzzer now sweeps all 64 cache-line offsets, protects inactive bytes with guards, and checks shadow-copy/leak/failure counters when the rewrite exports them; `run-conformance.sh --validate` checks its build, but neither fuzzer has been run under KCOV/KASAN | finish §5 |
| **Rewrite-specific security/ABI audit** | ⚠️ focused MPP/RGA hardening through 2026-07-17 fixed the RK3588 VDPU381/VDPU383 CCU mismatch plus broad topology, DMA/IOMMU, reset, fd/fence, watchdog, fault-attribution, and removal races; the follow-up also adapted the five applicable RGA 5.10 reliability/cache-safety lessons and audited the forward-port MPP/RGA lifetime findings for structural equivalents | run the remaining booted hardware/KASAN matrix (§4/§6) |
| Production-readiness gate / definition of done | ❌ | **add** (§7) |

---

## 1. Instrumented kernels

Three builds; the sanitizers do not usefully coexist.

- **Kernel A — memory/logic.** The existing [`debug-kernel.md`](./debug-kernel.md)
  build *is* this: KASAN(inline) + UBSAN + `DMA_API_DEBUG(_SG)` + `DEBUG_SG` +
  `DEBUG_LIST` + lockdep (`PROVE_LOCKING`) + `DEBUG_ATOMIC_SLEEP` +
  `PAGE_OWNER`/`PAGE_POISONING`, with ramoops so an IOMMU-fault oops survives the
  reboot. Add `CONFIG_KUNIT=y` + both `*_REWRITE_KUNIT_TEST=y` so the 251 unit
  cases run under KASAN as the very first gate. Add `FAULT_INJECTION` +
  `FAILSLAB` + `FAIL_PAGE_ALLOC` + `FAULT_INJECTION_USERCOPY` +
  `FUNCTION_ERROR_INJECTION` for §4. The device-free preflight is
  `REWRITE_BUILD_PROFILES=memory kernel-drivers/tests/rewrite-build-gate.sh all`,
  which only proves that the provider/rewrite objects and Rock 5B DTB compile
  under this instrumentation.
- **Kernel B — race.** A *separate* build with `KCSAN=y` + lockdep. `debug-kernel.md`
  §3 turns KCSAN off on purpose (it conflicts with KASAN and adds noise), so the
  race pass needs its own kernel. This is the build that finds the
  IRQ-vs-timeout-vs-close-vs-completion data races the recovery code is full of.
  The device-free preflight is
  `REWRITE_BUILD_PROFILES=race kernel-drivers/tests/rewrite-build-gate.sh all`;
  it does not replace booting a KCSAN kernel and driving the P4 workloads.
- **Kernel C — production.** No sanitizers. The only build on which
  perf/latency/soak numbers mean anything (`debug-kernel.md` §8).

## 2. The oracle: differential testing against the forward-port

The rewrite is ABI-compatible with the vendor forward-port, so **the
forward-port is the golden reference** — the single strongest technique for a
rewrite. Kconfig makes the two tracks mutually exclusive per device node
(`rewrite-drivers.md` head), so A/B in one kernel is impossible: use the existing
`PROFILE=rewrite` / `PROFILE=forward-port` **dual-boot** flow
([`kernel-drivers/tests/conformance.md`](../tests/conformance.md) "Expanded conformance bundle"), keeping
`assets/` and command lines identical across the two boots.

The maintained
[`librga` consumer model](../rga/docs/userspace-consumers.md)
does not broaden the required Linux RK3588 profile beyond the current
conformance direction.  Outside ffmpeg-rockchip, JeffyCN GStreamer, and the
official librga samples, the strongest additional signal is RKNN/RKNPU
preprocessing plus simple display/compositor/desktop blits: fd or virtual
RGB/RGBA/NV12/NV21 resize/convert/crop/letterbox, legacy `c_RkRgaBlit()`
RGB-family fill/scale/rotate/simple-blend paths, and clean negative handling
for raw physical-address import plus AFBC32x8/RFBC64x4 destination modes.
No surveyed current Linux-media user promoted RFBC64x4/AFBC32x8, per-channel
rotation, tile alpha/pattern/color-key, broad RGA2-Pro modes, or Android
GraphicBuffer/HWC allocator behavior into the required Rock 5B rewrite gate.

**The gap to keep closing:** `abi-replay.sh` diffs comparable *normalised ABI
logs* rather than the **pixels/bitstream**. It still records the non-submit
dma-buf allocator handoff visible to current GStreamer/KMS paths, but the broad official librga
sample binaries are still mostly pass/fail/timing because many samples hard-code their own
`/data`-style input/output conventions. The GStreamer generated
decode/transcode wrapper now caches shared H.264/H.265 inputs plus generated
VP9 IVF input, and can opt into generated AV1 IVF diagnostics for the
source-implemented but hardware-unproven VPU981 backend plus generated
VP8/H.263/MPEG diagnostics for advertised legacy
decoder caps, then compares `artifacts.tsv` byte counts plus SHA-256s, with
the comparator requiring manifests by default. The FFmpeg suite does the same for
encoded bitstreams, the MPP suite records official-test decode/encode outputs in
`artifacts.tsv` when those media cases produce files, and `librga-suite.sh`
adds the required `ysp_librga_smoke` case to dump deterministic direct RGA
destination buffers for rewrite-vs-forward-port comparison. Extend that
byte-exact discipline to additional official librga sample outputs only where a
remaining userspace-visible gap needs it:

The direct `librga-smoke.cpp` source is also part of the device-free
maintenance gate through `LIBRGA_SMOKE_VALIDATE_BUILD=1`, so API/header drift in
the maintained direct RGA artifact path fails before a board run. That build
check is not runtime proof; the full `ysp_librga_smoke` case still needs a
booted `/dev/rga` owner and artifact comparison against the forward-port.
The MPP suite has a matching device-free case-builder check through
`MPP_VALIDATE_CASES=1`, so selected official-test case names and required
environment variables fail early instead of being discovered only after a board
boot.
The GStreamer flush/force-key-unit/seek/EOS helper has a similar optional
source gate through `GST_EVENT_HARNESS_VALIDATE_BUILD=1`: it builds whenever
the host has GStreamer development pkg-config files and otherwise records a
visible skip in `VALIDATE_ONLY=1`.

`debugfs-counter-check.sh` can now require positive `started_job_count` /
`hw_total_ns` deltas for selected rewrite MPP/RGA runs while failing positive
timeout, IOMMU-fault, or IRQ-error deltas. It can also require at least N
positive per-core counters with prefix specs such as
`mpp:started_rkvdec_core:2` or `rga:started_rga3_core:2`, so multicore
scheduling claims can be checked directly in the conformance logs. This makes the performance gate
harder to satisfy with a userspace-only pass that never reaches the rewrite
hardware completion path.

**RGA multi-task parallelism differential.** The current rewrite serializes
tasks within one request, while preserving parallel execution between separate
requests. That source-level distinction still needs one focused hardware A/B
measurement against the forward port:

1. Submit two equal, independent 4K RGA3-compatible copies or resizes in one
   unflagged `imbeginJob()`/`imendJob()` request.
2. Submit the same operations as two separate `IM_ASYNC` one-task requests.
3. Repeat the single-request case with `IM_JOB_FLAGS_EXEC_SEQUENTIAL`, and add a
   genuinely dependent `src -> tmp -> dst` chain as the correctness control.
4. Record wall time, each release-fence completion time, output hashes, and the
   per-core `started_rga3_core:*`, scheduled-job, completed-job, timeout, fault,
   and IRQ-error counter deltas on both kernels.
5. Repeat with small independent rectangle fills to separate hardware time from
   mapping/IRQ/requeue overhead, and with large buffers to expose the DDR
   bandwidth ceiling.

Expected source-derived result: the forward port may overlap unflagged tasks in
one request, whereas the rewrite will show only one task from that request
active at a time. Both should overlap the two separate async requests, subject
to core eligibility and load. The sequential/dependent control must preserve
array order and bit-exact output; note that the current forward oracle stores
but does not interpret librga's newer sequential bit, so that case may expose a
forward-port correctness gap rather than a rewrite performance gap. Until this
run exists, describe the current-stack impact as **probably immaterial for
FFmpeg/GStreamer/ordinary IM2D calling shapes, but hardware-unmeasured for
explicit independent Task-API batches**.

- **RGA** is deterministic pixel math → expect **bit-exact** destination buffers.
  The in-repo `ysp_librga_smoke` path now writes destination dumps for direct
  im2d copy/resize/fill, dma-buf import/copy, RKNN/RKNPU-style
  RGB/NV12/NV21 preprocessing plus RKNN-style RGBA crop/letterbox,
  legacy GStreamer-shaped `c_RkRgaBlit()` conversions, display/compositor-shaped
  BGRx `c_RkRgaBlit()` 90-degree rotation, Gaussian matrix, forced-core,
  pre-intr, and async fence-chain cases. A one-pixel CSC or stride error is
  invisible to a pass/fail gate but caught instantly here. Add official-sample
  artifact dumps later only for sample coverage that exposes a new
  current-userspace behavior.
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

A first executable recovery harness now exists as
[`../tests/rewrite-recovery-stress.sh`](../tests/rewrite-recovery-stress.sh).
It can run kill/close, reset-opener, and explicit platform unbind/rebind loops
around a busy MPP/RGA workload, then run a liveness probe, scan fresh dmesg
lines for fatal signatures, and snapshot MPP/RGA debugfs counter deltas.
`RECOVERY_VALIDATE_ONLY=1` is part of the device-free
`run-conformance.sh` validation gate, but it only proves the harness
configuration. It still needs a booted RK3588 rewrite run, and it does not yet
induce synthetic hardware timeout or synthetic IOMMU faults. Submit-path
allocation failures remain open beyond the non-submit fail-nth smoke below.

The bounded ioctl mutator now has the first scoped fault-injection hook for the
allocation/usercopy row: run `IOCTL_FUZZ_FAIL_NTH_MAX=N
IOCTL_FUZZ_ITERS=<small>` on Kernel A, with `IOCTL_FUZZ_OUT=<dir>` and
`IOCTL_FUZZ_DMESG_SCAN=1` so the run leaves logs plus dmesg before/after
snapshots. The C mutator writes
`/proc/self/fail-nth` immediately before each individual non-submit ioctl and
clears it immediately afterward, so the injected fault is tied to the ioctl
syscall rather than shell startup. This covers parser/import/control unwind
paths; it does **not** replace the real submit-path allocation failures in the
matrix below.

| Trigger | How to induce | Assert (debugfs + behaviour) |
|---|---|---|
| **Job timeout** | wedge HW or shrink the 500 ms (MPP) / 1000 ms (RGA) window | `timeout_count++`, reset pulse, PM/clock released, `-ETIMEDOUT`/`-EBUSY` returned, fence signalled; next job dispatches only after a successful reset. For either rewrite, a reset failure increments `recovery_failure_count`, quarantines that core, masks its IRQ, and drains its queue with `-EIO`; an MPP coordinator reset failure quarantines every dependent decoder core. |
| **IOMMU fault** | submit deliberately bad IOVAs / unmapped register fd | `iommu_fault_count++`, job `-EIO`; a successful reset increments `iommu_refresh_count` and leaves the device usable, while a reset failure follows the same quarantine/drain assertions above; ramoops clean |
| **Device unbind under load** | `echo > .../unbind` with jobs queued+active | queued+active jobs complete `-ENODEV`, exported release fences signalled, **no UAF (KASAN)** |
| **close() / RESET_SESSION mid-flight** | close fd / reset while a job is active or an acquire fence is pending | session job list drains before imports/requests drop; no orphaned fence; race it under Kernel B |
| **Allocation failure** | `failslab`/`fail_page_alloc` scoped to the driver, hit each site | dma_buf attach, `pin_user_pages`, DMA map, coherent cmd-buffer, CCU link-table node → graceful unwind, no leak (KMEMLEAK), no unsignalled fence |
| **Hard-CCU error/timeout** (opt-in) | enable `rockchip,ccu-mode=2` in DT, wedge a linked task | force-stop→reset→relink→resend→`ZAP_CACHE` path; peer-core power ownership transfers; unrecoverable chain aborts cleanly |
| **RKVENC2 DCHS** | dual-core encoder jobs; kill one mid-handshake; force producer completion after consumer channel matching but before consumer START | producer retirement cannot cross consumer patch-through-START; RXE is retained only when the consumer started first; TX/RX id slot clears on completion/timeout/reset/close/remove |
| **Fence abuse** | acquire fence that never signals / signals error; `user_close_fence` both ways; double-close the fd | correct status propagation; kernel keeps/relinquishes fd per the flag; no refcount imbalance |

The pass criterion for the whole matrix: **correct errno, all fences signalled,
counters move as expected, and the device is still usable for the next job** —
verified across a loop, not once.

## 5. Fuzzing (net-new)

**syzkaller** is the main event; both device nodes are unprivileged ioctl
surfaces (`copy_from_user`: ~11 sites in MPP incl. the ≤128 KB `SET_REG_WRITE`
register image; many in RGA).

- **Descriptions.** A first syzlang draft exists, together with the checks that
  keep its ioctl constants and struct-size markers in sync with `abi-probe.sh`
  and compile it against an upstream syzkaller checkout. As fuzzer ABI grammar
  it is kept in the private `rock-5b-security` repository, not here.
  Expand it for each node:
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

A cheap first pass before syzkaller now exists as
[`../tests/ioctl-fuzz-smoke.sh`](../tests/ioctl-fuzz-smoke.sh): it mutates
non-submit MPP/RGA ioctl payloads, sizes, flags, bad user pointers, RGA import
pools, and request create/cancel lifetimes. With `IOCTL_FUZZ_FAIL_NTH_MAX=N`,
the wrapper repeats the mutator with `IOCTL_FUZZ_FAIL_NTH=1..N`; each C-side
ioctl wrapper sets `/proc/self/fail-nth` only for the syscall under test and can
require at least one consumed injected fault with
`IOCTL_FUZZ_FAIL_NTH_REQUIRE_HIT=1`. `IOCTL_FUZZ_OUT=<dir>` persists per-run
logs; `IOCTL_FUZZ_DMESG_SCAN=1` brackets each run with dmesg fatal-signature
checks, and `IOCTL_FUZZ_REQUIRE_DMESG=1` makes unreadable dmesg a failure.
It still needs to be run on a booted rewrite kernel, ideally under Kernel A
with KASAN/KCOV. Device-free validation
now compiles the mutator through `IOCTL_FUZZ_VALIDATE_BUILD=1` in
`../tests/run-conformance.sh --validate`, but that only catches
build rot; it still needs real booted rewrite runs, including fail-nth sweeps,
and should later be replaced or augmented by a proper libFuzzer/AFL in-process
harness plus syzkaller.

The RGA userptr-IOMMU-specific first pass is
[`../tests/iommu-machinery-fuzz.sh`](../tests/iommu-machinery-fuzz.sh), which
builds `rga-iommu-fuzz.cpp` and can force scattered userptr RGA3 copy/resize/
rotate/cvtcolor, reuse the bit-exact decode oracle, and run RGA scatter
concurrently with AV1 decode while scanning dmesg/debugfs for IOMMU faults and
RGA userptr-IOMMU fallback leaks. Its default boundary sweep submits every
source offset modulo a 64-byte cache line with a complementary destination
offset, and verifies guard bytes before and after every active range. When a
rewrite exposes boundary-shadow counters, the harness requires positive
copy-to/copy-from deltas, zero active head/tail views after the run, and no
shadow setup failures. Device-free validation now compiles the RGA scatter fuzzer object
through `IOMMU_FUZZ_VALIDATE_BUILD=1`; that is only a source/build gate. The
remaining production evidence is still a booted rewrite run on RK3588 with
RGA userptr-IOMMU fallback `attempt`/`ok` deltas, `active` returning to baseline, clean IOMMU fault
counters, and correct output under the debug kernel.

## 6. Security / ABI hardening review (in progress, human)

Tool passes don't replace reading these surfaces. Method mirrors
[`bsp-audit.md`](./bsp-audit.md) (which is the *forward-port's* 89-finding audit).
The 2026-07-14 focused MPP pass covered the decoder reference-data selection,
encoder DCHS/overflow IRQ behavior, cross-core CCU completion,
IRQ/timeout/reset/remove lifetime, V1 collector bounds, custom translation
table concurrency, and procfs configuration. It corrected a critical
hardware-family mismatch: the RK3588 core is VDPU381 and must use the vendor
218-word/six-write-part `rkvdec_link_v2_hw_info`, link IRQ/work-mode register
`0x00`, core status word 224, and error mask `0xf0`; the rewrite had used the
RK3576 VDPU383 table and `0x48`/`0x4c` link registers. Focused KUnit assertions
now pin those RK3588 values. The same pass serialized queue admission with
core/CCU removal, bounded session-switch-only V1 arrays, locked translation
table commit/snapshot, and verified a `CONFIG_PROC_FS=n` warning-clean build.
The continuation made DCHS allocation failure stop submission, restored the
VEPU580 circular-bitstream overflow advance, reset encoder/direct-decoder cores
after hardware error IRQs, changed HARD-CCU IRQ completion to claim the actual
table-done job across the coordinator instead of the interrupting core's
software owner, and made member-core removal quiesce/abort the coupled cluster.
It also found that the standalone rewrite did not reproduce the vendor driver's
shared-IOMMU-domain setup: a HARD-CCU peer could therefore fetch link-table and
import IOVAs mapped only for the selected core. HARD mode now requires equal
DMA/IOMMU domains across every online peer, drops advertised decoder support and
returns `-EXDEV` for mixed-domain descriptor staging, and constrains peer
power-up to the validated mask/domain. Rock 5B now also supplies the required
positive topology: `vdec1_mmu` points to `vdec0_mmu` with
`rockchip,shared-domain-owner`, and the Rockchip provider returns the owner's
singleton group so IOMMU core creates, attaches, and installs one ordinary
default DMA domain for both decoder masters. Provider self-links/chains are
rejected and unresolved owners defer; nodes without the property retain their
singleton group. The runtime equal-domain test remains a fail-closed verifier,
and the shipped SOFT-CCU default is unchanged.
The shared-domain follow-up also made IOMMU fault hooks explicitly
provider-owned: each physical decoder IOMMU is cleared independently on
removal, and a callback with a controller/master source must match that exact
core instead of falling back to the first core in the common domain.
The HARD-CCU fault follow-up then separated physical source attribution from
software job ownership. It reads the faulting peer's link `CFG_ADDR`, finds the
active job that owns that descriptor IOVA, and schedules the existing
coordinator-wide recovery on that job's active slot. An unmatched descriptor
falls back to another active job in the same HARD coordinator, so a fault on an
empty peer slot cannot disappear until the ordinary 500 ms timeout.
The session-control follow-up then closed reset and multi-message ordering
races. Each staged job snapshots the client type, translation table, codec
information, inherited RCB descriptors, and session epoch. Reset removes
earlier staged jobs for that session, advances the epoch before aborting active
work, and rejects stale translations/admissions with `-ECANCELED`; active-list
and scheduler-queue ownership become visible together under the session lock.
Repeated client initialization is idempotent only for the already-bound type,
while an encoder/decoder rebind fails with `-EBUSY`.
The poll-lifecycle follow-up made RKVENC2 slice overflow recoverable instead of
leaving a permanently unpollable completed job at the session head. It also
defers slice-buffer validation until a split-mode job is selected, preserving
the forward-port full-frame behavior for non-split `POLL_HW_IRQ` and the
empty-session `-EIO` result without touching slice-only userspace memory. The
2026-07-17 reconciliation rechecked the newer 5.10 rule that treats an encoder
error IRQ as the last slice. No literal transplant is needed: every rewrite
terminal error IRQ wakes threaded completion, marks the job done, wakes the
session, and makes `POLL_HW_IRQ` consume the completed error instead of waiting
for another slice. Existing split FIFO/poll lifecycle KUnit covers recovery of
the session-head job and the non-split/empty-session distinctions.

The same reconciliation checked the forward-port MPP procfs-session teardown
UAF and RGA session-close UAF. The MPP rewrite has no service-wide unpinned
session list for procfs to walk; its state/events readers traverse pinned jobs,
hardware, and queues under their owning locks, while file-release KUnit covers
cleanup. RGA close first unlinks and marks the session closing, waits dispatch
idle, aborts pending-fence and active jobs, waits for its job list to drain, and
only then drops imports and requests; session-close handoff KUnit pins that
ordering. These findings are structural non-transplants, not permission to
skip the booted KASAN close/reset/unbind matrix above.

The VEPU580 follow-up then matched the vendor `0x03f0` reset mask: a bitstream
overflow still advances/wraps the circular write pointer and lets the current
frame continue, but its retained status now resets the core at terminal
completion before another frame starts. The prior rewrite checked only generic
error bits 5–8 and incorrectly omitted that post-overflow reset. The adjacent
decoder readback audit also removed undefined signed-left-shift behavior from
the RLC decoded-length adjustment: unsigned 32-bit delta/shift arithmetic keeps
the BSP bit pattern even when error/wrap status falls below the stream start.
The reset-containment follow-up then closed MPP's fail-open recovery edge.
Reset assertion/deassertion failure now quarantines the core until reprobe,
including a reset deassertion that fails during runtime power-up, removes it
from support/selection/admission/dispatch, drains already queued jobs with
`-EIO`, and leaves its IRQ masked across runtime suspend. A failed decoder
coordinator reset applies the same policy to every dependent core, while
`recovery_failure_count` and the per-hardware `recovery_failed` state expose the
degradation. KUnit pins core/CCU admission rejection, selector skipping, and
dispatcher refusal. The adjacent HARD-CCU table audit also moved the full BSP
readback-destination span check into table materialization: a 285-word register
image now fails with `-EINVAL` before the start doorbell rather than reaching
hardware and failing only during completion readback. HARD-CCU completion now
pins the table's software-owner hardware and blocks on its run lock before
rechecking the exact slot. This closes the immediate-doorbell race where the
threaded IRQ acknowledged a completed table, lost `mutex_trylock()`, and left
the job to report a false 500 ms timeout; the pin also closes concurrent
abort/removal use-after-free exposure around the previous raw `job->hw` load.
The same counted snapshot now protects both passes over collected unfinished
jobs during HARD-CCU reset/resend; retaining the job object no longer leaves its
detached hardware pointer unprotected.
The HARD-CCU power-ownership follow-up also made the initial chain owner hold a
separate runtime-PM/clock reference on its selected core as well as every peer.
Those references transfer together to the next listed job, so the first job's
normal completion cannot power off its selected core while that core remains in
the coordinator work mask for later descriptors.
The link-pool audit then matched the vendor allocator's sentinel invariant:
each per-core HARD pool keeps one unused next-table node, rejects pools smaller
than two nodes at probe, and returns `-ENOSPC` before a full pool can produce a
zero tail address. The ownership KUnit now fills the usable `capacity - 1`
slots, verifies the sentinel remains unused across relinking, and pins the
fail-closed final admission.
The descriptor/MMIO separation audit then removed direct task-register and
cache-control writes from HARD submission. Those values now exist only in the
coherent table, and add-mode jobs no longer touch the selected core's link
control either; the selected physical core can be busy executing a different
software owner's descriptor. Direct MMIO remains the SOFT/direct-decoder path,
while HARD per-core link/RCB setup is limited to an idle coordinator start.
The adjacent codec-metadata audit made RKVDEC2 CCU watchdog sizing fail safe:
an overflowing width/height/bitdepth pixel count now selects the longest 100 ms
threshold rather than wrapping into the 20 ms range; the existing threshold
KUnit case covers the maximum-width metadata boundary.
The direct-encoder comparison then restored the BSP's per-frame VEPU580
hardware-watchdog calculation. After the submitted registers and configured
core clock are applied, the rewrite selects the 50/100/200/400/800 ms interval
from the encoded resolution, preserves the upper submodule byte, and clamps the
24-bit frame threshold; above-table metadata uses the longest interval instead
of the vendor path's zero fallback. KUnit pins both the 1080p table boundary
and saturation behavior, independently of the 500 ms software timeout.
The shared-domain follow-up rejects self-referencing, chained, cyclic, and
non-Rockchip owner phandles before provider deferral, and the mainline helper
now verifies the attached IOMMU provider before reading Rockchip-private data.
The adjacent ABI-arithmetic pass also makes literal `SET_REG_ADDR_OFFSET`
updates reject cumulative 32-bit wrap; the existing offset KUnit case pins the
failure and preserves the original register value.
The teardown-lifetime follow-up serialized active-job hardware pin and detach
under the session lock. Reset/close abort now owns a hardware reference before
canceling timeout work or acquiring the run lock, so concurrent completion and
platform removal cannot drop the final reference and free the devm hardware
object between abort's pointer load and use.
The HARD-CCU containment follow-up closed the contended-peer gap in the
coordinator-wide abort path. A failed `mutex_trylock()` no longer silently
leaves that peer active until its ordinary 500 ms timeout: it queues immediate
work holding the exact job and hardware references. The worker acquires the run
lock and aborts only if that same job still owns the active slot; KUnit pins
same-target result updates, target replacement, and the corresponding job-ref
lifetime. The follow-up closes the remaining pre-lock capture gap: the abort
target is pinned before `mutex_trylock()`, is queued only while it still owns
the slot, and its timeout is canceled only after the worker claims it. A stale
target can therefore neither select a replacement nor remove that replacement's
watchdog.
The immediate-fault follow-up also publishes the HARD-CCU software-owner flag
before the `CFG_DONE` doorbell, with a write barrier ordering both descriptor
and ownership state ahead of hardware start. A fault generated as soon as the
CCU fetches the descriptor can therefore still resolve the correct active slot
instead of scheduling recovery on an empty physical peer.
The IOMMU-fault completion follow-up split fault recovery from each core's
ordinary delayed timeout work in both rewrites. The provider callback now
records the active-slot activation generation, and dedicated work claims only
that exact generation before canceling its watchdog. Delayed fault work can no
longer complete a replacement job or consume the replacement's timeout; KUnit
pins the matching-generation and stale-replacement cases in MPP and RGA.
The IRQ/PM follow-up then closed the hard-top-half side of the same recovery
race. Run locks serialize threaded completion but cannot stop an already-running
hard IRQ handler from reading or clearing MMIO while timeout, fault, reset, or
removal recovery resets and runtime-suspends the core. Both rewrites now disable
the registered engine IRQ and drain its hard handler before claiming/resetting
the slot, then re-enable it after the core is quiesced. RGA also publishes
`removing` under the job lock shared by queue admission and the abort sweep,
giving the selected-core removal race a real synchronization edge.
The watchdog-target follow-up closed the ordinary-timeout version of the
replacement race. Cancellation can lose to a delayed worker that has already
started; after the completed job dispatches a successor, a worker that merely
takes "the active job" would time out the successor. MPP and RGA watchdogs now
hold an explicit reference to their target, workers claim only that job, and
successor start uses `mod_delayed_work()` so its new timeout is queued even
while the stale invocation exits. Focused KUnit cases pin target-reference
release, replacement survival, and replacement watchdog rearming.
The RGA fault-lifetime follow-up removed the generic DMA-domain handler
fallback, which cannot register or unregister safely on the IOMMU-core-owned
default DMA domain. Attached-domain cores now require the provider-local hook;
shared-domain faults require an exact physical source instead of redirecting to
the first peer, each provider callback is cleared independently, and provider
unregister waits for already-running IOMMU IRQ callbacks. The same pass moved
the queue-on-hardware prototype outside the KUnit-only block, fixing a current
mainline build failure hidden by 6.18's KUnit-enabled configuration.
The RGA acquire-fence follow-up fixed a recursive spinlock deadlock: dma-fence
callbacks already run with the fence lock held, so status must be read with
`dma_fence_get_status_locked()`. It also made callback ownership atomic during
abort and made completion respect the callback-arming sentinel. KUnit now pins
last-core abort interleaved between callback registrations, preventing teardown
from dropping the callbacks' shared work reference while the submit path is
still arming later fences.
The release-fence publication follow-up removed an fd-reuse rollback race in
both modern request submit and legacy async blit. The rewrite now reserves the
fd and creates its `sync_file`, copies the fd number to userspace, and only then
installs the file. If that copy faults, the still-uninstalled reservation is
dropped directly instead of calling `close_fd()` on a number another thread
could already have closed and reused. KUnit covers the reservation remaining
invisible before installation and both install/abort ownership transitions.
The close/dispatch handoff follow-up then closed the remaining scheduler gaps.
A successful acquire worker could previously read its result before `release()`
marked the session closing, then publish a hardware job after the close path had
already swept every queue. A successful multi-task IRQ could do the same while
moving a request from its completed core to the next task's selected core.
Sessions now count workers and IRQ handoffs that have committed to dispatch;
close rejects later handoffs and waits for earlier ones to publish their queue
state before aborting hardware jobs. KUnit pins both the pre-close counted
handoff and post-close `-EFAULT` completion path.
The acquire-state follow-up removed the close path's cross-lock inference from
`queued`, `hw`, `done`, and `result`. Deferred jobs now publish one explicit
session-locked wait state, which close/removal claims exactly once before
canceling callbacks. Submit also rechecks hardware availability after callback
arming, so last-core removal just before wait-state publication completes the
release fence with `-ENODEV` instead of leaving an unsignaled fence orphaned.
Synchronous RGA completion now also publishes `result` before `done` with a
release/acquire pair, removing the plain completion-flag race targeted by the
KCSAN profile.
The RGA hot-reprobe follow-up fixed public core-mask reuse after a partial
unbind. Probe previously assigned a mask from the count of surviving same-class
cores, so rebinding core 0 while core 1 remained gave both devices core 1's bit.
Probe now claims the first vacant class-specific slot, rejects excess cores, and
keeps forced-core routing and per-core counters unambiguous; KUnit models both
RGA3 and RGA2 partial-reprobe cases.
The dma-buf follow-up removed another first-segment assumption: codec imports
now prove that all mapped DMA entries form one byte-contiguous span covering
the allocation inside the 32-bit register aperture, and encoded plane offsets
must remain inside that allocation.
The cache-lifetime follow-up aligned the rewrite with the forward port's
explicit dma-buf-identity rule: lookup pins the object named by the current fd
before matching, preventing a reused integer fd from selecting an old mapping,
and stale cache eviction preserves any reference already held by a job.
The register-offset follow-up retains per-register dma-buf provenance after fd
translation, then validates the cumulative embedded plus
`SET_REG_ADDR_OFFSET` value against the allocation and 32-bit IOVA aperture.
Literal non-fd registers retain the forward port's additive-offset behavior
but reject cumulative 32-bit wrap instead of programming the wrapped value.
The explicit-fd parser follow-up now requires `TRANS_FD_TO_IOVA` and
`RELEASE_FD` payloads to be exact bounded arrays of 32-bit elements. Partial
trailing bytes can no longer be accepted while silently escaping translation or
release; KUnit pins zero, misaligned, oversized, and boundary-sized payloads.
The explicit-IOVA affinity follow-up now maps every fd in a translation command
on one DMA device, serializes translation against release/reset, and pins that
device for later no-translate jobs. Partial core removal therefore returns
`-ENODEV` instead of running a cached IOVA in another core's IOMMU domain, while
rebinding the same platform device restores the mapping affinity; KUnit pins
the online, offline, and same-device-rebind selections.
The runtime-testability follow-up replaced the VP9 translation fixture's
unresolvable synthetic fd with an exported test dma-buf, so the documented
dma-buf-identity lookup is exercised instead of failing with `-EBADF` when the
suite is booted. It also made both rewrite `import_count` files the live gauges
required by the idle/leak gate: successful cache/handle publication increments
the relevant gauge and final mapping release decrements it back to zero, even
when a prepared job or configured request outlives the userspace handle.
The follow-on RCB/SOFT-CCU pass retained the documented coherent-DRAM scratch
model (rather than pretending to provide the vendor's driver-managed fixed-IOVA
SRAM mapping), accepted valid DMA address zero, rechecked core/CCU/cancellation
state under the coordinator run lock before final SOFT/HARD start writes, and
added the vendor per-core force-idle/reset/error-clear/reconnect sequence for
SOFT-CCU error, timeout, and IOMMU-fault recovery.
The MPP profile-boundary follow-up then used the register-0 identities published
by current libmpp and observed on Rock 5B to pin each hard-coded backend:
RKVENC2 must report VEPU58x `0x50603312`, and RKVDEC2 must report VDPU38x
`0x53813f05`. A zero or different ID now fails probe with `-ENODEV` before IRQ
or IOMMU-fault registration, preventing the generic DT compatibles from
silently applying RK3588 VEPU580/VDPU381 register and link-table layouts to a
different Rockchip revision; KUnit covers required, absent, mismatched, and
exact identities.
The VDPU381 aperture follow-up fixed a soft-CCU hardware-sequence omission.
The converted Rock 5B nodes exposed only `0x400` bytes from the function base,
while the cache and max-outstanding-read registers used by every direct-core
submission occupy offsets `0x510` through `0x59c`. Range-checked rewrite jobs
therefore skipped all of those writes even though the forward port issued them.
The maintained DT and overlay now expose a `0x600` function aperture ending at
the MMU boundary, and probe requires at least `0x5a0`; KUnit pins rejection of
the former truncated size and acceptance of the complete minimum.
The same audit found that the opt-in HARD-CCU path never performed the vendor
driver's cache-size, cache-clear, and max-outstanding-read setup when starting
an idle chain. The rewrite now validates the entire cache register set before
writing it, initializes every powered work-mask core before the coordinator
doorbell, and leaves add-mode submissions untouched. The focused KUnit case
checks fail-closed truncated-window behavior and all seven programmed values.
The explicit-IOVA follow-up closed two ways around the rewrite's dma-buf
ownership model. A session-provided translation table now augments rather than
replaces the fixed RK3588 address-register table, so omitting a known DMA
register cannot leave a literal address uninspected. `REG_FD_NO_TRANS` also
requires prior device affinity, proves every known nonzero IOVA lies within a
dma-buf mapped by that session on that exact core, and transfers mapping
references to the job until completion. This prevents guessed cross-session or
physical addresses and concurrent `RELEASE_FD` unmapping from reaching active
codec DMA; KUnit pins missing affinity, custom-table omission, both range
boundaries, deduplicated mapping retention, offline rejection, and same-device
rebind.
The RGA recovery follow-up then removed a fail-open reset path. RGA3 no longer
turns a simultaneous DONE+ERROR status into success, and every RGA error IRQ
resets before runtime suspend. A failed soft reset is recoverable only through
a successful reset-controller pulse; otherwise the core is quarantined, skipped
by mapping/scheduling, and prevented from retaining or accepting jobs. Existing
queued jobs complete with `-EIO`, loss of the last usable core aborts deferred
acquire-fence work, its IRQ remains masked across runtime suspend, and
`recovery_failure_count` makes the permanent degradation visible. KUnit pins
error precedence, the admission race, queue drain, and
faulted-core selection.
The remaining checklist still requires an equally adversarial RGA pass and
booted sanitizer/fault-injection evidence.

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

1. 251 KUnit cases green **under KASAN** (99 MPP + 152 RGA), persisted from the
   booted suites by `tests/rewrite-kunit-log-check.sh`; hardware-in-the-loop
   kselftests added (the KUnit cases themselves never open the device).
2. **Byte-exact** differential parity vs forward-port across the full P2 matrix —
   0 diffs (RGA pixels, VDEC YUV, VENC-vs-VENC bitstream).
3. Full `mpp-suite` / `librga-suite` / `gstreamer-suite` / `ffmpeg-suite` pass via the comparators
   with `PROFILE=rewrite RUN_COUNTER_CHECKS=1`; every unsupported profile
   returns `-EOPNOTSUPP` with no warning/hang/leak, and the default positive
   hardware-start/busy-time plus timeout/fault/error counter gates pass (the
   `tests/conformance.md` "expected rewrite result" rule, gated).
   `tests/rewrite-evidence-audit.sh` must also pass in normal mode with
   default artifact, counter-delta, clean dmesg, booted-KUnit, representative
   official-MPP core-case, and comparator requirements against paired
   forward-port/rewrite logs; its `--selftest` is only a maintenance check.
4. **72 h+ multi-instance soak**: 0 KASAN / KCSAN / lockdep / KMEMLEAK /
   DMA-debug splats; live import, MPP queue, RGA userptr-IOMMU, and boundary-
   shadow gauges return to baseline at idle, while cumulative job and
   `release_fence_count` counters stop changing. The latter is not an active-
   fence gauge; add one before claiming direct fence-reference leak coverage.
5. Every §4 fault scenario recovers cleanly, verified in a loop via debugfs.
6. syzkaller: multi-day run, 0 crashes, coverage plateau that **includes the
   recovery lines**.
7. Perf within an agreed ratio of the forward-port on Kernel C
   (`PERF_MAX_RATIO` in the `-compare.sh` gate; forward-port reference numbers in
   [`../tests/README.md`](../tests/README.md) "Observed results").

Until 1–7 hold, the hardware-validated stack stays the forward-port.

## 8. Scoped harness-maintenance backlog

This child scope improves the public harness without changing the risk order or
satisfying any production-readiness gate. Qualification work always takes
precedence, and each cleanup must preserve the command and evidence contracts
in [`../tests/conformance.md`](../tests/conformance.md).

The comparator-duplication item is closed: the five licensed
`*-suite-compare.sh` entry points are now thin launchers over the parameterized
`suite-compare.sh` engine, preserving suite-specific artifact policy and stable
commands.

- Give the remaining public single-purpose C/C++ probes a small manifest or
  runner so their coverage and privilege boundary are explicit. Destructive or
  memory-corruption triggers remain in the sibling `rock-5b-security`
  repository and must not be imported during this cleanup.
- Reconcile the external conformance seed's build helpers with the maintained
  `tests/build-*.sh` interfaces so the same third-party source is not built by
  two independently drifting recipes.

---

Cross-references: [rewrite-driver track](./rewrite-drivers.md) (what the drivers
implement, §2/§3 ABI ledgers, §6 pins), [`debug-kernel.md`](./debug-kernel.md)
(Kernel A / ramoops), [`kernel-drivers/tests/README.md`](../tests/README.md) (the smoke on-ramp)
and [`kernel-drivers/tests/conformance.md`](../tests/conformance.md) (the rewrite
build gate + `../rock-5b/build/rockchip-conformance` bundle), [`bsp-audit.md`](./bsp-audit.md)
(audit method), [`multicore-scheduling.md`](../mpp/docs/multicore-scheduling.md) (the
scheduling behaviour P4 exercises), [`rewrite-hard-ccu-finding.md`](../iommu/docs/rewrite-hard-ccu-finding.md)
(the opt-in HARD-CCU path in the §4 matrix), [kernel status](./forward-port-status.md) /
[`../../status.md`](../../status.md) (where results get recorded).
