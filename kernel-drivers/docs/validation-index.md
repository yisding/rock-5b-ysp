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

Current reconciled numbers are **MPP KUnit = 92, RGA KUnit = 152, total = 244**
(the gate scripts require exactly the cases named in
[`rewrite-kunit-manifest.tsv`](../tests/rewrite-kunit-manifest.tsv), which is
that split). Older docs may still cite the
superseded `86`/`122`/`208` at tips `8469183da227` / `9ff18809b5e0`.

## Comparative disposition

The full source/design comparison lives in
[`rewrite-drivers.md`](./rewrite-drivers.md#current-comparison-2026-08-04).
Its operational conclusion is:

| Question | Answer |
|----------|--------|
| Which track should users run now? | Forward port: it has the broad hardware/ABI scope and the conformance, sanitizer, root-gate, and production-performance record. |
| Why continue the rewrite? | Its public-API-only, explicit session/job ownership and fail-closed design are easier to carry across kernels and make ABI and recovery invariants executable. The proposed cluster/activation/task-execution objects remain future refactoring, not current-source evidence. |
| What is the rewrite's principal cost? | Narrower hardware scope, two very large translation units, and an unclosed hardware-validation gap; KUnit coverage does not replace real register/IRQ/reset evidence. |
| How do the tracks relate? | The forward port is both the shipping implementation and the differential oracle. The rewrite has absorbed or architecturally dissolved several forward-port fixes, so comparison should continue rather than treating either line as disposable. |
| When should the default change? | Only after the rewrite produces the same media artifacts, survives the hostile recovery/fuzz/soak gates, and meets the production performance ceiling. |

## Coverage matrix — what is proven, per track

✅ hardware-proven · ⚠️ partial/device-free only · ❌ not done · — n/a

| Test category | Harness | Forward-port | Rewrite |
|---|---|---|---|
| Bit-exact decode H264/H265/VP9/AV1 | `decode-differential.sh` | ✅ Exact `6.18.42` / `0092` package decodes all four codecs bit-exact at PSNR=inf; its independent VA-API campaign also includes pinned conformance and all 163 HEVC Main vectors | ❌ no media run |
| Encode rkvenc2 H264/H265 + slice + RC | `kasan-mpp-suite.sh`, `encode-test-tiny.sh` | ✅ clean | ❌ |
| RGA blit/scale/CSC/10-bit/AFBC | `librga-*`, `rga-mmu-debug.sh` | ✅ | ⚠️ Predecessor `g19634f4eebba` passes 12 maintained smoke operations and the imported-handle repair, then fails legacy RGB and official USERPTR paths; current fixes are compile-only. |
| Conformance suites (mpp/librga/gst/ffmpeg) | `*-suite.sh` | ✅ Exact `0092`: ABI PASS, MPP 12/12, FFmpeg 21/21 required + 3/3 diagnostic, GStreamer 100/102 with two classified userspace failures, and maintained direct librga smoke with 31 artifacts | ⚠️ Predecessor `g19634f4eebba` passes official MPP 12/12 and partial direct librga smoke; the librga run exposed two RGA defects fixed only in the unbooted current tip. GStreamer/FFmpeg remain unrun. |
| KASAN memory-safety matrix | `kasan-mpp-suite.sh` | ✅ Broad historical clean run; current IEP2 tail has its own KASAN/lockdep gates, but the current production package is non-KASAN | ⚠️ Exact 244-case KUnit interval is clean under KASAN/live lockdep and MPP 12/12 completes, but no full memory-safety workload matrix exists. |
| Destructive ioctl PoC ladder (OOB/UAF/type-confusion) | PoC ladder, now kept in the private `rock-5b-security` repository | ✅ 0055/0060/0061/0063/0070 + cross-UAF | ❌ (surface differs; not run) |
| ABI replay / cross-profile diff | `abi-probe.sh`, `abi-replay.sh` | ✅ `abi_status=0` | ⚠️ comparator wired; rewrite is booted but current-tip ABI replay is not recorded |
| Booted KUnit (92 MPP + 152 RGA = 244 current gate) | `rewrite-kunit-log-check.sh` | — | ⚠️ KASAN boot `#2` (`g19634f4eebba`, 2026-08-05) passes exact 92/92 MPP plus 152/152 RGA with zero failures/skips, a clean outer interval, and live lockdep. Current fix tip `df22eeef8757` keeps the manifest but extends an existing case and therefore still needs the compound rerun. |
| Clean-source build gate (normal/test-disabled/memory/race) | `rewrite-build-gate.sh` | — | ⚠️ On 2026-08-05, maintained 6.18 `df22eeef8757` on `v6.18.42` and mainline `518f59c9f1f8` on `v7.2-rc6` pass the warning-fatal clean-archive `normal` profile, including Rockchip/VSI IOMMU, both KUnit-enabled rewrite objects, and the ROCK 5B DTB. The source audit reports 306 known signals, zero new, and zero absent on both. Test-disabled, memory, race, and ABI-mutation results belong to older tips and were not silently carried forward. Current source remains unbooted. |
| Fault-injection / recovery matrix | `rewrite-recovery-stress.sh`, root gates | ⚠️ exact `0092` passes VP9 hard-lock regression plus RGA cancellation/reset stress with clean kernel windows; historical root gates are green, but the systematic matrix remains unbuilt | ❌ not run |
| Differential FP↔RW byte-exact oracle | `*-suite-compare.sh`, `rewrite-evidence-audit.sh` | — | ❌ (needs RW booted) |
| Fuzzing under KCOV/KASAN (syzkaller/ioctl/iommu) | `ioctl-fuzz-smoke.sh`, `iommu-machinery-fuzz.sh`; the syzkaller description is kept in the private `rock-5b-security` repository | ⚠️ ran without KCOV | ❌ |
| 72 h multi-instance soak | (none yet) | ❌ | ❌ |
| Perf ratio on production (non-KASAN) kernel | root gates / conformance run | ✅ Published `…20260723~rk1` booted 2026-07-24: H.265 720p encode ~353 fps, transcode 20.8×/88× realtime | ❌ no Kernel C |

Reading: the forward-port has broad historical hardware proof for correctness,
memory-safety, and production performance. Source, export, Published binaries,
and the installed/booted package now align at `0092` / `7d53bc7a3adc` /
`6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1`. That exact production artifact
has broad green functional/recovery evidence and a flat two-hour encode soak;
its two-hour decode workload and kernel scan pass while the strict userspace
fd-span oracle remains red. Because the production config has no KASAN/lockdep,
the three-patch tail is not exact-tip memory-safety qualified. The rewrite has
compile evidence plus exact predecessor KUnit, 12/12 official MPP, and partial
librga hardware evidence, but no complete current-tip media workload; the
systematic fault-injection matrix, fuzzing-under-coverage, and the soak are gaps
for **both** tracks.

## Consolidated gap list

**Rewrite — the big one: current-tip media qualification remains open.** Boot
`#2 g19634f4eebba` proves the exact 92+152 plan and official MPP 12/12; its
librga run proves the earlier handle-plane repair but exposes the RGA defects
fixed only at maintained tips `df22eeef8757` and `518f59c9f1f8`. Those tips have
source/build evidence only. They need a warning-clean boot, exact KUnit,
corrected full librga, all intended bindings, isolated ABI replay, and the
paired media matrix. Gap-audit
[§ six board runs](./rewrite-conformance-gap-audit.md) enumerates the minimum
set. See [`rewrite-drivers.md`](./rewrite-drivers.md) for exact tips and proof
boundaries.

**Rewrite — instrumentation debt:** an *active* (outstanding-reference) fence
counter is needed before RGA fence cleanup can be asserted — `release_fence_count`
is cumulative. This must land in the driver before a gate can check it.

**Rewrite — AV1:** the maintained source contains a VPU981 decoder backend,
VSI-IOMMU integration, ABI/KUnit coverage, and build wiring. It has no board
result. AV1 remains diagnostic by default in the suites for staged bring-up,
but a full current-tip qualification must promote it to required and close the
AFBC, fault, power-management, output, and differential gates tracked in the
[`AV1 rewrite assessment`](../av1/docs/av1-rewrite-assessment.md).

**Both tracks:** the systematic fault-injection/recovery matrix, fuzzing under
KCOV/KASAN, and the 72 h soak remain open. Production performance exists only
for the forward port; the rewrite still owes the cross-profile ratio.

**Forward-port — current qualification gaps.** The old fixed-count list had
gone stale as gates closed and the series grew. The live boundary is:

- Run exact `0092` under KASAN/lockdep through the RGA
  cancellation/session-close and decoder recovery/reset-contention gates. The
  production-profile functional result cannot establish memory-safety for the
  same tail.
- Run targeted hostile/ownership gates for the `0076`–`0087` audit tail,
  including RGA ABI/cross-session import, MPP lifetime, encoder, decoder, and
  the forced fragmented-DMA-BUF RGA2 mapped-SG path. Broad ordinary conformance
  still does not cover those paths; capture the root-only counters with them.
- Repeat the two-hour 4K decode soak without unrelated desktop activity and
  require the committed 32-fd span oracle as well as the retained driver-log
  lifecycle checks. The workload and kernel scan are green, but the oracle is
  not.
- Complete authenticated RDP encode/reconnect and physical-display VA-API
  integration; headless codec and encoder results do not substitute for those
  session environments.
- For IEP2, runtime-verify the libmpp BFF bootstrap fix and retain the
  untriggered software-timeout path as an explicit fault-injection gap. The
  other dedicated KASAN/lockdep IEP2 gates are green.
- Complete the systematic fault-injection matrix, KCOV/KASAN fuzzing, and the
  72-hour production soak. These remain wider-audience qualification debt.

The documented SD rescue + `kernel-revert.sh` commands are operator-validated;
rollback is no longer part of this open list. `status.md` tracks 1 and 2 are the
live release record.

## The consistent plan to fully test the rewrite

The definition-of-done lives in [`rewrite-validation-plan.md` §7](./rewrite-validation-plan.md)
(7 gates) over the P1–P7 risk-ordered phases. Bring-up has reached boot/KUnit
and probe diagnosis. Package `P259b-Cad24` is no longer a boot candidate.
Lifecycle-fixed `P3138-Cad24` reached userspace with every case and runtime
restored, but disabled lockdep in one MPP fixture and leaked another fixture's
nested allocation. The current source fixes must clear the compound phase
before media qualification can start. Sequenced:

0. **Prereqs:** land the active-fence counter in the rewrite driver; obtain an
   AVS2 elementary-stream asset (cannot be generated). `P91d6-Cad24` is
   disqualified by the case-83 lockdep report.
1. **Current clean build gate:** the `normal` profile passes on 6.18
   `df22eeef8757` and mainline `518f59c9f1f8`; test-disabled, memory, race,
   and ABI-mutation profiles retain older-tip evidence and must be rerun before
   a full handoff claim.
2. **Build and boot a successor package from 6.18 `df22eeef8757`**; persist a **244-case green
   KUnit report plus complete clean interval and live-lockdep report**
   (`rewrite-kunit-log-check.sh`) tied to the boot fingerprint.
3. **P1 smoke** (`rewrite-smoke.sh`) then **P2 conformance**: all four suites
   under `PROFILE=rewrite RUN_COUNTER_CHECKS=1`, clean dmesg both kernels.
4. **P3 differential** byte-exact vs forward-port (dual-boot A/B; `*-suite-compare.sh`
   with `REQUIRE_ARTIFACTS=1`; `MPP_DUMP_OUTPUTS=1`) — RGA pixels, VDEC YUV,
   VENC-vs-VENC bitstream, 0 diffs. Needs the AVS2 asset.
5. **P4/P5** concurrency (KCSAN storms) + the **fault-injection/recovery matrix**
   (8 triggers, in a loop) + boot **HARD-CCU** mode separately.
6. **P6 fuzzing**: syzkaller multi-day (its Rockchip description lives in the
   private `rock-5b-security` repository, not here) + `ioctl-fuzz-smoke`/`iommu-machinery-fuzz`
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
