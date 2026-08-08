# Publish and reconstruct PPA artifacts

This runbook owns cross-package dependency order, signing, upload, recovery,
and exact artifact reconstruction. Launchpad is authoritative for accepted
sources, builds, binaries, and archive indexes; [W05](../../../status.md#watch-w05)
is the repository's dated observation of that moving state.

Do not collapse these identities into one claim:

```text
version string
  -> successful local build
  -> accepted source
  -> successful Launchpad build
  -> published binary and indexed candidate
  -> installed package
  -> runtime-qualified artifact
```

## Upload order

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

ABI-changing FFmpeg comparisons belong in their dedicated archives. The normal
system PPA may be configured as their build dependency for MPP/RGA headers, but
comparison packages must not silently replace its system ABI. Launchpad does
not automatically retry a build that began before its dependencies were
available.

## Sign, upload, and verify

Signing and upload remain explicit operator actions:

```bash
debsign -k <fingerprint> packaging/ppa/out/artifacts/*_source.changes
dput ppa:yi-ding/ubuntu-rock-5b packaging/ppa/out/artifacts/<package>_source.changes
```

Select the dedicated archive named in the
[archive topology](../README.md#archive-topology) when the source is an ABI
comparison or experimental kernel. Before upload:

1. Verify signatures on the source `.changes` and `.dsc`.
2. Match every payload to `Checksums-Sha256`.
3. Extract the `.dsc` once with `dpkg-source -x`.
4. Confirm that the archive, source name, version, and architecture match the
   intended lane.

A successful `dput` proves client-side transfer only. Use Launchpad's source,
build, binary-publication, and archive-index records before claiming the next
identity in the ladder above. Update W05 when the repository needs a fresh
dated publication observation; runtime results belong to the owning project
evidence, not this runbook.

## Recover an upload

Rules established by the initial archive incident:

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

The [dated incident record](../history/2026-07-06-ubuntu-rock-5b-upload-log.md)
retains the exceptional orig-rejection and archive-recreation evidence. It is
not a routine upload diary.

## Reconstruct an exact published artifact

Use immutable Debian and Launchpad metadata rather than a package version or
the build helper's current default:

1. Resolve the source publication in the intended archive and pocket.
2. Download its signed `.dsc`, source `.changes`, and every payload named by
   the source record.
3. Verify the signatures and every `Checksums-Sha256` entry.
4. Extract the source once with `dpkg-source -x`.
5. Resolve the successful arm64 build record and retain its build log,
   `.buildinfo`, binary `.changes`, output list, and hashes.
6. Resolve the binary publication and archive-index candidate separately.
7. Compare the reconstructed source with the intended provenance tuple in
   [`build-source-packages.sh`](../build-source-packages.sh). Record any
   deliberate difference instead of assuming today's default produced the
   historical artifact.
8. Match installed files to that identity before attributing runtime evidence
   to it.

The package-specific notes below name only the extra identity boundary; the
procedure above remains canonical.

<a id="mpp-source-artifact-reconstruction"></a>
### MPP identity

Compare the reconstructed source with the helper's intended MPP tuple. The
[MPP project](../../../vendor-libraries/mpp/README.md) owns behavior, public
patch provenance, and runtime validation; neither its branch nor today's helper
default proves which artifact Launchpad built.

<a id="ffmpeg-source-artifact-reconstruction"></a>
### FFmpeg identity

The successful arm64 build record is the source of truth for the toolchain,
dependency set, binary `.changes`, and output hashes. The
[FFmpeg project](../../../video-libraries/ffmpeg/README.md) owns codec rationale
and validation, while the helper owns only the intended input tuple.

<a id="grd-source-artifact-reconstruction"></a>
### GNOME Remote Desktop identity

Use the build records for the actual package, the helper defaults for intended
input, W10 for the moving release/recovery branch heads, and W05 for dated
external publication. The [GRD project](../../../apps/gnome-remote-desktop/README.md)
owns application behavior and validation.
