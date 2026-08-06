# packaging/ — the deploy hub

This directory owns delivery shape and operator safety for the kernel/media
stack: combined kernels, DKMS, native access-rule packages, reproducible PPA
sources, migration/rollback, and the no-binaries-in-Git policy.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Choose one compatible install channel, preserve recovery, install required device access, and verify the selected stack. |
| Developer focus | Reproducible package inputs, ABI/co-installability, kernel-channel exclusion, source artifacts, upgrade/rollback behavior, and delivery evidence. |
| Owns | The channel chooser below, package subdirectories, PPA topology/mechanics, userspace delta policy, external-workspace inventory, and binary policy. |
| Depends on | Kernel-driver deliverables, userspace libraries, FFmpeg/GRD sources, Ubuntu packaging metadata, and recoverable board storage. |
| Evidence boundary | [`../status.md`](../status.md) owns public delivery verdicts and next proofs; [W05](../status.md#watch-w05) owns dated PPA observation; each package/runbook owns mechanics and scoped validation. |

## The four delivery channels

| # | Channel | Entry | Stable boundary |
|---|---------|-------|-----------------|
| 1 | Combined Armbian kernel | [`../kernel-drivers/scripts/`](../kernel-drivers/scripts/README.md) and [`../kernel-drivers/patches/`](../kernel-drivers/patches/README.md) | MPP/RGA built into the kernel; mutually exclusive with DKMS. Status track 1 owns the current board verdict. |
| 2 | DKMS on a stock kernel | [`dkms/`](dkms/README.md) | Out-of-tree modules plus DT overlay; never install on a combined kernel. Status track 3 owns qualification. |
| 3 | Local native packages | [`codec-udev/`](codec-udev/README.md) and [`gdm-hwenc/`](gdm-hwenc/README.md) | Device/greeter access policy only; installing a rule does not validate the media stack. |
| 4 | Launchpad PPA | [`ppa/`](ppa/README.md) | Reproducible source packages and co-installable kernels/comparisons; status track 9 and W05 own user/publication state. |

The combined and DKMS kernel channels are mutually exclusive because their
symbols collide. Every channel still needs the canonical access rule for
`/dev/mpp_service`, `/dev/rga`, and `/dev/dma_heap/*`; kernel delivery does not
grant userspace access by itself.

For an end-to-end install decision, begin at [`../install.md`](../install.md).
For the supported PPA path, use [`../docs/ppa-support.md`](../docs/ppa-support.md)
and the guarded installer under [`ppa/`](ppa/README.md).

## Directory index (hub contract)

| Path | One-liner |
|------|-----------|
| [`codec-udev/`](codec-udev/README.md) | Local native package for the canonical codec/RGA/dma-heap access rule. |
| [`dkms/`](dkms/README.md) | Stock-kernel-only out-of-tree MPP/RGA modules and DT overlay. |
| [`ffmpeg-rockchip81/`](ffmpeg-rockchip81/README.md) | Historical self-contained `/opt` package recipe for the FFmpeg 8.1 forward-port line. |
| [`gdm-hwenc/`](gdm-hwenc/README.md) | Opt-in native package granting GDM greeter codec access. |
| [`ppa/`](ppa/README.md) | Archive topology, reproducible source export, artifact reconstruction, signing/upload/recovery, and exceptional incident history. |
| [`docs/`](docs/armbian-packaging.md) | Armbian packaging and patch-precedence explanations. |
| [`external-workspaces.md`](external-workspaces.md) | Source/build/artifact ownership across sibling workspaces. |
| [`userspace-patches.md`](userspace-patches.md) | Fork-versus-quilt policy, patch-addition procedure, and maintenance traps. |

## Operations runbook — running the rkmpp FFmpeg stack

This heading is a compatibility route. The former ABI-specific local-deb
procedure described a superseded experiment and copied mutable package names
and versions. Use these maintained operations instead:

- [`../docs/ppa-support.md`](../docs/ppa-support.md) for user installation,
  first verification, troubleshooting, and recovery;
- [`ppa/install-system-stack.sh`](ppa/install-system-stack.sh) for a compatible
  clean host;
- [`ppa/clean-install-system-stack.sh`](ppa/clean-install-system-stack.sh) for
  an explicitly reviewed migration from incompatible test archives; and
- [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md) for deeper
  device and media validation.

### Pin, or Ubuntu will silently take it back

The old hard-coded `apt-mark hold` list is retired. ABI and package names differ
between the normal system stack and comparison archives, so a timeless hold
command can preserve the wrong line. Inspect the installed artifact, archive
origin, and current support route before pinning; use the guarded PPA installer
for the normal stack and record any deliberate local pin with the machine's
recovery plan.

### Exact rollback to stock Ubuntu FFmpeg (older libav*62 set)

The former literal downgrade transaction applied only to one historical local
ABI. Do not replay it against a later Ubuntu archive. The maintained migration
helper resolves available replacement versions, simulates APT, limits removals,
and retains the distro kernel; the PPA support guide owns the recovery decision.

### What installing removes (local-deb era only)

This heading preserves the historical boundary: an early partial local FFmpeg
drop could remove development packages while replacing runtime libraries. The
maintained PPA builds a complete system package family, and the clean-migration
helper must show and constrain the actual transaction before approval.

### Player caveat — rkmpp decoders are standalone AVCodecs *(canonical copy)*

RKMPP decoders in the Rockchip FFmpeg lineage are standalone codecs rather than
generic `AVHWAccel` implementations. Consumers must select a compatible decoder
path; a generic acceleration toggle may not do so. The canonical commands and
consumer boundary live in
[`video-libraries/ffmpeg/README.md`](../video-libraries/ffmpeg/README.md#verify-transcode)
and the [application map](../docs/app-enablement.md).

### Verify the stack end-to-end

Start with the version/origin, device-access, and FFmpeg registration exercises
in [`ppa-support.md`](../docs/ppa-support.md), then run the canonical kernel and
media tests selected by [`install.md`](../install.md). A registered codec is not
proof of hardware execution; retain the command, media, artifact identity, pass
signal, and kernel-log boundary.

## History — packaging roads not taken

Only four design lessons remain useful from the early package experiments:

- a hand-split prebuilt codec-library bundle was not reproducible and was
  replaced by ordinary MPP/librga source packages;
- GRD-private FFmpeg isolation reduced cross-application risk but duplicated
  maintenance and helped only GRD;
- a system-wide FFmpeg replacement benefits every consumer but requires ABI,
  upgrade, and rollback discipline; and
- comparison ABIs and rewrite kernels belong in dedicated co-installable
  archives, not in the normal system channel.

Git history preserves the obsolete package names, version-specific commands,
and work chronology. The PPA [`history/`](ppa/history/README.md) retains only
the material archive incident facts unavailable from ordinary metadata.

## Binary policy

Do not commit built `.deb`, `.ko`, `.dtbo`, `.so`, source-package, or build-tree
artifacts. Commit source, packaging metadata, scripts, manifests, and small
reconstruction evidence; build under `../rock-5b/build/` and use the central
`~/Code/.ccache` store where supported.

Public binary delivery belongs in Launchpad or a deliberate GitHub Release with
artifact identity and checksums, not in the repository tree. The canonical udev
rule remains [`../kernel-drivers/scripts/99-rockchip-codec.rules`](../kernel-drivers/scripts/99-rockchip-codec.rules);
package builders copy it rather than maintaining a second tracked body.

## Remaining PPA gates

This heading no longer maintains a second backlog. Use
[`../status.md`](../status.md) track 9 for the smallest public delivery proof,
[W05](../status.md#watch-w05) for publication freshness, and each package/project
owner for its full qualification ladder.

## See also

- [`../install.md`](../install.md) — delivery chooser, safety, and quick start.
- [`../docs/ppa-support.md`](../docs/ppa-support.md) — supported PPA operation.
- [`docs/armbian-packaging.md`](docs/armbian-packaging.md) — Armbian media-patch
  conflicts and DT packaging strategy.
- [`docs/armbian-patch-precedence.md`](docs/armbian-patch-precedence.md) — core
  versus userpatch ordering.
- [`../kernel-drivers/docs/resyncing.md`](../kernel-drivers/docs/resyncing.md) —
  kernel resync checklist shared by combined and DKMS consumers.
- [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — artifact/evidence lifecycle and
  handoff gate.
