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
| 1 | Kernel forward-port | ⚠️ The July 4 codec results remain the production baseline. On the installed KASAN build, patches `0042`/`0043` have clean memory scans, the corrected 12-case official-MPP matrix passes, and the FFmpeg codec/bit-exact PSNR gates pass. Patches `0044`/`0045` close the two RGA ABI gaps: rebuilt KASAN debug build `Pb999-C4ad2` booted and passed the full ABI replay (`abi_status=0`), the 12-case MPP matrix, and the full FFmpeg codec/bit-exact PSNR suite, all with clean memory scans — the complete current tip is hardware-validated for those gates. The RGA series through `0051` (10-bit strides/offsets, RGA2 page-table DMA ownership, over-4G service via swiotlb bounce) is BOOT-VERIFIED on debug build `P7589-C4ad2` with the full smoke/ABI/MPP/FFmpeg sweep green and clean scans. **Distribution blocker found on that same KASAN boot, fix staged:** the `cross` session-close reproducer tripped a slab-use-after-free on the `rga_request` object — the RGA2 IRQ completion path (`rga_request_release_signal` → `wake_up`) races `/dev/rga` close (`rga_request_session_destroy_abort` → `kfree`), with a refcount underflow, distinct from the buffer force-free `0040` already fixed. Root-caused to a double-drop of the request's initial reference by four unserialised retire paths; fixed by `0052@c46bfd6622ba6` (idempotent `rga_request_release_ref()` under the manager lock), compiled clean, **booted gate (a quiet `cross` run) pending the next debug build** ([UAF finding](./findings/2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md)). **Second, fatal distribution blocker on the same boot (not yet fixed) — now with a repeatable trigger:** the `vp90-2-10-show-existing-frame2.webm` VP9 vector corrupts MPP/`rk_vcodec` buffer state (the `rockchip-vaapi` VA-API path segfaults; direct RKMPP throws invalid ref-count/buffer-slot assertions), and ~47 s later a *deferred* fault hard-locked the board (`Unable to handle kernel paging request at dfff800000000363`, near-NULL deref). Root-cause candidate: the async worker `mpp_task_worker_default()` (`mpp_common.c:1003`) derefs `task->session->mpp` unguarded — unlike the ioctl path at `:615` — so a pending task whose client was torn down (`not find client 0`) NULL-faults. **Kernel fix implemented** (`0053@98232d5c06fab`, checkpatch-clean): the worker fetches the device via `mpp_get_task_used_device()` and drops the orphan on NULL, and the orphan pop/free/running paths are made NULL-safe (`pop_pending` no longer refuses NULL-device tasks — which had spun/leaked the abort path). The upstream trigger (VP9 `show_existing_frame` refcount bug in MPP userspace) is unfixed. Gate needs serial/netconsole + the KASAN reproducer since ramoops doesn't persist here ([MPP crash finding](./findings/2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md), [ramoops finding](./findings/2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md)). An unchecked RKVENC2 slice-FIFO overflow and the dependency-blocked GStreamer suite also remain. Clean production build `Pf558-Cb831` predates `0044`/`0045`, is not uploaded or boot-tested, and the Published PPA stops at `0041`. | 2026-07-21 | [kernel status](./kernel-drivers/docs/forward-port-status.md) |
| 2 | BSP-audit fix series | ⚠️ Staged only: the split series diverges from the verified draft and does not compile until patch 0024 is regenerated. | 2026-07-01 | [`cleanup-split/`](./kernel-drivers/patches/cleanup-split/README.md) |
| 3 | DKMS channel | ⚠️ Compiles on 6.18; its DT overlay is dtc-validated but not boot-validated. | 2026-07-01 | [`packaging/dkms/`](packaging/dkms/README.md) |
| 4 | Clean-room rewrite drivers | 🚧 Current 6.18/mainline source tips incorporate the five applicable Rockchip 5.10 RGA reliability/cache-safety lessons and pass warning-free normal/memory/race clean-source gates. The post-reconciliation audit added booted 206-case KUnit evidence, before/after dmesg rejection, stronger safety/idle counters, required official-MPP core coverage, AVS2, and low-delay slice-poll cases; all device-free bad-fixture/build wiring passes. Existing package composites predate the source tip, and no current rewrite kernel has booted hardware proof. | 2026-07-17 | [conformance-gap audit](./kernel-drivers/docs/rewrite-conformance-gap-audit.md) |
| 5 | ffmpeg tree | ⚠️ Public refs for canonical `main`, `ffmpeg-80`, and `ffmpeg-81` remain at the source/FATE-validated tips. The normal PPA uses separate 8.0 branch `fix/rkmpp-output-timeout@da5befc806`; it is built/Published but still needs the combined GRD runtime gate. The canonical tips and AV1 MP4/MKV path still lack new board validation. | 2026-07-19 | [FFmpeg status](./video-libraries/ffmpeg/README.md) |
| 6 | ffmpeg submissions | ❌ The targeting plan exists, but no patch has been submitted. | 2026-07-02 | [`submission-plan.md`](./video-libraries/ffmpeg/docs/submission-plan.md) |
| 7 | GNOME Remote Desktop backend | ⚠️ Public release branch `release/50.2-rkmpp@cf60b4d` carries 15 clean release commits on upstream 50.2. It keeps the 60 fps RKMPP path, cached-readback root fix, bounded encode recovery, reconnect fixes, and live-validated progress-gated ACK recovery. The diagnostic pipeline watchdog/thread, idle-baseline workaround, routine ACK messages, audio format/flow traces, Opus suppression, and legacy-format probe are archived rather than shipped. Exact source/native arm64 builds and RDP integration pass; normal-PPA source `18632058` is accepted and build `33422570` is running. Install and final focus/resume validation remain. | 2026-07-21 | [`release patches`](./apps/gnome-remote-desktop/patches/README.md), [`audio diagnosis`](./apps/gnome-remote-desktop/docs/audio-redirection.md), [`ACK wedge`](./findings/2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md) |
| 8 | Mesa / Panfrost | 🔄 Four MRs remain open; selected G610 reruns pass and !42679 needs a rebase. | 2026-07-11 | [`video-libraries/mesa/`](video-libraries/mesa/README.md) |
| 9 | Launchpad PPA | ⚠️ GRD 50.2 source `18632058` is accepted/Pending in the normal PPA and arm64 build `33422570` is running. The rest of the normal system stack, both dedicated FFmpeg comparisons, both rewrite-kernel replacements, and experimental GRD `~exp3` have Published sources and successful arm64 builds. Optional GDM upload and board migration/kernel/GRD runtime gates remain open. | 2026-07-21 | [`packaging/ppa/`](packaging/ppa/README.md) |
| 10 | Binary publishing | ❌ No built binaries are committed and no GitHub Release exists. | 2026-07-01 | [`packaging/`](packaging/README.md) |
| 11 | Kodi HW decode | 🚧 Decoder selection, MPP, and FFmpeg prerequisites are ready; Kodi build, playback, and packaging are unproven. | 2026-07-11 | [`apps/kodi/`](apps/kodi/README.md) |
| 12 | ROCK 5B SD/SPI boot chain | ⚠️ SPI → NVMe works; failing vendor raw artifacts have zero-byte U-Boot control DTBs, while the untested 26.5.1 `current` candidate has a valid DTB. | 2026-07-11 | [U-Boot comparison](./boot-firmware/docs/version-comparison.md) |
| 13 | Maximum-mainline kernel | 🚧 The pinned upstream 7.2-rc3 `public` and `wip` integrations are reproducible, and both passed native arm64 kernel, package, payload, and external-module-headers checks. Neither has been installed, booted, or hardware-tested. | 2026-07-17 | [`kernel-maxline/`](./packaging/ppa/kernel-maxline/README.md) |
| 14 | Desktop-app HW video (browsers) | 🚧 Survey of the enablement landscape (three roads: VA-API driver, `libv4l-rkmpp` Chromium shim, maxline kernel V4L2) is mapped. Phase one of the leading road executed: the `rockchip-vaapi` VA-API-over-MPP driver was forked to `yisding/rockchip-vaapi@ysp/cleanup`, built against the ysp stack, and three bit-exactness bugs found and fixed — H.264 (ref×bframes matrix + 4K) and VP9 (×10) now bit-exact vs software via ffmpeg-vaapi, packaged as a `.deb`. Since the driver only shims bitstream/surfaces (MPP + `mpp_rkvdec2` do the decode), those bit-exact results also independently re-validate the forward-port's H.264/VP9 rkvdec2 decode on the current tip (build `#5` `P9636-C4ad2`, RGA `0044`–`0051`) — smoke-scope, 8-bit, Profile 0. The substantive renovation (zero-copy buffer model, drain-thread sync, HEVC writer, 10-bit NV15→P010) and any real Firefox/Chromium end-to-end run remain. | 2026-07-21 | [enablement map](./docs/app-enablement.md), [driver review](./findings/2026-07-21-rockchip-vaapi-driver-review.md) |

