# kernel-forward-port/ - PPA kernel source package

This directory owns the source-package path for the co-installable ROCK 5B
forward-port kernel.

**Published, installed, and booted (checked 2026-08-11):**
`6.18.43+rk3588av1fwport20260808-0ubuntu1~rk1` — the complete
`0001`–`0096` production forward-port tip `7698e7018e3d5`. The dedicated PPA
lane applied all 96 patches after Armbian build input `7b923c78b50d` selected
Linux 6.18.43, retained source stamp `7698e7018e3d`, matched the maintained
forward-port IOMMU implementation, and contained zero `*-rewrite` paths.

The generated `.dsc` passed `dscverify --nosigcheck` and extracted cleanly.
The extracted source reports Linux 6.18.43; all 19 files changed by patches
`0095`–`0096` are byte-identical to `7698e7018e3d5`; and the packaged config
keeps `CONFIG_ROCKCHIP_MPP_SERVICE=y` and `CONFIG_ROCKCHIP_MULTI_RGA=y` while
leaving the rewrite drivers, KASAN, KCSAN, `PROVE_LOCKING`, and
`DMABUF_DEBUG` off. Direct GPG verification reports good signatures on the
`.dsc`, `.buildinfo`, and source `.changes` from
`0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`. Final signed-artifact SHA-256
values are:

- orig: `ec9c79ba6fdedd926c2d47916ca01a8cd0b919ceb578e4060990fdfa43b68e2e`;
- Debian tar: `5b5227f53c4d878d8408bf33e066ee69ec80c52589fc86fb77ec20eb68e3fd5c`;
- `.dsc`: `b041513da6405c5a753faff8914ba4ea9058fffaffacd2ca81f2296c326a00e4`;
- `.buildinfo`: `88dfb9cd50dcb73b82292c7f46f676a8977bf0c2591a4f74dc12b6e86241f6b5`;
- source `.changes`: `ca33abfc6d1dce4658fa69eea8f2b1927143cf464f47becc5044737a346b4173`.

`dput` passed its suite, field, checksum, and GPG gates and transferred all
five source artifacts to `ppa:yi-ding/ubuntu-rock-5b` at 17:45 PDT, writing
`linux-rockchip64-ysp_6.18.43+rk3588av1fwport20260808-0ubuntu1~rk1_source.ppa.upload`
(SHA-256
`5675dc61aa1eb5f04407558b842b85fceded3dde984c6ec7d997a92a6a4d29ba`).
Launchpad later published exact source publication
[`18663042`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18663042),
arm64 build
[`33479597`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33479597)
completed successfully, and image/DTB/headers binary publications
`247936301`, `247936299`, and `247936300` are all Published. The board's
installed image, DTB, and headers match this exact version, and `/boot/Image`
and `/boot/dtb` select the corresponding `6.18.43-ysp-rockchip64` artifacts.

The 2026-08-11 production run passed system and matrix identity, ABI replay,
all 12 MPP cases, and 30/31 required librga cases. Gray256 alone failed before
hardware start: a high physically contiguous USERPTR was misclassified as raw
direct-address memory and excluded RGA2 before patch `0093`'s transient remap.
Source patch `0097` at `e7ff978398825` fixes all three admission/MMU/address
decisions and passes strict checkpatch plus a complete production-config RGA
`W=1 WERROR=1` build; it is not packaged or booted. See the
[`0097` finding](../../../findings/2026-08-11-forward-port-rga2-contiguous-userptr-rejection.md).

**Previous Published 2026-08-07 candidate:** `6.18.43+rk3588av1fwport20260807-0ubuntu1~rk1`
— the unchanged `0001`–`0092` production forward-port tip `7d53bc7a3adc`
rebased by Armbian onto Linux 6.18.43. Dedicated-lane patch-only staging
matched the production tree's IOMMU implementation and found zero
`*-rewrite` paths. A fresh `.dsc` extraction reports Linux 6.18.43, carries
the exact production config, enables RKVENC2, RKVDEC2, and IEP2, and leaves
KASAN, lockdep, and `DMABUF_DEBUG` off. `dscverify --nosigcheck` validates all
payload checksums, and direct GPG checks validate the `.dsc`, `.buildinfo`,
and source `.changes` signatures from `0FDDE6BC…AA2228E6`.

