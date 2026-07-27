# Validation index — RGA/MPP driver testing (both tracks)

Single entry point for "how are these drivers tested, what's proven, and what's
left." It **maps** to the detailed docs — it does not duplicate them. Two driver
tracks are validated with one shared harness:

- **Forward-port** (`av1-fwport`, tree `linux-6.18-rkvenc-av1-fwport`) — the BSP
  driver forward-ported to 6.18. **The currently hardware-validated stack.**
- **Rewrite** (`rk3588-rewrite-6.18` / `rk3588-rewrite-mainline`) — the
  clean-room reimplementation. **Booted KUnit/probe bring-up exists, but no
  successful media-hardware run does.** It does not replace the forward-port
  until the rewrite definition-of-done (below) is met.
  The tips move faster than this page: they are maintained in
  [`rewrite-drivers.md`](./rewrite-drivers.md), which is where to read them.

## Source-of-truth map (don't re-derive these elsewhere)

| Concern | Canonical doc |
|---|---|
| Rewrite gate definitions / definition-of-done | [`rewrite-validation-plan.md`](./rewrite-validation-plan.md) §7 |
| Rewrite state-of-evidence + proof-gap ledger | [`rewrite-conformance-gap-audit.md`](./rewrite-conformance-gap-audit.md) |
| How to run the suites/comparators operationally | [`../tests/rewrite-conformance.md`](../tests/rewrite-conformance.md) |
| Test-script catalog + smoke on-ramp | [`../tests/README.md`](../tests/README.md) |
| Forward-port per-patch validation ledger | [`forward-port-status.md`](./forward-port-status.md) |
| Generic 9-step kernel validation ladder | [`kernel-validation-runbook.md`](./kernel-validation-runbook.md) |
| Whole-project status + watchlist | [`../../status.md`](../../status.md) |

If two docs disagree, the table above wins — for the *concerns* it routes. It
does not win on a moving commit hash or a gate result whose owning doc is
fresher; check the date on both before treating a row here as current.

Current reconciled numbers are **MPP KUnit = 85, RGA KUnit = 148, total = 233**
(the gate scripts require exactly `85`/`148`). Older docs may still cite the
superseded `86`/`122`/`208` at tips `8469183da227` / `9ff18809b5e0`.

## Comparative disposition

