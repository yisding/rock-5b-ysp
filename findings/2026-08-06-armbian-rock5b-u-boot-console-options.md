# Armbian ROCK 5B vendor U-Boot disables its only interactive console

> Scope: Armbian U-Boot policy for ROCK 5B `current`, `vendor`, and `edge`,
> plus the repository-wide provenance and configuration survey for
> `BOOTDELAY`, `CONFIG_DISABLE_CONSOLE`, and
> `CONFIG_SYS_CONSOLE_INFO_QUIET`
> Source: `armbian/build` `origin/main@61ba9d2a0`; Radxa U-Boot
> `next-dev-v2024.10@39cd993e5` and `next-dev-v2026.01@e27cb147b`;
> upstream U-Boot `v2026.01@127a42c72`
> Date: 2026-08-06
> Trust: CONFIG-INSPECTED, SOURCE-INSPECTED, ROOT-CAUSED, DESIGN

## Result

Armbian's ROCK 5B `current` and `vendor` targets take all three settings from
two different layers:

| Option | What it controls | Radxa ROCK 5B defconfig | Armbian policy before the candidate patch | Upstream ROCK 5B `v2026.01` |
| --- | --- | --- | --- | --- |
| `CONFIG_BOOTDELAY` | Seconds before autoboot; `0` still checks for input but provides no countdown delay | `0` | shared `rockchip64_common.inc` also injects `0` after `make defconfig` | omitted, so U-Boot's Kconfig default is `2`; Armbian `edge` overrides it to `1` |
| `CONFIG_DISABLE_CONSOLE` | Disables console input and output completely | `y` | not overridden | omitted (`n`) |
| `CONFIG_SYS_CONSOLE_INFO_QUIET` | Suppresses only the post-relocation stdin/stdout/stderr device summary | `y` | not overridden | omitted (`n`) |

`CONFIG_DISABLE_CONSOLE=y` is the setting that makes the serial U-Boot banner,
prompt, and input disappear. `CONFIG_SYS_CONSOLE_INFO_QUIET=y` is narrower and
does not disable an otherwise working console. `CONFIG_BOOTDELAY=0` is
independent of both: it removes the intentional wait but does not itself mute
UART.

The Radxa implementation makes the first distinction concrete.
`arch/arm/mach-rockchip/spl.c` and `board.c` both convert
`CONFIG_DISABLE_CONSOLE` into `GD_FLG_DISABLE_CONSOLE`; `common/console.c` then
returns without accepting input or emitting output, and the NS16550 driver has
the same guard. The board code also removes `earlycon=` from Linux boot
arguments when the flag is set. Thus neither `BOOTDELAY=1` nor any other delay
can create an interactive prompt until the disabled-console option is removed.

The shelved Armbian candidate therefore removes only the two
console-suppression symbols in a board-scoped Radxa U-Boot patch. It leaves
Armbian's delay policy unchanged:

| Target | U-Boot source | Before | After candidate |
| --- | --- | --- | --- |
| `current`, `vendor` | Radxa `next-dev-v2024.10` | delay `0`, console disabled, console-device summary quiet | delay `0`, console enabled, console-device summary shown |
| `edge` | upstream `v2026.01` | delay `1`, console enabled, console-device summary shown | unchanged |

The shelved candidate artifact is
[`boot-firmware/patches/0001-rock-5b-enable-armbian-u-boot-console.patch`](../boot-firmware/patches/0001-rock-5b-enable-armbian-u-boot-console.patch).

## Armbian policy survey

At `armbian/build@61ba9d2a0`, the build configuration contains 60 textual
`BOOTDELAY` assignments:

| Assigned value | Assignments | Where |
| --- | ---: | --- |
| `0` | 1 | `config/sources/families/include/rockchip64_common.inc` |
| `1` | 57 | 47 board assignments, eight family assignments, and two vendor-hook assignments |
| `2` | 2 | NanoPi R5C and R5S board overrides |

No file under `config/boards/` assigns zero. The lone Armbian-policy zero is
inherited by five family configurations and 163 board descriptors:

| Family | Board descriptors |
| --- | ---: |
| `rockchip64` | 65 |
| `rk35xx` | 43 |
| `rockchip-rk3588` | 53 |
| `seeed-rk3576` | 1 |
| `seeed-rk3588` | 1 |

Of those 163 descriptors, 120 contain no board-level `BOOTDELAY` assignment at
all. The remaining 43 contain at least one assignment, sometimes only inside a
branch hook; 41 files assign `1` and two assign `2`. Consequently, changing the
common value would alter the effective timing for a large cross-generation set
of RK3308, RK3328, RK3399, RK356x, RK3576, and RK3588 targets. It would not be a
ROCK 5B console fix.

The common zero is historical rather than RK3588-specific. `git blame` traces
it to `43b3beed8b` (2017-08-16, "[WIP] Initial Rock64 support"), where it was
introduced for the original RK3328 Rock64 family. Commit `150ac0c2a`
(2019-11-19, "Remove K<4, change branches, new features (#1586)") moved it into
the new `rockchip64_common.inc`. Neither commit records an autoboot rationale,
and both predate ROCK 5B support.

