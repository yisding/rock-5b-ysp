# Maximum-mainline RK3588 kernel plan for this Armbian ROCK 5B

> Scope: ROCK 5B; Ubuntu 26.04 / Armbian 26.5.1; upstream Linux and all
> publicly available RK3588 proposal series known on 2026-07-17
> Source: `~/Code/kernel/mainline-status.md`; upstream Linux `v7.2-rc3`
> (`a13c140cc289c0b7b3770bce5b3ad42ab35074aa`); running system and this
> repository's kernel packaging
> Date: 2026-07-17
> Trust: CONFIG-INSPECTED / SOURCE-INSPECTED / DESIGN / INFERRED

## Result

The best fit is a dedicated, reproducible **maximum-mainline integration
branch based on the exact upstream `v7.2-rc3` tag**, with each not-yet-merged
series imported and recorded separately. Build it with the normal Armbian
`rockchip64-bleedingedge` configuration as a starting point, but package it
with this repository's already-proven co-installable image/DTB/headers package
layout. Do not use either Collabora's rebasing integration branch or Armbian's
entire bleeding-edge patch bundle as the release source.

Maintain two outputs from the same integration repository:

- `maxline-public`: every applicable public queued, sent, RFC, and pending
  series, with superseded revisions removed and conflicting series
  reconciled. This is the most defensible package for routine testing.
- `maxline-wip`: `maxline-public` plus public proof-of-concept commits and
  selected Collabora WIP needed for features such as HDMI FRL. This is the
  literal maximum-feature build, but it cannot honestly be called a stable or
  fully upstreamable kernel.

"All proposed patchsets" must mean **one current implementation of every
publicly proposed feature**, not every historical revision of every series.
Several entries in the supplied status file have newer successors or overlap
another proposal. Some TODO features have no public code and therefore cannot
be built at all. The distinction is recorded below instead of silently
claiming coverage.

This is an integration and build plan, not evidence that the proposed kernel
boots. The current 6.18.38 YSP kernel and its packaging prove the Armbian boot
contract, while the existing 7.2-rc3 source package proves that this repository
can package a 7.2 kernel. The proposed-series combination still needs compile,
boot, subsystem, suspend, and rollback testing.

## Why this base and not the tempting alternatives

As of this finding, kernel.org identifies `7.2-rc3` as the current mainline
release. It is newer than Collabora's `rockchip-release` base and is an exact,
reviewable tag. Three series in the supplied status document are already
queued for 7.3, so they must still be applied explicitly to a 7.2 base.
`linux-next` is useful as an applicability and conflict oracle, not as the
shipping base: its contents change daily and do not provide a durable package
identity.

The alternatives each solve the wrong problem:

| Source | Finding | Use |
| --- | --- | --- |
| Upstream `v7.2-rc3` | Exact tag, includes all features merged through 7.2 | Release base |
| Collabora `rockchip-release` | Inspected at `566f27ab33057295aa5d4e2d6cedcbfa50a5dcd2`; 167 commits over v7.1 and includes debug, CI, no-upstream, WIP, hack, and board-specific commits | Reference and WIP donor only |
| Armbian `rockchip64-bleedingedge` patch snapshot | A local inspected snapshot was a single broad commit touching 2,008 files with roughly 1.29 million insertions, including unrelated external drivers | Configuration and packaging reference only |
| `linux-next` | Moving integration target | CI comparison only |

A wholesale import of either integration tree makes it impossible to say
which proposal is included, which version won, or whether an unrelated driver
caused a regression. A manifest-driven queue makes those answers mechanical.

## Compatibility contract observed on this installation

The running machine is a Radxa ROCK 5B on Ubuntu 26.04 (`resolute`) with
Armbian 26.5.1, family `rockchip-rk3588`. It currently boots
`6.18.38-ysp-rockchip64` from NVMe. The relevant interface is:

