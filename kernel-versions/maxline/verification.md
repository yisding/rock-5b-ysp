# RK3588 maxline implementation and build record

> Scope: 2026-09-13 rebase of the RK3588 maxline `public`/`wip` stacks from
> shipped Linux `v7.2` to `v7.3-rc2`, the five-series proposal refresh on top
> of it, and the first source-package build; plus retained earlier evidence
> Source: this directory's [`README.md`](README.md), manifest, public/WIP
> ledgers, exported patches, pinned configuration, and the
> native build and package inspections recorded below
> Date: 2026-09-13
> Trust: MEASURED (build/package results) / SOURCE-INSPECTED (integrated trees
> and package payloads) / CONFIG-INSPECTED (pinned final configuration)
> Board/build host: Radxa ROCK 5B, native arm64
> Host OS: Armbian 26.5.1 / Ubuntu 26.04 (`resolute`)
> Running recovery kernel: `6.18.44-ysp-rockchip64`
> Result: `public` rebased to `v7.3-rc2`, refreshed five proposal series, and
> **passes a full native arm64 `Image modules dtbs` build**. `wip` replayed its
> 19-commit tail cleanly but was not compiled. Both profiles produced signed
> source packages. Nothing has been installed or booted.

## Repository handoff

Everything required to reproduce and audit the two kernel trees is in
this [`maxline/`](README.md) directory:

- `manifest.yaml` pins the upstream and linux-next bases, four integration
  heads, patch/config hashes, intended package releases, and current
  verification boundary.
- `public-series.tsv` records every public mailbox, patch count, mailbox hash,
  and integration disposition.
- `wip-donors.tsv` records every selected WIP donor commit, source URL,
  disposition, and subject.
- `patches/maxline-public.patch` and `patches/maxline-wip.patch` are the exact
  tree deltas used by the builder. They make the final sources independent of
  future mailing-list or integration-branch rebases.
- `config/arm64-rockchip64.config` is the exact final configuration.
- `build-kernel.sh` and `debian/` produce co-installable Armbian-compatible
  image, DTB, and headers packages.

Generated object trees and `.deb` files are intentionally ignored rather than
committed. The checked-in source deltas, configuration, and packaging reproduce
the refreshed source profiles; no refreshed binary package is claimed here.

## Exact source identities

| Layer | Identity | Size relative to parent |
| --- | --- | --- |
| Linus base | `v7.3-rc2`, `df2908090cda368b01ff43709f51890076c56157` | fetched 2026-09-13; Makefile version `7.3.0-rc2` |
| Public | `maxline-public-20260913`, `1e66ae0b4633f6a3de00b7bd705b10c45f44ff8a` | 248 commits; 171 files, 30,742 insertions, 4,524 deletions above `v7.3-rc2` |
| WIP | `maxline-wip-20260913`, `7306d4ede54c9a78cebd3ed31156bdeecc57dc2d` | 19-commit tail; 18 files, 1,391 insertions, 54 deletions above the public head |
| Superseded public | `rk3588-7.2-public`, `a52ffff8cb35f2c2bd99450ca22f5d1e268cc18a` | 299 commits on `v7.2` |
| Superseded WIP | `rk3588-maxline-wip`, `5466810e49f94d670a65b97db745c8bdc6596f08` | 19 commits on that public head |
| linux-next base | `next-20260731`, `415606a7be939835db9b0d6b711887586646346d` | historical; not replayed for this refresh |
| Public-next | `rk3588-maxline-public-next`, `0cae4ac6682384151b7c94c5db7f614775e0eee6` | historical; 264 commits above linux-next |
| WIP-next | `rk3588-maxline-wip-next`, `15a5179dc3b2318e6c56d300e2f4c74ef0a3fb7b` | historical; 19 commits above public-next |

The public tree covers 41 current public series dispositions, now 16
`upstream`, 13 `reconciled`, and 12 `applied`. `applied` means the posted
implementation was retained, `upstream` means the relevant current
implementation was already in the base, and `reconciled` means the feature was
ported or combined with overlapping work. The WIP ledger records 25 Collabora
donor commits. Only selected non-debug feature work is retained; CI, debug,
hack, and unrelated board work from the Collabora integration branch is
excluded.

