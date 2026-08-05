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
| 1 | Kernel forward-port | ⚠️ **2026-08-04:** source/export, Published binaries, and installed image/DTB/headers are the exact `7d53bc7a3adc` / `0001`–`0092` / `6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1` artifact. It boots as `6.18.42-ysp-rockchip64` with taint `0`. ABI, 12/12 MPP, 21/21 required plus 3/3 diagnostic FFmpeg, direct librga/RGA, decoder liveness/quality, IOMMU machinery, VP9/RGA recovery, broad VA-API, and bounded fatal-log gates are green; GStreamer is 100/102 with two classified userspace semantics failures and no kernel fault. The two-hour dual-codec encode soak passes flat and clean. The two-hour 4K decode workload and kernel scan pass, but its strict resource oracle is red because four transient loop-boundary samples make a 36-fd span against the 32-fd limit despite medians falling 56→54. This is a green kernel functional/recovery verdict with a non-green userspace soak oracle, not KASAN/lockdep proof; root counters, authenticated RDP/display integration, and targeted hostile paths remain. The SD-card rescue + `kernel-revert.sh` commands are operator-validated. | 2026-08-04 | [production validation](./findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md), [fix finding](./findings/2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md), [kernel package](./packaging/ppa/kernel-forward-port/README.md), [series status](./kernel-drivers/docs/forward-port-status.md) |
| 2 | BSP-audit fixes | 🚧 All 11 remaining distinct HIGH audit bugs are ported as `0058`–`0068`; the combined tail passed KASAN, destructive-path, production conformance, and root gates. Several fixes still lack individual hostile-path tests, and the older 65-patch MEDIUM/LOW cleanup series remains unshippable. | 2026-07-24 | [audit ledger](./docs/status-ledger.md), [patch catalog](./kernel-drivers/docs/patch-catalog.md) |
| 3 | DKMS channel | ⚠️ Compiles on 6.18; its DT overlay is dtc-validated but not boot-validated. | 2026-07-01 | [`packaging/dkms/`](packaging/dkms/README.md) |
| 4 | Clean-room rewrite drivers | 🚧 **2026-08-05:** maintained tips are 6.18 `37ae7459656b` on `v6.18.42` and mainline `02bf372dac70` on `v7.2-rc6`; tracked rewrite sources, Kconfig, ABI ledgers, and UAPI are byte-identical. Both pass the warning-fatal clean-archive `normal` build and the 305-signal audit with zero new or absent signals. Predecessor KASAN boot `#2 g19634f4eebba` passes the exact **92 MPP + 152 RGA** manifest, clean outer interval, and live lockdep; official MPP is 12/12. Its librga run runtime-verifies the earlier handle-plane repair, then exposes oversized RGA2 SWIOTLB segments and legacy fd-zero fence handling. Both are source-fixed at the new tips, along with a misleading successful-fallback diagnostic and inverted official-sample success classification, but the fixes are not boot-verified. AV1/VSI, recovery, performance, fuzz, soak, and the proposed ownership refactor remain open. | 2026-08-05 | [librga root cause and fix](./findings/2026-08-05-rewrite-rga-librga-swiotlb-fence-status.md), [current rebase/build finding](./findings/2026-08-04-rewrite-kernel-rebase-6-18-42-7-2-rc6.md), [architecture guide](./kernel-drivers/docs/rewrite-driver-architecture/README.md), [KUnit fixture and evidence contract](./kernel-drivers/docs/rewrite-kunit.md), [AV1 assessment](./kernel-drivers/av1/docs/av1-rewrite-assessment.md) |
| 5 | ffmpeg tree | ⚠️ Package branch `fix/rkmpp-output-timeout@c9428bedaa` fixes the asynchronous `MppFrame` reset/close double release. The affected object, `fate-source`, source package, and focused RK3588 gates pass: 10/10 immediate-close plus 10/10 flush/reuse, without the old libmpp refcount/pool diagnostics. Published and installed packages remain at predecessor `33a651a55b`; candidate installation and the real GRD fallback/recreation gate are pending. Canonical-tip and AV1 MP4/MKV board validation remain open. | 2026-07-30 | [lifetime fix](./findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md), [FFmpeg status](./video-libraries/ffmpeg/README.md) |
| 7 | GNOME Remote Desktop backend | 🚧 Public `release/50.2-rkmpp@c4ef3c9` rebases all 16 existing release changes patch-identically onto latest GNOME 50 stable and adds a narrowed reconnect-timeout repair: only a display explicitly reassigned into the persistent user handover survives timeout, keeping its `RemoteId` listener so the next authenticated attempt can retry without restarting the daemon. **`50.2+rkmpp+git20260729.15.c4ef3c9-0ubuntu1~rk2` is installed** (2026-08-02 14:54), the system daemon is enabled and listening on 3389, and the booted `6.18.42-ysp-rockchip64` sets neither `CONFIG_DMABUF_DEBUG` nor `CONFIG_KASAN`, so both stated preconditions for the reconnect gate are now met. The gate itself has **not** run: it needs an authenticated RDP client, and the system credentials are root-only. Separately, the encoder watchdog/forced-IDR/VBR-ceiling work is built and verified present in `fix/forced-idr-recovery@100da72` (which sits directly on the released `c4ef3c9`) but is **absent from the installed binary** and has never been run. | 2026-08-04 | [reconnect audit and fix](./findings/2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md), [encoder watchdog](./findings/2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md), [testing](./apps/gnome-remote-desktop/docs/testing.md) |
| 8 | Mesa / Panfrost | 🔄 **2026-08-04:** all four MRs remain open and unmerged, but the rebase need moved: !42679 was updated 2026-07-23 and is conflict-free, while **!42614 now reports `need_rebase`**. !42613/!42614 still carry the exact heads whose selected G610 shards passed, so that evidence stands; !42679's green pipeline predates its new head and needs a rerun. | 2026-08-04 | [`video-libraries/mesa/`](video-libraries/mesa/README.md) |
| 9 | Launchpad PPA | ✅ **2026-08-05:** the forward-port kernel publication milestone is closed: `6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1` (`0092`) source and build are Published/successful, all three arm64 packages are in the live PPA index, and the exact image, DTB, and headers are installed and previously booted through broad production validation. MPP `1.5.0+git20260805.a8b19653+ds-0ubuntu1~rk1` is likewise Published, selected from the normal PPA, installed, and runtime-validated through its retained VP9 oracle, 120-process stress, four-codec differential, and 12/12 official suite. The documented SD rescue + `kernel-revert.sh` path is operator-validated. The clean-install transaction remains a separate migration test for machines carrying incompatible stacks, not an open kernel-publication condition. | 2026-08-05 | [`packaging/ppa/`](packaging/ppa/README.md), [MPP package closure](./findings/2026-08-04-libmpp-vp9-show-existing-reference-slot-leak.md#installed-ppa-package-closure), [kernel production validation](./findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md), [recovery finding](./findings/2026-08-04-forward-port-sd-rescue-rollback-used.md) |
| 10 | Binary publishing | ❌ No built binaries are committed, and the last `gh release list` check (2026-08-04) found no GitHub Release. The repository-owned license gate closed on 2026-08-05: Yi Ding's non-code contributions are CC BY-SA 4.0 and code contributions follow their upstream target, with only Yi Ding's own original kernel contributions GPL-2.0-or-later. Upstream kernel code retains its existing license. No release artifact set or checksummed manifest has been selected yet. | 2026-08-05 | [`packaging/`](packaging/README.md), [`LICENSE.md`](LICENSE.md) |
| 11 | Kodi HW decode | 🚧 Decoder selection, MPP, and FFmpeg prerequisites are ready; Kodi build, playback, and packaging are unproven. Re-checked 2026-08-04: the PPA still publishes no Kodi source and no build evidence has entered the repo, but the GBM/GLES build and tty1 playback are board state and stay unverified since 2026-07-11. | 2026-08-04 | [`apps/kodi/`](apps/kodi/README.md) |
| 12 | ROCK 5B SD/SPI boot chain | ⚠️ SPI → NVMe works; failing vendor raw artifacts have zero-byte U-Boot control DTBs, while the untested 26.5.1 `current` candidate has a valid DTB. | 2026-07-11 | [U-Boot comparison](./boot-firmware/docs/version-comparison.md) |
| 13 | Maximum-mainline kernel | 🚧 **2026-08-02:** refreshed `public`/`wip` sources pin Linux `7.2-rc6` at Torvalds `master@075b74841bd0`, with validation branches on `next-20260731@415606a7be93`; revised proposals and subsystem-next acceptances are reconciled. Linus/public passes the full native compile gate; linux-next/WIP passes focused and partial builds, with its full build stopped by request. Refreshed packages, boot, and hardware validation remain open. | 2026-08-02 | [refresh audit](./findings/2026-08-02-rk3588-maxline-proposal-refresh.md), [`kernel-maxline/`](./packaging/ppa/kernel-maxline/README.md) |
| 14 | Desktop-app HW video (browsers) | 🚧 The published baseline remains `1.0.11+ysp12-0ubuntu1~rk1`; its exact-kernel `0092` broad normal/sanitized decode/encode campaign, HEVC sweep and soaks retain their recorded results. The host now has locally built **`1.0.11+ysp13-0ubuntu1~rk1` installed**; the installed driver matches the deb payload at SHA-256 `ed578a241803f35f51ccc6afe38b1d132539ae48ca691b5a3180e37565fe56c0`. Ysp13's retained-export worker/lifecycle/sanitizer, 17-vector conformance, static-analysis and 1,440-frame zero-copy gates pass. Google Chrome 151 now presents H.264 correctly instead of green and selects `VaapiVideoDecoder` for 640x480 VP9 Profile 0; its 384x240 VP9 software choice matches Chromium's intentional below-360p priority. **H.264, VP9 Profile 0 and HEVC Main remain default**; Main10, VP9 Profile 2 and encode stay opt-in. Ysp13 source is still dirty, uncommitted, changelog-`UNRELEASED` and unpublished. Chrome replay is manual; the stock Google deb was launched with no sandbox-disabling options, yet `chrome://gpu` reports `Sandboxed: false` and the live GPU process has `Seccomp: 0`, zero filters, and an unconfined LSM label. The multiple-thread sandbox-init warning is not yet attributed. XtraDeb Chromium 151 still omits libva. Open: automated H.264/VP9/HEVC Chrome gates and GPU sandbox, ysp13 commit/publication, XtraDeb Chromium packaging, sandbox-enabled Firefox, physical HDR, clean-image install, 512 MiB CMA, the decode fd-span oracle, app/session selection, WebRTC introspection, and the FFmpeg-only same-process TSan race. | 2026-08-05 | [production validation](./findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md), [Google Chrome installed replay](./findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md), [Chromium 151 package boundary](./findings/2026-08-04-chromium-151-gpu-working-v4l2-only.md), [interlaced/IEP2 regression](./findings/2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md), [`rockchip-vaapi` project](./video-libraries/vaapi/README.md) |
| 15 | CPU voltage binning (PVTM/eFuse) | ❌ No patch, branch, or build exists. The board's BSP-selected L5/L7/L7 voltage columns are measured and materially lower than mainline's worst-die table below 2.4 GHz; the two-track port plan is gated by cold-boot, SRAM-margin, and shared-DSU-rail validation. | 2026-07-27 | [port plan](./kernel-versions/docs/pvtm-opp-binning-plan.md), [measured index](./findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md) |

## Next gates

A next gate is the smallest result that would materially advance its track, not
a general wish list. The action path points to the maintained runbook, exact
evidence owner, or decision boundary; keep it usable when a gate changes. Close
or replace a gate only with evidence from the owning detail page, and update the
dashboard date and ledger row when public state changes.

| # | Track | Next proof | Action path |
|---|-------|------------|-------------|
| 1 | Kernel forward-port | Exercise exact `0092` under KASAN/lockdep through RGA cancellation/session-close and decoder recovery/reset contention; then capture root-only debugfs counters and remaining targeted hostile paths. | [production validation gaps](./findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md#remaining-qualification-gaps), [0092 verification gate](./findings/2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md#verification-gate) |
| 2 | BSP-audit fixes | Add targeted hostile-path gates for the acquire-fence, shutdown, missing-plane, and partial-handle fixes that broad conformance does not exercise. | [runtime gate inventory](./kernel-drivers/patches/cleanup-draft/verification.md#runtime-gate-result-record-here-when-run), [port record](./findings/2026-07-22-bsp-high-current-tip-port.md) |
| 3 | DKMS channel | Install on a stock 6.18 ROCK 5B, boot the overlay, and run `validate-combined.sh`. | [DKMS build and install](./packaging/dkms/README.md#dkms-build-install) |
| 4 | Clean-room rewrite drivers | Build and boot a KASAN package from `37ae7459656b`; first require exact 92+152 KUnit and corrected full librga with no SWIOTLB mapping failures or false dma-buf rejection, then complete aged kmemleak, every runtime/core, AV1 AFBC/fault/PM counters, ABI replay, and full conformance. | [librga verification gate](./findings/2026-08-05-rewrite-rga-librga-swiotlb-fence-status.md#boundary-and-verification-gate), [rewrite validation plan](./kernel-drivers/docs/rewrite-validation-plan.md), [qualification contract](./kernel-drivers/docs/rewrite-kunit.md#capture-a-reproducible-result) |
| 5 | ffmpeg tree | Build/install `c9428bedaa`, then repeat GRD hardware timeout, software fallback, and encoder recreation while requiring a clean libmpp/kernel log; afterward re-test AV1 from MP4/MKV. | [lifetime integration gate](./findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md#verification-gate) |
| 7 | GNOME Remote Desktop backend | Installation and the kernel precondition are done; run the measured idle reconnect sequence (connect → idle-lock → drop client ≥ the 900 s `sleep-inactive-ac-timeout` → reconnect), requiring the second attempt to reach GDM→user handover without restarting the daemon while an initial greeter failure still cleans up normally. Blocked only on RDP credentials, which are root-only. Then focus/resume and audio, then install `fix/forced-idr-recovery` to make the watchdog/VBR gates measurable at all. | [reconnect reproduction](./findings/2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md#act-4-latest-gnome-50-rebase-and-narrowed-june-fix-salvage), [watchdog gate](./findings/2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md#verification-gate) |
| 8 | Mesa / Panfrost | Rebase !42614, then rerun selected G610 CI on it and on !42679's post-07-23 head. | [MR tips and selected CI](./video-libraries/mesa/README.md#mr-status) |
| 9 | Launchpad PPA | Kernel and MPP publication/install closure need no further archive proof. Publish and install FFmpeg `c9428bedaa`, then replay its GRD fallback/recreation gate; refresh and exercise the clean-install transaction separately only when a machine actually migrates from an incompatible stack. | [PPA package matrix and migration path](./packaging/ppa/README.md#current-state), [FFmpeg integration gate](./findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md#verification-gate) |
| 10 | Binary publishing | Select the first release's exact source/binary artifacts, verify each artifact's complete corresponding-source and third-party redistribution obligations, then publish a versioned checksummed manifest. | [license scope](./LICENSE.md), [artifact policy](./packaging/README.md) |
| 11 | Kodi HW decode | Build Kodi GBM/GLES and validate RKMPP playback with `kodi-gbm` on tty1. | [Kodi tty1 runbook](./apps/kodi/docs/build-hwaccel.md#5-test-on-tty1-gbm-needs-drm-master) |
| 12 | ROCK 5B SD/SPI boot chain | Substitute the 26.5.1 `current` FIT, loader, and then both on a captured 26.2.1 SD baseline; record where each boot stops or succeeds. | [raw-SD hypothesis test](./scripts/README.md#rock-5b-raw-sd-u-boot-hypothesis-test) |
| 13 | Maximum-mainline kernel | Build and inspect refreshed `public` packages, then install with serial recovery and the known-good 6.18 packages retained; prove boot, storage, network, display, suspend, and rollback before `wip`. | [recovery-first test order](./packaging/ppa/kernel-maxline/README.md#install-and-test-order) |
| 14 | Desktop-app HW video (browsers) | Turn installed ysp13's manual H.264 visual pass and VP9 VA-API selection into an automated Chrome gate requiring checked visible output, `VaapiVideoDecoder`, stable-copy markers and no fallback/display errors; add HEVC. In parallel, identify which initialization step precedes stock Chrome's multiple-thread `InitializeSandbox()` warning, then prove a live GPU process with an active sandbox. Commit and publish ysp13 separately. Also rerun the default decode soak without unrelated desktop activity and require its committed 32-fd span oracle; then add BFF/1080i, 512 MiB CMA, sandbox-enabled Firefox, physical HDR, and a mixed VA-API/V4L2 XtraDeb Chromium. | [Google Chrome automation/sandbox gate](./findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md#boundary-and-next-gate), [production validation](./findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md), [Chromium package gate](./findings/2026-08-04-chromium-151-gpu-working-v4l2-only.md#next-gate), [interlaced/IEP2 regression](./findings/2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md#verification-gate) |
| 15 | CPU voltage binning (PVTM/eFuse) | Boot a non-PPA static L5/L7 board override and prove each policy's selected rail voltage under verified compute load, including cold-boot and data-integrity checks. | [validation plan](./kernel-versions/docs/pvtm-opp-binning-plan.md#5-validation-plan-both-tracks), [measured baseline](./findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md) |


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
| W01 | [Armbian media-patch drift](#watch-w01) | 2026-08-04 | Patch blobs unchanged; DT anchors still hold. |
| W02 | [Armbian patcher precedence](#watch-w02) | 2026-08-04 | Core-wins behavior unchanged; rename workaround still required. |
| W03 | [Armbian codec-udev upstreaming](#watch-w03) | 2026-08-04 | PR merged; future images should carry the rule. |
| W04 | [Ubuntu FFmpeg version](#watch-w04) | 2026-08-04 | Resolute still publishes `7:8.0.1-3ubuntu2`. |
| W05 | [Launchpad PPA publication](#watch-w05) | 2026-08-05 | Kernel `6.18.42` / `0092` and MPP `a8b19653` source publications are Published, their arm64 builds succeeded, and their binaries are selected from the live normal-PPA index and installed. Kernel publication/boot and MPP installed-runtime milestones are closed. |
| W06 | [Mesa MR stack](#watch-w06) | 2026-08-04 | Four MRs still open; the rebase need moved from !42679 to !42614. |
| W07 | [`ffmpeg-rockchip-81` tips](#watch-w07) | 2026-08-04 | `main` unchanged, but `ffmpeg-80` and `ffmpeg-81` both moved; their replay evidence is stale. |
| W08 | [AV1 container-extradata validation](#watch-w08) | 2026-07-16 | Fix carried forward; board re-test pending. |
| W09 | [Kodi build and tty1 playback](#watch-w09) | 2026-08-04 | No Kodi source in the PPA; build/playback remain board-unverified. |
| W10 | [GRD reconnect validation/submission](#watch-w10) | 2026-08-04 | Latest GNOME 50 source remains `c4ef3c9`; packaging-only `~rk2` is Published and **installed since 2026-08-02**, with the kernel precondition met on `6.18.42`. The reconnect replay, repeated focus/resume, compressed-audio interoperability, and upstream review all remain, and the replay is blocked on root-only RDP credentials. The encoder watchdog/VBR work is built but not installed and never exercised. |
| W11 | [Repository-wide license](#watch-w11) | 2026-08-05 | Resolved: Yi Ding's non-code is CC BY-SA 4.0; only Yi Ding's original kernel contributions are GPL-2.0-or-later. |
| W12 | [Dev-box-only artifacts](#watch-w12) | 2026-08-03 | Identified code/package artifacts are captured. |
| W13 | [librga P010/P210 series](#watch-w13) | 2026-07-25 | `0074` is boot-verified on the `6.18.40` KASAN forward-port: raw RGA 10-bit stride/UV-offset gates pass and fresh-librga P010/NV15 probes pass. Production packaging still must ship the kernel and librga changes together; the source-built 10-bit `librga-smoke` wrapper remains red only at unrelated `imfill`. |
| W14 | [YSP Armbian builder](#watch-w14) | 2026-07-20 | Exact-6.18.38 clean production build `Pf558-Cb831` completed BTF and Debian packaging; the wrapper now pins source and purges stale debug-build Kbuild metadata. |
| W15 | [RGA session-close fix vs. the frozen import](#watch-w15) | 2026-08-04 | Frozen base patch still has the old force-free path; three fwport patches (`0039`/`0070`/`0079`) now owe regeneration. |
| W16 | [Forward-port kernel-fix tail](#watch-w16) | 2026-08-04 | Source/export, Published binaries, and the installed/booted package are aligned at `0001`–`0092` / `7d53bc7a3adc`; broad kernel functional/recovery proof and the encode soak are green, while the decode workload is kernel-clean but misses the strict fd-span oracle. Exact-tail KASAN/lockdep and remaining hostile-path qualification are still owed. |
| W17 | [Maximum-mainline proposal-set drift](#watch-w17) | 2026-08-02 | Refreshed against current proposal mail, Torvalds master, linux-next, and subsystem-next refs; future “maximum current” claims still require another deliberate audit. |
| W18 | [rockchip-vaapi fork state](#watch-w18) | 2026-08-05 | Published ysp12 retains the broad exact-kernel campaign. Fork/local HEAD remain `184d7d4`; dirty UNRELEASED ysp13 was built and installed locally, its installed driver matches the deb payload, Chrome H.264 now presents correctly, and 640x480 VP9 selects VA-API. Stock Chrome uses no sandbox-disabling flags but its GPU process is still unsandboxed (`Seccomp: 0`); commit/publication, automated replay and sandbox remain. |
| W19 | [MPP `INIT_CLIENT_TYPE` double-call → use-after-free](#watch-w19) | 2026-07-24 | **Root-caused, reproduced, escalated to a UAF, fix committed as `0069`** (`-EBUSY` re-init guard). Two `INIT_CLIENT_TYPE` ioctls persistently corrupt `queue->session_attach`; a *later* single unprivileged INIT then reads a **freed `struct mpp_session`** (KASAN slab-use-after-free), so it is memory-corruption, not a mere WARN. BSP-identical, untouched by `0058`-`0068`. **Gate CLOSED 2026-07-24:** the reproducer returns `errno=16` (`EBUSY`) on the booted `#8` KASAN build carrying the fix, and that tail passed full conformance on the Published production kernel. |
| W20 | [Intermittent Plymouth initramfs-daemon boot stall](#watch-w20) | 2026-07-23 | **CSI-loop attribution falsified as sole cause:** the stall recurred on 2026-07-23 with the patched `~rk1` package binary-verified in the booted initramfs (identical fingerprint, no `SIGRTMIN+20`). Boot-transaction mechanism reconfirmed; internal daemon wedge unknown again. Mitigation `plymouth.enable=0` still unapplied; next hang needs a live `plymouthd` stack via `debug-shell.service` instead of a reset. |
| W21 | [ffmpeg-rockchip `rkmpp` transcode deadlock without the `da5befc806` backpressure fix](#watch-w21) | 2026-07-23 | The harness's default `FFDIR` binary (FFmpeg-**master**, `libavcodec 63`; its dir's `RELEASE` file misleadingly says 6.1) deadlocks on `h264→hevc` and `hevc_main10→p010` `rkmpp`/`rkrga` pipelines (all threads on `futex`). The **shipping `/usr/bin/ffmpeg 8.0.3~rk1` (`libavcodec 62`, carries `da5befc806`) runs both cleanly**, and the **kernel is not implicated** (clean RGA reset, no D-state/KASAN). Already-catalogued encoder-backpressure/decoder-hang class ([`fix-candidates.md`](./video-libraries/ffmpeg/docs/fix-candidates.md)), fixed on our 8.0 line — not a new finding; not yet forward-ported to main. |
| W22 | [RK3588 per-die voltage binning absent from mainline](#watch-w22) | 2026-07-27 | Rechecked three release candidates later at maxline `v7.2-rc5-252`: still absent, and `rk3588-opp.dtsi` is byte-identical between the 6.18 forward port and maxline, so one DT patch serves both. Mainline ships the BSP's unbinned worst-die column **exactly** (19/19 shared CPU OPPs) while the BSP's per-die columns reach 50–87 mV lower. This board is bin 0 and its BSP index is now **measured** — L5 little, L7 both big — so the entitlement is priced, not estimated. |
| W23 | [Ramoops retention reversal & the 6.18.38 kernel A/B](#watch-w23) | 2026-07-28 | **Ramoops recovers records across warm reboots on every 6.18.40-era kernel** — ≥9 recoveries in the retained journal since 2026-07-26, same firmware stack — so the documented all-zero failure is scoped to the 6.18.38-era kernels and the firmware-phase hypothesis is retired. The four-reboot kernel A/B on the still-installed `6.18.38-current` is pending; the 2026-07-27 19:38 GRD-SG oops dump is archived in `/var/lib/systemd/pstore/`. |
| W24 | [ROCK 5B stock-Ubuntu image inputs](#watch-w24) | 2026-08-01 | Ubuntu 26.04 arm64 images, Canonical's draft Image Cookbook/`ubuntu-image` 3.6.0 schema, Linux 6.18 LTS projection, and the inspected upstream U-Boot tip are recorded as design inputs. No successor image, clean kernel package, gadget, or upstream-U-Boot board boot exists yet. |
| W25 | [libmpp VP9 repeated-reference output ownership](#watch-w25) | 2026-08-05 | Closed in source and the installed PPA package at `a8b19653`: source `18657949` is Published, arm64 build `33468629` succeeded, and the live archive version is installed. Installed sync/no-thread/multi-thread outputs are 16/16 and byte-identical, 120/120 stress decoders are teardown-clean, the four-codec differential is bit-exact, the official suite is 12/12, and bounded kernel-journal scans are clean. |

<a id="watch-w01"></a>
### W01 — Armbian media-patch drift

- **Why recheck:** DT patch 02 converts Armbian's nodes in place; changed node
  labels or patch anchors can break the build or decoder DT.
- **Last checked:** 2026-08-04
- **State 2026-08-04:** Live `armbian/build` main has moved to `9c26d236e194`,
  but **both media blobs are byte-identical to the 2026-07-11 reading** —
  `rockchip64-6.18` `media-0001` is still `390c2e0b` and `media-0007` still
  `a2a4143e`, read with `git ls-tree` against the current tip. Armbian moving is
  therefore not by itself a reason to re-audit the DT hunks; this row exists to
  separate the two. Checklist:
  [resyncing guide §4](./kernel-drivers/docs/resyncing.md).

<a id="watch-w02"></a>
### W02 — Armbian patcher precedence

- **Why recheck:** The self-contained-DT/AV1 build must rename two core media
  patches. A restored userpatch override, `series.conf` migration, or supported
  disable mechanism would change that procedure.
- **Last checked:** 2026-08-04
- **State 2026-08-04:** `lib/tools/patching.py` **has changed** — blob `d14c53f6`
  → `853cfd9c` — but the three load-bearing lines are untouched, so the
  core-wins conclusion holds and the rename workaround is still required. Read
  directly from the current blob: `CONST_PATCH_ROOT_DIRS` still appends the
  userpatches root *before* the core root; the `ALL_DIR_PATCH_FILES_BY_NAME`
  build is still a plain last-write-wins loop, so core still overwrites user;
  and `NORMAL_PATCH_FILES` is still re-sorted alphabetically afterwards.
  `CONST_ROOT_TYPES_CONFIG_ORDER` is also still `['core', 'user']`, preserving
  the trap that *config* resolves user-over-core while *patches* resolve
  core-over-user. **A blob change here is not a behavior change** — diff the
  three anchors before concluding anything. Mechanism and workaround:
  [`armbian-patch-precedence.md`](./packaging/docs/armbian-patch-precedence.md).

<a id="watch-w03"></a>
### W03 — Armbian codec-udev upstreaming

- **Why recheck:** The upstream rule determines whether `codec-udev` is required
  or only backfills older/custom images.
- **Last checked:** 2026-08-04
- **State 2026-08-04:** Unchanged.
  [armbian/build#10085](https://github.com/armbian/build/pull/10085) is still
  `MERGED` with the same merge commit `a6163444eb6c305b635c82242fbeb636daf4b6f4`
  (merged 2026-06-30), confirmed through the GitHub API. Images built from that
  base should carry the MPP/dma-heap rule.

<a id="watch-w04"></a>
### W04 — Ubuntu FFmpeg version

- **Why recheck:** A future Resolute `7:8.1.x` can silently supersede the
  `+rkmpp` packages.
- **Last checked:** 2026-08-04
- **State 2026-08-04:** Unchanged — Resolute still publishes exactly one
  `Published` `ffmpeg` source, `7:8.0.1-3ubuntu2` in `Release` (published
  2026-02-20), per the Launchpad `getPublishedSources` API. No `7:8.1.x` has
  appeared, so the `+rkmpp` replacement is not at risk of being superseded yet.
  Hold recipe: [`packaging/README.md`](packaging/README.md).

<a id="watch-w05"></a>
### W05 — Launchpad PPA publication

- **Why recheck:** Acceptance, build state, and binary publication can change
  after upload without a local repository edit.
- **Last checked:** 2026-08-05
- **State 2026-08-05:** Official Launchpad API rechecks report forward-port
  source publication `18656958` `Published` and arm64 build `33467257`
  `Successfully built`; the normal PPA index exposes the same `0092` image,
  DTB, and headers installed on the board. MPP source publication `18657949`
  is also `Published`, build `33468629` is `Successfully built`, and the live
  index selects `1.5.0+git20260805.a8b19653+ds-0ubuntu1~rk1`. All four
  installed MPP runtime/development/demo packages report that exact version,
  and the installed-runtime closure is recorded under W25. This closes the
  forward-port publication/install/boot milestone. A clean-install run is
  still useful when migrating a different machine from incompatible PPAs; it
  is not missing evidence for this already-published kernel artifact.
- **State 2026-08-04:** Launchpad Published `0001`–`0092` / `7d53bc7a3adc` as
  source publication `18656958` at
  `6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1`; remote arm64 build `33467257`
  completed successfully in 41m44s; all three successor binaries are Published,
  installed, and booted as `6.18.42-ysp-rockchip64`. Exact package identity,
  broad native and VA-API suites, bounded kernel logs, recovery stress, and
  production decode/encode soaks are recorded in the
  [production validation finding](./findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md).
  GRD replacement
  source `18654077`, binary publication
  `247717203`, and build `33461880` are Published/successful and the package is
  installed. The documented SD rescue + `kernel-revert.sh` commands are
  operator-validated.

<a id="watch-w06"></a>
### W06 — Mesa MR stack

- **Why recheck:** Review feedback, CI, merge state, and rebase requirements
  determine the next upstream action.
- **Last checked:** 2026-08-04
- **State 2026-08-04:** All four remain `opened` and none has merged, but **the
  rebase requirement has moved**, which changes the next action:

  | MR | `detailed_merge_status` | head | last updated |
  |----|------------------------|------|--------------|
  | [!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563) | `unchecked` | `833101f35ed6` | 2026-07-03 |
  | [!42679](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42679) | `unchecked` | `6509025064fe` | **2026-07-23** |
  | [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613) | `unchecked` | `8875a22856da` | 2026-07-06 |
  | [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614) | **`need_rebase`** | `4c23f1db1f9c` | 2026-07-06 |

  !42679 — the MR the previous next-gate was written against — was updated on
  2026-07-23, reports no conflicts, and **no longer needs a rebase**; !42614 now
  does. !42613 and !42614 still carry the exact heads whose four selected G610
  shards passed (`8875a22856d`, `4c23f1db1f9`), so that evidence is not
  invalidated. **`unchecked` is not a merge verdict** — it means GitLab has not
  recomputed mergeability, so do not read it as "mergeable". Prior selected
  evidence stands: !42563 pipeline 1697832 green for x86/arm64 build plus G610
  GL/piglit; !42679 pipeline 1700107 green for x86 build, clang, llvmpipe, and
  softpipe — but that pipeline predates the 07-23 head, so !42679 needs a fresh
  run. The web UI remains bot-blocked; use the GitLab API. Superseded context:
  [!38433](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/38433).

<a id="watch-w07"></a>
### W07 — `ffmpeg-rockchip-81` tips

- **Why recheck:** The canonical master, 8.0, and 8.1 lines follow moving
  upstream branches; later upstream movement requires a fresh replay and test.
- **Last checked:** 2026-08-04
- **State 2026-08-04:** **Two of the three canonical tips have moved** — this is
  exactly the drift the row exists to catch, and it invalidates the replay
  evidence for those two lines:

  | Branch | Recorded 2026-07-19 | Now | |
  |--------|--------------------|-----|---|
  | `main` | `8b57e531d1fc` | `8b57e531d1fc` | unchanged |
  | `ffmpeg-80` | `be753f3bbb2c` | **`ab675f19cf17`** | moved |
  | `ffmpeg-81` | `8d3ca020b6a2` | **`629f4968d226`** | moved |

  Read with `git ls-remote` against `yisding/ffmpeg-rockchip-81`. The 2026-07-19
  source-build and `fate-source` results belong to the old `ffmpeg-80`/`ffmpeg-81`
  heads and **do not carry forward**; both lines need a fresh replay and test
  before any claim about them is repeated. `main` is unaffected. Upstream
  `nyanmisaka/ffmpeg-rockchip@388741a3544b` matches the tip named in
  [ledger track 5](docs/status-ledger.md) as sharing the async-frame lifetime
  defect. The dedicated PPA remains at `be367abfe6`; separate normal-PPA branch
  `fix/rkmpp-output-timeout@da5befc806` is public, built, and Published, with its
  combined GRD hardware gate still pending.

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
- **Last checked:** 2026-08-04
- **State 2026-08-04:** The packaging half is re-verified and unchanged: the
  `ubuntu-rock-5b` PPA publishes `ffmpeg`, `ffmpeg-rockchip`,
  `gnome-remote-desktop`, `librga`, `linux-rockchip64-ysp`, `mpp`, `plymouth`,
  `rk3588-codec-udev`, and `rockchip-vaapi` — **no Kodi source at all** — and no
  Kodi build evidence has entered the repository. Fork `libavcodec63` packages
  were built, MPP was fixed, and no Kodi patch is needed. **Scope limit:** this
  recheck covers the package channel and the repository record only. The
  GBM/GLES build and `kodi-gbm` tty1 playback are dev-box and board state that
  cannot be verified from here, and remain unproven since 2026-07-11. See
  [`apps/kodi/`](apps/kodi/README.md).

<a id="watch-w10"></a>
### W10 — GRD reconnect validation/submission

- **Why recheck:** The corrected series must survive the exact macOS
  focus-away/focus-return sequence before promotion, and the submission claim
  needs a public review artifact.
- **Last checked:** 2026-08-04
- **State 2026-08-04:** The `~rk2` package is **installed** (2026-08-02 14:54)
  and the system daemon is enabled and listening on 3389. The booted
  `6.18.42-ysp-rockchip64` sets neither `CONFIG_DMABUF_DEBUG` nor
  `CONFIG_KASAN`, so both stated preconditions for the reconnect gate are met
  and only the replay itself is outstanding. It is blocked on the system RDP
  credentials, which are root-only: the user-level `grdctl` reports RDP
  disabled, and no secrets service is reachable from an SSH context. Note the
  user-level `tls-cert` still points at a dangling per-session scratchpad path
  under `/tmp`, which needs repointing at durable storage before user RDP is
  re-enabled. The encoder watchdog/forced-IDR/VBR work is built and confirmed
  present in `fix/forced-idr-recovery@100da72`, which sits directly on the
  released `c4ef3c9`, but is absent from the installed binary and has never
  been exercised.
- **Superseded state 2026-08-02:** Launchpad's `~rk1` arm64 build `33452991` failed after
  8m42s and retained no diagnostics. A local host rebuild reproduced the
  likely boundary: the RDP success assertion can be followed by enough
  Mutter/PipeWire teardown to reach 21.64s, beyond Meson's 20s default.
  Packaging-only `~rk2` changes no production source and keeps the test fatal
  with `--timeout-multiplier 3`. Local source/native/RDP/Lintian/signature
  gates pass; source `18654077`, binary `247717203`, and arm64 build `33461880`
  are Published/successful. Its log records RDP green in 9.76s, zero failures,
  and two expected skips. Installation and the exact board reconnect replay
  remain.

<a id="watch-w11"></a>
### W11 — Repository-wide license

- **Why recheck:** Future license-policy edits must retain the per-upstream code
  mapping and must not claim to relicense imported third-party material.
- **Last checked:** 2026-08-05
- **State 2026-08-05:** Resolved in [`LICENSE.md`](LICENSE.md). Yi Ding's
  original documentation and non-code contributions are CC BY-SA 4.0. Yi
  Ding's original code contributions follow the license of their upstream
  target, with only Yi Ding's own original kernel contributions
  GPL-2.0-or-later. Imported GPL-2.0-only kernel material, patch context, and
  every other author's contribution remain unchanged.
  Track 10 is no longer gated on this decision; artifact-level source and
  redistribution checks remain.

<a id="watch-w12"></a>
### W12 — Dev-box-only artifacts

- **Why recheck:** Uncaptured code or packaging in a dirty worktree is a single
  point of failure.
- **Last checked:** 2026-08-03
- **State 2026-08-03:** Re-verified in-repo and unchanged. Both GRD prototypes
  are still exported under
  [`patches/reference/`](./apps/gnome-remote-desktop/patches/reference/) as
  `async-pbo-prototype.patch` and `memfd-prototype.patch`, and all three
  evidence owners are present: [`baseline.md`](./apps/gnome-remote-desktop/docs/baseline.md)
  §7, [`profiling.md`](./apps/gnome-remote-desktop/docs/profiling.md) §4, and
  [`external-workspaces.md`](packaging/external-workspaces.md). The throwaway
  headless harness is still not preserved, but its reconstruction is documented.
  Note the scope limit: this checks that everything *known* to be at risk is
  captured. It cannot discover a new uncaptured artifact sitting in a dirty
  external tree — that needs a sweep of the trees named in
  [`external-workspaces.md`](packaging/external-workspaces.md).

<a id="watch-w13"></a>
### W13 — librga P010/P210 series

- **Why recheck:** The fix must remain reconstructible and its 10-bit shipping
  gate must not be mistaken for completed hardware validation.
- **Last checked:** 2026-07-25
- **State 2026-07-25 (KASAN gate):** The `0074` kernel fix is boot-verified on `6.18.40-video-port-kasan-rockchip-rk3588 #2`. Raw RGA stride/UV-offset run `20260725-195821-rga-10bit-gates` passed cores 1, 2, 4, and default with `kernel_flags=0`; fresh-librga run `20260725-200145-rga-im2d-10bit-current-gates` passed P010 and NV15 widths 256/320/1920. The 10-bit `librga-smoke` subcases pass with that fresh library, but the whole smoke still exits 1 at unrelated `imfill`. See the [6.18.40 KASAN validation finding](./findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md).
- **State 2026-07-25 (TILE):** The byte-stride convention holds for **TILE too**,
  not just RASTER — settled against BSP `develop-5.10`/`develop-6.1`, where the
  `* 8` in the tile stride is the eight-lines-per-tile-block factor, not a
  pixel-depth scale, and `rga_convert_addr()` has no `rd_mode` distinction at
  all. librga `b8def3e` had gated the pixel→byte conversion on raster, and the
  rewrite's TILE branch pinned the wrong convention with a KUnit guard. Fixed in
  librga `4c26ddf` (shipped as the `…20260725.26a50ef` PPA upload) and rewrite
  `40cf22629cf63`/`7481ab327d7ea`. **Kernel and librga must now ship together
  for TILE 10-bit**, the same coupling as the `0072`/`c80eea7` raster pair. See
  the [TILE byte-stride finding](./findings/2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md).

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
### W15 — RGA session-close fix vs. the frozen import

- **Why recheck:** The RGA `/dev/rga`-close force-free hazard is fixed in the
  forward-port tree, but the superseded two-patch import — still the DKMS
  source — is a frozen vendor snapshot that carries the old
  `rga_mm_force_releaser_buffer()` path, so the two can silently diverge until
  the next regeneration.
- **Last checked:** 2026-08-04
- **State 2026-08-04:** Re-verified in-repo and **still diverged — the debt has
  grown**. The frozen base patch
  [`rk3588-rkvenc2-01-vcodec-rga-drivers.patch`](./kernel-drivers/patches/rk3588-rkvenc2-01-vcodec-rga-drivers.patch)
  still carries `rga_mm_force_releaser_buffer` (3 occurrences), while the
  forward-port series now holds **three** patches over this area rather than the
  one this row was opened for: `0039` (release session buffers by reference),
  `0070` (don't drop `mm->lock` during session release), and `0079` (job/buffer
  lifetime and locking). All three must fold in at the next base-patch
  regeneration, and the DKMS channel keeps consuming the old path until then.
- **State 2026-07-17:** Driver fix `linux-6.18-rkvenc-av1-fwport@bc086cbe03d7`
  ("release session buffers by reference on close") makes
  `rga_mm_session_release_buffer()` drop each buffer through
  `kref_put(..., rga_mm_kref_release_buffer)` instead of force-freeing;
  compile-verified, not yet re-exercised on hardware. It is now exported as
  forward-port patch `0039`. The base patch
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
- **Last checked:** 2026-08-04
- **State 2026-08-04 (source safety tail):** Maintained source and the exported
  series are aligned at `7d53bc7a3adc`, 92 commits/patches on `v6.18`.
  `0090`–`0092` close the RGA job-task UAF, provider callback/current-task
  lifetime, soft-CCU retire-before-reset, and concurrent reset-request gaps;
  the six affected objects pass arm64 `W=1`. Exact source package
  `6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1` passed full-tree
  predecessor comparison plus fresh-extraction provenance checks and is
  Published as source publication `18656958`; remote arm64 build `33467257`
  completed successfully, all three binaries are Published, and the exact
  image/DTB/headers are installed and booted. ABI, native codec/RGA/IOMMU and
  recovery suites, the independent VA-API matrix, bounded fatal-log scans, and
  production soaks are complete: encode passes flat, while decode completes
  with a clean kernel window but fails the strict 32-fd span oracle at 36 even
  though its head/tail medians fall from 56 to 54. This production profile has
  no KASAN or lockdep,
  so exact-tail memory-safety qualification and remaining hostile paths are
  still owed.
  See the
  [fix finding](./findings/2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md).
- **Superseded state 2026-08-04 (production predecessor):** Signed source
  `6.18.42+rk3588av1fwport20260803-0ubuntu1~rk1` passed staging, signature,
  extracted-source provenance/config, and IEP2 payload checks. The source and
  all three arm64 binaries are Published; the package is installed and booted
  as `6.18.42-ysp-rockchip64`. That predecessor's narrow evidence comprises
  standalone IEP2 and 17/17 pinned tier-1 VA-API vectors. This is ordinary
  integrated exercise of that tail, not the still-owed targeted
  `0076`–`0087` hostile/ABI/RGA regression gates or the full conformance set.
- **State 2026-07-29 (audit sweep):** The exported tail is now contiguous
  `0001`–`0079`. A systematic WARN/oops audit of the driver source found **18
  distinct defects** and fixed them in `0076`–`0079`, including all five
  previously catalogued but unfixed entries in the vendor-driver latent-defect
  catalogue (kept in the private `rock-5b-security` repository).
  Twelve are reachable by any process that can open `/dev/mpp_service` or
  `/dev/rga`; five of those are unprivileged kernel-heap corruption. **All four
  patches are compile-verified only — none has been booted and no reproducer
  has been run**, so the earlier `0001`–`0071` hardware evidence does not extend
  to them, and a KASAN + `DEBUG_ATOMIC_SLEEP` + lockdep boot with full
  conformance is owed before they ship. The same sweep confirms the forward
  port never carried the sleeping fault-handler tail that panicked the board
  (its `rockchip_iommu_set_fault_handler()` is a plain pointer swap), which
  corroborates the
  [orig-provenance finding](./findings/2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md).
  See [the audit finding](./findings/2026-07-29-forward-port-warn-oops-audit-and-fixes.md).

<a id="watch-w17"></a>
### W17 — Maximum-mainline proposal-set drift

- **Why recheck:** Upstream Linux, public proposal revisions, and integration
  branches move independently. The checked-in profiles remain reproducible,
  but "maximum current public support" becomes stale without changing this
  repository.
- **Last checked:** 2026-08-02
- **State 2026-08-02:** Linux `7.2-rc6`, Torvalds `master@075b74841bd0`,
  `next-20260731@415606a7be93`, public `e6951bc3f935`, WIP
  `73d29539f7bb`, public-next `0cae4ac66823`, WIP-next `15a5179dc3b2`,
  41 public dispositions, and 25 WIP donors are pinned in
  [`manifest.yaml`](packaging/ppa/kernel-maxline/manifest.yaml),
  [`public-series.tsv`](packaging/ppa/kernel-maxline/public-series.tsv), and
  [`wip-donors.tsv`](packaging/ppa/kernel-maxline/wip-donors.tsv). The audit
  found revised HDMI, DW-DP, SCDC, HDPTX, HDMI-RX, and CAN series; new public
  VP9, DCPHY, and N/CTS work; plus DRM, USB, media, and PHY acceptance changes.
  Linus/public passes its full compile gate; linux-next/WIP has focused and
  partial-build evidence, but its full build was stopped by request. Debian
  packaging and all hardware validation remain open; re-audit before claiming
  a later proposal maximum.

<a id="watch-w18"></a>
### W18 — rockchip-vaapi fork state

- **Why recheck:** The VA-API-driver track lives in an external fork, not this
  repo; the fork branch and the upstream it descends from move independently
  of any change here.
- **Last checked:** 2026-08-05
- **State 2026-08-05 (installed local ysp13):** Local and fork HEAD remain
  `main@184d7d4`; the fork and PPA remain at ysp12, while the dirty local ysp13
  worktree was built and its driver/config packages installed. The installed
  driver is byte-identical to the deb payload (SHA-256
  `ed578a241803f35f51ccc6afe38b1d132539ae48ca691b5a3180e37565fe56c0`).
  Google Chrome 151 now presents H.264 correctly instead of green and selects
  `VaapiVideoDecoder` for 640x480 VP9 Profile 0. A separate 384x240 VP9 source
  selects `VpxVideoDecoder`, matching Chromium's below-360p software priority.
  The fix preserves NV12/P010 storage and passes the exact 24-frame hardware
  worker lifetime, focused lifecycle with ASan/UBSan, 17/17 conformance,
  static analysis, and the complementary 1,440-frame zero-copy audit. The
  source remains uncommitted, changelog-`UNRELEASED`, and unpublished; Chrome
  replay is manual. Stock Chrome was launched without sandbox-disabling flags,
  but its GPU process still reports `Sandboxed: false`, `Seccomp: 0`, zero
  filters, and an unconfined LSM label. Chrome's multiple-thread sandbox-init
  warning is measured but not yet attributed. See the
  [stable-export finding](./findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md).
- **State 2026-08-04 (installed ysp12 broad hardware campaign):** On exact
  kernel `0092`, the normal and sanitized lifecycle, zero-copy, concurrency,
  pinned conformance, 163-vector HEVC, Main10/tile/AV1/HDR/VP9 Profile 2/10-bit,
  RGA geometry, GStreamer-VA, encode/import/multislice/WebRTC, and concurrent
  codec gates pass. The full 7,200-second dual H.264+HEVC encode gate completes
  216,000 frames per codec with flat 57,260 KiB RSS, 60 fds, and an empty kernel
  delta. The 7,200-second 4K decode workload and kernel scan also complete, but
  its committed userspace oracle rejects four loop-boundary transients whose
  36-fd span exceeds 32 despite head/tail medians falling 56→54. App/session
  selection, WebRTC introspection, and an FFmpeg-only same-process TSan race
  remain separately classified in the
  [production validation finding](./findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md).
- **State 2026-08-04 (ysp12 installed and published):** Local and fork HEAD are
  `main@184d7d4` ("release: prepare ysp12"), worktree clean and pushed to
  `yisding/rockchip-vaapi`; upstream remains `woodyst/main@e8c64dd`. ysp12
  disables MPP's decoder-internal deinterlacer, the path kernel `6.18.42` made
  live by enabling IEP2. Against the **installed** package on that kernel the
  pinned conformance set is **17/17 bit-exact**, including the interlaced
  `h264/CABREF3_Sand_D.264` decoding through VA-API — the vector that failed on
  ysp10. Source package built from the release commit: a fresh `dpkg-source -x`
  matches all 661 tracked files byte-for-byte, `dscverify` passes against the
  personal key ring, and source Lintian is clean. Signed with
  `0FDDE6BC…AA2228E6` and uploaded; source publication `18656370` was accepted,
  arm64 build `33465947` succeeded in 4m20s, and the exact arm64 binary is
  Published in the PPA index as verified 2026-08-05. `ysp11` carried only the 8192x8192 picture-size
  change and was superseded before publication. Chromium 151 later closed the
  GL startup boundary but exposed a V4L2-only arm64 package; Firefox sandbox,
  physical HDR, 512 MiB CMA, Chromium mixed-package/playback/sandbox, and
  clean-image gates remain. The 17-vector rerun here is the focused interlaced
  regression guard; the later exact-`0092` broad VA-API campaign and soaks are
  recorded in the current state above.
- **Superseded state 2026-08-04 (installed ysp10, ysp11 built):** Local and fork HEAD
  are `main@73dea57`; upstream remains `woodyst/main@e8c64dd`. Installed driver
  and config are `1.0.11+ysp10-0ubuntu1~rk1`, and its payload reproduces exactly
  from its own clean commit at three independent build paths, so the dirty-
  worktree provenance gap that ysp8 carried is **closed**. Kernel `6.18.42`
  enabled IEP2 and broke interlaced decode until the driver was changed to
  disable MPP's decoder-internal deinterlacer; see the
  [regression finding](./findings/2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md).
  The fork also carries the 8192x8192 picture-size change and a proposed
  roadmap Phase 6 for `VAEntrypointVideoProc` deinterlacing.
- **Superseded state 2026-08-02 (installed ysp8):** Local and fork HEAD are
  `main@aee5926`; upstream remains `woodyst/main@e8c64dd`. Installed driver and
  config are `1.0.11+ysp8-0ubuntu1~rk1`, `dpkg -V` clean, and the installed
  driver hash exactly matches the ysp8 deb. The safe decode, encode, import,
  concurrency, GStreamer, and isolated-Mutter VLC/mpv/Firefox matrices are
  green, including both 10-bit profiles in all three applications. A later
  [forward-port RGA discriminator](./findings/2026-08-02-rga3-forward-port-small-geometry-discriminator.md)
  passed 90/90 runs and 4,320/4,320 exact frames at each formerly suspect
  small geometry, including both RGA3 cores; the silent-write finding is now
  scoped to the rewrite driver. The installed source identity is still
  incomplete: ysp8 was built from a dirty tracked worktree over `aee5926`. See the
  [installed validation](./findings/2026-08-02-rockchip-vaapi-ysp8-installed-runtime-validation.md)
  for exact hashes, package/runtime identities, all gate results, the harmless
  optional-IEP2 `cmd 100 ret -22` root cause, and the remaining boundaries.
- **State 2026-08-02 (Firefox Main10 correction):** `df14bb6` (2026-07-30)
  **supersedes the earlier "Panfrost cannot import P010 chroma" diagnosis**: the driver
  exported split P010 chroma as `0x36315247`, a VA-style `GR16` literal, where
  `DRM_FORMAT_GR1616` is `0x32335247`, so Mesa's `EGL_BAD_MATCH` was correct
  and the import never reached Panfrost. That commit replaces every DRM format
  and modifier literal with the `DRM_FORMAT_*` macros, deletes both speculative
  `panfrost-p010-chroma-retry` patches, and leaves the RDD sandbox pair as the
  only Firefox patches; `1.0.11+ysp7` imports Main10 zero-copy in both Firefox
  processes. Upstream `woodyst/main` is still `e8c64dd`.

<a id="watch-w19"></a>
### W19 — MPP `INIT_CLIENT_TYPE` double-call → use-after-free

- **Why recheck:** A real unprivileged-reachable **use-after-free**, not just a
  WARN. On `Pabd5-C4ad2` (`CONFIG_DEBUG_LIST` + KASAN) the double-init WARNs, but
  it **persistently corrupts `queue->session_attach`**, and a *later* ordinary
  INIT then reads a freed `struct mpp_session` (KASAN slab-use-after-free). On a
  production kernel the corruption is silent until the freed-node access faults.
  Stays live only as the record of a submit-now-tier bug and its fix; the gate
  itself is closed.
- **Last checked:** 2026-07-24
- **State 2026-07-24 (gate CLOSED):** `0069`'s `-EBUSY` re-init guard is
  runtime-verified. On the booted KASAN `#8` build (`av1-fwport@4401383a6d9b5`,
  tail `0001`–`0071`) `mpp-double-init-repro` returns `errno=16` (`EBUSY`) on the
  second `INIT_CLIENT_TYPE`, with no WARN and no UAF
  ([validation run](./findings/2026-07-23-forward-port-current-tip-full-validation-run.md)),
  and the same tail then passed the full conformance set plus root gates on the
  Published production kernel 2026-07-24. `P29f4-C9fc5` was never needed — the
  fix rode the `#8` build instead. Remaining work is upstream submission, not
  verification.
- **State 2026-07-23:** Root-caused, deterministically reproduced, and escalated to a
  UAF while building the OOB PoCs. Two `MPP_CMD_INIT_CLIENT_TYPE` ioctls on one
  `/dev/mpp_service` session double-add `session->session_link`
  (`mpp_session_attach_workqueue()`, `mpp_common.c:492`; the `:1448` INIT case has
  no re-init guard) and leak the first `session->dma`. A subsequent single INIT
  from an unrelated PoC then hit `BUG: KASAN: slab-use-after-free` at the
  `list_add`, reading a freed kmalloc-1k `mpp_session` (`session_link` offset
  408). Reachable as UID 1000. BSP-identical unguarded code, untouched by
  `0058`-`0068`.
  Fix = reject re-init with `-EBUSY`, committed as `0069`; debug build
  `P29f4-C9fc5` (config byte-identical to `Pabd5-C4ad2`) is built but not yet
  installed (the current boot's list stays poisoned until reboot).
  Reproducer: `mpp-double-init-repro.c`, kept in the private
  `rock-5b-security` repository.
  Detail: [`findings/2026-07-22-mpp-process-request-list-add-double-add-warn.md`](./findings/2026-07-22-mpp-process-request-list-add-double-add-warn.md).

<a id="watch-w20"></a>
### W20 — Intermittent Plymouth initramfs-daemon boot stall

- **Why recheck:** Intermittent, so it goes quiet between hits and is easy to
  misattribute. Two boots on 2026-07-22 (`#3` and `#6`) never reached
  `sysinit.target` and were hard power-cycled. The loud
  `systemd-networkd-wait-online` timeout in the log is **not** the cause — it is
  chronic and non-fatal (the healthy boot logs the identical timeout *and* the
  identical PCIe PMU-notifier lockdep splat, yet reaches `graphical.target`).
  Stays live until the internal wedge is captured live (the parser fix alone
  did **not** stop it), or Plymouth is disabled for an exclusion boot.
- **Last checked:** 2026-07-23
- **State then (2026-07-23):** The stall recurred at 09:56 PDT on a boot that
  provably ran the patched `~rk1` Plymouth: packages installed 05:35,
  initramfs/uInitrd regenerated 05:41, uInitrd payload byte-identical to the
  installed files, and disassembly confirms upstream `45655f12`'s
  `continue`→`break` fix in the running `libply-splash-core`. Identical
  fingerprint (both Plymouth jobs stuck, no `SIGRTMIN+20`, no
  `sysinit.target`), so the incomplete-CSI loop is falsified as the sole
  internal cause; details in
  [`findings/2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md`](./findings/2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md).
  Next discriminator: enable `debug-shell.service` +
  `plymouth.debug=stream:/dev/ttyS2` and capture the wedged daemon's
  `/proc/<pid>/stack`/`wchan`/`syscall` instead of resetting.
  `plymouth.enable=0` remains the reliable mitigation and clean exclusion test.
- **State 2026-07-22:** Root cause at the boot-transaction level is an unresponsive
  initramfs-inherited `plymouthd`: it owns the abstract socket but never
  dispatches the real-root system-initialized request. Plymouth clients have no
  timeout, so `plymouth-read-write.service` (infinite start timeout,
  `Before=sysinit.target`) and `plymouth-start`'s `show-splash` post-command
  remain active indefinitely. Adjacent healthy boots log the daemon's
  `SIGRTMIN+20` and finish in 30–60 ms. Exact forward-port source plus both
  failed journals prove all MPP probes returned; the `fdba*` sync markers are
  routine Hantro JPEG. The failed and adjacent healthy build-`#6` boots used the
  same initrd, generated before both; extraction shows a complete,
  package-identical Plymouth/DRM payload. Starting real-root PID 1 also proves
  the daemon processed and ACKed initramfs's new-root request.
  `splash=verbose`, active `ttyS2 tty1`, and the absence of
  `plymouth.ignore-serial-consoles` make the exact Plymouth source create
  terminal-only devices and return before starting udev or a DRM renderer.
  Its active terminal keyboard parser contains upstream issue #321's
  incomplete-CSI infinite loop (`continue` without advancing the buffer).
  That issue reproduced timing-sensitive hangs on ARM64 systems attached to a
  serial-console server and was fixed after this Ubuntu snapshot by upstream
  commit `45655f12` (`continue` → `break`). The failed boot lacks a live stack
  or saved input bytes, so the internal attribution is a source match rather
  than a directly sampled task-state proof.
  Immediate board fix: append `plymouth.enable=0` to
  `/boot/armbianEnv.txt`'s existing `extraargs=` line; `bootlogo=false` alone
  still injects `splash=verbose`. No initramfs/boot-script rebuild is needed.
  If retaining Plymouth, backport upstream `45655f12`, rebuild/install
  `libplymouth5` plus `plymouth`, and regenerate the initramfs.
  `plymouth.ignore-serial-consoles` is a narrower mitigation that removes the
  likely serial trigger but does not fix the parser.
  Ubuntu has not packaged the fix in Resolute, Stonking, Noble
  updates/proposed, its current packaging branches, or Debian sid. A minimal
  PPA backport,
  `24.004.60+git20250831.4a3c171d-0ubuntu8.1~rk1`, now has exact-source
  checksum verification, source/native-arm64 builds, a three-file `debdiff`,
  and clean binary lintian locally. Signed source publication
  [`18636085`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18636085)
  is accepted; Launchpad arm64 build
  [`33428910`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33428910)
  succeeded, and all nine binary publications are accepted/Pending the PPA
  publisher.
  Gate after reboot: confirm the cmdline token, skipped Plymouth start, completed
  read-write unit, and reached sysinit/basic targets. If retaining Plymouth,
  client reply timeouts must cover read-write/show-splash and finite systemd
  timeouts must also cover quit/quit-wait. For internal capture use
  `plymouth.debug=stream:/dev/ttyS2`. Detail:
  [`findings/2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md`](./findings/2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md).

<a id="watch-w21"></a>
### W21 — ffmpeg-rockchip `rkmpp` transcode deadlock without the `da5befc806` backpressure fix

- **Why recheck:** Surfaced during the 2026-07-23 validation run and initially
  mislabelled (twice) by version: it is **not** a kernel bug and **not** in the
  shipping 8.0.3 port. It hangs the FFmpeg suite when the runtime ffmpeg-rockchip
  build lacks the input-backpressure fix, so it can be mistaken for a kernel
  regression.
- **Last checked:** 2026-07-23
- **Identity caveat:** the deadlocking binary is `FFDIR=../rock-5b/ffmpeg/ffmpeg-rockchip/ffmpeg`,
  which reports `libavcodec 63` (FFmpeg **master**, version `N-125363-g53e76abdc7`).
  Note the *source tree* at that path is mismatched — its `RELEASE` reads `6.1`
  and headers say `LIBAVCODEC_VERSION_MAJOR 60`, so the binary is a stale
  master-based build, not from the checked-out 6.1 source. The **authoritative
  fingerprint is the runtime libavcodec version, not the RELEASE file** (an
  earlier note wrongly called this a "6.1" build).
- **State then:** On that FFmpeg-master build the
  `h264_rkmpp → scale_rkrga → hevc_rkmpp` transcode and the
  `hevc_main10 → scale_rkrga=p010le → hwdownload` case deadlock — all threads
  `S`-state on `futex_do_wait`, 0-byte / ~1-frame output. The **installed
  `/usr/bin/ffmpeg 8.0.3-0ubuntu1~rk1`** (`libavcodec 62`, carries our
  `fix/rkmpp-output-timeout@da5befc806`) runs **both** cases cleanly —
  `run-root-gates.sh` transcode gate PASS (48 frames, both directions), and a
  direct `main10→p010` run produced the full 373 MB output. Same kernel/RGA/MPP
  for both, clean RGA `soft reset`, no `hung_task`/D-state/KASAN, so the **kernel
  is not implicated**; only the build without `da5befc806` hangs. This is the
  encoder input-backpressure / decoder receive-loop hang class already catalogued
  in [`fix-candidates.md`](video-libraries/ffmpeg/docs/fix-candidates.md) and
  fixed on our 8.0 line — **not a new finding**. Our fix is not yet
  forward-ported to the main/master branch.
  Harness: `ffmpeg-suite.sh` now uses `timeout -k` (reaps a deadlock) and prints
  the runtime `libavcodec` version for attribution. Detail:
  [`findings/2026-07-23-forward-port-current-tip-full-validation-run.md`](./findings/2026-07-23-forward-port-current-tip-full-validation-run.md).

<a id="watch-w22"></a>
### W22 — RK3588 per-die voltage binning absent from mainline

- **Why recheck:** Whether upstream gains RK3588 eFuse-driven OPP selection is an
  external fact that changes without a repository edit, and it is the difference
  between our mainline-based kernels running vendor **worst-die** voltages and
  running per-part ones. It also gates any honest BSP-vs-forward-port power or
  thermal comparison: without this, such a comparison measures the missing
  driver, not the port. Watch `drivers/soc/rockchip/`, `drivers/cpufreq/` for a
  rockchip entry, and `rk3588-opp.dtsi` for `opp-supported-hw`.
- **Last checked:** 2026-07-27
- **State 2026-07-27:** Still absent, rechecked at maxline `v7.2-rc5-252`
  (`fac7077731585`), three release candidates past the 2026-07-25 check.
  `drivers/soc/rockchip/` is unchanged, there is no `drivers/cpufreq/rockchip-*`,
  rk3588 is still missing from `cpufreq-dt-platdev.c`, no rk3588 DT declares
  `litcore_grf`/`bigcore*_grf`/`dsu_grf`/`pvtpll`/`pvtm`, and `rk3588-opp.dtsi`
  is **byte-identical to the 6.18 forward port's** (190 lines, clean `diff`) — so
  a single DT patch will serve both trees. Upstream has been active nearby
  without moving this: `rockchip-otp` gained RK3528/RK3562/RK3568 plus a
  word-size fix (the provider grows while the RK3588 cells stay unread), and
  `75fb63ae0312` "soc: rockchip: grf: Support multiple grf" is an RK3576 JTAG fix
  — `grf.c` still knows only `rockchip,rk3588-sys-grf`, not the per-core GRFs
  this needs. A `--grep=pvtm --grep=opp-supported-hw` sweep since 2025-01-01
  returns one commit, and it is Qualcomm's. **What did change is on our side:**
  booting the BSP on this board makes the selection observable, so the previously
  undecidable index is measured — `pvtm-volt-sel=5` (cluster0), `=7` (cluster1/2),
  confirmed independently at the regulator (`policy0` @ 1800 MHz reads 887500 µV,
  exactly `opp-microvolt-L5`) and by the exposed turbo step (`BIT(7)` matches only
  2400). This die's entitlement is therefore **−37.5 to −87.5 mV on nine of ten
  non-trivial CPU OPPs, and 0 mV at 2400 MHz**. Also corrected: live per-die
  measurement *does* have upstream precedent (`drivers/soc/mediatek/mtk-svs.c`
  reads efuse + a thermal zone and calls `dev_pm_opp_adjust_voltage()`), which
  changes the recommended upstream shape from a cpufreq special case to a
  `drivers/soc/rockchip/` process-monitor driver. Detail:
  [`findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md`](./findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md);
  plan: [`kernel-versions/docs/pvtm-opp-binning-plan.md`](./kernel-versions/docs/pvtm-opp-binning-plan.md).
- **State 2026-07-25:** Absent from both mainline trees. `drivers/soc/rockchip/`
  is exactly `Kconfig Makefile dtpm.c grf.c io-domain.c` in the 6.18 forward port
  (`v6.18-253`) and the 7.2-rc2 maxline tree (`v7.2-rc2-242`) — no
  `rockchip_opp_select.c`, `rockchip_pvtm.c`, `rockchip-cpuinfo.c`, or
  `rockchip_system_monitor.c`; no `drivers/cpufreq/rockchip-cpufreq.c`; rk3588
  is not in `cpufreq-dt-platdev.c`. `rk3588-opp.dtsi` carries 27 flat OPPs with
  zero `opp-supported-hw`/`nvmem`/`leakage`/`pvtm` (across all mainline rockchip
  DTs, only `rk3562.dtsi` uses `opp-supported-hw`). Every one of the **19 shared
  CPU OPPs matches the BSP's baseline `opp-microvolt` exactly**, while the BSP
  additionally carries `opp-microvolt-L1..L6` columns reaching **50–87 mV
  lower**. Armbian's `rockchip64-6.18` archive adds nothing (`rk3588-0025-add-missing-op-nodes.patch`
  appends plain nodes only); Armbian's `vendor` branch **is** the BSP and does
  have it. Two consequences worth holding separately: the M/J bins are
  **derated** (little 1704 vs 1800, big 2016 vs 2400, and +25…+75 mV), so
  mainline's bin-0-only table would run an RK3588J past its caps — but **this
  board measures bin 0** (`specification_serial_number` `0x01`,
  `customer_demand` `0x00`, read live from `rockchip-otp0`), so here only the
  voltage is conservative, not the OPP set. Half the port is already upstream and
  dead: `drivers/nvmem/rockchip-otp.c` plus the leakage cells at
  `rk3588-base.dtsi:3323` have **no consumer anywhere**, and
  `dev_pm_opp_set_config()` is exported — the gap is an
  `imx-cpufreq-dt.c`-shaped driver plus two DT cells. PVTM is the part that does
  not port cheaply (runtime closed-loop PVTPLL calibration). Detail:
  [`findings/2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md`](./findings/2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md).

<a id="watch-w23"></a>
### W23 — Ramoops retention reversal & the 6.18.38 kernel A/B

- **Why recheck:** Two facts here drift silently. The kernel A/B (four
  reboots, nothing to flash) is the open gate that turns "kernel-generation-
  scoped" from the best available inference into a proof, and nobody schedules
  reboots automatically. And `/var/lib/systemd/pstore/` only stays meaningful
  if it is checked after crashes — `systemd-pstore` archives and erases
  `/sys/fs/pstore` within seconds of every boot, which is exactly the blind
  spot that hid the working channel for two days.
- **Last checked:** 2026-07-28
- **State 2026-07-28:** Retention **works** on the current kernels: ≥9
  cross-reset recoveries in the retained journal (2026-07-26 12:14 onward)
  across `6.18.40-ysp`, `6.18.40-video-port-kasan`, and
  `6.18.40-video-rewrite-kasan`, on the unchanged
  `ddr-v1.20-b8ce94f14b / bl31-v1.48 / uboot-rmbian-201` firmware — including
  the 2026-07-27 19:38:08 GRD-SG oops dump recovered after a clean warm
  reboot (root-readable at `/var/lib/systemd/pstore/dmesg-ramoops-0`). The
  2026-07-21..24 all-zero failures were real (systemd-pstore condition-skip
  lines prove pstore was genuinely empty on those boots) but every one ran on
  a 6.18.38-era kernel; the flip coincides with repo `49b115e` (2026-07-25,
  6.18.38 → 6.18.40 rebuild wave) with DTB node, cmdline, and userspace held
  constant. The fixing change is unidentified (upstream 6.18.39/40, Armbian
  patch refresh, and repo patchset revision moved together). Open gate: probe
  `write` → warm reboot → `read` on `6.18.40-ysp`, then the same on the
  still-installed `6.18.38-current-rockchip64`. Do not boot the BSP kernel
  between a crash and a recovery attempt (its `0xe0000@0x110000` window
  contains and corrupts ours). Detail:
  [`findings/2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md`](./findings/2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md);
  maintained boundary:
  [`boot-firmware/docs/ramoops-retention.md`](./boot-firmware/docs/ramoops-retention.md).

<a id="watch-w24"></a>
### W24 — ROCK 5B stock-Ubuntu image inputs

- **Why recheck:** Ubuntu point images and seeds, the draft Image Cookbook and
  `ubuntu-image`/`ukpack` schemas, kernel.org's projected LTS dates, upstream
  U-Boot releases, and external firmware pins can move independently. Each can
  invalidate the proposed build inputs without changing any YSP source.
- **Last checked:** 2026-08-01
- **State 2026-08-01:** Ubuntu 26.04 publishes a generic arm64 preinstalled
  server image. Canonical's Image Cookbook explicitly covers unsupported
  hardware with a device PPA and Ubuntu-archive userspace; its image-definition
  reference is labelled for `ubuntu-image` 3.6.0 and its gadget reference can
  encode raw firmware plus GPT/ESP/root structures. The cookbook remains draft.
  kernel.org lists 6.18 as longterm with projected EOL December 2028. The local
  upstream U-Boot source inspection is a non-release tip
  `6741b0dfb41` (`v2026.07-730-g6741b0dfb41`) with no board boot result; select
  and re-pin a released tag before implementation. No image, clean
  `linux-rock5b` package, gadget, or final boot chain has been built or tested.
  Evidence and source links:
  [`findings/2026-08-01-stock-ubuntu-rock5b-successor-architecture.md`](./findings/2026-08-01-stock-ubuntu-rock5b-successor-architecture.md);
  durable design:
  [`docs/ubuntu-rock5b-image-plan.md`](./docs/ubuntu-rock5b-image-plan.md).

<a id="watch-w25"></a>
### W25 — libmpp VP9 repeated-reference output ownership

- **Why recheck:** This userspace leg was separated from the July VA-API and
  kernel crash fixes but never received its own status owner. The existing
  reproducer gates decoder process success and a clean kernel journal, so it
  reports PASS while retaining libmpp slot assertions and buffer cleanup in
  every process log. Rockchip's userspace MPP source and issue tracker can
  change independently of the kernel series.
- **Last checked:** 2026-08-05
- **State 2026-08-05:** Fixed in public `yisding/ysp/main@a8b19653` and closed
  in the installed normal-PPA package. Generic slot
  queues now store distinct occurrence nodes, and VP9 show-existing output
  snapshots its presentation frame with one owned buffer reference. The new
  base regression queues 40 events on one slot and recovers every distinct
  PTS/DTS in order. `mpi_dec_test`, `mpi_dec_nt_test`, and `mpi_dec_mt_test`
  each produce the full 16-image, 2,433,024-byte vector exactly matching the
  software NV12 oracle. The original 30×4 stress has 120/120 successful
  decoders, no slot/refcount/leak diagnostic, and no deferred kernel fault.
  H.264/H.265/VP9/AV1 differential decode remains bit-exact for 30 frames each.
  Official Launchpad API and APT-index checks now report source publication
  `18657949` Published and arm64 build `33468629` successful. The live normal
  PPA selects `1.5.0+git20260805.a8b19653+ds-0ubuntu1~rk1`, and that exact
  runtime, development library, VPU library, and demo set is installed.
  Installed-package replay on rewrite KASAN boot `g19634f4eebba` reproduces
  the three 16-frame/2,433,024-byte outputs at the software oracle SHA-256,
  passes 120/120 concurrent stress decoders with zero ownership/leak
  diagnostic, keeps all four 30-frame codec differentials bit-exact, and
  passes the official MPP suite 12/12. The exact VP9, stress, differential,
  and official-suite journal intervals contain zero fatal kernel line.
  Detail:
  [`findings/2026-08-04-libmpp-vp9-show-existing-reference-slot-leak.md`](./findings/2026-08-04-libmpp-vp9-show-existing-reference-slot-leak.md).
- **State 2026-08-04:** Root-caused against installed package
  `1.5.0+git20260730.ad325345+ds-0ubuntu1~rk1`. The retained vector's final
  eight show-existing packets select `6,7,3,4,5,6,7,3`; the parser can enqueue
  those events before the HAL thread drains output. `mpp_buf_slot_enqueue()`
  has one intrusive list node per slot and unconditionally removes/re-adds it,
  but charges every enqueue. The three repeated reference identities therefore
  match the three physical slots left at `display=2`. Output uses a shallow
  `mpp_frame_copy()` without acquiring a buffer ref for each repeated
  presentation. In 30×4 direct-MPP runs: 120/120 processes exit 0, with 720
  slot assertions, 240 non-positive buffer-ref reports, 120 three-frame pool
  residues, and 120 leaked-buffer cleanup lines; the kernel window is clean.
  Those runs request `-n 16`, so `mpi_dec_test` rewinds the under-producing
  stream and partially decodes it again. A one-pass `-n 0` run proves the
  visible consequence: libmpp outputs 13 image frames versus software's 16,
  matching frames 0–7 and then retaining only software frames 11–15; the first
  presentations of repeated identities `6`, `7`, and `3` are dropped.
  A fresh fetch puts Rockchip `develop` at `df4864bd1e90` (2026-07-28), still
  carrying the same VP9 and queue code; public issue/PR searches find no fix.
  Next proof is a libmpp patch that queues distinct presentation events with
  snapshotted PTS/DTS and one buffer ref per event, followed by count/order,
  framehash, PTS, and teardown-clean regression on this vector. Detail:
  [`findings/2026-08-04-libmpp-vp9-show-existing-reference-slot-leak.md`](./findings/2026-08-04-libmpp-vp9-show-existing-reference-slot-leak.md).
