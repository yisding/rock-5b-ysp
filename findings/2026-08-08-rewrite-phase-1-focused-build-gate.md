# Rewrite Phase 1 exact tips pass the full build matrix and 6.18 packaging

> Scope: clean-room rewrite Phase 1 source boundary, focused cross-kernel builds, and full 6.18 package construction
> Source: `rk3588-rewrite-6.18@ab69ece9986420b22aa83c510926f079610f3081`; `rk3588-rewrite-mainline@3a0da2f33e963de15cd4157c0ca02c2d87c80e04`
> Date: 2026-08-08
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PACKAGE-INSPECTED, PARTIAL

## Result

Both exact Phase 1 source tips pass the warning-fatal clean-archive `normal`,
`test-disabled`, KASAN/fault-injection `memory`, and KCSAN/lockdep `race`
profiles. Each of the eight profiles built the Rockchip and VSI IOMMU
providers, MPP and RGA rewrite objects, and Rock 5B DTB. The normal, memory,
and race profiles compiled both embedded rewrite KUnit suites; the
test-disabled profiles proved that production objects do not depend on either
suite. The memory profile enforces the package's 2,048-byte frame ceiling.

The gate also passed the source-pinned 484-signal ownership inventory, the
306-signal KUnit source inventory, the exact 94 MPP + 152 RGA manifests, and
cross-tree identity. The seven tracked MPP/RGA source, Kconfig, ABI, and UAPI
files are byte-identical between the two commits. Explicit comparison of every
preserved predecessor archive copy against its committed worktree also passed.

Strict checkpatch over each complete provisional Phase 1 delta is clean: zero
errors, warnings, or checks across 3,610 lines from
`c20fc8c1cbf76..ab69ece998642` and `09e39082007dd..3a0da2f33e963`.
The tip commits only move large KUnit fixtures to test-managed heap storage;
they do not change production code or generated production inventory signals.

The exact 6.18 tip also produced a replacement `rewrite-debug` Debian package set
against pinned Linux 6.18.43 base `7b923c78b50d2ec52690c4353e5aad8302e80599`.
The package build compiled the whole kernel, modules, headers, and DTBs and
embedded `(gab69ece99864)` in the ARM64 boot image. It did not install or boot
anything.

## Evidence and reproduction

The predecessor focused build used the repository's central `~/Code/.ccache` store through a
task-local cross-compiler wrapper and kept disposable state under
`~/Code/rock-5b/build/rewrite-build-gate/`:

```bash
PATH=~/Code/rock-5b/build/rewrite-ccache-bin:/usr/sbin:/usr/bin:/sbin:/bin \
CCACHE_DIR=~/Code/.ccache \
REWRITE_BUILD_PROFILES="normal test-disabled" \
REWRITE_BUILD_TMP_ROOT=~/Code/rock-5b/build/rewrite-build-gate \
KEEP_TMP=1 JOBS=8 \
bash kernel-drivers/tests/rewrite-build-gate.sh all
```

All four profiles exited zero and contained no `warning:` or `error:` line:

| Tree/profile | Preserved build directory | `build.log` SHA-256 |
|---|---|---|
| 6.18 normal | `rkcompat-rewrite-build.6.18.normal.LHpRvO` | `3c330c93f5b4854702ad3def639b7fad9e082e122b466bf2fd80edcd63fe5c40` |
| 6.18 test-disabled | `rkcompat-rewrite-build.6.18.test-disabled.N9Zksx` | `16ed6c4f27cfbbc75ff1a27b69698f38de7ede23e7be480cc8978f6d86f3e50e` |
| mainline normal | `rkcompat-rewrite-build.mainline.normal.A5drXN` | `761bb3a76bb23d5b9b105075d245166e378adf7ef3f2bee0b5060fea01b7bbf3` |
| mainline test-disabled | `rkcompat-rewrite-build.mainline.test-disabled.r8Z5D5` | `8fb29b55c8d109dab581e7cfd63957ad52e75fd00799fdb308c75b886bfefb1c` |

The final ccache observation was 2,134 hits and 555 misses among 2,689
cacheable calls, with the one allowed cache store using 21.1 of 30.0 GB.

## Predecessor full 6.18 rewrite-debug package

The package run kept the patch-export boundary at `v6.18.42`, pinned Armbian's
compiled base to the exact 6.18.43 commit, cleaned Kbuild state, and used the
central ccache store:

