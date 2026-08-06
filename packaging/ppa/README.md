# ppa/ - Launchpad source packages

This directory owns reproducible Debian source packaging, archive topology,
build-dependency order, signing/upload/recovery procedure, and package-specific
mechanical notes for the ROCK 5B stack.

It does not own live publication: Launchpad is authoritative and
[W05](../../status.md#watch-w05) is the dated cache. Intended source inputs are
the defaults in [`build-source-packages.sh`](build-source-packages.sh); actual
artifacts are identified by signed Debian/Launchpad metadata; installed and
runtime results belong to status and project evidence owners.

Give [the PPA support guide](../../docs/ppa-support.md) to users installing the
stack. This page is for package maintainers.

## PPA Layout

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
host. Use [`clean-install-system-stack.sh`](clean-install-system-stack.sh) for
an explicitly reviewed migration from incompatible test archives; it verifies
availability before removing conflicts, simulates APT, constrains removals, and
retains the distro kernel for recovery.

## Current State

This heading is a compatibility route, not a live package matrix.

- Launchpad is authoritative for accepted source, build, binary, and index
  records.
- [W05](../../status.md#watch-w05) owns the dated archive observation and
  freshness rules.
- [Status track 9](../../status.md) owns the compact user-visible stack verdict
  and next proof.
- Package/project READMEs own durable mechanics and validation boundaries.
- The [incident record](history/2026-07-06-ubuntu-rock-5b-upload-log.md) keeps
  only otherwise-unavailable orig-rejection and archive-recreation facts.

A version string, successful local build, accepted source, successful Launchpad
build, published binary, installed package, and runtime-qualified artifact are
different identities.

## Directory Contents

| Path | Durable responsibility |
|------|------------------------|
| [`build-source-packages.sh`](build-source-packages.sh) | Select intended inputs, export source trees, overlay Debian packaging, and create unsigned source packages. |
| [`install-system-stack.sh`](install-system-stack.sh) | Install the compatible normal stack while retaining the distro kernel for recovery. |
| [`clean-install-system-stack.sh`](clean-install-system-stack.sh) | Perform a reviewed migration away from incompatible test archives with availability, simulation, and removal guards. |
| [`plymouth/`](plymouth/README.md) | Verify the exact distro source and apply the incomplete-CSI boot-hang backport. |
| [`codec-udev/`](codec-udev/README.md) | Package the canonical unprivileged codec-device access rule. |
| [`ffmpeg-baseline/`](ffmpeg-baseline/README.md) | Preserve the upstream FFmpeg comparison-package recipe. |
| [`ffmpeg-rockchip/`](ffmpeg-rockchip/README.md) | Package the co-installable FFmpeg 6.1 Rockchip command-line tools. |
| [`gdm-hwenc/`](gdm-hwenc/README.md) | Package the optional GDM hardware-encode ACL rule. |
| [`kernel-forward-port/`](kernel-forward-port/README.md) | Package the forward-port kernel line. |
| [`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md), [`kernel-rewrite-alpha-7.2-rc3/`](kernel-rewrite-alpha-7.2-rc3/README.md), and [`kernel-rewrite-alpha-7.2-rc5/`](kernel-rewrite-alpha-7.2-rc5/README.md) | Package co-installable rewrite experiments without redefining their technical validation. |
| [`kernel-maxline/`](kernel-maxline/README.md) | Package the maximum-mainline profiles owned by [`kernel-versions/maxline/`](../../kernel-versions/maxline/README.md). |
| [`kernel-sgguard/`](kernel-sgguard/README.md) | Preserve the focused sg-guard diagnostic package definition. |
| [`history/`](history/README.md) | Retain exceptional archive incidents whose facts are unavailable elsewhere. |

The `debian/` directories under `mpp`, `librga`, `ffmpeg`,
`ffmpeg-rockchip`, and `gnome-remote-desktop` are the actual Debian packaging
overlays. GRD's [`source-deltas/`](gnome-remote-desktop/source-deltas/README.md)
contains historical reconstruction inputs, not the maintained release input.

Generated `.dsc`, `.changes`, `.buildinfo`, orig tarballs, binary packages, and
build trees are ignored under `packaging/ppa/out/` by default. Set `OUT` to a
task-specific directory under `../rock-5b/build/` when the output should live
outside the checkout.

## Source Inputs

[`build-source-packages.sh`](build-source-packages.sh) is the sole owner of
the maintained input defaults. Read the executable assignments there instead
of copying pins or source versions into prose.

| Input family | Variables or fixed inputs |
|--------------|---------------------------|
| Workspace layout | `ROCK5B_WORKSPACE`, `WORKSPACE_ROOT`, `OUT` |
| MPP | `MPP_REPO`, `MPP_COMMIT`, `MPP_UPSTREAM_VERSION` |
| librga | `LIBRGA_REPO`, `LIBRGA_COMMIT`, `LIBRGA_UPSTREAM_VERSION` |
| System FFmpeg | `FFMPEG_REPO`, `FFMPEG_COMMIT`, `FFMPEG_UPSTREAM_VERSION` |
| Co-installable FFmpeg tool | `FFMPEG_ROCKCHIP_REPO`, `FFMPEG_ROCKCHIP_COMMIT`, `FFMPEG_ROCKCHIP_UPSTREAM_VERSION` |
| GNOME Remote Desktop | `GRD_REPO`, `GRD_COMMIT`, `GRD_UPSTREAM_VERSION`; `GRD_DELTA` is historical reconstruction only |
| Forward-port and sg-guard kernels | `KERNEL_PPA_*`, `KERNEL_SGGUARD_*`, and their checked-in configs |
| Rewrite kernels | matching `KERNEL_ALPHA_*` source, repository, commit, version, and checked-in config inputs |
| Native rule packages | `CODEC_UDEV_*`, `GDM_HWENC_*`, and their canonical checked-in rule files |

Override a repository, commit, and upstream version as one provenance tuple.
Do not advance librga independently of the kernel stride convention it targets,
and do not change a kernel source name or version without reviewing
co-installability and upgrade behavior. A source-build retry for the same
upstream version must reuse the accepted orig tarball byte-for-byte.

## Build Source Packages

Build the default userspace dependency chain:

```bash
bash packaging/ppa/build-source-packages.sh
```

Build selected targets by passing their names, for example:

```bash
bash packaging/ppa/build-source-packages.sh mpp librga ffmpeg
bash packaging/ppa/build-source-packages.sh ffmpeg-rockchip gnome-remote-desktop
bash packaging/ppa/build-source-packages.sh plymouth gdm-hwenc
bash packaging/ppa/build-source-packages.sh kernel
bash packaging/ppa/build-source-packages.sh kernel-alpha-6.18 kernel-alpha-7.2-rc3
```

For native Debian builds, keep the system toolchain first so Meson sees Ubuntu
multiarch metadata:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  OUT=../rock-5b/build/ppa-source \
  bash packaging/ppa/build-source-packages.sh mpp
```

The helper exports clean pinned commits for normal userspace sources, overlays
the checked-in packaging, and writes artifacts beneath `OUT/artifacts/`. It
reuses an existing orig tarball unless `FORCE_ORIG=1`; before reuse it extracts
the tarball and rejects a content mismatch. GRD's maintained path exports a
clean commit without `GRD_DELTA`. The native rule packages have no orig
tarball.

The forward-port kernel target is intentionally outside the default set. It
exports the patched Armbian worktree, including its deliberate tracked delta,
and applies provenance guards because `git archive` cannot represent that
source state. Each rewrite target instead archives its explicit commit and
checked-in package config. Their project READMEs own qualification results.

### Reproducing the FFmpeg 8.1 packages

The maintained `ffmpeg` target builds the normal system ABI. The upstream 8.1
comparison recipe remains in [`ffmpeg-baseline/`](ffmpeg-baseline/README.md).
The exact helper and Debian packaging for the historical Rockchip 8.1 source
are frozen at repository commit `8522426`.

Use a detached worktree so reconstruction does not replace current packaging:

```bash
git worktree add --detach ../rock-5b/build/ffmpeg81-packaging 8522426
FFMPEG_REPO=/path/to/ffmpeg-rockchip-81 \
OUT=../rock-5b/build/ffmpeg81-source \
  bash ../rock-5b/build/ffmpeg81-packaging/packaging/ppa/build-source-packages.sh ffmpeg
git worktree remove ../rock-5b/build/ffmpeg81-packaging
```

The snapshot itself owns its source commit, version, and ABI package names.
For a Debian-revision retry, obtain and reuse the accepted orig tarball; that
older helper predates the current automatic source-tree comparison.

<a id="ffmpeg81-package-lessons"></a>
#### Frozen FFmpeg 8.1 package lessons

The historical forward-port package needed three mechanical corrections before
its full local arch+indep build, FATE run, and Launchpad arm64 build passed:

- drop the RKMPP decoder's static `pix_fmts` metadata because
  `libavcodec-avcodec` rejects it for a hardware decoder; the separate
  DRM PRIME `AVCodecHWConfig` used by Kodi remains intact;
- stop installing the absent upstream `RELEASE_NOTES` file; and
- publish the generated Doxygen `ffmpeg-doc` payload as `Architecture: all`,
  because it is built in the architecture-independent pass.

These are reconstruction rules for that frozen FFmpeg 8.1 package, not current
branch or archive state. The [FFmpeg validation scorecard](../../video-libraries/ffmpeg/docs/validation.md)
owns the evidence classification, and the [Kodi decoder analysis](../../apps/kodi/docs/decoder-selection.md)
owns why the metadata change does not alter decoder selection.

## Upload Order

Respect build dependencies, and wait for each wave's development packages to
enter the target archive index before starting its consumers:

```text
Wave A   Plymouth, codec udev, MPP, librga
Wave B   system FFmpeg
Wave B'  optional co-installable FFmpeg Rockchip tool package
Wave C   GNOME Remote Desktop
Wave D   optional GDM hardware-encode ACL
Wave K   kernel packages, independently of the userspace dependency chain
```

ABI-changing FFmpeg comparisons belong in their dedicated archives. The
normal system PPA may be configured as their build dependency for MPP/RGA
headers, but comparison packages must not silently replace its system ABI.
Launchpad does not automatically retry a build that began before its
dependencies were available.

### Sign, upload, and recover

Signing and upload remain explicit operator actions:

```bash
debsign -k <fingerprint> packaging/ppa/out/artifacts/*_source.changes
dput ppa:yi-ding/ubuntu-rock-5b packaging/ppa/out/artifacts/<package>_source.changes
```

Select the dedicated archive named in [PPA Layout](#ppa-layout) when the source
is an ABI comparison or experimental kernel. Before upload, verify signatures
on the source `.changes` and `.dsc`, extract the `.dsc` once with
`dpkg-source -x`, and match each payload to `Checksums-Sha256`. A successful
`dput` proves client-side transfer only; [W05](../../status.md#watch-w05) owns
the API and package-index checks required before claiming publication.

Recovery rules established by the initial archive incident:

1. For a Debian-only revision, reuse the byte-identical accepted orig tarball.
   If local reconstruction differs, retrieve the accepted payload through the
   Launchpad source record and verify it against the signed `.dsc`.
2. A rejected transfer can leave a local `.ppa.upload` marker. Use
   `dput --force` only after the source index proves that version was not
   accepted and all source checksums have been reverified.
3. Wait for build dependencies to publish before uploading the next wave.
4. Capture failed build records and hosted logs before superseding them.
5. Never delete and recreate an archive as a routine upgrade mechanism. For a
   necessary ABI split, first preserve recoverable sources and binaries in a
   holding archive, save identities and hashes, audit reverse dependencies and
   archive dependencies, and account for the name-reuse delay.

The [dated incident record](history/2026-07-06-ubuntu-rock-5b-upload-log.md)
retains the exceptional orig-rejection and archive-recreation evidence. It is
not a routine upload diary.

## Package Notes

### Plymouth

[`plymouth/build-source-package.sh`](plymouth/build-source-package.sh) pins and
verifies the distro source files, overlays exactly one DEP-3 quilt backport for
the incomplete-CSI boot hang, and adds the package changelog entry. Its README
owns the source-integrity and patch mechanics; W05 owns publication.

### Codec device access

`rk3588-codec-udev` installs the canonical rule for `/dev/mpp_service`,
`/dev/rga`, and `/dev/dma_heap/*`, grants the `video` group and active local
seat access, and reloads/retriggers udev. DMA-heap permission is required in
addition to codec-node permission for unprivileged RKMPP allocation.

### MPP

The helper repacks the selected MPP source as `+ds`, excluding unused upstream
Windows binaries. It produces runtime libraries, compatibility packaging,
demos, and development headers. The technical source delta is a reviewable
fork branch, not a packaging-local quilt series; unversioned linker symlinks
remain in the development package and the unused static archive remains
unshipped. [`vendor-libraries/mpp/`](../../vendor-libraries/mpp/README.md) owns
behavior, public patch provenance, and validation.

<a id="mpp-source-artifact-reconstruction"></a>
#### MPP source-artifact reconstruction

Use Launchpad's source publication to download the signed `.dsc` and every
payload it authenticates. Verify `Checksums-Sha256`, run `dpkg-source -x` on
the `.dsc`, and retain the source upload's `.changes` and `.buildinfo`. The
successful arm64 build record then identifies its dependency/toolchain set,
binary `.changes`, and output hashes. Compare those records with the intended
tuple in `build-source-packages.sh`; do not infer artifact identity from the
current default. W05 owns the dated publication observation.

### librga

The librga overlay produces the runtime library and development package while
retaining upstream's `librga.so.2` SONAME. Its source branch carries the
P010/P210 request work and 10-bit byte-stride conversion, which must remain
paired with the kernel convention. [`vendor-libraries/rga/`](../../vendor-libraries/rga/README.md)
owns that contract and its evidence; the build helper owns the selected tuple.

### FFmpeg

The system FFmpeg target uses the full Ubuntu/Debian package surface and keeps
the distro ABI family while enabling RKMPP, RKRGA, libdrm, and GPLv3-required
features. It is distinct from the private `/opt` tool package. The source
branch owns codec fixes, [`video-libraries/ffmpeg/`](../../video-libraries/ffmpeg/README.md)
owns their rationale and validation, and the build helper owns the selected
source tuple.

<a id="ffmpeg-source-artifact-reconstruction"></a>
#### FFmpeg source-artifact reconstruction

Resolve the actual source through Launchpad's source publication, verify the
signed `.dsc` and its payload hashes, extract it with `dpkg-source -x`, and
retain both source and binary `.changes`/`.buildinfo` records. The successful
arm64 build record supplies toolchain, dependency, and binary hashes. Compare
those immutable artifacts with the build helper's intended tuple and W05's
dated publication cache; none substitutes for the others.

### FFmpeg Rockchip 6.1 Tool Package

This older lineage is co-installable because it packages only private tools
under `/opt/ffmpeg-rockchip` plus explicitly named wrappers. It does not
provide the system `ffmpeg` command or any distro `libav*` binary/development
package. [`ffmpeg-rockchip/`](ffmpeg-rockchip/README.md) owns the configure and
packaging details.

### GNOME Remote Desktop

The maintained GRD target archives the clean selected commit, removes generated
shader outputs, overlays `gnome-remote-desktop/debian/`, enables FFmpeg, and
builds the arm64 package. `GRD_DELTA` is reserved for reconstructing an older
dirty source snapshot; [`source-deltas/`](gnome-remote-desktop/source-deltas/README.md)
is a frozen historical input. The application
[`README`](../../apps/gnome-remote-desktop/README.md),
[`design`](../../apps/gnome-remote-desktop/docs/design.md), and
[`validation`](../../apps/gnome-remote-desktop/docs/validation.md) own behavior,
architecture, and accumulated proof.

<a id="grd-source-artifact-reconstruction"></a>
#### GRD source-artifact reconstruction

Download the signed `.dsc` and authenticated payloads from the relevant
Launchpad source publication, verify `Checksums-Sha256`, and extract once with
`dpkg-source -x`. Retain the source and arm64 build `.changes`/`.buildinfo`
records and their output hashes. Use those records for actual artifact identity,
the helper defaults for intended input, W10 for the moving branch head, and W05
for dated external publication.

### GDM Greeter Hardware Encode ACL

The `gdm-hwenc` target creates a small native package from the canonical rule
under [`../gdm-hwenc/`](../gdm-hwenc/README.md). It grants the `gdm` group
access to codec devices and is deliberately opt-in because that widens the
pre-login greeter's hardware access. Enable it only after the main GRD package
path is otherwise qualified.

## What Is Still Not In This Repo

- External upstream and fork source checkouts selected by the helper.
- Generated source/binary packages, build directories, and hosted archive
  payloads; reconstruct them from signed metadata or a task build directory.
- Launchpad credentials, private signing keys, and operator authentication.
- Private security material or upstream-submission plans.
- Live archive, installed-host, or runtime state; those belong to Launchpad,
  status, and project evidence owners respectively.

## See Also

- [`../../docs/ppa-support.md`](../../docs/ppa-support.md) - end-user archive
  installation and troubleshooting.
- [`../README.md`](../README.md) - deployment and package-policy hub.
- [`../userspace-patches.md`](../userspace-patches.md) - fork-versus-quilt
  maintenance policy.
- [`../../docs/source-trees.md`](../../docs/source-trees.md) - external
  checkout map.
- [`../../status.md`](../../status.md) - live project status and watches.
- [`history/`](history/README.md) - exceptional incident evidence.
- [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) - evidence lifecycle and
  handoff gate.
