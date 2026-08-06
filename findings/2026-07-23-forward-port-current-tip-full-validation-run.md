# Forward-port current tip (`0072`) full validation run — KASAN debug build

> Scope: forward-port kernel tip `0001`–`0072` (less `0012`) on the booted
> KASAN+lockdep debug build (`6.18-rkvenc-av1-fwport` @ `4401383a6d9b5`,
> `6.18.38-current-rockchip64 #8`); correctness + memory-safety rungs of the
> [kernel validation runbook](../kernel-drivers/docs/kernel-validation-runbook.md).
> Source: booted board; test harness under `kernel-drivers/tests/`.
> Date: 2026-07-23
> Trust: MEASURED

## Result

Ran the validation ladder against the **latest forward-port kernel** — a build
that carries the full `0059`–`0072` tail, including the `0072` RGA3
unaligned-base reject — as far as an unprivileged (`video` + `systemd-journal`)
session allows. **Every correctness and memory-safety rung is green, and `0072`
is confirmed present and working on this boot** (the scattered-userptr fuzzer now
fails closed with a driver reject instead of silently returning zero output). The **root-only gates
were then run with `sudo` and are all green** (encoder, transcode, rga-mmu,
iommu-fuzz, VP9 `show_existing_frame` survives clean; `mpp-debug-capture` an
expected forward-port skip). One **userspace defect** surfaced, unrelated to the
kernel: the harness's default `FFDIR` ffmpeg-rockchip binary (FFmpeg-**master**,
`libavcodec 63`) deadlocks on two `rkmpp`/`rkrga` transcode pipelines because it
lacks our `da5befc806` backpressure fix, while the shipping `/usr/bin/ffmpeg
8.0.3~rk1` (`libavcodec 62`, carries the fix) runs the same transcodes cleanly.

Because this is a KASAN/lockdep build, these results close **correctness and
memory-safety** only — no performance/soak claims (runbook principle 2).

> **Identity correction.** An earlier draft of this finding mislabelled the
> booted kernel as the pre-`0072` `Pc1f8-C9fc5` (`#7`) build and stated `0072`
> was absent. That was wrong: the booted vmlinuz was built 2026-07-23 07:39,
> *after* `0072` was committed (07:02), from `av1-fwport` HEAD `4401383a6d9b5`
> (the `0072` tip). Verified empirically below.

## Evidence and reproduction

- **Identity:** ROCK 5B; `6.18.38-current-rockchip64 #8`; KASAN+lockdep debug
  config (same class as `C9fc5`); vmlinuz md5 `6bb59e4aed8c71b3ed4747ac5dc226d1`
  (built 2026-07-23 07:39); kernel-notes sha256
  `94b76691cf89b86814ab1368bba01928fe34841989c05a8b28d15868866a66a3`; taint 0.
  Source tree `../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport` @ `4401383a6d9b5`, patch
  tail `0001`–`0072` (less `0012`). **No `P####-C####` hash is recorded in-repo
  for this build** — the docs stop at `Pc1f8-C9fc5` (`#7`, the `0071` tip); this
  `#8` build is the next rebuild that adds `0072`.
- **Boot health (step 2):** `validate-combined.sh` is root-only; equivalent
  checks replicated via `journalctl -k` — all codec nodes present
  (`rkvenc-core0/1`, `video-codec0/1`, `/dev/rga`, `/dev/mpp_service`), all
  probes succeeded (RGA hw `3.0.76831`×2 + `3.2.63318`). Whole-boot fatal sweep =
  **0** (only the chronic PCIe-PMU `possible recursive locking` lockdep WARNING at
  boot, pre-workload).
- **Smoke (step 3):**
  - `test-decode.sh` → H.264 + H.265 PASS (~2100 fps @ 320×240).
  - `decode-differential.sh` → **H.264 / H.265 / VP9 / AV1 all bit-exact,
    PSNR = inf** vs software reference.
  - `abi-probe.sh` / `abi-replay.sh` → PASS (unsupported-descriptor errno
    `EFAULT`, per the documented request-wrapper contract).
  - `librga-smoke.sh` → base fully green (EXIT 0). AFBC32x8/RFBC64x4 dst
    correctly rejected. 10-bit P010 case **skipped**: the staged
    `airockchip-librga` (`v1.10.6_[3]`) is not the P010-patched ysp fork
    (`format 0x4000(unknown)` in *userspace*, before the kernel).