Armbian treats `BOOTDELAY` as distribution policy, not merely a defconfig
property. `lib/functions/compilation/uboot.sh` runs after `make defconfig` and
rewrites `CONFIG_BOOTDELAY` from the resolved Armbian variable: with `sed` for
older U-Boot trees and with `scripts/config --set-val` for newer ones. Changing
only Radxa's `CONFIG_BOOTDELAY=0` line would therefore be overwritten back to
the inherited Armbian value.

The other two symbols are different. Armbian has no generic build variable or
post-defconfig rewrite for either. They come from the selected U-Boot source
and Armbian's source patch queue. Within Armbian's active patch material:

- `CONFIG_DISABLE_CONSOLE=y` appears in one stored defconfig
  (`armsom-w3-rk3588_defconfig`); board patches remove it for Firefly ITX-3588J
  and Hinlink H88K, and the EasePi R2 defconfig records that it was removed when
  copied from ROCK 5B.
- `CONFIG_SYS_CONSOLE_INFO_QUIET=y` has 34 direct stored-defconfig occurrences,
  one added-patch occurrence, and one retained patch-context occurrence. One
  Hinlink H88K patch removes it. These are source-patch occurrences, not unique
  built targets: versioned patch directories and copied defconfigs can
  duplicate a board.
- Positive or retained `CONFIG_BOOTDELAY` source-patch occurrences span every
  normal policy seen here: 36 at `0`, 19 at `1`, six at `2`, seven at `3`, and
  two at `5`. These source values are subordinate to a resolved Armbian
  `BOOTDELAY` assignment.

This distinction is why the console fix can remain a board-scoped U-Boot source
patch while the delay question is shelved separately.

## Radxa and upstream defconfig survey

The full defconfig surveys show that the three options are not one common
"quiet mode":

| Tree | Defconfigs | Explicit delay `0` | `DISABLE_CONSOLE=y` | `SYS_CONSOLE_INFO_QUIET=y` |
| --- | ---: | ---: | ---: | ---: |
| Radxa `next-dev-v2024.10@39cd993e5` | 1,317 | 101 | 1 | 251 |
| Radxa `next-dev-v2026.01@e27cb147b` | 1,326 | 110 | 1 | 260 |
| upstream `v2026.01@127a42c72` | 1,481 | 37 | 1 | 156 |

In both Radxa branches, ROCK 5B is the **only** defconfig that sets
`CONFIG_DISABLE_CONSOLE=y`, and it sets all three options. The upstream tree's
single disabled-console defconfig is `anbernic-rgxx3-rk3566_defconfig`; upstream
`rock5b-rk3588_defconfig` sets none of the three.

Radxa commit `0d3169e641d` added `CONFIG_DISABLE_CONSOLE=y` on 2022-09-13 with
the subject "rock-5b-rk3588_defconfig: disable console" and no further
rationale. The zero delay and quiet console-device summary were already in the
defconfig ancestry. Both Radxa options remain present in
`next-dev-v2026.01@e27cb147b`.

Armbian already has direct precedent for reversing this vendor choice. Commit
`9ff15f7896` (2025-05-07, "hinlink-h88k: enable uboot serial log") removes both
symbols with the same two-line defconfig change proposed for ROCK 5B. The
Firefly ITX-3588J board patch separately removes `CONFIG_DISABLE_CONSOLE=y`.

## Why the delay change was shelved

The survey rules out folding a delay change into this console patch:

1. Changing `rockchip64_common.inc` from `0` to `1` would touch up to 163 board
   descriptors across six SoC generations, including 120 with no local delay
   assignment. That scope needs its own fleet-wide decision and boot testing.
2. Changing only `CONFIG_BOOTDELAY` in Radxa's defconfig would not survive
   Armbian's post-defconfig rewrite.

The shelved candidate therefore contains only the vendor-source delta in
Armbian's existing board-scoped `u-boot-radxa-rk35xx/board_rock-5b` patch
directory. It changes no other board, does not modify `BOOTDELAY`, and leaves
ROCK 5B `edge` unchanged.

## Evidence and reproduction

The survey used `git grep`, `git blame`, and `git log -S` at the pins in the
header. Counts and reconstruction commands are recorded in
[`findings/evidence/2026-08-06-armbian-rock5b-u-boot-console/`](evidence/2026-08-06-armbian-rock5b-u-boot-console/README.md).

The unpatched Armbian resolver reproduced `BOOTDELAY=0`, Radxa U-Boot, and
`next-dev-v2024.10` for `BOARD=rock-5b BRANCH=current`. The final shelved
candidate does not touch `config/boards/rock-5b.conf` or any `BOOTDELAY` line.

Both layers of the candidate patch pass `git apply --check`: the outer patch
against `armbian/build@61ba9d2a0`, and the embedded defconfig patch against
Radxa's exact `next-dev-v2024.10` source blob (`6832279aad6`).

## Boundary

This is source- and configuration-inspected evidence. The candidate has not
yet been built into a U-Boot artifact or boot-tested on ROCK 5B. Enabling the
console establishes that U-Boot can use its configured UART; it does not prove
that earlier proprietary DDR initialization or BL31 output follows the same
verbosity policy. Changing the shared Rockchip delay remains a separate,
deliberately untested proposal.
