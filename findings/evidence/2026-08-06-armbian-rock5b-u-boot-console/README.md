# Armbian ROCK 5B U-Boot console-option survey evidence

Supports [Armbian ROCK 5B vendor U-Boot disables its only interactive
console](../../2026-08-06-armbian-rock5b-u-boot-console-options.md).

| Artifact | What it is |
| --- | --- |
| [`0001-rock-5b-enable-armbian-u-boot-console.patch`](../../../boot-firmware/patches/0001-rock-5b-enable-armbian-u-boot-console.patch) | Shelved mail patch against `armbian/build` `main`; it adds only a board-scoped Radxa-U-Boot console patch |

## Source pins

| Tree | Pin |
| --- | --- |
| `armbian/build` | `origin/main@61ba9d2a082c5be257b6b78888b2954c18302cf5` |
| `radxa/u-boot` | `next-dev-v2024.10@39cd993e5d6296635438e84f4576b3a9bf76f86e` |
| `radxa/u-boot` | `next-dev-v2026.01@e27cb147b4f8c7dcd22afe702e0c6c4821150cd8` |
| upstream `u-boot/u-boot` | `v2026.01@127a42c7257a6ffbbd1575ed1cbaa8f5408a44b3` |

The Armbian and Radxa remote refs were refreshed immediately before capture on
2026-08-06. The branch pins are recorded because both Radxa branch names move.

## Reconstructing the Armbian policy counts

From an `armbian/build` checkout containing the pinned commit:

```bash
git grep -n -E '(^|[[:space:]])(declare -g )?BOOTDELAY=' \
  61ba9d2a0 -- config ':!config/optional/**'

git grep -n 'CONFIG_DISABLE_CONSOLE' \
  61ba9d2a0 -- config patch
git grep -n 'CONFIG_SYS_CONSOLE_INFO_QUIET' \
  61ba9d2a0 -- config patch
git grep -n 'CONFIG_BOOTDELAY' \
  61ba9d2a0 -- config patch
```

**Pass/fail signal:** 60 Armbian `BOOTDELAY` assignments resolve textually to
57 assignments of `1`, two of `2`, and one of `0`; the only zero is
`config/sources/families/include/rockchip64_common.inc`. No board file assigns
zero.

The 163-descriptor inheritance scope comes from board files whose
`BOARDFAMILY` is one of the five configurations that source the common include:

```bash
git grep -n 'rockchip64_common\.inc' 61ba9d2a0 -- config/sources/families
git grep -n 'BOARDFAMILY=' 61ba9d2a0 -- config/boards
```

The descriptors split into 65 `rockchip64`, 43 `rk35xx`, 53
`rockchip-rk3588`, one `seeed-rk3576`, and one `seeed-rk3588`. Comparing those
paths with the board-level `BOOTDELAY` search leaves 120 files with no local
assignment.

## Reconstructing provenance

```bash
git blame -L 15,15 61ba9d2a0 -- \
  config/sources/families/include/rockchip64_common.inc
git blame 150ac0c2a^ -- config/sources/rockchip64.conf
git show --format=fuller 43b3beed8b -- config/sources/rk3328.conf
```

**Pass/fail signal:** the line traces through the 2019 family split to
`43b3beed8b` (2017-08-16, initial RK3328 Rock64 support).

From the Radxa U-Boot checkout:

```bash
git blame next-dev-v2024.10 -- configs/rock-5b-rk3588_defconfig
git show --format=fuller 0d3169e641d -- \
  configs/rock-5b-rk3588_defconfig
```

**Pass/fail signal:** `0d3169e641d` adds only
`CONFIG_DISABLE_CONSOLE=y`, with subject
`rock-5b-rk3588_defconfig: disable console`.

## Reconstructing the defconfig survey

For each Radxa pin, count all `configs/*_defconfig` paths and then inspect the
three exact assignments:

```bash
git ls-tree -r --name-only 39cd993e5 -- configs
git grep -n -E '^CONFIG_(BOOTDELAY|DISABLE_CONSOLE|SYS_CONSOLE_INFO_QUIET)=' \
  39cd993e5 -- configs

git ls-tree -r --name-only e27cb147b -- configs
git grep -n -E '^CONFIG_(BOOTDELAY|DISABLE_CONSOLE|SYS_CONSOLE_INFO_QUIET)=' \
  e27cb147b -- configs
```

Run the equivalent commands at upstream `v2026.01`. The captured totals are:

| Tree | Defconfigs | Delay `0` | Console disabled | Console-device summary quiet |
| --- | ---: | ---: | ---: | ---: |
| Radxa 2024.10 | 1,317 | 101 | 1 | 251 |
| Radxa 2026.01 | 1,326 | 110 | 1 | 260 |
| upstream 2026.01 | 1,481 | 37 | 1 | 156 |

For both Radxa pins, this command returns exactly one path:

```bash
git grep -n '^CONFIG_DISABLE_CONSOLE=y' <pin> -- configs
```

**Pass/fail signal:** the one path is
`configs/rock-5b-rk3588_defconfig`. Upstream's one path is instead
`configs/anbernic-rgxx3-rk3566_defconfig`; its ROCK 5B defconfig contains none
of the three assignments.

## Patch checks

```bash
git -C <armbian-build> apply --check \
  /path/to/0001-rock-5b-enable-armbian-u-boot-console.patch

awk '/^\+diff --git a\/configs\/rock-5b-rk3588_defconfig/{emit=1}
     emit { if ($0=="-- ") exit; sub(/^\+/,""); print }' \
  /path/to/0001-rock-5b-enable-armbian-u-boot-console.patch |
  git -C <radxa-u-boot> apply --check -
```

Both checks exited zero. `git rev-parse
next-dev-v2024.10:configs/rock-5b-rk3588_defconfig` returned
`6832279aad63e59924b8f6d7946d6ea163fc157e`, matching the embedded patch's
preimage.

Before the delay change was shelved, the official resolver established the
unpatched baseline for `BOARD=rock-5b BRANCH=current`:

```bash
./compile.sh config-dump-json \
  BOARD=rock-5b BRANCH=current RELEASE=resolute
```

**Pass/fail signal:** it returned `BOOTDELAY=0`,
`BOOTSOURCE=https://github.com/radxa/u-boot.git`, and
`BOOTBRANCH=branch:next-dev-v2024.10`. The final candidate changes no Armbian
configuration variable or `CONFIG_BOOTDELAY` source line.

Not built and not boot-tested.