## Next gates

A next gate is the smallest result that would materially advance its track, not
a general wish list. The action path points to the maintained runbook, exact
evidence owner, or decision boundary; keep it usable when a gate changes. Close
or replace a gate only with evidence from the owning detail page, and update the
dashboard date and ledger row when public state changes.

| # | Track | Next proof | Action path |
|---|-------|------------|-------------|
| 1 | Kernel forward-port | Fix the RGA2 DMA-sync and RKVENC2 overflow paths, install the GStreamer development dependencies, finish the KASAN matrix, then rebuild/upload a production image with the complete patch tail, repeat the green gates on it, and validate rollback. | [RGA2 DMA-sync gate](./findings/2026-07-20-rga2-unmapped-page-table-dma-sync.md#verification-gate), [slice-FIFO gate](./findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md#verification-gate) |
| 2 | BSP-audit fix series | Regenerate patch 0024 and prove the full split series compiles. | [Compile defect and remedy](./kernel-drivers/patches/cleanup-split/README.md#cleanup-split-compile-gate) |
| 3 | DKMS channel | Install on a stock 6.18 ROCK 5B, boot the overlay, and run `validate-combined.sh`. | [DKMS build and install](./packaging/dkms/README.md#dkms-build-install) |
| 4 | Clean-room rewrite drivers | Rebuild/package one current July 17 source tip; persist 206 green booted KUnit results, then capture paired clean-dmesg/counter/artifact evidence including AVS2 and H.264/H.265 low-delay slice polling. | [Remaining rewrite hardware gates](./kernel-drivers/docs/rewrite-conformance-gap-audit.md#remaining-gaps-and-hardware-gates) |
| 5 | ffmpeg tree | Re-test AV1 from MP4 and MKV through `av1_rkmpp` on RK3588. | [AV1 follow-up evidence](./findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md#av1-follow-up) |
| 6 | ffmpeg submissions | Submit the first patch from the ordered upstream/fork plan and record its review URL. | [Suggested first wave](./video-libraries/ffmpeg/docs/submission-plan.md#suggested-first-wave) |
| 7 | GNOME Remote Desktop backend | After build `33422570` publishes, install the clean 50.2 `~rk1`, repeat the macOS focus-away/return video gate, and confirm audible PCM with the normal codec offer. A-law implementation remains explicitly deferred. | [Focus/resume acceptance gate](./apps/gnome-remote-desktop/docs/testing.md#10-exp6exp7-macos-focusresume-gate), [audio release boundary](./apps/gnome-remote-desktop/docs/audio-redirection.md) |
| 8 | Mesa / Panfrost | Rebase !42679 and rerun its selected CI coverage. | [MR tips and selected CI](./video-libraries/mesa/README.md#mr-status) |
| 9 | Launchpad PPA | Install, boot, and revert the co-installable forward-port kernel on the ROCK 5B. | [Kernel package checklist](./packaging/ppa/kernel-forward-port/README.md#remaining-checklist) |
| 10 | Binary publishing | Choose and record the repository-wide license required before a public release. | [License decision boundary](./LICENSE.md) |
| 11 | Kodi HW decode | Build Kodi GBM/GLES and validate RKMPP playback with `kodi-gbm` on tty1. | [Kodi tty1 runbook](./apps/kodi/docs/build-hwaccel.md#5-test-on-tty1-gbm-needs-drm-master) |
| 12 | ROCK 5B SD/SPI boot chain | Substitute the 26.5.1 `current` FIT, loader, and then both on a captured 26.2.1 SD baseline; record where each boot stops or succeeds. | [Raw-SD hypothesis test](./scripts/README.md#rock-5b-raw-sd-u-boot-hypothesis-test) |
| 13 | Maximum-mainline kernel | Install the `public` profile first with the known-good 6.18 packages and physical/serial recovery retained; prove explicit boot, storage, network, display, suspend, and rollback before trying `wip`. | [Recovery-first install and test order](./packaging/ppa/kernel-maxline/README.md#install-and-test-order) |
| 14 | Desktop-app HW video (browsers) | Close Phase 0 of the production roadmap: swap synthetic clips for real conformance vectors, add an ASan gate + CI skeleton, and run the `.deb` end-to-end in Firefox — then start Phase 1 (object heap, external-buffer-group zero-copy, per-context worker sync). | [Production roadmap](https://github.com/yisding/rockchip-vaapi/blob/ysp/cleanup/docs/ROADMAP.md), [phase-one results](./findings/2026-07-21-rockchip-vaapi-driver-review.md#9-phase-one-results-measured-board-validated-2026-07-21) |

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
| W05 | [Launchpad PPA publication](#watch-w05) | 2026-07-19 | Latest normal FFmpeg, GRD `~exp3`, and both rewrite-kernel replacements are Published with successful arm64 builds. |
| W06 | [Mesa MR stack](#watch-w06) | 2026-07-11 | Four MRs open; !42679 needs a rebase. |
| W07 | [`ffmpeg-rockchip-81` tips](#watch-w07) | 2026-07-19 | Canonical public tips unchanged; separate normal-PPA timeout branch remains at `da5befc806`. |
| W08 | [AV1 container-extradata validation](#watch-w08) | 2026-07-16 | Fix carried forward; board re-test pending. |
| W09 | [Kodi build and tty1 playback](#watch-w09) | 2026-07-11 | Prerequisites ready; build/playback/package pending. |
| W10 | [GRD reconnect validation/submission](#watch-w10) | 2026-07-21 | The reconstructed-ACK recovery is live-validated, the idle-time false starvation actuator is source-fixed, and installed `exp9` audibly validates PCM RDP output after the PipeWire migration; repeated focus/resume video validation, compressed-audio interoperability, publication/promotion, and upstream review remain. |
| W11 | [Repository-wide license](#watch-w11) | 2026-07-11 | No repository-wide license granted. |
| W12 | [Dev-box-only artifacts](#watch-w12) | 2026-07-11 | Identified code/package artifacts are captured. |
| W13 | [librga P010/P210 series](#watch-w13) | 2026-07-21 | On `P63dd-C4ad2` the `0048` stride fix makes P010 luma bit-exact; chroma still lands wrong because `rga_convert_addr()` derives UV offsets at 1 byte/px — fixed by kernel patch `0049`, booted chroma gate pending. |
| W14 | [YSP Armbian builder](#watch-w14) | 2026-07-20 | Exact-6.18.38 clean production build `Pf558-Cb831` completed BTF and Debian packaging; the wrapper now pins source and purges stale debug-build Kbuild metadata. |
| W15 | [RGA session-close fix vs. base patch](#watch-w15) | 2026-07-17 | Force-free UAF fixed in fwport patch `0040`; frozen base patch still has the old path. |
| W16 | [Forward-port kernel-fix tail](#watch-w16) | 2026-07-21 | RGA fixes `0046`–`0048` pass their booted gates on `P63dd-C4ad2` (legacy blits, `EOPNOTSUPP` probe, P010 luma bit-exact; smoke/MPP/FFmpeg/ABI replay all green, smoke fully green for the first time). The `0048` gate exposed the `0049` UV plane-offset fix; `0049`–`0051` (UV offsets, RGA2 page-table DMA ownership + device DMA parameters, over-4G service via swiotlb-bounced DMA mappings) are committed and checkpatch-clean with booted gates pending the next debug build. Slice-FIFO hardening, GStreamer, publication, exact-image validation, and rollback remain. |
| W17 | [Maximum-mainline proposal-set drift](#watch-w17) | 2026-07-17 | The build is reproducible at pinned inputs; any claim about the broadest current public proposal set requires a deliberate manifest refresh. |
| W18 | [rockchip-vaapi fork state](#watch-w18) | 2026-07-21 | Fork `yisding/rockchip-vaapi@ysp/cleanup` holds the phase-one work; upstream woodyst has been quiet since 2026-05-28. |

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
- **Last checked:** 2026-07-19
- **State then:** Launchpad's API and exact-version binary queries showed the
  current package lines Published. In the normal PPA, FFmpeg source
  [`18628833`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18628833)
  carries `da5befc806`; arm64 build
  [`33417109`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33417109)
  succeeded and the exact `ffmpeg` binary is Published. The two Armbian-based
  rewrite replacements are also Published: 6.18.38 source/build
  [`18623665`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+sourcepub/18623665) /
  [`33406491`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+build/33406491)
  and 7.2-rc3 source/build
  [`18623666`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+sourcepub/18623666) /
  [`33406492`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+build/33406492).
  Experimental GRD `~exp3` source
  [`18626586`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+sourcepub/18626586),
  successful build
  [`33412698`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+build/33412698),
  and its exact arm64 binary are Published. The normal PPA has no dependency on
  the experimental archive. The optional GDM ACL package was not uploaded, and
  no PPA kernel had passed its board gate.

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
- **Last checked:** 2026-07-19
- **State then:** `git ls-remote` confirmed published tips remain
  `main@8b57e531d1fc` over
  `FFmpeg/master@ceabc9b306f5`, `ffmpeg-80@be753f3bbb2c` over
  `release/8.0@435ae0581deb`, and `ffmpeg-81@8d3ca020b6a2` over
  `release/8.1@94138f6973dd`. The former PR #1/refactor lineage is integrated
  into all three. Source builds and `fate-source` passed; no new hardware or
  package validation was performed for those tips. The dedicated PPA remains
  at `be367abfe6`; separate normal-PPA branch
  `fix/rkmpp-output-timeout@da5befc806` is public, built, and Published, with
  its combined GRD hardware gate still pending.

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

- **Why recheck:** The corrected series must survive the exact macOS
  focus-away/focus-return sequence before promotion, and the submission claim
  needs a public review artifact.
- **Last checked:** 2026-07-20
- **State then:** Diagnostic `~exp2` and recovery `~exp3` narrowed the original
  graphics-thread stall; the latter is Published as source `18626586` and build
  `33412698`. Subsequent local `exp5@b3f0e20` hardware testing proved exported
  patch `0017` removes the uncached imported-buffer readback hang. The fluid
  session then exposed a distinct intermittent encode fallback: MPP refused a
  frame under transient input-pool pressure, while FFmpeg `540657970e` waited
  for output from that never-submitted frame. Wrapper fix `da5befc806` is
  Published in the normal PPA. The next macOS focus-return wedge was captured
  independently: the resumed connection retained 908 reconstructed frame ACKs
  and zero frame slots despite live input/transport and healthy hardware.
  Cleaned patch `0018@34145d9` adds transition logs and a progress-gated
  two-second recovery. Its functional `~exp6@7e958e6` predecessor passes tests
  and a local arm64 package build and is installed. The watchdog fired once
  with two stalled ACKs, forced refresh, and restored hardware submissions,
  runtime-validating that recovery. The same live run caught a second failure:
  GDB showed the first new work after focus return was about
  1 ms old but inherited a 42.493-second pre-idle submit age and immediately
  fired the software cooldown. Patch `0019@3e4480e` gives newly outstanding
  work a fresh watchdog window. The final source and native arm64 `exp7`
  package builds pass. Installed `exp8` with diagnostic patch `0020` captured
  the Microsoft macOS client's sole exact stereo PCM format. Installed `exp9`
  adds patch `0021`'s channel/training/PipeWire PCM/`SNDC_WAVE2`/wave-confirm
  markers and temporarily removes Opus from the server offer. Its live trace
  reached nonzero capture, PCM sends, and confirmations; after the PipeWire
  migration reboot, the client rendered audible audio. A Windows control
  rejects playback DVC with the same status and appears to use ADPCM or A-law
  over SVC, so the next codec step is to identify the exact returned tuple,
  not to chase DVC. Repeated focus/resume video validation,
  publication/promotion, compressed-audio implementation, and an upstream
  GNOME review remain.

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
- **Last checked:** 2026-07-21
- **State then:** The series from `2cffdf6` through `main@a632217` was exported
  under [`vendor-libraries/rga/patches/`](./vendor-libraries/rga/patches/README.md).
  On `P63dd-C4ad2` (kernel `0048` stride fix) the direct im2d P010 probes
  show luma bit-exact; the remaining chroma corruption is the kernel's
  `rga_convert_addr()` deriving UV plane offsets at 1 byte/px, fixed by
  kernel patch `0049@a398364aaf8ed` (booted chroma gate pending). The
  FFmpeg Main10→P010 case shows the matching signature (y≈61 dB,
  u/v≈4.6 dB). The smoke's 10-bit im2d cases (luma-asserting) pass with
  `LIBRGA_SMOKE_10BIT=1` on the source-built fork. Linear NV15
  input is separately not RGA-expressible at 1920 wide. See the
  [root-cause finding](./findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md)
  and [shipping guidance](./vendor-libraries/rga/docs/librga-p010-p210-rkrga.md).

<a id="watch-w14"></a>
### W14 — YSP Armbian builder

- **Why recheck:** Builder resources, supported releases, branch mapping, and
  Armbian trunk behavior can shift without a repo change.
- **Last checked:** 2026-07-20
- **State then:** Exact Linux 6.18.38 build `Pf558-Cb831` completed native
  arm64 compilation, BTF, image/modules/DTBs/headers, and Debian packaging in
  109 minutes. The wrapper pins commit `e46dc0adfe39724bcf52cea47b8f9c9aed86a394`,
  rejects stale unknown user configs, removes its tracked heavy-debug override,
  and forces `CLEAN_LEVEL=make-kernel` for that config-class transition so old
  dependency metadata cannot corrupt the production build. The original VM
  setup remains documented in the [builder finding](findings/2026-07-08-armbian-builder-setup.md).

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
### W16 — Forward-port kernel-fix tail

- **Why recheck:** The frozen base pair, maintained split series, PPA package,
  and booted debug build can silently carry different kernel-fix tails. Keep the
  exported patch tail and the claimed production gate aligned with the exact
  KASAN evidence.
- **Last checked:** 2026-07-21
- **State then:** The maintained series now exports all three fixes: `0041`
  unlinks MPP sessions before private teardown; `0042@83e4d357f8d2` clears
  `session->dma` after RESET_SESSION destroys it; and
  `0043@655d178191807` samples the RKVENC2 abort flag before the final task
  reference can free the object. Run `20260718-093751-kasan-narrowed` verifies
  `0042` with zero flagged lines. Run `20260718-103917-kasan-mpp-suite`
  exercises `0042`/`0043` with empty KASAN/fatal scans and passing ordinary
  encode cases. Corrected run `20260720-213128-kasan-mpp-suite` proves the
  apparent multi-instance H.265 and slice failures were harness defects; all
  three 120-frame cases pass, and full `20260720-213542-mpp-suite` passes the
  selected 12-case matrix. An abusive split control separately found an open
  RKVENC2 slice-FIFO overflow. Patches `0044@72accfd1d5a14` and
  `0045@27452e30a2cfd` fix the two RGA ABI replay gaps: `rkvenc-fwport-6.18`
  was fast-forwarded to `27452e3`, rebuilt as KASAN debug build `Pb999-C4ad2`,
  installed, and booted, and run `20260721-034716-kasan-narrowed` passed the
  full ABI replay (`abi_status=0`) with a clean memory scan. The same boot
  re-ran the 12-case MPP matrix (`20260721-042445`) and full FFmpeg
  codec/bit-exact PSNR suite (`20260721-042631`) green with clean scans. The
  librga smoke's `no core match` flakiness was then root-caused and fixed in
  the harness (13 cases green), and new RGA fixes `0046@e1d6d47d9565d`
  (legacy-virtual `0045` regression), `0047@0388a3efc829a` (under-4G
  `EOPNOTSUPP` reporting), and `0048@8e641bcd48a38` (byte-literal 10-bit
  raster strides, the measured P010 corruption) passed their booted gates on
  rebuilt debug build `P63dd-C4ad2`: legacy blits succeed, the exclusion
  probe returns `EOPNOTSUPP` with the explanatory log, P010 luma is
  bit-exact, the librga smoke is fully green for the first time (28 cases,
  `LIBRGA_SMOKE_10BIT=1`), ABI replay `20260721-081456` and the 12-case MPP
  matrix `20260721-081639` are clean, and FFmpeg `20260721-081448` passes
  all 14 required cases plus bit-exact AV1 PSNR. The `0048` gate exposed a
  final 10-bit defect — `rga_convert_addr()` places UV planes at 1 byte/px
  offsets — fixed by `0049@a398364aaf8ed` (booted chroma gate pending its
  debug build). DMA-debug also flagged the missing
  `dma_set_max_seg_size()` on the rga2 device (96 KiB CMA segments vs the
  64 KiB default). Patches `0050@473903525009a` and `0051@162edad7bb9c7` implement the renumbered DMA scope: the page tables become owned streaming DMA mappings of the RGA2 device (plus `dma_set_max_seg_size` and a page-preserving swiotlb min-align mask), and over-4G buffers are served on RGA2 through DMA-API mappings of the 32-bit device with `EOPNOTSUPP` fallback. On debug build `P9636-C4ad2` (`#5`, carrying `0049`–`0051`) the `0049` and `0050` gates pass: P010→P010 copies are bit-exact including chroma, P010→NV12 chroma is neutral, FFmpeg `hevc_main10_p010_rga` flips to PSNR `inf/inf/inf` (run `20260721-110029`), and smoke (28 ok)/MPP (12/12)/ABI (`20260721-110007`) are green with a completely clean DMA-debug/KASAN journal — both the July 20 page-table splat and the segment-size warning are gone. The `0051` gate ran the over-4G system-heap imcopy on RGA2 (no more `EOPNOTSUPP`) but read back stale destination data on two successive debug builds, exposing two copy-back defects: the post-clean was wrongly guarded with `!iommu_mapped` (excluding default-map-core origins; fixed on `P9636`, keyed on bounce direction), and — first-order, exposed by the `P9412` (`#6`) re-run — the transient dst bounce inherited the channel get-side `DMA_TO_DEVICE`, so swiotlb never copied the device output back at unmap. Fixed in the amended `0051@162edad7bb9c7` (every transient bounce mapped `DMA_BIDIRECTIONAL`, matching the persistent mappings); the content-exact gate awaits the next debug build. A mixed-heap differential matrix on `P9412` isolates the defect to the dst leg alone: src-only bounces (system→CMA) and the userptr bounce branch (malloc→CMA) are content-exact, and the mapping-failure fallback gate passes — 128 MiB over-4G buffers fail cleanly with `EOPNOTSUPP` plus the explanatory log (swiotlb's 256 KiB per-mapping cap, not pool exhaustion, is the practical bound: over-4G buffers with ≥1 MiB exporter chunks always take the fallback). The same boot closed the last `0048` caveat — the compact-NV15 raster leg is hardware-validated by the new `rga-nv15-test` probe (semantic NV15→NV12 read, CPU-unpacked P010→NV15 write, bit-exact NV15 copy at 256/320/1920 widths). On debug build `P7589-C4ad2` (`#7`, the amended `0051`) the gate CLOSES: the full differential matrix is content-exact (both-legs, dst-only, and userptr bounces), the fallback stays clean `EOPNOTSUPP`, and the same-boot smoke (28 ok)/P010/NV15/ABI (`20260721-145234`)/MPP (`20260721-145243`)/FFmpeg (`20260721-145258`, 24/24, Main10 PSNR inf) sweep is green with a zero-flagged-line journal — `0044`–`0051` are BOOT-VERIFIED on one kernel. (Watchlist: `P7589`'s first boot attempt hung with no oops/pstore capture and needed a hard reset; the second boot was clean — watching for recurrence.)
  Clean exact-6.18.38 production build `Pf558-Cb831` and the freshly extracted
  unsigned 20260720 PPA source package carry both lifetime fixes with the
  non-debug AV1/RGA config but predate `0044`/`0045`. The Published kernel still
  stops at `0041`, so RGA/GStreamer
  completion, upload/Launchpad build, exact-image board conformance, and
  rollback remain open. Evidence:
  [procfs fix](findings/2026-07-17-mpp-procfs-session-teardown-oops.md),
  [RESET_SESSION fix](findings/2026-07-18-mpp-reset-session-dma-double-free-kasan.md),
  [RKVENC2 fix](findings/2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md),
  [RGA ABI fixes](findings/2026-07-21-rga-forward-port-abi-gaps.md), and
  [slice-FIFO finding](findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md).

<a id="watch-w17"></a>
### W17 — Maximum-mainline proposal-set drift

- **Why recheck:** Upstream Linux, public proposal revisions, and integration
  branches move independently. The checked-in profiles remain reproducible,
  but "maximum current public support" becomes stale without changing this
  repository.
- **Last checked:** 2026-07-17
- **State then:** The exact upstream `v7.2-rc3` base, public integration
  `f12fb0acf7bb`, WIP integration `74b24e96da62`, 38 public series
  dispositions, and 26 WIP donors were pinned in
  [`manifest.yaml`](packaging/ppa/kernel-maxline/manifest.yaml),
  [`public-series.tsv`](packaging/ppa/kernel-maxline/public-series.tsv), and
  [`wip-donors.tsv`](packaging/ppa/kernel-maxline/wip-donors.tsv). Both profiles
  compiled and packaged; neither booted. Refresh those ledgers and preserve the
  old identities before claiming a newer proposal set.

<a id="watch-w18"></a>
### W18 — rockchip-vaapi fork state

- **Why recheck:** The VA-API-driver track lives in an external fork, not this
  repo; the fork branch and the upstream it descends from move independently
  of any change here.
- **Last checked:** 2026-07-21
- **State then:** The phase-one correctness/packaging work is committed to
  `git@github.com:yisding/rockchip-vaapi.git` branch `ysp/cleanup` (built
  `rockchip-vaapi_1.0.11+ysp1_arm64.deb`, board-validated). `origin` is
  upstream `woodyst/rockchip-vaapi@e8c64dd` (v1.0.11), quiet since
  2026-05-28. The ysp source of truth for the *decision and evidence* is
  [`findings/2026-07-21-rockchip-vaapi-driver-review.md`](./findings/2026-07-21-rockchip-vaapi-driver-review.md);
  the *code* is only in the fork. If the renovation proceeds, re-check whether
  upstream has revived (offer changes back) before diverging further.
