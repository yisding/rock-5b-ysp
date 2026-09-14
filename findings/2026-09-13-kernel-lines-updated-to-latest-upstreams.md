# All four ROCK 5B kernel lines updated to their latest upstreams

> Scope: forward-port, both clean-room rewrite lines, and maximum-mainline
> kernel source and packaging
> Source: Linux `v6.18.51@f6388029ea9e2`, `v7.3-rc2@df2908090cda3`, Armbian
> `build@2a53f158`, and the patchwork series pinned below
> Date: 2026-09-13
> Trust: SOURCE-INSPECTED / COMPILE-VERIFIED (maxline public) / MEASURED
> (package and Launchpad artifacts). No new boot or hardware result.

## Result

Every maintained kernel line moved to its current upstream, and each was
re-exported as a signed source package:

| Line | Was | Now | Local range | Conflicts |
| --- | --- | --- | ---: | --- |
| Forward-port | Linux 6.18.44 | Linux **6.18.51** | 97 patches, unchanged | none |
| Rewrite 6.18 | `v6.18.42` | **`v6.18.51`** | 445 commits | none |
| Rewrite mainline | `v7.2-rc6` | **`v7.3-rc2`** | 370 commits | 1 hand-resolved |
| Maxline public | `v7.2` | **`v7.3-rc2`** | 299 → 244, then 248 after the series refresh | 9 hand-resolved, 4 replayed from the rerere cache |
| Maxline WIP | public + 19 | public + 19 | 19 commits | none |

The two rewrite composites were then rebuilt on freshly generated Armbian
patch layers, and both replayed their full series onto those snapshots without
a single conflict.

The forward-port series needed no adjustment for the 6.18.44 → 6.18.51 stable
bump: Armbian's patcher applied all 97 patches to `linux-6.18.y` without a
reject, and both forward-compat hazards the
[resync guide](../kernel-drivers/docs/resyncing.md) ranks highest are still
clear at 6.18.51 — `struct iommu_dma_cookie` is byte-for-byte the 6.18.44
layout with `iovad` first, and `IOMMU_COOKIE_NONE` still exists.

## What v7.3-rc2 absorbed from maxline

55 of the 299 pinned public commits are now redundant against the released
base, so the public integration shrank to 244 before the series refresh below.
Ten complete ledger series became `upstream`:

| Series | Patches | Upstream form |
| --- | ---: | --- |
| `pci-port-reset` | 5 | merged as the `.reset_root_port()` callback (`3fc686d550f6d`, `4c99bace4f4ef`, `4d88cb82a6d9f`, `b376b3ff9cb05`) |
| `hdptx-clock-fixes` | 10 | v6 landed whole |
| `csi-dphy-2500` | 3 | landed whole |
| `vop2-multi-output` | 5 | landed, then refactored further upstream |
| `vop2-yuv-background` | 2 | landed whole |
| `rkvdec-h265-fixes` | 3 | landed whole |
| `pci-wakeirq` | 1 | `071e245ab749c` |
| `dp-altmode-race` | 1 | landed whole |
| `force-color-format` | 28 | non-i915 portion landed; the i915 tail is retained |
| `hdmi-yuv` | 14 | five reconciled commits landed |

Two maxline-specific ports became **inversions** and were deleted rather than
resolved:

- `drm/bridge: port OOB HPD to scoped Linus iterator` renamed
  `drm_for_each_bridge_in_chain()` to the `_scoped` spelling for the Linus
  base. Upstream `12f5090aaa3cc` renamed `_scoped` **back**, so the port now
  produced an undeclared identifier. Dropped; the parent commit's original
  spelling is correct again.
- `drm/display: bridge_connector: Use HDMI color format for HDMI conns` is
  byte-equivalent to upstream `9743ab2c18204`. It applied without conflicting
  and silently produced a **duplicate definition** of
  `drm_bridge_connector_color_format()`. Dropped.

Both were caught only by the full compile, not by the rebase. A rebase that
reports "no conflicts" across a release boundary is not evidence the tree
builds.

