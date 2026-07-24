# Kernel validation runbook

One procedure for validating **any** newly built or newly booted kernel on the
ROCK 5B — the vendor forward-port (production or KASAN debug builds), the
BSP-audit patch tips, the clean-room rewrite drivers, and the maximum-mainline
(maxline) integrations. It exists so a new kernel is never trusted from a
compile, a boot, or a single green suite: validation is the ordered ladder
below, and a kernel's support state advances exactly as far as the highest
rung it has passed **with recorded evidence**.

Deep references this runbook composes (it links rather than duplicates):
[`../tests/README.md`](../tests/README.md) (gate-by-gate details and env
tables), [`../tests/rewrite-conformance.md`](../tests/rewrite-conformance.md)
(conformance suites), [`debug-kernel.md`](./debug-kernel.md) (KASAN build),
[`rewrite-validation-plan.md`](./rewrite-validation-plan.md) (rewrite-specific
plan), [`../../packaging/ppa/kernel-maxline/README.md`](../../packaging/ppa/kernel-maxline/README.md)
(maxline install/test order), and the evidence rules in
[`../../CONTRIBUTING.md`](../../CONTRIBUTING.md).

## Principles

1. **Fail closed.** A gate that cannot run (missing device node, unreadable
   dmesg, absent vector) is a blocker or an explicit skip with exit `77` — it
   is never reported as a pass. Quarantined destructive cases fail the full
   gate when omitted, so a skipped required case cannot go green.
2. **Correctness and performance need different kernels.** Bit-exactness,
   memory-safety, and ABI gates are valid on any build, including KASAN debug
   builds and loaded systems. Throughput, latency, RSS, and soak-rate
   evidence counts **only** on a production (non-sanitizer) build on an
   otherwise idle board. Never benchmark under a debug kernel
   ([`debug-kernel.md`](./debug-kernel.md) §8).
3. **Identity before evidence.** No result counts until the booted kernel is
   fingerprinted (step 2). Debug and stock builds can share `uname -r`;
   `dpkg -i` can clobber same-version files. The fingerprint is what ties a
   log bundle to an exact binary.
4. **Destructive gates are opt-in and flagged.** Crash reproducers, foreign-fd
   probes, raw physical imports, and unbind-under-load can hang or crash the
   board. Run them only with recovery staged (step 0) and, for the crash
   reproducers, only on a build you can afford to lose.
5. **Crash traces need off-board capture.** Ramoops/pstore does **not**
   survive an RK3588 warm reset on this firmware
   ([finding](../../findings/2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md)).
   Before any gate that may crash the kernel, attach serial (`ttyS2`,
   1500000 baud) or netconsole; `journalctl -b -1` (persistent journal)
   catches the pre-crash tail but usually not the trace.
6. **Record as you go.** Every rung produces a dated artifact (per-suite log
   dirs, `summary.tsv`, dmesg scans). Results land in a dated finding, then
   the dashboards (step 9), under the
   [`re-verify-don't-re-date` rule](../../CONTRIBUTING.md).

## Step 0 — before installing anything: stage recovery

The ROCK 5B has no U-Boot boot menu; boot follows the `/boot/Image`,
`/boot/uInitrd`, and `/boot/dtb` symlinks. A bad install is recovered by
repointing or reinstalling from an SD rescue boot, so recovery is staged
*before* the install:

- `sudo bash ../scripts/kernel-revert.sh list` — know what is installed and
  active now.
- Keep the last-known-good kernel image+dtb+headers **debs** on
  rescue-accessible storage. Same-version rebuilds clobber the good files on
  `dpkg -i`, and only `kernel-revert.sh reinstall <deb>` gets them back.
- Verify an SD rescue boot that reaches the internal root actually works.
- The installers enforce this: both
  [`../scripts/install-combined-kernel.sh`](../scripts/README.md) and the
  debug installer refuse to run without `RECOVERY_READY=1`, and require the
  exact `PHASH='P####-C####'` so the wrong deb set cannot be installed.
- Maxline first boots follow the stricter recovery-first order in
  [`kernel-maxline/README.md`](../../packaging/ppa/kernel-maxline/README.md):
  install `public` before `wip`, never remove the working 6.18 kernel, keep
  physical/serial access, and prove storage, network, display, suspend, and
  **rollback** before touching any accelerator.

