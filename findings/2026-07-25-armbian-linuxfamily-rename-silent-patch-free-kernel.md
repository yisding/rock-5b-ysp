# One Armbian variable, `LINUXFAMILY`, silently built a patch-free kernel and threw away the whole kernel ccache

> Scope: `kernel-drivers/scripts/build-kernel.sh` local flavors (forward-port,
> forward-port-debug, rewrite, rewrite-debug) against the external Armbian build
> tree at `~/Code/kernel/rock5b-kernel-build/armbian-build`
> Source: armbian/build @ `82b64307-dirty`; `lib/functions/main/config-prepare.sh:141,284`,
> `config/sources/common.conf:115-128`, `config/sources/families/rockchip-rk3588.conf`,
> `config/sources/families/include/rockchip64_common.inc:28-42`, `config/boards/rock-5b.conf`
> Date: 2026-07-25
> Trust: MEASURED (the failed build, both worktrees on disk, the shipped config) /
> SOURCE-CONFIRMED (every derivation above read in the Armbian tree) /
> FIX-COMPILE-VERIFIED (patch dir and `P####` confirmed live; the family pin
> itself is staged but has not yet completed a build)

## Result

Armbian assigns `LINUXFAMILY="${BOARDFAMILY}"` at
`config-prepare.sh:141`, then derives **three** independent things from it:

| Derived | Where | Value before | Value after the rename |
|---|---|---|---|
| Kernel worktree path | `config-prepare.sh:284` — `linux-kernel-worktree/${KERNEL_MAJOR_MINOR}__${LINUXFAMILY}__${ARCH}` | `6.18__rockchip64__arm64` | `6.18__rockchip-rk3588__arm64` |
| Kernel patch dir | `common.conf` — `KERNELPATCHDIR="archive/${KERNEL_PATCH_ARCHIVE_BASE}-${KERNEL_MAJOR_MINOR}"`, base defaulting to `LINUXFAMILY` | `archive/rockchip64-6.18` | `archive/rockchip-rk3588-6.18` |
| Package / install slot | `linux-image-${BRANCH}-${LINUXFAMILY}` | `…-rockchip64` | `…-rockchip-rk3588` |

`rockchip64_common.inc:28-42` sets `LINUXFAMILY=rockchip64` **only** for the
branches it knows — `current`, `edge`, `bleedingedge`. These flavors use custom
BRANCH names (`video-port`, `video-port-kasan`, `video-rewrite`,
`video-rewrite-kasan`) as the slot mechanism, so they fall through that `case`
and `LINUXFAMILY` is left at whatever `BOARDFAMILY` says. When Armbian moved
`config/boards/rock-5b.conf` to `BOARDFAMILY="rockchip-rk3588"`, all three moved
at once.

**Consequence 1 — a patch-free kernel that still packages and installs.**
`archive/rockchip-rk3588-6.18` **does not exist** (verified: the only rk3588
patch dirs are `rk35xx-legacy` and `rk35xx-vendor-6.1`, both for the BSP
branches). Armbian therefore applied *zero* core patches and *zero* of the 75
generated userpatches, which the wrapper was still staging into
`archive/rockchip64-6.18`. There was **no error**. The build ran 2 h 10 m,
produced four installable debs named `linux-image-video-port-kasan-…`, and
shipped a stock 6.18.40 + KASAN with none of the vendor video port. The
packaged config had no `ROCKCHIP_MPP`, `RKVENC`, `RKVDEC2` or AV1 symbols at
all — only mainline `VIDEO_ROCKCHIP_RGA=m` and `VIDEO_ROCKCHIP_VDEC=m`.

**Consequence 2 — the entire kernel half of the shared ccache was discarded.**
The kernel compiles with `-g -gdwarf-5` and no `-fdebug-prefix-map`, and
ccache's `hash_dir` defaults to true, so the **working directory is part of every
object's cache key**. Moving the worktree renamed that directory, so every
pre-existing entry became unreachable. Both trees are on disk simultaneously:

```
cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64/
cache/sources/linux-kernel-worktree/6.18__rockchip-rk3588__arm64/
```

This is a far better explanation of the observed ~2-3 % hit rate than the
Kconfig delta that was assumed first — see Boundary.

**`declare -g LINUXFAMILY="rockchip64"` in the userpatches config does not
work**, and all four flavor configs contain that line believing it does.
`config-prepare.sh:141` runs *after* the userpatches config is sourced and
overwrites it. Only a `compile.sh` command-line argument wins — the same
mechanism, and the same reason, as the long-standing `USE_CCACHE` gotcha: the
log shows `Applying cmdline param … early` followed by `Skip cmdline param …
already set after config`.

## Root cause

A custom `BRANCH` (deliberate — it is what gives each flavor its own install
slot) falls through `rockchip64_common.inc`'s `case`, leaving `LINUXFAMILY`
bound to a board-family name that Armbian is free to rename. Three unrelated
subsystems then follow that one variable.

## Fix

`build-kernel.sh` now pins `LINUXFAMILY=rockchip64` as a `compile.sh` argument
at both call sites, with `KBRANCH` derived from it so the two cannot disagree,
plus `KERNELPATCHDIR=archive/$KBRANCH` as a redundant second line of defence.

This is **not** staying behind on a superseded family. `rockchip-rk3588.conf`
sources `rockchip64_common.inc` and defines only `legacy` (5.10) and `vendor`
(6.1) branches, both of which set `LINUXFAMILY=rk35xx` and use the `rk35xx-*`
patch dirs. **No mainline `rockchip-rk3588` patch set exists.** For a 6.18
mainline build the pin restores exactly the value Armbian itself would use, and
`archive/rockchip64-6.18` (177 core patches) is the intended set.

Two guards were added because this class of failure is silent:

- **Pre-flight** — refuse to build when the staged userpatch directory is
  missing or empty, and print the family and patch dir in use.
- **Post-flight** — `die` when the produced deb carries `-P0000-`, Armbian's
  hash of an empty patch set. Verified to fire on the bad artifact and stay
  silent on a correctly patched one.

## Boundary

- The family pin is staged and syntax/lint-clean but has **not yet completed a
  build**; the run in flight when this was written still uses
  `rockchip-rk3588`. Its `P47b9` hash and `Using kernel patch dir:
  archive/rockchip64-6.18` confirm the `KERNELPATCHDIR` half only.
- The `hash_dir` mechanism is **inferred, not measured**. That `hash_dir=true`
  and `-gdwarf-5`-without-prefix-map hold here is verified; that they are the
  dominant cause of the low hit rate is not. The clean test is a rebuild after
  the family pin, comparing the direct/preprocessed hit split against this
  run's `103/4381` with only 1 preprocessed hit.
- Restoring the `-rockchip64` package name makes the next build a **different
  package** from the `-rockchip-rk3588` debs now in `output/debs`. Interaction
  with an already-installed slot of either name is untested.
- No claim about whether Armbian intends mainline RK3588 to migrate to a new
  family later. If it gains a real mainline patch set, this pin should be
  revisited rather than left to rot.

## Why it matters

The dangerous property is not that the build broke — it is that it *succeeded*.
It produced correctly-named, installable, bootable kernel packages whose only
defect was the total absence of the drivers the whole tree exists to develop.
Nothing in the build output distinguished it from a good build; it was caught
by grepping the packaged config for `CONFIG_ROCKCHIP_MPP` on a hunch. The two
tells worth remembering are `-P0000-` in the deb version and an Armbian
`Using kernel patch dir:` line naming anything other than `archive/$KBRANCH`.