The exported deltas are pinned as follows:

| File | SHA-256 |
| --- | --- |
| `patches/maxline-public.patch` | `6ba6bd663c07ec593f881a6e65faab4d45b06698d220d7129ff0ee5a63d3c9a2` |
| `patches/maxline-wip.patch` | `d980213908315a7b37dcfe7d91be7f0a0e2fc5d237d688e5982f6fafaa9d4ad0` |
| `config/arm64-rockchip64.config` | `a571b504f7bdf7aa3db37c7097390a9a2781561852af4587d0476b5ed9cf2450` |

`lore.kernel.org` now serves an anti-bot challenge to non-browser clients, so
the reconstructed `https://lore.kernel.org/all/<first_message_id>/raw` URL no
longer works from a script. Fetch the mailbox through the
`patchwork.kernel.org` API instead — `/api/1.2/series/?q=<terms>` to resolve a
series id, then `https://patchwork.kernel.org/series/<id>/mbox/` — and check
the series record's `received_all` before trusting it: per-project copies are
sometimes short a patch. The ledger hash verifies the downloaded mailbox
either way.

The 2026-08-02 refresh is in the
[`proposal finding`](../../findings/2026-08-02-rk3588-maxline-proposal-refresh.md);
this pass, including the ten series that reached Linus and the one deferred
series, is in the
[`update finding`](../../findings/2026-09-13-kernel-lines-updated-to-latest-upstreams.md).

## Material integration work

The combined tree was not produced by blindly concatenating mailboxes. The
following integration choices were necessary and are present in the exported
patches:

- RGA3 parallel jobs and RKVDEC multicore were combined around one generic
  V4L2 M2M parallel-job model while retaining RKVDEC per-core power, watchdog,
  metrics, and fdinfo behavior.
- The overlapping VOP2 reset, forced-format, HDMI scrambling, 10-bit YUV,
  SCDC, overscan, and HPD changes were reduced to one implementation of each
  behavior against the current DRM APIs.
- DW DisplayPort runtime PM, audio, OOB HPD, reference-lifetime fixes, and DT
  compatibility were ported to the current layouts.
- Rockchip PCIe system PM was ported after the generic PCI reset and wake work.
- RKCIF fixes, the Shared Media Graph RFC, and RKISP2 were combined into one
  camera media graph.
- The duplicated Hantro AV1 IRQ context from the tracepoint and fdinfo series
  was reduced to one declaration while preserving both sets of metrics.
- The Shared Media Graph RFC's `devv_dbg()` typo was corrected to `dev_dbg()`.
- The V4L2 parallel-job setter was exported for modular RGA/RKVDEC consumers,
  and RKISP2 was made to select the modular ISP helpers it calls.
- The WIP FRL port preserves the public HDMI 2.0/YUV/SCDC stack while adding
  FRL training, rate selection, PHY mode/TxFFE control, VOP ACLK scaling, and
  ROCK 5B FRL-enable GPIO handling.
- Public VDPU381 VP9 v1 replaces the former private WIP donor and is integrated
  with the public multicore RKVDEC device model.
- The linux-next replay keeps its `atomic_create_state` bridge API while
  retaining DW-DP v8 bus-format negotiation and omits exact equivalents already
  accepted in DRM, USB, and media integration trees. Its forced-color replay
  removes a duplicate color-format helper already supplied by the next base.
- HDMI v10's connector-state creation is ported to Linus's `reset` callback;
  its OOB-HPD walk uses Linus's scoped bridge iterator, while the linux-next
  endpoint retains its newer state-creation and iterator APIs.

## Configuration result

### 2026-08-23 release-base rebase audit

- Fetched upstream through `4352b8aee98005853aa63f57d6377282de17a33f` and tag
  `v7.2@8d3ae59288f1`.
- Rebased all 299 public commits cleanly from `7.2-rc6@237a1c39e8df` to `v7.2`,
  then rebased all 19 WIP commits cleanly from the old public head to the new one.
- Compared each refreshed final tree with its corresponding pre-rebase final tree:
  both differ only by the 747 commits between `7.2-rc6` and `v7.2` (603 files,
  +8,554/-3,055). The rebase introduced no integration-delta drift.