Separately, `drm_connector_funcs.atomic_create_state` reached Linus in
`6db0e11f48063`. The maxline README previously recorded that member as
linux-next-only and deliberately confined to the validation tree; that
distinction is now gone, and the Linus-based stack uses the newer API.

## Maxline series refresh

A patchwork audit of all 41 ledger series found six with newer revisions since
the 2026-08-02 pin. Five were re-integrated; the sixth is deferred.

| Series | Pinned | Now | Disposition |
| --- | --- | --- | --- |
| `dw-dp-improvements` | v8 (21) | **v11** (21) | replaced; 20 old commits dropped, 20 applied (one absorbed upstream) |
| `usbdp-cleanup` | v13 (35) | **v14** (38) | replaced; 34 old commits dropped, 37 applied. v14 adds the `usb: dwc3: rockchip` glue driver |
| `rkisp2` | v1 (5) | **v3** (5) | replaced; 4 of 5 applied, the DTS patch skipped as a strict subset of the integrated nodes |
| `samsung-csi-dcphy` | v2 (4) | **v4** (7) | replaced |
| `rk3588-crypto` | v2 (4) | **v3** (4) | replaced |
| `rocket-dvfs` | — | v1 (7) | **deferred** |

`accel/rocket: DVFS for the RK3588 NPU` is deferred because it does not apply
to any tree maxline can build: it depends on `struct rocket_device::max_cores`
and the multi-core slot rework from the unmerged `accel/rocket: RK3576 NPU
(RKNN) enablement` v12 series, which maxline does not carry and which is RK3576
enablement rather than RK3588 work. Taking DVFS would mean taking that base
first. Three loose `accel/rocket` fixes and three `crypto: rockchip` follow-up
fixes posted after their series are likewise recorded but not integrated.

The rkisp2 replacement needed two integration repairs, both in the amended
`integration: adapt rkisp2 to the refreshed v3 driver` commit: v3's Kconfig
entry stopped selecting `V4L2_ISP` although the driver still calls those
helpers, and v3 replaced the single `RKISP2_ISP_PAD_SINK_VIDEO` sink with a
`DMA_BASE`/`DMA_0..2` model plus a dedicated inline pad, so the retained
shared-media-graph join had to move to `RKISP2_ISP_PAD_SINK_VIDEO_CIF`. The
second was again found by the compile, not the merge.

`media: rkisp2: Implement inline mode` was **not** re-applied: v3 already
carries the CIF inline sink pad that patch existed to add, and replaying it
produced 14 conflicts in `rkisp2-isp.c` against code that already implements
its intent.

## Rewrite lines

Both rewrite branches kept their full local range and a byte-identical
`drivers/video/rockchip/` payload across the rebase.