- **Memory-safety (step 4, journal-scanned via `sanitizer-scan.sh`):**
  - `kasan-mpp-suite.sh` (`20260723-104152`) → 12/12 required cases pass,
    `flagged_kernel_lines=0 clean=1`.
  - `reset-session-kasan.sh` (`20260723-104210`) → `abi_status=0 flagged=0`
    (RESET_SESSION double-free `0042`).
  - The next three reproducers have since moved to the private
    `rock-5b-security` repository and are no longer in this tree; the results
    recorded here stand as measured on this boot.
  - `mpp-double-init-repro` (`0070`) → 2nd `INIT_CLIENT_TYPE` returns `errno=16`
    (`EBUSY`); re-init guard holds, no WARN, no UAF.
  - `mpp-clientless-release-fd-uaf` (`0058`) → ioctl returns `-1`, board survives.
  - `rga-session-uaf.sh cross` (`0052`/`0057`) → 2000 rounds / **64,000 async
    submits, `submit_fail=0`, `flagged=0`**.
- **`0072` RGA3 unaligned-base reject — runtime-VERIFIED on this boot:**
  `rga-iommu-fuzz` (device access only) drove scattered/contiguous userptr copies
  across cache-line offsets. A non-16-aligned IOMMU base is now **rejected** by
  the driver (`rga_mm_get_buffer_info` → `-EINVAL`; kernel log
  `Can't get src buffer info from handle` → `submit failed`) rather than silently
  returning all-zero pixels (the pre-`0072` bug). Confirmed the reject set equals
  the corrupt set: `rga_shadow_setup()` runs for *any* userptr whose offset isn't
  cache-line aligned (contiguous or scattered), so every `offset % 16 != 0`
  coincides with a shadow head whose pre-offset bytes are unowned — exactly what
  `0072` rejects. After correcting the fuzzer's oracle (below), all fuzz modes
  pass: `copy/all × both/src/dst` → `FAIL=0`.
- **Conformance (step 5):**
  - MPP official matrix authoritative coverage = the KASAN 12-case run above.
  - `ffmpeg-suite.sh FFMPEG_REQUIRE_AV1=1` (`20260723-104740`, `system` runtime
    via `/usr/bin/ffmpeg`, `SUITE_DMESG_SCAN=0` since `dmesg` is root-restricted):
    24 cases. Decode/PSNR **bit-exact (inf)** for H.264/H.265/VP9/AV1; encode
    option cases pass; `hevc→h264`, `av1→h264`, `av1→hevc` transcodes produce
    valid non-empty output. **Two userspace failures (see below).**
- **Artifacts:** `../rock-5b/build/rockchip-conformance/logs/forward-port/20260723-104152-kasan-mpp-suite/`,
  `.../20260723-104210-kasan-narrowed/`,
  `../rock-5b/build/rockchip-conformance/logs/rewrite/20260723-104740-ffmpeg-suite/`.
  Raw captures, not committed.

## Root-only gates — RUN 2026-07-23, all green

`sudo run-root-gates.sh` on this boot (`20260723-141619-root-gates`):
`encode-test-tiny` PASS, `transcode` PASS, `rga-mmu-debug` PASS,
**`iommu-machinery-fuzz` PASS** (the `0072` scatter reject end-to-end, with the
corrected oracle), `mpp-debug-capture` SKIP (exit 77 — reads rewrite debugfs
absent on a forward-port kernel), `vp9-show-existing` PASS (30 loops × 4
concurrent decodes of the `show_existing_frame` vector + 60 s deferred-fault wait;
board survived, `flagged_kernel_lines=0 clean=1`, no trace — the `0053`/`0054`/`0058`
fixes hold). Every fatal-signature kernel scan was clean.

## Test-harness fixes applied this run

- `rga-iommu-fuzz.cpp`: the oracle scored the `0072` reject as a failure
  (`PASS=0 FAIL=96`). Corrected it to **expect a reject whenever either buffer's
  IOMMU base offset is non-16-aligned** (a reject → pass), while still requiring a
  16-aligned base (and the offset-0 contiguous reference) to run and match, and
  still failing a wrong-content success (the original silent-zero bug). All modes
  now `FAIL=0`.
- `run-root-gates.sh`: the VP9 `show_existing_frame` gate
  (`mpp-vp9-show-existing-repro.sh`) is no longer behind `--with-vp9-crash`; it
  runs by default as a normal regression gate (the crash is fixed by `0053`/`0058`),
  still wrapped in `kernel.panic_on_oops=0` for its window.
