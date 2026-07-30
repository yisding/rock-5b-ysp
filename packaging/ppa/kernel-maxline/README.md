# RK3588 maximum-mainline kernel builds

This project builds two reproducible, Armbian-compatible maximum-mainline
kernel package sets for the ROCK 5B. Both start at the exact upstream
`v7.2-rc3` commit. The integration deltas are checked in, so a rebuild does not
depend on whatever a mailing-list endpoint calls "latest" in the future.

For a reader-first comparison with Armbian 6.18, Ubuntu 26.04's 7.0 kernel,
and vanilla upstream 7.2-rc3, including the distinction between code that is
present and hardware the ROCK 5B device tree actually enables, see [what
maxline adds for the ROCK 5B](board-support.md).

## Project brief

| Field | Contents |
|-------|----------|
| User outcome | Compare the known-good 6.18 vendor-media path with a broad, auditable mainline RK3588 feature integration, without replacing the recovery kernel or confusing compilation with board support. |
| Developer focus | Reproduce the pinned proposal integration, review conflict resolutions and profile boundaries, build co-installable packages, and advance them through explicit boot and hardware gates. |
| Owns | The manifest, public/WIP ledgers, exported integration patches, pinned config, Debian packaging, build helper, board comparison, historical design record, and measured verification record in this directory. |
| Depends on | Upstream Linux `v7.2-rc3`, the pinned proposal sources, Armbian's boot/package contract, and tested serial or physical recovery access before installation. |
| Current state | Both profiles passed native arm64 compile, package, payload, and headers checks on 2026-07-17. Neither has been installed, booted, or hardware-tested. See [`status.md` track 13](../../../status.md#dashboard). |

## Maintained records

| Path | Purpose |
|------|---------|
| [`board-support.md`](board-support.md) | Reader-first comparison of upstream, Armbian, and maxline code versus ROCK 5B device-tree enablement and untested hardware. |
| [`manifest.yaml`](manifest.yaml) | Exact base/profile commits, patch and config hashes, releases, package versions, artifact sizes/hashes, and verification boundary. |
| [`public-series.tsv`](public-series.tsv) | Every pinned public mailbox, patch count, mailbox hash, and integration disposition. |
| [`wip-donors.tsv`](wip-donors.tsv) | Every selected WIP donor commit, source, subject, and disposition. |
| [`integration-design-record.md`](integration-design-record.md) | Historical proposal analysis and conflict plan that produced the profiles; the manifest and ledgers supersede its revision labels as operational truth. |
| [`verification.md`](verification.md) | Native arm64 compile, package, payload, symbol, and external-module-headers evidence, plus the explicit unbooted boundary. |

## Profiles

- `public` is the recommended first-boot kernel. It contains the applicable
  current public queued, posted, RFC, and pending series from the supplied
  Collabora status document. Where a series is already in 7.2, it is recorded
  but not duplicated. Where proposals overlap, the exported result contains
  one reconciled implementation.
- `wip` adds the selected non-debug Collabora HDMI 2.1 FRL controller stack
  and the public VDPU381 VP9 proof-of-concept. This is the literal
  maximum-feature build, not a stability claim.

The public integration is 241 commits above `v7.2-rc3`. The WIP delta is 21
more commits. Exact input identities, hashes, exported patch hashes, branch
heads, config hash, and resulting kernel release names are in
[`manifest.yaml`](manifest.yaml), [`public-series.tsv`](public-series.tsv),
and [`wip-donors.tsv`](wip-donors.tsv).

Several inputs had advanced beyond the revisions in the copied status
document by integration time. In particular, the build uses USBDP v13, PCI
port reset v8, V4L2 codec tracepoints v2, and V4L2 fdinfo v3. The ledgers pin
the actual mail imported, not the older prose labels.

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
  7.2; their ledger disposition is `upstream` or `reconciled`.
- Overlapping V4L2 tracepoint and fdinfo patches both introduced the Hantro
  AV1 IRQ context; the integration keeps one declaration and both metrics.
- The Shared Media Graph RFC contained a `devv_dbg()` typo; its explicit
  integration fix uses the kernel's `dev_dbg()` helper.
- The RGA3 parallel-job setter is exported for modular consumers, and RKISP2
  selects the modular generic ISP helpers it calls.

The WIP patch deliberately excludes Collabora debug and hack commits. Its FRL
port keeps the public HDMI scrambling, YUV, overscan, and HPD behavior while
adding SCDC link training, FRL rate selection, Rockchip PHY mode switching,
VOP ACLK scaling, TxFFE control, and the ROCK 5B FRL-enable GPIOs. The VP9
proof-of-concept was ported to the public branch's multicore RKVDEC device
model and restored the exact shared VP9 layout on which that commit depends.

Features marked TODO in the source status document but lacking public code
cannot be manufactured by an integration build. This includes HDMI 8K/ARC/
HDCP, DMC frequency scaling, Samsung CSI DCPHY, VICAP DVP/scaler, IEP2, and
unpublished encoder/decoder format work. FRL does not by itself make the
status document's separate HDMI 8K TODO complete.

## Build

The builder uses a local Torvalds Linux Git repository only to archive the
pinned base commit. It applies the checked-in deltas, copies the pinned
Armbian-derived config, and builds three unique binary packages: image, DTBs,
and headers.

```bash
packaging/ppa/kernel-maxline/build-kernel.sh public
packaging/ppa/kernel-maxline/build-kernel.sh wip
```

Defaults assume the upstream repository is at the sibling path
`~/Code/rock-5b/kernel/linux`, use all CPUs, and write ignored build/output trees to
`packaging/ppa/out/maxline/package-{public,wip}`. Overrides are explicit:

```bash
MAXLINE_KERNEL_GIT=/path/to/torvalds/linux \
MAXLINE_JOBS=8 \
MAXLINE_OUTPUT_DIR=/path/to/new-empty-output \
  packaging/ppa/kernel-maxline/build-kernel.sh public
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
  packaging/ppa/kernel-maxline/build-kernel.sh public
```

The builder rejects a mismatched commit, tracked source changes, or setting
only one checkpoint variable. The normal path, with both variables unset,
always builds in the freshly archived package source and remains the
standalone reproduction route.

The script refuses to overwrite an existing output directory. Each profile
has unique binary package names and a unique kernel release:

```text
linux-{image,dtb,headers}-ysp-maxline-public-rockchip64
7.2.0-rc3-ysp-maxline-public-rockchip64

linux-{image,dtb,headers}-ysp-maxline-wip-rockchip64
7.2.0-rc3-ysp-maxline-wip-rockchip64
```

The package layout follows this repository's existing Armbian-compatible
contract: `/boot/vmlinuz-$release`, `/lib/modules/$release`,
`/boot/dtb-$release`, `/usr/src/linux-headers-$release`, initramfs hooks, and
the `/boot/Image` and `/boot/dtb` last-installed symlinks.

The Debian rules delegate the package payload and lifecycle details to two
tracked helpers:

- [`debian/scripts/install-kernel-packages.sh`](debian/scripts/install-kernel-packages.sh)
  installs the built image, modules, DTBs, and external-module-capable headers
  into their three binary-package staging trees.
- [`debian/scripts/write-maintainer-scripts.sh`](debian/scripts/write-maintainer-scripts.sh)
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

Both profiles passed a native arm64 `Image modules dtbs` build and Debian
binary-package build on 2026-07-17. Each image package contains 3,489 modules;
the public Image is 39,053,824 bytes, the WIP Image is 39,184,896 bytes, and
both contain the 197,796-byte ROCK 5B DTB. Package names, architecture,
dependencies, release paths, feature modules, config, `Module.symvers`, and
`scripts/module.lds` were inspected from the resulting `.deb` files.

The packaged headers were also extracted, their post-install preparation was
run, and a minimal out-of-tree module was built against each. The resulting
module vermagic matched the respective public or WIP release. The WIP object
checks found `rkvdec_vdpu381_vp9_fmt_ops` in `rockchip-vdec.ko` and the FRL
rate-selection symbols in `vmlinux`. Exact package versions, byte counts, and
SHA-256 hashes are recorded in [`manifest.yaml`](manifest.yaml). Generated
packages remain under the ignored `packaging/ppa/out/maxline/package-*`
directories on the build host; they are not Git artifacts.

The complete [`verification record`](verification.md) preserves build-host
versions, exact tree and payload sizes, package metadata, symbol checks,
headers testing, and the remaining hardware boundary.

The build emitted one non-fatal warning from the imported RK3588 crypto v2
proposal (`rk2_crypto_skcipher.c`: unused local `v`). No package has been
installed or booted on the ROCK 5B yet, so compile and payload verification
must not be read as hardware validation.

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
RKVDEC H.264/H.265 multicore under concurrent RGA load, Rocket NPU, camera
media graph, crypto, CAN-FD, and HDMI-RX audio. End-to-end RKISP2 also needs
the userspace libcamera pipeline/IPA and a supported sensor description.

The current installation blacklists `snd_soc_hdmi_codec` in its kernel
command line. Leave that in place for the first boot, then remove both
blacklist spellings only for the HDMI/DP audio phase. Test the WIP kernel last;
FRL and VP9 are experimental and a successful compile does not prove either
hardware path.