- Verified the exported WIP patch reproduces the WIP branch tree exactly when
  applied on top of the public head.
- Ran arm64 `olddefconfig` against the checked-in config on the WIP tree. Every
  explicitly listed RK3588 feature selection remained unchanged; observed differences
  were compiler/toolchain-derived hidden symbols plus new v7.2 defaults such as
  `COMPAT_VDSO` and `ARM64_BTI_KERNEL`, not losses of requested board features.

### Retained 2026-08-02 compile evidence

The full config is checked in. Important requested results include:

```text
CONFIG_CAN_ROCKCHIP_CANFD=m
CONFIG_CRYPTO_DEV_ROCKCHIP2=m
CONFIG_DRM_ACCEL_ROCKET=m
CONFIG_DRM_PANTHOR=m
CONFIG_DRM_ROCKCHIP=y
CONFIG_PHY_ROCKCHIP_SAMSUNG_HDPTX=m
CONFIG_PHY_ROCKCHIP_SAMSUNG_DCPHY=m
CONFIG_PHY_ROCKCHIP_USBDP=y
CONFIG_ROCKCHIP_DW_DP=y
CONFIG_ROCKCHIP_DW_HDMI_QP=y
CONFIG_ROCKCHIP_DW_MIPI_DSI2=y
CONFIG_ROCKCHIP_IOMMU=y
CONFIG_ROCKCHIP_VOP2=y
CONFIG_TYPEC_FUSB302=y
CONFIG_VIDEO_HANTRO=m
CONFIG_VIDEO_HANTRO_ROCKCHIP=y
CONFIG_VIDEO_ROCKCHIP_CIF=m
CONFIG_VIDEO_ROCKCHIP_ISP2=m
CONFIG_VIDEO_ROCKCHIP_RGA=m
CONFIG_VIDEO_ROCKCHIP_VDEC=m
CONFIG_VIDEO_SYNOPSYS_HDMIRX=m
CONFIG_VSI_IOMMU=y
```

## Build environment and commands

The 2026-09-13 refresh ran one eight-job native arm64 build of `public` with
the system toolchain path required by this repository, through ccache into the
shared `~/Code/.ccache` store:

```bash
refresh="/home/yi/Code/rock-5b/build/maxline-refresh-20260913"
cp kernel-versions/maxline/config/arm64-rockchip64.config "$refresh/builds/public/.config"
PATH=/usr/sbin:/usr/bin:/sbin:/bin make -C "$refresh/public" \
  O="$refresh/builds/public" olddefconfig
CCACHE_DIR=/home/yi/Code/.ccache PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  make -C "$refresh/public" O="$refresh/builds/public" \
  CC="ccache gcc" -j8 Image modules dtbs
```

`wip` did not get a full-tree build, but it did get a focused gate over every
directory its 19-commit tail touches, in a freshly configured object tree:

```bash
cp kernel-versions/maxline/config/arm64-rockchip64.config "$refresh/builds/wip/.config"
PATH=/usr/sbin:/usr/bin:/sbin:/bin make -C "$refresh/wip" \
  O="$refresh/builds/wip" olddefconfig
CCACHE_DIR=/home/yi/Code/.ccache PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  make -C "$refresh/wip" O="$refresh/builds/wip" \
  CC="ccache gcc" -j8 drivers/gpu/drm/ drivers/phy/rockchip/
```

That gate exits successfully with no compile error, and the FRL objects are
genuinely built rather than skipped: `dw-hdmi-qp.o` (581,040 bytes),
`dw_hdmi_qp-rockchip.o` (431,784), `rockchip_drm_vop2.o` (700,728),
`drm_scdc_helper.o` (380,504), and `phy-rockchip-samsung-hdptx.o` (641,064),
with FRL symbols present in the SCDC helper and the dw-hdmi-qp bridge. A
focused gate is not a full-tree build; `wip` still owes one.

### Superseded 2026-08-02 environment

The 2026-08-02 refresh ran two concurrent four-job native arm64 builds. These
standalone compile gates invoked GCC directly and did not use ccache. They
describe the superseded `7.2-rc6` source identity. The same host reports:

```text
gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0
GNU ld 2.46
GNU Make 4.4.1
dpkg-buildpackage 1.23.7
pahole 1.31
git 2.55.0
```