```bash
BASE_TAG=v6.18.42 \
ARMBIAN_KERNELBRANCH=commit:7b923c78b50d2ec52690c4353e5aad8302e80599 \
ARMBIAN_CLEAN_LEVEL=make-kernel \
ARMBIAN_USE_CCACHE=yes \
ARMBIAN_USE_TMPFS=no \
PREFER_DOCKER=yes \
bash kernel-drivers/scripts/build-kernel.sh rewrite-debug
```

Armbian build UUID `bff94651-da60-4386-8e12-1737dec0a73b` compiled kernel
release `6.18.43-video-rewrite-kasan-rockchip64` in 740 seconds and packaged it
in 57 seconds. Ccache reported 14,025 hits and 237 misses for the compile. The
new artifacts are:

| Package | Bytes | SHA-256 |
|---|---:|---|
| `linux-image-video-rewrite-kasan-rockchip64_26.08.0-trunk_arm64__6.18.43-S7b92-D6d03-P910c-Cad24-H1c44-HK01ba-Vc222-B3ab8-R448a.deb` | 649,892,032 | `6ab41283b325911dec6980458a7544fdcdfc0e78762dd7dd33f54fea069dac67` |
| `linux-dtb-video-rewrite-kasan-rockchip64_26.08.0-trunk_arm64__6.18.43-S7b92-D6d03-P910c-Cad24-H1c44-HK01ba-Vc222-B3ab8-R448a.deb` | 30,525,632 | `e2a935c170fac47b60e928763506116deef2c5acc436558161ec39cde802bfc7` |
| `linux-headers-video-rewrite-kasan-rockchip64_26.08.0-trunk_arm64__6.18.43-S7b92-D6d03-P910c-Cad24-H1c44-HK01ba-Vc222-B3ab8-R448a.deb` | 112,947,392 | `90192bddd46e648ab5787917b7537ddd70f6a4a2da989f94d97e46529b1f412c` |
| `linux-libc-dev-video-rewrite-kasan-rockchip64_26.08.0-trunk_arm64__6.18.43-S7b92-D6d03-P910c-Cad24-H1c44-HK01ba-Vc222-B3ab8-R448a.deb` | 7,884,992 | `935ab88117e30b57ede48b14dce8930c76320081f63eb87dfcb12522537ea419` |

All four control and data tar streams parse successfully. The packaged Rock 5B
DTB is a valid version-17 DTB. The packaged config SHA-256 is
`371568af516d28d604b397a2bd0d62a30eccbfbe5cd7630e93db653694509b8e`,
identical to the preceding package's resolved config. It enables KUnit,
KUnit debugfs/default autorun, both rewrite drivers and both rewrite test
suites, KASAN, lockdep, and the Rockchip IOMMU; it disables the three legacy
MPP/RGA driver paths. The patched Armbian worktree's seven tracked rewrite
identity files compare byte-for-byte with `fd068ad6aae65`, and the retained
`.o.cmd` files show both rewrite objects compiled through the central `ccache`
wrapper after their exact source copies were staged.

The plain kernel log is
`b2ff2bc69fca9528622dac50f4f40b7acda8a258613756f35f2db4bbf1486f59`.
It contains no compiler error, fatal diagnostic, failed target, or undefined
reference. This broad Armbian configuration is not warning-clean: it emits
1,729 compiler-warning lines across upstream and vendor code. Exactly 35 are
from the rewrite source, all `-Wframe-larger-than=2048` in embedded KUnit
functions (17 MPP, 18 RGA); no production rewrite function warns. The maximum
test frame is 4,256 bytes. This config uses generic KASAN, 4 KiB pages, and
VMAP stacks, so arm64 deliberately doubles each test kthread stack to 32 KiB.
The warnings are test-fixture debt to convert to KUnit-managed heap objects,
not evidence that the production driver failed to compile.

The run also exposed that the old build-stamp extension made its source suffix
part of an otherwise valid date without RFC comment delimiters. Kernel
initramfs and `CONFIG_IKHEADERS` tar helpers reported invalid-date fallback,
although the boot image retained the intended source identity and every Debian
payload remained valid. The extension now emits a parenthesized `(g<sha>)`,
validates the complete timestamp with GNU `date`, and the identity gate accepts
both old and new forms. Future `rewrite-debug` postflight also fails closed if
the packaged KUnit, sanitizer, lockdep, or rewrite-test symbols are absent.

## KUnit frame cleanup and replacement package