The full source/design comparison lives in
[`rewrite-drivers.md`](./rewrite-drivers.md#current-comparison-2026-07-26).
Its operational conclusion is:

| Question | Answer |
|----------|--------|
| Which track should users run now? | Forward port: it has the broad hardware/ABI scope and the conformance, sanitizer, root-gate, and production-performance record. |
| Why continue the rewrite? | Its public-API-only, session/job-owned, fail-closed design is easier to carry across kernels and makes ABI and recovery invariants executable. |
| What is the rewrite's principal cost? | Narrower hardware scope, two very large translation units, and an unclosed hardware-validation gap; KUnit coverage does not replace real register/IRQ/reset evidence. |
| How do the tracks relate? | The forward port is both the shipping implementation and the differential oracle. The rewrite has absorbed or architecturally dissolved several forward-port fixes, so comparison should continue rather than treating either line as disposable. |
| When should the default change? | Only after the rewrite produces the same media artifacts, survives the hostile recovery/fuzz/soak gates, and meets the production performance ceiling. |

## Coverage matrix — what is proven, per track

✅ hardware-proven · ⚠️ partial/device-free only · ❌ not done · — n/a

| Test category | Harness | Forward-port | Rewrite |
|---|---|---|---|
| Bit-exact decode H264/H265/VP9/AV1 | `decode-differential.sh` | ✅ PSNR=inf (repeated, incl. this session) | ❌ no media run |
| Encode rkvenc2 H264/H265 + slice + RC | `kasan-mpp-suite.sh`, `encode-test-tiny.sh` | ✅ clean | ❌ |
| RGA blit/scale/CSC/10-bit/AFBC | `librga-*`, `rga-mmu-debug.sh` | ✅ | ❌ |
| Conformance suites (mpp/librga/gst/ffmpeg) | `*-suite.sh` | ✅ FFmpeg 14–24 req, GStreamer 98–129, MPP 12/12 | ⚠️ device-free wiring only |
| KASAN memory-safety matrix | `kasan-mpp-suite.sh` | ✅ clean | ⚠️ booted KUnit exposed fixture Oops/UAF; no real MPP/RGA workload completed |
| Destructive ioctl PoC ladder (OOB/UAF/type-confusion) | `*-repro.c`, `rga-session-uaf.sh` | ✅ 0055/0060/0061/0063/0070 + cross-UAF | ❌ (surface differs; not run) |
| ABI replay / cross-profile diff | `abi-probe.sh`, `abi-replay.sh` | ✅ `abi_status=0` | ⚠️ comparator wired; RW side not booted |
| Booted KUnit (85 MPP + 148 RGA = 233) | `rewrite-kunit-log-check.sh` | — | ⚠️ follow-up boot passed the previous 85+147 result plan but emitted five RGA fixture debug-object warnings; the committed shared-IRQ policy test adds the 148th RGA case, so an exact clean rerun remains pending |
| Clean-source build gate (normal/memory/race) | `rewrite-build-gate.sh` | — | ⚠️ lifecycle-repaired 6.18 `db8251e` and mainline `fac7077` pass all six clean-archive normal/memory/race builds; repaired 6.18 package `P3138-Cad24` has the expected config, device-initcall symbols, image, and DTB; boot proof remains open |
| Fault-injection / recovery matrix | `rewrite-recovery-stress.sh`, root gates | ⚠️ root gates green on `Pc1f8-C9fc5` 2026-07-23 and on the production kernel 2026-07-24; the systematic fault-injection matrix is still unbuilt | ❌ not run |
| Differential FP↔RW byte-exact oracle | `*-suite-compare.sh`, `rewrite-evidence-audit.sh` | — | ❌ (needs RW booted) |
| Fuzzing under KCOV/KASAN (syzkaller/ioctl/iommu) | `ioctl-fuzz-smoke.sh`, `iommu-machinery-fuzz.sh`, `syzkaller/` | ⚠️ ran without KCOV | ❌ |
| 72 h multi-instance soak | (none yet) | ❌ | ❌ |
| Perf ratio on production (non-KASAN) kernel | root gates / conformance run | ✅ Published `…20260723~rk1` booted 2026-07-24: H.265 720p encode ~353 fps, transcode 20.8×/88× realtime | ❌ no Kernel C |

Reading: the forward-port is broadly hardware-proven for correctness,
memory-safety, and now production perf. The rewrite has compile evidence plus a
partial booted KUnit/probe record, but no successful userspace media workload;
the systematic fault-injection matrix, fuzzing-under-coverage, and the soak are
gaps for **both** tracks.

## Consolidated gap list

**Rewrite — the big one: no successful media-hardware evidence exists.** The
first boot exposed KUnit fixture poisoning and an RGA3 DT-resource conflict; a
follow-up passed the preceding 85+147 KTAP plan but emitted five RGA fixture
debug-object warnings, and both RGA3 cores then failed probe on incompatible
shared-IRQ flags. The 148-case/shared-IRQ tip is compile-verified but still
needs a warning-clean boot, all intended bindings, isolated ABI replay, and the
paired media matrix. Gap-audit
[§ six board runs](./rewrite-conformance-gap-audit.md) enumerates the minimum
set. See [`rewrite-drivers.md`](./rewrite-drivers.md) for exact tips and proof
boundaries.

**Rewrite — instrumentation debt:** an *active* (outstanding-reference) fence
counter is needed before RGA fence cleanup can be asserted — `release_fence_count`
is cumulative. This must land in the driver before a gate can check it.

**Rewrite — AV1:** the rewrite does not bind the VPU981/AV1 block at all. Separate
scoped implementation, tracked in [`../av1/docs/av1-rewrite-assessment.md`](../av1/docs/av1-rewrite-assessment.md);
AV1 stays diagnostic-only in the suites so the omission is explicit.

**Both tracks:** the systematic fault-injection/recovery matrix, fuzzing under
KCOV/KASAN, and the 72 h soak remain open. Production performance exists only
for the forward port; the rewrite still owes the cross-profile ratio.

**Forward-port — open defects a full run must still gate.** Four, and only four:

- RKVENC2 256-entry slice-FIFO overflow — **fixed both sides 2026-07-25,
  compile-verified only.** Kernel `0075` reserves the last FIFO slot for the
  terminal record and carries a dropped length forward; MPP `0002`/`0003` harden
  the vepu5xx poll loops. The `split_arg=4` hardware gate needs the paired
  userspace and is owed.
- VP9 `show_existing_frame` **leg-2 only** — the MPP-*userspace* buffer-slot /
  refcount anomaly. The kernel side is closed: the `0053`/`0054`/`0058` fixes
  held on the 2026-07-23 root gates and again on the production kernel
  2026-07-24, with the board surviving and `flagged_kernel_lines=0`.
- The 10-bit RGA stride tail `0072`–`0074` is compile-clean with its gate
  **owed**: the `0072` gate ran on-board 2026-07-24 and failed, which is what
  `0074` fixes ([UV-offset finding](../../findings/2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md)).
- Four of the eleven BSP-audit HIGH fixes have no targeted hostile gate on any
  boot — acquire-fence stress (`0063`), shutdown-outside-`irq_lock` (`0064`),
  missing-plane (`0065`), partial-handle unwind (`0067`). The series is
  boot-validated; those four individually are not
  ([per-bullet detail](./forward-port-status.md)).

Closed since this list was first written, kept here because other docs still
cite them as open: the MPP `process_request()` `list_add` double-add is
root-caused to a double `INIT_CLIENT_TYPE`, fixed as `0069`, and returns
`-EBUSY` on a booted kernel; a production (non-KASAN) image **is** validated —
Published `…20260723~rk1`, tail `0001`–`0071`, full conformance set plus root
gates green 2026-07-24; the root-only gates ran green on `Pc1f8-C9fc5`
2026-07-23 and again on that production kernel; and the RGA `mm_session`
debugfs UAF fix is FIX-RUNTIME-VERIFIED on `Pc1f8-C9fc5`. `status.md` tracks 1
and 2 are the live record for all four.

## The consistent plan to fully test the rewrite

The definition-of-done lives in [`rewrite-validation-plan.md` §7](./rewrite-validation-plan.md)
(7 gates) over the P1–P7 risk-ordered phases. Bring-up has reached boot/KUnit
and probe diagnosis. Package `P259b-Cad24` is no longer a boot candidate:
source and binary inspection found that its KUnit suites clear already-probed
live service singletons. The lifecycle-repaired package must clear that phase
before media qualification can start. Sequenced:

0. **Prereqs:** land the active-fence counter in the rewrite driver; obtain an
   AVS2 elementary-stream asset (cannot be generated); Kernel A is now built as
   `P3138-Cad24`, the repaired KASAN/UBSAN/lockdep/fault-injection + KUnit
   package from `db8251e`, while Kernel B = KCSAN remains to be packaged at the
   current tip.
1. **Re-run `rewrite-build-gate.sh`** (normal/memory/race) at the current tip —
   complete: both current tips pass all three clean-archive profiles.
2. **Boot Kernel A + Kernel B**; persist a **233-case green KUnit report**
   (`rewrite-kunit-log-check.sh`) tied to each boot fingerprint.
3. **P1 smoke** (`rewrite-smoke.sh`) then **P2 conformance**: all four suites
   under `PROFILE=rewrite RUN_COUNTER_CHECKS=1`, clean dmesg both kernels.
4. **P3 differential** byte-exact vs forward-port (dual-boot A/B; `*-suite-compare.sh`
   with `REQUIRE_ARTIFACTS=1`; `MPP_DUMP_OUTPUTS=1`) — RGA pixels, VDEC YUV,
   VENC-vs-VENC bitstream, 0 diffs. Needs the AVS2 asset.
5. **P4/P5** concurrency (KCSAN storms) + the **fault-injection/recovery matrix**
   (8 triggers, in a loop) + boot **HARD-CCU** mode separately.
6. **P6 fuzzing**: syzkaller multi-day + `ioctl-fuzz-smoke`/`iommu-machinery-fuzz`
   under KCOV/KASAN — 0 crashes, coverage plateau reaching recovery lines.
7. **72 h soak** on production Kernel C + **perf within `PERF_MAX_RATIO`** (1.25).
8. **`rewrite-evidence-audit.sh` passes in normal mode** → flip the
   hardware-validated stack from forward-port to rewrite and record it in
   `status.md`.

## Test-harness cleanup backlog (organization)

Non-blocking but worth doing so the harness stays maintainable:
- **Document `run-root-gates.sh`** and `mpp-vp9-show-existing-repro.sh` in
  `../tests/README.md` — the root-gate orchestrator is currently undocumented.
- **Prune stale README references** (`av1dec.c`, `load.sh`, `rollback.sh`,
  `probe-only.sh`, `run-encode-test.sh`, …) that no longer exist under `tests/`.
- **Collapse the 5 near-identical `*-suite-compare.sh`** (~219 lines each,
  differing only in glob + `REQUIRE_ARTIFACTS` default) into one parameterized
  comparator; normalize the `REQUIRE_ARTIFACTS` default (mpp=0 vs others=1).
- ~~**Single dmesg fatal-signature regex**~~ — **done.** Every scan now derives
  from `suite-common.sh:SUITE_DMESG_FATAL_RE`, including
  `iommu-machinery-fuzz.sh`. `run-root-gates.sh` keeps a standalone copy on
  purpose (it must run as root without the helpers) and can no longer drift
  silently: `scripts/tests/test_repo_checks.py` asserts the two are
  byte-identical, and all seven scans are pinned against a fixed corpus of real
  fault lines and benign look-alikes.
- **Corral the orphan PoC `.c` reproducers** (`mpp-*-repro.c`, `*-oob-repro.c`,
  `rga-*-test.cpp`, …) — findings-driven one-offs with no suite wrapper; give
  them a manifest/runner so coverage is visible.
- **De-duplicate build helpers:** `conformance/scripts/build-*.sh` parallels
  `tests/build-*.sh` for the same sources; `conformance/bin/` is empty.
