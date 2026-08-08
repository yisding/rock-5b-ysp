# Userspace patch map

This document owns the repository-wide policy for carrying userspace deltas:
which components use a public fork branch, which use Debian quilt, and which
maintenance traps apply. It does not own source pins, package versions,
publication state, validation results, or private upstream-submission plans.

[`ppa/build-source-packages.sh`](ppa/build-source-packages.sh) is authoritative
for intended package inputs. Signed Debian/Launchpad metadata identifies actual
artifacts, [W05](../status.md#watch-w05) caches publication state, and each
project catalog below owns public patch behavior and evidence.

## At a glance

| Component | Intended-input owner | Delta form | Public technical owner |
|-----------|----------------------|------------|------------------------|
| MPP | `MPP_*` defaults in the build helper | Public fork branch; orig is repacked | [`vendor-libraries/mpp/`](../vendor-libraries/mpp/README.md) |
| librga | `LIBRGA_*` defaults in the build helper | Public fork branch | [`vendor-libraries/rga/`](../vendor-libraries/rga/README.md) |
| System FFmpeg | `FFMPEG_*` defaults in the build helper | Public fork branch | [`video-libraries/ffmpeg/`](../video-libraries/ffmpeg/README.md) |
| Co-installable FFmpeg tools | `FFMPEG_ROCKCHIP_*` defaults in the build helper | Upstream snapshot; no local delta | [`ppa/ffmpeg-rockchip/`](ppa/ffmpeg-rockchip/README.md) |
| FFmpeg comparison baseline | Frozen package recipe | Pristine upstream plus recovered Debian packaging | [`ppa/ffmpeg-baseline/`](ppa/ffmpeg-baseline/README.md) |
| GNOME Remote Desktop | `GRD_*` defaults in the build helper | Public fork branch; clean export | [`apps/gnome-remote-desktop/`](../apps/gnome-remote-desktop/README.md) |
| Plymouth | [`ppa/plymouth/build-source-package.sh`](ppa/plymouth/build-source-package.sh) | Debian quilt | [`ppa/plymouth/`](ppa/plymouth/README.md) |
| rockchip-vaapi | Its package source/build owner | Public fork branch | [`video-libraries/vaapi/`](../video-libraries/vaapi/README.md) |
| Codec/GDM access rules | Checked-in native package inputs | Native in-repository files | [`codec-udev/`](codec-udev/README.md) and [`gdm-hwenc/`](gdm-hwenc/README.md) |

The historical ABI-changing FFmpeg source package has no maintained packaging
directory. Reconstruct it from the frozen repository snapshot described by the
[frozen FFmpeg 8.1 recipe](ppa/docs/building.md#reproduce-the-frozen-ffmpeg-81-packages),
or recover the signed Debian source from Launchpad. Do not confuse that absence
with a moving package or publication assertion.

## Two ways patches are carried

**Fork branch** is the normal model. The source delta lives as reviewable
commits on a public fork, and packaging exports the selected commit into the
orig tarball. The Debian overlay does not repeat the source delta under
`debian/patches/`. This preserves commit history and makes rebasing possible,
but it also means the fork/project catalog—not this packaging checkout—is where
the patch content is reviewed.

**Quilt** is reserved for Plymouth's small distro-source backport. Pristine
Ubuntu source is combined with DEP-3 patches under
`ppa/plymouth/debian/patches/`, ordered by `series`. The packaging checkout is
therefore the patch-content owner for that component.

Do not mix both models for one component. MPP deliberately uses its fork
branch and must not regain a packaging-local quilt copy. Snapshot-only and
native rule packages are neither model: they carry no external source delta.

Public catalogs may record affected behavior, patch identity and provenance,
dependencies, and validation. Destinations, submission order, send/withhold
choices, embargo or disclosure coordination, and working memory-corruption
reproducers remain outside this public repository.

## Per component

<a id="mpp--fork-branch-11-commits"></a>
### MPP — fork branch

The package exports the branch selected by the helper, removes unused Windows
binaries during `+ds` repacking, and overlays only Debian packaging. The MPP
architecture and project front door own the public fix inventory, including
queue ownership, encoder poll/error handling, parser/HAL repairs, diagnostics,
and presentation-event lifetime behavior.

The usual working tree is a vendor-mirror checkout with a separate `yisding`
remote. Push maintained work only to the fork remote; the vendor mirror's
`origin` is a read-only reference for this workflow. A branch that tracks newer
vendor development is not automatically a packaging input.

Use the [MPP artifact reconstruction route](ppa/docs/publishing.md#mpp-source-artifact-reconstruction)
to identify a particular package. Do not infer that identity from the helper's
next intended input or from a matching version string.

### librga — fork branch

The packaging input is a public fork checkout. Its vendor-mirror remote and the
separate read-only upstream checkout are comparison sources, not destinations
for maintained work. There is no quilt series.

[`vendor-libraries/rga/`](../vendor-libraries/rga/README.md) owns the exported
patch series and the P010/P210 stride contract. The selected librga input must
move with the kernel layout convention; this cross-layer dependency is more
important than either branch name.

### FFmpeg — three separate lineages

The normal system lineage is a public fork branch selected by `FFMPEG_*`; its
project docs own the patch catalog, mechanism, rebase notes, and accumulated
validation. The older co-installable tool lineage is an upstream snapshot with
private package names and no local source delta. The comparison baseline is
pristine upstream with a recovered Debian tree.

The lineages use separate archive/package shapes because their ABI and purpose
differ. The [PPA topology](ppa/README.md#archive-topology) owns that separation, the
[FFmpeg reconstruction route](ppa/docs/publishing.md#ffmpeg-source-artifact-reconstruction)
identifies an actual system package, and W07 owns dated moving-branch heads.
Investigation checkouts named in [`external-workspaces.md`](external-workspaces.md)
are not packaging inputs unless the build helper explicitly selects them.

### GNOME Remote Desktop — fork branch

The package archives the clean commit selected by `GRD_*` and normally applies
no source delta. W10 owns the dated remote head. The application front door,
design, and validation docs own reconnect/handover, capture, encode recovery,
color signaling, and test conclusions.

The directory under
[`apps/gnome-remote-desktop/patches/`](../apps/gnome-remote-desktop/patches/README.md)
is a frozen older-base replay, not the maintained package input. Editing it
does not change what ships. `GRD_DELTA` is empty for the maintained path and is
reserved for historical source reconstruction. Use the
[GRD artifact reconstruction route](ppa/docs/publishing.md#grd-source-artifact-reconstruction)
for a particular package identity.

## Build procedure

Build one or more targets through the input owner:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
OUT=../rock-5b/build/ppa-source \
  bash packaging/ppa/build-source-packages.sh <target> [<target> ...]
```

The helper documents accepted target names and exports artifacts beneath
`OUT/artifacts/`. Override a component's repository, commit, and upstream
version together. Existing orig tarballs are reused by default because a
Debian-only revision must reference the accepted byte-identical orig. Set
`FORCE_ORIG=1` only when the upstream source version changes or while performing
an explicit clean reconstruction check.

### Adding a patch to a fork-branch component (everything except Plymouth)

1. Commit the change on the component's maintained fork branch. Never push it
   to a vendor mirror's `origin`.
2. Update the component's repository/commit/version tuple in
   `ppa/build-source-packages.sh`; add `+ds` only for an input whose exporter
   repacks the orig.
3. Add the Debian changelog entry. A changed upstream version starts a new
   Debian revision series.
4. Rebuild with a fresh orig and verify the archive contains the selected
   commit's change.
5. Update the project patch catalog with behavior, public provenance,
   dependencies, validation, and remaining evidence boundary. Keep private
   submission/disclosure planning out of the public catalog.

For a direct archive-content check:

```bash
tar -xzOf <package>.orig.tar.gz --wildcards '*/path/to/file.c' | rg <marker>
```

### Adding a patch to Plymouth (the only quilt component)

1. Make the change against the exact verified distro source.
2. Generate a patch with a complete DEP-3 header and place it under
   `ppa/plymouth/debian/patches/`.
3. Append the filename to `series` in application order.
4. Apply the full series sequentially to a clean source tree; a per-patch
   dry-run against pristine source gives false failures when patches depend on
   earlier entries.
5. Rebuild while reusing the existing orig tarball and bumping only the Debian
   revision when the upstream source version is unchanged.

Use a task directory under `../rock-5b/build/` for the clean apply test and
generated source package; do not use `/tmp` for board builds.

## Traps

- **librga and the kernel form one 10-bit layout contract.** A mismatch can
  produce silent chroma corruption rather than an error. Keep the warning near
  `LIBRGA_COMMIT` load-bearing and follow the RGA project's shipping boundary.
- **MPP has several legitimate bases.** The packaging fork, moving vendor
  development branch, and optional legacy-conformance source may implement the
  same logic in different functions. A change does not port mechanically
  between them; identify the selected base before editing or testing.
- **A vendor mirror's worktree is not durable patch storage.** Commit to the
  public fork or place a conformance-only bootstrap patch in its owned test
  catalog. Otherwise a checkout can erase the fix and make userspace falsely
  report a kernel regression.
- **Intended, published, installed, and runtime-qualified identities differ.**
  Use the build helper, signed artifact metadata, W05, and project/status
  evidence respectively.
- **Build output belongs outside the checkout.** Use a separate directory
  under `../rock-5b/build/` and the central ccache store when supported.