The 6.18 line replayed all 445 commits onto `v6.18.51` with no conflict at
all. The mainline line replayed all 370 onto `v7.3-rc2` with exactly one:
upstream `414cb6f3ac621` ("iommu/rockchip: Drop global rk_ops in favor of
per-device ops") removed the file-scope `rk_ops` pointer that the rewrite's
`media: rockchip: harden rewrite drivers` commit also touched. The resolution
keeps upstream's removal and retains only the rewrite's forward declaration of
`rk_iommu_ops`; no remaining code references the removed global.

Prior tips are preserved at
`ysp-backup/rk3588-rewrite-6.18-before-6.18.51-20260913` and
`ysp-backup/rk3588-rewrite-mainline-before-7.3-rc2-20260913`.

## Armbian input

Armbian `build` moved from `53552811` to `2a53f158`. Its `bleedingedge` branch
now selects `KERNEL_MAJOR_MINOR=7.3` and ships an `archive/rockchip64-7.3`
patch directory, so the mainline rewrite composite uses a real 7.3 patch layer
instead of a 7.2 layer cherry-picked forward.

For [W01](../status.md#watch-w01): the `media-0001` blob **changed**
(`390c2e0bb071` → `fb1c0562fa57`); `media-0007` is unchanged
(`a2a4143ee2f8`). Both remain disabled in the forward-port and 6.18 rewrite
lanes, so neither affects those packages, and all 97 forward-port patches
still applied cleanly.

`kernel-patches-to-git` committed four Armbian patcher `*.orig` backups into
the 7.3 snapshot. They are excluded from the exported working tree but were
landing in the package orig tarball, so the composite carries an explicit
commit removing them.

## Packaging and upload

Five signed source packages, each `dscverify`-clean, extraction-checked for
its expected Linux version, and payload-compared against its exact source
commit before signing:

| Package | Version | Archive | State |
| --- | --- | --- | --- |
| `linux-rockchip64-ysp` | `6.18.51+rk3588av1fwport20260913-0ubuntu1~rk1` | `ubuntu-rock-5b` | Published; arm64 build [`33593313`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33593313) succeeded and all three binaries are Published, so it is the archive's install candidate |
| `linux-rockchip64-ysp-alpha-7.3-rc2` | `7.3.0~rc2+rk3588rewritealpha20260913-0ubuntu1` | `rock5b-kernel72rc2-rewrite` | Published; arm64 build [`33593381`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+build/33593381) succeeded, binaries Published |
| `linux-rockchip64-ysp-alpha-6.18` | `6.18.51+rk3588rewritealpha20260913-0ubuntu1` | `rock5b-kernel618-rewrite` | Published; arm64 build [`33593384`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+build/33593384) succeeded, binaries Published |
| `linux-rockchip64-ysp-maxline-public` | `7.3.0~rc2+git20260913+rk3588maxlinepublic-0ubuntu1` | `ubuntu-rock-5b-experimental` | Published; arm64 build [`33593389`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+build/33593389) succeeded, binaries Published |
| `linux-rockchip64-ysp-maxline-wip` | `7.3.0~rc2+git20260913+rk3588maxlinewip-0ubuntu1` | `ubuntu-rock-5b-experimental` | Published; arm64 build [`33593390`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+build/33593390) succeeded, binaries Published |

All five arm64 builds completed within about six hours of upload (checked
2026-09-13 17:16 PDT), turning every source-only claim in this finding's
original boundary section into a build-verified one. None is installed or
booted.

The maxline profiles had never been uploaded because the builder only emitted
binary packages. It now takes `MAXLINE_SOURCE_PACKAGE=1`. Two bugs surfaced
doing that: its default kernel path still pointed at the pre-2026-07
`~/Code/kernel/linux`, and the orig tarball has to sit beside the source
directory rather than in the artifacts directory. Both are fixed.

`kernel-patches-to-git` commits Armbian's `*.orig` patcher backups into the
snapshot — four in the 7.3 layer, six in the 6.18 one. They are excluded from
the exported working tree but were reaching the package orig tarballs, so each
composite carries an explicit commit removing them.

## Boundary

- No kernel from this pass has been installed or booted, and no KUnit,
  conformance, or hardware result belongs to any of them.
- The maxline `public` profile passes a full native arm64
  `Image modules dtbs` build: `7.3.0-rc2+`, 3,484 modules, 39,578,112-byte
  `Image`, 198,330-byte ROCK 5B DTB, with `rockchip-vdec.ko` still exporting
  `rkvdec_vdpu381_vp9_fmt_ops`. `wip` got only a focused local compile over
  the directories its tail touches, with the FRL objects genuinely built —
  but its Launchpad source-package build is a real full-tree compile, and it
  also succeeded.
- Neither rewrite composite was compiled locally, and none of the five
  packages was built locally in the sense of a full local kernel build; all
  five arm64 builds are Launchpad's, and all five succeeded.
- The maxline pinned configuration survived `olddefconfig` on 7.3-rc2 with
  every listed RK3588 feature retained, and picked up `CONFIG_V4L2_ISP=m` and
  `CONFIG_USB_DWC3_ROCKCHIP=y` from the refreshed series.
- The three defects this pass found were all invisible to `git rebase` and
  `git am`. Treat a clean replay across a release boundary as unproven until
  the affected objects compile.