`dput` completed at 11:19 PDT and wrote
`linux-rockchip64-ysp_6.18.43+rk3588av1fwport20260807-0ubuntu1~rk1_source.ppa.upload`.
Launchpad Published source publication at 11:50 PDT
[`18661703`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18661703)
and arm64 build
[`33477272`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33477272),
which completed successfully at 12:08 PDT. Launchpad Published all three arm64
binaries — `linux-image-ysp-rockchip64`, `linux-dtb-ysp-rockchip64`, and
`linux-headers-ysp-rockchip64` — at 12:33 PDT, so this exact version is now the
normal PPA's install candidate. It is now installed and booted with the
matching YSP DTB. The 2026-08-08 production run passed identity, ABI, and MPP,
then stopped at three RGA2-only large-USERPTR librga failures. Successor source
patch `0093` fixes driver-owned USERPTR segment sizing, while `0095` supersedes
`0094` with all-high alias-safe DMA32 staging and RGA ownership repairs;
`0096` closes MPP/provider ownership and disables hard-CCU selection. The
`0093`–`0096` tail is in the Published, installed, and booted `20260808`
successor described above. Its old oversized-SG signature is absent and 30/31
required librga cases pass; the remaining high-contiguous-USERPTR admission
gap is fixed by unpublished source patch `0097`. See the
[USERPTR finding](../../../findings/2026-08-08-forward-port-rga2-userptr-swiotlb-segments.md)
[ownership audit finding](../../../findings/2026-08-08-forward-port-rga-mpp-ownership-audit-fixes.md),
and [0097 finding](../../../findings/2026-08-11-forward-port-rga2-contiguous-userptr-rejection.md).

**Previous 2026-08-04 upload:** `6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1`
— the `0001`–`0092` forward-port tip `7d53bc7a3adc`, adding the RGA
request-config lifetime fix, non-sleeping IOMMU fault-callback quiescence, and
RKVDEC2 soft-CCU recovery ordering. Strict checkpatch and the affected-object
arm64 `W=1` build pass; no full local kernel build was run for this upload.

The first patch-only provenance pass caught root-owned `mpp-rewrite/` and
`rga-rewrite/` build leftovers in the shared worktree and refused to stage the
package. Those two exact directories were removed and patch-only staging was
repeated; its IOMMU function comparison passes and it reports zero
`*-rewrite` paths. An independent full-tree comparison against the Published
`20260803` orig finds exactly the eight files changed by commits `0090`–`0092`,
with no added, removed, or unrelated path, and all eight byte-match public
branch tip `7d53bc7a3adc` in a fresh `.dsc` extraction. The extracted package
reports Linux 6.18.42, carries the exact production config, and has zero
rewrite-driver paths. `dscverify --nosigcheck` validates both tarballs and
direct GPG checks validate the `.dsc`, `.buildinfo`, and source `.changes`
signatures from `0FDDE6BC…AA2228E6`.

`dput` completed at 17:05 PDT and wrote
`linux-rockchip64-ysp_6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1_source.ppa.upload`.
Launchpad Published source publication
[`18656958`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18656958)
and arm64 build
[`33467257`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33467257)
on `bos03-arm64-004` completed successfully in 41m44s. The build log ends with
`Status: successful`; all three arm64 binaries are now Published, installed,
and booted. The running `6.18.42-ysp-rockchip64` image, DTB, and headers report
the exact `20260804` package version. A full production-profile campaign covers
ABI, MPP, FFmpeg, GStreamer, librga/RGA, decoder liveness/quality, IOMMU and
recovery stress, the independent VA-API matrix, bounded kernel-log scans, and
two-hour decode and encode soaks. Encode passes flat; decode completes with an
empty kernel delta but misses its strict userspace fd-span oracle at 36 versus
32 despite falling head/tail medians. See the
[production validation finding](../../../findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md).

**Previous 2026-08-03 upload:** `6.18.42+rk3588av1fwport20260803-0ubuntu1~rk1`
— the `0001`–`0089` forward-port tip `7615b69a744af`, adding the two RK3588
IEP2 deinterlacing commits to the Published `0001`–`0087` source. The Armbian
stable base moved from 6.18.41 to 6.18.42 during staging, so this cut carries
that stable delta without a repeat of the older full conformance campaign.

**`CONFIG_ROCKCHIP_MPP_IEP2` was missing from the packaged config** and is added
here. Without it the 20260802 config would have built this source with the IEP2
driver compiled out — the package would have published cleanly and simply not
had the feature.

The worktree was staged with `build-kernel.sh forward-port --patch-only`. That
run initially failed its own provenance gate: the guard treated
`rockchip_iommu_sync_fault_handler` as proof of a rewrite composite, but commit
`7615b69a744af` legitimately added that symbol to the forward-port line. The
guard now judges the symbol against the flavor tree instead of asserting which
line owns it, and passes. A concurrent `rewrite-debug` build then re-staged the
shared worktree underneath, wiping the IEP2 staging and leaving root-owned
`mpp-rewrite/` and `rga-rewrite/` directories; staging was re-run after those
were removed. Cutting an orig during that window would have repeated the
2026-07-25 contamination.

