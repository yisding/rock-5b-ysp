# rockchip-vaapi ysp9 RC retires the VP9 quarantine and passes full sanitizer, RGA repeat, and package gates

> Scope: C15 hardware codecs/RGA and status track 14; `rockchip-vaapi`
> release-candidate source, on-board decode/conversion validation, parser
> safety gates, and Debian artifact qualification
> Source: `yisding/rockchip-vaapi` `main@de9005583440f0e5144999fed9c8245efa2c886c`;
> booted ROCK 5B kernel and userspace stack identified below
> Date: 2026-08-02
> Trust: **MEASURED** + **BOOT-VERIFIED** + **SOURCE-INSPECTED** +
> **PACKAGE-VERIFIED** + **CONFIRMED** (normal and ASan/UBSan board gates,
> checksum-exact RGA output, parser fuzzing, and isolated Debian lifecycle) +
> **PARTIAL** (the ysp9 packages are built but not installed; fresh-image,
> 512 MiB CMA, sandbox-enabled Firefox, physical HDR, and publication remain)

## Result

`rockchip-vaapi@de90055` is a clean, pushed ysp9 RC source point. The VP9
`vp90-2-10-show-existing-frame2.webm` stream no longer has a kernel-release or
kernel-notes interlock: it ran as an ordinary required conformance vector and
passed bit-exact both normally and with the complete ASan/UBSan driver. The
normal and sanitized matrices also completed all five VP9 determinism repeats
without a crash or mismatch.

The same source adds a permanent repeated small-geometry RGA discriminator.
On the production forward-port/vendor RGA3 driver, its default normal run
completed 30 decodes and 1,440 checksum-exact P010 frames:

| Geometry/workload | Runs | Exact frames | Result |
|---|---:|---:|---|
| 320x240 and 416x240, sequential plus mixed concurrency | 28 | 1,344 | PASS |
| 1280x720 control | 2 | 96 | PASS |

Every run required exactly 48 AFBC NV15-to-P010 conversions, 48 surface
assignments, zero cancellations, and an HEVC Main10 AFBC context. The scoped
kernel journal contained no RGA failure, IOMMU fault, timeout, oops, or fatal
kernel signature. A focused run with the complete ASan/UBSan driver added four
small-geometry runs plus one control, 240/240 exact frames, and another clean
kernel-journal interval.

This converts the one-off forward-port discriminator into a source-owned
regression gate. It does not change the separate rewrite-driver verdict: the
silent small-geometry destination-write failure remains proven there and has
still not been reproduced on this forward-port driver.

## Exact identity

| Item | Identity |
|---|---|
| Board | Radxa ROCK 5B |
| Kernel | `6.18.41-ysp-rockchip64 #1` |
| Kernel package | `6.18.41+rk3588av1fwport20260802-0ubuntu1~rk1` |
| Kernel notes SHA-256 | `20acca6b5e2e69b565f2d39e478cd78723424d14ff6bc9ba08b7189a7c673489` |
| RGA driver | production forward-port/vendor RGA3 |
| Source | `de9005583440f0e5144999fed9c8245efa2c886c` on `yisding/rockchip-vaapi` `main` |
| Debian version | `1.0.11+ysp9-0ubuntu1~rk1` |
| Driver deb SHA-256 | `f566d299038901fd9a6d4eec702452a2d715d6dc8d677b11dc6d2c0f104177f3` |
| Config deb SHA-256 | `c645da540ac91b6a98d5fa379238a89e685ed482f7c083ad85cbc636e6b4cf8e` |
| Packaged driver payload SHA-256 | `01b624a7985ffbe9167eaf051aca363e6d914888901fdd414438a8a6542ddd69` |
| Buildinfo SHA-256 | `c0f4c61924f706dffa09727ea1231083d68dfe710a946e02537aef2a5fe33dfe` |

The runtime gates loaded the driver built from the same source tree before the
clean commit and package build; no source file changed between those runs and
`de90055`. The packaged payload has not yet replaced installed ysp8, so this is
exact source and package provenance plus in-tree runtime proof, not installed-
ysp9 runtime proof.

## Full hardware matrices

Both of these exited zero:

```sh
FFMPEG=/usr/bin/ffmpeg make check
FFMPEG=/usr/bin/ffmpeg make check-sanitize
```

Each mode passed:

- all 17 pinned conformance cases with their required VA-API or intentional
  software-fallback path;
- the formerly guarded VP9 show-existing-frame case as an ordinary bit-exact
  VA-API decode;
- six H.264 reference/B-frame combinations;
- the 4K H.264 case;
- five VP9 determinism runs; and
- the intentional VP8 software fallback.

No ASan or UBSan report occurred. The narrower local safety ladder was also
green: unit tests, ASan/UBSan unit tests, TSan, Valgrind, ShellCheck, POSIX
shell syntax, and focused `clang-tidy` for the changed decoder path.

## Terminal conversion accounting

The earlier throughput validator assumed every completed RGA conversion must
be assigned to its original VA surface. FFmpeg's explicit output limit can
legitimately advance a reused surface fence after conversion but before the
assignment lock is acquired. The driver already discarded that stale route
safely; ysp9 now logs it as `output canceled`, and the throughput gate requires
the invariant:

```text
assigned + canceled == converted
```

It still requires every requested visible frame to be assigned, so the new
accounting cannot hide a missing presentation frame. The ordinary throughput
run passed with no cancellation:

| Codec | Visible | Converted | Assigned | Canceled | Throughput |
|---|---:|---:|---:|---:|---:|
| HEVC Main10 | 240 | 240 | 240 | 0 | 93.53 fps |
| VP9 Profile 2 | 240 | 265 | 265 | 0 | 103.61 fps |

A VP9 early-stop loop capped at 100 iterations exercised the terminal branch
on iteration 4. Its append-mode audit log contained 1,059 conversions, 1,058
assignments, one cancellation, and zero accounting failures. This confirms the
new branch is reachable and that the validator distinguishes a safe stale-
route discard from an RGA write or presentation failure.

## Parser and package gates

The committed seed corpora replayed cleanly under ASan/UBSan: 100 H.264, 415
HEVC, and 37 VP9 inputs. Each parser then completed 20,000 libFuzzer executions
without a sanitizer finding.

`make check-package-install` built the arm64 driver and architecture-independent
config packages from clean commit `de90055`, passed Lintian, and passed the
isolated clean install, upgrade, config purge, reinstall, and full-purge
lifecycle. Package metadata pins the config package to the exact driver
version and requires the shipping MPP, RGA, libc, and libva dependencies.

## Boundary and next gate

- Install both ysp9 packages, confirm the installed payload SHA-256 is
  `01b624a7985ffbe9167eaf051aca363e6d914888901fdd414438a8a6542ddd69`,
  and rerun a compact installed-driver conformance/RGA smoke before calling the
  binary itself release-qualified.
- Repeat the installed test on a genuinely fresh image with the intended
  512 MiB CMA configuration; this boot still has 256 MiB.
- Complete Firefox with the RDD sandbox enabled and physical HDR presentation.
- After those deployment gates, tag the source, create the GitHub Release, and
  publish the driver/config pair through the YSP PPA.
- The separate rewrite-driver RGA dropped-write root cause remains open; this
  finding only closes recurrence on the production forward-port driver.
