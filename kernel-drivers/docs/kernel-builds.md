# Kernel builds — the unified map

Every ysp kernel build starts from **one entry point**:

```bash
bash kernel-drivers/scripts/build-kernel.sh <flavor>
```

This page is the map: what each flavor builds, from which source tree, with
which config, and where its install/validation runbook lives. The deep
material stays in the linked pages; this page only routes.

```mermaid
flowchart LR
    BK[build-kernel.sh &lt;flavor&gt;] --> LOCAL[local flavors\nArmbian engine]
    BK --> PPA[ppa-* flavors\nbuild-source-packages.sh]
    BK --> MAX[maxline-* flavors\nkernel-maxline/build-kernel.sh]
    LOCAL --> DEBS[installable .debs\narmbian-build/output/debs]
    PPA --> SRC[unsigned source packages\npackaging/ppa/out/artifacts]
    MAX --> MDEB[pinned 7.2-rc3 packages\npackaging/ppa/out/maxline]
```

## Package slots

Each local flavor installs into its **own** slot, so all four kernels can be
installed side by side and installing one never disturbs another. The slot name
is the Armbian `BRANCH`, which is the whole mechanism: Armbian derives both the
package name (`linux-image-${BRANCH}-${LINUXFAMILY}`) *and* the kernel release
string (`LOCALVERSION=-${BRANCH}-${LINUXFAMILY}`, hence `/boot/vmlinuz-*`,
`/lib/modules/*`, the headers dir) from it.

| Flavor | Slot / package suffix | Release string |
|--------|----------------------|----------------|
| `forward-port` | `video-port-rockchip64` | `6.18.y-video-port-rockchip64` |
| `forward-port-debug` | `video-port-kasan-rockchip64` | `6.18.y-video-port-kasan-rockchip64` |
| `rewrite` | `video-rewrite-rockchip64` | `6.18.y-video-rewrite-rockchip64` |
| `rewrite-debug` | `video-rewrite-kasan-rockchip64` | `6.18.y-video-rewrite-kasan-rockchip64` |

Installing does not require naming a slot: `install-kernel.sh` takes the
`PHASH` that identifies one build and infers the slot from the deb filename,
so the slot and the build cannot disagree. `SLOT=` exists only to
disambiguate, and the installer refuses the two slots below outright.

Two slots are **not** ours and must never be written by these scripts:
`current-rockchip64` belongs to Armbian's own stock kernel, and
`ysp-rockchip64` is the PPA lineage
([`kernel-forward-port/`](../../packaging/ppa/kernel-forward-port/README.md)).

Making a custom `BRANCH` work needs three `declare -g` lines in each flavor's
`config-rock5b-*.conf.sh` — `KERNEL_MAJOR_MINOR`, `LINUXFAMILY`, `LINUXCONFIG`.
Armbian's `rockchip64_common.inc` sets those from a `case $BRANCH in
current|edge|bleedingedge`, and a branch it does not know falls straight through,
after which the build aborts with *"BAD config, missing KERNEL_MAJOR_MINOR"*.

`LINUXCONFIG` deliberately does **not** follow the slot for production flavors:
it names the config *file* Armbian reads, and production builds keep using
Armbian's stock `linux-rockchip64-current.config` so the config hash stays
comparable across the re-slot. (Pointing it at a slot-named file seeded from
`/boot/config-$(uname -r)` silently moved `C####` `b831` → `435e`.) The debug
flavors do seed per-slot configs, deliberately, and each under its own slot name.

## Flavors