## Step 1 — build identity going in

Every build is named by its patch/config hash pair `P####-C####`, printed by
`build-kernel.sh` and embedded in the deb filenames. Record, at build
time: the `P####-C####`, the patch tail it corresponds to (e.g.
`0001`–`0057`), the base commit pin, and whether the config class
is production or debug/KASAN. A config-class change (debug ⇄ production)
changes `C####`; treat a surprising `C####` as a stopped-clock error, not a
detail ([`resyncing.md`](./resyncing.md) §4/§6 make re-deriving the pair a
mandatory propagation step).

## Step 2 — first boot: fingerprint before anything else

On the freshly booted kernel, capture and record all of:

```sh
uname -a                                   # release + build number #N
md5sum /boot/vmlinuz-$(uname -r)           # must equal the deb payload's md5
sha256sum /sys/kernel/notes                # the boot-unique GNU notes fingerprint
```

- The **vmlinuz md5 vs deb** check is the proof the booted image is the build
  you think it is: extract with
  `dpkg-deb --fsys-tarfile <image-deb> | tar -xO ./boot/vmlinuz-<release> | md5sum`
  and compare. (`uname -r` alone cannot distinguish a debug rebuild from
  stock; the `#N` counter resets on clean builds and is not unique either.)
- The **kernel-notes SHA-256** is the fingerprint downstream gates key on —
  the rockchip-vaapi risky-vector guard requires it verbatim (step 7).
- For debug kernels also cross-check `/boot/config-$(uname -r)` against the
  build's `.config` and confirm `kernel.panic_on_oops` matches the intent
  ([`debug-kernel.md`](./debug-kernel.md)).

Then the boot-health gate: `sudo bash ../scripts/validate-combined.sh` —
taint 0, all vendor codec nodes present (`rkvenc-core0/1`, two decoder cores,
`/dev/rga`, `/dev/mpp_service`), clean probe dmesg, no fatal signatures. On a
rewrite kernel the equivalent is the rewrite probe/KUnit checks; on maxline it
is the subsystem matrix from its README (storage → network → USB → PCIe →
display → suspend → rollback) **before** any accelerator work.

## Step 3 — accelerator smoke (any kernel flavor)

From [`../tests/`](../tests/README.md), in order; all exit `77` (skip, not
pass) when the device nodes are absent:

| Gate | Command | Pass |
|------|---------|------|
| Decoder liveness | `bash test-decode.sh` | 30 frames H.264+H.265 to NV12, exit 0 |
| Decoder correctness | `bash decode-differential.sh` | HW vs SW **PSNR = inf** (bit-exact) for every enabled codec (H.264/H.265/VP9, AV1 on av1-capable builds) |
| Encoder | `sudo bash encode-test-tiny.sh` | valid NAL streams, no IOMMU fault markers |
| Full pipeline | `sudo bash transcode-test.sh` | both rkmpp↔rkrga transcode directions, ffprobe-verified |
| One-shot | `sudo bash rewrite-smoke.sh` | ABI probe + decode + encode + transcode in one pass (valid on forward-port and rewrite) |

A smoke pass is *liveness plus bit-exactness at one operating point* — it
does not close conformance, concurrency, or lifetime gates.

## Step 4 — memory-safety gates (debug/KASAN builds)

Run on the KASAN/lockdep/DMA-debug build of the same patch tail
([`debug-kernel.md`](./debug-kernel.md)); "clean" everywhere means the shared
fatal-signature scan (`SUITE_DMESG_FATAL_RE` in `suite-common.sh` /
`kasan-scan.sh`) matched **zero** lines over exactly the workload window:

- `kasan-mpp-suite.sh` — the required 12-case MPP codec matrix under KASAN,
  every case green **and** an empty flag file.
- KASAN ABI replay (`abi-replay.sh` via the debug flow) — `abi_status=0`
  with a clean scan.
