# RGA 10-bit UV plane offset still pixel-scaled — `0072` fixed the stride but not `0049`'s sibling site

> Scope: forward-port RGA driver on the **production PPA kernel**
> `linux-image-ysp-rockchip64 6.18.38+rk3588av1fwport20260724-0ubuntu1~rk1`
> (tail `0001`–`0073`, prod build `P272c-Cb831`) paired with
> `librga2 2.2.0+git20260724.b8def3e-0ubuntu1~rk1` — the kernel `0072` +
> librga `c80eea7`/`b8def3e` byte-stride pair.
> Source: booted board; `drivers/video/rockchip/rga3/rga_common.c`
> `rga_convert_addr()` (~:725–742, the `0049` block `6c7eb3efa3f0d`);
> harness under `kernel-drivers/tests/`, probes in session scratchpad.
> Date: 2026-07-24
> Trust: MEASURED / SOURCE-CONFIRMED

## Result

**The 10-bit byte-stride fix is incomplete, and the residual defect is a silent
wrong-output bug.** Kernel `0072` (`138f0de2c972`) converted the RGA3 *stride*
writer back to byte-literal `vir_w` and taught `rga_check_align()` the byte unit,
but it left the **sibling site introduced by `0049` (`6c7eb3efa3f0d`)** —
`rga_convert_addr()` in `rga_common.c` — still scaling `vir_w` by the pixel depth
when it derives the **UV plane offset**:

```c
if (img->compact_mode == RGA_10BIT_INCOMPACT)
        y_bytes = (uint64_t)img->vir_w * img->vir_h * 2;
else
        y_bytes = (uint64_t)img->vir_w * img->vir_h * 10 / 8;
img->uv_addr = img->yrgb_addr + y_bytes;
```

After `0072`, `vir_w` **is** the byte stride, so the Y plane is exactly
`vir_w * vir_h` bytes. The `×10/8` / `×2` double-applies the pixel depth —
precisely the error `0072` removed from the stride writer, one site over. The
correct expression is `y_bytes = (uint64_t)img->vir_w * img->vir_h;` for both
compact and incompact (the `compact_mode` branch becomes unnecessary).

Consequences, both observed on this boot:

1. **Tightly-sized surfaces still IOMMU-fault** — the UV read starts 26 880 B
   too late and runs past the mapping. Identical `EACCES` + `rk_iommu` read-fault
   signature to the pre-`0072` bug.
2. **Over-sized surfaces silently produce wrong chroma** — the blit *succeeds*
   and reads the UV plane from the wrong offset. This is worse than the fault:
   it is undetected corruption, and it is why the two GStreamer NV12_10 cases now
   report **pass** (their 193 536 B buffers clear the inflated 188 160 B read
   window, so the fault disappears while the chroma stays wrong). Those two
   greens are **false**; the suite does not validate chroma content.

The visible `EACCES` symptom that motivated `0072` is therefore fixed *for the
one geometry GStreamer happens to use*, while the underlying convention split
has been converted from a loud failure into a quiet one.

## Evidence and reproduction

- **Identity:** ROCK 5B; `6.18.38-ysp-rockchip64 #1`; **production** config class
  (no `CONFIG_KASAN`/`PROVE_LOCKING`/`DEBUG_OBJECTS`/`UBSAN`/kmemleak); taint 0.
  vmlinuz md5 `625857b0a17e6bde64bccab963888e91` — **equals** the installed
  package's `md5sums` entry, `dpkg -V` clean. Kernel-notes sha256
  `1a57bbc28e29814626551ce31fe6c1c14c09619e904155306aa086ec334e3250`, and that
  84-byte notes blob is present **verbatim inside**
  `/boot/vmlinuz-6.18.38-ysp-rockchip64` — so the booted image is provably the
  20260724 package payload, not a same-`uname` older build. That image contains
  the `0073` marker string `"rga2 page table reject"`, confirming the
  `0072`/`0073` tail is really in the running kernel. Kernel + librga installed
  together 2026-07-24 13:54 (`dpkg.log`); booted ~18:29.
- **Detection:** RGA3 is scheduler-preferred for these jobs; RGA2 (`core=4`)
  honors the byte-stride contract and passes throughout.
