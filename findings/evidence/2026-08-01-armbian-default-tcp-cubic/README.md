# Armbian default-TCP-congestion-control patch

Supports [Armbian's rockchip64 configs default TCP congestion control to
reno](../../2026-08-01-armbian-rockchip64-defaults-tcp-reno.md).

| File | What it is |
| --- | --- |
| `0001-fix-rockchip-default-to-CUBIC-congestion-control-not.patch` | `git format-patch` export of `fix/rockchip-default-tcp-cubic@3edb6541f`, prepared against `armbian/build` `origin/main@587b6f2c0` |

Pushed to the fork at
`yisding/armbian-build` `fix/rockchip-default-tcp-cubic`. **No pull request has
been opened.**

## Scope

Four rockchip configs carry `CONFIG_DEFAULT_RENO=y`; the patch replaces it with
`CONFIG_DEFAULT_CUBIC=y`, drops the one
`# CONFIG_DEFAULT_CUBIC is not set` line that would otherwise keep reno as the
only selectable entry, and updates the one stale
`CONFIG_DEFAULT_TCP_CONG="reno"` string. Net effect is +5/−6 across four files.

`linux-rockchip-rk3588-current.config` is a **symlink** to the `-edge` config
and is deliberately not edited — `sed -i` on it would replace the symlink with
a regular file, turning a five-line diff into an eleven-thousand-line one. It
inherits the fix through its target.

Deliberately **not** covered, though they also resolve to reno:

| Configs | Why left alone |
| --- | --- |
| `linux-meson64-{current,edge,bleedingedge,oldlts}`, `linux-virtual-current` | Same `CONFIG_DEFAULT_RENO=y` line, but other maintainers' families |
| `linux-mvebu64-{current,edge,legacy}` | Reach reno by a *different* route — they set `CONFIG_TCP_CONG_CUBIC=m`, which makes `DEFAULT_CUBIC` unselectable. Fixing them means building cubic in, a larger behavioural change |

## Reconstructing it

```bash
cd <armbian/build checkout>
git switch -c fix/rockchip-default-tcp-cubic origin/main
for f in $(grep -l "CONFIG_DEFAULT_RENO=y" config/kernel/*rockchip*.config | sort); do
  [ -L "$f" ] && continue
  sed -i -e 's/^CONFIG_DEFAULT_RENO=y$/CONFIG_DEFAULT_CUBIC=y/' \
         -e '/^# CONFIG_DEFAULT_CUBIC is not set$/d' \
         -e 's/^CONFIG_DEFAULT_TCP_CONG="reno"$/CONFIG_DEFAULT_TCP_CONG="cubic"/' "$f"
done
```

## How it was verified

Each config was resolved with the kernel's own Kconfig parser, using the
`scripts/kconfig/conf` binary and Kconfig tree shipped in the
`linux-headers-6.18.41-ysp-rockchip64` package (a full kernel source tree is
not required):

```bash
H=/usr/src/linux-headers-6.18.41-ysp-rockchip64
( cd $H && ARCH=arm64 SRCARCH=arm64 srctree=. CC=gcc LD=ld HOSTCC=gcc \
    KCONFIG_CONFIG=/path/to/candidate.config \
    ./scripts/kconfig/conf --olddefconfig Kconfig )
```

`CC` must be set or the run aborts at `scripts/Kconfig.include:45`
("Sorry, this C compiler is not supported") and leaves a partial config that
looks like a result.

**Pass/fail signal:** all 4/4 resolve to `CONFIG_DEFAULT_CUBIC=y`,
`CONFIG_DEFAULT_TCP_CONG="cubic"`, and no `CONFIG_DEFAULT_RENO`. The unpatched
configs reproduce `CONFIG_DEFAULT_RENO=y` through the same procedure, which is
what makes the post-patch result meaningful.

The same procedure was run across all 112 upstream configs to establish the
fleet baseline recorded in the finding: 97 cubic, 12 reno, 2 bbr, 3 unresolved.
Of the unresolved three, `linux-rockchip-rk3588-current` is an artefact —
`git show` on a symlink yields the target's path rather than config content —
while `linux-ls1046a-ask-current` and `linux-nuvoton-ma35d1-vendor` genuinely
did not resolve against this Kconfig tree and are untested.

Not boot-tested, and no kernel was built from these configs.