| Flavor | Builds | Source tree (branch) | Config | Output / install path |
|--------|--------|----------------------|--------|----------------------|
| `forward-port` | Production forward-port kernel (vendor MPP/RGA/AV1 port, self-contained DT) | `../kernel/linux-6.18-rkvenc-av1-fwport` (HEAD) | stock Armbian `rockchip64-current`; opt-in `IOMMU_DEBUG=yes` extension | `.debs`; install via [`install-combined-kernel.sh`](../scripts/README.md#the-scripts), validate via `validate-combined.sh` |
| `forward-port-debug` | KASAN/lockdep debug build of the forward-port kernel ("Kernel A") | same as `forward-port` | [`config-rock5b-debug-kernel.conf.sh`](../scripts/debug-kernel/config-rock5b-debug-kernel.conf.sh) + shared [instrumentation fragment](../scripts/debug-kernel/ysp-debug-instrumentation.conf.sh), seeded from `/boot/config-$(uname -r)` | `.debs`; install/hold/rollback via [`debug-kernel/`](../scripts/debug-kernel/README.md) |
| `rewrite` | Production clean-room rewrite kernel (rewrite drivers, vendor MPP/RGA off) | `../kernel/linux-6.18-rkvenc` (**must be on `rk3588-rewrite-6.18`, clean**) | stock Armbian `rockchip64-current` | `.debs`; install via `SLOT=video-rewrite install-combined-kernel.sh`. **New and not yet exercised** — added with the slot split so the rewrite has a production slot; no build of this flavor has been run. |
| `rewrite-debug` | KASAN/lockdep debug build of the clean-room rewrite kernel (rewrite drivers + 232 KUnit cases built in, vendor MPP/RGA off) | `../kernel/linux-6.18-rkvenc` (**must be on `rk3588-rewrite-6.18`, clean**) | [`config-rock5b-rewrite-debug-kernel.conf.sh`](../scripts/debug-kernel/config-rock5b-rewrite-debug-kernel.conf.sh) + the same shared fragment | `.debs`; same [`debug-kernel/`](../scripts/debug-kernel/README.md) install flow |
| `ppa-forward-port` | Unsigned source package `linux-rockchip64-ysp` for the normal PPA | patched Armbian worktree (see [`kernel-forward-port/`](../../packaging/ppa/kernel-forward-port/README.md)) | package `debian/config` | source artifacts under `packaging/ppa/out/artifacts` |
| `ppa-rewrite-6.18` | Unsigned source package `linux-rockchip64-ysp-alpha-6.18` (co-installable rewrite kernel) | pinned composite commit of `linux-6.18-rkvenc` (see [`kernel-rewrite-alpha-6.18/`](../../packaging/ppa/kernel-rewrite-alpha-6.18/README.md)) | package `debian/config` | source artifacts under `packaging/ppa/out/artifacts` |
| `ppa-rewrite-7.2-rc3` | Unsigned source package `linux-rockchip64-ysp-alpha-7.2-rc3` | pinned composite commit of `linux` (see [`kernel-rewrite-alpha-7.2-rc3/`](../../packaging/ppa/kernel-rewrite-alpha-7.2-rc3/README.md)) | package `debian/config` | source artifacts under `packaging/ppa/out/artifacts` |
| `maxline-public` / `maxline-wip` | Pinned upstream 7.2-rc3 maximum-mainline packages | `../kernel/linux` at pinned integration commits (see [`kernel-maxline/`](../../packaging/ppa/kernel-maxline/README.md)) | maxline `config/` | `packaging/ppa/out/maxline/package-<profile>` |

Not flavors of this entry point, but part of the same delivery picture:

- **DKMS channel** ([`packaging/dkms/`](../../packaging/dkms/README.md)) —
  out-of-tree modules for a stock kernel; **mutually exclusive** with the
  built-in local flavors on one installed kernel.
- **YSP Armbian builder VM** — exact-production image rebuilds
  ([builder finding](../../findings/2026-07-08-armbian-builder-setup.md), watchlist W14).

## Modes and knobs (local flavors)

```bash
build-kernel.sh <flavor> --stage-only    # regenerate + stage patches/config, no compile
build-kernel.sh --restore                # reset Armbian patch archive + userpatches
build-kernel.sh <flavor> --install-deps  # debug flavors: apt-install missing host deps
IOMMU_DEBUG=yes build-kernel.sh forward-port          # DMA/IOMMU observability extension
ARMBIAN_USE_CCACHE=no build-kernel.sh <flavor>        # clean retry
ARMBIAN_CLEAN_LEVEL=make-kernel build-kernel.sh <flavor>  # drop all Kbuild metadata
```

Mechanics preserved from the validated engine: rolling `linux-6.18.y` by
default with `ARMBIAN_KERNELBRANCH=commit:<sha>` for reproducible rebuilds,
core media patch exclusions for the self-contained DT, `USE_CCACHE` **as a
compile.sh argument** (the Docker relaunch drops env vars — [ccache
guide](./kernel-build-ccache.md)), stale debug-config sweep with
`CLEAN_LEVEL=make-kernel` escalation on config-class transitions, and the final
`P####-C####` hash print consumed by the installers.

## Debug-flavor specifics

Both `*-debug` flavors stage the ramoops DT patch and seed the base config
from the running kernel, then apply the shared instrumentation fragment
(KASAN inline, lockdep/PROVE_LOCKING, DMA-API debug, fault injection, pstore,
stall detectors — full rationale in [`debug-kernel.md`](./debug-kernel.md) §3).
The rewrite flavor additionally forces the rewrite/KUnit options on and the
vendor MPP/RGA drivers off, mirroring the validated
[rewrite package config](../../packaging/ppa/kernel-rewrite-alpha-6.18/README.md).
Because the two debug flavors share one instrumentation fragment, they share a
config class (`C####`); the patch hash (`P####`) is what distinguishes their
artifacts. Flavors no longer share package names — each has its own
[slot](#package-slots), so a debug install cannot clobber a production one — but
still pin installs by the printed `PHASH` (successive builds *within* a slot
share a name), prepare recovery first ([`install.md`](../../install.md) §3), and
never benchmark on a debug kernel ([`debug-kernel.md`](./debug-kernel.md) §8).

Since builds within a slot do share a package name, `uname -v` now carries the
**real wall-clock build time** to tell them apart: the `ysp-build-stamp`
extension overrides Armbian's reproducible-build stamp (which pins
`KBUILD_BUILD_TIMESTAMP` to the kernel git revision date, making every rebuild
look identical). The trade-off is deliberate — `SOURCE_DATE_EPOCH` stays pinned,
but two builds of identical source no longer produce a byte-identical vmlinux.

## Validation pointers

- Local production kernel: [`kernel-validation-runbook.md`](./kernel-validation-runbook.md).
- Debug kernels: [`debug-kernel.md`](./debug-kernel.md) §4–§7 (crash capture, install, rollback).
- Rewrite kernels: [`rewrite-conformance.md`](../tests/rewrite-conformance.md) and the
  [conformance-gap audit](./rewrite-conformance-gap-audit.md) hardware gates
  (236-case AV1-branch booted KUnit report, paired suites).
- PPA packages: per-package READMEs above; publication state in
  [`packaging/ppa/`](../../packaging/ppa/README.md) and watchlist W05.
- Maxline: [recovery-first install order](../../packaging/ppa/kernel-maxline/README.md#install-and-test-order).