- **Exercise / pass-fail signal:**
  - `rga-10bit-legacy-stride-test <core>` (built per its header shim recipe),
    compact NV12_10 320×240, `vir_w=448` byte stride, below-4G CMA dma-bufs:
    **core 1 FAIL, core 2 FAIL, core 0 FAIL** (`EACCES` + `rk_iommu fdb60f00`/
    `fdb70f00` read fault, clean soft reset), **core 4 PASS**. Gate criterion is
    exit 0 on cores 1, 4 and 0 → **gate FAILS**.
  - **Quantitative root-cause proof** — bisecting the source allocation that
    makes the fault disappear (page granular):
    - compact: fails at 184 320 B, passes at 188 416 B → true requirement
      **188 160 B** = `560×240` (pixel-scaled Y) `+ 448×120` (byte-literal UV
      rows). Not 201 600 B, so the *stride* is byte-literal (`0072` landed) and
      only the *plane offset* is scaled.
    - incompact (`compact_mode=1`): fails at 266 240 B, passes at 270 336 B →
      true requirement **268 800 B** = `896×240 + 448×120`. Predicted from the
      `×2` branch before running — matched exactly.
  - **Direct wrong-chroma proof** (`uv-offset-content-test`, source
    over-allocated to 322 560 B so neither offset can fault; source filled
    `[0,107520)=0x00`, `[107520,134400)=0x40`, `[134400,…)=0xC0`):
    blit `ret=0`, and the destination chroma plane histograms
    **near-0x40 = 0, near-0xC0 = 9600** — the UV plane is read *entirely* from
    the buggy `×10/8` offset. Verdict printed: "UV read from the x10/8 BUGGY
    offset".
  - `rga-p010-test` (system librga): **both** cases fail at submit
    (`P010→NV12`, `P010→P010`). `rga-nv15-test`: **3/3 fail**
    (`NV15→NV12`, `P010→NV15`, `NV15→NV15`).
  - `LIBRGA_SMOKE_10BIT=1 librga-smoke.sh` against the system librga
    (`STAGE=/usr PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig`):
    base matrix green (AFBC32x8/RFBC64x4 dst correctly rejected, afbc16x16 and
    tile8x8 roundtrips ok, legacy BGRx/NV12/I420 ok), **`im2d P010->NV12`
    FAILS**, exit 1.
  - `ffmpeg-suite.sh` case `system_ffmpeg_hevc_main10_p010_rga`:
    **`pass` → `diagnostic-fail`, a regression against the
    `20260724-043221` baseline** on the previous kernel+librga pair. The P010
    readback is truncated — `packet size 6029312 < expected frame_size 6220800`
    for 1920×1080 P010 — so the Main10→P010 RGA path is now producing short
    frames.
- **Artifacts:** `../rockchip-conformance/logs/forward-port/20260724-184309-*`
  (`system`, `mpp-suite`, `librga-suite`, `gstreamer-suite`, `ffmpeg-suite`).
  Probes and their sources in the session scratchpad; not committed.

## Full validation ladder on this boot (production build)

Everything **except** the 10-bit legs is green:

- **Step 2 identity** — as above; boot health from `journalctl -k` (root-only
  `validate-combined.sh` not runnable): all codec nodes present, RGA hw
  `3.0.76831`×2 + `3.2.63318`, taint 0.
- **Step 3 smoke** — `abi-probe.sh` PASS, `abi-replay.sh` PASS
  (unsupported-descriptor errno `EFAULT` per the request-wrapper contract),
  `test-decode.sh` H.264+H.265 PASS, `decode-differential.sh` **H.264 / H.265 /
  VP9 / AV1 all bit-exact, PSNR = inf**, 30 frames each.
- **Step 5 conformance** (`RUN_ID=20260724-184309`, `PROFILE=forward-port`,
  `RUN_CONTINUE_ON_FAIL=1`, `SUITE_DMESG_SCAN=0` — `dmesg` is root-restricted):
  - **MPP official matrix 12/12 pass.**
  - **FFmpeg 21/21 required pass**; the sole non-pass is the *diagnostic*
    `system_ffmpeg_hevc_main10_p010_rga` regression above. The `FFDIR`
    `ffmpeg-rockchip-81` binary reports `libavcodec 63` and the W21 deadlock
    warning fired, but no transcode hung this run.
  - **GStreamer 100/102 required pass.** The two failures are the already-known
    userspace issues (`generated_transcode_h264_dmabuf_to_h265` caps
    negotiation, `event_flush_dec_h264` flush behavior). The three
    `generated_dec_h265_10_*` cases report pass — see the false-green caveat
    above.
  - **librga upstream demo matrix 9 pass / 38 fail**, versus 8/39 on the
    `20260724-042733` baseline — the same pre-existing `/data/*.bin` +
    missing `system-uncached*` heap environment gap, one case improved, never
    green on this board. The harness's own `ysp_librga_smoke` case passes.
