# STATUS — project-wide dashboard (dated)

Whole-project state at a glance. The [forward-port scorecard](./kernel-drivers/docs/forward-port-status.md)
owns durable kernel capability evidence; this page owns the live public
boundary across **every** track.

**How to read it.** Every row carries a **last-verified date** — trust a row
only as of its date. Facts that can go stale *silently* (external PRs/MRs,
distro versions, and installed board state) are concentrated in the
[watchlist](#watchlist--facts-that-go-stale-silently) so routine maintenance
means re-checking one list. Update rule: the
[resyncing guide §6](./kernel-drivers/docs/resyncing.md) update-propagation table names this page
whenever a gate changes. The canonical status and optional-ledger procedure is in
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
stays in the linked project or finding; no separate cross-project ledger is
currently needed. The next proof is kept in the separate table below so both
remain scannable.

| # | Track | Public state | Verified | Detail |
|---|-------|--------------|----------|--------|
| 1 | Kernel forward-port | ⚠️ The exact published and installed forward-port kernel has a green functional/recovery verdict and encode soak. Its 4K decode workload and kernel scan pass, but the strict userspace resource oracle is red. Exact-tail KASAN/lockdep, targeted hostile paths, root counters, and authenticated display integration remain open; [W16](#watch-w16) owns the moving source/package identity. | 2026-08-04 | [production validation](./findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md), [series status](./kernel-drivers/docs/forward-port-status.md) |
| 2 | BSP-audit fixes | 🚧 All 11 remaining distinct HIGH audit bugs are ported as `0058`–`0068`; the combined tail passed KASAN, destructive-path, production conformance, and root gates. Several fixes still lack individual hostile-path tests, and the older 65-patch MEDIUM/LOW cleanup series remains unshippable. | 2026-07-24 | [BSP audit](./kernel-drivers/docs/bsp-audit.md), [port record](./findings/2026-07-22-bsp-high-current-tip-port.md), [patch catalog](./kernel-drivers/docs/patch-catalog.md) |
| 3 | DKMS channel | ⚠️ Compiles on 6.18; its DT overlay is dtc-validated but not boot-validated. | 2026-07-01 | [`packaging/dkms/`](packaging/dkms/README.md) |
| 4 | Clean-room rewrite drivers | 🚧 The repaired 6.18 KASAN package boots with exact 92/152 KUnit and 12/12 official MPP. Corrected librga reaches 21/34 required cases and narrows the remaining RGA2 failures to plain-system-heap DMA-BUF routing and USERPTR bounce alignment. Exact-tip fix package `P49e6-Cad24` is built and package-verified but uninstalled and unbooted. AV1/VSI, recovery, performance, fuzz, and soak qualification remain open. | 2026-08-05 | [RGA2 bounce follow-up](./findings/2026-08-05-rewrite-rga2-dmabuf-userptr-bounce-followup.md), [architecture guide](./kernel-drivers/docs/rewrite-driver-architecture/README.md) |
| 5 | ffmpeg tree | ⚠️ The asynchronous RKMPP frame-lifetime fix passes source and focused hardware gates. Its published/install state belongs to [W05](#watch-w05); installed-package GRD fallback/recreation and AV1 container validation remain open. | 2026-08-05 | [lifetime fix and gate](./findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md), [FFmpeg project](./video-libraries/ffmpeg/README.md) |
| 7 | GNOME Remote Desktop backend | 🚧 The release branch is installed and the kernel preconditions for the reconnect gate are met, but the authenticated idle reconnect has not run. The separate watchdog/forced-IDR candidate is built but absent from the installed binary and has no runtime proof. | 2026-08-04 | [reconnect finding](./findings/2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md), [watchdog finding](./findings/2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md) |
| 8 | Mesa / Panfrost | 🔄 Selected G610 shards passed on the recorded MR heads, but all four MRs remain unmerged and one needs rebase; refreshed CI is also owed on the updated transfer MR. [W06](#watch-w06) owns the live MR state. | 2026-08-04 | [`video-libraries/mesa/`](video-libraries/mesa/README.md) |
| 9 | Launchpad PPA | ✅ The normal PPA provides the complete nine-source system stack; the exact kernel and MPP packages are installed and hardware-validated. The FFmpeg successor is Published but not installed or integration-tested, VA-API still needs exact PPA-binary replay, and incompatible-stack migration remains a separate operational gate. [W05](#watch-w05) owns live publication identities. | 2026-08-05 | [PPA packaging](./packaging/ppa/README.md), [new-user guide](./docs/ppa-support.md) |
| 10 | Binary publishing | ❌ Repository licensing is defined, but no GitHub release, artifact set, or checksummed manifest exists. | 2026-08-05 | [`packaging/`](packaging/README.md), [`LICENSE.md`](LICENSE.md) |
| 11 | Kodi HW decode | 🚧 Decoder selection and media prerequisites are ready; Kodi build, tty1 playback, and packaging remain unproven, and the PPA publishes no Kodi package. | 2026-08-04 | [`apps/kodi/`](apps/kodi/README.md) |
| 12 | ROCK 5B SD/SPI boot chain | ⚠️ SPI → NVMe works; failing vendor raw artifacts have zero-byte U-Boot control DTBs, while the untested 26.5.1 `current` candidate has a valid DTB. | 2026-07-11 | [U-Boot comparison](./boot-firmware/docs/version-comparison.md) |
| 13 | Maximum-mainline kernel | 🚧 Refreshed public and WIP sources are reconciled with their upstream bases; the public profile passes a full native compile and WIP passes focused/partial builds. Refreshed packages, boot, and hardware validation remain open. | 2026-08-02 | [refresh audit](./findings/2026-08-02-rk3588-maxline-proposal-refresh.md), [`kernel-maxline/`](./packaging/ppa/kernel-maxline/README.md) |
| 14 | Desktop-app HW video (browsers) | 🚧 The current VA-API release passes its retained driver gates, and Google Chrome selects hardware decode for proven H.264 and VP9 cases. The exact PPA binary is not installed, browser replay remains manual, and the live Chrome GPU process was unsandboxed; automated pixel checks, sandbox proof, and the remaining app/display boundaries are open. | 2026-08-05 | [Chrome/driver finding](./findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md), [`rockchip-vaapi` project](./video-libraries/vaapi/README.md) |
| 15 | CPU voltage binning (PVTM/eFuse) | ❌ No patch, branch, or build exists. The board's BSP-selected L5/L7/L7 voltage columns are measured and materially lower than mainline's worst-die table below 2.4 GHz; the two-track port plan is gated by cold-boot, SRAM-margin, and shared-DSU-rail validation. | 2026-07-27 | [port plan](./kernel-versions/docs/pvtm-opp-binning-plan.md), [measured index](./findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md) |

## Next gates

A next gate is the smallest result that would materially advance its track, not
a general wish list. The action path points to the maintained runbook, exact
evidence owner, or decision boundary; keep it usable when a gate changes. Close
or replace a gate only with evidence from the owning detail page, and update the
dashboard date when public state changes.

| # | Track | Next proof | Action path |
|---|-------|------------|-------------|
| 1 | Kernel forward-port | Exercise exact `0092` under KASAN/lockdep through RGA cancellation/session-close and decoder recovery/reset contention; then capture root-only debugfs counters and remaining targeted hostile paths. | [production validation gaps](./findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md#remaining-qualification-gaps), [0092 verification gate](./findings/2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md#verification-gate) |
| 2 | BSP-audit fixes | Add targeted hostile-path gates for the acquire-fence, shutdown, missing-plane, and partial-handle fixes that broad conformance does not exercise. | [runtime gate inventory](./kernel-drivers/patches/cleanup-draft/verification.md#runtime-gate-result-record-here-when-run), [port record](./findings/2026-07-22-bsp-high-current-tip-port.md) |
| 3 | DKMS channel | Install on a stock 6.18 ROCK 5B, boot the overlay, and run `validate-combined.sh`. | [DKMS build and install](./packaging/dkms/README.md#dkms-build-install) |
| 4 | Clean-room rewrite drivers | Install and boot exact-tip 6.18 package `P49e6-Cad24`, then require exact KUnit/MPP plus the DMA-BUF reroute and USERPTR zero-failure counter contract in the corrected librga suite. | [RGA2 bounce verification gate](./findings/2026-08-05-rewrite-rga2-dmabuf-userptr-bounce-followup.md#boundary-and-verification-gate), [rewrite validation plan](./kernel-drivers/docs/rewrite-validation-plan.md) |
| 5 | ffmpeg tree | Install exact Published `c9428bedaa`, then repeat GRD hardware timeout, software fallback, and encoder recreation while requiring a clean libmpp/kernel log; afterward re-test AV1 from MP4/MKV. | [lifetime integration gate](./findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md#verification-gate) |
| 7 | GNOME Remote Desktop backend | Run the documented authenticated idle reconnect without restarting the daemon; then install the watchdog candidate before attempting its recovery/VBR gates. | [reconnect reproduction](./findings/2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md#act-4-latest-gnome-50-rebase-and-narrowed-june-fix-salvage), [watchdog gate](./findings/2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md#verification-gate) |
| 8 | Mesa / Panfrost | Rebase !42614, then rerun selected G610 CI on it and on !42679's post-07-23 head. | [W06 MR tips and selected CI](#watch-w06) |
| 9 | Launchpad PPA | Confirm the uploaded FFmpeg source server-side, install the resulting package, and replay its GRD integration gate. | [W05 publication record](#watch-w05), [FFmpeg integration gate](./findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md#verification-gate) |
| 10 | Binary publishing | Select the first release's exact source/binary artifacts, verify each artifact's complete corresponding-source and third-party redistribution obligations, then publish a versioned checksummed manifest. | [license scope](./LICENSE.md), [artifact policy](./packaging/README.md) |
| 11 | Kodi HW decode | Build Kodi GBM/GLES and validate RKMPP playback with `kodi-gbm` on tty1. | [Kodi tty1 runbook](./apps/kodi/docs/build-hwaccel.md#5-test-on-tty1-gbm-needs-drm-master) |
| 12 | ROCK 5B SD/SPI boot chain | Substitute the 26.5.1 `current` FIT, loader, and then both on a captured 26.2.1 SD baseline; record where each boot stops or succeeds. | [raw-SD hypothesis test](./scripts/README.md#rock-5b-raw-sd-u-boot-hypothesis-test) |
| 13 | Maximum-mainline kernel | Build and inspect refreshed `public` packages, then install with serial recovery and the known-good 6.18 packages retained; prove boot, storage, network, display, suspend, and rollback before `wip`. | [recovery-first test order](./packaging/ppa/kernel-maxline/README.md#install-and-test-order) |
| 14 | Desktop-app HW video (browsers) | Install and replay the exact PPA VA-API binary, then automate pixel-checked Chrome H.264/VP9/HEVC selection while proving the live GPU process is sandboxed. | [Chrome automation/sandbox gate](./findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md#boundary-and-next-gate), [package replay gate](./video-libraries/vaapi/README.md) |
| 15 | CPU voltage binning (PVTM/eFuse) | Boot a non-PPA static L5/L7 board override and prove each policy's selected rail voltage under verified compute load, including cold-boot and data-integrity checks. | [validation plan](./kernel-versions/docs/pvtm-opp-binning-plan.md#5-validation-plan-both-tracks), [measured baseline](./findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md) |


## Status Ledger

No separate status ledger is currently needed: every track routes directly to
the project document, package record, or live finding that owns its evidence.
The optional-ledger rule remains in [`CONTRIBUTING.md`](CONTRIBUTING.md) if a
future track has irreducible cross-project synthesis. Keep this page as the
compact dashboard, next-gate queue, and watchlist of facts that can change
silently.

<a id="watchlist--facts-that-go-stale-silently"></a>

## Watchlist — facts that go stale silently

Re-check these on a maintenance pass. The index is the quick scan; each linked
detail names its external authority, exact recheck, freshness boundary, and the
state observed on its last-checked date.

| ID | Watch item | Last checked | Summary |
|----|------------|--------------|---------|
| W01 | [Armbian media-patch drift](#watch-w01) | 2026-08-04 | Patch blobs unchanged; DT anchors still hold. |
| W02 | [Armbian patcher precedence](#watch-w02) | 2026-08-04 | Core-wins behavior unchanged; rename workaround still required. |
| W04 | [Ubuntu FFmpeg version](#watch-w04) | 2026-08-04 | Resolute still publishes `7:8.0.1-3ubuntu2`. |
| W05 | [Launchpad PPA publication](#watch-w05) | 2026-08-05 | All nine normal-PPA source names are Published. FFmpeg `c9428bedaa` now has Published source and binaries and is selected by the arm64 index, but remains uninstalled; kernel/MPP are installed and validated, while VA-API still needs exact PPA-binary replay. |
| W06 | [Mesa MR stack](#watch-w06) | 2026-08-04 | Four MRs still open; the rebase need moved from !42679 to !42614. |
| W07 | [`ffmpeg-rockchip-81` tips](#watch-w07) | 2026-08-04 | `main` unchanged, but `ffmpeg-80` and `ffmpeg-81` both moved; their replay evidence is stale. |
| W10 | [GRD release and recovery branches](#watch-w10) | 2026-08-04 | Release remains `c4ef3c9`; the unshipped forced-IDR recovery branch remains `100da72`. Package/board state routes to W05 and track 7. |
| W16 | [Forward-port kernel-fix tail](#watch-w16) | 2026-08-04 | The board boots `6.18.42-ysp-rockchip64`, with exact matching image/DTB/headers installed. W05 owns moving publication state; track 1 and the linked findings own validation. |
| W17 | [Maximum-mainline proposal-set drift](#watch-w17) | 2026-08-02 | Refreshed against current proposal mail, Torvalds master, linux-next, and subsystem-next refs; future “maximum current” claims still require another deliberate audit. |
| W18 | [rockchip-vaapi fork state](#watch-w18) | 2026-08-05 | Public fork `main` is `70f26d9`; recorded upstream is `e8c64dd`. W05 and track 14 own publication, installed-package, and browser state. |
| W20 | [Intermittent Plymouth initramfs-daemon boot stall](#watch-w20) | 2026-07-23 | The stall recurred with the parser fix installed, falsifying that loop as the sole cause. Disable Plymouth for mitigation; capture the next wedged daemon live. |
| W22 | [RK3588 per-die voltage binning absent from mainline](#watch-w22) | 2026-07-27 | Still absent at maxline `fac7077731585`; the maintained plan and finding own the measured board entitlement and implementation consequences. |
| W23 | [Ramoops retention reversal & the 6.18.38 kernel A/B](#watch-w23) | 2026-07-28 | **Ramoops recovers records across warm reboots on every 6.18.40-era kernel** — ≥9 recoveries in the retained journal since 2026-07-26, same firmware stack — so the documented all-zero failure is scoped to the 6.18.38-era kernels and the firmware-phase hypothesis is retired. The four-reboot kernel A/B on the still-installed `6.18.38-current` is pending; the 2026-07-27 19:38 GRD-SG oops dump is archived in `/var/lib/systemd/pstore/`. |
| W24 | [ROCK 5B stock-Ubuntu image inputs](#watch-w24) | 2026-08-01 | Ubuntu 26.04 image/schema, Linux 6.18 LTS, and upstream U-Boot/firmware references remain the external design inputs; re-pin them before implementation. |

<a id="watch-w01"></a>
### W01 — Armbian media-patch drift

- **Authority:** remote — `armbian/build` main and its `rockchip64-6.18` media
  patch blobs.
- **Recheck:** Fetch the remote tip, then compare `media-0001` and `media-0007`
  blob IDs with `git ls-tree` before replaying the resync checklist.
- **Freshness:** Unknown after either media blob changes or the remote cannot be
  read; an unrelated main-tip move does not invalidate the cached blob result.
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

- **Authority:** remote — `armbian/build` `lib/tools/patching.py` on main.
- **Recheck:** Fetch the remote file and inspect/diff the three ordering anchors
  named below with `git show` before relying on the rename workaround.
- **Freshness:** Unknown after the patcher blob or any named anchor changes;
  keep the cached conclusion only when a fresh inspection preserves all three.
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

- **Disposition:** Retired 2026-08-05 — the upstream merge is a resolved package
  compatibility fact, not a live cache. The
  [`codec-udev` package owner](packaging/ppa/codec-udev/README.md) explains when
  the rule is native and when the package backfills older/custom images.

<a id="watch-w04"></a>
### W04 — Ubuntu FFmpeg version

- **Authority:** service — Launchpad's Ubuntu Resolute archive publications.
- **Recheck:** Query Launchpad `getPublishedSources` for source name `ffmpeg` in
  Resolute `Release` and compare the highest Published version.
- **Freshness:** Unknown after a newer publication appears, the API query fails,
  or immediately before changing the package hold/replacement policy.
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

<!-- ppa-live-ffmpeg: 7:8.0.3+rockchip+git20260730.c9428bedaa-0ubuntu1~rk1 -->
<!-- ppa-live-grd: 50.2+rkmpp+git20260729.15.c4ef3c9-0ubuntu1~rk2 -->

- **Authority:** service — Launchpad's `ubuntu-rock-5b` source, build, binary,
  and archive-index records.
- **Recheck:** Query `getPublishedSources`, each relevant build and binary
  publication, and the Resolute arm64/all indexes; compare exact identities
  before install or migration.
- **Freshness:** Unknown after every upload or pending status transition, after
  an API/index failure, and before claiming a package is newly installable.
- **Why recheck:** Acceptance, build state, and binary publication can change
  after upload without a local repository edit.
- **Last checked:** 2026-08-05
- **State 2026-08-05:** Official Launchpad API rechecks list nine Published
  source packages in the normal PPA. Forward-port source publication `18656958`
  is `Published` and arm64 build `33467257` `Successfully built`; the normal
  PPA index exposes the same `0092` image, DTB, and headers installed on the
  board. MPP source publication `18657949` is also `Published`, build
  `33468629` is `Successfully built`, and the live index selects
  `1.5.0+git20260805.a8b19653+ds-0ubuntu1~rk1`. All four
  installed MPP runtime/development/demo packages report that exact version;
  the maintained [MPP evidence basis](./vendor-libraries/mpp/docs/mpp-library-architecture.md#vp9-presentation-event-ownership)
  owns the installed-runtime closure. This closes the
  forward-port publication/install/boot milestone. VA-API ysp13 source
  publication `18657954` is Published, arm64 build `33468630` succeeded, and
  live binary publications include the driver `247800963` and its
  architecture-independent config package; those PPA-built binaries have not
  replaced the same-version local build. A later authoritative recheck found
  FFmpeg `c9428bedaa` source publication `18658504` Published, arm64 build
  `33469512` successful, all 29 binary publications `247812235`–`247812263`
  Published, and the live arm64 index selecting the exact package. It remains
  uninstalled and its GRD integration gate remains open. GRD source publication
  `18654077`, arm64 build `33461880`, and binary publication `247717203` remain
  Published; the live index selects the exact installed `~rk2` version. A clean-install run is still useful
  when migrating a different machine from incompatible PPAs; it is not missing
  evidence for the already-published kernel artifact.
<a id="watch-w06"></a>
### W06 — Mesa MR stack

- **Authority:** remote — GitLab merge-request, head, pipeline, and detailed
  merge-status records for !42563, !42679, !42613, and !42614.
- **Recheck:** Query all four GitLab MR API records and the pipelines attached
  to their returned heads; do not infer mergeability from the web UI.
- **Freshness:** Unknown after any `updated_at`, head, state, merge-status, or
  pipeline change, or whenever GitLab declines the API query.
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

- **Authority:** remote — `yisding/ffmpeg-rockchip-81` branch refs.
- **Recheck:** Run `git ls-remote` for `main`, `ffmpeg-80`, and `ffmpeg-81`, then
  compare each returned head with the pin whose evidence is being reused.
- **Freshness:** Unknown after any branch head moves or the remote query fails;
  source/FATE or hardware evidence never carries across an unreviewed move.
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
  `nyanmisaka/ffmpeg-rockchip@388741a3544b` matches the tip named in the
  [async-frame lifetime finding](findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md)
  as sharing the defect. The dedicated PPA remains at `be367abfe6`; separate normal-PPA branch
  `fix/rkmpp-output-timeout@da5befc806` is public, built, and Published, with its
  combined GRD hardware gate still pending.

<a id="watch-w08"></a>
### W08 — AV1 container-extradata validation

- **Disposition:** Retired 2026-08-05 — this is an internal validation gate, not
  silent external drift. [Status track 5](#dashboard) owns the one next proof;
  the [Kodi/FFmpeg finding](findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md)
  retains the `av1C` fix and evidence boundary.

<a id="watch-w09"></a>
### W09 — Kodi build and tty1 playback

- **Disposition:** Retired 2026-08-05 — build/playback is active internal work
  and PPA membership is already cached by W05. [Status track 11](#dashboard)
  owns the public boundary and next proof; the
  [Kodi front door](apps/kodi/README.md) and
  [tty1 runbook](apps/kodi/docs/build-hwaccel.md) own the operation.

<a id="watch-w10"></a>
### W10 — GRD release and recovery branches

- **Authority:** remote — `yisding/gnome-remote-desktop` release and
  forced-IDR-recovery branch refs.
- **Recheck:** Run `git ls-remote` for `release/50.2-rkmpp` and
  `fix/forced-idr-recovery`; W05 separately rechecks package publication.
- **Freshness:** Unknown after either branch moves or the query fails; board
  installation and reconnect evidence remain owned by status track 7.
- **Why recheck:** A branch move changes the source identity behind package or
  reconnect/recovery evidence without changing this repository.
- **Last checked:** 2026-08-04
- **State 2026-08-04:** `release/50.2-rkmpp` remains at public release
  `c4ef3c9`; `fix/forced-idr-recovery` remains at `100da72` directly above it.
  W05 owns the package publication cache. [Status track 7](#dashboard), the
  [reconnect evidence](findings/2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md),
  and the [recovery finding](findings/2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md)
  own installed state, measured results, and next proofs.

<a id="watch-w11"></a>
### W11 — Repository-wide license

- **Disposition:** Retired 2026-08-05 — repository licensing is a stable policy
  owned by [`LICENSE.md`](LICENSE.md); [status track 10](#dashboard) owns the
  still-open artifact redistribution/publication boundary.

<a id="watch-w12"></a>
### W12 — Dev-box-only artifacts

- **Disposition:** Retired 2026-08-05 — the identified at-risk artifacts are
  captured and workspace hygiene is a repository rule, not a changing host
  fact. [`external-workspaces.md`](packaging/external-workspaces.md) owns the
  reconstruction/disposition map; [`CONTRIBUTING.md`](CONTRIBUTING.md) owns the
  no-build-artifacts contract.

<a id="watch-w13"></a>
### W13 — librga P010/P210 series

- **Disposition:** Retired 2026-08-05 — the paired kernel/librga ABI and measured
  10-bit boundary are resolved project knowledge. The maintained
  [P010/P210 contract](vendor-libraries/rga/docs/librga-p010-p210-rkrga.md)
  owns the shipping rule; the
  [KASAN validation](findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md)
  retains the exact exercised identity and signals.

<a id="watch-w14"></a>
### W14 — YSP Armbian builder

- **Disposition:** Retired 2026-08-05 — the completed build and wrapper behavior
  are stable evidence rather than a current host cache. The
  [kernel-build owner](kernel-drivers/docs/kernel-builds.md) and
  [builder finding](findings/2026-07-08-armbian-builder-setup.md) retain the
  exact identity, resource boundary, and recovery rule.

<a id="watch-w15"></a>
### W15 — RGA session-close fix vs. the frozen import

- **Disposition:** Retired 2026-08-05 — this is checked-in regeneration debt,
  so it cannot drift without a repository change. The
  [patch catalog](kernel-drivers/docs/patch-catalog.md),
  [resyncing guide](kernel-drivers/docs/resyncing.md), and
  [session-close finding](findings/2026-07-17-rga-session-close-uaf.md) own the
  fix, frozen-import boundary, and next regeneration action.

<a id="watch-w16"></a>
### W16 — Forward-port kernel-fix tail

- **Authority:** board — the ROCK 5B's booted kernel and installed package
  database; W05 separately owns Launchpad publication state.
- **Recheck:** Compare `uname -r` and `uname -v` with `dpkg-query` versions for
  image/DTB/headers, then follow the production-validation identity checks.
- **Freshness:** Unknown after any kernel package operation, boot-selection
  change, reboot into another kernel, payload modification, or unavailable board.
- **Why recheck:** The frozen base pair, maintained split series, PPA package,
  and booted debug build can silently carry different kernel-fix tails. Keep the
  exported patch tail and the claimed production gate aligned with the exact
  KASAN evidence.
- **Last checked:** 2026-08-04
- **State 2026-08-04:** The board boots `6.18.42-ysp-rockchip64`; installed
  image, DTB, and headers match source package
  `6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1`, whose maintained/exported
  source identity is `7d53bc7a3adc` / `0001`–`0092`. W05 owns current
  Launchpad publication. The
  [production validation](./findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md)
  and [fix finding](./findings/2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md)
  own the exercised gates and remaining qualification boundary.

<a id="watch-w17"></a>
### W17 — Maximum-mainline proposal-set drift

- **Authority:** remote — kernel.org branches, public proposal revisions, and
  subsystem integration branches consumed by the maxline manifest.
- **Recheck:** Refresh the remote refs/proposal revisions and rerun the
  package-owned manifest/range audit before making a newer maximum claim.
- **Freshness:** Unknown after any consumed ref or proposal revision moves, or
  when a required remote cannot be inspected.
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

- **Authority:** remote — `yisding/rockchip-vaapi` main and its recorded
  `woodyst/rockchip-vaapi` upstream head.
- **Recheck:** Run `git ls-remote` for both main refs and compare the returned
  commits with the source identities whose validation is being reused.
- **Freshness:** Unknown after either head moves or a remote query fails;
  publication and installed/browser evidence remain with W05 and track 14.
- **Why recheck:** The VA-API-driver track lives in an external fork, not this
  repo; the fork branch and the upstream it descends from move independently
  of any change here.
- **Last checked:** 2026-08-05
- **State 2026-08-05:** Public fork `main` is `70f26d9`; recorded upstream
  `woodyst/main` is `e8c64dd`. These identities do not carry validation forward
  if either ref moves. The
  [VA-API owner](video-libraries/vaapi/README.md) and
  [stable-export finding](./findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md)
  retain the release mechanism and exercised evidence; W05 and dashboard track
  14 own changing publication and installed/browser state.

<a id="watch-w19"></a>
### W19 — MPP `INIT_CLIENT_TYPE` double-call → use-after-free

- **Disposition:** Retired 2026-08-05 — the verified `-EBUSY` re-init guard is
  resolved kernel knowledge, not external state. The public
  [patch catalog](kernel-drivers/docs/patch-catalog.md) and
  [root-cause finding](findings/2026-07-22-mpp-process-request-list-add-double-add-warn.md)
  retain behavior, patch identity, trust, and validation. The working
  memory-corruption reproducer remains only in the private `rock-5b-security`
  repository and is not linked or reproduced here.

<a id="watch-w20"></a>
### W20 — Intermittent Plymouth initramfs-daemon boot stall

- **Authority:** board — the ROCK 5B boot transaction, initramfs payload, and
  live `plymouthd` task state.
- **Recheck:** On the next stall use `debug-shell.service` and
  `plymouth.debug=stream:/dev/ttyS2` to capture the daemon's stack, `wchan`, and
  syscall before reset; use `plymouth.enable=0` for the exclusion boot.
- **Freshness:** Unknown after kernel, initramfs, Plymouth package, serial-console,
  or boot-argument changes; a healthy boot alone does not close an intermittent hit.
- **Why recheck:** Intermittent, so it goes quiet between hits and is easy to
  misattribute. Two boots on 2026-07-22 (`#3` and `#6`) never reached
  `sysinit.target` and were hard power-cycled. The loud
  `systemd-networkd-wait-online` timeout in the log is **not** the cause — it is
  chronic and non-fatal (the healthy boot logs the identical timeout *and* the
  identical PCIe PMU-notifier lockdep splat, yet reaches `graphical.target`).
  Stays live until the internal wedge is captured live (the parser fix alone
  did **not** stop it), or Plymouth is disabled for an exclusion boot.
- **Last checked:** 2026-07-23
- **State 2026-07-23:** The stall recurred with the patched `~rk1` Plymouth
  verified in the booted initramfs, so the incomplete-CSI parser loop is not
  the sole cause. `plymouth.enable=0` remains the mitigation and exclusion
  test. On the next hit, capture the wedged daemon before reset as specified by
  the recheck above. The
  [initial mechanism finding](./findings/2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md)
  and [recurrence finding](./findings/2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md)
  own the transaction evidence and attribution history; W05 owns publication.

<a id="watch-w21"></a>
### W21 — ffmpeg-rockchip `rkmpp` transcode deadlock without the `da5befc806` backpressure fix

- **Disposition:** Retired 2026-08-05 — the version-attribution trap and
  backpressure fix are stable FFmpeg evidence, while moving branch heads belong
  to W07. [`fix-candidates.md`](video-libraries/ffmpeg/docs/fix-candidates.md)
  owns the mechanism and
  [the validation finding](findings/2026-07-23-forward-port-current-tip-full-validation-run.md)
  owns the exercised binaries, pass/fail signals, and kernel exclusion.

<a id="watch-w22"></a>
### W22 — RK3588 per-die voltage binning absent from mainline

- **Authority:** remote — kernel.org Linux source and Rockchip DT bindings.
- **Recheck:** Search current `drivers/soc/rockchip/`, `drivers/cpufreq/`,
  `cpufreq-dt-platdev.c`, and RK3588 OPP DT for a per-die selector and its cells.
- **Freshness:** Unknown after the inspected kernel ref moves or the source
  cannot be fetched; the board's measured L5/L7/L7 entitlement is stable evidence.
- **Why recheck:** Whether upstream gains RK3588 eFuse-driven OPP selection is an
  external fact that changes without a repository edit, and it is the difference
  between our mainline-based kernels running vendor **worst-die** voltages and
  running per-part ones. It also gates any honest BSP-vs-forward-port power or
  thermal comparison: without this, such a comparison measures the missing
  driver, not the port. Watch `drivers/soc/rockchip/`, `drivers/cpufreq/` for a
  rockchip entry, and `rk3588-opp.dtsi` for `opp-supported-hw`.
- **Last checked:** 2026-07-27
- **State 2026-07-27:** Still absent at maxline `v7.2-rc5-252`
  (`fac7077731585`): no RK3588 per-die selector or required DT cells, and
  `rk3588-opp.dtsi` remains the flat table. The
  [measured-entitlement finding](./findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md)
  and [implementation plan](./kernel-versions/docs/pvtm-opp-binning-plan.md)
  own the stable board measurements, upstream-shape analysis, and next gate.

<a id="watch-w23"></a>
### W23 — Ramoops retention reversal & the 6.18.38 kernel A/B

- **Authority:** board — the ROCK 5B firmware/kernel combination and its
  `/sys/fs/pstore` / `/var/lib/systemd/pstore` records.
- **Recheck:** Run the maintained write → warm reboot → read probe on the
  6.18.40 kernel and still-installed 6.18.38 control without booting BSP between.
- **Freshness:** Unknown after kernel, DTB, firmware, ramoops-layout, or pstore
  service changes, or when the post-reset archive was not captured.
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

- **Authority:** remote — Canonical image/cookbook/schema publications,
  kernel.org LTS records, upstream U-Boot releases, and external firmware refs.
- **Recheck:** Review the current Ubuntu arm64 image and schema references,
  kernel.org LTS table, and released U-Boot/firmware refs; use `git ls-remote`
  for source heads before re-pinning the implementation plan.
- **Freshness:** Unknown after any newer point image, schema, LTS designation,
  U-Boot release, or firmware ref, or when a source cannot be queried.
- **Why recheck:** Ubuntu point images and seeds, the draft Image Cookbook and
  `ubuntu-image`/`ukpack` schemas, kernel.org's projected LTS dates, upstream
  U-Boot releases, and external firmware pins can move independently. Each can
  invalidate the proposed build inputs without changing any YSP source.
- **Last checked:** 2026-08-01
- **State 2026-08-01:** Ubuntu 26.04 publishes a generic arm64 preinstalled
  server image; Canonical's draft Image Cookbook covers unsupported hardware
  with a device PPA and records `ubuntu-image` 3.6.0 schemas. kernel.org lists
  Linux 6.18 as longterm through December 2028. The inspected U-Boot identity
  `6741b0dfb41` is a non-release tip, so select and re-pin a released tag before
  implementation. Evidence and source links:
  [`findings/2026-08-01-stock-ubuntu-rock5b-successor-architecture.md`](./findings/2026-08-01-stock-ubuntu-rock5b-successor-architecture.md);
  durable design:
  [`docs/ubuntu-rock5b-image-plan.md`](./docs/ubuntu-rock5b-image-plan.md).

<a id="watch-w25"></a>
### W25 — libmpp VP9 repeated-reference output ownership

- **Disposition:** Retired 2026-08-05 — the defect is resolved knowledge, not
  an external fact that can go stale silently. The maintained
  [MPP presentation-event model and evidence basis](./vendor-libraries/mpp/docs/mpp-library-architecture.md#vp9-presentation-event-ownership)
  owns the mechanism, repair, validation result, trust, and boundary. [W05](#watch-w05)
  remains the dated cache for Launchpad publication state, and dashboard track
  9 remains the public package/runtime rollup.
