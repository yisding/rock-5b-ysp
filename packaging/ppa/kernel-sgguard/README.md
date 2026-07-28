# kernel-sgguard/ — diagnostic forward-port kernel with the scatterlist guard

**Do not install this as a system kernel.** It is a temporary instrument for
attributing the GRD/RKMPP system-heap scatterlist corruption that oopses the
production kernel on the first RDP login of every boot (3/3). Delete the
package, this directory, and its PPA publication once the writer is identified.

| | |
|---|---|
| Source package | `linux-rockchip64-ysp-sgguard` |
| Binaries | `linux-image-ysp-sgguard-rockchip64`, `linux-dtb-…`, `linux-headers-…` |
| Version | `6.18.40+rk3588av1fwport20260725sgguard1-0ubuntu1~rk1` |
| Target archive | `ppa:yi-ding/ubuntu-rock-5b-experimental` — **never** the normal system PPA |
| `uname -r` | `6.18.40-ysp-sgguard-rockchip64` |

## What it is, exactly

The production forward-port source with **one** commit added: the temporary
`page_link` guard from
[`kernel-drivers/patches/system-heap-sg-guard/`](../../../kernel-drivers/patches/system-heap-sg-guard/README.md).
Same Armbian 6.18.40 worktree, same contiguous `0001`–`0075` vendor series, and
the *same tracked production config* — `KERNEL_SGGUARD_CONFIG` points at
`kernel-forward-port/debian/config/arm64-rockchip64.config` rather than carrying
a second copy, so the two kernels cannot drift apart in config.

## Why it goes through the PPA rather than being built locally

To remove the toolchain variable. Production is a Launchpad buildd binary
(**gcc 15.2.0 / binutils 2.46**); every local Armbian build uses the Docker
container's **gcc 13.3.0 / binutils 2.42**. That gap left the earlier KASAN
comparison unable to separate "KASAN masks the bug" from "the gcc-13 build does
not have it" — see
[`findings/2026-07-27-kasan-vs-production-build-provenance-confound.md`](../../../findings/2026-07-27-kasan-vs-production-build-provenance-confound.md).
Building this through Launchpad makes **the guard patch the only difference**
from the kernel that reproduces.

## Why it is co-installable

Separate source and binary package names mean installing it neither replaces nor
upgrades `linux-image-ysp-rockchip64`, and apt will never select it as an
upgrade candidate. The production kernel stays installed and bootable
throughout; select between them with
[`kernel-revert.sh`](../../../kernel-drivers/scripts/kernel-revert.sh), which is
the board's only kernel selection mechanism (U-Boot offers no menu).

This mirrors the co-installable pattern used by
[`kernel-rewrite-alpha-6.18/`](../kernel-rewrite-alpha-6.18/README.md); only
`debian/control` and `debian/rules` differ from `kernel-forward-port/`, and the
`debian/scripts/` helpers are byte-identical and enforced so by
`check-doc-consistency.py`.

## Build

```bash
bash packaging/ppa/build-source-packages.sh kernel-sgguard
```

The Armbian worktree named by `KERNEL_PPA_REPO` must already carry the 76-patch
series **and** the guard commit — that is the state a
`KERNEL_TREE=~/Code/tmp/fwport-sgguard bash kernel-drivers/scripts/build-kernel.sh forward-port`
run leaves behind. Verify before exporting:

```bash
grep -c SGGUARD "$KERNEL_PPA_REPO/drivers/dma-buf/heaps/system_heap.c"   # non-zero
```

Artifacts land in `packaging/ppa/out/artifacts/`. Sign and upload with
`debsign` + `dput ppa:yi-ding/ubuntu-rock-5b-experimental`.

## Reading the result

Boot it and take one RDP login at the reproduction geometry. The three data it
must yield are in the
[repro plan](../../../kernel-drivers/docs/grd-sg-corruption-repro-plan.md#2b-what-the-guard-must-capture-and-what-is-already-excluded):
the **prior** `page_link` value, the damaged table's **owning device** and
attachment count, and the first **checkpoint** that drifts. `sg_guard=0` on the
kernel command line makes the guard inert for a control run on the identical
binary.