- **Step 4 memory-safety** — **not applicable / open**: production build, no
  KASAN. Whole-boot fatal sweep with `SUITE_DMESG_FATAL_RE` = **0 matches**
  (but see the harness gap below, which limits what that zero means).
- **Steps 6–8** — not run.

## Harness gaps found this run

1. **The shared fatal-signature scan does not match RGA/rk_iommu page faults.**
   This boot contains **37** `Page fault at …` / `RGA IOMMU: read fault!` lines,
   and `SUITE_DMESG_FATAL_RE` matches **zero** of them. The
   `iommu[^[:alnum:]]*(fault|panic|oops)` alternative cannot match
   `rk_iommu fdb60f00.iommu: Page fault at …` (the text between `iommu` and
   `fault` is alphanumeric). Every "clean kernel scan" recorded by the suites is
   therefore blind to exactly the fault class this whole 10-bit investigation is
   about — including the 2026-07-24 production run, whose NV12_10 faults were
   caught by case failures and manual reading, not by the scan.
2. **`rga-p010-test` does not fail closed.** It printed
   `P010->NV12 submit FAILED` and `P010->P010 submit FAILED` and still
   **exited 0**, violating runbook principle 1. `rga-nv15-test` correctly
   exits 1. As written, `rga-p010-test` cannot gate anything.
3. **No 10-bit chroma-content gate exists for the legacy path.** The GStreamer
   NV12_10 cases only assert the pipeline runs, which is why a wrong-offset UV
   read reads as a pass. The `uv-offset-content-test` probe from this run is the
   shape such a gate needs.

## Fix and harness work — IMPLEMENTED 2026-07-24 (compile/behaviour-verified; NOT booted)

1. **Kernel `0074` (`710e6ad12af6`)** "video: rockchip: rga: derive 10-bit UV
   plane offsets byte-literally": `rga_convert_addr()` now computes
   `img->uv_addr = img->yrgb_addr + (u64)img->vir_w * img->vir_h`, dropping the
   pixel-depth scaling and the now-redundant `compact_mode` branch; 10-bit stays
   semi-planar so `v_addr` remains zero. `checkpatch --strict` clean (0 errors,
   0 warnings, 0 checks); `make drivers/video/rockchip/rga3/` builds clean.
   Exported to the tracked series; the series is now contiguous `0001`–`0074`.
2. **New gate `kernel-drivers/tests/rga-10bit-uv-offset-test.c`** — the content
   half of the pair. Over-allocates the source so neither offset can fault, then
   runs the same blit **three times**, varying only the bytes the correct offset
   reads, then only the bytes the scaled offset reads. Chroma that changes with
   the former and not the latter is a pass. Self-referential, so it needs no
   model of the colour conversion and cannot be satisfied by a blit that merely
   avoids faulting; covers compact **and** incompact; fails closed. On the
   booted (unfixed) kernel it correctly reports FAIL for both modes with a clean
   journal, and its "tracks scaled-offset bytes: YES" result proves the fixture
   markers reach the output — the discriminator is live, not vacuous.
3. **GStreamer suite now content-checks 10-bit chroma.** `verify_10bit_chroma`
   decodes the same generated input in software, scales it to the same geometry,
   and requires U and V within `GST_CHROMA_MIN_PSNR` (default 20 dB); wired to
   `generated_dec_h265_10_rga_scale`,
   `generated_dec_h265_10_env_disable_nv12_10` and their `422_10` siblings.
   Luma is reported but not gated, precisely because this defect leaves luma
   clean. **Verified to catch the bug on this boot:** the two cases that
   reported `pass` earlier in this same run now fail with
   `y=40.885 u=7.471 v=7.039` and `y=52.355 u=7.452 v=6.999` — clean luma, ~7 dB
   chroma. The 20 dB floor sits far from both the broken value (~7 dB) and the
   luma agreement band (40–52 dB).