- `mpp-vp9-show-existing-repro.sh`: its default `IVF` was a stale absolute path
  from a *prior session's* scratchpad (a dead file), so the gate failed
  `missing VP9 ES` before decoding anything. Repointed the default to the tracked
  vector `$CONFORMANCE_ROOT/assets/vp9-show-existing.ivf` (overridable via `IVF=`).

## The two FFmpeg failures (userspace ffmpeg-rockchip missing `da5befc806`; kernel + shipping 8.0.3 clean)

The deadlocks are in the `FFDIR` binary (`../rock-5b/ffmpeg/ffmpeg-rockchip/ffmpeg`),
which reports **`libavcodec 63` (FFmpeg master**, `N-125363-g53e76abdc7`). Its
directory's `RELEASE` file says 6.1 and the checked-out source headers say
`LIBAVCODEC_VERSION_MAJOR 60`, so the *binary is a stale master build mismatched
with the 6.1 source now at that path* — the runtime `libavcodec` version is the
authoritative fingerprint, not the RELEASE file. The **installed
`/usr/bin/ffmpeg 8.0.3-0ubuntu1~rk1`** (`libavcodec 62`, carries our
`fix/rkmpp-output-timeout@da5befc806`) runs the *same* transcodes cleanly.

- `system_ffmpeg_transcode_h264_to_hevc_rkrga` (**required**, `FFDIR` master
  binary): the `h264_rkmpp → scale_rkrga → hevc_rkmpp` pipeline **deadlocked** —
  all 17 threads `S`-state on `futex_do_wait`, **0-byte** output (`ffprobe` →
  `hevc,0,0`). Ran ~30 min until manually `SIGKILL`ed; the suite's per-case
  `timeout 180` had no `-k` fallback and ffmpeg's `SIGTERM` handler deadlocked on
  the same futex, so it was never reaped (now fixed — `timeout -k`).
- `system_ffmpeg_hevc_main10_p010_rga` (**diagnostic**, `FFDIR` master): same
  signature, `SIGKILL`ed at 210 s, recorded `diagnostic-fail`.
- **Shipping 8.0.3 is clean on both:** `run-root-gates.sh` forces
  `/usr/bin/ffmpeg` and its transcode gate PASSED (48 frames, both directions);
  a direct `hevc_main10 → scale_rkrga=p010le → hwdownload` run on 8.0.3 produced
  the full 373 MB output (exit 0).
- **Kernel attribution ruled out:** threads block on a userspace `futex` (not
  D-state); the RGA driver logged a clean `soft reset` on session exit; no
  `hung_task`, no paging fault, no KASAN; the reverse + AV1 transcodes (even on
  the master build) drove the same kernel RGA/MPP fine — same kernel, two
  userspace builds, only the one without `da5befc806` hangs. This is the encoder
  input-backpressure / decoder receive-loop hang class already catalogued in
  [`fix-candidates.md`](../video-libraries/ffmpeg/docs/fix-candidates.md) and
  fixed on our 8.0 line — **not a new finding** (status watchlist W21). The fix
  is not yet forward-ported to main/master.

## Boundary

- **KASAN build → no performance/soak/throughput claims.** Steps 8 (soak) and the
  production-build perf rungs are untouched.
- **Root-only gates: RUN and green** (see section above) — `encode-test-tiny`,
  `transcode`, `rga-mmu-debug`, `iommu-machinery-fuzz`, `vp9-show-existing` all
  PASS; `mpp-debug-capture` an expected SKIP. No longer blocked.
- **P010 correctness NOT re-established this run:** the librga 10-bit smoke and the
  FFmpeg Main10→P010 case were blocked by the unpatched staged librga and the
  userspace deadlock respectively. The kernel `0049`/`0051` P010 fixes were
  validated on prior builds, not re-confirmed here.
- Conformance `dmesg` bracketing was inert (root-restricted); the whole-boot
  `journalctl` fatal sweep substitutes for it.

## Why it matters / follow-up

- The forward-port tip `0001`–`0072` is **memory-safety- and correctness-clean on
  hardware** for every gate a non-root session can drive, and `0072`'s reject is
  now runtime-verified (previously compile-verified only).
- The root-only gates are now green on this tip too (correctness scope).
- **Follow-up:** rebuild a **production** (non-KASAN) image of this `0072` tail for
  the performance/soak rungs and install/rollback. The `FFDIR` ffmpeg-rockchip
  transcode deadlock (W21) and the `ffmpeg-suite.sh` width-0/`timeout -k` harness
  gaps remain.
