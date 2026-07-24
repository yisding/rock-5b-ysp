# Validation index — RGA/MPP driver testing (both tracks)

Single entry point for "how are these drivers tested, what's proven, and what's
left." It **maps** to the detailed docs — it does not duplicate them. Two driver
tracks are validated with one shared harness:

- **Forward-port** (`av1-fwport`, tree `linux-6.18-rkvenc-av1-fwport`) — the BSP
  driver forward-ported to 6.18. **The currently hardware-validated stack.**
- **Rewrite** (`rk3588-rewrite-6.18` @ `1fe46df86f1ca`,
  `rk3588-rewrite-mainline` @ `ec9a4a06ecf12`) — the clean-room reimplementation.
  **No booted-hardware evidence yet.** It does not replace the forward-port until
  the rewrite definition-of-done (below) is met.

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

If two docs disagree, the table above wins. Current reconciled numbers are
**MPP KUnit = 85, RGA KUnit = 147, total = 232** at rewrite tips
`1fe46df86f1ca` / `ec9a4a06ecf12` (the 2026-07-23 `harden rewrite driver
recovery` commit; the gate scripts require exactly `85`/`147`). Older docs may
still cite the superseded `86`/`122`/`208` at tips `8469183da227` /
`9ff18809b5e0`.

## Coverage matrix — what is proven, per track

✅ hardware-proven · ⚠️ partial/device-free only · ❌ not done · — n/a

| Test category | Harness | Forward-port | Rewrite |
|---|---|---|---|
| Bit-exact decode H264/H265/VP9/AV1 | `decode-differential.sh` | ✅ PSNR=inf (repeated, incl. this session) | ❌ never booted |
| Encode rkvenc2 H264/H265 + slice + RC | `kasan-mpp-suite.sh`, `encode-test-tiny.sh` | ✅ clean | ❌ |
| RGA blit/scale/CSC/10-bit/AFBC | `librga-*`, `rga-mmu-debug.sh` | ✅ | ❌ |
| Conformance suites (mpp/librga/gst/ffmpeg) | `*-suite.sh` | ✅ FFmpeg 14–24 req, GStreamer 98–129, MPP 12/12 | ⚠️ device-free wiring only |
| KASAN memory-safety matrix | `kasan-mpp-suite.sh` | ✅ clean | ❌ (KUnit-under-KASAN not booted) |
| Destructive ioctl PoC ladder (OOB/UAF/type-confusion) | `*-repro.c`, `rga-session-uaf.sh` | ✅ 0055/0060/0061/0063/0070 + cross-UAF | ❌ (surface differs; not run) |
| ABI replay / cross-profile diff | `abi-probe.sh`, `abi-replay.sh` | ✅ `abi_status=0` | ⚠️ comparator wired; RW side not booted |
| Booted KUnit (85 MPP + 147 RGA = 232) | `rewrite-kunit-log-check.sh` | — | ❌ machinery ready, never booted-green |
| Clean-source build gate (normal/memory/race) | `rewrite-build-gate.sh` | — | ✅ all 6 profiles green 2026-07-23 at current tip (`1fe46df`/`ec9a4a06`); not hardware |
| Fault-injection / recovery matrix | `rewrite-recovery-stress.sh`, root gates | ❌ root gates pending (see below) | ❌ never booted |
| Differential FP↔RW byte-exact oracle | `*-suite-compare.sh`, `rewrite-evidence-audit.sh` | — | ❌ (needs RW booted) |
| Fuzzing under KCOV/KASAN (syzkaller/ioctl/iommu) | `ioctl-fuzz-smoke.sh`, `iommu-machinery-fuzz.sh`, `syzkaller/` | ⚠️ ran without KCOV | ❌ |
| 72 h multi-instance soak | (none yet) | ❌ | ❌ |
| Perf ratio on production (non-KASAN) kernel | (none yet) | ❌ no production image | ❌ no Kernel C |

Reading: the forward-port is broadly hardware-proven for correctness and
memory-safety; the rewrite has **only device-free evidence**; and fault-injection,
fuzzing-under-coverage, soak, and perf are gaps for **both** tracks.

## Consolidated gap list

**Rewrite — the big one: no booted evidence exists.** Everything in the
definition-of-done requires a booted rewrite kernel, and none has ever run.
Gap-audit [§ six board runs](./rewrite-conformance-gap-audit.md) enumerates the
minimum set. The clean-source build gate **was re-run green (all six
normal/memory/race profiles) on 2026-07-23 at the current `1fe46df`/`ec9a4a06`
tip** — but that is compile evidence, not hardware.

**Rewrite — instrumentation debt:** an *active* (outstanding-reference) fence
counter is needed before RGA fence cleanup can be asserted — `release_fence_count`
is cumulative. This must land in the driver before a gate can check it.

**Rewrite — AV1:** the rewrite does not bind the VPU981/AV1 block at all. Separate
scoped implementation, tracked in [`../av1/docs/av1-rewrite-assessment.md`](../av1/docs/av1-rewrite-assessment.md);
AV1 stays diagnostic-only in the suites so the omission is explicit.

**Both tracks:** fault-injection/recovery matrix, fuzzing under KCOV/KASAN, the
72 h soak, and the perf ratio have no runs on either track.

**Forward-port — open defects a full run must still gate:**
- RKVENC2 256-entry slice-FIFO overflow — kernel + MPP unhardened (harness-mitigated only).
- VP9 `show_existing_frame` leg-2 (MPP userspace buffer-slot/refcount) still open; kernel `0052`/`0053` fix not yet booted-gated.
- MPP `process_request()` `list_add` double-add WARN — BSP-shared, untouched by `0057`-`0067`.
- No production (non-KASAN) image validated; Published PPA stops at `0040`.
- **Root-only gates** (encode/transcode/iommu-fuzz/vp9-crash) — pending; now unblocked by the `Pc1f8-C9fc5` debug build (carries the `0070` RGA fix).
- RGA `mm_session` debugfs UAF fix (`0070`) is COMPILE-VERIFIED only — runtime gate pending on `Pc1f8`.

## The consistent plan to fully test the rewrite

The definition-of-done lives in [`rewrite-validation-plan.md` §7](./rewrite-validation-plan.md)
(7 gates) over the P1–P7 risk-ordered phases. It cannot start until the rewrite
**boots**, which has never happened. Sequenced:

0. **Prereqs:** land the active-fence counter in the rewrite driver; obtain an
   AVS2 elementary-stream asset (cannot be generated); build a rewrite debug
   package (Kernel A = KASAN/UBSAN/lockdep/fault-injection + KUnit; Kernel B =
   KCSAN) at the current tip.
1. **Re-run `rewrite-build-gate.sh`** (normal/memory/race) at the current
   `1fe46df`/`ec9a4a06` tip — ✅ **done 2026-07-23, all six profiles green.**
2. **Boot Kernel A + Kernel B**; persist a **232-case green KUnit report**
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
- **Single dmesg fatal-signature regex:** `run-root-gates.sh` and
  `iommu-machinery-fuzz.sh` re-roll their own instead of sourcing
  `suite-common.sh:SUITE_DMESG_FATAL_RE`; they can silently drift.
- **Corral the orphan PoC `.c` reproducers** (`mpp-*-repro.c`, `*-oob-repro.c`,
  `rga-*-test.cpp`, …) — findings-driven one-offs with no suite wrapper; give
  them a manifest/runner so coverage is visible.
- **De-duplicate build helpers:** `conformance/scripts/build-*.sh` parallels
  `tests/build-*.sh` for the same sources; `conformance/bin/` is empty.
