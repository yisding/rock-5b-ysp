# PPA package mechanics

This catalog records stable, cross-package distinctions in the userspace and
native-rule overlays. It does not track published versions or runtime verdicts.
Kernel packages have sufficiently different build and qualification contracts
that their own READMEs remain canonical.

## Package map

| Package family | Stable role | Detailed owner |
|----------------|-------------|----------------|
| Plymouth | Apply one verified distro-source boot-hang backport | [`plymouth/`](../plymouth/README.md) |
| Codec access | Grant unprivileged MPP, RGA, and DMA-heap access | [`codec-udev/`](../codec-udev/README.md) |
| MPP | Package the codec runtime, compatibility library, demos, and headers | [MPP project](../../../vendor-libraries/mpp/README.md) |
| librga | Package the RGA runtime and development files while preserving the SONAME | [librga project](../../../vendor-libraries/rga/README.md) |
| System FFmpeg | Replace the distro FFmpeg family without changing its ABI line | [FFmpeg project](../../../video-libraries/ffmpeg/README.md) |
| FFmpeg Rockchip 6.1 tools | Install private, co-installable tools under `/opt` | [`ffmpeg-rockchip/`](../ffmpeg-rockchip/README.md) |
| GNOME Remote Desktop | Enable the maintained FFmpeg/RKMPP backend in the distro package | [GRD project](../../../apps/gnome-remote-desktop/README.md) |
| GDM hardware encode | Optionally widen codec-device access to the greeter | [`gdm-hwenc/`](../gdm-hwenc/README.md) |

Use the [build runbook](building.md) for intended input selection and the
[publication runbook](publishing.md#reconstruct-an-exact-published-artifact)
for exact artifact identity.

## Plymouth

[`plymouth/build-source-package.sh`](../plymouth/build-source-package.sh) pins
and verifies the distro source files, overlays exactly one DEP-3 quilt backport
for the incomplete-CSI boot hang, and adds the package changelog entry. Its
README owns source-integrity and patch mechanics; W05 owns publication.

## Codec device access

`rk3588-codec-udev` installs the canonical rule for `/dev/mpp_service`,
`/dev/rga`, and `/dev/dma_heap/*`, grants the `video` group and active local
seat access, and reloads/retriggers udev. DMA-heap permission is required in
addition to codec-node permission for unprivileged RKMPP allocation.

## MPP

The helper repacks the selected MPP source as `+ds`, excluding unused upstream
Windows binaries. It produces runtime libraries, compatibility packaging,
demos, and development headers. The technical source delta is a reviewable
fork branch, not a packaging-local quilt series; unversioned linker symlinks
remain in the development package and the unused static archive remains
unshipped. [`vendor-libraries/mpp/`](../../../vendor-libraries/mpp/README.md)
owns behavior, public patch provenance, and validation.

## librga

The librga overlay produces the runtime library and development package while
retaining upstream's `librga.so.2` SONAME. Its source branch carries the
P010/P210 request work and 10-bit byte-stride conversion, which must remain
paired with the kernel convention.
[`vendor-libraries/rga/`](../../../vendor-libraries/rga/README.md) owns that
contract and its evidence; the build helper owns the selected tuple.

## System FFmpeg

The system FFmpeg target uses the full Ubuntu/Debian package surface and keeps
the distro ABI family while enabling RKMPP, RKRGA, libdrm, and GPLv3-required
features. It is distinct from the private `/opt` tool package. The source
branch owns codec fixes,
[`video-libraries/ffmpeg/`](../../../video-libraries/ffmpeg/README.md) owns
their rationale and validation, and the build helper owns the selected source
tuple.

## FFmpeg Rockchip 6.1 tools

This older lineage is co-installable because it packages only private tools
under `/opt/ffmpeg-rockchip` plus explicitly named wrappers. It does not
provide the system `ffmpeg` command or any distro `libav*` binary/development
package. [`ffmpeg-rockchip/`](../ffmpeg-rockchip/README.md) owns the configure
and packaging details.

## GNOME Remote Desktop

The maintained GRD target archives the clean selected commit, removes generated
shader outputs, overlays `gnome-remote-desktop/debian/`, enables FFmpeg, and
builds the arm64 package. `GRD_DELTA` is reserved for reconstructing an older
dirty source snapshot;
[`source-deltas/`](../gnome-remote-desktop/source-deltas/README.md) is a frozen
historical input. The application
[`README`](../../../apps/gnome-remote-desktop/README.md),
[`design`](../../../apps/gnome-remote-desktop/docs/design.md), and
[`validation`](../../../apps/gnome-remote-desktop/docs/validation.md) own
behavior, architecture, and accumulated proof.

## GDM greeter hardware encode

The `gdm-hwenc` target creates a small native package from the canonical rule
under [`packaging/gdm-hwenc/`](../../gdm-hwenc/README.md). It grants the `gdm`
group access to codec devices and is deliberately opt-in because that widens
the pre-login greeter's hardware access. Enable it only after the main GRD
package path is otherwise qualified.