The package warning audit led to a test-only follow-up at
`ab69ece9986420b22aa83c510926f079610f3081` and
`3a0da2f33e963de15cd4157c0ca02c2d87c80e04`. Seventeen MPP and eighteen RGA
tests now allocate their dominant service, hardware, session, job, request, or
import fixtures with `kunit_kzalloc()`/`kunit_kcalloc()`. The two MPP fixtures
whose hardware object moved off stack also use ordinary delayed-work
initialization instead of the on-stack debug form. Production code, test
assertion ordering, cleanup ordering, and the 484-signal production inventory
are unchanged. The KUnit debt inventory fell from 308 to 306 because the two
on-stack async owners disappeared.

The exact tips then passed all eight warning-fatal focused profiles:

```bash
PATH=~/Code/rock-5b/build/rewrite-ccache-bin:/usr/sbin:/usr/bin:/sbin:/bin \
CCACHE_DIR=~/Code/.ccache \
REWRITE_BUILD_PROFILES="normal test-disabled memory race" \
REWRITE_BUILD_TMP_ROOT=~/Code/rock-5b/build/rewrite-build-gate \
KEEP_TMP=0 JOBS=8 \
bash kernel-drivers/tests/rewrite-build-gate.sh all
```

In particular, both KASAN/fault-injection `memory` profiles compiled with
`CONFIG_FRAME_WARN=2048` and emitted no warning. Both KCSAN/lockdep `race`
profiles also passed. The build gate rechecked cross-tree identity, both
source-bound audits, and both exact manifests before compiling each tree.

Armbian build UUID `ee1f2206-3956-407f-a163-01aafbdadd0b` rebuilt the pinned
Linux 6.18.43 composite in 937 seconds and packaged it in 73 seconds. Ccache
reported 14,212 hits and 50 misses. The replacement artifacts are:

| Package | Bytes | SHA-256 |
|---|---:|---|
| `linux-image-video-rewrite-kasan-rockchip64_26.08.0-trunk_arm64__6.18.43-S7b92-D6d03-P692f-Cad24-H1c44-HK01ba-Vc222-B3ab8-R448a.deb` | 649,902,272 | `c4e34838301d5723eef0fa656d30611ee840528527bb386ec9f699d4624440c1` |
| `linux-dtb-video-rewrite-kasan-rockchip64_26.08.0-trunk_arm64__6.18.43-S7b92-D6d03-P692f-Cad24-H1c44-HK01ba-Vc222-B3ab8-R448a.deb` | 30,525,632 | `1fdff38826a677e239100f9b7d78010ed2f9424be64797ae74ea8c73f5d62535` |
| `linux-headers-video-rewrite-kasan-rockchip64_26.08.0-trunk_arm64__6.18.43-S7b92-D6d03-P692f-Cad24-H1c44-HK01ba-Vc222-B3ab8-R448a.deb` | 112,947,392 | `cf4c16b1807b9c4f969b955ffd7b511e263e6242ec7bbe6c14c1080b95a5e6c5` |
| `linux-libc-dev-video-rewrite-kasan-rockchip64_26.08.0-trunk_arm64__6.18.43-S7b92-D6d03-P692f-Cad24-H1c44-HK01ba-Vc222-B3ab8-R448a.deb` | 7,884,992 | `513ae3c37f7b85aadc5c8cae024ab990f865cc5935efe57febfd56e1e21d008c` |

All four control/data tar streams parse. The packaged config remains exactly
`371568af516d28d604b397a2bd0d62a30eccbfbe5cd7630e93db653694509b8e`,
and the patched Armbian worktree's seven identity files compare byte-for-byte
with the committed 6.18 source. The boot image reports:

```text
Linux version 6.18.43-video-rewrite-kasan-rockchip64 ...
# SMP PREEMPT Sun, 09 Aug 2026 00:22:44 +0000 (gab69ece99864)
```

The replacement plain log SHA-256 is
`0f00802cec3b7b1636d58e77d6cd70a08480d7ea92a8e006bdf1f2452fc0fb25`.
It contains 1,694 compiler-warning lines, 20 fortify warning annotations, and
three build-infrastructure `WARNING:` lines, all unrelated to the rewrite. It
contains zero rewrite compiler warning, zero frame-size warning, and zero
invalid-date or tar-timestamp diagnostic. This closes the source/package
warning debt; it does not replace the deferred runtime gates.

## Boundary

This is full 6.18 package construction plus focused mainline compilation, not
runtime qualification. The KUnit code compiled but did not execute. Nothing
was installed or booted, and this result does not establish codec/RGA behavior,
interrupt or reset recovery, live lockdep, memory safety, performance, fuzzing,
or soak stability. Phase 2 remains blocked on installation of the exact 6.18
package, boot, KUnit-runtime, and hardware replay gates.
