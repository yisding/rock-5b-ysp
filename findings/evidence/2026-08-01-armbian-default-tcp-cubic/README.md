# Armbian default-TCP-congestion-control patch

Supports [Armbian's rockchip64 configs default TCP congestion control to
reno](../../2026-08-01-armbian-rockchip64-defaults-tcp-reno.md).

| File | What it is |
| --- | --- |
| `0001-fix-kernel-config-default-to-CUBIC-congestion-contro.patch` | `git format-patch` export of `fix/default-tcp-cubic@0fbef7eb2`, prepared against `armbian/build` `origin/main@535528112` |

## Scope

Nine distinct kernel configs carry `CONFIG_DEFAULT_RENO=y`; the patch replaces
it with `CONFIG_DEFAULT_CUBIC=y`, drops the two
`# CONFIG_DEFAULT_CUBIC is not set` lines that would otherwise keep reno as the
only selectable entry, and updates the two stale
`CONFIG_DEFAULT_TCP_CONG="reno"` strings. Net effect is +11/−13 across nine
files.

`linux-rockchip-rk3588-current.config` is a **symlink** to the `-edge` config
and is deliberately not edited — `sed -i` on it would replace the symlink with
a regular file. It inherits the fix through its target.

## Reconstructing it

The patch was produced mechanically:

```bash
cd <armbian/build checkout>
git switch -c fix/default-tcp-cubic origin/main
for f in $(grep -l "CONFIG_DEFAULT_RENO=y" config/kernel/*.config | sort); do
  [ -L "$f" ] && continue
  sed -i -e 's/^CONFIG_DEFAULT_RENO=y$/CONFIG_DEFAULT_CUBIC=y/' \
         -e '/^# CONFIG_DEFAULT_CUBIC is not set$/d' \
         -e 's/^CONFIG_DEFAULT_TCP_CONG="reno"$/CONFIG_DEFAULT_TCP_CONG="cubic"/' "$f"
done
```

## How it was verified

Each changed config was resolved with the kernel's own Kconfig parser, using
the `scripts/kconfig/conf` binary and Kconfig tree shipped in the
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

**Pass/fail signal:** all 9/9 resolve to `CONFIG_DEFAULT_CUBIC=y`,
`CONFIG_DEFAULT_TCP_CONG="cubic"`, and no `CONFIG_DEFAULT_RENO`. The
pre-patch configs reproduce `CONFIG_DEFAULT_RENO=y` through the same
procedure, which is what makes the post-patch result meaningful.

Not boot-tested, and no kernel was built from these configs.
