# Source trees — reconstructing every cited tree

Reference appendix. Every `file:line` citation in maintained documentation
resolves against a recorded tree state. This map owns immutable documentation
and comparison pins plus the commands needed to reconstruct them. Moving
branches, intended package inputs, publication state, installed-runtime results,
and feature inventories belong to the linked project, package, status, or
finding owners.

Dev-box paths (`/home/yi/Code/…`) appear only as provenance. Public sources and
tracked patches reconstruct every tree unless a row explicitly says otherwise.
The root [workspace guide](../README.md#local-workspace-layout) owns current
checkout and build-directory layout.

| # | Tree | Anchors for | Immutable pin or owner |
|---|------|-------------|------------------------|
| 1 | Forward-port kernel tree | [kernel driver guide](../kernel-drivers/docs/how-the-drivers-work.md), [uAPI guide](../kernel-drivers/docs/dev-uapis.md), [forward-port guide](../kernel-versions/docs/vendor-forward-port.md), [vendor delta](../kernel-drivers/docs/vendor-delta.md), [device-tree guide](../kernel-drivers/docs/device-tree.md) | `v6.18` + tracked driver patch 01; add DT patch 02 for DT anchors |
| 2 | Audited tree | [BSP audit](../kernel-drivers/docs/bsp-audit.md), cleanup-draft line numbers | parent of `56e403ede081` = `5614909e5803` |
| 3 | Vendor-delta comparison | [vendor delta](../kernel-drivers/docs/vendor-delta.md), [BSP 6.1/6.6 comparison](../kernel-drivers/docs/bsp-6.1-6.6-comparison.md) | tree 1 / `710e6ad12af6` vs BSP `b4ef083dc0c3`; BSP 6.6 `1ba51b059f25` |
| 4 | Userspace media trees | userspace, FFmpeg, VA-API, and Firefox source citations | table in §4 |
| 5 | GNOME Remote Desktop | capture-path anchors and historical patch replay | upstream `c14e09ef67e9` plus the pins in §5 |
| 6 | Register recipes and IEP2/VDPP identity | kernel/userspace driver docs and [IEP2 audit](../kernel-drivers/iep2/docs/rk3588-iep2-vdpp.md) | MPP HAL/vproc sources and RK3588 TRM Part 2 Rev 1.0 |
| 7 | Canonical uAPI headers | kernel uAPI docs | inside patch 01 |
| 8 | Clean-room rewrite drivers | [rewrite-driver track](../kernel-drivers/docs/rewrite-drivers.md) | dated source and package-composite snapshots in §8 |
| 9 | Upstream-style V4L2 RGA3 comparison | rewrite-driver comparison | `rk3588-rewrite-mainline@180ee72a9a80` |
| 10 | Expanded Rockchip conformance bundle | [rewrite-conformance](../kernel-drivers/tests/conformance.md) | tracked manifest and five immutable third-party pins |
| 11 | RK3588 AV1 / VSI-IOMMU comparison | [AV1 kernel note](../kernel-drivers/av1/docs/av1-rk3588.md) | `a81feb1e2971`, `839de47fcda2`, and `b4ef083dc0c3` |
| 12 | Mesa MR !43161 benchmark | [validation scorecard](../video-libraries/mesa/docs/validation.md#depth-bias-workaround-validation) | Mesa `647256dc2ae` + tracked override; equivalent local `6000414f9ea` |
| 13 | 2026-07-30 codec audit | [driver quality comparison](../kernel-drivers/docs/driver-architecture-comparison.md#12-current-mainline-and-maxline-rockchip-codec-audit-2026-07-30) | audit and prepared-fix pins in §13 |
| 14 | 2026-08-02 maxline refresh | [refresh finding](../findings/2026-08-02-rk3588-maxline-proposal-refresh.md) | dated package and linux-next pins in §14 |

---

## 1. The forward-port tree (the primary anchor tree)

Kernel-driver citations to `mpp_*.c`, `rga_*.c`, and `compat/` headers resolve
against pristine mainline `v6.18` plus the tracked patches:

```bash
git clone --branch v6.18 --depth 1 \
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.18
cd linux-6.18
git am /path/to/rock-5b-ysp/kernel-drivers/patches/rk3588-rkvenc2-01-vcodec-rga-drivers.patch
git am /path/to/rock-5b-ysp/kernel-drivers/patches/rk3588-rkvenc2-02-vcodec-rga-dt.patch
```

Driver anchors need only patch 01. Device-tree anchors need patch 02. Patch 02
applies to pristine `v6.18`, but the resulting DT compiles only with Armbian's
`media-0001` labels because vanilla 6.18 does not define `vdec0`/`vdec1`. See
the [patch catalog](../kernel-drivers/patches/README.md) and
[Armbian packaging guide](../packaging/docs/armbian-packaging.md).

The two patch origins are:

| Patch | Origin commit |
|-------|---------------|
| Driver import | `924f4232546d` |
| RK3588 device tree | `5614909e5803` |

Repository commit `23cbe21` later changed nine
`#ifdef CONFIG_PM_DEVFREQ` guards in patch 01 to the two-symbol OOT-safe guard.
Each replacement is one line, so all recorded line numbers remain stable. This
is the only deliberate source difference from `924f4232546d`.

The historical `rkvenc-fwport-6.18` line remains public at
`655d178191807`. The maintained `rk3588-video-6.18` line rebases 31 of its 32
commits with identical patch-ids; the omitted `e059aad8d68b` is an unrelated
libbpf tooling fix. The [patch catalog](../kernel-drivers/patches/README.md),
[W16](../status.md#watch-w16), [package record](../packaging/ppa/kernel-forward-port/README.md),
and status tracks 1–2 own moving source, export, publication, and validation.

For DKMS, pass
`KSRC=<reconstructed-tree>/drivers/video/rockchip` to
[`build-deb.sh`](../packaging/dkms/build-deb.sh); the script owns its current
default input.

## 2. The audited tree (bsp-audit.md line-number pin)

[BSP audit](../kernel-drivers/docs/bsp-audit.md) line numbers use the tree before
cleanup commit `56e403ede081`. Its parent is `5614909e5803`, the §1 tree
(modulo the nine same-line guard edits). The cleanup commit is the source of
the tracked `cleanup-split/` and `cleanup-draft/` archives. Reconstruct §1 to
re-derive the anchors; after applying cleanup patches, use function name and
nearby code because later line numbers drift.

## 3. The vendor-delta.md `$OURS` / `$BSP` measurement pair

| Variable | Tree | Pin |
|----------|------|-----|
| `$OURS` | §1 driver tree used for the recorded shipping comparison | `linux-6.18-rkvenc-av1-fwport@710e6ad12af6` |
| `$BSP` | `rockchip-linux/kernel` `develop-6.1`, `drivers/video/rockchip/` | `b4ef083dc0c3` |
| `$BSP66` | `rockchip-linux/kernel` `develop-6.6` | `1ba51b059f25` |

The vendor branches move. Use these hashes to reproduce the recorded count;
[vendor delta](../kernel-drivers/docs/vendor-delta.md) owns the measurements
and interpretation.

## 4. Userspace pins — libmpp, librga, FFmpeg, rockchip-vaapi, Firefox

| Component | Repository or artifact | Immutable pin | Citation owner |
|-----------|------------------------|---------------|----------------|
| libmpp v1.3.9 study | `rockchip-linux/mpp` | tag `v1.3.9`; commit was not recorded | [userspace library guide](../vendor-libraries/docs/how-the-userspace-libs-work.md) Part A |
| libmpp KMPP study | `mpp-rockchip` | `1375813cbbae5ad6861b166475dd8fb672183220` | [MPP architecture](../vendor-libraries/mpp/docs/mpp-library-architecture.md) and KMPP/Rust notes |
| libmpp AV1 design | `github.com/yisding/mpp` `ysp/main` | `3381fd2c9a0099135a94852c9434b47075458de1` | [direct AV1 design](../video-libraries/vaapi/docs/av1-direct-mpp-service-backend.md) |
| libmpp IEP2/VDPP audit | same | `ad325345` | [IEP2 audit](../kernel-drivers/iep2/docs/rk3588-iep2-vdpp.md) |
| libmpp VP9 repair / package snapshot | same | `a8b19653af1a0b23754afafd7de72919fa8d0c0c` | [VP9 ownership](../vendor-libraries/mpp/docs/mpp-library-architecture.md#vp9-presentation-event-ownership) and [artifact record](../packaging/ppa/docs/publishing.md#mpp-source-artifact-reconstruction) |
| librga 10-bit evidence | `github.com/yisding/librga` | `26a50ef`; lineage `2cffdf6f332c` → `cc39281`/mirror `32c3bf1` → `c80eea7`, `b8def3e`, `4c26ddf` | [P010/P210 note](../vendor-libraries/rga/docs/librga-p010-p210-rkrga.md) |
| librga historical study | `tsukumijima/librga-rockchip` | `2cffdf6f332c` (`v2.2.0`) | userspace library guide Part B |
| librga prebuilt study | `airockchip/librga` | `2b32edc` | [FFmpeg guide](../video-libraries/ffmpeg/README.md) |
| ffmpeg-rockchip documented build | `nyanmisaka/ffmpeg-rockchip` | `40c412daccf0` | FFmpeg guide and [implementation comparison](../video-libraries/ffmpeg/docs/implementation-comparison.md) |
| Jellyfin FFmpeg comparison | `jellyfin/jellyfin-ffmpeg` | `455bfe539220` | [8.1.2 comparison](../video-libraries/ffmpeg/docs/rockchip-812-jellyfin-comparison.md) |
| FFmpeg release comparisons | `FFmpeg/FFmpeg` | `n8.1.2@38b88335f99e`; `n8.0.3@151b17dd2400` | FFmpeg comparison docs |
| FFmpeg publication-base study | `FFmpeg/FFmpeg` | `master@ceabc9b306f5`; `release/8.0@435ae0581deb`; `release/8.1@94138f6973dd` | [rebase notes](../video-libraries/ffmpeg/docs/rebase-notes.md) §7 |
| rockchip-vaapi stable-export evidence | `github.com/yisding/rockchip-vaapi` | `70f26d950bcb` vs upstream `woodyst/rockchip-vaapi@e8c64dd` | [VA-API project](../video-libraries/vaapi/README.md) and [finding](../findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md) |
| rockchip-vaapi AV1 design | same | `docs/AV1_SUPPORT_PLAN.md` change `4d98eca2c76a007bc46523a26d39f3043d80ec52` | direct AV1 design |
| Firefox RDD package audit | Mozilla Team PPA Resolute source | `153.0+build1-0ubuntu0.26.04.1~mt1`; `.dsc` SHA-256 `5fb63a47f969bc97479bf19abecc4d8d790ad2bcb1d3e7b2adde26248d50c8ed` | [VA-API consumer scorecard](../video-libraries/vaapi/docs/validation.md#consumer-and-sandbox-conclusions) |

The libmpp v1.3.9 study hash is unknown; do not substitute the different
`1375813cbbae` tree. Librga Part B anchors were rechecked at `2cffdf6f332c`.
Moving FFmpeg heads belong to [W07](../status.md#watch-w07) and the rebase notes;
package intent belongs to the build script.

## 5. GNOME Remote Desktop base

Capture-path file/line anchors and root-level patches `0001`–`0016` use
upstream `c14e09ef67e916ae83a4eddee6a56591078e78e0` (`50.1` + 16).
Pristine tag `50.1@5ef1a2aa6bef` is lineage only: it cannot replay the complete
series because patch `0003` needs upstream `cf250ed` and patch `0009` reverts
`5230bf3`.

The historical reconnect base is
`rdp-handover-reconnect-v2@eb91daf476dc1c4ba23ccfdd8c077b8b83e84773`.
The moving release/recovery heads belong to [W10](../status.md#watch-w10);
[`build-source-packages.sh`](../packaging/ppa/build-source-packages.sh) owns
package intent; the [artifact record](../packaging/ppa/docs/publishing.md#grd-source-artifact-reconstruction)
owns exact Published-source reconstruction.

| Historical experiment | Pin | Reconstruction |
|-----------------------|-----|----------------|
| Frame-starvation diagnostics | `1c870bc82d1920edfac1e1544b61bd7c7b9a1873` | public `debug/exp1-frame-starvation` |
| Recovery source export | `2571326322c754de7608ef4afb1dff8e4d031cbd` | replay `0001`–`0015` on `c14e09e`; use the artifact record for byte-exact package recovery |
| Cached-copy readback | `b3f0e20` | [pipeline archive](../apps/gnome-remote-desktop/patches/archive/pipeline-investigation/) |
| Bounded acknowledgement resume | `7e958e6` | archived patch `0018` |
| Corrected starvation baseline | `3e4480e066d30ba44015ae1b8cb3bbb92fe6414e` | public history plus archived patch `0019` |

Unpinned `exp8`–`exp10` states are represented by the
[archive](../apps/gnome-remote-desktop/patches/archive/README.md), not by
invented hashes.

The dirty package snapshot is `a59c904c99088235eb4de31ca340747d334494f3`
plus
[`dirty20260706-worktree.patch`](../packaging/ppa/gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch).
`git apply --check` passed against a clean archive of that commit.

## 6. Where the register recipes live

The kernel drivers consume register arrays; userspace constructs codec values.
The cited recipes live in `rockchip-linux/mpp` under `mpp/hal/rkenc/` and
`mpp/hal/rkdec/`, with register-layout headers beside each HAL.

The IEP2 audit used RK3588 TRM Part 2, Revision 1.0, 2022-03-09. Extracted-text
SHA-256 identities are:

| Artifact | SHA-256 |
|----------|---------|
| TRM Part 1 | `fe16cd1e43596bf33cd94c7e50828b11102467b59fa7ccda109c789a7b0bb9af` |
| TRM Part 2 | `f92ba6cedaa774411f299606c2470f45d758eb185487c405463aed91ddac4261` |

The earlier address-map investigation did not record its revision; these hashes
pin the available artifacts without retroactively claiming they were the
copies used then.

## 7. Canonical uAPI headers (dev-uapis.md's definitions)

Patch 01 contains both documented headers:

| Header | Reconstructed path | Size in patch |
|--------|--------------------|---------------|
| MPP | `include/uapi/linux/rk-mpp.h` | +82 lines |
| RGA | `drivers/video/rockchip/rga3/include/rga.h` | +1007 lines |

`MPP_CMD_SET_ERR_REF_HACK`, `MPP_FLAGS_REG_OFFSET_ALONE`, and
`MPP_FLAGS_POLL_NON_BLOCK` are absent from patch 01. They occur in later
forward-port and rewrite trees; the [BSP comparison](../kernel-drivers/docs/bsp-6.1-6.6-comparison.md),
[uAPI guide](../kernel-drivers/docs/dev-uapis.md), and
[rewrite project](../kernel-drivers/docs/rewrite-drivers.md) own their lineage
and behavior.

## 8. Rewrite-driver tree

This section records dated trees needed to reproduce source comparisons. The
[rewrite project](../kernel-drivers/docs/rewrite-drivers.md) owns feature
history, parity claims, build/runtime evidence, and moving heads; status track 4
owns the public verdict.

| Snapshot | Pin and base | Historical relationships |
|----------|--------------|--------------------------|
| 6.18 rewrite Phase 2 hard-CCU reset ownership, 2026-08-08 | `rk3588-rewrite-6.18@e41bdb50a9ab7` on `v6.18.42@856a9b51680c` | Shadow-cluster tip `e854cacd64c21`; makes the retained participant pulse one cluster-validated reset epoch |
| Mainline rewrite Phase 2 hard-CCU reset ownership, 2026-08-08 | `rk3588-rewrite-mainline@1c91ffc853f7a` on `v7.2-rc6@075b74841bd0` | Shadow-cluster tip `130fb983eeaf3`; byte-identical MPP group-reset ownership |
| 6.18 rewrite Phase 2 shadow-cluster construction, 2026-08-08 | `rk3588-rewrite-6.18@e854cacd64c21` on `v6.18.42@856a9b51680c` | Reset-domain tip `53a7fa1acbc00`; adds read-only cluster membership/diagnostics without changing admission or recovery |
| Mainline rewrite Phase 2 shadow-cluster construction, 2026-08-08 | `rk3588-rewrite-mainline@130fb983eeaf3` on `v7.2-rc6@075b74841bd0` | Reset-domain tip `ba8e11de18a8e`; byte-identical MPP cluster construction |
| 6.18 rewrite Phase 2 reset-domain construction, 2026-08-08 | `rk3588-rewrite-6.18@53a7fa1acbc00` on `v6.18.42@856a9b51680c` | Phase 1 tip `ab69ece998642`; adds stable reset-domain identity/membership and complete single-target operations |
| Mainline rewrite Phase 2 reset-domain construction, 2026-08-08 | `rk3588-rewrite-mainline@ba8e11de18a8e` on `v7.2-rc6@075b74841bd0` | Phase 1 tip `3a0da2f33e963`; byte-identical MPP reset-domain construction |
| 6.18 rewrite, 2026-08-08 | `rk3588-rewrite-6.18@c20fc8c1cbf76` on `v6.18.42@856a9b51680c` | prior repair tip `f371868322027`; adds per-session RKVDEC dispatch serialization and RGA command-buffer publication |
| Mainline rewrite, 2026-08-08 | `rk3588-rewrite-mainline@09e39082007dd` on `v7.2-rc6@075b74841bd0` | mirrors the three earlier MPP repairs plus the same session-serialization and RGA-publication fixes |
| 6.18 rewrite, 2026-08-06 | `rk3588-rewrite-6.18@67f323aebdf39` on `v6.18.42@856a9b51680c` | pre-rebase backup `33c30ec6989e`; forward-port oracle `rk3588-video-6.18@12a7da02bea83`; pre-forward-port backup `40cf22629cf63` |
| Mainline rewrite, 2026-08-06 | `rk3588-rewrite-mainline@7a6d4cb075a67` on `v7.2-rc6@075b74841bd0` | prior backups `9e503f6b16df` and `5bae68d8381c` |
| Upstream-style RGA3 comparison | `rk3588-rewrite-mainline@180ee72a9a80` | detailed in §9 |

The two maintained Phase 2 snapshots have byte-identical tracked MPP/RGA
rewrite sources, Kconfig, ABI ledgers, and UAPI. Their exact 99 MPP + 152 RGA
manifest, 766-signal
production ownership inventory, and 306-signal KUnit-debt audit pass with zero
new or absent signals. The older 2026-08-08 rows preserve pre-cluster and
pre-refactor snapshots, while the 2026-08-06 rows remain historical pins rather
than claims about later branch heads.

The historical Debian composite trees remain reconstructible:

| Composite | Base and layering |
|-----------|-------------------|
| `rk3588-rewrite-armbian-6.18.38@8daf5e9513b8` | Armbian snapshot `2ff6303a64ce`, then the 6.18 rewrite through `563f329dd8c4` |
| `rk3588-rewrite-armbian-7.2-rc3@24f7424fb958` | `v7.2-rc3@a13c140cc289` + Armbian build checkout `5cbc1c59c` / snapshot `2657f01c9b9a`, then the mainline rewrite |

Both composites predate the later reconciliation and are package
reconstruction pins, not current validation evidence. Fetch the public
`yisding/linux-rock5b` branches and check out the hashes above. Package metadata
and build scripts own any newer intended input.

## 9. Upstream-style V4L2 RGA3 comparison tree

The comparison in rewrite-drivers §1 uses
`rk3588-rewrite-mainline@180ee72a9a80`,
`drivers/media/platform/rockchip/rga/`. The public history contains the
mainline V4L2 mem2mem driver plus local RK3588/RGA3 work, including
`rga3-hw.c` and the then-present multicore-disable logic in `rga.c`. The
rewrite project owns the measured line count and interpretation.

## 10. Expanded Rockchip conformance bundle

The tracked seed and authoritative reconstruction interface are
[`kernel-drivers/tests/conformance/`](../kernel-drivers/tests/conformance/README.md).
Its `MANIFEST.tsv` records the five third-party snapshots; its
`scripts/bootstrap-sources.sh` reconstructs them beneath the disposable bundle.

| Component | Bundle path | Pin |
|-----------|-------------|-----|
| JeffyCN GStreamer Rockchip | `sources/jeffycn-gstreamer-rockchip` | `JeffyCN/mirrors.git` `gstreamer-rockchip@dcbcd6454ef892e385b3a782600369eb6c0719db` |
| Rockchip MPP library/tests | `sources/rockchip-mpp` | `rockchip-linux/mpp.git` `develop@c2c1ee502b3a26efebcf843f7a0aeb4d172c6237` |
| Official librga/IM2D samples | `sources/airockchip-librga` | `airockchip/librga.git` `main@2b32edcb97b601b25683e2941d888c8515da6d55` |
| Linux MPP/RGA/DRM demo | `sources/mpp-linux-cpp-demo` | `WainDing/mpp_linux_cpp.git` `master@3d7cca63c4f5f0febacef0b0d0cdb36394fb5ca0` |
| Android RKMediaCodecDemo | `sources/rkmediacodec-demo` | `c-xh/RKMediaCodecDemo.git` `master@38b85b3c160bf58f2237d5f49b601c1636d484a5` |

The manifest and bootstrap script own source intent. The
[rewrite-conformance runbook](../kernel-drivers/tests/conformance.md)
owns suite composition, commands, results, and future priorities. Generated
sources, assets, logs, and comparator outputs remain external build artifacts.

## 11. RK3588 AV1 / VSI-IOMMU comparison trees

The AV1 analysis used these dated 2026-07-02 snapshots:

| Tree | Pin | Relevant source |
|------|-----|-----------------|
| 6.18 rewrite/forward-port | `rk3588-rewrite-6.18@a81feb1e2971` | MPP, Rockchip-IOMMU compatibility, RK3588 DT |
| Mainline comparison | `rk3588-rewrite-mainline@839de47fcda2` | VSI IOMMU, Hantro, RK3588 DT |
| Rockchip BSP donor | `develop-6.1@b4ef083dc0c3` | AV1 MPP, Rockchip AV1 IOMMU, RK3588s DT |

The mainline comparison contains this VSI-IOMMU sequence:

| Commit | Subject |
|--------|---------|
| `90d50734815a` | DT binding |
| `917ace84b770` | VSI IOMMU driver |
| `6ddfbec80077` | RK3588 VSI-IOMMU DT node |
| `80b0d3546ce1` | format-security repair |
| `3040784f8721` | list-iteration cleanup |

These files are not vendored here. The
[AV1 note](../kernel-drivers/av1/docs/av1-rk3588.md) owns the design conclusion.

## 12. Mesa MR !43161 benchmark tree

Reconstruct the benchmark driver behavior from public Mesa MR commit
`647256dc2ae` and the tracked override:

```bash
git clone https://gitlab.freedesktop.org/mesa/mesa.git mesa-mr43161-bench
cd mesa-mr43161-bench
git checkout 647256dc2ae
git apply /path/to/rock-5b-ysp/video-libraries/mesa/patches/mr43161-benchmark-override.patch
```

The external local snapshot `benchmark/mr43161-all-blits@6000414f9ea` contains
the same driver source. The
[reproducer runbook](../video-libraries/mesa/reproducers/README.md) owns build
and execution; raw logs remain external.

## 13. Current mainline media and maxline codec audit trees

The 2026-07-30 codec audit used these immutable pins:

| Ref | Pin | Role |
|-----|-----|------|
| Torvalds mainline | `3708dd9488440e35a165aee2bb2a1a7b1d0d5777` | audit base |
| Prepared mainline fixes | `c28b6586f74f7fb37c071174b66a445cf4ce0884` | seven RKVDEC/Hantro corrections |
| Media next | `a52e6f7923c17a672135b485ffd96fbd72f46267` | integration cross-check |
| Maxline public | `f12fb0acf7bb923c5958e9430edd0dae93400951` | public RK3588 integration |
| Maxline WIP | `74b24e96da6245ef951ec34de481b7b8a2b91d34` | WIP including VDPU381 VP9 |
| VP9 donor | `6f0159ae61a89d4e4eee2e4f0170c351bf7543fa` | VDPU381 VP9 change |

Reconstruct the public audit tree:

```bash
git clone git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git linux
cd linux
git remote add linux-rock5b https://github.com/yisding/linux-rock5b.git
git fetch linux-rock5b rk3588-maxline-public rk3588-maxline-wip
git fetch https://git.linuxtv.org/media.git next:refs/remotes/media/next
git worktree add ../linux-maxline f12fb0acf7bb923c5958e9430edd0dae93400951
```

Reconstruct prepared mainline corrections by checking out
`3708dd9488440e35a165aee2bb2a1a7b1d0d5777` and applying
`kernel-drivers/patches/mainline-codec-fixes/0*.patch`.

The VSI-IOMMU correction series uses subsystem base
`iommu/next@b4f6d7b19f3ae` and result `1240a1c2c6894`:

```bash
git remote add iommu git://git.kernel.org/pub/scm/linux/kernel/git/iommu/linux.git
git fetch iommu next
git worktree add ../linux-iommu-vsi-fixes b4f6d7b19f3ae
git -C ../linux-iommu-vsi-fixes am \
  /path/to/rock-5b-ysp/kernel-drivers/patches/iommu-vsi-probe-fixes/000[123]-*.patch
```

`drivers/iommu/vsi-iommu.c` was byte-identical between
`3708dd9488440` and `b4f6d7b19f3ae` when prepared. Recheck before rebasing.
The driver-quality document owns findings and line-level interpretation.

## 14. 2026-08-02 maxline refresh trees

The dated refresh captured:

| Ref | Pin | Role |
|-----|-----|------|
| Torvalds base | `075b74841bd0065a3bda3440873c747938e69b68` | Linux 7.2-rc6 |
| `next-20260731` | `415606a7be939835db9b0d6b711887586646346d` | linux-next base |
| Maxline public | `e6951bc3f935427a24140421f780113a64b8a54c` | packaged public source |
| Maxline WIP | `73d29539f7bba7d5865680d35a291ed48bb19cd5` | packaged FRL WIP source |
| Public on linux-next | `0cae4ac6682384151b7c94c5db7f614775e0eee6` | validation replay |
| WIP on linux-next | `15a5179dc3b2318e6c56d300e2f4c74ef0a3fb7b` | validation replay |

The [public-series manifest](../kernel-versions/maxline/public-series.tsv)
owns proposal identities and mailbox hashes. The refresh finding owns conflict
and acceptance results.

To reconstruct package profiles without external branches, archive the
manifest's exact Linus base and apply `patches/maxline-public.patch`, followed
by `patches/maxline-wip.patch` for WIP. Use the exact published hashes above
for the linux-next comparison; those refs are validation snapshots, not package
inputs.