Verified on the artifacts, not just the worktree: the orig carries
`mpp_iep2.c`, `rockchip_iep2_regs.h`, the IEP2 Kconfig and `mpp_iep2.o` Makefile
wiring, `rockchip,iep-v2` plus `iommu@fdbb0800` in `rk3588-base.dtsi`, and both
`&iep`/`&iep_mmu` in `rk3588-rock-5b.dtsi`; it reports Linux 6.18.42 and
contains **zero** `*-rewrite/` paths across 101043 entries. The packaged config
has `CONFIG_ROCKCHIP_MPP_IEP2=y` with KASAN, lockdep, and `DMABUF_DEBUG` off.
`dscverify` validated both tarballs, `debsign` signed the `.dsc`,
`.buildinfo`, and source `.changes` with `0FDDE6BC…AA2228E6` (both
`gpg --verify` good), and `dput` completed at 19:32 PDT writing
`linux-rockchip64-ysp_6.18.42+rk3588av1fwport20260803-0ubuntu1~rk1_source.ppa.upload`.

**Published (checked 2026-08-04).** The Launchpad API reports the source and
all three arm64 binaries — `linux-image-ysp-rockchip64`,
`linux-dtb-ysp-rockchip64`, `linux-headers-ysp-rockchip64` — Published at this
exact version, so this is what `apt` now installs from
`ppa:yi-ding/ubuntu-rock-5b`. The package was installed and booted on the board
the same day as `6.18.42-ysp-rockchip64`, where IEP2 is confirmed working
standalone for the first time on a production (non-KASAN) kernel. Enabling IEP2
also un-masked a `rockchip-vaapi` defect that broke interlaced H.264 decode on
the then-published `ysp10` driver; `rockchip-vaapi 1.0.11+ysp12` fixes it and
restores 17/17 pinned vectors to bit-exact on this kernel
([regression finding](../../../findings/2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md)).
That is the tier-1 gate set only: full conformance, the HEVC sweep, ABI replay,
GStreamer, RGA completion, and the soaks were not run on this artifact and
remain pending. The documented SD rescue + `kernel-revert.sh` commands have
been used successfully by the operator; see the
[recovery finding](../../../findings/2026-08-04-forward-port-sd-rescue-rollback-used.md).

**Previous 2026-08-02 upload:** `6.18.41+rk3588av1fwport20260802-0ubuntu1~rk1`
— the complete `0001`–`0087` forward-port tip `5b87d46eefdcb`. It adds the
seven post-08-01 MPP/RKVENC2/RKVDEC2/RGA ioctl, lifetime, ownership, and review
repair commits to the Published `0001`–`0080` source. The worktree was staged
with `build-kernel.sh forward-port --patch-only`; the wrapper verified the
atomic-safe IOMMU setter against the forward-port tree, rejected the rewrite-only
sync helper, and found zero `*-rewrite` paths. The generated `.dsc` and both
tarballs validate, a fresh `dpkg-source -x` reports Linux 6.18.41, all 11 driver
files touched by the new tail byte-match the forward-port tip, and the packaged
config retains MPP/RGA/AV1 with `DMABUF_DEBUG`, KASAN, and lockdep disabled.
`debsign` signed the `.dsc`, `.buildinfo`, and source `.changes` with
`0FDDE6BC…AA2228E6`; direct GPG verification passed. `dput` completed at 11:44
PDT and wrote
`linux-rockchip64-ysp_6.18.41+rk3588av1fwport20260802-0ubuntu1~rk1_source.ppa.upload`.
GitHub branch `rk3588-video-6.18` was published at `5b87d46eefdcb` for this
upload. Launchpad source publication
[`18654047`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18654047)
is Published and arm64 build
[`33461848`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33461848)
succeeded; all three binaries were Published. This predecessor was superseded
by the `20260803` package before becoming the current board target.

