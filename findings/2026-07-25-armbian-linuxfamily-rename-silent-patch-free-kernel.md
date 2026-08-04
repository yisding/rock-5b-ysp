# One Armbian variable, `LINUXFAMILY`, silently built a patch-free kernel and threw away the whole kernel ccache

> Scope: `kernel-drivers/scripts/build-kernel.sh` local flavors (forward-port,
> forward-port-debug, rewrite, rewrite-debug) against the external Armbian build
> tree at `~/Code/rock-5b/build/kernel/rock5b-kernel-build/armbian-build`
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

> **Corrected 2026-07-25, same day.** This section first claimed the fix was to
> pin `LINUXFAMILY=rockchip64` as a `compile.sh` argument. **That does not work
> and has been removed.** `config-prepare.sh:141` performs an unconditional
> `LINUXFAMILY="${BOARDFAMILY}"` *after* the config is sourced, clobbering any
> config value and any command-line value — Armbian's own comment on that line
> concedes it ("this... shouldn't happen, extensions might change it too"). The
> measurement: a build run with the argument applied logged
> `Applying cmdline param [ 'LINUXFAMILY': … --> 'rockchip64' early ]`, then
> `Skip … already set … after config`, and still produced the artifact
> `kernel-rockchip-rk3588-video-port-kasan` from
> `artifact_name="kernel-${LINUXFAMILY}-${BRANCH}"`. `LINUXSOURCEDIR` at `:284`
> is likewise an unconditional `declare -g`, so the worktree path cannot be
> pinned either.

Each of the three consequences needs its own answer, because the common cause is
not reachable:

| Consequence | Fix |
|---|---|
| Patch dir | **`KERNELPATCHDIR` passed explicitly** as a `compile.sh` argument. Armbian only defaults it when unset, so an explicit value wins. This is the one that actually mattered — it is what stopped the silent patch-free kernel. |
| Worktree path / ccache | **`CCACHE_NOHASHDIR=1`**, set from the `ysp-build-stamp` extension's `kernel_make_config` hook. Not preventable upstream; only survivable. |
| Package / slot name | **Not fixed — it follows Armbian.** The slot is `…-rockchip-rk3588`. `build-kernel.sh` now *discovers* `BOARDFAMILY` from `config/boards/rock-5b.conf` rather than assuming, so its result glob matches what is actually built. |

`CCACHE_NOHASHDIR` was measured in isolation rather than assumed — same source,
two directories, `-g -gdwarf-5`, `CCACHE_BASEDIR` set in both, which is exactly
how Armbian invokes the kernel make:

```text
default              hits=0 misses=2    b/t.o DW_AT_comp_dir = .../b  (correct)
CCACHE_NOHASHDIR=1   hits=1 misses=1    b/t.o DW_AT_comp_dir = .../a  (stale)
```

So `CCACHE_BASEDIR` genuinely does **not** cover the working directory under
`-g`, and the cost of the mitigation is a reused object carrying the comp_dir of
whichever build first cached it.

Note `archive/rockchip64-6.18` (177 core patches) remains the right patch set
regardless: `rockchip-rk3588.conf` sources `rockchip64_common.inc` and defines
only `legacy` (5.10) and `vendor` (6.1) branches, both setting
`LINUXFAMILY=rk35xx` on the `rk35xx-*` dirs. **No mainline `rockchip-rk3588`
patch set exists.**

Two guards were added because this class of failure is silent:

- **Pre-flight** — refuse to build when the staged userpatch directory is
  missing or empty; `die` when `KERNELPATCHDIR` disagrees with it.
- **Post-flight** — extract the packaged kernel config from the produced deb and
  require `CONFIG_ROCKCHIP_MPP_RKVDEC2`, a symbol both the forward-port and
  rewrite series add and neither mainline nor Armbian's core patches provide.
  An earlier version of this guard tested the deb's `P####` hash for `0000` and
  was **useless**: Armbian hashes the union of the core and userpatch dirs and
  returns zeros only when the combined list is empty (`hash-files.sh:66-69`), so
  with 356 core patches present it could never fire.

Two guards were added because this class of failure is silent:

- **Pre-flight** — refuse to build when the staged userpatch directory is
  missing or empty, and print the family and patch dir in use.
- **Post-flight** — `die` when the produced deb carries `-P0000-`, Armbian's
  hash of an empty patch set. Verified to fire on the bad artifact and stay
  silent on a correctly patched one.

## Boundary

- `KERNELPATCHDIR` is **confirmed working end to end**: a full build produced
  `P47b9` (vs `P0000`) and a packaged config carrying `ROCKCHIP_MPP_SERVICE`,
  `RKVENC2`, `RKVDEC2`, `AV1DEC` and `RGA_ASYNC`, alongside `KASAN`/`LOCKDEP`.
  Runtime 138:04.
- `CCACHE_NOHASHDIR` is measured **in isolation** (the table above) but has not
  yet run inside a real kernel build. Its practical benefit is prospective: it
  makes the cache survive a future worktree-path change, and cannot be observed
  until one happens.
- **The cross-worktree cache-reuse experiment was not run and cannot be, as
  designed.** It depended on moving the build to the `rockchip64` worktree via
  the family pin; since the pin does not work, the worktree cannot be relocated
  deliberately. The `~11.5k` objects cached under `6.18__rockchip-rk3588__arm64`
  therefore remain the live cache, and the `1.16%` hit rate of that run is still
  unexplained beyond "the config genuinely changed when the patches started
  applying".
- Whether `hash_dir` is the *dominant* cause of a cold rebuild in this workload
  remains **INFERRED**. The isolated test proves the mechanism exists; it does
  not establish its share of the observed misses.
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