The refreshed compile commands, after copying the pinned config and running
`olddefconfig` in each object directory, are:

```bash
maxline_refresh="$PWD/packaging/ppa/out/maxline/refresh-20260802"
PATH=/usr/sbin:/usr/bin:/sbin:/bin make \
  --jobserver-style=pipe \
  -C "$maxline_refresh/worktrees/mainline" \
  O="$maxline_refresh/builds/linus-public" \
  -j4 Image modules dtbs
PATH=/usr/sbin:/usr/bin:/sbin:/bin make \
  --jobserver-style=pipe \
  -C "$maxline_refresh/worktrees/wip-next" \
  O="$maxline_refresh/builds/next-wip" \
  -j4 Image modules dtbs
```

## 2026-09-13 compile result — `public`

The command above exited successfully with no compile error. This was an
incremental resume after two fixes, so the log is not a whole-tree warning
census; treat it as a build-success result, not a warning-free claim.

| Result | `public` on `v7.3-rc2` |
| --- | ---: |
| Kernel release | `7.3.0-rc2+` |
| `Image` bytes | 39,578,112 |
| `vmlinux` bytes | 464,399,080 |
| ROCK 5B DTB bytes | 198,330 |
| Built modules | 3,484 |
| `rockchip-vdec.ko` bytes | 5,959,880 |

The objects the refreshed series own are all present and linked:

| Module | Bytes | Series |
| --- | ---: | --- |
| `rockchip-isp2.ko` | 3,860,880 | rkisp2 v3 |
| `rk_crypto2.ko` | built | RK3588 crypto v3 (module renamed from the v2 spelling) |
| `phy-rockchip-samsung-dcphy.ko` | 599,704 | Samsung DC-PHY v4 |

`rockchip-vdec.ko` still exports `rkvdec_vdpu381_vp9_fmt_ops`, so the public
VDPU381 VP9 backend survived the base bump.

Two failures were found and fixed during this gate, both invisible to the
merge machinery:

1. `drm/bridge: port OOB HPD to scoped Linus iterator` renamed
   `drm_for_each_bridge_in_chain()` to `_scoped` for the old Linus base;
   upstream `12f5090aaa3cc` renamed `_scoped` back, so the port produced an
   implicit-declaration error. The port was deleted.
2. `drm/display: bridge_connector: Use HDMI color format for HDMI conns`
   applied without conflicting even though upstream `9743ab2c18204` is the
   same patch, producing a duplicate definition of
   `drm_bridge_connector_color_format()`. The commit was dropped.
3. The retained rkisp2 shared-media-graph join still named
   `RKISP2_ISP_PAD_SINK_VIDEO`, which the v3 driver replaced with a
   `DMA_BASE`/`DMA_0..2` model plus a dedicated inline pad. It now targets
   `RKISP2_ISP_PAD_SINK_VIDEO_CIF`.

## Superseded 2026-08-02 compile results

The Linus/public command exited successfully, and an immediate incremental
rerun also exited successfully. These are raw, unstripped build-tree artifacts,
not packaged payload sizes:

| Result | Linus/public |
| --- | ---: |
| Kernel release | `7.2.0-rc6+` |
| `Image` bytes | 39,119,360 |
| `vmlinux` bytes | 462,354,488 |
| ROCK 5B DTB bytes | 198,298 |
| Built modules | 3,489 |
| `rockchip-vdec.ko` bytes | 5,984,984 |

`rockchip-vdec.ko` exports `rkvdec_vdpu381_vp9_fmt_ops`, confirming the new
public VDPU381 VP9 backend is present in the completed module.

The linux-next/WIP build first ran at four jobs, then resumed incrementally at
eight jobs after Linus completed. Focused builds had already passed for the
VDPU381 VP9 object and the next-only RKISP2 buffer-size helper port. The broad
build subsequently compiled the refreshed Rockchip PHY, PCIe, VOP2/DRM,
DW-DP, and HDMI paths without error. It was stopped at the user's request
before final link, so it has no successful full-build exit status or final
artifact measurements.

The standalone Debian package reproduction commands are:

```bash
kernel-versions/maxline/build-kernel.sh public
kernel-versions/maxline/build-kernel.sh wip
```