| Item | Observed contract |
| --- | --- |
| Boot script | `/boot/boot.scr`, generated from `/boot/boot.cmd` |
| Kernel | `/boot/Image` symlink, loading the selected `vmlinuz-$release` |
| Initramfs | `/boot/uInitrd` symlink |
| DTB directory | `/boot/dtb` symlink |
| Board DTB | `rockchip/rk3588-rock-5b.dtb` from `fdtfile` in `/boot/armbianEnv.txt` |
| Modules | `/lib/modules/$release` |
| Existing custom packages | `linux-image-ysp-rockchip64`, `linux-dtb-ysp-rockchip64`, `linux-headers-ysp-rockchip64` |
| Current custom package version | `6.18.38+rk3588av1fwport20260716.1-0ubuntu1~rk1` |
| Firmware chain | DDR v1.20, BL31 v1.48, Armbian U-Boot dated 2026-06-05 |

The existing helpers under `packaging/ppa/kernel-forward-port/debian/` already
install the kernel, modules, versioned DTB tree, headers, initramfs, and the
Armbian-facing symlinks. Reuse that interface. Give the new build a unique
localversion and binary package namespace, for example:

```text
source:  linux-rockchip64-ysp-maxline
image:   linux-image-ysp-maxline-rockchip64
dtb:     linux-dtb-ysp-maxline-rockchip64
headers: linux-headers-ysp-maxline-rockchip64
release: 7.2.0-rc3-ysp-maxline-rockchip64
```

The existing `packaging/ppa/kernel-rewrite-alpha-7.2-rc3/` source package
already demonstrates the same 7.2-rc3 base and package mechanics. Copy the
packaging structure for a future implementation, but do not copy its rewritten
driver layer into this mainline-focused branch.

There is no kernel reason to replace the working SPI U-Boot or firmware.
Keeping boot firmware fixed reduces the experiment to kernel, modules, DTBs,
and initramfs.

One local configuration detail will mask a proposed feature: the current
`extraargs` contains both `module_blacklist=snd_soc_hdmi_codec` and
`modprobe.blacklist=snd_soc_hdmi_codec`. Keep that blacklist for the first boot
to minimize risk, then remove it only for the HDMI/DP audio validation phase.

## Exact source policy

Create a kernel integration repository branch such as
`rk3588-maxline-7.2-rc3`. Its first commit must be the signed upstream tag
`v7.2-rc3`, not a similarly named tarball or a moving branch. Add a machine
readable `series.yaml` beside the integration scripts. Every input needs:

```yaml
- id: usbdp-cleanup-v8
  feature: USB-C orientation and DisplayPort PHY
  message_id: 20260626-rockchip-usbdp-cleanup-v8-0-47f682987895@collabora.com
  revision: 8
  expected_patches: 29
  base_commit: <value from cover letter>
  source: https://lore.kernel.org/linux-phy/20260626-rockchip-usbdp-cleanup-v8-0-47f682987895@collabora.com/
  mbox_sha256: <record after retrieval>
  disposition: apply
  result_commits: <first>..<last>
  notes: supersedes the older standalone orientation series
```

Allowed dispositions are `apply`, `folded`, `reconciled`, `upstream`, and
`blocked-no-code`. Preserve the downloaded mailboxes or at least their SHA-256
hashes. A release build must never ask the network for "latest"; updating a
series is a deliberate manifest change followed by a full rebuild and test.

Use `b4` to retrieve mail exactly as posted and `git am -3` to retain authorship
and reviewable commits. For example, after checking the cover letter's base and
patch count:

```bash
b4 am -o ../rk3588-maxline-mboxes \
  20260626-rockchip-usbdp-cleanup-v8-0-47f682987895@collabora.com
git am -3 ../rk3588-maxline-mboxes/*.mbx
```

Do not blindly run that wildcard across several series. Use a fresh output
directory per series, apply one manifest entry at a time, and record the
resulting commit range. A failed three-way application is an integration task,
not permission to drop patches.

## Proposed-series coverage ledger

The following ledger is the 2026-07-17 input set. "Apply" means include in both
profiles. "Experimental" means include in both to satisfy maximum public
coverage, but prevent that feature from being a release gate. "WIP only" means
include only in `maxline-wip`.