**Previous 2026-07-29 upload:** `6.18.40+rk3588av1fwport20260729-0ubuntu1~rk1`
— **provenance repair** of the production package. The `…20260725` orig was
accidentally a rewrite-composite snapshot of the shared Armbian worktree: its
`drivers/iommu/rockchip-iommu.c` carried the rewrite branch's hardened
`rockchip_iommu_set_fault_handler()`, whose sleeping clear path panicked the
installed `~rk2` kernel from the vendor MPP job ISR on 2026-07-29 08:01
([ISR-panic finding](../../../findings/2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md),
[orig-provenance finding](../../../findings/2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md)).
The re-cut export matches the forward-port tree byte-for-byte on the
driver/IOMMU payload and drops the leftover
`drivers/video/rockchip/*-rewrite/` directories — the exporter now excludes
those paths permanently — while changing no config relative to `~rk2`
(`CONFIG_DMABUF_DEBUG` stays off). `debsign` signed the `.dsc`, `.buildinfo`,
and source `.changes` with `0FDDE6BC…AA2228E6` (`gpg --verify` good); `dput`
to `ppa:yi-ding/ubuntu-rock-5b` completed client-side and wrote
`linux-rockchip64-ysp_6.18.40+rk3588av1fwport20260729-0ubuntu1~rk1_source.ppa.upload`.
**Launchpad processing pending** — confirm source acceptance, the arm64
build, then install/boot and re-run the interrupted RDP login gate.

**Superseded 2026-07-25 upload:** `6.18.40+rk3588av1fwport20260725-0ubuntu1~rk1`
— a **production (non-debug)** source package of `rk3588-video-6.18` tail
`0001`–`0075`, rebased to Linux 6.18.40 stable commit `221fc2f4d0ed`.
It carries the hardware-verified 2026-07-25 fixes for RGA 10-bit UV plane
offsets (`0074`) and the RKVENC2 slice-FIFO terminal record (`0075`). Source
packaging used the tracked production config rather than the transient Armbian
worktree `.config`; `dpkg-source -x` plus `make olddefconfig` verified the
extracted source reports `6.18.40`, keeps `CONFIG_ROCKCHIP_MPP_SERVICE=y`,
`CONFIG_ROCKCHIP_MPP_AV1DEC=y`, and `CONFIG_VIDEO_ROCKCHIP_RGA=m`, and leaves
`CONFIG_KASAN`/`CONFIG_PROVE_LOCKING` disabled. The extracted source also
contains the `rkvenc2_push_slice_len()` terminal-slot logic and byte-literal
RGA UV-offset calculations. `debsign` signed the `.dsc`, `.buildinfo`, and
source `.changes` with `0FDDE6BC…AA2228E6`; `gpg --verify` passed; `dput` to
`ppa:yi-ding/ubuntu-rock-5b` completed client-side and wrote
`linux-rockchip64-ysp_6.18.40+rk3588av1fwport20260725-0ubuntu1~rk1_source.ppa.upload`.
**Launchpad processing pending** — confirm source publication, arm64 build,
install, boot, conformance, and rollback.

The previously uploaded candidate: `6.18.38+rk3588av1fwport20260724-0ubuntu1~rk1`
— production source of tail `0001`–`0073`, adding the RGA3 raster 10-bit
byte-stride ABI fix and the RGA2 above-4G page-table reject over the Published
`…20260723`. It was source-packaged, signed, and `dput`-uploaded client-side;
Launchpad processing was still pending when superseded locally by the 6.18.40
`…20260725` upload.

The previously published candidate: `6.18.38+rk3588av1fwport20260723-0ubuntu1~rk1`
— production build `P5618-Cb831`, contiguous series `0001`–`0071`; **Published**
with source publication
[`18639187`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18639187),
board-installed/booted, passed full conformance + root gates 2026-07-24.

The published candidate before that:

| Field | Current evidence |
|-------|------------------|
| Version | `6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1` |
| Launchpad | Source publication `18626523`; successful arm64 build `33412608`; exact image present in the live PPA index. |
| Contents | RGA session-close reference lifetime fix, early MPP procfs unlink, the preceding raw-import hardening, and the full MPP/RGA/AV1 forward port. |
| Board result | Package install and boot passed. The first conformance preflight Oopsed before a media case, so driver conformance and rollback remain unproven. |
| Superseded by | The `20260723` upload above carries the entire `0044`-onward tail (RGA ABI/10-bit/DMA fixes, the `0052`-`0058` lifetime fixes, the BSP-audit HIGH port, and the `0070`/`0071`/`0072`-era fixes), all renumbered into the contiguous `0001`–`0071` series. The intermediate local `…20260720` (0042/0043 only, build `Pf558-Cb831`) was never uploaded. |

