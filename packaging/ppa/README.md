# ppa/ - Launchpad source packages

This directory holds the reproducible Debian packaging for the ROCK 5B media
stack. The ABI-compatible system stack belongs in
`ppa:yi-ding/ubuntu-rock-5b`; ABI-changing FFmpeg builds and experimental
rewrite kernels use dedicated PPAs.

The PPA's implemented source packages are built by Launchpad and installed by
`apt`: the codec access rule, MPP, librga, FFmpeg with RKMPP/RKRGA, the
co-installable nyanmisaka FFmpeg 6.1 fork, GRD, and kernel source packages. The
forward-port kernel has a
tracked PPA source package under
[`kernel-forward-port/`](kernel-forward-port/README.md); its local arm64 binary
build and normalized Armbian payload comparison pass, its Launchpad source is
published, and its Launchpad arm64 build succeeded. A physical-import-hardened
replacement also passes full Armbian and exact PPA-source local binary builds;
Launchpad published it successfully. The 20260717 replacement fixes RGA and
MPP session teardown lifetime bugs, passes a full Armbian integration build,
and built successfully on Launchpad. A local 20260720 successor adds the two
KASAN-derived MPP/RKVENC lifetime fixes and passes a clean exact-6.18.38
Armbian image/module/DTB/header build plus unsigned PPA source validation; it
has not been uploaded or board-tested. The alpha clean-room
rewrite kernels have separate co-installable source packages under
[`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) and
[`kernel-rewrite-alpha-7.2-rc3/`](kernel-rewrite-alpha-7.2-rc3/README.md).
Their historical vanilla-based packages are public; the replacement packages
now layer the rewrite drivers after Armbian and pass local source and full
native arm64 binary builds. Both replacement sources and their successful
Launchpad arm64 builds are Published. These fixed July package pins predate the
maintained rewrite tips, source VPU981 AV1 backend, and current 92+152 KUnit
manifest, so their build results are historical package evidence rather than
current rewrite-source evidence. Kernel board install/revert gates are still
pending. The optional
greeter ACL package has both the existing local deb source and a native PPA
source wrapper under
[`gdm-hwenc/`](gdm-hwenc/README.md).

The sibling [`kernel-maxline/`](kernel-maxline/README.md) workstream is
different: it is a local, reproducible build/package track for public and WIP
integrations pinned to Linux `7.2-rc6`, Torvalds `master@075b74841bd0`, with matching
`next-20260731` validation branches. It has not been uploaded to a
PPA, installed, booted, or hardware-validated, so it is deliberately absent
from the live-archive table below.

The reader-facing counterpart to this page is
[`../../docs/ppa-support.md`](../../docs/ppa-support.md): what the archive and
its kernel support, what they do not, the evidence behind each claim, and the
comparison with a Rockchip BSP distribution. Give that page to someone
considering the PPA; this page is for building and publishing it.

## PPA Layout

Each incompatible FFmpeg or rewrite-kernel line has its own archive. This
avoids Launchpad's per-archive rule that a previously accepted source version
cannot later be replaced by an earlier version, even after publications are
deleted.

| PPA | Role | Live state at the check below |
|-----|------|-------------------------------|
| `ppa:yi-ding/ubuntu-rock-5b` | Normal system stack: Plymouth boot-hang fix, codec udev access, MPP, librga, FFmpeg 8.0.3 Rockchip, patched GNOME Remote Desktop, co-installable FFmpeg 6.1 tools, and the Linux 6.18 forward-port kernel. | The `0001`–`0092` / `6.18.42` kernel source is Published as publication `18656958`; remote arm64 build `33467257` completed successfully and awaits binary ingestion. Its `0089` predecessor remains the Published, installed, and booted binary. GRD replacement source `18654077`, binary `247717203`, and build `33461880` are Published/successful and installed. Other package rows below retain their exact recorded states. This is the only normal system-stack install target. |
| `ppa:yi-ding/rock5b-ffmpeg81-upstream` | Upstream FFmpeg 8.1.2 comparison baseline. | One source and 29 copied binary publications are Published. |
| `ppa:yi-ding/rock5b-ffmpeg81-rockchip` | ABI-changing FFmpeg 8.1.2 RKMPP/RKRGA forward port. Add the system PPA as well for MPP and librga. | One source and 29 copied binary publications are Published. |
| `ppa:yi-ding/rock5b-kernel618-rewrite` | Experimental Linux 6.18.38 Armbian-based clean-room rewrite kernel. | Replacement source `18623665`, successful arm64 build `33406491`, and exact binaries are Published. |
| `ppa:yi-ding/rock5b-kernel72rc2-rewrite` | Experimental Linux 7.2-rc3 Armbian-based clean-room rewrite kernel (legacy archive name). | Replacement source `18623666`, successful arm64 build `33406492`, and exact binaries are Published. |
| `ppa:yi-ding/ubuntu-rock-5b-experimental` | Isolated staging archive for the GRD reconnect candidate, plus migration backups of MPP, librga, co-installable FFmpeg 6.1, the forward-port kernel, and the superseded FFmpeg-8.1-linked GRD build. | Recovery candidate `~exp3` source `18626586`, successful arm64 build `33412698`, and its exact binary are Published. This archive depends one-way on the normal PPA's `Release/main` pocket for that build dependency; the normal PPA has no dependency on this staging archive. |

For the primary 6.18 forward-port test path, run
[`install-system-stack.sh`](install-system-stack.sh) on an arm64 Resolute
system. It adds only the system PPA and installs the codec access rule, MPP/RGA
runtime and development packages, FFmpeg, patched GNOME Remote Desktop, the
complete `pipewire-audio` desktop stack, and the co-installable YSP kernel image,
DTBs, and headers. The audio package replaces standalone PulseAudio with
`pipewire-pulse`, which is required because GRD captures native PipeWire sinks;
see the [`RDP audio diagnosis`](../../apps/gnome-remote-desktop/docs/audio-redirection.md).
Verify the boot entry and prepare the SD recovery path before rebooting. The
documented SD + `kernel-revert.sh` flow is operator-validated; full
current-package validation remains a test gate.

If the machine already has one of the earlier FFmpeg 8.1, private-FFmpeg, GRD,
or rewrite-kernel test stacks, use
[`clean-install-system-stack.sh`](clean-install-system-stack.sh) instead. It
adds the system PPA and verifies that the complete replacement set is published
before removing any incompatible PPA source. It then runs an APT simulation,
rejects any removal outside the explicit conflict list, and asks for
confirmation. Shared `libav*` packages are downgraded in place to the exact
FFmpeg 8.0.3 PPA version so unrelated desktop applications are not removed;
incompatible ABI-only and private packages are purged. Standalone `pulseaudio`
and `pulseaudio-module-bluetooth` are the only additional intentional removals;
the transaction installs Ubuntu's `pipewire-audio` replacement so desktop
applications and GRD share one native PipeWire graph. The machine's existing
Armbian kernel is retained as a recovery boot option. After installation the
script checks every exact package version, verifies `pipewire-audio`, and
invokes `/usr/bin/ffmpeg` directly to require the `h264_rkmpp` encoder, avoiding
a private executable earlier in `PATH`.

```bash
bash packaging/ppa/clean-install-system-stack.sh
```

## Current State

Last recorded comprehensively through Launchpad's devel API and exact-version
binary queries at `2026-07-19T20:13:55-07:00`, with newer per-package checks
stated in the affected rows. The step-by-step provenance is retained in the
[`history/` upload transcript](history/2026-07-06-ubuntu-rock-5b-upload-log.md):

| Package | Version in this repo | Public PPA state | Notes |
|---------|----------------------|------------------|-------|
| `plymouth` | `24.004.60+git20250831.4a3c171d-0ubuntu8.1~rk1` under [`plymouth/`](plymouth/README.md) | Source publication [`18636085`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18636085) is accepted; arm64 build [`33428910`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33428910) succeeded and all nine binary publications are accepted/Pending. | Exact Ubuntu Resolute `-0ubuntu8` source plus upstream `45655f12`, fixing the incomplete-CSI non-advancing loop that can hang `plymouthd` on serial-console input. `debdiff` contains only the changelog, one DEP-3 patch, and its series entry; source/binary lintian has no warning or error introduced by the backport. |
| `rk3588-codec-udev` | `1.1` under [`codec-udev/`](codec-udev/README.md) | Source publication [`18620729`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18620729) and arm64-hosted `Architecture: all` build [`33399688`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33399688) are Published/successful. Version 1.0 is superseded. | Installs the canonical non-root MPP/RGA/DMA-heap access rule; `1.1` retriggers real sysfs devices and verifies the resulting permissions. Local source/binary builds, lintian, package installation, and live-device permission checks pass. |
| `mpp` | `1.5.0+git20260805.a8b19653+ds-0ubuntu1~rk1` | Signed source publication [`18657949`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18657949) is accepted/Pending. Arm64 build [`33468629`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33468629) has a successful build log and is in Launchpad's `Uploading build` ingestion state. The full source export, exact orig-content checks, clean `.dsc` extraction, all three signature checks, `dscverify`, and Lintian's error gate pass. Prior source [`18650756`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18650756) and its five arm64 binaries are Published. | Fork tip `a8b19653` preserves every VP9 show-existing presentation occurrence, snapshots its metadata, and owns one buffer reference per event. One-pass sync/no-thread/multi-thread decode returns all 16 frames byte-identically; 120/120 stress decoders and 30-frame H.264/H.265/VP9/AV1 differential runs are clean. The package also advances across the intervening IEP2 cache/mode and vproc signal-frame/field fixes. Binary publication, install, and installed-runtime replay remain. |
| `librga` | `2.2.0+git20260725.26a50ef-0ubuntu1~rk1` | Source publication [`18641905`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18641905) is Published; arm64 build [`33440960`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33440960) succeeded in 6m02s, and binary publications [`247477790`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247477790) and [`247477791`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247477791) are Published. The exact packages are installed from the normal PPA. Client-side verification also passed the full local arm64 build and Lintian error gate, with SONAME unchanged at `librga.so.2`. | Extends the 10-bit `vir_w` byte-stride conversion to **TILE** (FBC stays on the pixel convention); also fixes the cmake `-DLINUX` hole and unchecked `fread()`s. **Must land with a kernel carrying the matching TILE plane-offset fix** — a mismatched pair is wrong by 20% on the 10-bit TILE path. Note the upstream date is `20260725` (commit is 2026-07-25 UTC): a same-date bump to a digit-leading hash sorts *below* `b8def3e` under dpkg comparison. |
| `ffmpeg` | `7:8.0.3+rockchip+git20260730.c9428bedaa-0ubuntu1~rk1` | The successor source package builds and validates locally; publication and arm64 binary build are pending. Predecessor source [`18647960`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18647960), build [`33450629`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33450629), and all 29 binaries [`247606934`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247606934)–[`247606962`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247606962) remain Published. | Retains bounded RKMPP backpressure and the HEVC unused-following-reference fix, then fixes asynchronous input-frame ownership across encoder reset/close. Focused hardware gates pass 10/10 immediate-close and 10/10 flush/reuse iterations without the old libmpp refcount/pool diagnostics. The predecessor remains installed; package installation and repeated GRD fallback/recreation are pending. |
| `rockchip-vaapi` | `1.0.11+ysp12-0ubuntu1~rk1` | Uploaded 2026-08-04 from release commit `184d7d4`, which is public on `yisding/rockchip-vaapi main`. Source publication [`18656370`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18656370) accepted; arm64 build [`33465947`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33465947) succeeded in 4m20s, with binaries pending the publisher at the last check. Client-side gates: a fresh `dpkg-source -x` matches all 661 tracked files of the release commit byte-for-byte, `dscverify` passes against the personal key ring, and source Lintian is clean. Predecessor `ysp10` source `18654839` and its binaries remain Published. | Disables MPP's decoder-internal deinterlacer, which kernel `6.18.42` made live by enabling IEP2 and which broke interlaced H.264 decode on `ysp10`. Verified on the board against the installed package: **17/17 pinned conformance vectors bit-exact**, including the interlaced `CABREF3_Sand_D.264` through VA-API. `ysp11` carried only the 8192x8192 picture-size change and was superseded before publication. |
| `ffmpeg` 8.1.2 baseline | `7:8.1.2-1+rk2` in [`ffmpeg-baseline/`](ffmpeg-baseline/README.md) | Dedicated-PPA source publication [`18619544`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-ffmpeg81-upstream/+sourcepub/18619544) and all 29 copied binary publications are Published. | Isolated in `ppa:yi-ding/rock5b-ffmpeg81-upstream`. |
| `ffmpeg` 8.1.2 Rockchip | `7:8.1.2+rockchip81+git20260711.be367abfe6-0ubuntu1~rk1` | Dedicated-PPA source publication [`18619545`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-ffmpeg81-rockchip/+sourcepub/18619545) and all 29 copied binary publications are Published. | Isolated in `ppa:yi-ding/rock5b-ffmpeg81-rockchip`; it builds against the fresh main PPA for MPP/librga. |
| `ffmpeg-rockchip` | `6.1+git20260423.40c412dacc-0ubuntu1~rk1` under [`ffmpeg-rockchip/`](ffmpeg-rockchip/README.md) | Fresh-main source publication [`18619787`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18619787) and its arm64 tool binary are Published. | Co-installable `/opt/ffmpeg-rockchip` tools; does not replace system FFmpeg. |
| `gnome-remote-desktop` (normal stack) | `50.2+rkmpp+git20260729.15.c4ef3c9-0ubuntu1~rk2` | Replacement source publication [`18654077`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18654077), arm64 binary [`247717203`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247717203), and build [`33461880`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33461880) are Published/successful; the build finished in 5m33s. Its hosted log records `--timeout-multiplier 3`, RDP pass in 9.76s, zero failures, and the two expected TPM/hardware-EGL skips. The superseded `~rk1` source [`18649293`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18649293) is Published but build [`33452991`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33452991) failed without retained diagnostics. | Seventeen clean commits on latest GNOME 50 stable: RKMPP backend, corrected reconnect ownership/coalescing, cached GPU-copy readback, bounded encode recovery, progress-gated ACK-resume recovery, full-range BT.709 signaling, and narrowly retained persistent-user-display state after a reconnect timeout. Production source is unchanged from `~rk1`; packaging raises only Meson's test-timeout multiplier because a successful local RDP run took 21.64s to finish Mutter/PipeWire teardown after the 20s upstream limit. The test remains enabled and fatal. |
| `gnome-remote-desktop` (archived recovery build) | `50.1+rkmpp+git20260717.2571326-0ubuntu1~exp3` | Experimental source publication [`18626586`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+sourcepub/18626586), successful arm64 build [`33412698`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+build/33412698), and arm64 binary are Published. | Historical diagnostic build; superseded by the clean release candidate. |
| `gnome-remote-desktop` (archived audio probe) | `50.1+rkmpp+git20260721.11.3e4480e+audioprobe1-0ubuntu1~exp10` | Source/native arm64 builds and live format probes passed; installed, not published. | Proved the macOS client accepts A-law plus PCM and rejects the tested ADPCM tuples. Its diagnostics and temporary Opus suppression are archived, not released. |
| forward-port kernel | `6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1` under [`kernel-forward-port/`](kernel-forward-port/README.md) | Source publication [`18656958`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18656958) is Published and remote arm64 build [`33467257`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33467257) completed successfully in 41m44s; binary ingestion remains pending. The `20260803` predecessor remains Published, installed, and booted as `6.18.42-ysp-rockchip64`. | Carries complete `0001`–`0092` source at `7d53bc7a3adc`. The first provenance pass caught and refused stale rewrite build directories; after exact cleanup, patch-only staging reports zero foreign paths. Full-tree comparison against the Published orig differs in only the expected eight files, which byte-match the public tip after fresh `.dsc` extraction; signatures and archive checksums pass. No local kernel build was run for this upload. |
| sg-guard diagnostic kernel | `6.18.40+rk3588av1fwport20260725sgguard1-0ubuntu1~rk1` under [`kernel-sgguard/`](kernel-sgguard/README.md) | Source package built locally; upload to `ppa:yi-ding/ubuntu-rock-5b-experimental` pending. | **Diagnostic only — never a system kernel.** The production forward-port source plus one temporary `page_link` guard commit, built through Launchpad so its gcc 15.2 matches production and the guard is the only variable. Co-installable (own source/binary names), so it cannot replace or upgrade `linux-image-ysp-rockchip64`. Delete once the writer is identified. |
| alpha rewrite kernel 6.18 | `6.18.38+rk3588rewritealpha20260715-0ubuntu1` under [`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) | Source publication [`18623665`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+sourcepub/18623665), successful arm64 build [`33406491`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+build/33406491), and the exact binaries are Published. | Historical Armbian 6.18.38 composite; predates maintained rewrite source and has no board result. |
| alpha rewrite kernel 7.2-rc3 | `7.2.0~rc3+rk3588rewritealpha20260715-0ubuntu1` under [`kernel-rewrite-alpha-7.2-rc3/`](kernel-rewrite-alpha-7.2-rc3/README.md) | Source publication [`18623666`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+sourcepub/18623666), successful arm64 build [`33406492`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+build/33406492), and the exact binaries are Published. | Historical v7.2-rc3/Armbian composite; predates maintained rewrite source and has no board result. |
| `gnome-remote-desktop-gdm-hwenc` | `1.0` under [`gdm-hwenc/`](gdm-hwenc/README.md) | Native source wrapper imported; not uploaded. | Optional greeter ACL package. The canonical rule also feeds the local deb source under [`../gdm-hwenc/`](../gdm-hwenc/README.md). |

