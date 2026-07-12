# STATUS — project-wide dashboard (dated)

Whole-project state at a glance. [kernel status](./kernel-drivers/docs/forward-port-status.md) stays the deep
scorecard for the *kernel port*; this page rolls up **every** track.

**How to read it.** Every row carries a **last-verified date** — trust a row
only as of its date. Facts that can go stale *silently* (external PRs/MRs,
distro versions, un-pushed dev-box state) are concentrated in the
[watchlist](#watchlist--facts-that-go-stale-silently) so routine maintenance
means re-checking one list. Update rule: the
[resyncing guide §6](./kernel-drivers/docs/resyncing.md) update-propagation table names this page
whenever a gate changes; keep dates honest (re-verify, don't re-date).

## Dashboard

| # | Track | Public state | Verified | Detail |
|---|-------|--------------|----------|--------|
| 1 | Kernel forward-port | ✅ Primary validated path: combined Armbian kernel is hardware-validated for H.264/H.265 encode/decode, full hardware transcode, and the AV1/VP9 superset decode build. | 2026-07-04 | [kernel status](./kernel-drivers/docs/forward-port-status.md) |
| 2 | BSP-audit fix series | ⚠️ Staged review material, not shippable: current split series diverged from the adversarially-verified draft and does not compile until patch 0024 is regenerated. | 2026-07-01 | [`cleanup-split/`](./kernel-drivers/patches/cleanup-split/README.md) |
| 3 | DKMS channel | ⚠️ Secondary path: compiles on the documented 6.18 target; boot overlay is dtc-validated but not boot-validated. | 2026-07-01 | [`packaging/dkms/`](packaging/dkms/README.md) |
| 4 | Clean-room rewrite drivers | 🚧 Active bring-up: 6.18 remains at `d1d15a3d052a`; mainline was rebased to official `v7.2-rc2` at `083bdb98e715`. Source-package `olddefconfig` validation passes for both alpha kernel packages, and broad device-free validation exists, but there is still no booted hardware-validation record. | 2026-07-10 | [rewrite-driver track](./kernel-drivers/docs/rewrite-drivers.md) §6 |
| 5 | ffmpeg tree | ⚠️ `ffmpeg-rockchip-81` builds and packages. The AV1 MP4/MKV fix (`be367abfe6`) and decoder `pix_fmts` cleanup (`8356739686`) are committed on `main`; open, mergeable PR #1 advanced to `c8aca81111` with review fixes. The decoder, `ffmpeg`, and focused FATE test pass. Packaging exports `main@be367abfe6` with no quilt series, and source publication `18615674` plus arm64 build `33388714` are public. RK3588 MP4/MKV hardware re-validation remains pending. | 2026-07-11 | [Kodi/ffmpeg finding](./findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md) |
| 6 | ffmpeg submissions | ❌ Nothing submitted yet; the upstream-vs-fork targeting plan exists. | 2026-07-02 | [`submission-plan.md`](./video-libraries/ffmpeg/docs/submission-plan.md) |
| 7 | GNOME Remote Desktop backend | ✅ Patch series applies to GRD 50.1 and the hardware path sustains 60 fps; handover-reconnect work is still awaiting upstream submission. | 2026-07-03 | [`profiling.md`](./apps/gnome-remote-desktop/docs/profiling.md) |
| 8 | Mesa / Panfrost | 🔄 Four-MR `gl_FragCoord` transfer stack remains open at the validated tips; selected G610 reruns passed, interpolation evidence is separated under `interp_probe/`, and !42679 now needs a rebase. | 2026-07-11 | [`video-libraries/mesa/`](video-libraries/mesa/README.md) |
| 9 | Launchpad PPA | ⚠️ Public arm64 indexes now contain MPP, librga, Rockchip-81 FFmpeg from `main@be367abfe6`, the co-installable FFmpeg 6.1 tools, and all three `~rk2` co-installable kernels. GRD and the optional GDM greeter ACL remain held, and kernel board install/revert validation is pending, so this is not yet the primary full-stack install path. | 2026-07-11 | [`packaging/ppa/`](packaging/ppa/README.md) |
| 10 | Binary publishing | ❌ No built binaries are committed and no GitHub Releases exist yet. | 2026-07-01 | [`packaging/`](packaging/README.md) |
| 11 | Kodi HW decode | 🚧 Design + prerequisites done: stock Kodi 22 auto-selects the fork `*_rkmpp` decoders via their `AVCodecHWConfig` (no Kodi patch), the fork `libavcodec63` debs are built, and the MPP runtime is fixed. Not yet done: the Kodi GBM/GLES build, tty1 playback validation, and the `kodi` PPA package. | 2026-07-11 | [`apps/kodi/`](apps/kodi/README.md) |

> **Runtime gate pending.** The BSP-audit cleanup series still needs the runtime
> codec regression test before it can ship. Compile status alone is not
> verification; record the result in
> [`kernel-drivers/patches/cleanup-draft/verification.md`](./kernel-drivers/patches/cleanup-draft/verification.md)
> when it is run.

## Status Ledger

Longer dated audit notes now live in
[`docs/status-ledger.md`](./docs/status-ledger.md). Keep this page as the
status dashboard plus the watchlist of facts that can change silently.

<a id="watchlist--facts-that-go-stale-silently"></a>

## Watchlist — facts that go stale silently

Re-check these on any maintenance pass; each row records the last time anyone
looked.

| Watch item | Why it matters | Last checked | State then |
|------------|----------------|--------------|------------|
| Armbian `media-0001` drift (node labels, av1d `@@` anchor) | DT patch 02 converts its nodes in place — a change breaks the build or the decoder DT | 2026-07-11 | Live `armbian/build` main `815a50b664f9` still carries byte-identical `rockchip64-6.18` `media-0001`/`media-0007` blobs (`390c2e0b`/`a2a4143e`); `vdec0`, `vdec1`, and the `av1d` hunk assumptions hold. Checklist: [resyncing guide §4](./kernel-drivers/docs/resyncing.md) |
| Armbian patcher precedence (empty-file disable **broken** on glob branches; `rockchip64-6.18` is glob, not series) | The self-contained-DT / AV1 build disables `media-0001`+`media-0007` by **renaming them in Armbian's core tree**; if Armbian restores userpatch override, moves the branch to `series.conf`, or adds a per-patch disable, switch the disable step to the supported mechanism | 2026-07-11 | Live-main `lib/tools/patching.py` blob remains `d14c53f6`, identical to the audited core-wins implementation; no precedence change observed. Mechanism + fix: [`packaging/docs/armbian-patch-precedence.md`](./packaging/docs/armbian-patch-precedence.md) |
| [armbian/build#10085](https://github.com/armbian/build/pull/10085) (udev rule upstreaming) | Determines whether `codec-udev` is required or just a backfill for older/custom images | 2026-07-11 | GitHub still records it merged 2026-06-30 as `a6163444eb6c305b635c82242fbeb636daf4b6f4`; future Armbian images built from that base should carry the MPP/dma-heap rule. |
| Ubuntu ffmpeg version on resolute | A future `7:8.1.x` silently supersedes the `+rkmpp` debs | 2026-07-11 | The live resolute arm64 universe index still publishes `ffmpeg 7:8.0.1-3ubuntu2`; hold recipe: [`packaging/README.md`](packaging/README.md) |
| Launchpad PPA publication state | Source acceptance, build state, and binary publication can change after upload without local file changes | 2026-07-11 | Launchpad API + public arm64 index check 21:44 PDT: `main@be367abfe6` FFmpeg source [`18615674`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18615674) is Published and build [`33388714`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33388714) succeeded; its `ffmpeg`/`libavcodec63` binaries are indexed. Co-installable `ffmpeg-rockchip`, MPP, librga, and all three `~rk2` kernel image/DTB/header sets are also indexed. GRD/GDM remain held; no kernel has passed its board gate. |
| Mesa MR stack [!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563) / [!42679](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42679) / [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613) / [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614) (+ superseded [!38433](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/38433)) | Review feedback / CI results / merge state drive next steps | 2026-07-11 | GitLab API: all remain `opened` at the previously recorded tips/pipelines; !42679 is now reported `need_rebase`. Selected CI evidence remains: !42563 pipeline 1697832 green for x86/arm64 build + G610 GL/piglit; !42679 pipeline 1700107 green for x86 build + clang + llvmpipe + softpipe; corrected !42613 `8875a22856d` pipeline 1700162 and !42614 `4c23f1db1f9` pipeline 1700163 passed all four selected G610 shards. Web UI stays bot-blocked; use the GitLab API. |
| `ffmpeg-rockchip-81` tip | Main carries correctness fixes; refactor work remains isolated in PR #1. | 2026-07-11 | GitHub API check 21:37 PDT: `main` tip `be367abfe6`; `refactor/section-c` tip `c8aca81111`, with updated main merged and review findings fixed. [PR #1](https://github.com/yisding/ffmpeg-rockchip-81/pull/1) is open and mergeable. PPA source exports the exact main tip. |
| `av1_rkmpp` container extradata | Kodi AV1 playback from MP4/MKV depends on MPP recognizing the container's `av1C` extradata | 2026-07-11 | Root cause fixed directly on main in `be367abfe6`: the fork sent extradata but omitted `mpp_packet_set_extra_data()`, so MPP parsed the `av1C` header as an OBU. Source build/FATE and package source validation pass; RK3588 MP4/MKV decode re-test pending. [finding §3](findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md) |
| Kodi build + tty1 playback | The `apps/kodi` design is validated but the build and on-board playback have not been run | 2026-07-11 | Prereqs done (fork `libavcodec63` debs built, MPP fixed, no Kodi patch needed). Pending: GBM/GLES build, `kodi-gbm` on tty1 with the Prime-decoder settings, and the `kodi` PPA package. [`apps/kodi/`](apps/kodi/README.md) |
| GRD handover fix upstream MR | Row 7's "awaiting submission" has no artifact to point at yet | 2026-07-11 | GitLab project/fork MR queries found no submission for `rdp-handover-reconnect`; branch still points to `a3a1a32`. |
| Repository-wide license decision | A public release needs a clear license; until then the repo stands as an integration record, not a redistributable release | 2026-07-11 | No repository-wide license granted; current boundary remains [`LICENSE.md`](LICENSE.md). |
| **Dev-box-only artifacts** (single point of failure) | ✅ No currently identified code/package artifact is available only in an uncaptured dirty worktree. The GRD async-PBO and MemFd prototype diffs are now exported under [`apps/gnome-remote-desktop/patches/reference/`](./apps/gnome-remote-desktop/patches/reference/). The throwaway headless-harness driver was never preserved, but its four-component reconstruction is documented. | 2026-07-11 | Prototype evidence and disposition: [`baseline.md`](./apps/gnome-remote-desktop/docs/baseline.md) §7; harness reconstruction: [`profiling.md`](./apps/gnome-remote-desktop/docs/profiling.md) §4; workspace disposition: [`packaging/external-workspaces.md`](packaging/external-workspaces.md). |
| **librga P010/P210 fix series** | ✅ **Exported in-repo** as [`vendor-libraries/rga/patches/`](./vendor-libraries/rga/patches/README.md), covering the source series from `2cffdf6` to local `main@a632217`. It is no longer a dev-box-only single point of failure, and `LIBRGA_SMOKE_10BIT=1 kernel-drivers/tests/librga-smoke.sh` provides the smallest direct IM2D P010/P210 hardware check. Recorded hardware validation of padded P010/P210 RKRGA paths is still pending. | 2026-07-11 | Local source tip and exported series rechecked; [`vendor-libraries/rga/docs/librga-p010-p210-rkrga.md`](./vendor-libraries/rga/docs/librga-p010-p210-rkrga.md) § Shipping guidance. |
| **YSP Armbian builder box** (dev-box state) | The `rock-5b` builder is a Noble 24.04 aarch64 VMware VM whose RAM (7.7 GiB, only ~19–45 MiB over Armbian's BTF gate), grown 97 GB LV, the `resolute` `supported` flag, and the `current=6.18 / edge=7.1 / vendor=6.1` branch map can all shift silently under `armbian/build` trunk | 2026-07-08 | `armbian/build` `26.08.0-trunk`; native compile reached (`gcc 13.3.0`, arm64-on-arm64) but the BTF/`pahole` link is unproven on 8 GB; setup + branch/release/cache map: [`findings/2026-07-08-armbian-builder-setup.md`](findings/2026-07-08-armbian-builder-setup.md) |
