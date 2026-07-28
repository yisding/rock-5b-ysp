# Rewrite KUnit pre-phase is applied with an 84/148 gate

> Scope: clean-room MPP/RGA rewrite drivers, both maintained kernel trees, and
> the YSP qualification harness
> Source: `rk3588-rewrite-6.18@669697f23d3df` and
> `rk3588-rewrite-mainline@a49eb7575f436`; YSP
> `kernel-drivers/tests/rewrite-build-gate.sh`
> Date: 2026-07-28
> Trust: SOURCE-INSPECTED, CONFIG-INSPECTED, COMPILE-VERIFIED, PARTIAL

## Result

The rationalization plan's pre-phase is applied byte-identically to both
rewrite trees:

- `0a2d7b9414f58` / `aa18488c8642b` change both existing lifecycle-suite
  Kconfig defaults from `KUNIT_ALL_TESTS` to `n`;
- `669697f23d3df` / `a49eb7575f436` remove
  `rk_mpp_abi_layout_kunit()` and its registration, leaving the stronger
  compile-time size, offset, ioctl type/number/direction/size assertions as the
  ABI-layout owner; and
- the live boot gate is now exactly 84 MPP plus 148 RGA cases (232 total).
  Recorded 85-case boots remain historical evidence for their source pins.

The YSP harness now checks the configuration boundary directly. A synthetic
ordinary `KUNIT_ALL_TESTS=y` configuration resolves both rewrite drivers to
`y` while leaving both lifecycle suites disabled; qualification profiles still
force both suites to `y`. A new `test-disabled` build profile compiles the same
provider, rewrite-driver, and DTB targets without either suite. With
`VERIFY_ABI_STATIC_ASSERT=1`, the gate changes
`RK_MPP_MSG_V1_ABI_SIZE` from 24 to 25 in its disposable clean archive and
requires the test-disabled MPP object build to fail at the existing static
assertion.

The device-free source audit records 248 lexical signals in the two current
KUnit regions. The checked baseline permits those known signals and permits
their removal, but rejects a new production-singleton access, FD acquisition,
raw allocation, stack-owned async initializer, manual list link, or fatal
assertion after acquisition and before a registered cleanup action. It also
requires both maintained trees to produce the same signal set.

## Evidence

These commands passed on both source tips:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin JOBS=4 \
  bash kernel-drivers/tests/rewrite-build-gate.sh all

PATH=/usr/sbin:/usr/bin:/sbin:/bin JOBS=4 \
  REWRITE_BUILD_PROFILES=test-disabled \
  VERIFY_ABI_STATIC_ASSERT=1 \
  bash kernel-drivers/tests/rewrite-build-gate.sh all

python3 kernel-drivers/tests/rewrite-kunit-source-audit.py \
  /home/yi/Code/kernel/linux-6.18-rkvenc \
  /home/yi/Code/kernel/linux

bash kernel-drivers/tests/rewrite-kunit-log-check.sh --selftest
bash kernel-drivers/tests/rewrite-evidence-audit.sh --selftest

git -C /home/yi/Code/kernel/linux-6.18-rkvenc format-patch \
  --stdout HEAD~2..HEAD |
  /home/yi/Code/kernel/linux-6.18-rkvenc/scripts/checkpatch.pl \
  --strict --no-signoff --ignore COMMIT_MESSAGE -

# Repeated with /home/yi/Code/kernel/linux and its checkpatch.pl.

bash scripts/check-repo.sh
```

Both normal clean-archive builds compiled the Rockchip IOMMU provider, the
KUnit-enabled MPP/RGA rewrite objects, and the ROCK 5B DTB without warnings.
Both test-disabled builds compiled the same targets, and both deliberate ABI
mutations failed compilation as required. The audit reported `248 signals, 0
new, 0 baseline entries absent` for each tree. Strict source-content
checkpatch reported zero errors and warnings for both two-commit kernel series,
and the repository handoff gate passed all five stages.

## Boundary

This is source/configuration/compile evidence only. It does not execute the
84/148 suites, prove that a boot remains warning-free with lockdep live, clear
kmemleak, restore production services after KUnit, or validate any MPP/RGA
hardware path. The lexical audit prevents growth of named debt patterns; it
does not prove that the 248 baselined signals are correctly owned or cleaned
up.

## Verification gate

Build and boot a successor 6.18 qualification package from
`669697f23d3df`. Require exact 84/84 MPP plus 148/148 RGA KTAP, a complete
fatal-signature-free KUnit interval, live lockdep, a clean aged kmemleak scan,
restored production runtimes and every expected core, then proceed to isolated
ABI replay and the full paired hardware-conformance matrix.