The superseded 2026-07-17 compile checkpoint was also exercised through the
package builder's guarded reuse path:

```bash
MAXLINE_BUILD_DIR=packaging/ppa/out/maxline/build-public-check \
MAXLINE_SOURCE_DIR=packaging/ppa/out/maxline/linux-public \
MAXLINE_JOBS=8 \
  kernel-versions/maxline/build-kernel.sh public

MAXLINE_BUILD_DIR=packaging/ppa/out/maxline/build-public-check \
MAXLINE_SOURCE_DIR=packaging/ppa/out/maxline/linux-wip \
MAXLINE_JOBS=8 \
  kernel-versions/maxline/build-kernel.sh wip
```

The helper rejects a checkpoint unless both paths are supplied, the source is
clean, and its `HEAD` is the exact pinned profile commit. The normal path does
not depend on checkpoint objects: it archives the pinned base, applies the
checked-in deltas, installs the checked-in config and Debian packaging, and
performs the full build.

## Historical 2026-07-17 compile and payload results

The superseded `v7.2-rc3` profiles passed `Image modules dtbs` and a binary
Debian package build. These sizes do not describe the 2026-08-02 refresh.

| Result | Public | WIP |
| --- | ---: | ---: |
| Kernel release | `7.2.0-rc3-ysp-maxline-public-rockchip64` | `7.2.0-rc3-ysp-maxline-wip-rockchip64` |
| `Image` bytes | 39,053,824 | 39,184,896 |
| `vmlinux` bytes | 462,123,272 | 462,246,680 |
| ROCK 5B DTB bytes | 197,796 | 197,796 |
| Installed modules | 3,489 | 3,489 |
| `rockchip-vdec.ko` bytes | 229,496 | 246,432 |

Representative packaged public modules were inspected directly:

| Module | Bytes |
| --- | ---: |
| `rk_crypto2.ko` | 58,456 |
| `rockchip-rga.ko` | 111,328 |
| `rockchip-cif.ko` | 123,008 |
| `rockchip-isp2.ko` | 185,848 |
| `rockchip-vdec.ko` | 229,496 |
| `synopsys-hdmirx.ko` | 148,024 |
| `rockchip_canfd.ko` | 48,520 |

The WIP `rockchip-vdec.ko` symbol table contains
`rkvdec_vdpu381_vp9_fmt_ops` and `rkvdec_vdpu381_vp9_decoded_fmts`. The WIP
`vmlinux` contains `dw_hdmi_qp_bridge_frl_rate_valid` and
`dw_hdmi_qp_rk3588_set_frl_rate`. These checks prove that the ported objects
were linked, not that the corresponding hardware paths work.

## Historical 2026-07-17 Debian artifacts

Public package version:
`7.2.0~rc3+rk3588maxlinepublic20260717-0ubuntu1`.

| Public package | Bytes | SHA-256 |
| --- | ---: | --- |
| `linux-dtb-ysp-maxline-public-rockchip64` | 693,854 | `4ad4d5834421b828debe3891a944a03c917580bdf1414dbcdb4f21b81c925190` |
| `linux-headers-ysp-maxline-public-rockchip64` | 16,788,148 | `a0c2a1718eb8f015a0fd5d85142bbf2d29173fdedaea1f525c0b63ac6b64f52c` |
| `linux-image-ysp-maxline-public-rockchip64` | 55,551,268 | `43e5e553f480f088949ed99d8faecc0bdd0b285ce62cb4eccb7970bbd163bb67` |

WIP package version: `7.2.0~rc3+rk3588maxlinewip20260717-0ubuntu1`.

| WIP package | Bytes | SHA-256 |
| --- | ---: | --- |
| `linux-dtb-ysp-maxline-wip-rockchip64` | 693,584 | `ef6a81166ad680c6c1fae171a9e05dace2f42e9d46b119bd4e15c3e81074eafb` |
| `linux-headers-ysp-maxline-wip-rockchip64` | 16,761,736 | `2db62d7d194c238f03245cbf47e5e93a5b4bd26a5726fbb0b9ef774cf5c266f1` |
| `linux-image-ysp-maxline-wip-rockchip64` | 55,569,264 | `2a0e06045b73f10dcf0d3cb43b85c2a2a17addc2d3ef79b2d7c0f080807bf369` |

