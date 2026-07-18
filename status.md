# STATUS — project-wide dashboard (dated)

Whole-project state at a glance. [kernel status](./kernel-drivers/docs/forward-port-status.md) stays the deep
scorecard for the *kernel port*; this page rolls up **every** track.

**How to read it.** Every row carries a **last-verified date** — trust a row
only as of its date. Facts that can go stale *silently* (external PRs/MRs,
distro versions, un-pushed dev-box state) are concentrated in the
[watchlist](#watchlist--facts-that-go-stale-silently) so routine maintenance
means re-checking one list. Update rule: the
[resyncing guide §6](./kernel-drivers/docs/resyncing.md) update-propagation table names this page
whenever a gate changes. The canonical status/ledger procedure is in
[`CONTRIBUTING.md`](CONTRIBUTING.md); keep dates honest (re-verify, don't
re-date).

Symbols: ✅ hardware-validated or otherwise complete for its stated scope;
⚠️ usable or reviewable with a material caveat; 🚧 active work without the
required runtime proof; 🔄 waiting on an external review/rebase cycle; ❌ not
available yet. A subsystem absent from this dashboard is **untracked**, not
implicitly working or broken. The
[`support coverage inventory`](docs/support-coverage.md) exposes whole-board
areas that are only narrowly evidenced or entirely unassessed; capture runtime
evidence in [`findings/`](findings/README.md) before adding a new status track.

## Dashboard

This table answers **what is true as of the verification date**. Longer evidence
stays in the linked detail and status ledger; the next proof is kept in the
separate table below so both remain scannable.

| # | Track | Public state | Verified | Detail |
|---|-------|--------------|----------|--------|
| 1 | Kernel forward-port | ✅ Primary path: combined kernel hardware-validated for H.264/H.265 encode/decode, RGA, transcode, and AV1/VP9 superset decode. | 2026-07-04 | [kernel status](./kernel-drivers/docs/forward-port-status.md) |
| 2 | BSP-audit fix series | ⚠️ Staged only: the split series diverges from the verified draft and does not compile until patch 0024 is regenerated. | 2026-07-01 | [`cleanup-split/`](./kernel-drivers/patches/cleanup-split/README.md) |
| 3 | DKMS channel | ⚠️ Compiles on 6.18; its DT overlay is dtc-validated but not boot-validated. | 2026-07-01 | [`packaging/dkms/`](packaging/dkms/README.md) |
| 4 | Clean-room rewrite drivers | 🚧 Armbian-based 6.18.38 and v7.2-rc3 composites pass the warning-free focused build gate and local source/full arm64 package builds; both replacement sources are accepted in their dedicated PPAs and their arm64 builds are running, but no rewrite kernel has booted hardware proof. | 2026-07-16 | [rewrite-driver track](./kernel-drivers/docs/rewrite-drivers.md) §6 |
| 5 | ffmpeg tree | ⚠️ Canonical `main`, `ffmpeg-80`, and `ffmpeg-81` branches are published and source/FATE-validated; existing PPAs remain pinned to older tested commits, and AV1 MP4/MKV still lacks board re-validation. | 2026-07-16 | [FFmpeg status](./video-libraries/ffmpeg/README.md) |
| 6 | ffmpeg submissions | ❌ The targeting plan exists, but no patch has been submitted. | 2026-07-02 | [`submission-plan.md`](./video-libraries/ffmpeg/docs/submission-plan.md) |
| 7 | GNOME Remote Desktop backend | ⚠️ The backend sustains 60 fps, but the live `~exp1` handover session froze after Firefox opened. Diagnostic-only `~exp2` at `1c870bc` adds rate-limited pipeline progress/starvation logging, passes full/local package builds and the RDP test, and built successfully in the experimental PPA. The freeze and original macOS reconnect scenario need re-testing. | 2026-07-17 | [`profiling and diagnostics`](./apps/gnome-remote-desktop/docs/profiling.md) |
| 8 | Mesa / Panfrost | 🔄 Four MRs remain open; selected G610 reruns pass and !42679 needs a rebase. | 2026-07-11 | [`video-libraries/mesa/`](video-libraries/mesa/README.md) |
| 9 | Launchpad PPA | ⚠️ The recreated main system PPA and dedicated FFmpeg PPAs have Published sources and binaries. Main-PPA forward-port replacement source `18624245` and dedicated rewrite sources `18623665`/`18623666` are accepted. Experimental GRD diagnostic source `18625943` is accepted and arm64 build `33411510` succeeded; publication is pending. Optional GDM upload and board migration/kernel/GRD runtime gates remain open. | 2026-07-17 | [`packaging/ppa/`](packaging/ppa/README.md) |
| 10 | Binary publishing | ❌ No built binaries are committed and no GitHub Release exists. | 2026-07-01 | [`packaging/`](packaging/README.md) |
| 11 | Kodi HW decode | 🚧 Decoder selection, MPP, and FFmpeg prerequisites are ready; Kodi build, playback, and packaging are unproven. | 2026-07-11 | [`apps/kodi/`](apps/kodi/README.md) |
| 12 | ROCK 5B SD/SPI boot chain | ⚠️ SPI → NVMe works; failing vendor raw artifacts have zero-byte U-Boot control DTBs, while the untested 26.5.1 `current` candidate has a valid DTB. | 2026-07-11 | [U-Boot comparison](./boot-firmware/docs/version-comparison.md) |

## Next gates

A next gate is the smallest result that would materially advance its track, not
a general wish list. The action path points to the maintained runbook, exact
evidence owner, or decision boundary; keep it usable when a gate changes. Close
or replace a gate only with evidence from the owning detail page, and update the
dashboard date and ledger row when public state changes.

| # | Track | Next proof | Action path |
|---|-------|------------|-------------|
| 1 | Kernel forward-port | No open kernel-function gate; rerun the hardware suite whenever the kernel or patch base changes. | [Hardware test runbook](./kernel-drivers/tests/README.md#run) |
| 2 | BSP-audit fix series | Regenerate patch 0024 and prove the full split series compiles. | [Compile defect and remedy](./kernel-drivers/patches/cleanup-split/README.md#cleanup-split-compile-gate) |
| 3 | DKMS channel | Install on a stock 6.18 ROCK 5B, boot the overlay, and run `validate-combined.sh`. | [DKMS build and install](./packaging/dkms/README.md#dkms-build-install) |
| 4 | Clean-room rewrite drivers | After the accepted Launchpad builds publish, install one replacement, boot it on the board, and capture the first hardware conformance log. | [Rewrite acceptance commands](./kernel-drivers/tests/rewrite-conformance.md#rewrite-acceptance-one-command) |
| 5 | ffmpeg tree | Re-test AV1 from MP4 and MKV through `av1_rkmpp` on RK3588. | [AV1 follow-up evidence](./findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md#av1-follow-up) |
| 6 | ffmpeg submissions | Submit the first patch from the ordered upstream/fork plan and record its review URL. | [Suggested first wave](./video-libraries/ffmpeg/docs/submission-plan.md#suggested-first-wave) |
| 7 | GNOME Remote Desktop backend | Reproduce the Firefox-triggered freeze against `~exp2`, preserve the `[RDP.PIPELINE]` transition, then re-test macOS Windows App reconnect before promotion. | [Diagnostic signals](./apps/gnome-remote-desktop/docs/profiling.md#8-pipeline-starvation-diagnostics-in-the-exp2-package) |
| 8 | Mesa / Panfrost | Rebase !42679 and rerun its selected CI coverage. | [MR tips and selected CI](./video-libraries/mesa/README.md#mr-status) |
| 9 | Launchpad PPA | Install, boot, and revert the co-installable forward-port kernel on the ROCK 5B. | [Kernel package checklist](./packaging/ppa/kernel-forward-port/README.md#remaining-checklist) |
| 10 | Binary publishing | Choose and record the repository-wide license required before a public release. | [License decision boundary](./LICENSE.md) |
| 11 | Kodi HW decode | Build Kodi GBM/GLES and validate RKMPP playback with `kodi-gbm` on tty1. | [Kodi tty1 runbook](./apps/kodi/docs/build-hwaccel.md#5-test-on-tty1-gbm-needs-drm-master) |
| 12 | ROCK 5B SD/SPI boot chain | Substitute the 26.5.1 `current` FIT, loader, and then both on a captured 26.2.1 SD baseline; record where each boot stops or succeeds. | [Raw-SD hypothesis test](./scripts/README.md#rock-5b-raw-sd-u-boot-hypothesis-test) |

> **Runtime gate pending.** The BSP-audit cleanup series still needs the runtime
> codec regression test before it can ship. Compile status alone is not
> verification; record the result in
> [`kernel-drivers/patches/cleanup-draft/verification.md`](./kernel-drivers/patches/cleanup-draft/verification.md)
> when it is run.

## Status Ledger

Longer dated audit notes now live in
[`docs/status-ledger.md`](./docs/status-ledger.md). Keep this page as the compact
dashboard, next-gate queue, and watchlist of facts that can change silently.

<a id="watchlist--facts-that-go-stale-silently"></a>

## Watchlist — facts that go stale silently

Re-check these on a maintenance pass. The index is the quick scan; each linked
detail preserves why the item can drift and the exact state observed on its
last-checked date.

| ID | Watch item | Last checked | Summary |
|----|------------|--------------|---------|
| W01 | [Armbian media-patch drift](#watch-w01) | 2026-07-11 | Patch blobs unchanged; DT anchors still hold. |
| W02 | [Armbian patcher precedence](#watch-w02) | 2026-07-11 | Core-wins behavior unchanged; rename workaround still required. |
| W03 | [Armbian codec-udev upstreaming](#watch-w03) | 2026-07-11 | PR merged; future images should carry the rule. |
| W04 | [Ubuntu FFmpeg version](#watch-w04) | 2026-07-11 | Resolute still publishes `7:8.0.1-3ubuntu2`. |
| W05 | [Launchpad PPA publication](#watch-w05) | 2026-07-17 | GRD `~exp2` source accepted and arm64 build `33411510` succeeded; publication is pending. |
| W06 | [Mesa MR stack](#watch-w06) | 2026-07-11 | Four MRs open; !42679 needs a rebase. |
| W07 | [`ffmpeg-rockchip-81` tips](#watch-w07) | 2026-07-16 | Three canonical branch tips published; source validation passed. |
| W08 | [AV1 container-extradata validation](#watch-w08) | 2026-07-16 | Fix carried forward; board re-test pending. |
| W09 | [Kodi build and tty1 playback](#watch-w09) | 2026-07-11 | Prerequisites ready; build/playback/package pending. |
| W10 | [GRD reconnect validation/submission](#watch-w10) | 2026-07-17 | Diagnostic `~exp2` branch and source are public; Firefox-freeze capture, macOS reconnect test, and upstream MR remain pending. |
| W11 | [Repository-wide license](#watch-w11) | 2026-07-11 | No repository-wide license granted. |
| W12 | [Dev-box-only artifacts](#watch-w12) | 2026-07-11 | Identified code/package artifacts are captured. |
| W13 | [librga P010/P210 series](#watch-w13) | 2026-07-11 | Series exported; 10-bit hardware gate remains. |
| W14 | [YSP Armbian builder](#watch-w14) | 2026-07-08 | Native compile reached; BTF link remains unproven. |
| W15 | [RGA session-close fix vs. base patch](#watch-w15) | 2026-07-17 | Force-free UAF fixed in fwport patch `0040`; frozen base patch still has the old path. |
| W16 | [MPP procfs/session lifetime fix](#watch-w16) | 2026-07-17 | Captured NULL dereference fixed in fwport patch `0041`; boot/reproduction gate pending. |

<a id="watch-w01"></a>
### W01 — Armbian media-patch drift

- **Why recheck:** DT patch 02 converts Armbian's nodes in place; changed node
  labels or patch anchors can break the build or decoder DT.
- **Last checked:** 2026-07-11
- **State then:** Live `armbian/build` main `815a50b664f9` still carried
  byte-identical `rockchip64-6.18` `media-0001`/`media-0007` blobs
  (`390c2e0b`/`a2a4143e`); `vdec0`, `vdec1`, and `av1d` hunk assumptions held.
  Checklist: [resyncing guide §4](./kernel-drivers/docs/resyncing.md).

<a id="watch-w02"></a>
### W02 — Armbian patcher precedence

- **Why recheck:** The self-contained-DT/AV1 build must rename two core media
  patches. A restored userpatch override, `series.conf` migration, or supported
  disable mechanism would change that procedure.
- **Last checked:** 2026-07-11
- **State then:** Live-main `lib/tools/patching.py` blob `d14c53f6` still matched
  the audited core-wins implementation. Mechanism and workaround:
  [`armbian-patch-precedence.md`](./packaging/docs/armbian-patch-precedence.md).

<a id="watch-w03"></a>
### W03 — Armbian codec-udev upstreaming

- **Why recheck:** The upstream rule determines whether `codec-udev` is required
  or only backfills older/custom images.
- **Last checked:** 2026-07-11
- **State then:** [armbian/build#10085](https://github.com/armbian/build/pull/10085)
  remained merged as `a6163444eb6c305b635c82242fbeb636daf4b6f4` (2026-06-30).
  Images built from that base should carry the MPP/dma-heap rule.

<a id="watch-w04"></a>
### W04 — Ubuntu FFmpeg version

- **Why recheck:** A future Resolute `7:8.1.x` can silently supersede the
  `+rkmpp` packages.
- **Last checked:** 2026-07-11
- **State then:** The live Resolute arm64 universe index published
  `ffmpeg 7:8.0.1-3ubuntu2`. Hold recipe:
  [`packaging/README.md`](packaging/README.md).

<a id="watch-w05"></a>
### W05 — Launchpad PPA publication

- **Why recheck:** Acceptance, build state, and binary publication can change
  after upload without a local repository edit.
- **Last checked:** 2026-07-17
- **State then:** The recreated `ubuntu-rock-5b` main PPA had all seven current
  sources and their binaries Published: MPP, librga, co-installable FFmpeg 6.1,
  the forward-port kernel, FFmpeg 8.0.3, GRD, and codec-udev 1.1. FFmpeg build
  [`33397317`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33397317),
  GRD build
  [`33397319`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33397319),
  and codec-udev build
  [`33399688`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33399688)
  succeeded, and the main PPA had zero archive dependencies. The upstream and
  Rockchip FFmpeg 8.1 PPAs each had one source plus 29 binaries Published.
  At 16:07 PDT the main PPA had also accepted 5.10-reconciled forward-port
  kernel source
  [`18624245`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18624245);
  arm64 build
  [`33407351`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33407351)
  was running while source `18619788` and its binaries remained Published.
  On 2026-07-16 the rewrite-kernel PPAs accepted Armbian-based 6.18.38 source
  [`18623665`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+sourcepub/18623665)
  and 7.2-rc3 source
  [`18623666`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+sourcepub/18623666);
  arm64 builds
  [`33406491`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+build/33406491)
  and
  [`33406492`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+build/33406492)
  were still running at 12:37 PDT. Historical 6.18.0 and 7.2-rc2 binaries remain
  Published until the replacements complete. The experimental archive accepted
  GRD reconnect-v2 source publication
  [`18620800`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+sourcepub/18620800)
  and arm64 build
  [`33399816`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+build/33399816).
  A 2026-07-15 recheck confirmed the build succeeded.
  On 2026-07-17, the experimental archive accepted the GRD `~exp2` source and
  arm64 build
  [`33411510`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+build/33411510)
  succeeded; binary publication remained pending.
  The main PPA has no dependency on the experimental archive. The optional GDM
  ACL package was not uploaded, and no PPA kernel had passed its board gate.

<a id="watch-w06"></a>
### W06 — Mesa MR stack

- **Why recheck:** Review feedback, CI, merge state, and rebase requirements
  determine the next upstream action.
- **Last checked:** 2026-07-11
- **State then:** [!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563),
  [!42679](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42679),
  [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613), and
  [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614)
  remained open; !42679 reported `need_rebase`. Selected evidence remained:
  !42563 pipeline 1697832 green for x86/arm64 build plus G610 GL/piglit;
  !42679 pipeline 1700107 green for x86 build, clang, llvmpipe, and softpipe;
  !42613 `8875a22856d` pipeline 1700162 and !42614 `4c23f1db1f9` pipeline
  1700163 passed all four selected G610 shards. The web UI remained bot-blocked;
  use the GitLab API. Superseded context: [!38433](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/38433).

<a id="watch-w07"></a>
### W07 — `ffmpeg-rockchip-81` tips

- **Why recheck:** The canonical master, 8.0, and 8.1 lines follow moving
  upstream branches; later upstream movement requires a fresh replay and test.
- **Last checked:** 2026-07-16
- **State then:** Published tips were `main@8b57e531d1fc` over
  `FFmpeg/master@ceabc9b306f5`, `ffmpeg-80@be753f3bbb2c` over
  `release/8.0@435ae0581deb`, and `ffmpeg-81@8d3ca020b6a2` over
  `release/8.1@94138f6973dd`. The former PR #1/refactor lineage is integrated
  into all three. Source builds and `fate-source` passed; no new hardware or
  package validation was performed. The dedicated PPA remains at
  `be367abfe6`.

<a id="watch-w08"></a>
### W08 — AV1 container-extradata validation

- **Why recheck:** Kodi AV1 playback from MP4/MKV depends on MPP recognizing the
  container's `av1C` extradata.
- **Last checked:** 2026-07-16
- **State then:** `be367abfe6` fixed the missing `mpp_packet_set_extra_data()`
  call that caused MPP to parse the `av1C` header as an OBU; the fix is carried
  by all three canonical branches. Earlier source build/FATE and package
  validation passed, but the new branch tips have only source/FATE validation;
  RK3588 MP4/MKV decode re-test remained pending.
  See [finding §3](findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md).

<a id="watch-w09"></a>
### W09 — Kodi build and tty1 playback

- **Why recheck:** Decoder selection is designed, but the application build and
  real playback have not been demonstrated.
- **Last checked:** 2026-07-11
- **State then:** Fork `libavcodec63` packages were built, MPP was fixed, and no
  Kodi patch was needed. GBM/GLES build, `kodi-gbm` tty1 playback with Prime
  settings, and the Kodi PPA package remained pending. See
  [`apps/kodi/`](apps/kodi/README.md).

<a id="watch-w10"></a>
### W10 — GRD reconnect validation/submission

- **Why recheck:** The corrected series must reproduce the original macOS
  reconnect failure before promotion, and the submission claim needs a public
  review artifact.
- **Last checked:** 2026-07-17
- **State then:** The live `~exp1` handover session froze after Firefox opened,
  while the kernel stayed responsive and showed no new fault. Public branch
  [`debug/exp1-frame-starvation`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/commits/debug/exp1-frame-starvation)
  at `1c870bc82d19` adds rate-limited `[RDP.PIPELINE]` progress counters and a
  suspected-starvation warning without changing renderer scheduling. Clean
  Meson/Ninja and Debian arm64 builds passed; the RDP test passed. Experimental
  `~exp2` source publication `18625943` was accepted and build `33411510`
  succeeded in 6m24s. Publication, reproducing the Firefox freeze with the new
  logs, the exact macOS
  Windows App reconnect, and an upstream GNOME MR remained pending.

<a id="watch-w11"></a>
### W11 — Repository-wide license

- **Why recheck:** A public release needs a clear redistribution license.
- **Last checked:** 2026-07-11
- **State then:** No repository-wide license had been granted; the boundary
  remained [`LICENSE.md`](LICENSE.md).

<a id="watch-w12"></a>
### W12 — Dev-box-only artifacts

- **Why recheck:** Uncaptured code or packaging in a dirty worktree is a single
  point of failure.
- **Last checked:** 2026-07-11
- **State then:** No identified code/package artifact remained only in an
  uncaptured dirty tree. GRD async-PBO and MemFd prototypes were exported under
  [`patches/reference/`](./apps/gnome-remote-desktop/patches/reference/). The
  throwaway headless harness was not preserved, but its reconstruction was
  documented. Evidence: [`baseline.md`](./apps/gnome-remote-desktop/docs/baseline.md)
  §7, [`profiling.md`](./apps/gnome-remote-desktop/docs/profiling.md) §4, and
  [`external-workspaces.md`](packaging/external-workspaces.md).

<a id="watch-w13"></a>
### W13 — librga P010/P210 series

- **Why recheck:** The fix must remain reconstructible and its 10-bit shipping
  gate must not be mistaken for completed hardware validation.
- **Last checked:** 2026-07-11
- **State then:** The series from `2cffdf6` through `main@a632217` was exported
  under [`vendor-libraries/rga/patches/`](./vendor-libraries/rga/patches/README.md).
  `LIBRGA_SMOKE_10BIT=1 kernel-drivers/tests/librga-smoke.sh` provided the direct
  IM2D gate; padded P010/P210 RKRGA hardware validation remained pending. See
  [shipping guidance](./vendor-libraries/rga/docs/librga-p010-p210-rkrga.md).

<a id="watch-w14"></a>
### W14 — YSP Armbian builder

- **Why recheck:** Builder resources, supported releases, branch mapping, and
  Armbian trunk behavior can shift without a repo change.
- **Last checked:** 2026-07-08
- **State then:** The Noble 24.04 aarch64 VMware VM had 5 vCPU, 7.7 GiB RAM,
  a 97 GB root LV, and `armbian/build 26.08.0-trunk`. Native compilation reached
  GCC 13.3.0 arm64-on-arm64; the BTF/`pahole` link remained unproven on 8 GB.
  `resolute` was marked supported and branch map was current=6.18, edge=7.1,
  vendor=6.1. See the [builder finding](findings/2026-07-08-armbian-builder-setup.md).

<a id="watch-w15"></a>
### W15 — RGA session-close fix vs. base patch

- **Why recheck:** The RGA `/dev/rga`-close force-free hazard is fixed as a
  fwport-tree commit, but the repo's shipped base patch is a frozen vendor
  snapshot that still carries the old `rga_mm_force_releaser_buffer()` path, so
  the two can silently diverge until the next regeneration.
- **Last checked:** 2026-07-17
- **State then:** Driver fix `linux-6.18-rkvenc-av1-fwport@bc086cbe03d7`
  ("release session buffers by reference on close") makes
  `rga_mm_session_release_buffer()` drop each buffer through
  `kref_put(..., rga_mm_kref_release_buffer)` instead of force-freeing;
  compile-verified, not yet re-exercised on hardware. It is now exported as
  forward-port patch `0040`. The base patch
  [`rk3588-rkvenc2-01-vcodec-rga-drivers.patch`](./kernel-drivers/patches/rk3588-rkvenc2-01-vcodec-rga-drivers.patch)
  still contains the old force-free path (as does `@1c9a110129fe` "validate
  physical import pages"); fold both fwport fixes in at the next base-patch
  regeneration ([resyncing guide](./kernel-drivers/docs/resyncing.md)). The
  triggering test leak is fixed in
  [`abi-probe.c`](./kernel-drivers/tests/abi-probe.c). See the
  [finding](findings/2026-07-17-rga-session-close-uaf.md).

<a id="watch-w16"></a>
### W16 — MPP procfs/session lifetime fix

- **Why recheck:** The captured `/proc/mpp_service/sessions-summary` Oops is
  fixed in the forward-port source series, but the running kernel and frozen
  base patch still have the unsafe teardown order; the new build has not been
  booted or stress-tested.
- **Last checked:** 2026-07-17
- **State then:** The complete trace faults at `rwsem_read_trylock()` from
  `rkvenc_dump_session()` with a NULL private pointer while a proc reader races
  encoder close. Forward-port commit `df0d7037213c`, exported as patch `0041`,
  removes sessions from the procfs-visible service list under `session_lock`
  before device-private or DMA teardown. The three affected arm64 objects and
  strict patch style checks pass. Next gate: package/install the fixed kernel,
  reboot, run procfs/churn concurrency once, then repeat the 1,000-iteration
  no-forced-IDR FFmpeg control. See the
  [finding](findings/2026-07-17-mpp-procfs-session-teardown-oops.md).
