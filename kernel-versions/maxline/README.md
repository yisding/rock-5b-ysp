# RK3588 maximum-mainline kernel builds

This project builds two reproducible, Armbian-compatible maximum-mainline
kernel package sets for the ROCK 5B. Both start at Torvalds
`master@075b74841bd0` rechecked on 2026-08-02. The integration deltas are checked in, so a rebuild does not
depend on whatever a mailing-list endpoint calls "latest" in the future.

For a reader-first comparison with Armbian 6.18, Ubuntu 26.04's 7.0 kernel,
and the pinned upstream snapshot, including the distinction between code that is
present and hardware the ROCK 5B device tree actually enables, see [what
maxline adds for the ROCK 5B](board-support.md).

## Project brief

| Field | Contents |
|-------|----------|
| User outcome | Compare the known-good 6.18 vendor-media path with a broad, auditable mainline RK3588 feature integration, without replacing the recovery kernel or confusing compilation with board support. |
| Developer focus | Reproduce the pinned proposal integration, review conflict resolutions and profile boundaries, build co-installable packages, and advance them through explicit boot and hardware gates. |
| Owns | The manifest, public/WIP ledgers, exported integration patches, pinned config, build helper, board comparison, historical design record, and measured verification record in this directory. The Debian packaging overlay remains under [`packaging/ppa/kernel-maxline/`](../../packaging/ppa/kernel-maxline/README.md). |
| Depends on | Torvalds Linux `7.2-rc6`, `master@075b74841bd0`, the pinned proposal sources, Armbian's boot/package contract, and tested serial or physical recovery access before installation. |
| Current state | The 2026-08-02 source refresh is pinned on both Torvalds master and `next-20260731`; compile validation is recorded in [`verification.md`](verification.md). The earlier 2026-07-17 profiles passed package, payload, and headers checks, but those old binaries do not represent this refresh. No maxline profile has been installed, booted, or hardware-tested. See [`status.md` track 13](../../status.md#dashboard). |

## Maintained records

| Path | Purpose |
|------|---------|
| [`board-support.md`](board-support.md) | Reader-first comparison of upstream, Armbian, and maxline code versus ROCK 5B device-tree enablement and untested hardware. |
| [`manifest.yaml`](manifest.yaml) | Exact Linus/linux-next bases, profile commits, patch/config hashes, intended releases and package versions, and verification boundary. |
| [`public-series.tsv`](public-series.tsv) | Every pinned public mailbox, patch count, mailbox hash, and integration disposition. |
| [`wip-donors.tsv`](wip-donors.tsv) | Every selected WIP donor commit, source, subject, and disposition. |
| [`integration-design-record.md`](integration-design-record.md) | Historical proposal analysis and conflict plan that produced the profiles; the manifest and ledgers supersede its revision labels as operational truth. |
| [`verification.md`](verification.md) | Native arm64 compile, package, payload, symbol, and external-module-headers evidence, plus the explicit unbooted boundary. |
| [`build-kernel.sh`](build-kernel.sh) | Reconstruct a pinned profile and build it with the separate Debian packaging overlay. |

## Profiles

- `public` is the recommended first-boot kernel. It contains the applicable
  current public queued, posted, RFC, and pending series from the supplied
  Collabora status document. Where a series is already in the Linus base, it is recorded
  but not duplicated. Where proposals overlap, the exported result contains
  one reconciled implementation.
- `wip` adds the selected non-debug Collabora HDMI 2.1 FRL controller stack.
  VDPU381 VP9 moved to `public` when a four-patch public v1 series appeared.
  This remains the maximum-feature build, not a stability claim.

The public integration is 299 commits above `075b74841bd0`. The WIP delta is 19
more commits. Exact input identities, hashes, exported patch hashes, branch
heads, config hash, and resulting kernel release names are in
[`manifest.yaml`](manifest.yaml), [`public-series.tsv`](public-series.tsv),
and [`wip-donors.tsv`](wip-donors.tsv).

The 2026-08-02 refresh replaces HDMI scrambling v8 with v10, DW-DP v3 with
v8, SCDC diagnostics v6 with v9, HDPTX fixes v4 with v5, HDMI-RX audio v2
with v4, and RK3588 CAN v4 with v6. It also adds public VDPU381 VP9 v1,
Samsung CSI DCPHY v2, and HDMI-QP audio N/CTS v3. The exact audit—including
which pieces entered subsystem `next` branches—is in the
[`refresh finding`](../../findings/2026-08-02-rk3588-maxline-proposal-refresh.md).

## Important integration decisions

The public patch is an exact tree delta rather than a command that downloads
and blindly applies every mailbox. That matters because the combined tree
needed real ports:

- RGA3's generic parallel-job work and the RKVDEC multicore series were
  reconciled into one scheduler model. RKVDEC retains per-core power,
  watchdog, metrics, and fdinfo handling.
- The VOP2 reset, forced-format, HDMI 2.0 scrambling, 10-bit YUV, SCDC,
  overscan, and HPD changes share code. Their final state retains each feature
  once, using the newest public DRM APIs.
- DW DisplayPort runtime PM/audio/OOB-HPD and Rockchip PCIe system PM were
  ported to the 7.2 layouts instead of dropping conflicted patches.
- The camera RFCs were combined into the RKCIF/RKISP2 shared media graph.
- RGA3 test-only DT/IOMMU changes and several complete series were already in
  the Linus base; their ledger disposition is `upstream` or `reconciled`.
- Overlapping V4L2 tracepoint and fdinfo patches both introduced the Hantro
  AV1 IRQ context; the integration keeps one declaration and both metrics.
- The Shared Media Graph RFC contained a `devv_dbg()` typo; its explicit
  integration fix uses the kernel's `dev_dbg()` helper.
- The RGA3 parallel-job setter is exported for modular consumers, and RKISP2
  selects the modular generic ISP helpers it calls.
- Public VDPU381 VP9 is ported to the multicore RKVDEC device model: register
  access and watchdogs follow the selected core, while persistent DMA tables
  use the main core's device. The linux-next replay additionally follows that
  base's ISP buffer-size helper rename.
- The linux-next replay keeps its newer DRM bridge `atomic_create_state` API
  while retaining the refreshed DW-DP bus-format negotiation hook. Accepted
  DRM and USB-C patches are omitted there rather than duplicated; the
  forced-color replay also drops a duplicate helper already in the next base.
- The Linus replay uses the connector `reset` callback for HDMI state creation;
  linux-next's newer `drm_connector_funcs.atomic_create_state` member is not
  available in Linus and is intentionally confined to the next validation tree.
  The OOB-HPD bridge walk likewise uses Linus's scoped iterator name.

The WIP patch deliberately excludes Collabora debug and hack commits. Its FRL
port keeps the public HDMI scrambling, YUV, overscan, and HPD behavior while
adding SCDC link training, FRL rate selection, Rockchip PHY mode switching,
VOP ACLK scaling, TxFFE control, and the ROCK 5B FRL-enable GPIOs. Its legacy
audio-table cleanup is superseded by the public N/CTS v3 implementation.

Features marked TODO in the source status document but lacking public code
cannot be manufactured by an integration build. This includes HDMI 8K/ARC/
HDCP, DMC frequency scaling, VICAP DVP/scaler, IEP2, and
unpublished encoder/decoder format work. FRL does not by itself make the
status document's separate HDMI 8K TODO complete.

## Build

The builder uses a local Torvalds Linux Git repository only to archive the
pinned base commit. It applies the checked-in deltas, copies the pinned
Armbian-derived config, and builds three unique binary packages: image, DTBs,
and headers.

```bash
kernel-versions/maxline/build-kernel.sh public
kernel-versions/maxline/build-kernel.sh wip
```

Defaults assume the upstream repository is at the sibling path
`~/Code/rock-5b/kernel/linux`, use all CPUs, and write ignored build/output trees to
`packaging/ppa/out/maxline/package-{public,wip}`. Overrides are explicit:

```bash
MAXLINE_KERNEL_GIT=/path/to/torvalds/linux \
MAXLINE_JOBS=8 \
MAXLINE_OUTPUT_DIR=/path/to/new-empty-output \
  kernel-versions/maxline/build-kernel.sh public
```

`MAXLINE_BUILD_DIR` may point at a completed out-of-tree checkpoint build of
the exact selected integration tree. Set `MAXLINE_SOURCE_DIR` to the matching
clean integration worktree at the pinned commit. Keeping both the source and
object paths stable lets the Debian build preserve and incrementally reuse
those objects (`dpkg-buildpackage -nc`) while still constructing packages
from the pinned archived source and checked-in config. This is useful after
the full-tree compile gate:

```bash
MAXLINE_BUILD_DIR=packaging/ppa/out/maxline/build-public-check \
MAXLINE_SOURCE_DIR=packaging/ppa/out/maxline/linux-public \
  kernel-versions/maxline/build-kernel.sh public
```

The builder rejects a mismatched commit, tracked source changes, or setting
only one checkpoint variable. The normal path, with both variables unset,
always builds in the freshly archived package source and remains the
standalone reproduction route.

The script refuses to overwrite an existing output directory. Each profile
has unique binary package names and a unique kernel release:

```text
linux-{image,dtb,headers}-ysp-maxline-public-rockchip64
7.2.0-rc6-ysp-maxline-public-rockchip64

linux-{image,dtb,headers}-ysp-maxline-wip-rockchip64
7.2.0-rc6-ysp-maxline-wip-rockchip64
```

The package layout follows this repository's existing Armbian-compatible
contract: `/boot/vmlinuz-$release`, `/lib/modules/$release`,
`/boot/dtb-$release`, `/usr/src/linux-headers-$release`, initramfs hooks, and
the `/boot/Image` and `/boot/dtb` last-installed symlinks.

The Debian rules delegate the package payload and lifecycle details to two
tracked helpers:

- [`debian/scripts/install-kernel-packages.sh`](../../packaging/ppa/kernel-maxline/debian/scripts/install-kernel-packages.sh)
  installs the built image, modules, DTBs, and external-module-capable headers
  into their three binary-package staging trees.
- [`debian/scripts/write-maintainer-scripts.sh`](../../packaging/ppa/kernel-maxline/debian/scripts/write-maintainer-scripts.sh)
  generates the image, DTB, and headers maintainer scripts that run kernel
  hooks, maintain Armbian's last-installed `/boot` targets, and prepare headers
  after installation.

`write-maintainer-scripts.sh` is byte-identical across all four kernel source
packages and `scripts/check-doc-consistency.py` enforces that.
`install-kernel-packages.sh` is **deliberately** not identical here: this
package builds out-of-tree from a separate kernel source, so `debian/rules.in`
passes it three extra arguments (localversion, build root, kernel source) and
the helper resolves `Image`/`System.map`/`.config`/generated headers from the
object tree rather than the source root. The other three packages build in-tree
and share one copy between them. Do not "resync" this file across all four
without also changing their `debian/rules`.

## Verified build

The Linus-based public profile passes a full native arm64
`Image modules dtbs` gate and a clean incremental recheck. Focused linux-next
objects for both next-only conflict fixes pass, and a broader linux-next/WIP
build reached the refreshed PHY, PCIe, DRM/VOP2, DW-DP, and HDMI paths without
error before being stopped at the user's request. It therefore has no full
build pass. Exact results and identities are in
[`verification.md`](verification.md).

Debian packages were not rebuilt for this refresh. The six packages, payload
inspection, and external-module headers smoke tests recorded on 2026-07-17
belong to the superseded `v7.2-rc3` source identities and remain historical
evidence in the verification record. Generated objects and packages stay under
ignored `packaging/ppa/out/maxline/`; they are not Git artifacts.

The complete [`verification record`](verification.md) preserves build-host
versions, exact tree and payload sizes, package metadata, symbol checks,
headers testing, and the remaining hardware boundary.

No package has been installed or booted on the ROCK 5B yet, so compile and
historical payload verification must not be read as hardware validation.

## Install and test order

Install `public` before `wip`. Installing either profile switches Armbian's
last-installed `/boot/Image` and `/boot/dtb` targets, so keep the known-good
6.18 package installed and have serial-console or physical recovery access.
Do not remove the working kernel.

After package installation, confirm that `/boot/armbianEnv.txt` still names
`rockchip/rk3588-rock-5b.dtb`, regenerate/check the initramfs and boot script,
and reboot into the explicit new release. Validate storage, both Ethernet
ports, USB, PCIe/NVMe, display, suspend/resume, and rollback before testing
accelerators.

Test the public-only areas next: HDMI 2.0/YUV/SCDC, DP AltMode and audio,
RKVDEC H.264/H.265/VP9 under concurrent RGA load, Rocket NPU, camera/DCPHY,
media graph, crypto, CAN-FD, and HDMI-RX audio. End-to-end RKISP2 also needs
the userspace libcamera pipeline/IPA and a supported sensor description.

The current installation blacklists `snd_soc_hdmi_codec` in its kernel
command line. Leave that in place for the first boot, then remove both
blacklist spellings only for the HDMI/DP audio phase. Test the WIP kernel last;
FRL and VP9 are experimental and a successful compile does not prove either
hardware path.