All six packages are `arm64`. The image packages depend on
`initramfs-tools | linux-initramfs-tool`; the headers packages carry their
compiler, ELF, SSL, BTF, flex, and bison dependencies. The package names and
release paths are unique between profiles, allowing them to coexist with one
another and the known-good 6.18 packages. Their maintainer hooks intentionally
make the most recently installed profile the Armbian `/boot/Image` and
`/boot/dtb` target.

The installed layout was verified inside the packages:

```text
/boot/vmlinuz-$release
/boot/config-$release
/boot/System.map-$release
/boot/dtb-$release/rockchip/rk3588-rock-5b.dtb
/lib/modules/$release
/usr/src/linux-headers-$release
```

## Historical 2026-07-17 verification performed

The final source/package checks were:

- both exported patches reverse-apply cleanly to their pinned branch heads;
- commit counts are 241 above base and 21 above public;
- patch and config hashes equal the manifest;
- all 38 public mailbox hashes have valid SHA-256 form and unique IDs;
- all 26 WIP donor commit IDs are valid and unique;
- YAML parsing, `bash -n`, ShellCheck, and `git diff --check` pass;
- all six package control files parse and report the intended package,
  version, architecture, dependencies, and `Provides` fields;
- package payloads contain the intended Image, 3,489 modules, ROCK 5B DTB,
  `.config`, `Module.symvers`, and `scripts/module.lds`;
- both headers packages were extracted, their post-install preparation was
  run, and a minimal external module was built successfully;
- public external-module vermagic is
  `7.2.0-rc3-ysp-maxline-public-rockchip64 SMP preempt mod_unload aarch64`;
- WIP external-module vermagic is
  `7.2.0-rc3-ysp-maxline-wip-rockchip64 SMP preempt mod_unload aarch64`;
- packaged headers md5 manifests verify after extraction;
- every recorded package size and SHA-256 value was compared to the local
  generated artifact.

The headers test caught and fixed a staging defect in which cleanup could
remove architecture-selected static headers. The final helper restores static
source headers, overlays generated headers from the exact object tree, and the
rebuilt WIP headers package passes the external-module test. The already-built
public package was confirmed to contain every static header affected by the
same final helper.

One non-fatal compiler warning remains in imported proposed code:

```text
drivers/crypto/rockchip/rk2_crypto_skcipher.c:456: unused variable 'v'
```

It does not fail the build or package tests, but it should be checked against a
future revision of the RK3588 crypto series.

## Explicit boundary and next action

`public` passes its full native arm64 compile on `v7.3-rc2`, `wip` passes a
focused compile over the directories its tail touches, and both profiles have
signed source packages uploaded to `ppa:yi-ding/ubuntu-rock-5b-experimental`.
**No maxline package has been installed or booted.** `wip` still owes a
full-tree build. There is no claim for NVMe/root survival,
Ethernet, USB, PCIe, suspend, display, audio, camera, codec, NPU, crypto, CAN,
HDMI-RX, FRL, or VP9 runtime behavior.

Two defects in this refresh were invisible to `git rebase` and `git am` and
surfaced only at compile time — a maxline port that upstream had inverted, and
a duplicate function definition from a commit upstream had taken verbatim.
Treat a clean replay across a release boundary as unproven until the affected
objects compile; run the `wip` compile before trusting its Launchpad build.

Run the `wip` full-tree compile, confirm the Launchpad builds of both
profiles, then install public first while retaining the 6.18 packages and
recovery access.
Keep the existing `snd_soc_hdmi_codec` blacklist for the survival boot, then
test the public platform/display/DP/media gates in the order documented in the
main finding. Test public VP9 after the platform gates. Install `wip` only after
public is recoverable and understood; test FRL last.

No-code status TODOs remain outside the possible build: HDMI 8K/ARC/HDCP, DMC
frequency scaling, VICAP DVP/scaler, IEP2, unpublished
codec formats, and missing board/sensor descriptions. FRL compilation alone
does not satisfy the separate 8K TODO, and the upstream-oriented kernel does
not provide Rockchip BSP userspace ABIs.
