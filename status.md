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
| 5 | ffmpeg tree | ⚠️ Current local `ffmpeg-rockchip-81` forward-port at `75638e7f0b17` builds and packages; feature/encode/RGA-smoke validation passed. Installed `/usr` MPP lacks decoder parser registration, but a clean `mpp-rockchip` 1.0.12 / pkg-config 1.3.10 build makes `h264_rkmpp` decode pass, so remaining work is packaging/selecting that MPP runtime and rerunning full decode/transcode. | 2026-07-06 | [`ffmpeg-rockchip81` finding](./findings/2026-07-06-ffmpeg-rockchip81-package-validation.md) |
| 6 | ffmpeg submissions | ❌ Nothing submitted yet; the upstream-vs-fork targeting plan exists. | 2026-07-02 | [`submission-plan.md`](./video-libraries/ffmpeg/docs/submission-plan.md) |
| 7 | GNOME Remote Desktop backend | ✅ Patch series applies to GRD 50.1 and the hardware path sustains 60 fps; handover-reconnect work is still awaiting upstream submission. | 2026-07-03 | [`profiling.md`](./apps/gnome-remote-desktop/docs/profiling.md) |
| 8 | Mesa / Panfrost | 🔄 Four-MR `gl_FragCoord` transfer stack remains open; selected G610 reruns passed, and interpolation evidence is now separated under `interp_probe/`. | 2026-07-06 | [`video-libraries/mesa/`](video-libraries/mesa/README.md) |
| 9 | Launchpad PPA | ⚠️ PPA work is in progress, but the full stack is not installable yet: MPP and librga source + arm64 binaries are public; Rockchip-81 FFmpeg source `18614542` is published but arm64 build `33387355` failed on removed `--disable-omx`, with local `~rk3` packaging prepared but not uploaded; forward-port kernel source `18614540` is published and arm64 build `33387353` is currently building; alpha rewrite kernel sources `18614549` and `18614550` are pending with arm64 builds `33387366` and `33387367` queued. GRD and the optional GDM greeter ACL remain held. Kernel board install/revert validation is pending. | 2026-07-10 | [`packaging/ppa/`](packaging/ppa/README.md) |
| 10 | Binary publishing | ❌ No built binaries are committed and no GitHub Releases exist yet. | 2026-07-01 | [`packaging/`](packaging/README.md) |

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
| Armbian `media-0001` drift (node labels, av1d `@@` anchor) | DT patch 02 converts its nodes in place — a change breaks the build or the decoder DT | 2026-07-01 (running kernel derives from it) | Assumptions hold on `rockchip64-6.18`; checklist: [resyncing guide §4](./kernel-drivers/docs/resyncing.md) |
| Armbian patcher precedence (empty-file disable **broken** on glob branches; `rockchip64-6.18` is glob, not series) | The self-contained-DT / AV1 build disables `media-0001`+`media-0007` by **renaming them in Armbian's core tree**; if Armbian restores userpatch override, moves the branch to `series.conf`, or adds a per-patch disable, switch the disable step to the supported mechanism | 2026-07-04 (read `patching.py` @ `82b6430`) | core-wins confirmed; no PR to restore; mechanism + fix: [`packaging/docs/armbian-patch-precedence.md`](./packaging/docs/armbian-patch-precedence.md) |
| [armbian/build#10085](https://github.com/armbian/build/pull/10085) (udev rule upstreaming) | Determines whether `codec-udev` is required or just a backfill for older/custom images | 2026-07-06 | Merged 2026-06-30 as `a6163444eb6c305b635c82242fbeb636daf4b6f4`; future Armbian images built from that base should carry the MPP/dma-heap rule. |
| Ubuntu ffmpeg version on resolute | A future `7:8.1.x` silently supersedes the `+rkmpp` debs | 2026-07-06 | Launchpad primary archive still publishes `ffmpeg 7:8.0.1-3ubuntu2` in `resolute` Release; hold recipe: [`packaging/README.md`](packaging/README.md) |
| Launchpad PPA publication state | Source acceptance, build state, and binary publication can change after upload without local file changes | 2026-07-10 | Launchpad API check after 23:20 PDT: Rockchip-81 FFmpeg source `18614542` is `Published`, but arm64 build `33387355` is `Failed to build` because `configure` rejected `--disable-omx`; local `~rk3` packaging drops that flag but is not uploaded. Earlier 23:05 PDT check found forward-port kernel source `18614540` `Published` with arm64 build `33387353` `Currently building`, and alpha kernel sources `18614549`/`18614550` `Pending` with arm64 builds `33387366`/`33387367` `Needs building`. MPP and librga source + arm64 binaries were already public. GRD and GDM ACL are not uploaded. Re-check before telling users to install from the PPA. |
| Mesa MR stack [!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563) / [!42679](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42679) / [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613) / [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614) (+ superseded [!38433](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/38433)) | Review feedback / CI results / merge state drive next steps | 2026-07-06 | All `opened`. Titles/tips checked via authenticated `glab api` against project 176; fork pipelines live under project 27504. Selected CI: !42563 pipeline 1697832 green for x86/arm64 build + G610 GL/piglit; !42679 pipeline 1700107 green for x86 build + clang + llvmpipe + softpipe; old !42613 pipeline 1700108 and old !42614 pipeline 1700109 red on selected G610 jobs for classified reasons. Corrected !42613 `a9d6caeeb53` pipeline 1700150 got 3/4 selected G610 shards green and exposed only stale `glx-copy-sub-buffer` expectation in piglit 2/2. Current branches are !42613 `8875a22856d` pipeline 1700162 and !42614 `4c23f1db1f9` pipeline 1700163; both passed all four selected G610 shards. Web UI stays bot-blocked; use `glab api "projects/176/merge_requests/<iid>/notes"` and `glab api "projects/27504/pipelines/<id>/jobs"`. |
| `ffmpeg-rockchip-81` tip | It has moved mid-documentation several times; package validation used the local branch `refactor/section-c`, not the older status-row tip. | 2026-07-06 | `75638e7f0b17`; package/failure ledger: [`findings/2026-07-06-ffmpeg-rockchip81-package-validation.md`](findings/2026-07-06-ffmpeg-rockchip81-package-validation.md) |
| GRD handover fix upstream MR | Row 7's "awaiting submission" has no artifact to point at yet | 2026-07-01 | Not submitted |
| Repository-wide license decision | A public release needs a clear license; until then the repo stands as an integration record, not a redistributable release | 2026-07-06 | No repository-wide license granted; current boundary recorded in [`LICENSE.md`](LICENSE.md). |
| **Dev-box-only artifacts** (single point of failure) | Loss = unrecoverable: GRD async-PBO/MemFd prototype worktrees and the headless-harness driver script. The `mpp`/`librga`/`ffmpeg`/GRD/GDM-ACL PPA packaging and the rewrite-driver branches are no longer in this bucket. | 2026-07-09 | Remaining capture actions live in [`apps/gnome-remote-desktop/docs/baseline.md`](./apps/gnome-remote-desktop/docs/baseline.md) §7 and [`apps/gnome-remote-desktop/docs/profiling.md`](./apps/gnome-remote-desktop/docs/profiling.md) §4; packaging workspace disposition lives in [`packaging/external-workspaces.md`](packaging/external-workspaces.md). |
| **librga P010/P210 fix series** | ✅ **Exported in-repo** as [`vendor-libraries/rga/patches/`](./vendor-libraries/rga/patches/README.md), covering the source series from `2cffdf6` to `a632217`. It is no longer a dev-box-only single point of failure, and `LIBRGA_SMOKE_10BIT=1 kernel-drivers/tests/librga-smoke.sh` now provides the smallest direct IM2D P010/P210 hardware check. Recorded hardware validation of padded P010/P210 RKRGA paths is still pending. | 2026-07-04 | [`vendor-libraries/rga/docs/librga-p010-p210-rkrga.md`](./vendor-libraries/rga/docs/librga-p010-p210-rkrga.md) § Shipping guidance |
| **YSP Armbian builder box** (dev-box state) | The `rock-5b` builder is a Noble 24.04 aarch64 VMware VM whose RAM (7.7 GiB, only ~19–45 MiB over Armbian's BTF gate), grown 97 GB LV, the `resolute` `supported` flag, and the `current=6.18 / edge=7.1 / vendor=6.1` branch map can all shift silently under `armbian/build` trunk | 2026-07-08 | `armbian/build` `26.08.0-trunk`; native compile reached (`gcc 13.3.0`, arm64-on-arm64) but the BTF/`pahole` link is unproven on 8 GB; setup + branch/release/cache map: [`findings/2026-07-08-armbian-builder-setup.md`](findings/2026-07-08-armbian-builder-setup.md) |
