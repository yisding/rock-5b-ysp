# kernel-forward-port/ - PPA kernel source package

This directory owns the source-package path for the co-installable ROCK 5B
forward-port kernel.

**Uploaded 2026-08-03 (latest):** `6.18.42+rk3588av1fwport20260803-0ubuntu1~rk1`
— the `0001`–`0089` forward-port tip `7615b69a744af`, adding the two RK3588
IEP2 deinterlacing commits to the Published `0001`–`0087` source. The Armbian
stable base moved from 6.18.41 to 6.18.42 during staging, so this cut carries
that stable delta unexercised.

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

**Launchpad processing pending** — confirm source acceptance and the arm64
build. IEP2's runtime evidence was gathered on a KASAN/lockdep build over a
6.18.41 base, so it describes the source, not this artifact: this production
configuration on a 6.18.42 base has not been installed, booted, or
hardware-validated. Every board gate remains pending.

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
GitHub branch `rk3588-video-6.18` is published at `5b87d46eefdcb` with no
unpushed commits. Launchpad source publication
[`18654047`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18654047)
is Published and arm64 build
[`33461848`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33461848)
is currently building. Every board/runtime gate remains pending.

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
and the [historical upload log](../history/2026-07-06-ubuntu-rock-5b-upload-log.md), instead of
being mixed into the current-state summary.

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
| Kernel variant | Armbian `rockchip64-current` 6.18.38 worktree with the self-contained-DT RK3588 MPP/RGA/AV1 forward-port applied. The older convert-in-place combined kernel can use the same source-package shape later if needed. |
| Upload state | Initial arm64 build `33387353` failed on missing `mkimage`; retry `33387391` succeeded. The 5.10-reconciled build `33407351`, physical-import-hardened build `33407863`, and session-lifetime build `33412608` all succeeded. |

## Source Inputs

The local build wrapper currently owns these inputs: `ROCK5B_WORKSPACE`
defaults to the sibling `rock-5b` workspace, and `WORKSPACE_ROOT` defaults to
that grouped root.

| Input | Default |
|-------|---------|
| Patched Armbian kernel worktree | `KERNEL_PPA_REPO=$WORKSPACE_ROOT/kernel/rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64` |
| Production kernel config | `KERNEL_PPA_CONFIG=$ROOT/packaging/ppa/kernel-forward-port/debian/config/arm64-rockchip64.config` |
| Source package name | `KERNEL_PPA_SOURCE=linux-rockchip64-ysp` |
| Upstream version | `KERNEL_PPA_UPSTREAM_VERSION=6.18.41+rk3588av1fwport20260802` |

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
  `6.18.38-ysp-rockchip64` instead of Armbian's
  `6.18.38-current-rockchip64`.
- Binary hashes differ from the Armbian debs because the local PPA build used
  the host resolute toolchain (`gcc 15`, binutils `2.46`, pahole `1.31`), while
  the comparison Armbian deb was built with Ubuntu 24.04-era `gcc 13`,
  binutils `2.42`, and pahole `1.25`.
- Header package file lists differ by `92` paths, primarily generated
  `include/config/*` entries that follow the compiler/config probe differences.

Not done yet:

- Rollback and `kernel-revert.sh` recovery validation. Install and reboot of
  the 20260717 image passed; conformance did not.
- ~~Upload and Launchpad arm64 build~~ — **done.** The Published package is
  `…20260723~rk1`, carrying the full `0001`–`0071` tail; it was installed from
  the PPA, booted, and passed the full conformance set plus root gates
  2026-07-24.
- Exact-production-image repetition of the corrected MPP and FFmpeg passes.
  The isolated KASAN functional failures are resolved, but those results do not
  validate the unbooted `Pf558-Cb831` package.
- RGA completion: patches `0044`/`0045` fix the known `RGA2_GET_RESULT` and
  `RGA_IOC_REQUEST_CONFIG` contract failures and pass booted KASAN ABI replay
  (`Pb999-C4ad2`, `abi_status=0`). Direct dma-buf smoke also exposed the
  [RGA2 unmapped page-table DMA sync](../../../findings/2026-07-20-rga2-unmapped-page-table-dma-sync.md).
- The GStreamer runtime suite; its development pkg-config packages are absent
  on the current host.
- Full `lintian`; both source and binary scans were stopped after several
  minutes with no output because traversing the kernel archive/payload was
  taking too long.
- Booted-board confirmation that an invalid raw RGA physical import returns an
  errno without a warning, oops, or reboot. Do not enable the raw physical
  probes on the older `20260716` kernel.

## Remaining Checklist

> **Before any re-cut, stage the worktree.** `build-source-packages.sh` snapshots
> the *shared* Armbian kernel worktree
> (`…/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64`), which holds
> whichever flavor's series the last `build-kernel.sh` run staged there. Export
> immediately after `build-kernel.sh forward-port`, and verify
> `drivers/iommu/rockchip-iommu.c` matches the fwport tree byte-for-byte with no
> `*-rewrite` paths present. The rewrite-path exclusion added after the 2026-07-25
> incident does **not** cover shared files, and `rockchip-iommu.c` is exactly the
> shared file whose rewrite-branch tail
> [panicked the board](../../../findings/2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md).
> Checked 2026-08-02: the patch-only staging gate completed for the 87-commit
> forward-port tip before the `20260802` orig was exported.

**State as of 2026-08-02.** The latest source ships the complete `0001`–`0087`
tree at `5b87d46eefdcb`; source `18654047` is Published and arm64 build
`33461848` is currently building. The previous `0001`–`0080` source is
Published as `18652965` and arm64 build `33460058` succeeded, but it predates
the seven audit and review commits. The older `20260729` package is installed
but unbooted; none of the seven new commits has been booted or
hardware-validated.

1. Fix RGA2 page-table DMA ownership, install the GStreamer development
   stack, and finish the remaining conformance suites. (The KASAN tip rebuild
   with `0044`/`0045` is done — debug build `Pb999-C4ad2` passes booted ABI
   replay.)
2. Confirm Launchpad build `33461848` succeeds and publishes binaries, then
   install and repeat the green MPP/FFmpeg plus completed RGA/GStreamer gate on
   that exact image.
3. Validate rollback and `kernel-revert.sh` recovery on the board before giving
   install guidance. Install and reboot of the 20260717 image already pass.