- Targeted reproducers for every previously fixed memory-safety bug that a
  patch-tail or flavor regression could reopen — currently
  `kasan-narrowed-repro.sh` (RESET_SESSION double-free, `0041`),
  `rga-session-uaf.sh cross` (⚠️ can crash unpatched kernels; `0051`/`0056`),
  and the clientless `RELEASE_FD` reproducer
  (`mpp-clientless-release-fd-uaf.c`, `0057` — the proven root cause of the
  VP9 `show_existing_frame` board hard-lock; see the
  [crash finding](../../findings/2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md)).
  Expected result on a fixed kernel: clean errno (`-EINVAL` where
  applicable), board stays up, zero flagged lines.
- Optional depth: `ioctl-fuzz-smoke.sh` with `fail-nth` fault injection,
  `iommu-machinery-fuzz.sh` (both debug-kernel-only modes).
- A whole-session journal sweep at the end of the boot
  (`journalctl -k | grep -E "$SUITE_DMESG_FATAL_RE"`-equivalent) so a fault
  outside a scan window cannot slip through.

A production-only validation (no debug build of the same tail) leaves this
step **open** and must say so in the status row.

## Step 5 — conformance suites (any kernel flavor)

Driver: `sudo PROFILE=<forward-port|rewrite> bash
../tests/rewrite-conformance-run.sh` (or the individual suites). Logs land in
`rockchip-conformance/logs/$PROFILE/<RUN_ID>-<suite>-suite/` with
`RUN_ID=YYYYMMDD-HHMMSS`; every suite brackets its workload with the dmesg
fatal scan and records `summary.tsv` + `artifacts.tsv` (byte counts +
SHA-256s). Reference required-case counts (they grow with optional media —
read `summary.tsv`, not folklore): MPP matrix 12/12 (KASAN set; ~30 full),
FFmpeg 24 cases with AV1 promoted (bit-exact PSNR `inf` for
H.264/H.265/VP9/AV1, Main10→P010 RGA), GStreamer ~102 required, librga suite
47, librga im2d smoke 28 with `LIBRGA_SMOKE_10BIT=1`.

For a kernel replacing a validated one, finish with the comparators
(`*-suite-compare.sh`) against the last validated run: any required
baseline-pass that the candidate fails, artifact SHA mismatch, or slowdown
beyond `PERF_MAX_RATIO` is a regression. The rewrite additionally requires
its paired-evidence audit (`rewrite-evidence-audit.sh`) and 232 green booted
KUnit cases — see
[`rewrite-validation-plan.md`](./rewrite-validation-plan.md) §7 for its full
definition of done.

## Step 6 — concurrency, recovery, stress

- `rewrite-recovery-stress.sh` — kill/reset(/opt-in unbind) around a busy
  workload; pass = correct errno, device usable after, counters move, clean
  scan.
- Application-level concurrency: the rockchip-vaapi concurrent-decode gates
  (step 7) run two hardware decoders in one process with bit-exact readback
  under normal, ASan/UBSan, and TSan drivers.
- Rewrite track: the §4 fault-injection/recovery matrix and multi-day
  syzkaller runs per its plan.

## Step 7 — the VA-API application gate and the risky-vector protocol

The [`yisding/rockchip-vaapi`](https://github.com/yisding/rockchip-vaapi)
driver's hardware gate doubles as an independent end-to-end validation of the
kernel's H.264/VP9 decode path (bitstream in → dma-buf out → byte-exact
compare vs software). Full command list in its
[`docs/TESTING.md`](https://github.com/yisding/rockchip-vaapi/blob/main/docs/TESTING.md):
host checks, object-lifecycle gates, zero-copy gates, concurrent-decode
gates, the pinned-vector conformance gate (normal + ASan/UBSan), and the
two-hour 4K soak.

**The risky-vector protocol** — the conformance set includes
`vp90-2-10-show-existing-frame2.webm`, which hard-locked the board on
kernels lacking the relevant fixes. Its harness is fail-closed on kernel
identity, and enabling it on a *new* kernel build is a deliberate,
audit-backed act:

1. **Audit** the new kernel's patch tail for the crash fixes (currently the
   `0054` register-translation bounds check and the `0057` clientless
   `RELEASE_FD` guard, plus the `0052`/`0053` hardening; re-derive this list
   from the crash finding if the tail has moved).