### Already queued for 7.3 but absent from a 7.2 base

| Feature | Source | Decision |
| --- | --- | --- |
| VOP2 multi-output fixes | [v1](https://lore.kernel.org/linux-rockchip/20260504-vop2-layer-cfg-tmout-v1-0-730226a7331e@collabora.com/) | Apply; reconcile with later VOP reset hunks |
| YUV background color | [v2](https://lore.kernel.org/linux-rockchip/20260601-vop2-bg-yuv-v2-0-e5aef1d16fec@collabora.com/) | Apply |
| Force color format | [v17](https://lore.kernel.org/linux-rockchip/20260609-color-format-v17-0-35739b5782cc@collabora.com/) | Apply |

All status-document entries marked merged in 7.2 or earlier are already in the
base and get the `upstream` disposition. They must not be re-applied.

### Pending improvement series

| Feature | Current source/decision |
| --- | --- |
| Rocket NPU standalone DPU/PPU and pipelining | Apply [v1, 5 patches](https://lore.kernel.org/linux-kernel/20260217-accel-rocket-clean-base-v1-0-d72354325a25@r-sc.ca/) |
| Rockchip PCIe system suspend | Apply [v5, 8 patches](https://lore.kernel.org/linux-rockchip/20260316-rockchip-pcie-system-suspend-v5-0-5bb5ad37d643@collabora.com/) after generic PCI core changes |
| PCIe port/slot reset on link down | Apply [v6, 4 patches](https://lore.kernel.org/linux-pci/20250715-pci-port-reset-v6-0-6f9cce94e7bb@oss.qualcomm.com/) before Rockchip PCIe PM |
| Naneng PCIe SSC cleanup | Apply [v2](https://lore.kernel.org/linux-rockchip/1772696450-139583-1-git-send-email-shawn.lin@rock-chips.com/) before the two following PHY fixes |
| PCIe wake signal | Apply [v12](https://lore.kernel.org/linux-pci/20260707-wakeirq_support-v12-1-b4453f5bcc97@oss.qualcomm.com/) before Rockchip PCIe PM |
| Naneng TX-detect/RX-termination erratum | Apply [v1](https://lore.kernel.org/linux-rockchip/1774423383-36599-1-git-send-email-shawn.lin@rock-chips.com/) |
| Naneng SSC spread direction | Apply [v1](https://lore.kernel.org/linux-rockchip/20260714-naneng-ssc-fix-v1-1-1c40a58061ae@flipper.net/) |
| Improved USB-C orientation | Mark `folded`: the old [v2](https://lore.kernel.org/linux-rockchip/20250226103810.3746018-1-heiko@sntech.de/) is superseded by the comprehensive USBDP v8 series below |
| VOP VP clock reset | Reconcile [v3](https://lore.kernel.org/linux-rockchip/20241108185212.198603-1-detlev.casanova@collabora.com/) with the HDMI YUV/VOP reset changes; retain the behavior once |
| HDMI infoframe limiting | Use the newer second-approach [v4](https://lore.kernel.org/all/20260107-limit-infoframes-2-v4-0-213d0d3bd490@oss.qualcomm.com/), not the v1 linked by the status snapshot |
| Stateless-codec tracepoints | Apply [v1](https://lore.kernel.org/linux-rockchip/20260212162328.192217-1-detlev.casanova@collabora.com/) |
| HDMI PHY clocks | Apply [v4](https://lore.kernel.org/linux-rockchip/20260612-hdptx-clk-fixes-v4-0-ce5e1d456cda@collabora.com/) before HDMI YUV support |
| USBDP cleanup/DP support | Apply [v8, 29 patches](https://lore.kernel.org/linux-phy/20260626-rockchip-usbdp-cleanup-v8-0-47f682987895@collabora.com/); this carries the orientation successor |
| RKCIF fixes | Apply [v2, 2 patches](https://lore.kernel.org/linux-media/20260216-rkcif-fixes-v2-0-ee40931fe0ff@collabora.com/) |
| RK3x I2C SCL debounce and recovery | Use v3, a 2-patch successor to the status document's [v2](https://lore.kernel.org/linux-rockchip/20260321105146.7419-1-linux.amoon@gmail.com/); resolve and pin its cover-message ID during manifest creation |
| eMMC platform-data refactor | Apply [v2](https://lore.kernel.org/linux-rockchip/1774620875-18258-1-git-send-email-shawn.lin@rock-chips.com/) before the DLL quirk |
| eMMC DLL clock quirk | Apply [v3](https://lore.kernel.org/linux-rockchip/1775632729-22841-1-git-send-email-shawn.lin@rock-chips.com/) |
| RKVDEC bitwriter conversion | Apply corrected [v3, 4 patches](https://lore.kernel.org/linux-rockchip/20260402-rkvdec-use-bitwriter-v3-0-2072474ceaf4@collabora.com/); the status document omits the URL scheme |
| SAI slot width | Apply [v1](https://lore.kernel.org/linux-rockchip/5445638.31r3eYUQgx@workhorse/) |
| VDPU381 H.264/H.265 multicore | `reconciled`, not a blind apply: port [v1, 7 patches](https://lore.kernel.org/linux-media/20260409-rkvdec-multicore-v1-0-62b316abf0f7@collabora.com/) onto the generic parallel-job substrate described below |
| VDPU381 H.265 corrections | Apply [v2](https://lore.kernel.org/linux-rockchip/20260527194737.1999409-1-michael.bommarito@gmail.com/) before the multicore port |
| HDMI SCDC link health | Apply [v6](https://lore.kernel.org/dri-devel/20260611-scdc-link-health-v6-0-6307875a6b5e@collabora.com/) after the display core and HDMI series |
| HDMI audio warning cleanup | Apply [v1](https://lore.kernel.org/lkml/20260519-fix-hdmi-audio-warnings-v1-1-9608966c993f@collabora.com/) |
| HDMI overscan | Apply [v1](https://lore.kernel.org/linux-rockchip/20260602-hdmi-overscan-v1-0-31f71b817c80@flipper.net/) |
| HDMI 10-bit YUV422/YUV420 | Apply [v3, 14 patches](https://lore.kernel.org/linux-rockchip/20260709-dw-hdmi-qp-yuv-v3-0-a4a982a9f2e7@collabora.com/) after HDMI PHY clock fixes; reconcile its VOP/reset changes |
| V4L2 hardware usage in fdinfo | Experimental [v2, 5 patches](https://lore.kernel.org/linux-media/20260617-v4l2-add-fdinfo-v2-0-d298e98ce06a@collabora.com/); the API naming remained under review |
| DP AltMode negotiation race | Apply [v1](https://lore.kernel.org/all/20260615194923.4192117-2-rdbabiera@google.com/) after Type-C/USBDP groundwork |
| CSI D-PHY 2.5 Gbit/s | Apply [v3](https://lore.kernel.org/linux-phy/20260630-feature-mipi-csi-dphy-4k60-v3-0-176792ab71fa@wolfvision.net/) before camera pipeline testing |

### Sent, RFC, and WIP features from the main status table

| Feature | Source | Decision |
| --- | --- | --- |
| HDMI 2.0 / 4K60 scrambling | [v8, 39 patches](https://lore.kernel.org/linux-rockchip/20260702-dw-hdmi-qp-scramb-v8-0-d79890d00b6a@collabora.com/) | Apply after display framework, PHY, and VOP prerequisites |
| Synopsys DW DP bridge and audio | [v3, 10 patches](https://lore.kernel.org/linux-rockchip/20260612-synopsys-dw-dp-improvements-v3-0-dc61e6352508@collabora.com/) | Apply with the review-found reference-lifetime and DT-compatibility fixes carried as an explicit integration delta |
| RK3588 crypto engine | [v2](https://lore.kernel.org/linux-rockchip/20260708175837.1718437-1-dawidro@gmail.com/) | Apply and enable its new Kconfig symbols |
| RK3588 CAN | [v4](https://lore.kernel.org/linux-can/tencent_EF20BAF99D37B9D3B0C9FC254C8FAC04680A@qq.com/) | Apply; hardware validation requires an exposed CAN interface/transceiver |
| RKISP2 ISP | [RFC v1, 5 patches](https://lore.kernel.org/linux-media/20260424175853.638202-1-paul.elder@ideasonboard.com/) | Experimental; add the shared-media-graph RFC below for usable VICAP/ISP topology |
| RGA3 multicore | [v1, 17 patches](https://lore.kernel.org/linux-media/20260606-spu-rga3multicore-v1-0-3ec2b15675f7@pengutronix.de/) | Apply patches 1-15; patches 16-17 are test-only picks whose underlying DT/IOMMU changes are already in 7.2 |
| HDMI-RX audio | [v2](https://lore.kernel.org/linux-media/20260715200834.8486-1-royalnet026@gmail.com/) | Apply; validate capture independently of HDMI output audio |
| VDPU381 VP9 | [public WIP commit](https://github.com/dvab-sarma/android_kernel_rk_opi/commit/aa00b89b6bbfd7570e459172417e2e72921689f4) | WIP only; port rather than cherry-pick if its base differs |

For complete ISP operation, also import the [six-patch Shared Media Graph
RFC](https://lore.kernel.org/all/20260619052637.1110672-1-paul.elder@ideasonboard.com/).
It lets RKCIF/VICAP and the two ISP instances join one media graph and supports
both inline and memory-to-memory paths. End-to-end camera use additionally
needs the corresponding 19-patch libcamera rkisp2 pipeline handler/IPA and a
supported sensor DT; kernel compilation alone does not establish a working
camera.

### No public implementation to include

The status document still marks Samsung CSI DCPHY, HDMI 8K, HDMI ARC, HDMI
HDCP, DMC frequency scaling, VICAP DVP/scaler, IEP2, several encoder/decoder
formats, and other board DT enablement as TODO. Its VICAP MUX/TOISP and
VEPU580 H.264 entries are WIP but provide no public series or commit. There is
no proposal to import for these. Record each as `blocked-no-code` so the
manifest reports the gap instead of making an impossible coverage claim.

HDMI FRL controller support is WIP rather than a posted series. The PHY half
is upstream, but the controller side is required above 4K60. Selected
Collabora commits can be ported into `maxline-wip` after removing debug/hack
commits and documenting each donor SHA. That does not imply 8K support, which
remains TODO in the source status.

## Integration conflicts that require real engineering

### RGA3 versus RKVDEC multicore scheduling

The two multicore proposals change the V4L2 memory-to-memory scheduler in
different ways. RGA3 introduces a generic `max_parallel_jobs` mechanism;
RKVDEC adds a manual/early job-completion path. Applying both mailboxes in
sequence is likely to conflict textually and would leave two competing models.

Use RGA3's generic parallel-job infrastructure as the shared substrate. Apply
the non-conflicting RKVDEC RCB sizing, IOMMU, and per-core changes, then port
the RKVDEC scheduling logic onto that substrate in a separately authored
`integration: reconcile rkvdec and rga parallel jobs` patch. The manifest
must point from both original series to this resulting commit. Test concurrent
decode and RGA loads; testing each engine alone is insufficient.

### Display stack overlap

The queued VOP2 fixes, old VOP clock-reset series, HDMI PHY clock fixes, HDMI
2.0, HDMI YUV, forced color format, infoframe limits, and Rock 5B DT changes
touch adjacent code. Apply them in dependency order and retain each behavior
exactly once. In particular, HDMI YUV v3 depends at runtime on the PHY clock
fixes and carries VOP/reset robustness that overlaps the older VOP reset work.
A clean `git am` is not proof that the combined atomic modeset state is sound.

### DP review deltas

DW DP v3 had high-severity automated/review findings around reference cleanup
and DT backward compatibility. Preserve the posted series for provenance, then
carry fixes as named integration commits. Do not hide them by editing the
mailbox. Exercise probe failure, cable replug, both USB-C orientations, DP
audio, and repeated AltMode negotiation.

### ISP is an RFC stack, not one driver

RKISP2 is explicitly RFC-quality and the shared graph API still has open TODOs.
The proposed kernel should compile it and make it available, but camera success
requires the RKCIF/CSI path, shared graph, sensor DT, and matching libcamera
userspace. Keep camera failures from blocking validation of otherwise sound
storage/display kernels, while never labeling the ISP production-ready.

## Recommended application order

Use subsystem checkpoints so every conflict has a small search space:

1. Exact upstream `v7.2-rc3` and the three queued-for-7.3 VOP2 series.
2. Generic framework work: PCI reset/wake, HDMI infoframe limit v4, V4L2
   trace/fdinfo, Shared Media Graph, and the selected generic V4L2 parallel-job
   implementation.
3. PCIe, bus, and PHY: Rockchip PCIe PM; Naneng SSC/errata; I2C v3; eMMC
   refactor then DLL; SAI.
4. Display/HDMI: PHY clocks, reconciled VOP resets, HDMI 2.0, HDMI YUV/color,
   SCDC, overscan, and audio fixes.
5. USB-C/DP: USBDP v8, DW DP v3 plus review deltas, then AltMode race fix and
   board integration.
6. Camera: CSI D-PHY, RKCIF fixes, shared graph, RKISP2, and board/sensor DT.
7. Codecs/RGA: bitwriter, H.265 fixes, RGA3 generic scheduler and driver work,
   then reconciled RKVDEC multicore and fdinfo.
8. Accelerators and peripherals: Rocket, crypto, CAN, HDMI-RX audio.
9. `maxline-wip` only: curated FRL controller work and the VP9 proof of concept.

After each numbered checkpoint, build at least `Image`, modules, and DTBs. Tag
successful checkpoints. This turns a final failure from an all-series mystery
into a one-subsystem regression.

## Kernel configuration

Start with Armbian's normal
`config/kernel/linux-rockchip64-bleedingedge.config`, copied at a pinned Armbian
build commit. Do not use the rewritten 7.2 package's config as the authoritative
base. Merge a small feature fragment with `scripts/kconfig/merge_config.sh`, run
`make olddefconfig`, and assert the final `.config`; proposed series can rename
or add symbols.

The baseline inspected on 2026-07-17 already enables the Rockchip RGA, VDEC,
HDMI-RX, Panthor GPU, and Rocket NPU drivers as modules. It did not expose all
capture symbols, so the feature fragment should request at least:

```text
CONFIG_DRM_ROCKCHIP=m
CONFIG_DRM_PANTHOR=m
CONFIG_DRM_ACCEL_ROCKET=m
CONFIG_ROCKCHIP_VOP2=y
CONFIG_ROCKCHIP_DW_DP=y
CONFIG_ROCKCHIP_DW_HDMI_QP=y
CONFIG_ROCKCHIP_DW_MIPI_DSI2=y
CONFIG_DRM_DW_HDMI_QP_CEC=y
CONFIG_PHY_ROCKCHIP_SAMSUNG_HDPTX=m
CONFIG_PHY_ROCKCHIP_USBDP=m
CONFIG_TYPEC_FUSB302=m
CONFIG_VIDEO_HANTRO=m
CONFIG_VIDEO_HANTRO_ROCKCHIP=y
CONFIG_VIDEO_ROCKCHIP_VDEC=m
CONFIG_VIDEO_ROCKCHIP_RGA=m
CONFIG_VIDEO_ROCKCHIP_CIF=m
CONFIG_VIDEO_DW_MIPI_CSI2RX=m
CONFIG_VIDEO_ROCKCHIP_ISP2=m
CONFIG_VIDEO_SYNOPSYS_HDMIRX=m
CONFIG_ROCKCHIP_IOMMU=y
CONFIG_VSI_IOMMU=y
```

Treat this as requested policy, not a guaranteed valid fragment. Check the
actual symbol names and dependency-selected values after all series are
applied. Add the crypto and CAN symbols introduced by their respective
series. Fail the build if an expected non-optional feature becomes unset; do
not accept `olddefconfig` silently dropping it.

## Build and package path

Build natively on arm64, as used by the existing Armbian builder, to avoid a
second variable. A direct kernel checkpoint can use:

```bash
make olddefconfig
make -j"$(nproc)" Image modules dtbs
make dtbs_check
```

For the installable result, copy the proven Debian packaging into a new,
isolated packaging directory and update only package identity, source pin,
changelog, and config. Build all three binary packages from one source tree.
Install image, DTB, and headers in the same `apt install` transaction so the
versioned files and `/boot` symlinks cannot drift apart.

Do not replace or rename the currently installed YSP packages. Co-installation
is the rollback mechanism. Before the first reboot, verify:

```bash
dpkg-deb -c linux-image-ysp-maxline-rockchip64_*.deb
dpkg-deb -c linux-dtb-ysp-maxline-rockchip64_*.deb
test -e /boot/dtb-7.2.0-rc3-ysp-maxline-rockchip64/rockchip/rk3588-rock-5b.dtb
test -d /lib/modules/7.2.0-rc3-ysp-maxline-rockchip64
readlink -f /boot/Image
readlink -f /boot/dtb
readlink -f /boot/uInitrd
```

Because this boot path has no interactive kernel menu, retain serial access
and a known-good SD/SPI recovery route. Record the old symlink targets before
installation. A rollback consists of selecting/reinstalling the old
image+DTB package pair and regenerating the initramfs/symlinks through the same
package hooks—not deleting files by hand.

## Validation gates

Separate applicability, compilation, boot, and functional claims:

### Source and build

- Verify the upstream tag and manifest mailbox hashes.
- Require `git diff --check`, no `.rej`/`.orig`, no uncommitted mailbox edits,
  and one manifest disposition for every ledger entry.
- Run the config assertions after `olddefconfig`.
- Build `Image modules dtbs`; run `dtbs_check`; inspect new warnings with
  focused `W=1` builds for touched subsystems.
- Confirm the packaged `uname -r`, module directory, board DTB, and symlink
  destinations all match.

### First boot and platform survival

- Boot first with the existing HDMI codec blacklist and serial logging.
- Confirm `uname -a`, DT compatibility, root-on-NVMe, PCIe links, USB host,
  network, fan/thermal, cpufreq, GPU render node, and clean module loading.
- Exercise reboot and several suspend/resume cycles before enabling optional
  media modules. Root NVMe survival after resume is a release gate.

### Feature validation

- Display: `modetest` on both HDMI outputs; 1080p, 4K30, 4K60, 8/10-bit and
  YUV modes; hotplug; CEC; overscan; SCDC debugfs; concurrent outputs.
- Audio: remove the HDMI codec blacklist, then test HDMI and DP playback,
  unplugged-cable behavior, and HDMI-RX capture separately.
- USB-C/DP: both cable orientations, USB-only, DP-only, mixed USB+DP, repeated
  replug, suspend/resume, and multiple adapters.
- Video decode: `v4l2-compliance` plus H.264/H.265/AV1 conformance and fluster
  runs; then concurrent multicore decode and combined decode+RGA stress.
- RGA3: `v4l2-compliance`, format/size coverage, simultaneous contexts, and
  multicore throughput without ordering or fence corruption.
- NPU: enumerate the Rocket DRM accelerator, run standalone DPU/PPU and
  pipelined workload tests using compatible upstream userspace.
- Camera: inspect `media-ctl -p`, validate memory-to-memory and inline paths,
  then run the matching libcamera rkisp2 pipeline on a documented sensor.
- PCIe/PHY/eMMC/I2C/CAN/crypto: targeted suspend, link reset, wake, storage
  stress, error-recovery, CAN loopback, and crypto test-manager coverage.

`maxline-public` can become the day-to-day kernel only after platform survival,
storage, display, USB-C, and primary media tests pass. `maxline-wip` should stay
an opt-in test package behind the known-good boot path.

## Userspace boundary

This kernel is maximum **mainline architecture**, not a superset of Rockchip's
6.1 BSP ABI. It uses upstream interfaces: Panthor for the GPU, Rocket for the
NPU, V4L2 request/media APIs for codecs and capture, and the upstream V4L2 RGA
driver. Rockchip MPP, private RGA, and RKNPU ioctl stacks are different drivers
and UAPIs. Existing RKMPP/librga/RKLLM applications will not automatically use
the corresponding proposed mainline drivers merely because Armbian boots.

Do not forward-port those vendor drivers into this branch: doing so would
defeat the purpose of an auditable mainline-feature kernel and reintroduce the
large BSP maintenance surface. Keep the existing 6.18 YSP/BSP-forward-port
package for vendor-userspace workloads and use the maxline package to validate
the upstream stack.

## Evidence and reproduction

- **Identity:** Radxa ROCK 5B; Armbian 26.5.1 / Ubuntu 26.04; NVMe root;
  `6.18.38-ysp-rockchip64`; upstream base `v7.2-rc3` at
  `a13c140cc289c0b7b3770bce5b3ad42ab35074aa`.
- **Detection:** inspected `/etc/armbian-release`, `/boot/boot.cmd`,
  `/boot/armbianEnv.txt`, `/proc/cmdline`, installed packages, boot symlinks,
  this repository's kernel packaging, Armbian's current family/config files,
  Collabora's status and integration branch, kernel.org, and linked proposal
  cover letters/review mirrors.
- **Exercise:** source/config/boot inspection plus proposal dependency and
  supersession analysis; no maximum-mainline kernel was built in this finding.
- **Pass/fail signal:** the plan passes documentation consistency and source
  coverage review; kernel build and hardware pass signals are the gates above.
- **Artifacts:** this finding; the supplied source snapshot remains at
  `~/Code/kernel/mainline-status.md` and is intentionally not duplicated here.

## Boundary

The proposal inventory and upstream version are time-sensitive. A new series
revision or an upstream merge can change the correct queue immediately. Refresh
the manifest before implementation, but retain this dated ledger so changes are
reviewable. Mailing-list review comments were sampled for material conflicts;
this is not a substitute for reading every reply when importing a series.

No kernel from this plan has been compiled or booted, proposed features have
not been exercised on this board, and HDMI FRL/VP9 ports have not been audited.
No-code TODOs, vendor ABI compatibility, 8K, HDCP, ARC, DMC scaling, and missing
board/sensor DT work are not solved by stacking public patches.

## Primary references

- [Collabora RK3588 mainline status](https://gitlab.collabora.com/hardware-enablement/rockchip-3588/notes-for-rockchip-3588/-/blob/main/mainline-status.md)
- [Collabora RK3588 Linux integration tree](https://gitlab.collabora.com/hardware-enablement/rockchip-3588/linux)
- [Linux kernel release status](https://www.kernel.org/)
- [Armbian build repository](https://github.com/armbian/build)
- [Armbian user configuration and `userpatches`](https://docs.armbian.com/Developer-Guide_User-Configurations/)
- [Shared Media Graph RFC](https://lore.kernel.org/all/20260619052637.1110672-1-paul.elder@ideasonboard.com/)
- [RKISP2 libcamera RFC](https://lists.libcamera.org/pipermail/libcamera-devel/2026-July/059937.html)
- [RGA3 multicore series mirror](https://patchew.org/linux/20260606-spu-rga3multicore-v1-0-3ec2b15675f7%40pengutronix.de/)
- [HDMI YUV series mirror](https://patchew.org/linux/20260709-dw-hdmi-qp-yuv-v3-0-a4a982a9f2e7%40collabora.com/)

## Why it matters / follow-up

Implement the integration repository and manifest first, before modifying this
repository's packaging. The first useful milestone is `maxline-public` through
the bus/PHY checkpoint, booted with the current audio blacklist. Add display,
DP, and media checkpoints independently; only then create and install the
co-installable package. Recheck the status document, upstream release, series
revisions, and Collabora integration head on every refresh.
