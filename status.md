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
| 4 | Clean-room rewrite drivers | 🚧 Both alpha packages pass source/config gates and broad device-free validation; neither has booted hardware proof. | 2026-07-10 | [rewrite-driver track](./kernel-drivers/docs/rewrite-drivers.md) §6 |
| 5 | ffmpeg tree | ⚠️ Rockchip-81 builds, passes focused tests, and is public in the PPA; AV1 MP4/MKV still lacks board re-validation. | 2026-07-11 | [Kodi/ffmpeg finding](./findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md) |
| 6 | ffmpeg submissions | ❌ The targeting plan exists, but no patch has been submitted. | 2026-07-02 | [`submission-plan.md`](./video-libraries/ffmpeg/docs/submission-plan.md) |
| 7 | GNOME Remote Desktop backend | ✅ The series applies to GRD 50.1 and the hardware path sustains 60 fps; the reconnect fix is not submitted. | 2026-07-03 | [`profiling.md`](./apps/gnome-remote-desktop/docs/profiling.md) |
| 8 | Mesa / Panfrost | 🔄 Four MRs remain open; selected G610 reruns pass and !42679 needs a rebase. | 2026-07-11 | [`video-libraries/mesa/`](video-libraries/mesa/README.md) |
| 9 | Launchpad PPA | ⚠️ MPP, librga, both FFmpeg tracks, and three kernels are public; GRD/GDM are held and kernel board gates are open. | 2026-07-11 | [`packaging/ppa/`](packaging/ppa/README.md) |
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
| 4 | Clean-room rewrite drivers | Boot one packaged alpha kernel on the board and capture the first hardware conformance log. | [Rewrite acceptance commands](./kernel-drivers/tests/rewrite-conformance.md#rewrite-acceptance-one-command) |
| 5 | ffmpeg tree | Re-test AV1 from MP4 and MKV through `av1_rkmpp` on RK3588. | [AV1 follow-up evidence](./findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md#av1-follow-up) |
| 6 | ffmpeg submissions | Submit the first patch from the ordered upstream/fork plan and record its review URL. | [Suggested first wave](./video-libraries/ffmpeg/docs/submission-plan.md#suggested-first-wave) |
| 7 | GNOME Remote Desktop backend | Submit the handover-reconnect fix upstream and link the MR. | [Submission state and branch](#watch-w10) |
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
| W05 | [Launchpad PPA publication](#watch-w05) | 2026-07-11 | Userspace and kernels public; board gates remain open. |
| W06 | [Mesa MR stack](#watch-w06) | 2026-07-11 | Four MRs open; !42679 needs a rebase. |
| W07 | [`ffmpeg-rockchip-81` tips](#watch-w07) | 2026-07-11 | Main and PR tips recorded; PR remains mergeable. |
| W08 | [AV1 container-extradata validation](#watch-w08) | 2026-07-11 | Fix built and public; board re-test pending. |
| W09 | [Kodi build and tty1 playback](#watch-w09) | 2026-07-11 | Prerequisites ready; build/playback/package pending. |
| W10 | [GRD handover-fix submission](#watch-w10) | 2026-07-11 | No upstream MR found. |
| W11 | [Repository-wide license](#watch-w11) | 2026-07-11 | No repository-wide license granted. |
| W12 | [Dev-box-only artifacts](#watch-w12) | 2026-07-11 | Identified code/package artifacts are captured. |
| W13 | [librga P010/P210 series](#watch-w13) | 2026-07-11 | Series exported; 10-bit hardware gate remains. |
| W14 | [YSP Armbian builder](#watch-w14) | 2026-07-08 | Native compile reached; BTF link remains unproven. |

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
- **Last checked:** 2026-07-11
- **State then:** The 21:44 PDT API/index check found Rockchip-81 FFmpeg source
  [`18615674`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18615674)
  published and build
  [`33388714`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33388714)
  successful, with `ffmpeg`/`libavcodec63` indexed. Co-installable
  `ffmpeg-rockchip`, MPP, librga, and all three `~rk2` kernel sets were indexed.
  GRD/GDM remained held; no kernel had passed its board gate.

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

- **Why recheck:** Main carries correctness fixes while refactor work remains
  isolated in PR #1; either tip or mergeability can change.
- **Last checked:** 2026-07-11
- **State then:** GitHub API at 21:37 PDT reported `main@be367abfe6` and
  `refactor/section-c@c8aca81111`. [PR #1](https://github.com/yisding/ffmpeg-rockchip-81/pull/1)
  was open and mergeable; PPA source exported the exact main tip.

<a id="watch-w08"></a>
### W08 — AV1 container-extradata validation

- **Why recheck:** Kodi AV1 playback from MP4/MKV depends on MPP recognizing the
  container's `av1C` extradata.
- **Last checked:** 2026-07-11
- **State then:** `be367abfe6` fixed the missing `mpp_packet_set_extra_data()`
  call that caused MPP to parse the `av1C` header as an OBU. Source build/FATE
  and package validation passed; RK3588 MP4/MKV decode re-test remained pending.
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
### W10 — GRD handover-fix submission

- **Why recheck:** Dashboard track 7's submission claim needs a public review
  artifact.
- **Last checked:** 2026-07-11
- **State then:** GitLab project/fork MR queries found no submission for
  `rdp-handover-reconnect`; the branch remained at `a3a1a32`.

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
