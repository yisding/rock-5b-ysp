# ppa/ — Launchpad packaging hub

This directory owns reproducible Debian source packaging, archive topology,
build-dependency order, signing/upload/recovery procedure, and package-specific
mechanics for the ROCK 5B stack. It is the maintainer entry point; users
installing the normal stack should follow the
[PPA support guide](../../docs/ppa-support.md).

Live publication is deliberately elsewhere: Launchpad is authoritative and
[W05](../../status.md#watch-w05) is the dated repository cache. The build helper
owns intended inputs, signed Debian/Launchpad metadata identifies actual
artifacts, and project evidence owners record installed/runtime results.

## Choose a task

| Need | Start here |
|------|------------|
| Build all or selected source packages | [Build runbook](docs/building.md) |
| Sign, upload, verify publication, or recover a rejected upload | [Publication runbook](docs/publishing.md) |
| Reconstruct the exact source and binaries Launchpad built | [Artifact reconstruction](docs/publishing.md#reconstruct-an-exact-published-artifact) |
| Understand a userspace or native package overlay | [Package mechanics](docs/package-notes.md) |
| Change or qualify a kernel package | Its package README in the [repository layout](#repository-layout) |
| Install or migrate a compatible host | [`install-system-stack.sh`](install-system-stack.sh) or [`clean-install-system-stack.sh`](clean-install-system-stack.sh) |
| Check public package state | [W05](../../status.md#watch-w05) and Launchpad |

The complete maintainer-doc index is under [`docs/`](docs/README.md).

## Archive topology

Incompatible ABI lines use different archives because Launchpad will not accept
an earlier source version into an archive that already accepted a later one,
even after deletion.

| PPA | Stable role |
|-----|-------------|
| `ppa:yi-ding/ubuntu-rock-5b` | Normal ABI-compatible Resolute/arm64 system stack and the sole ordinary install target |
| `ppa:yi-ding/rock5b-ffmpeg81-upstream` | Isolated upstream FFmpeg 8.1 comparison baseline |
| `ppa:yi-ding/rock5b-ffmpeg81-rockchip` | Isolated ABI-changing FFmpeg 8.1 Rockchip forward port; depends on the normal PPA for MPP/RGA |
| `ppa:yi-ding/rock5b-kernel618-rewrite` | Co-installable experimental Linux 6.18 rewrite package |
| `ppa:yi-ding/rock5b-kernel72rc2-rewrite` | Co-installable experimental 7.2-rc rewrite package; archive name is historical |
| `ppa:yi-ding/ubuntu-rock-5b-experimental` | Isolated diagnostic/recovery candidates and migration holding copies |

The normal PPA targets Ubuntu 26.04 Resolute on arm64. Architecture-independent
packages build on arm64 and publish as `Architecture: all`. Dedicated archives
must never silently replace the normal system ABI.

Use [`install-system-stack.sh`](install-system-stack.sh) for a clean compatible
host. Use [`clean-install-system-stack.sh`](clean-install-system-stack.sh) only
for an explicitly reviewed migration from incompatible test archives; it
verifies availability before removing conflicts, simulates APT, constrains
removals, and retains the distro kernel for recovery.

## State and evidence boundary

- Launchpad owns accepted source, build, binary, and index records.
- [W05](../../status.md#watch-w05) owns the dated archive observation and its
  freshness rules.
- [Status track 9](../../status.md) owns the compact user-visible stack verdict
  and next proof.
- The build helper owns intended source tuples; the
  [publication runbook](docs/publishing.md) explains how to identify actual
  artifacts.
- Package and project READMEs own durable mechanics and validation boundaries.
- The [incident record](history/2026-07-06-ubuntu-rock-5b-upload-log.md) retains
  only otherwise-unavailable orig-rejection and archive-recreation facts.

A version string, local build, accepted source, successful Launchpad build,
published binary, installed package, and runtime-qualified artifact are
different identities.

## Repository layout

### Shared operations and documentation

| Path | Durable responsibility |
|------|------------------------|
| [`build-source-packages.sh`](build-source-packages.sh) | Select intended inputs, export sources, overlay Debian packaging, and create unsigned source packages. |
| [`install-system-stack.sh`](install-system-stack.sh) | Install the compatible normal stack while retaining the distro kernel for recovery. |
| [`clean-install-system-stack.sh`](clean-install-system-stack.sh) | Perform a reviewed migration away from incompatible test archives with availability, simulation, and removal guards. |
| [`docs/`](docs/README.md) | Build, publication/reconstruction, and cross-package mechanics runbooks. |
| [`history/`](history/README.md) | Exceptional archive incidents whose facts are unavailable elsewhere. |

### Userspace and native source overlays

| Path | Durable responsibility |
|------|------------------------|
| [`plymouth/`](plymouth/README.md) | Verify the exact distro source and apply the incomplete-CSI boot-hang backport. |
| [`codec-udev/`](codec-udev/README.md) | Package the canonical unprivileged codec-device access rule. |
| `mpp/debian/` | Package the selected MPP runtime, compatibility library, demos, and headers. |
| `librga/debian/` | Package the selected librga runtime and development files. |
| `ffmpeg/debian/` | Package the system-ABI FFmpeg RKMPP/RKRGA integration. |
| [`ffmpeg-baseline/`](ffmpeg-baseline/README.md) | Preserve the upstream FFmpeg comparison-package recipe. |
| [`ffmpeg-rockchip/`](ffmpeg-rockchip/README.md) | Package the co-installable FFmpeg 6.1 Rockchip command-line tools. |
| `gnome-remote-desktop/debian/` | Package the selected clean GRD source with the FFmpeg backend enabled. |
| [`gnome-remote-desktop/source-deltas/`](gnome-remote-desktop/source-deltas/README.md) | Retain frozen historical reconstruction inputs, not maintained release input. |
| [`gdm-hwenc/`](gdm-hwenc/README.md) | Package the optional GDM hardware-encode ACL rule. |

The [package-mechanics catalog](docs/package-notes.md) explains the stable
distinctions without duplicating source pins, publication state, or runtime
verdicts.

### Kernel source packages

| Path | Durable responsibility |
|------|------------------------|
| [`kernel-forward-port/`](kernel-forward-port/README.md) | Package the production forward-port kernel line. |
| [`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) | Package the co-installable 6.18 rewrite experiment. |
| [`kernel-rewrite-alpha-7.2-rc3/`](kernel-rewrite-alpha-7.2-rc3/README.md) | Package the co-installable 7.2-rc3 rewrite experiment. |
| [`kernel-rewrite-alpha-7.2-rc5/`](kernel-rewrite-alpha-7.2-rc5/README.md) | Preserve the deferred 7.2-rc5 rewrite package definition. |
| [`kernel-maxline/`](kernel-maxline/README.md) | Package maximum-mainline profiles owned by [`kernel-versions/maxline/`](../../kernel-versions/maxline/README.md). |
| [`kernel-sgguard/`](kernel-sgguard/README.md) | Preserve the focused sg-guard diagnostic package definition. |

Generated `.dsc`, `.changes`, `.buildinfo`, orig tarballs, binary packages, and
build trees are ignored under `packaging/ppa/out/` by default. Put new build
state in a task-specific directory under `../rock-5b/build/`; do not commit it.

## Outside this directory

- External upstream and fork source checkouts selected by the helper.
- Generated packages, build directories, and hosted archive payloads.
- Launchpad credentials, private signing keys, and operator authentication.
- Private security material or upstream-submission plans.
- Live archive, installed-host, and runtime state.

## See also

- [`../../docs/ppa-support.md`](../../docs/ppa-support.md) — end-user archive
  installation and troubleshooting.
- [`../README.md`](../README.md) — deployment and package-policy hub.
- [`../userspace-patches.md`](../userspace-patches.md) — fork-versus-quilt
  maintenance policy.
- [`../external-workspaces.md`](../external-workspaces.md) — external checkout,
  build, and artifact ownership.
- [`../../docs/source-trees.md`](../../docs/source-trees.md) — pinned external
  sources used by documentation.
- [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) — evidence lifecycle and
  handoff gate.
