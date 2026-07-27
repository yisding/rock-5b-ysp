# ROCK 5B zero-DTB race evidence

Controlled logs, minimal fixes, and source-path analysis supporting the
[2026-07-13 zero-DTB finding](../../2026-07-13-rock5b-u-boot-fit-dtb-race.md).

| File | Role |
|------|------|
| [`controlled-delay-prepatch.log`](controlled-delay-prepatch.log) | Reproduction before the Make dependency repair |
| [`controlled-delay-postpatch.log`](controlled-delay-postpatch.log) | Same controlled run after the repair |
| [`Makefile-controlled-delay-and-fix.patch`](Makefile-controlled-delay-and-fix.patch) | Minimal controlled-delay reproducer and dependency fix |
| [`armbian-rockchip-rk3588-enable-itb-deps-extension.patch`](armbian-rockchip-rk3588-enable-itb-deps-extension.patch) | Armbian extension form of the dependency repair |
| [`coreutils-copy-path-comparison.md`](coreutils-copy-path-comparison.md) | Jammy/Noble `cp`, Linux clone, runner, and adjacent Radxa dependency analysis |

The dated finding owns the result and trust classification. These files remain
the reproducible appendix; they are not a second current-state explanation.