Install-facing state: the complete normal system stack is now published, apart
from the optional GDM greeter ACL package. The PPA kernel is installed and
booted, and its documented SD rescue + `kernel-revert.sh` path is
operator-validated. Treat it as a **narrowly validated test path, not a fully
qualified primary path**: the exact clean-migration transaction and full
current-kernel campaign remain open.

The PPA targets **resolute** (Ubuntu 26.04 / Armbian userspace) on **arm64**.
The PPA is configured with only the `arm64` processor. Architecture-independent
packages are built on arm64 and published as `Architecture: all`.

## Directory Contents

| Path | Purpose |
|------|---------|
| [`build-source-packages.sh`](build-source-packages.sh) | Exports clean upstream git snapshots, overlays the packaging in this repo, and creates unsigned source packages under `packaging/ppa/out/artifacts/` by default. |
| [`plymouth/`](plymouth/README.md) | Exact Ubuntu Resolute source download/verification plus the one-patch upstream incomplete-CSI boot-hang backport. |
| [`install-system-stack.sh`](install-system-stack.sh) | Installs the published normal stack on a clean arm64 Resolute system while retaining the existing distro kernel for recovery. |
| [`clean-install-system-stack.sh`](clean-install-system-stack.sh) | Replaces earlier incompatible test packages with exact versions from the system PPA while retaining the distro kernel as a recovery path. |
| [`mpp/debian/`](mpp/debian/changelog) | Debian packaging for Rockchip MPP from `ysp/main@a8b19653`. |
| [`librga/debian/`](librga/debian/changelog) | Debian packaging for the local `librga-fork` commit `26a50ef`, including the P010/P210 work and the 10-bit RASTER+TILE byte-stride conversion. |
| [`ffmpeg/debian/`](ffmpeg/debian/changelog) | Ubuntu/Debian FFmpeg 8.0.3 packaging for the RKMPP/RKRGA forward port, unused-following-reference fix, and asynchronous encoder-frame lifetime fix at `c9428bedaa`. |
| [`ffmpeg-rockchip/debian/`](ffmpeg-rockchip/debian/changelog) | Co-installable `/opt/ffmpeg-rockchip` packaging for nyanmisaka's FFmpeg 6.1 Rockchip fork at `40c412daccf0`. |
| [`gnome-remote-desktop/debian/`](gnome-remote-desktop/debian/changelog) | Ubuntu/Debian GRD packaging pinned to the clean release commit with `-Dffmpeg=enabled`. The normal export has no `GRD_DELTA`; that option is retained only for historical reconstruction. |
| [`gnome-remote-desktop/source-deltas/`](gnome-remote-desktop/source-deltas/README.md) | Historical tracked-file GRD deltas retained to reconstruct older dirty source-package snapshots. |
| [`codec-udev/`](codec-udev/README.md) | Native PPA source wrapper for the canonical unprivileged MPP/RGA/DMA-heap access rule. |
| [`gdm-hwenc/`](gdm-hwenc/README.md) | Native source-package wrapper for the optional GDM greeter hardware-encode ACL rule. |
| [`kernel-forward-port/`](kernel-forward-port/README.md) | Launchpad source-package track for the forward-port kernel; records source inputs, packaging shape, generated artifacts, and remaining binary/board validation gates. |
| [`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) | Launchpad source-package track for the 6.18 alpha clean-room rewrite kernel. |
| [`kernel-rewrite-alpha-7.2-rc3/`](kernel-rewrite-alpha-7.2-rc3/README.md) | Launchpad source-package track for the Armbian-based 7.2-rc3 alpha clean-room rewrite kernel. |
| [`kernel-rewrite-alpha-7.2-rc5/`](kernel-rewrite-alpha-7.2-rc5/README.md) | Deferred Armbian-based 7.2-rc5 alpha package definition; it needs a maintained-tip rebase and validation before it can supersede the rc3 line, which keeps the last Published binaries. |
| [`kernel-maxline/`](kernel-maxline/README.md) | Local reproducible build/package track for the 2026-08-02 maximum-mainline `public` and FRL-only `wip` integrations; Linus/public passes its refreshed full compile gate, while the linux-next/WIP full build was stopped by request after focused and partial-build checks passed. Refreshed packaging and board boot gates remain open. |
| [`history/`](history/README.md) | Dated build, lintian, signing, upload, Launchpad, and retry transcripts retained as provenance rather than current-state guidance. |

Generated `.dsc`, `.changes`, `.buildinfo`, orig tarballs, `.deb`, `.ddeb`, and
build directories are intentionally not committed. The script writes them under
`packaging/ppa/out/` by default; that directory is ignored. Set `OUT=` to use a
different output root.

## Source Inputs

The helper derives `ROCK5B_WORKSPACE` from the sibling `rock-5b` directory and
defaults its packaging-specific `WORKSPACE_ROOT` to that grouped root. Override
`ROCK5B_WORKSPACE` for the whole layout, `WORKSPACE_ROOT` for packaging alone,
or individual paths/pins with the matching environment variables.

| Source | Default variable | Default value |
|--------|------------------|---------------|
| Grouped board workspace | `ROCK5B_WORKSPACE` | Sibling `rock-5b` directory |
| Packaging source workspace | `WORKSPACE_ROOT` | `$ROCK5B_WORKSPACE` |
| MPP repo | `MPP_REPO` | `$WORKSPACE_ROOT/rockchip-userspace/mpp-rockchip` |
| MPP commit | `MPP_COMMIT` | `a8b19653` |
| librga repo | `LIBRGA_REPO` | `$WORKSPACE_ROOT/rockchip-userspace/librga-fork` |
| librga commit | `LIBRGA_COMMIT` | `26a50ef` (must match the shipped kernel's 10-bit stride convention) |
| FFmpeg repo | `FFMPEG_REPO` | `$WORKSPACE_ROOT/ffmpeg/ffmpeg-rockchip-81` |
| FFmpeg commit | `FFMPEG_COMMIT` | `c9428bedaa45448d79c629f6be83a41257ac6167` |
| nyanmisaka FFmpeg Rockchip repo | `FFMPEG_ROCKCHIP_REPO` | `$WORKSPACE_ROOT/ffmpeg/ffmpeg-rockchip` |
| nyanmisaka FFmpeg Rockchip commit | `FFMPEG_ROCKCHIP_COMMIT` | `40c412daccf08164493da0de990eb99a8948116b` |
| GRD repo | `GRD_REPO` | `$WORKSPACE_ROOT/gnome/grd/gnome-remote-desktop` |
| GRD snapshot commit | `GRD_COMMIT` | `c4ef3c96194038e737be0857519ff77227279292` (`release/50.2-rkmpp`; 17 release commits on latest GNOME 50 stable commit `18cc5f7`) |
| GRD source delta | `GRD_DELTA` | Empty for release. Override only to reconstruct a historical snapshot such as [`dirty20260706-worktree.patch`](gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch). |
| Forward-port kernel worktree | `KERNEL_PPA_REPO` | `$WORKSPACE_ROOT/build/kernel/rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64` |
| Forward-port kernel config | `KERNEL_PPA_CONFIG` | [`kernel-forward-port/debian/config/arm64-rockchip64.config`](kernel-forward-port/debian/config/arm64-rockchip64.config) |
| Forward-port kernel source version | `KERNEL_PPA_UPSTREAM_VERSION` | `6.18.42+rk3588av1fwport20260804` |
| Alpha rewrite 6.18 kernel repository | `KERNEL_ALPHA_618_REPO` | `$WORKSPACE_ROOT/kernel/linux-6.18-rkvenc` |
| Alpha rewrite 6.18 kernel commit | `KERNEL_ALPHA_618_COMMIT` | `8daf5e9513b8aa9de018dad7754b6efacfd0fd49` |
| Alpha rewrite 6.18 kernel config | fixed package input | [`kernel-rewrite-alpha-6.18/debian/config/arm64-rockchip64.config`](kernel-rewrite-alpha-6.18/debian/config/arm64-rockchip64.config) |
| Alpha rewrite 6.18 kernel source version | `KERNEL_ALPHA_618_UPSTREAM_VERSION` | `6.18.38+rk3588rewritealpha20260715` |
| Alpha rewrite 7.2-rc3 kernel repository | `KERNEL_ALPHA_72RC3_REPO` | `$WORKSPACE_ROOT/kernel/linux` |
| Alpha rewrite 7.2-rc3 kernel commit | `KERNEL_ALPHA_72RC3_COMMIT` | `24f7424fb9589ea2118127084a5f2748aa762b63` |
| Alpha rewrite 7.2-rc3 kernel config | fixed package input | [`kernel-rewrite-alpha-7.2-rc3/debian/config/arm64-rockchip64.config`](kernel-rewrite-alpha-7.2-rc3/debian/config/arm64-rockchip64.config) |
| Alpha rewrite 7.2-rc3 kernel source version | `KERNEL_ALPHA_72RC3_UPSTREAM_VERSION` | `7.2.0~rc3+rk3588rewritealpha20260715` |
| GDM greeter ACL rule | `GDM_HWENC_RULE` | [`../gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules`](../gdm-hwenc/root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules) |
| Codec access rule | `CODEC_UDEV_RULE` | [`../../kernel-drivers/scripts/99-rockchip-codec.rules`](../../kernel-drivers/scripts/99-rockchip-codec.rules) |

Version strings can also be overridden with `MPP_UPSTREAM_VERSION`,
`LIBRGA_UPSTREAM_VERSION`, `FFMPEG_UPSTREAM_VERSION`,
`FFMPEG_ROCKCHIP_UPSTREAM_VERSION`, and `GRD_UPSTREAM_VERSION`. The kernel
source name can be overridden with `KERNEL_PPA_SOURCE`, though
`linux-rockchip64-ysp` is the current forward-port package name. The codec
access source/version can be overridden with `CODEC_UDEV_SOURCE` and
`CODEC_UDEV_VERSION`. The alpha
kernel source names can be overridden with `KERNEL_ALPHA_618_SOURCE` and
`KERNEL_ALPHA_72RC3_SOURCE`. The native greeter ACL source package name/version
can be overridden with `GDM_HWENC_SOURCE` and `GDM_HWENC_VERSION`.

## Build Source Packages

Build the default userspace dependency chain:

```bash
bash packaging/ppa/build-source-packages.sh
```

Build a subset:

```bash
bash packaging/ppa/build-source-packages.sh mpp librga
bash packaging/ppa/build-source-packages.sh ffmpeg
bash packaging/ppa/build-source-packages.sh ffmpeg-rockchip
bash packaging/ppa/build-source-packages.sh gnome-remote-desktop
bash packaging/ppa/build-source-packages.sh grd
bash packaging/ppa/build-source-packages.sh plymouth
bash packaging/ppa/build-source-packages.sh gdm-hwenc
bash packaging/ppa/build-source-packages.sh kernel
bash packaging/ppa/build-source-packages.sh kernel-alpha-6.18
bash packaging/ppa/build-source-packages.sh kernel-alpha-7.2-rc3
```

The kernel target exports the patched Armbian kernel worktree rather than using
`git archive`, because Armbian applies its patch stack into a dirty worktree.
It is intentionally not part of the no-argument default set because the orig
tarball is large.

Use a different output directory or source checkout:

```bash
OUT=/path/to/rock5b-ppa \
MPP_REPO=/path/to/mpp-rockchip \
LIBRGA_REPO=/path/to/librga-fork \
FFMPEG_REPO=/path/to/ffmpeg-rockchip-81 \
FFMPEG_ROCKCHIP_REPO=/path/to/ffmpeg-rockchip \
GRD_REPO=/path/to/gnome-remote-desktop \
bash packaging/ppa/build-source-packages.sh
```

For the forward-port kernel:

```bash
KERNEL_PPA_REPO=/path/to/armbian/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64 \
bash packaging/ppa/build-source-packages.sh kernel
```

For the alpha rewrite kernels:

```bash
KERNEL_ALPHA_618_REPO=/path/to/6.18.38-armbian-rewrite \
KERNEL_ALPHA_72RC3_REPO=/path/to/7.2-rc3-armbian-rewrite \
bash packaging/ppa/build-source-packages.sh kernel-alpha-6.18 kernel-alpha-7.2-rc3
```

The script reuses an existing orig tarball from the artifact directory unless
`FORCE_ORIG=1` is set. That is required for Launchpad: every Debian revision
for the same upstream version must reference byte-identical orig tarball
contents. Before reuse, the helper extracts the existing orig tarball and checks
that its contents match the freshly exported source tree; stale orig tarballs
fail loudly instead of silently changing the source-package delta.

The GRD exporter archives the clean pinned `GRD_COMMIT` and creates the orig
tarball without a source delta. The current source is the public 50.2 release
branch; the older 16-patch replay on `c14e09e` remains documented for lineage.
Diagnostic patches live under the patch archive and are not considered package
inputs. Override `GRD_REPO`,
`GRD_COMMIT`, `GRD_UPSTREAM_VERSION`, and `GRD_DELTA` together only when
reconstructing a historical source state.

The `gdm-hwenc` target is a native source package. It copies the canonical udev
rule from [`../gdm-hwenc/`](../gdm-hwenc/README.md) into the generated source
tree and does not create an orig tarball.

### Reproducing the FFmpeg 8.1 packages

The current `ffmpeg` helper target intentionally builds the normal system
FFmpeg 8.0.3 package. The upstream 8.1.2 comparison packaging is preserved in
[`ffmpeg-baseline/`](ffmpeg-baseline/README.md), which documents the exact orig
tarball hash and manual source-package rebuild.

The exact Debian packaging and helper pins used for the published Rockchip 8.1
source are preserved at this repository's commit `8522426`. That snapshot pins
FFmpeg source commit `be367abfe67045b9c68812ecee3b6162c92f9776`, version
`7:8.1.2+rockchip81+git20260711.be367abfe6-0ubuntu1~rk1`, and the ABI-63/61
binary package names. Rebuild it from a detached worktree so the current
FFmpeg-8.0 packaging is not replaced:

```bash
git worktree add --detach /tmp/rock-5b-ysp-ffmpeg81 8522426
FFMPEG_REPO=/path/to/ffmpeg-rockchip-81 \
OUT=/path/to/ffmpeg81-source-output \
bash /tmp/rock-5b-ysp-ffmpeg81/packaging/ppa/build-source-packages.sh ffmpeg
git worktree remove /tmp/rock-5b-ysp-ffmpeg81
```

Reuse the accepted orig tarball when preparing a Debian-revision retry; the
historical helper predates the current automatic source-tree/orig comparison.

## Upload Order

Respect the build-dependency chain:

```text
Wave A  plymouth, rk3588-codec-udev, mpp, librga
          wait for librockchip-mpp-dev and librga-dev to publish on arm64
Wave B  ffmpeg 8.0.3 Rockchip system package
          wait for libavcodec-dev/libavutil-dev/etc. to publish
Wave B' ffmpeg-rockchip
          optional co-installable tool package; can build once MPP/librga
          development packages are published because it does not replace
          system ffmpeg/libav* packages
Wave C  gnome-remote-desktop
Wave D  gnome-remote-desktop-gdm-hwenc (optional greeter ACL)
Wave K  forward-port kernel and alpha rewrite kernels. The current forward-port
        package is Published/booted with operator-validated SD recovery; the
        alpha rewrite packages still require board install/revert validation.
```

Keep ABI-changing FFmpeg 8.1 sources out of the normal system PPA. Future
Rockchip-81 builds belong in `rock5b-ffmpeg81-rockchip`, with the normal system
PPA configured as a build dependency for MPP/librga headers. Launchpad does not
automatically retry builds that fail before dependencies exist. The upstream
8.1 comparison source belongs in `rock5b-ffmpeg81-upstream`.

Signing and upload are deliberately outside the helper:

```bash
debsign -k <fingerprint> packaging/ppa/out/artifacts/*_source.changes
dput ppa:yi-ding/ubuntu-rock-5b packaging/ppa/out/artifacts/<system-package>_source.changes
dput ppa:yi-ding/rock5b-ffmpeg81-upstream packaging/ppa/out/artifacts/<ffmpeg-8.1-upstream>_source.changes
dput ppa:yi-ding/rock5b-ffmpeg81-rockchip packaging/ppa/out/artifacts/<ffmpeg-8.1-rockchip>_source.changes
dput ppa:yi-ding/rock5b-kernel618-rewrite packaging/ppa/out/artifacts/<kernel-6.18-rewrite>_source.changes
dput ppa:yi-ding/rock5b-kernel72rc2-rewrite packaging/ppa/out/artifacts/<kernel-7.2-rc3-rewrite>_source.changes
```

Use the exact files from the artifact directory; the upload log records the
fingerprint and package-specific retry history from the 2026-07-06 run.

## Package Notes

### Plymouth

The Plymouth helper pins and verifies Ubuntu Resolute's exact
`24.004.60+git20250831.4a3c171d-0ubuntu8` source files, then adds only upstream
commit `45655f12` and a PPA changelog entry. Ubuntu Resolute, Stonking, Noble
updates/proposed, Debian sid, and the current Ubuntu packaging branches all
still contain the vulnerable `continue`; Launchpad showed no pending Ubuntu
Plymouth upload when the backport was prepared.

The package-level regression surface is one control-flow statement in
`libply-splash-core`. The native arm64 build completes with the required system
`pkg-config`; the binary lintian run is clean, and source lintian reports only
pre-existing informational/pedantic Ubuntu-source tags.

The signed `~rk1` source is accepted as publication `18636085`. Launchpad arm64
build `33428910` completed successfully, and all nine resulting binaries were
accepted on 2026-07-23. They were still `Pending` the PPA publisher at the last
check, so the public `Packages.gz` index did not yet advertise the version.

### Codec device access

`rk3588-codec-udev` installs the canonical rule for `/dev/mpp_service`,
`/dev/rga`, and `/dev/dma_heap/*`. It grants the `video` group and active local
seat access and reloads/retriggers udev at installation time. This is required
for unprivileged RKMPP allocation; access to the codec node alone is not enough
when DMA-heap access is denied.

### MPP

The MPP package is based on `ysp/main@a8b19653`, eleven commits past
`mpp-rockchip` tag `1.0.12` / commit `1375813c`. The source is repacked as
`+ds` because unused upstream Windows binaries are removed before orig tarball
creation. The runtime packages are:

- `librockchip-mpp1`
- `librockchip-vpu1`
- `librockchip-vpu0` transitional package
- `rockchip-mpp-demos`
- `librockchip-mpp-dev`

The source delta lives as reviewable commits on the fork branch; there is no
packaging-local quilt series. The packaging keeps unversioned linker symlinks
in `-dev` and lists the upstream static archive in `debian/not-installed`
rather than shipping it.

### librga

The librga package is based on the local `librga-fork` commit `26a50ef`, carrying
the P010/P210 request-generation support (added back at `a632217`) plus the
10-bit `vir_w` byte-stride conversion that must pair with kernel `0072`/`0074`,
recorded under
[`../../vendor-libraries/rga/`](../../vendor-libraries/rga/README.md). It builds:

- `librga2`
- `librga-dev`

The upstream project reports Meson version `2.1.0`, while the package version is
`2.2.0+git20260703.a632217-*`; the built shared library keeps SONAME
`librga.so.2`.

### FFmpeg

The FFmpeg package uses the full Ubuntu/Debian packaging surface, not the smaller
local `/opt` package under [`../ffmpeg-rockchip81/`](../ffmpeg-rockchip81/README.md).
The system package is based on the official FFmpeg `n8.0.3` tag plus the
RKMPP/RKRGA forward-port and hardening series. The current packaging pin is
`fix/rkmpp-output-timeout@c9428bedaa`, based on the `rockchip-8.0` line. It
enables:

- `--enable-rkmpp`
- `--enable-rkrga`
- `--enable-libdrm`
- `--enable-version3`

This source retains Ubuntu Resolute's FFmpeg 8.0 ABI family: `libavcodec62`,
`libavutil60`, `libavformat62`, `libavfilter11`, `libavdevice62`,
`libswscale9`, and `libswresample6`. It therefore replaces Ubuntu's native
FFmpeg stack without introducing the FFmpeg 8.1 SONAME transition.

Getting the original FFmpeg 8.1 forward port to build as a full Debian package
took fixing three fork bugs, one per failed Launchpad build. A fourth runtime
fix handles AV1 container extradata. These fixes were carried into the 8.0
branch and are recorded in
[`../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md`](../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md):

1. **FATE `libavcodec-avcodec`** — the `*_rkmpp` decoders declared a static
   `pix_fmts` array while flagging `AV_CODEC_CAP_HARDWARE`, which the self-test
   forbids for video decoders. Fixed directly in source commit `8356739686`,
   which drops the unused array (output format is negotiated at runtime via
   `ff_get_format`; the DRM_PRIME hw_config players rely on is untouched).
2. **`RELEASE_NOTES`** — `debian/ffmpeg.install` installed a file the fork does
   not ship (it has `RELEASE` + `Changelog`); the line was dropped.
3. **`ffmpeg-doc` architecture** — the arm64-only correction pass had flipped it
   to `arm64`, but its doxygen HTML is built only in the arch-indep pass; set
   back to `Architecture: all` (matching the baseline).
4. **AV1 MP4/Matroska extradata** — the fork queued `av1C`/`CodecPrivate` but
   did not mark the MPP packet as extradata. Source commit `be367abfe6` calls
   `mpp_packet_set_extra_data()`, selecting MPP's configuration-record
   parser so it skips the `av1C` header and consumes the sequence-header OBU.

The FFmpeg 8.1 work that found and fixed the decoder `pix_fmts`, missing
`RELEASE_NOTES`, `ffmpeg-doc`, and AV1 extradata problems remains available in
`ppa:yi-ding/rock5b-ffmpeg81-rockchip`; the upstream comparison build is in
`ppa:yi-ding/rock5b-ffmpeg81-upstream`.

Version `7:8.0.3+rockchip+git20260713.463f542c-0ubuntu1~rk1` passed a full
local binary build, executable/media FATE tests, extracted-package smoke tests,
and RK3588 hardware tests for RKMPP encode, RKMPP decode, and the zero-copy
RKMPP-to-RGA-scale-to-RKMPP path. Source extraction and lintian also pass; the
only lintian result is the inherited newer-standards-version warning. Version
`7:8.0.3+rockchip+git20260717.540657970e-0ubuntu1~rk1` added a 500 ms bound to
synchronous low-delay and drain packet waits. Version
`7:8.0.3+rockchip+git20260719.da5befc806-0ubuntu1~rk1` then fixed the remaining
flow-control error: when MPP refuses a synchronous input because its finite task
pool is momentarily full, retry that put within the shared deadline instead of
waiting for output from a frame that was never submitted; report an elapsed
packet wait as `EAGAIN`. The changed object compiles, source lintian has warnings
only, Launchpad build `33417109` succeeded, and the exact binaries are Published.
The preceding general codec hardware coverage still applies, but the sustained
GRD workload that triggered this backpressure needs a direct board re-test.

Version `7:8.0.3+rockchip+git20260730.c9428bedaa-0ubuntu1~rk1` fixes a
separate lifetime defect in that asynchronous path. MPP owns a successfully
submitted `MppFrame` through packet return or context teardown, so FFmpeg now
keeps its imported `MppBuffer` reference separately, avoids deinitializing
submitted frames after MPP teardown, and drains reset-return packets on flush.
The affected object, `fate-source`, source construction, and source checksum
verification pass. Focused RK3588 hardware tests pass 10/10 immediate-close
and 10/10 flush/reuse iterations with no refcount, frame-pool, or kernel-fault
diagnostic. See the
[`lifetime finding`](../../findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md).
The candidate is not yet published or installed, and the real GRD
fallback/recreation gate remains open.

Private FFmpeg helper packages are a separate case: a package such as
`gnome-remote-desktop-ffmpeg-rk` that installs FFmpeg 6 libraries under
`/usr/lib/gnome-remote-desktop/ffmpeg-rk/` does not conflict with this PPA
`ffmpeg` source or its distro-style `libav*` binaries. A source package named
`ffmpeg` that produces `ffmpeg`/`libav*` binaries would not coexist; it would be
ordered by Debian version and either supersede or be superseded.

### FFmpeg Rockchip 6.1 Tool Package

The `ffmpeg-rockchip` package is based on nyanmisaka's FFmpeg Rockchip fork at
`40c412daccf0`, whose `RELEASE` is `6.1`. It is too old to be the normal
Ubuntu 26.04 system FFmpeg because resolute publishes FFmpeg 8.x and the fork
uses the older FFmpeg 6.1 ABI family (`libavcodec60`, `libavutil58`,
`libavformat60`, `libavfilter9`, `libavdevice60`, `libswscale7`,
`libswresample4`, `libpostproc57`).

To avoid collisions, the source package is named `ffmpeg-rockchip` and the
binary package installs only private command tools:

- `/opt/ffmpeg-rockchip/bin/ffmpeg`
- `/opt/ffmpeg-rockchip/bin/ffprobe`
- `/opt/ffmpeg-rockchip/bin/ffplay`
- `/usr/bin/ffmpeg-rockchip`
- `/usr/bin/ffprobe-rockchip`
- `/usr/bin/ffplay-rockchip`

It does not provide `ffmpeg`, `libavcodec-dev`, or any system `libav*` package
name, so it can be published in the same PPA without changing apt's selected
system FFmpeg. The package builds with `--disable-autodetect` and explicitly
enables only the external Rockchip path plus basic compression/SDL support:
`--enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga --enable-zlib
--enable-bzlib --enable-sdl2`.

Local validation built the source package, passed source lintian, and produced
an arm64 binary package after disabling LTO for resource use and disabling
upstream FATE tests because HLS list generation segfaulted in this fork.
Original arm64 build `33387375` succeeded on `bos03-arm64-043`; recreated-main
source publication `18619787` and the copied tool binary are Published.

### GNOME Remote Desktop

The release candidate is the clean `release/50.2-rkmpp` branch at
`c4ef3c961940`. It contains 17 reviewable commits on latest GNOME 50 stable
`18cc5f7`: the RKMPP backend and hardware enablement, reconnect/handover fixes,
the hardware-verified cached GPU-copy readback fix, bounded encode
failure/cooldown recovery, and the progress-gated RDPGFX acknowledgement-resume
recovery. The penultimate commit signals the shader's existing full-range
BT.709 conversion in the H.264 VUI; the exact experimental package corrected
the muted macOS client colors after clean activation. The tip preserves a
persistent GDM user display after a reassigned reconnect handover times out, so
its `RemoteId` listener can service the next attempt.

The 2026-07-29 audit did not restore June commit `a3a1a32` wholesale. Its
global `client_taken` state makes the routing token single-use and rejects the
legitimate second GDM-to-user connection, while its broad registered-display
test can retain greeter state. The release keeps the July ownership, socket,
timeout, and pending-only coalescing replacements, then marks only displays
explicitly reassigned during the two-leg flow as timeout-preservable. A
source-export contract in `build-source-packages.sh` rejects a default GRD pin
that loses `SetRemoteId`, any corrected ownership/coalescing invariant, or this
narrow subscription-retention path.

The investigation scaffolding is intentionally absent. There is no periodic
pipeline monitor, starvation actuator, diagnostics thread, routine ACK
suspend/resume logging, client-format dump, playback trace, Opus suppression,
or legacy-format environment probe. A warning remains only when one of the two
bounded recoveries actually fires. Audio behavior returns to GRD's normal
AAC/Opus/PCM offer.

`build-source-packages.sh` archives the release commit directly, removes
generated `*.spv` shader outputs, overlays
[`gnome-remote-desktop/debian/`](gnome-remote-desktop/debian/changelog), and
builds a `3.0 (quilt)` source package. It enables `-Dffmpeg=enabled`, restricts
the binary to `Architecture: arm64`, and uses the matching bounded-wait FFmpeg
package. The old dirty snapshot and diagnostic packages remain documented only
for historical reproduction.

The normal PPA publishes the failed `~rk1` source
[`18649293`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18649293),
whose arm64 build
[`33452991`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33452991)
retained no diagnostics. Replacement source
[`18654077`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18654077)
is Published and arm64 build
[`33461880`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33461880)
succeeded; binary publication `247717203` is Published. `~rk2` changes no
production source and keeps the RDP test fatal
while raising Meson's timeout multiplier to accommodate full teardown. Its
exact source/native arm64 builds pass locally: RDP integration is green, TPM
and hardware-EGL skip as expected, and Lintian reports only long-filename
warnings. Experimental `~exp3` remains historical evidence. The final
reconnect, sustained focus/resume, and audio gates remain after installation
of the promoted build.

### GDM Greeter Hardware Encode ACL

The `gdm-hwenc` target builds a small `3.0 (native)` source package for
`gnome-remote-desktop-gdm-hwenc`. It installs the same udev rule as the local
package under [`../gdm-hwenc/`](../gdm-hwenc/README.md), granting group `gdm`
access to the codec nodes so the pre-login greeter can hardware-encode.

This package is opt-in because it widens video-codec access to the whole `gdm`
group. It should be uploaded only after the GRD package path is otherwise ready.

## What Is Still Not In This Repo

- Full MPP/FFmpeg, librga/RGA, GStreamer, ABI, RDP-encode, fatal-journal, and
  soak qualification of the installed `6.18.42` / `0089` package, plus the
  targeted hostile/ownership gates for the late audit tail. Publication,
  install, boot, and the documented SD + `kernel-revert.sh` recovery path are
  already complete for their stated operator-evidence scope.
- Maintained-tip rebuild plus board install/revert validation for the Published
  historical alpha rewrite kernel source
  packages in
  [`kernel-rewrite-alpha-6.18/`](kernel-rewrite-alpha-6.18/README.md) and
  [`kernel-rewrite-alpha-7.2-rc3/`](kernel-rewrite-alpha-7.2-rc3/README.md).
  Both Launchpad builds succeeded; current local Armbian binary `.deb`s remain
  validation artifacts, not valid PPA upload inputs.
- The original dev-box `UPLOAD.md` runbook. The 2026-07 upload chronology is
  retained under [`history/`](history/README.md) instead.
- Signed upload artifacts, orig tarballs, `.changes`, `.dsc`, binary packages,
  and Launchpad credentials.

## See Also

- [`../README.md`](../README.md) - deploy hub and binary policy.
- [`../../status.md`](../../status.md) - project-wide dashboard.
- [`../ffmpeg-rockchip81/`](../ffmpeg-rockchip81/README.md) - self-contained
  local `/opt` FFmpeg package, separate from this PPA replacement package.
- [`../../video-libraries/ffmpeg/`](../../video-libraries/ffmpeg/README.md) -
  FFmpeg implementation notes and patch context.
