# Rewrite Phase 1 exact tips pass focused normal and test-disabled builds

> Scope: clean-room rewrite Phase 1 source boundary and focused cross-kernel build qualification
> Source: `rk3588-rewrite-6.18@fd068ad6aae656c917d610c35f63c1a738d3abac`; `rk3588-rewrite-mainline@a0dd1f6d68bd64c1316e2d2f7c9ac29b2d95e36a`
> Date: 2026-08-08
> Trust: SOURCE-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

Both exact Phase 1 source tips pass the warning-fatal clean-archive `normal`
and `test-disabled` profiles. Each of the four profiles built the Rockchip and
VSI IOMMU providers, MPP and RGA rewrite objects, and Rock 5B DTB. The normal
profiles compiled both embedded rewrite KUnit suites; the test-disabled
profiles proved that production objects do not depend on either suite.

The gate also passed the source-pinned 484-signal ownership inventory, the
308-signal KUnit source inventory, the exact 94 MPP + 152 RGA manifests, and
cross-tree identity. The seven tracked MPP/RGA source, Kconfig, ABI, and UAPI
files are byte-identical between the two commits. Explicit comparison of every
preserved archive copy against its committed worktree also passed.

Strict checkpatch over each complete provisional Phase 1 delta is clean: zero
errors, warnings, or checks from `c20fc8c1cbf76..fd068ad6aae65` and
`09e39082007dd..a0dd1f6d68bd6`. The two tip commits only correct continuation
alignment; they do not change generated inventory signals or behavior.

## Evidence and reproduction

The build used the repository's central `~/Code/.ccache` store through a
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

## Boundary

This is focused compilation and source-audit evidence, not a full kernel image,
module, or Debian-package build. The KUnit code compiled but did not execute.
Nothing was installed or booted, and this result does not establish codec/RGA
behavior, interrupt or reset recovery, live lockdep, memory safety, performance,
fuzzing, or soak stability. Phase 2 remains blocked on the exact 6.18 package,
install, boot, KUnit-runtime, and hardware replay gates.