4. **Fatal-signature scan widened — in all three copies, and de-noised.**
   `SUITE_DMESG_FATAL_RE` gained `Page fault at`, `bus error`, and an optional
   `(intr|read|write)` word in the `iommu` alternative; `kasan-scan.sh` switched
   from `grep -E` to `grep -aiE` to match `suite-common.sh`. `rga_job_err` /
   "submit failed" were deliberately **excluded** so fail-closed rejects do not
   read as faults.

   Running the root gates then exposed **a third copy** of the set —
   `run-root-gates.sh` carries its own standalone `FATAL_RE` (it must run as
   root without sourcing the suite helpers) and still had the old blind `iommu`
   alternative, so a root gate could report `kernel_flags=0` through a burst of
   RGA IOMMU faults. It now carries the same terms, with a comment tying the two
   copies together. (`iommu-machinery-fuzz.sh` has a fourth, local `FAULT_RE`
   that was already correct.)

   That run also exposed **three pre-existing false positives** that only bite
   under the case-insensitive scan, and which my first validation pass missed
   because it tested the three new terms *in isolation* rather than the
   assembled regex:
   - bare `BUG:` matches the harness's own marker `rga-mmu-de**bug:**`
     (6 lines in the `rga-mmu-debug` gate) — `run-root-gates.sh` had already
     learned this and used `\bBUG:`;
   - bare `Oops` matches `pstore.backend=ram**oops**` in the kernel cmdline;
   - `rga[^[:alnum:]]*(…|iommu)` matches the benign probe line
     `rga: IOMMU binding successfully`.

   Fixed with `\bBUG:`, `\bOops`, and by dropping `iommu` from the `rga`/`mpp`
   alternatives (genuine RGA IOMMU faults are caught by the dedicated `iommu`
   alternative, which requires the word `fault`/`panic`/`oops`). **Re-validated
   properly this time** — every line the assembled regex matches across the
   whole boot was classified, and all 72 matches are genuine faults
   (24 `Page fault at`, 24 `IOMMU intr fault`, 21 `IOMMU: read fault`,
   3 `IOMMU: write fault`), with 6/6 real fault signatures matched and 0/12
   benign lines matched. Both harness selftests and `check-repo.sh` pass.
5. **`rga-p010-test` now fails closed** — it scores both submits, corrupt luma,
   **non-neutral chroma**, and a non-bit-exact `P010→P010` copy into a `failures`
   counter and returns 1, matching `rga-nv15-test`. Verified: exits 1 on this
   boot where it previously exited 0.

6. **The duplicated fatal scans are now behaviour-pinned.** A new
   `FatalSignatureScanTests` in `scripts/tests/test_repo_checks.py` runs both
   copies (`suite-common.sh` and the standalone `run-root-gates.sh`) against
   fixtures of real captured fault lines and real benign lines: 8 must match,
   8 must not. It tests behaviour rather than spelling, so a reword passes but a
   reintroduced blind spot or false positive fails; a third case pins
   `kasan-scan.sh`'s case-insensitive grep. **Mutation-verified** — restoring
   the pre-fix `iommu` alternative and bare `Oops` makes it fail with 5 errors,
   naming both the missed faults and the `ramoops` false positive.

   The PPA source packages' duplicated `install-kernel-packages.sh` needed no
   new guard: `check_kernel_package_helpers()` in `check-doc-consistency.py`
   already asserts the three copies are byte-identical (maxline correctly
   excluded, since it genuinely diverges for out-of-tree builds). Verified live
   by injecting a one-line drift, which it caught immediately.

`scripts/check-repo.sh` passes (its patch-series regression test was updated to
expect the `0001`–`0074` tail and the new tip).

## Root-only gates — RUN 2026-07-24 22:05, all green

`sudo run-root-gates.sh` on this boot (`20260724-220535-root-gates`, hardware
`/usr/bin/ffmpeg 8.0.3-0ubuntu1~rk1`): `encode-test-tiny` PASS, `transcode`
PASS, `rga-mmu-debug` PASS, `iommu-machinery-fuzz` PASS, `mpp-debug-capture`
SKIP (exit 77 — reads rewrite debugfs absent on a forward-port kernel),
`vp9-show-existing` PASS. Every gate `kernel_flags=0`.

**Those zeroes were then re-verified against the corrected, strictly more
sensitive regex** (the run itself used the still-blind `run-root-gates.sh` copy):
re-scanning all six captured `*.kernel.txt` windows with the fixed set still
yields `flags=0` for every gate, so the PASS verdicts are genuine rather than an
artefact of the blind spot. The 10-bit defect does not perturb these paths —
consistent with it being confined to the RGA 10-bit plane-offset arithmetic.

## Corroboration and one gap (added 2026-07-24, from the TILE reconciliation)

A separate source-level reconciliation against both BSP branches
([TILE byte-stride finding](./2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md))
independently confirms the fix and narrows what it proves:

- **`0074` is right, and right for TILE too.** The BSP's `rga_convert_addr()` has
  no 10-bit branch and no `rd_mode` distinction at all — `uv_addr = yrgb_addr +
  vir_w * vir_h`, universally, on both `develop-6.1` and `develop-5.10`. The
  `×10/8` block `0074` deletes was never BSP code; it came from this repo's own
  `0049`. That is BSP-source confirmation of a fix measured here only on
  hardware, and it retracts a suspicion that `0074` over-reached into TILE.