2. **Verify on the booted build** — run the deterministic reproducers from
   step 4 on this exact boot; they must fail safe with a clean journal.
3. **Fingerprint** — only then pass `RISKY_VECTORS=run` together with
   `RISKY_KERNEL_RELEASE=$(uname -r)` and
   `RISKY_KERNEL_NOTES_SHA256=$(sha256sum /sys/kernel/notes)` values for the
   audited boot, and record the new fingerprint in that repo's
   `docs/TESTING.md` audit note.

A stale checkbox, an environment leftover, or a same-release rebuild cannot
re-enable the vector: the release string *and* the notes hash must both
match the audited boot.

## Step 8 — soak

- VA-API 4K soak (`make check-soak`): paced two-hour single-process 4K
  decode; ≥25 fps, bounded RSS variation, zero fd growth, every pool/worker
  lifecycle paired. Durations below 7,200 s are smoke runs, not exit
  evidence. Run on a **production** build on an otherwise idle board — the
  fps floor and RSS bounds are performance claims (principle 2).
- Rewrite exit additionally requires its 72-hour soak with sanitizer silence
  and gauges returning to baseline (its plan, §7).

## Step 9 — record the evidence

Per [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) and
[`findings/TEMPLATE.md`](../../findings/TEMPLATE.md):

1. A dated finding (or an update to the owning doc) with: the full identity
   block from step 2, every gate run with its `RUN_ID`/log path, pass/fail,
   and an explicit **boundary** (what was *not* validated — e.g. "KASAN
   build: no performance claims"; "production build: memory-safety step
   open").
2. Advance the [`status.md`](../../status.md) row and
   [`status-ledger.md`](../../docs/status-ledger.md) note only as far as the
   evidence goes, with the date; update the matching next-gate row.
3. If the kernel is meant to *replace* a validated one: keep the previous
   build's debs (step 0), and only retire them after rollback has been
   exercised once on the new build.
4. Propagate per [`resyncing.md`](./resyncing.md) §6 (scorecard, dashboard,
   packaging checklists), and update the rockchip-vaapi fingerprints if step
   7 was completed.

## Flavor deltas at a glance

| | Forward-port | Rewrite | Maxline |
|---|---|---|---|
| Reference oracle | software decode / vendor encoder | the forward-port (dual-boot A/B, bit-exact) | n/a (subsystem support matrix) |
| Extra required gates | GStreamer suite; RGA patch-gate probes (P010/NV15/legacy-blit/over-4G) | 232 booted KUnit; counter checks; paired evidence audit; KCSAN race kernel; fault-injection matrix; 72 h soak | recovery-first subsystem order; `public` before `wip`; blacklist handling for HDMI audio |
| Perf-valid build | production combined build only | Kernel C only | production only |
| Current state anchor | [`forward-port-status.md`](./forward-port-status.md) | [`rewrite-conformance-gap-audit.md`](./rewrite-conformance-gap-audit.md) | [`kernel-maxline/README.md`](../../packaging/ppa/kernel-maxline/README.md) |

## Worked example — forward-port debug build `Pd222-C4ad2` (2026-07-22)

The Jul 22 validation of the `0001`–`0057` tail followed this
ladder end-to-end and is the template for reading the steps above: identity
(`6.18.38-current-rockchip64` `#4`, vmlinuz md5 matched the deb, notes
`db292410…`); step 4 on this boot — `0057` reproducer returns `-EINVAL`
with the guard log, `0056` cross reproducer 256,000 async submits clean,
whole-session journal sweep zero flagged lines; step 5 — MPP 12/12
(`20260722-073705`), KASAN ABI replay clean (`20260722-073858`), FFmpeg
24/24 (`20260722-073958`), GStreamer 98/102 with the four failures
root-caused to userspace
([finding](../../findings/2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md));
step 7 — the risky-vector audit named this boot's fingerprint and the
VA-API gates ran against it. Because `Pd222` is a KASAN build, its results
close **correctness** gates only; the production rebuild of the same tail
re-runs steps 2–3, 5, and 8 for the performance/soak claims
([`forward-port-status.md`](./forward-port-status.md)).