Earlier package iterations established the packaging path: the initial build
failed because `mkimage` was absent; retry `18614559`/`33387391` added
`u-boot-tools`; recreated-main publication `18619788` copied the working
image/DTB/header set; and the 2026-07-16 replacements added the Rockchip 5.10
RGA reconciliation, RKVENC2 multi-slice fix, and raw physical-import hardening.
Their exact IDs and dated transitions remain in [Validation Status](#validation-status)
instead of being mixed into the current-state summary. The compact
[archive incident record](../history/2026-07-06-ubuntu-rock-5b-upload-log.md)
retains only the cross-package recovery decisions.

The current kernel delivery path is still the Armbian wrapper in
[`../../../kernel-drivers/scripts/build-kernel.sh`](../../../kernel-drivers/scripts/build-kernel.sh),
which produces local binary `.deb`s under the external Armbian build workspace.
Launchpad PPAs accept source uploads (`.dsc` + `*_source.changes`), not arbitrary
prebuilt binary kernel `.deb`s, so those local artifacts cannot be added to
`ppa:yi-ding/ubuntu-rock-5b` directly.

## Packaging policy

The package remains conservative and recovery-friendly:

| Field | Decision |
|-------|----------|
| Source package | `linux-rockchip64-ysp`; do not reuse Armbian's source name until the upgrade/recovery behavior is proven. |
| Binary packages | Co-installable names first: `linux-image-ysp-rockchip64`, `linux-dtb-ysp-rockchip64`, and `linux-headers-ysp-rockchip64`. A later drop-in package can replace `linux-image-current-rockchip64` after boot/revert testing. |
| Architecture | `arm64` only. |
| Kernel variant | Armbian `rockchip64-current` 6.18 worktree with the self-contained-DT RK3588 MPP/RGA/AV1/IEP2 forward port applied. The older convert-in-place combined kernel can use the same source-package shape later if needed. |
| Upload state | `20260808` source carrying `0093`–`0096`, its successful arm64 build, and all three binaries are Published, installed, and booted. Functional qualification is partial: identity/ABI/MPP and 30/31 librga cases pass, while gray256 exposes a high-contiguous-USERPTR gap. Source `0097` fixes that path but is not packaged. The broader 6.18.42 campaign remains the fully integrated hardware baseline. |

## Source Inputs

The local build wrapper currently owns these inputs: `ROCK5B_WORKSPACE`
defaults to the sibling `rock-5b` workspace, and `WORKSPACE_ROOT` defaults to
that grouped root.

| Input | Default |
|-------|---------|
| Patched Armbian kernel worktree | `KERNEL_PPA_REPO=$WORKSPACE_ROOT/build/kernel/rock5b-kernel-build/armbian-build-ppa/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64__ppa-forward-port` |
| Production kernel config | `KERNEL_PPA_CONFIG=$ROOT/packaging/ppa/kernel-forward-port/debian/config/arm64-rockchip64.config` |
| Source package name | `KERNEL_PPA_SOURCE=linux-rockchip64-ysp` |
| Upstream version | `KERNEL_PPA_UPSTREAM_VERSION=6.18.43+rk3588av1fwport20260808` |

The exporter copies the patched worktree contents, including Armbian patch
changes and untracked patch-added files, while excluding `.git`, `.config`,
build products, `.orig` backups, and `debian/`. It then overlays this directory's
`debian/` packaging and copies the tracked production config into
`debian/config/arm64-rockchip64.config`.

## Debian helper scripts

These helpers are invoked by `debian/rules`, not directly by board users. The
same source-package-local copies ship in both alpha-kernel directories so every
export is self-contained; `scripts/check-doc-consistency.py` enforces that all
three copies remain byte-identical.

| Helper | Role |
|--------|------|
| [`debian/scripts/install-kernel-packages.sh`](debian/scripts/install-kernel-packages.sh) | Stages the image/modules, DTBs, and buildable headers into their three binary-package roots. |
| [`debian/scripts/write-maintainer-scripts.sh`](debian/scripts/write-maintainer-scripts.sh) | Generates image/DTB/header maintainer scripts with Armbian-compatible `/boot`, initramfs, symlink, and header-prepare behavior. |

## Launchpad Constraints

- Build from source in the Launchpad build chroot. Do not upload the Armbian
  output `.deb`s as PPA inputs.
- Do not depend on network access during `debian/rules build`.
- Do not depend on Docker, privileged mounts, or the interactive Armbian
  `compile.sh` relaunch path inside Launchpad.
- Keep all source, generated patches, config, and Debian packaging in the source
  package or in build-dependencies available from Ubuntu/the PPA.
- Preserve Armbian-compatible boot hooks, initramfs generation, DTB placement,
  and recovery behavior before publishing a package that can supersede the stock
  Armbian kernel.

## Build Source Package

```bash
bash kernel-drivers/scripts/build-kernel.sh ppa-forward-port
# (delegates to packaging/ppa/build-source-packages.sh kernel)
```

The original source was generated on 2026-07-09, signed/uploaded on 2026-07-10
local time, then rebuilt as `~rk2` with `u-boot-tools` in Build-Depends. The
current session-lifetime source was generated, validated, signed, and uploaded
on 2026-07-17:

```text
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260717.orig.tar.gz
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1.debian.tar.xz
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1.dsc
packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1_source.changes
```

The orig tarball is large (`272M` in the first export), so the kernel target is
not part of the no-argument `build-source-packages.sh` default.

## Validation Status

Passed:

- `dpkg-buildpackage -S -sa -us -uc -d` through the helper.
- `dpkg-source -x` of the generated `.dsc`.
- `debian/rules override_dh_auto_configure` in the extracted source, proving the
  packaged config reaches `olddefconfig`.
- Full local arm64 binary build from the regenerated source package:
  - `linux-image-ysp-rockchip64_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk1_arm64.deb`
  - `linux-dtb-ysp-rockchip64_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk1_arm64.deb`
  - `linux-headers-ysp-rockchip64_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk1_arm64.deb`
- Normalized payload comparison against the matching local Armbian
  `6.18.38-current-rockchip64` debs:
  - module file list: `3574` vs `3574`, no normalized path differences;
  - DTB package file list: `390` vs `390`, no normalized path differences;
  - in-image DTB copy file list: `390` vs `390`, no normalized path differences;
  - Rockchip MPP AV1 config is enabled in both builds:
    `CONFIG_ROCKCHIP_MPP_AV1DEC=y`.
- Maintainer-script comparison against the matching local Armbian debs:
  - image scripts run the same `/etc/kernel/*.d` hook families with the YSP
    release string, update `/boot/Image`, and preserve the FAT `/boot` path;
  - DTB scripts use the same `/boot/dtb` symlink-or-move behavior with the YSP
    release string;
  - header scripts use the same prepare flow, with one intentional tolerance:
    `tools/bpf/resolve_btfids` failure is non-fatal in the YSP package.
- `debsign` signed the `.dsc`, `.buildinfo`, and `.changes` with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`.
- `dput ppa:yi-ding/ubuntu-rock-5b` completed client-side upload of the signed
  source package.
- Launchpad API/log check on 2026-07-10 23:30 PDT: source publication
  `18614540` is `Published`; arm64 build `33387353` `Failed to build` because
  `/bin/sh: 1: mkimage: not found` while generating
  `arch/arm64/boot/dts/rockchip/overlay/rockchip-fixup.scr`.
- Retry `~rk2` adds `u-boot-tools` to Build-Depends, extracts cleanly from the
  generated `.dsc`, signs successfully, and was uploaded with `dput`.
- Launchpad API check on 2026-07-10 23:49 PDT: retry source publication
  `18614559` is `Pending`; arm64 build `33387391` is `Currently building` on `bos03-arm64-047`.
- Launchpad API/public-index check on 2026-07-11 21:44 PDT: retry source
  publication `18614559` is Published, build `33387391` is `Successfully
  built`, and the image, DTB, and headers packages are public.
- Fresh-main API check on 2026-07-14 20:28 PDT: copied source publication
  `18619788` and all three copied arm64 binaries are Published in
  `ppa:yi-ding/ubuntu-rock-5b`.
- The 2026-07-16 production Armbian integration build applied the 37-patch
  forward-port series to 6.18.38, compiled and packaged image/DTB/headers/libc
  development packages successfully, and reported build identity
  `Pf618-Cb831`.
- The replacement source helper completed `dpkg-buildpackage -S -sa`, and
  `dpkg-source -x` verified every source checksum. Inspection of the extracted
  source confirmed the RGA low-voltage, config-error, sequential, shadow-page,
  IOMMU/register fixes; the RKVENC2 multi-slice terminal-error fix; AV1/VSI
  IOMMU; and the production config.
- `debsign` signed the replacement `.dsc`, `.buildinfo`, and `.changes` with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`; direct GPG verification passed.
  `dput` uploaded all five artifacts, and Launchpad accepted upload `38666840`
  as source publication
  [`18624245`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18624245).
  Arm64 build
  [`33407351`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33407351)
  was `Currently building` at 16:07 PDT.
- The physical-import hardening increased the Armbian forward-port series to
  38 patches. A Docker-backed full integration build completed image, DTB, and
  headers packages with build identity `P4825-Cb831`. The patch was present in
  the applied worktree, and `rga_mm.o` compiled successfully.
- Source version
  `6.18.38+rk3588av1fwport20260716.1-0ubuntu1~rk1` completed
  `dpkg-buildpackage -S -sa`; `dscverify --nosigcheck` and a fresh
  `dpkg-source -x` validated the source archive. Inspection of that extracted
  source confirmed the per-page linear-map check and both overflow guards.
- A cold, full arm64 binary build from the freshly extracted `.dsc` completed
  with exit code 0. Its stable local artifacts are under
  `packaging/ppa/out/artifacts/local-binaries/6.18.38+rk3588av1fwport20260716.1/`:
  - image: `960ee91fdbde134f5b2fe0aa86410d51f0b0b8c491311ef1c5ef7ca45ed2ed57`;
  - DTB: `7a6f656345067ddfee40e9f35270f4e9f203776fe01b7d1467ab33afd606e4c6`;
  - headers: `7a54115d43907d12ca4f1f31adc71bdf50c77b98c5dec3043c1cfb70249461d3`.
- `debsign` signed the hardened `.dsc`, source `.buildinfo`, and source
  `.changes` with `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`.
  Direct `gpg --verify` reported good signatures from
  `Yi Ding <yi.s.ding@gmail.com>` on all three files. `dput` passed its
  pre-upload checks and transferred all five source artifacts to the main PPA.
- Launchpad accepted the hardened upload as pending source publication
  [`18624583`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18624583)
  and started arm64 build
  [`33407863`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33407863)
  on `bos03-arm64-036`. It was `Currently building` at 22:52 PDT.
- The 2026-07-17 production integration build applied the complete 40-patch
  shipped series (41 forward-port commits minus the libbpf fix already present
  in Armbian), rebuilt `mpp_service.o` and `rga_mm.o`, and completed image,
  modules, DTBs, headers, and Debian packaging in eight minutes with build
  identity `Pbc61-C40aa`.
- Source version
  `6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1` completed
  `dpkg-buildpackage -S -sa`. `dscverify --nosigcheck` and a fresh
  `dpkg-source -x` passed. Inspection of the extracted source confirmed the
  kref-based RGA session release, early MPP service-list unlink, and defensive
  RKVENC diagnostic guard; regenerating the packaged config with
  `olddefconfig` retained `CONFIG_ROCKCHIP_MPP_AV1DEC=y` and
  `CONFIG_VIDEO_ROCKCHIP_RGA=m`.
- The `.dsc`, source `.buildinfo`, and source `.changes` carry good signatures
  from `Yi Ding <yi.s.ding@gmail.com>`. `dput` uploaded all five artifacts;
  Launchpad accepted pending source publication
  [`18626523`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18626523)
  and started arm64 build
  [`33412608`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33412608).
- Build `33412608` completed successfully in 41m45s. The live arm64 PPA index
  contains the exact `linux-image-ysp-rockchip64` version and pool artifact.
- KASAN successor run `20260718-093751-kasan-narrowed` verifies forward-port
  patch `0042`: RESET_SESSION completed and the original double-free signature
  produced zero flagged kernel lines.
- KASAN codec-matrix run `20260718-103917-kasan-mpp-suite` verifies the memory
  paths through patches `0042`/`0043`: both kernel-log scans were empty and the
  ordinary H.264/H.265 encode cases passed. This was a later Armbian debug
  build, not a rebuild of the Published PPA package.
- Corrected run `20260720-213128-kasan-mpp-suite` passed the formerly failing
  multi-instance H.265 and both 120-frame low-delay slice cases with no flagged
  kernel line. Full `20260720-213542-mpp-suite` passed all 12 selected official
  MPP cases. The FFmpeg codec matrix and corrected H.264/H.265/VP9 bit-exact
  PSNR gate also passed with empty KASAN scans.
- The 2026-07-20 production rebuild pinned Armbian to exact Linux 6.18.38
  commit `e46dc0adfe39724bcf52cea47b8f9c9aed86a394`, removed the tracked
  heavy-debug override, discarded stale Kbuild metadata with
  `CLEAN_LEVEL=make-kernel`, and built without ccache. It completed all kernel,
  BTF, module, DTB, header, and Debian-package stages in 109 minutes with
  identity `Pf558-Cb831`. Inspection confirmed both lifetime fixes,
  `CONFIG_ROCKCHIP_MPP_AV1DEC=y`, `CONFIG_VIDEO_ROCKCHIP_RGA=m`, and no KASAN,
  lockdep, DMA-API-debug, or debug-SG options.
- Unsigned source version
  `6.18.38+rk3588av1fwport20260720-0ubuntu1~rk1` completed
  `dpkg-buildpackage -S -sa -us -uc`. `dscverify --nosigcheck` and a fresh
  `dpkg-source -x` passed; the extracted source and packaged config retain both
  fixes and the same AV1/RGA production settings. This candidate has not been
  uploaded to Launchpad.

Notes:

- The PPA packages deliberately use co-installable names and release strings:
  `6.18.42-ysp-rockchip64` instead of Armbian's
  `6.18.42-current-rockchip64`.
- Binary hashes differ from the Armbian debs because the local PPA build used
  the host resolute toolchain (`gcc 15`, binutils `2.46`, pahole `1.31`), while
  the comparison Armbian deb was built with Ubuntu 24.04-era `gcc 13`,
  binutils `2.42`, and pahole `1.25`.
- Header package file lists differ by `92` paths, primarily generated
  `include/config/*` entries that follow the compiler/config probe differences.

Current open gates:

- Run exact `0092` under KASAN/lockdep through the RGA cancellation/session-close
  and decoder recovery/reset-contention gates; the production config cannot
  establish that memory-safety verdict.
- Run the targeted hostile/ownership gates for the `0076`–`0087` audit tail and
  the forced fragmented-DMA-BUF RGA2 path.
- Capture root-only debugfs counters plus authenticated RDP and physical-display
  integration. The separate clean-install/stale-package transaction remains an
  operational migration test for machines carrying incompatible archives; it
  does not gate this kernel's closed publication/install/boot milestone.
- Full `lintian` remains incomplete; earlier source and binary scans were
  stopped after several minutes with no output while traversing the kernel
  archive/payload.

Rollback is not on this list: the documented SD rescue + `kernel-revert.sh`
commands are operator-validated.

## Remaining Checklist

> **Use the canonical PPA flavor for every re-cut.**
> `build-kernel.sh ppa-forward-port` routes through the separate
> `armbian-build-ppa` Git worktree, takes a PPA-sequence lock, and stages and
> verifies the production series with `--patch-only` in the dedicated
> `…/linux-kernel-worktree/6.18__rockchip64__arm64__ppa-forward-port` lane, then
> restores that track's patch inputs and exports the exact lane. Direct
> `build-source-packages.sh kernel` calls use the same dedicated path by default
> but assume it has already been staged, so they are expert rebuilds rather than
> the ordinary entry point. The exporter rejects a kernel/package version
> mismatch before cutting an orig. The rewrite-path
> exclusion added after the 2026-07-25 incident does **not** cover shared files,
> and `rockchip-iommu.c` is exactly the shared file whose rewrite-branch tail
> [panicked the board](../../../findings/2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md).
> The staging verifier therefore still compares the incident function against
> the forward-port tree and rejects paths or shared-file symbols that the
> selected forward-port tree does not own before export.

**State as of 2026-08-11.** Exact `0001`–`0096` source
`7698e7018e3d5` is packaged as
`6.18.43+rk3588av1fwport20260808-0ubuntu1~rk1`, signed, checksum- and
extraction-verified, Published as source `18663042`, successfully built as arm64
build `33479597`, and Published as all three co-installable binaries. The image,
DTB, and headers are installed and booted as `6.18.43-ysp-rockchip64` with the
matching YSP DTB. Production conformance passes identity, ABI, MPP, and 30/31
required librga cases. Gray256 alone is rejected at policy because a high
physically contiguous USERPTR is mistaken for raw direct-address memory; the
former oversized-SG SWIOTLB signature is gone. Source `e7ff978398825` / patch
`0097` repairs that admission plus the matching MMU and address choices and is
strict-checkpatch and full-RGA `W=1 WERROR=1` verified, but not packaged or
booted. The exact 6.18.42 campaign remains the broader integrated evidence
baseline: its functional/recovery verdict is green, with the decode fd-span
oracle explicitly non-green.

1. Package, publish, install, and boot exact `0097`; repeatedly pass gray256
   plus the two historically intermittent RGA2 USERPTR samples, force
   successful-bounce and oversized high DMA-BUF alias/staging paths, confirm
   hard-CCU fallback, and then run full production conformance.
2. Build the exact current tail under KASAN/lockdep and pass the RGA
   cancellation/session-close and decoder recovery/reset-contention gates.
3. Run the `0076`–`0087` targeted hostile/ownership regression set plus the
   forced fragmented-DMA-BUF RGA2 gate.
4. Capture root-only debugfs counters and authenticated RDP/physical-display
   integration. Exercise the separate clean-install/stale-package transaction
   when a machine actually migrates from an incompatible stack; do not treat
   that operational scenario as missing publication evidence for this exact
   kernel. The documented SD recovery procedure is already usable.