- **TILE8x8 coverage added, and the defect is confirmed there on hardware.**
  Every measurement in the sections above was a RASTER blit;
  `rga-10bit-uv-offset-test` now also drives **TILE8x8 compact NV15**, and adds a
  tightly-sized run per mode. On this boot (no `0074`) it reports **5 failing
  checks**: raster compact, raster incompact and **tile8x8 compact** all show
  chroma tracking the pixel-scaled offset, and both tightly-sized runs fault
  (`RGA IOMMU: read fault`, IOVA `0xdd368400`). That is the first TILE 10-bit
  measurement in this project, and it **empirically confirms the source-only
  prediction** of the TILE finding, which had no hardware run: the defect is not
  raster-specific. What is still *not* proven is that `0074` fixes TILE — that
  needs the rebuilt kernel booted.
- **The librga on the board is superseded.** The installed
  `2.2.0+git20260724.b8def3e` gated its pixel→byte conversion on raster, so it
  sends TILE 10-bit `vir_w` as *pixels* — wrong against the BSP contract that
  `0072`/`0074` restore. Fork commit `4c26ddf` fixes it; **the packaged librga
  predates that**, so a TILE 10-bit gate on the current package would fail in
  userspace before reaching the kernel.

## Boundary

- `run-root-gates.sh` forces `/usr/bin/ffmpeg`, so the transcode gate exercises
  the shipping binary; the `FFDIR` build's W21 deadlock class is not covered by
  it.
- **Production build ⇒ memory-safety step open.** No KASAN/lockdep evidence on
  this tail; and per the harness gap above, the whole-boot sweep's zero is
  weaker evidence than it looks.
- **No performance or soak numbers were collected**, though this build would
  support them.
- **`0074` is compile-verified, not booted.** No hardware evidence exists that
  it makes the gates green — only that the code it removes is provably the
  source of the measured wrong offset. The gate set in "Why it matters" below is
  the proof still owed.
- **The new chroma checks are verified to FAIL on a broken kernel, not yet
  verified to PASS on a fixed one.** That asymmetry matters: a floor that a
  correct kernel cannot clear would be a false alarm. 20 dB is argued from the
  40–52 dB luma agreement measured on this boot (the same colour-range and
  matrix conventions apply to both planes, so correct chroma should land in a
  similar band, far above the ~7 dB broken value), but that is an inference
  until a `0074` kernel boots. `GST_CHROMA_MIN_PSNR` is tunable if it proves
  mis-set.
- Whether `0073` (RGA2 >4G page-table fail-closed) behaves correctly at runtime
  is **unverified** — the probe written for it used the wrong legacy ABI
  convention (`yrgb_addr` as fd rather than the virtual-address convention) and
  was not re-run. Only its presence in the image is established.

## Why it matters / follow-up

- The shipped stack still has **no correct 10-bit RGA path**, and the failure
  mode is now partly silent. Anything using im2d P010/NV15 (the ysp librga fork,
  ffmpeg-rockchip's RKRGA filters) either faults or gets wrong chroma; the
  Main10→P010 FFmpeg path has **regressed** from passing.
- **Verification gate for `0074` (owed, needs a rebuild + boot).** On a `0074`
  kernel, all of: `rga-10bit-legacy-stride-test` exit 0 on cores 1, 2, 4 and 0
  at the exact 161 280 B allocation; **`rga-10bit-uv-offset-test` exit 0 on all
  five checks — raster compact, raster incompact, tile8x8 compact, and both
  tightly-sized runs** (it drives the raw ioctl, so it is independent of which
  librga is installed and can run before the fixed package lands);
  `rga-p010-test` / `rga-nv15-test` green;
  `librga-smoke` `im2d P010->NV12` green; the two GStreamer NV12_10 cases green
  **with chroma PSNR above the floor** (not merely running); and
  `system_ffmpeg_hevc_main10_p010_rga` back to pass with a full-length
  6 220 800 B frame. Re-run the whole-boot sweep with the widened regex too —
  it should now be genuinely 0, not blind-0.
- **Still unverified: `0073`'s runtime behaviour.** Write a userptr probe using
  the correct legacy virtual-address convention (`yrgb_addr = 0`,
  `uv_addr` = user virtual base) and confirm an above-4G RGA2 legacy blit
  returns `-EOPNOTSUPP` with the `rga2 page table reject` log and no bus error.
- The rewrite drivers adopted byte-stride semantics end-to-end on 2026-07-24
  (`185d4dc` / `d5165ca`) including layout and validators, so they are
  **not** expected to carry this specific split — but they have no booted 10-bit
  evidence either, so that is an assumption, not a result.
