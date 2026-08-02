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
| 1 | Kernel forward-port | 🚧 **2026-08-01: a 6.18.41 source carrying the full 0001-0080 series was cut and uploaded** — `6.18.41+rk3588av1fwport20260801-0ubuntu1~rk1`, signed with `8F3025C4AA2228E6` and `dput` to `ppa:yi-ding/ubuntu-rock-5b` at 11:04 (all five files, upload record written). It is the first cut on a 6.18.41 base (previous were 6.18.40) and the first to carry the five commits that missed the 07-29 cut. Provenance was verified **on the published tarball**, not just the worktree: zero `*-rewrite` paths, zero `rockchip_iommu_sync_fault_handler`, and a `rockchip_iommu_set_fault_handler()` body byte-matching the forward-port tree (`c5d5c800f29b`) — the check the 20260725 cut lacked. The worktree was staged with the new `build-kernel.sh forward-port --patch-only`, which stops Armbian after patching so a source-only upload no longer needs a full compile. **Not validated:** none of the five commits has been booted, and this series has never been compiled against a 6.18.41 base by anything — Launchpad's builder is the first, on a version number that cannot be reused if it fails. Launchpad acceptance and build status are unconfirmed from here. The provenance-repaired `…20260729-0ubuntu1~rk1` is installed on the board (`ii linux-image-ysp-rockchip64`, `/boot/vmlinuz-6.18.40-ysp-rockchip64` and its modules dir present) but has never been booted — the board runs the rewrite KASAN kernel — so the dma-buf and ISR-panic gates both remain open on their original terms. The tree has since moved past the packaged source: the PPA ships series `0001`–`0075` while `linux-6.18-rkvenc-av1-fwport` now has 80 commits on `v6.18`, a gap of exactly five — `febed97bc459` (bound user register requests), `4dba1f42ab2b` (IOMMU cookie typing / buffer-release ordering), `b7883d72b746` (rkvenc2/rkvdec2-link window wrap, atomic clocks, WARN), `c10074f4474e` (RGA job/buffer lifetime, locking, import validation), all landed 07-29 09:57–09:58, plus `14c0456c4108` (RGA mapped-SG contracts) on 07-31. The four 07-29 commits missed the 09:04 `dput` by under an hour rather than being deferred. None of the five is built, booted, or hardware-validated. The GitHub mirror is current: `yisding/linux-rock5b` `rk3588-video-6.18` is at `14c0456c4108`, zero unpushed. **A re-cut is blocked on worktree provenance, not on the code:** the exporter snapshots the shared Armbian kernel worktree, which currently holds the rewrite series, so a cut today would reproduce the 07-25 contamination that caused the ISR panic — run `build-kernel.sh forward-port` and verify the worktree before exporting.** Prior state — 2026-07-29: the installed `~rk2` kernel panicked mid-validation; root-caused same day, fixed at source, package re-cut owed.** `~rk2` was signed, Launchpad-built, and installed 07-28 16:57 (retiring the "awaiting signature" state below), and the 07-29 08:00 RDP login gate started clean — GRD's `h264_rkmpp` encoder ran ~45 s with no dma-buf oops, confirming the `DMABUF_DEBUG` fix — but at 08:01:41 the box panicked from the idle task: the vendor MPP job ISR clears the IOMMU fault handler under a spinlock, and the shipped `rockchip_iommu_set_fault_handler()` carries the rewrite-branch hardening whose `platform_get_irq()`/`synchronize_irq()` tail sleeps ("BUG: scheduling while atomic" → branch to non-executable memory → "Attempted to kill the idle task!", full ramoops record). The shipped orig is provenance-contaminated — a rewrite-composite snapshot of the shared Armbian worktree, not the validated forward-port series (the `20260723` orig and the exported `0001`–`0075` series are clean). Source fix committed on both rewrite tips (`35eb735d21dd8` / `2cf0126529c1c`, rewrite-build-gate green): the setter is atomic-safe again and the teardown wait moved to new sleepable `rockchip_iommu_sync_fault_handler()`/`vsi_iommu_sync_fault_handler()` called only from process-context unbind. Every codec job on the installed kernel remains panic-capable under `irq_domain_mutex` contention until the re-cut package is installed. The provenance-repaired `…20260729-0ubuntu1~rk1` source is built (export verified: zero `*-rewrite` paths, `rockchip-iommu.c` byte-matches the fwport tree, file list differs from the shipped orig by exactly the 8 rewrite files plus the benign regenerated `rockchip-fixup.scr`), signed, and `dput` to `ppa:yi-ding/ubuntu-rock-5b` completed client-side at 09:04; the exporter now permanently excludes rewrite paths. Launchpad acceptance/build, install, and the re-armed RDP gate remain. **Prior state — root-caused 2026-07-28: there was no memory corruption.** The installed `6.18.40+rk3588av1fwport20260725` production kernel carries the hardware-verified `0074`/`0075` tail and oopses **deterministically** on GRD's first H.264 smoke frame — 3/3 boots, and 7× within boot -1 alone — because its config sets `CONFIG_DMABUF_DEBUG=y`. That option compiles in `mangle_sg_table()` (`drivers/dma-buf/dma-buf.c` ~:831), which XORs every `page_link` with `~0xffUL` for the interval an attachment is mapped; the system heap's `end_cpu_access()` then syncs exactly those mangled tables and `sg_phys()` dereferences the scrambled entry. All **8/8** recorded fault addresses invert through that XOR to valid in-RAM page frames (0.927–10.375 GiB), and the option correlates **4/4** with reproduction across every 6.18.40 kernel on the board. This retires the toolchain confound (the earlier config sweep checked `DMA_API_DEBUG`, which matches, but missed `DMABUF_DEBUG`), the KASAN-masking theory, and the unattributed-writer boundary; the vendor-driver sweep's negative result was correct, since the writer is in the dma-buf core. **None of it is ours:** `dma-buf.c` and `system_heap.c` are byte-identical to the vanilla `Linux 6.18.40` tag and neither our series nor Armbian's touches `drivers/dma-buf`, so the defect is wholly upstream — reported by Yunfei Wang on **2022-08-31** and unfixed for nearly four years, because Christian König holds that the dma-heap is at fault rather than the debug option and no sanctioned alternative to the heaps' sync exists. The option was never chosen either: Kconfig marks it `default y if DMA_API_DEBUG`. Fix applied to the tracked config — `# CONFIG_DMABUF_DEBUG is not set` — and the `~rk2` source package is built and validated (upstream bytes provably unchanged; exactly one config line differs from `~rk1`), **awaiting signature/upload, so not yet built by Launchpad or booted**. | 2026-08-01 | [ISR panic + fix](./findings/2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md), [orig provenance](./findings/2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md), [root cause + fix](./findings/2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md), [upstream provenance + fix options](./findings/2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md), [build-provenance confound](./findings/2026-07-27-kasan-vs-production-build-provenance-confound.md), [source sweep](./findings/2026-07-27-grd-sg-writer-source-sweep-vendor-drivers-cleared.md), [ioctl window + third repro](./findings/2026-07-27-grd-sg-oops-third-repro-ioctl-window-measured.md), [oops trace](./findings/2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md), [non-reproduction](./findings/2026-07-27-grd-sg-corruption-kasan-non-reproduction.md) |
| 2 | BSP-audit fixes | 🚧 All 11 remaining distinct HIGH audit bugs are ported as `0058`–`0068`; the combined tail passed KASAN, destructive-path, production conformance, and root gates. Several fixes still lack individual hostile-path tests, and the older 65-patch MEDIUM/LOW cleanup series remains unshippable. | 2026-07-24 | [audit ledger](./docs/status-ledger.md), [patch catalog](./kernel-drivers/docs/patch-catalog.md) |
| 3 | DKMS channel | ⚠️ Compiles on 6.18; its DT overlay is dtc-validated but not boot-validated. | 2026-07-01 | [`packaging/dkms/`](packaging/dkms/README.md) |
| 4 | Clean-room rewrite drivers | 🚧 Booted KASAN/lockdep package `P91d6-Cad24` completed its then-current exact 85/85 MPP plus 148/148 RGA KTAP, but MPP case 83 disabled lockdep, so the compound gate remains red. The 2026-07-29 review-round-2 fixes repaired legacy rotate validation, hard-CCU chain ownership, scheduler wakeup, RGA fence contexts/module lifetime, shared-IRQ power gating, and a KUnit double free. The later soft-CCU fix restored the BSP arm→`CORE_STA`+`START` critical section and repaired the lockdep/poll boundary. **2026-07-30:** current committed tips 6.18 `9771d14cfa109` and mainline `5bfb81f90f05b` additionally close AV1/VSI admission, retained-fault, callback-drain, stale-AFBC, error-result, PM, remove, shutdown, and reset-wiring races, carry a byte-identical ABI ledger, and move a 6.7 KiB KUnit fixture off stack so warning-fatal builds stay green. The exact gate is now 90 MPP + 148 RGA with 326 known source-audit signals and zero new/absent; object and DTB builds pass, but no successor boot or AV1 hardware run exists, and VCD completion still lacks an independent architectural AFBC DMA-retirement proof. | 2026-07-30 | [AV1/VSI lifecycle finding](./findings/2026-07-30-rewrite-av1-vsi-fault-afbc-lifecycle-races.md), [soft-CCU wedge root cause](./findings/2026-07-29-rewrite-soft-ccu-dual-core-wedge.md), [KUnit fixture and evidence contract](./kernel-drivers/docs/rewrite-kunit.md), [review round 2](./findings/2026-07-29-rewrite-driver-review-round-2.md) |
| 5 | ffmpeg tree | ⚠️ Package branch `fix/rkmpp-output-timeout@c9428bedaa` fixes the asynchronous `MppFrame` reset/close double release. The affected object, `fate-source`, source package, and focused RK3588 gates pass: 10/10 immediate-close plus 10/10 flush/reuse, without the old libmpp refcount/pool diagnostics. Published and installed packages remain at predecessor `33a651a55b`; candidate installation and the real GRD fallback/recreation gate are pending. Canonical-tip and AV1 MP4/MKV board validation remain open. | 2026-07-30 | [lifetime fix](./findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md), [FFmpeg status](./video-libraries/ffmpeg/README.md) |
| 7 | GNOME Remote Desktop backend | 🚧 Public `release/50.2-rkmpp@c4ef3c9` rebases all 16 existing release changes patch-identically onto latest GNOME 50 stable and adds the narrowed reconnect-timeout repair. The June patch was re-audited: its unsafe global `client_taken` and broad greeter-preservation paths remain excluded, while a reassigned persistent user display now retains its `RemoteId` subscription after timeout so another authenticated reconnect can retry without restarting the daemon. Exact source/native arm64 builds, RDP integration, and Lintian error gates pass; TPM/EGL skip as expected. Launchpad accepted signed package `50.2+rkmpp+git20260729.15.c4ef3c9-0ubuntu1~rk1` as Pending source `18649293`; arm64 build `33452991` is queued. Prior `…14.24f4392` is Published/successful and remains the public install candidate; its BT.709 fix is runtime-verified on the tested macOS RDP path. Successful successor publication and live idle-reconnect replay remain. | 2026-07-29 | [reconnect audit and fix](./findings/2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md), [color fix](./findings/2026-07-29-grd-fullrange-bt709-fixes-muted-colors.md), [testing](./apps/gnome-remote-desktop/docs/testing.md) |
| 8 | Mesa / Panfrost | 🔄 Four MRs remain open; selected G610 reruns pass and !42679 needs a rebase. | 2026-07-11 | [`video-libraries/mesa/`](video-libraries/mesa/README.md) |
| 9 | Launchpad PPA | ⚠️ GRD latest-GNOME-50 reconnect-fix source `50.2+rkmpp+git20260729.15.c4ef3c9-0ubuntu1~rk1` is accepted/Pending as source `18649293`, with arm64 build `33452991` queued as Needs building. Prior source `18647901` is Published and build `33450532` succeeded. The normal stack and comparison/rewrite builds are otherwise largely Published, while the 6.18.40 forward-port source remains only client-side uploaded. GRD successor publication/installation, clean board migration, combined kernel/GRD validation, and rollback remain open. | 2026-07-29 | [`packaging/ppa/`](packaging/ppa/README.md) |
| 10 | Binary publishing | ❌ No built binaries are committed and no GitHub Release exists. | 2026-07-01 | [`packaging/`](packaging/README.md) |
| 11 | Kodi HW decode | 🚧 Decoder selection, MPP, and FFmpeg prerequisites are ready; Kodi build, playback, and packaging are unproven. | 2026-07-11 | [`apps/kodi/`](apps/kodi/README.md) |
| 12 | ROCK 5B SD/SPI boot chain | ⚠️ SPI → NVMe works; failing vendor raw artifacts have zero-byte U-Boot control DTBs, while the untested 26.5.1 `current` candidate has a valid DTB. | 2026-07-11 | [U-Boot comparison](./boot-firmware/docs/version-comparison.md) |
| 13 | Maximum-mainline kernel | 🚧 The pinned upstream 7.2-rc3 `public` and `wip` integrations are reproducible and pass native kernel/package/payload/header checks. Neither has been installed, booted, or hardware-tested. | 2026-07-17 | [`kernel-maxline/`](./packaging/ppa/kernel-maxline/README.md) |
| 14 | Desktop-app HW video (browsers) | 🚧 **HEVC Main ships by default** beside H.264 and VP9 Profile 0; the installed split driver/config packages are now `1.0.11+ysp5`, payload-matched and green through the pinned matrix. HEVC Main10 and VP9 Profile 2 remain opt-in but their 1080p AFBC→P010 paths sustain **261.38/261.08 fps**. Stock VLC 3.0.23 presents H.264, HEVC Main, and Main10; Firefox 153.0 presents the two 8-bit paths, while Main10 is measured to fall back after Panfrost rejects its standards-correct GR1616 chroma EGL image. Exact-source Firefox 152.0.6/153.0 retry patches pass and the affected 152.0.6 release object compiles; the full package/sandboxed runtime is pending. Phase 4 now closes linear two-object YUV import, equal-row H.264/HEVC multi-slice, same-process two-decode/two-encode normal/ASan/TSan, native WebRTC peer transport, and the full 7,200-second dual-codec soak (216,000 frames/codec, flat fds, no RSS growth). P010 encode remains MPP-backend-blocked and tiled imports fail closed. Exact Published MPP `3381fd2c` and FFmpeg `33a651a55b` PPA binaries pass the isolated 163-vector sweep at 144 byte-exact, 17 skips, two size refusals, and zero backend/driver failures, plus the full normal and ASan/UBSan shipping matrices. Roadmap code is pushed at `main@5d558fa`; final driver/config `1.0.11+ysp6-0ubuntu1~rk1` passes exact-commit source/binary builds, Lintian error gates, and isolated package lifecycle, and its source is signed. Host installation/PPA upload, patched Firefox, physical HDR/mpv output, Chromium GL, clean-image hardware decode, and release remain. **2026-07-31 supersedes two Main10 claims:** the Firefox Main10 fallback was the driver emitting an invalid `GR16` fourcc, not a Panfrost GR1616 limitation, and corrected `ysp7` imports zero-copy in both Firefox processes; and the stateful packetized Main10 decode failure behind it was a kernel bug, cured by the rewrite soft-CCU IOTLB flush `75a34815b132`. Requalifying then found a **silent RGA defect** — the NV15→P010 conversion intermittently returns success without writing its destination, so a frame is bit-exact the buffer's previous contents (6/10 runs at 416x240, 3/8 at 320x240, clean at 720p/1080p). It is unbisected and makes every single-run small-geometry 10-bit result provisional. | 2026-07-31 | [`rockchip-vaapi` project](./video-libraries/vaapi/README.md), [roadmap qualification](./findings/2026-07-29-rockchip-vaapi-roadmap-phase2-phase4-closure.md), [IOTLB closure](./findings/2026-07-31-rewrite-soft-ccu-iotlb-closes-vaapi-main10-packetized-failure.md), [RGA dropped write](./findings/2026-07-31-rga3-afbc-p010-dropped-destination-write.md), [narrow-AFBC refusal](./findings/2026-07-29-rga-no-core-match-narrow-afbc-10bit.md), [shipping-stack gates](./findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md) |
| 15 | CPU voltage binning (PVTM/eFuse) | ❌ No patch, branch, or build exists. The board's BSP-selected L5/L7/L7 voltage columns are measured and materially lower than mainline's worst-die table below 2.4 GHz; the two-track port plan is gated by cold-boot, SRAM-margin, and shared-DSU-rail validation. | 2026-07-27 | [port plan](./kernel-versions/docs/pvtm-opp-binning-plan.md), [measured index](./findings/2026-07-27-rk3588-pvtm-volt-sel-measured.md) |

## Next gates

A next gate is the smallest result that would materially advance its track, not
a general wish list. The action path points to the maintained runbook, exact
evidence owner, or decision boundary; keep it usable when a gate changes. Close
or replace a gate only with evidence from the owning detail page, and update the
dashboard date and ledger row when public state changes.

| # | Track | Next proof | Action path |
|---|-------|------------|-------------|
| 1 | Kernel forward-port | **Boot what is already installed.** `…20260729-0ubuntu1~rk1` is installed but unbooted, so the next proof needs no build and no upload: boot `6.18.40-ysp-rockchip64` and re-run the RDP login gate at `2064x1296` — a clean login plus ≥10 min of encode closes both the dma-buf and ISR-panic gates. Confirm Launchpad accepted and built the source (uploaded client-side 07-29 09:04) separately; that is archive bookkeeping, not a board result. **A newer cut carrying the five unpackaged commits is a distinct, later gate with a hard precondition:** the exporter snapshots the shared Armbian kernel worktree, so it must run immediately after `build-kernel.sh forward-port`, with `drivers/iommu/rockchip-iommu.c` verified byte-identical to the fwport tree and no `*-rewrite` paths present, before `FORCE_ORIG=1` regenerates the orig. Verifying the export alone is insufficient — the rewrite-path exclusion does not cover shared files like `rockchip-iommu.c`, which is the file that panicked the board. Re-run the RDP login gate at `2064x1296` on a fresh boot — the 07-29 08:00 login already proved `Created h264_rkmpp encode session` runs clean on `DMABUF_DEBUG=n`, but the ISR panic cut it short, so a clean login plus ≥10 min of encode on the re-cut kernel closes both the dma-buf and ISR-panic gates. Identify the booted kernel from `dpkg -l` and `/boot/config-…` (a version bump does not change `uname -r`), and retain the `~rk2` .debs for rollback comparison. `uname -r` and `/proc/version` are unchanged by a revision bump, so identify the booted kernel from `/boot/config-6.18.40-ysp-rockchip64` and `dpkg -l`. Installing `~rk2` replaces `~rk1`'s modules directory, so retain a `DMABUF_DEBUG=y` kernel to re-run the comparison. No instrument is needed: the guard, the hardware watchpoint, and the `linux-rockchip64-ysp-sgguard` upload are all superseded. `~rk2` also carries the debug cleanup: `DMA_API_DEBUG`, `IOMMU_DEBUGFS` and `KALLSYMS_ALL` are now off alongside `DMABUF_DEBUG`, retiring all three genuine deviations from the stock 26.5.1 baseline. That makes `dma_debug_entries=2097152` in `extraargs` inert and reclaims ~256 MiB without editing the root-owned boot environment; the RGA/MPP debug facets are deliberately kept, being sub-options of drivers Armbian does not ship. | [root cause + fix](./findings/2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md#verification-gate), [upstream provenance + fix options](./findings/2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md), [debug option audit](./findings/2026-07-28-production-kernel-debug-option-audit.md#recommended-actions), [kernel package checklist](./packaging/ppa/kernel-forward-port/README.md#remaining-checklist) |
| 2 | BSP-audit fixes | Add targeted hostile-path gates for the acquire-fence, shutdown, missing-plane, and partial-handle fixes that broad conformance does not exercise. | [runtime gate inventory](./kernel-drivers/patches/cleanup-draft/verification.md#runtime-gate-result-record-here-when-run), [port record](./findings/2026-07-22-bsp-high-current-tip-port.md) |
| 3 | DKMS channel | Install on a stock 6.18 ROCK 5B, boot the overlay, and run `validate-combined.sh`. | [DKMS build and install](./packaging/dkms/README.md#dkms-build-install) |
| 4 | Clean-room rewrite drivers | Build and boot a source-bound successor package from `9771d14cfa109`; require the exact ordered 90+148 manifest, a clean outer-KTAP interval with live lockdep, matching source/config/package identity, a clean aged kmemleak scan, every runtime/core, AV1 AFBC/fault/PM counter evidence, ABI replay, and full conformance. | [AV1/VSI lifecycle finding](./findings/2026-07-30-rewrite-av1-vsi-fault-afbc-lifecycle-races.md), [qualification contract](./kernel-drivers/docs/rewrite-kunit.md#capture-a-reproducible-result) |
| 5 | ffmpeg tree | Build/install `c9428bedaa`, then repeat GRD hardware timeout, software fallback, and encoder recreation while requiring a clean libmpp/kernel log; afterward re-test AV1 from MP4/MKV. | [lifetime integration gate](./findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md#verification-gate) |
| 7 | GNOME Remote Desktop backend | Confirm build `33452991` succeeds and source `18649293` publishes, install `50.2+rkmpp+git20260729.15.c4ef3c9-0ubuntu1~rk1` on a production kernel without `CONFIG_DMABUF_DEBUG`, then repeat the measured idle reconnect sequence. Require the second attempt to reach GDM→user handover without restarting the system daemon, while an initial greeter failure still cleans up normally. Then run the sustained focus/resume and audio gates. | [reconnect reproduction](./findings/2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md#act-4-latest-gnome-50-rebase-and-narrowed-june-fix-salvage), [focus/resume gate](./apps/gnome-remote-desktop/docs/testing.md#10-exp6exp7-macos-focusresume-gate), [root cause + fix](./findings/2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md#verification-gate) |
| 8 | Mesa / Panfrost | Rebase !42679 and rerun its selected CI coverage. | [MR tips and selected CI](./video-libraries/mesa/README.md#mr-status) |
| 9 | Launchpad PPA | Confirm the 6.18.40 kernel source/build, then install, boot, and revert the co-installable kernel on the ROCK 5B. | [kernel package checklist](./packaging/ppa/kernel-forward-port/README.md#remaining-checklist) |
| 10 | Binary publishing | Choose and record the repository-wide license required before a public release. | [license decision boundary](./LICENSE.md) |
| 11 | Kodi HW decode | Build Kodi GBM/GLES and validate RKMPP playback with `kodi-gbm` on tty1. | [Kodi tty1 runbook](./apps/kodi/docs/build-hwaccel.md#5-test-on-tty1-gbm-needs-drm-master) |
| 12 | ROCK 5B SD/SPI boot chain | Substitute the 26.5.1 `current` FIT, loader, and then both on a captured 26.2.1 SD baseline; record where each boot stops or succeeds. | [raw-SD hypothesis test](./scripts/README.md#rock-5b-raw-sd-u-boot-hypothesis-test) |
| 13 | Maximum-mainline kernel | Install `public` first with serial recovery and the known-good 6.18 packages retained; prove boot, storage, network, display, suspend, and rollback before `wip`. | [recovery-first test order](./packaging/ppa/kernel-maxline/README.md#install-and-test-order) |
| 14 | Desktop-app HW video (browsers) | Install the already-qualified Published MPP `3381fd2c` and FFmpeg `33a651a55b` packages and confirm installed payload/runtime identity; then finish/install the final driver and Firefox packages and run sandboxed H.264/HEVC Main/Main10 plus a real-output mpv HDR gate without source-tree driver overrides. | [Roadmap release boundary](./findings/2026-07-29-rockchip-vaapi-roadmap-phase2-phase4-closure.md#remaining-release-boundary) |
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
| W01 | [Armbian media-patch drift](#watch-w01) | 2026-07-11 | Patch blobs unchanged; DT anchors still hold. |
| W02 | [Armbian patcher precedence](#watch-w02) | 2026-07-11 | Core-wins behavior unchanged; rename workaround still required. |
| W03 | [Armbian codec-udev upstreaming](#watch-w03) | 2026-07-11 | PR merged; future images should carry the rule. |
| W04 | [Ubuntu FFmpeg version](#watch-w04) | 2026-07-11 | Resolute still publishes `7:8.0.1-3ubuntu2`. |
| W05 | [Launchpad PPA publication](#watch-w05) | 2026-07-29 | **GRD successor `…15.c4ef3c9` is accepted/Pending as source `18649293`; arm64 build `33452991` is queued.** Prior `…14.24f4392` source `18647901` is Published and build `33450532` succeeded. **Prior:** `librga …20260725.26a50ef` and the 6.18.40 forward-port kernel were client-side uploaded with Launchpad confirmation still pending at their last check. The normal FFmpeg, prior GRD, production forward-port `…20260723`, rewrite-kernel replacements, and experimental GRD `~exp3` are Published with successful arm64 builds. |
| W06 | [Mesa MR stack](#watch-w06) | 2026-07-11 | Four MRs open; !42679 needs a rebase. |
| W07 | [`ffmpeg-rockchip-81` tips](#watch-w07) | 2026-07-19 | Canonical public tips unchanged; separate normal-PPA timeout branch remains at `da5befc806`. |
| W08 | [AV1 container-extradata validation](#watch-w08) | 2026-07-16 | Fix carried forward; board re-test pending. |
| W09 | [Kodi build and tty1 playback](#watch-w09) | 2026-07-11 | Prerequisites ready; build/playback/package pending. |
| W10 | [GRD reconnect validation/submission](#watch-w10) | 2026-07-29 | Latest GNOME 50 release source `c4ef3c9` retains the safe June intent without its single-use-token or broad-preservation bugs; source/native/RDP/Lintian gates pass and PPA source `18649293` is accepted with build `33452991` queued. The exact measured idle reconnect replay, repeated focus/resume, compressed-audio interoperability, and upstream review remain. |
| W11 | [Repository-wide license](#watch-w11) | 2026-07-11 | No repository-wide license granted. |
| W12 | [Dev-box-only artifacts](#watch-w12) | 2026-07-11 | Identified code/package artifacts are captured. |
| W13 | [librga P010/P210 series](#watch-w13) | 2026-07-25 | `0074` is boot-verified on the `6.18.40` KASAN forward-port: raw RGA 10-bit stride/UV-offset gates pass and fresh-librga P010/NV15 probes pass. Production packaging still must ship the kernel and librga changes together; the source-built 10-bit `librga-smoke` wrapper remains red only at unrelated `imfill`. |
| W14 | [YSP Armbian builder](#watch-w14) | 2026-07-20 | Exact-6.18.38 clean production build `Pf558-Cb831` completed BTF and Debian packaging; the wrapper now pins source and purges stale debug-build Kbuild metadata. |
| W15 | [RGA session-close fix vs. the frozen import](#watch-w15) | 2026-07-17 | Force-free UAF fixed in fwport patch `0039`; frozen base patch still has the old path. |
| W16 | [Forward-port kernel-fix tail](#watch-w16) | 2026-07-29 | The exported tail is contiguous `0001`-`0079`; the new `0076`-`0079` WARN/oops audit sweep (18 defects, 12 unprivileged-reachable) is **compile-verified only**. `0074` and `0075` have booted KASAN hardware evidence on `6.18.40-video-port-kasan-rockchip-rk3588` (RGA 10-bit gates, forced `split_arg=4` slice gate, KASAN MPP, ioctl fuzz, and root gates). **The shipped `…20260725` production package is not this series** — its orig is a rewrite-composite worktree snapshot whose hardened IOMMU setter panicked the board 2026-07-29; the provenance-repaired `…20260729` re-cut is signed and `dput`-uploaded client-side, Launchpad/install/rollback pending. |
| W17 | [Maximum-mainline proposal-set drift](#watch-w17) | 2026-07-17 | The build is reproducible at pinned inputs; any claim about the broadest current public proposal set requires a deliberate manifest refresh. |
| W18 | [rockchip-vaapi fork state](#watch-w18) | 2026-07-29 | Roadmap code is committed and pushed as `main@5d558fa`; upstream remains `e8c64dd` and unrevived. Installed driver is `1.0.11+ysp5`; signed final source `1.0.11+ysp6-0ubuntu1~rk1` and its exact binaries pass source/binary, Lintian-error, and isolated lifecycle gates but are not uploaded or installed. Exact Published MPP/FFmpeg binaries pass the isolated complete sweep, normal/ASan matrices, and a 7,200-second/216,005-frame 4K decode soak with no RSS or fd growth, but still need host installation. Firefox packaging/runtime, physical HDR/mpv, Chromium GL, clean-image install, and P010 encode remain open. |
| W19 | [MPP `INIT_CLIENT_TYPE` double-call → use-after-free](#watch-w19) | 2026-07-24 | **Root-caused, reproduced, escalated to a UAF, fix committed as `0069`** (`-EBUSY` re-init guard). Two `INIT_CLIENT_TYPE` ioctls persistently corrupt `queue->session_attach`; a *later* single unprivileged INIT then reads a **freed `struct mpp_session`** (KASAN slab-use-after-free), so it is memory-corruption, not a mere WARN. BSP-identical, untouched by `0058`-`0068`. **Gate CLOSED 2026-07-24:** the reproducer returns `errno=16` (`EBUSY`) on the booted `#8` KASAN build carrying the fix, and that tail passed full conformance on the Published production kernel. |
| W20 | [Intermittent Plymouth initramfs-daemon boot stall](#watch-w20) | 2026-07-23 | **CSI-loop attribution falsified as sole cause:** the stall recurred on 2026-07-23 with the patched `~rk1` package binary-verified in the booted initramfs (identical fingerprint, no `SIGRTMIN+20`). Boot-transaction mechanism reconfirmed; internal daemon wedge unknown again. Mitigation `plymouth.enable=0` still unapplied; next hang needs a live `plymouthd` stack via `debug-shell.service` instead of a reset. |
| W21 | [ffmpeg-rockchip `rkmpp` transcode deadlock without the `da5befc806` backpressure fix](#watch-w21) | 2026-07-23 | The harness's default `FFDIR` binary (FFmpeg-**master**, `libavcodec 63`; its dir's `RELEASE` file misleadingly says 6.1) deadlocks on `h264→hevc` and `hevc_main10→p010` `rkmpp`/`rkrga` pipelines (all threads on `futex`). The **shipping `/usr/bin/ffmpeg 8.0.3~rk1` (`libavcodec 62`, carries `da5befc806`) runs both cleanly**, and the **kernel is not implicated** (clean RGA reset, no D-state/KASAN). Already-catalogued encoder-backpressure/decoder-hang class ([`fix-candidates.md`](./video-libraries/ffmpeg/docs/fix-candidates.md)), fixed on our 8.0 line — not a new finding; not yet forward-ported to main. |
| W22 | [RK3588 per-die voltage binning absent from mainline](#watch-w22) | 2026-07-27 | Rechecked three release candidates later at maxline `v7.2-rc5-252`: still absent, and `rk3588-opp.dtsi` is byte-identical between the 6.18 forward port and maxline, so one DT patch serves both. Mainline ships the BSP's unbinned worst-die column **exactly** (19/19 shared CPU OPPs) while the BSP's per-die columns reach 50–87 mV lower. This board is bin 0 and its BSP index is now **measured** — L5 little, L7 both big — so the entitlement is priced, not estimated. |
| W23 | [Ramoops retention reversal & the 6.18.38 kernel A/B](#watch-w23) | 2026-07-28 | **Ramoops recovers records across warm reboots on every 6.18.40-era kernel** — ≥9 recoveries in the retained journal since 2026-07-26, same firmware stack — so the documented all-zero failure is scoped to the 6.18.38-era kernels and the firmware-phase hypothesis is retired. The four-reboot kernel A/B on the still-installed `6.18.38-current` is pending; the 2026-07-27 19:38 GRD-SG oops dump is archived in `/var/lib/systemd/pstore/`. |
| W24 | [ROCK 5B stock-Ubuntu image inputs](#watch-w24) | 2026-08-01 | Ubuntu 26.04 arm64 images, Canonical's draft Image Cookbook/`ubuntu-image` 3.6.0 schema, Linux 6.18 LTS projection, and the inspected upstream U-Boot tip are recorded as design inputs. No successor image, clean kernel package, gadget, or upstream-U-Boot board boot exists yet. |

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
- **Last checked:** 2026-07-29
- **State 2026-07-29:** Launchpad accepted
  `gnome-remote-desktop_50.2+rkmpp+git20260729.14.24f4392-0ubuntu1~rk1` as
  source publication
  [`18647901`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18647901)
  and dispatched arm64 build
  [`33450532`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33450532)
  to `bos03-arm64-101`. The source is Published and the build succeeded in
  18m56s. This is the clean 50.2 release branch plus the runtime-verified
  full-range BT.709 color-signaling fix. Latest-GNOME-50 reconnect successor
  `…15.c4ef3c9` passes local source/native/RDP/Lintian gates, is accepted as
  Pending source
  [`18649293`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18649293),
  and has arm64 build
  [`33452991`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33452991)
  queued as Needs building.
- **State 2026-07-25:** `librga_2.2.0+git20260725.26a50ef-0ubuntu1~rk1` uploaded
  from fork tip `26a50ef`, superseding the `…20260724.b8def3e` upload below —
  that one limited the 10-bit byte-stride conversion to RASTER, and `4c26ddf`
  extends it to TILE. Client-side verified (lintian clean bar a
  `newer-standards-version` warning, full local arm64 binary build, SONAME still
  `librga.so.2`), `debsign`ed, `dput` succeeded, **Launchpad processing
  pending** — verify it reaches Published with a successful arm64 build.
- **State 2026-07-24:** Two `dput` uploads carrying the 10-bit byte-stride fix,
  Launchpad processing pending — verify both reach Published with a successful
  arm64 build: production forward-port kernel
  `linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260724-0ubuntu1~rk1` (tail
  `0001`–`0073`, local production build `P272c-Cb831`, adding `0072` RGA3
  byte-stride fix and `0073` RGA2 >4G reject over the Published `…20260723`),
  and `librga_2.2.0+git20260724.b8def3e-0ubuntu1~rk1` (im2d raster pixel→byte
  conversion). Both are client-side verified (`dpkg-source -x`, content checks)
  and `debsign`ed. The `…20260723` kernel below has since reached Published,
  built on arm64, and passed full conformance plus root gates on-board
  ([run](./findings/2026-07-24-production-ppa-kernel-full-conformance-run.md)).
- **State 2026-07-23 (forward-port kernel):** The production (non-debug) source
  package `linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260723-0ubuntu1~rk1`
  — the complete current tip (single `rk3588-video-6.18` branch, contiguous
  `0001`–`0071`), built locally as production kernel `P5618-Cb831`
  (`CONFIG_KASAN` off, AV1 on) — was `debsign`-signed (`0FDDE6BC…AA2228E6`) and
  `dput`-uploaded to `ppa:yi-ding/ubuntu-rock-5b`; all client-side checks
  (GPG/checksums/required-fields) passed and **Launchpad accepted it** — source
  publication
  [`18639187`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18639187),
  status **Pending**. Next check: confirm it reaches Published and its arm64
  build succeeds, then board-install/boot/conformance/rollback this production
  image. The previous local `…20260720` was never uploaded, and the Published
  line had stopped at `…20260717` (patch `0041`-era).
- **State then (2026-07-19):** Launchpad's API and exact-version binary queries showed the
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
- **Last checked:** 2026-07-29
- **State 2026-07-29:** Public release source `c4ef3c9` rebases the 16 existing
  downstream patches without semantic drift onto latest GNOME 50 stable and
  adds narrowly scoped timeout survival for a reassigned persistent user
  display. The old June `client_taken` and preserve-any-registered-display
  mechanisms were re-reviewed and remain excluded. Source/native arm64, RDP
  integration, signatures, and Lintian error gates pass. Launchpad accepted
  Pending source `18649293` and queued arm64 build `33452991`; the exact idle
  reconnect plus first-redirect race still need board replay.
- **State 2026-07-21:** The reconstructed-ACK recovery is live-validated and the
  idle-time false-starvation actuator is source-fixed; installed `exp9` audibly
  validates PCM RDP output after the PipeWire migration. Repeated focus/resume
  video validation, compressed-audio interoperability, publication/promotion,
  and upstream review all remain owed.
- **State 2026-07-20:** Diagnostic `~exp2` and recovery `~exp3` narrowed the original
  graphics-thread stall; the latter is Published as source `18626586` and build
  `33412698`. Subsequent local `exp5@b3f0e20` hardware testing proved exported
  patch `0016` removes the uncached imported-buffer readback hang. The fluid
  session then exposed a distinct intermittent encode fallback: MPP refused a
  frame under transient input-pool pressure, while FFmpeg `540657970e` waited
  for output from that never-submitted frame. Wrapper fix `da5befc806` is
  Published in the normal PPA. The next macOS focus-return wedge was captured
  independently: the resumed connection retained 908 reconstructed frame ACKs
  and zero frame slots despite live input/transport and healthy hardware.
  Cleaned patch `0017@7f6a45e74fd3` adds transition logs and a progress-gated
  two-second recovery. Its functional `~exp6@7e958e6` predecessor passes tests
  and a local arm64 package build and is installed. The watchdog fired once
  with two stalled ACKs, forced refresh, and restored hardware submissions,
  runtime-validating that recovery. The same live run caught a second failure:
  GDB showed the first new work after focus return was about
  1 ms old but inherited a 42.493-second pre-idle submit age and immediately
  fired the software cooldown. Patch `0018@38e81610a400` gives newly outstanding
  work a fresh watchdog window. The final source and native arm64 `exp7`
  package builds pass. Installed `exp8` with diagnostic patch `0019` captured
  the Microsoft macOS client's sole exact stereo PCM format. Installed `exp9`
  adds patch `0020`'s channel/training/PipeWire PCM/`SNDC_WAVE2`/wave-confirm
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
- **Last checked:** 2026-07-25
- **State 2026-07-25 (KASAN gate):** The `0074` kernel fix is boot-verified on `6.18.40-video-port-kasan-rockchip-rk3588 #2`. Raw RGA stride/UV-offset run `20260725-195821-rga-10bit-gates` passed cores 1, 2, 4, and default with `kernel_flags=0`; fresh-librga run `20260725-200145-rga-im2d-10bit-current-gates` passed P010 and NV15 widths 256/320/1920. The 10-bit `librga-smoke` subcases pass with that fresh library, but the whole smoke still exits 1 at unrelated `imfill`. See the [6.18.40 KASAN validation finding](./findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md).
- **State 2026-07-25 (TILE):** The byte-stride convention holds for **TILE too**,
  not just RASTER — settled against BSP `develop-5.10`/`develop-6.1`, where the
  `* 8` in the tile stride is the eight-lines-per-tile-block factor, not a
  pixel-depth scale, and `rga_convert_addr()` has no `rd_mode` distinction at
  all. librga `b8def3e` had gated the pixel→byte conversion on raster, and the
  rewrite's TILE branch pinned the wrong convention with a KUnit guard. Fixed in
  librga `4c26ddf` (shipped as the `…20260725.26a50ef` upload, W05) and rewrite
  `40cf22629cf63`/`7481ab327d7ea`. **Kernel and librga must now ship together
  for TILE 10-bit**, the same coupling as the `0072`/`c80eea7` raster pair. See
  the [TILE byte-stride finding](./findings/2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md).
- **State 2026-07-24:** `rga_convert_addr()` is wrong again, in the opposite
  direction. `0049` scaled `vir_w` by pixel depth to fix the 1 byte/px UV
  derivation below, but `0072` then made `vir_w` a **byte** stride, so that
  scaling now double-applies the depth: measured on the booted `…20260724~rk1`
  plus librga `b8def3e` pair, the UV plane is read from the `×10/8` (compact) or
  `×2` (incompact) offset — tight buffers IOMMU-fault and over-sized buffers
  silently get wrong chroma. Fixed by `0074` (`710e6ad12af6`,
  `y_bytes = vir_w * vir_h`), boot-verified on the 2026-07-25 KASAN gate;
  the 10-bit gates now also check chroma content so a recurrence cannot pass as
  a green. See the
  [UV-offset finding](./findings/2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md).
- **State 2026-07-21:** The series from `2cffdf6` through `main@a632217` was exported
  under [`vendor-libraries/rga/patches/`](./vendor-libraries/rga/patches/README.md).
  On `P63dd-C4ad2` (kernel `0047` stride fix) the direct im2d P010 probes
  show luma bit-exact; the remaining chroma corruption is the kernel's
  `rga_convert_addr()` deriving UV plane offsets at 1 byte/px, fixed by
  kernel patch `0048@6c7eb3efa3f0` (booted chroma gate pending). The
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
### W15 — RGA session-close fix vs. the frozen import

- **Why recheck:** The RGA `/dev/rga`-close force-free hazard is fixed in the
  forward-port tree, but the superseded two-patch import — still the DKMS
  source — is a frozen vendor snapshot that carries the old
  `rga_mm_force_releaser_buffer()` path, so the two can silently diverge until
  the next regeneration.
- **Last checked:** 2026-07-17
- **State then:** Driver fix `linux-6.18-rkvenc-av1-fwport@bc086cbe03d7`
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
- **Last checked:** 2026-07-29
- **State 2026-07-29 (audit sweep):** The exported tail is now contiguous
  `0001`–`0079`. A systematic WARN/oops audit of the driver source found **18
  distinct defects** and fixed them in `0076`–`0079`, including all five
  previously catalogued but unfixed entries in the vendor-driver latent-defect
  catalogue (kept in the private `rock-5b-security` repository).
  Twelve are reachable by any process that can open `/dev/mpp_service` or
  `/dev/rga`; five of those are unprivileged kernel-heap corruption. **All four
  patches are compile-verified only — none has been booted and no reproducer
  has been run**, so the `0001`–`0071` hardware evidence below does not extend
  to them, and a KASAN + `DEBUG_ATOMIC_SLEEP` + lockdep boot with full
  conformance is owed before they ship. The same sweep confirms the forward
  port never carried the sleeping fault-handler tail that panicked the board
  (its `rockchip_iommu_set_fault_handler()` is a plain pointer swap), which
  corroborates the orig-provenance finding below. See
  [the audit finding](./findings/2026-07-29-forward-port-warn-oops-audit-and-fixes.md).
- **State 2026-07-29:** The shipped `…20260725` production package is **not** the exported series: its orig is a rewrite-composite snapshot of the shared Armbian worktree (byte-identical rewrite-branch `rockchip-iommu.c`, 10 inert `*-rewrite` files), and its hardened IOMMU fault-handler setter panicked the board from the vendor MPP job ISR on 2026-07-29 08:01. The series and the `20260723` orig are clean; the leak is unique to the 07-25 export. Source fix landed on both rewrite tips (`35eb735d21dd8`/`2cf0126529c1c`, pushed); the provenance-repaired `…20260729-0ubuntu1~rk1` re-cut (exporter now excludes rewrite paths) is signed and `dput`-uploaded client-side as of 09:04; Launchpad acceptance/build, install, and the re-armed RDP gate remain. See [the ISR-panic finding](./findings/2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md) and [the provenance finding](./findings/2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md).
- **State 2026-07-25:** The exported tail is contiguous `0001`-`0075` and the `0074`/`0075` board gates are now closed on `6.18.40-video-port-kasan-rockchip-rk3588 #2`. Raw RGA 10-bit stride/UV-offset gate `20260725-195821-rga-10bit-gates`, fresh-librga P010/NV15 gate `20260725-200145-rga-im2d-10bit-current-gates`, forced `split_arg=4` MPP gate `20260725-195350-mpp-suite`, KASAN MPP `20260725-195451-kasan-mpp-suite`, ioctl fuzz `20260725-200344-ioctl-fuzz-smoke`, and root gates `20260725-200607-root-gates` are green, with `mpp-debug-capture` skipped as expected. The remaining open piece is production package/install/rollback, not the KASAN hardware proof.
- **State 2026-07-24:** The exported tail was then contiguous `0001`–`0074`, and
  the claimed production gate is real: Published `…20260723~rk1` (tail
  `0001`–`0071`) was installed from the PPA, booted, and passed the full
  conformance set plus root gates. `0072`–`0074` (10-bit RGA stride/UV offset)
  are compile-clean with their board gate **owed** — the `0072` gate ran and
  failed, which is what `0074` fixes. The alignment this row exists to watch
  therefore holds for `0001`–`0071` and is open for the three-patch tail.
- **State 2026-07-21:** The maintained series now exports all three fixes: `0040`
  unlinks MPP sessions before private teardown; `0041@a68c39dbb834` clears
  `session->dma` after RESET_SESSION destroys it; and
  `0042@e2a89c172758` samples the RKVENC2 abort flag before the final task
  reference can free the object. Run `20260718-093751-kasan-narrowed` verifies
  `0041` with zero flagged lines. Run `20260718-103917-kasan-mpp-suite`
  exercises `0041`/`0042` with empty KASAN/fatal scans and passing ordinary
  encode cases. Corrected run `20260720-213128-kasan-mpp-suite` proves the
  apparent multi-instance H.265 and slice failures were harness defects; all
  three 120-frame cases pass, and full `20260720-213542-mpp-suite` passes the
  selected 12-case matrix. An abusive split control separately found an open
  RKVENC2 slice-FIFO overflow. Patches `0043@bb15076cd6fa` and
  `0044@2d6367ad0b05` fix the two RGA ABI replay gaps: `rkvenc-fwport-6.18`
  was fast-forwarded to `27452e3`, rebuilt as KASAN debug build `Pb999-C4ad2`,
  installed, and booted, and run `20260721-034716-kasan-narrowed` passed the
  full ABI replay (`abi_status=0`) with a clean memory scan. The same boot
  re-ran the 12-case MPP matrix (`20260721-042445`) and full FFmpeg
  codec/bit-exact PSNR suite (`20260721-042631`) green with clean scans. The
  librga smoke's `no core match` flakiness was then root-caused and fixed in
  the harness (13 cases green), and new RGA fixes `0045@7b48a8d5b30d`
  (legacy-virtual `0044` regression), `0046@0feb65c7ee16` (under-4G
  `EOPNOTSUPP` reporting), and `0047@4b2beb91521f` (byte-literal 10-bit
  raster strides, the measured P010 corruption) passed their booted gates on
  rebuilt debug build `P63dd-C4ad2`: legacy blits succeed, the exclusion
  probe returns `EOPNOTSUPP` with the explanatory log, P010 luma is
  bit-exact, the librga smoke is fully green for the first time (28 cases,
  `LIBRGA_SMOKE_10BIT=1`), ABI replay `20260721-081456` and the 12-case MPP
  matrix `20260721-081639` are clean, and FFmpeg `20260721-081448` passes
  all 14 required cases plus bit-exact AV1 PSNR. The `0047` gate exposed a
  final 10-bit defect — `rga_convert_addr()` places UV planes at 1 byte/px
  offsets — fixed by `0048@6c7eb3efa3f0` (booted chroma gate pending its
  debug build). DMA-debug also flagged the missing
  `dma_set_max_seg_size()` on the rga2 device (96 KiB CMA segments vs the
  64 KiB default). Patches `0049@c4bf430d907f` and `0050@afcd69845942` implement the renumbered DMA scope: the page tables become owned streaming DMA mappings of the RGA2 device (plus `dma_set_max_seg_size` and a page-preserving swiotlb min-align mask), and over-4G buffers are served on RGA2 through DMA-API mappings of the 32-bit device with `EOPNOTSUPP` fallback. On debug build `P9636-C4ad2` (`#5`, carrying `0048`–`0050`) the `0048` and `0049` gates pass: P010→P010 copies are bit-exact including chroma, P010→NV12 chroma is neutral, FFmpeg `hevc_main10_p010_rga` flips to PSNR `inf/inf/inf` (run `20260721-110029`), and smoke (28 ok)/MPP (12/12)/ABI (`20260721-110007`) are green with a completely clean DMA-debug/KASAN journal — both the July 20 page-table splat and the segment-size warning are gone. The `0050` gate ran the over-4G system-heap imcopy on RGA2 (no more `EOPNOTSUPP`) but read back stale destination data on two successive debug builds, exposing two copy-back defects: the post-clean was wrongly guarded with `!iommu_mapped` (excluding default-map-core origins; fixed on `P9636`, keyed on bounce direction), and — first-order, exposed by the `P9412` (`#6`) re-run — the transient dst bounce inherited the channel get-side `DMA_TO_DEVICE`, so swiotlb never copied the device output back at unmap. Fixed in the amended `0050@afcd69845942` (every transient bounce mapped `DMA_BIDIRECTIONAL`, matching the persistent mappings); the content-exact gate awaits the next debug build. A mixed-heap differential matrix on `P9412` isolates the defect to the dst leg alone: src-only bounces (system→CMA) and the userptr bounce branch (malloc→CMA) are content-exact, and the mapping-failure fallback gate passes — 128 MiB over-4G buffers fail cleanly with `EOPNOTSUPP` plus the explanatory log (swiotlb's 256 KiB per-mapping cap, not pool exhaustion, is the practical bound: over-4G buffers with ≥1 MiB exporter chunks always take the fallback). The same boot closed the last `0047` caveat — the compact-NV15 raster leg is hardware-validated by the new `rga-nv15-test` probe (semantic NV15→NV12 read, CPU-unpacked P010→NV15 write, bit-exact NV15 copy at 256/320/1920 widths). On debug build `P7589-C4ad2` (`#7`, the amended `0050`) the gate CLOSES: the full differential matrix is content-exact (both-legs, dst-only, and userptr bounces), the fallback stays clean `EOPNOTSUPP`, and the same-boot smoke (28 ok)/P010/NV15/ABI (`20260721-145234`)/MPP (`20260721-145243`)/FFmpeg (`20260721-145258`, 24/24, Main10 PSNR inf) sweep is green with a zero-flagged-line journal — `0043`–`0050` are BOOT-VERIFIED on one kernel. (Watchlist: `P7589`'s first boot attempt hung with no oops/pstore capture and needed a hard reset; the second boot was clean — watching for recurrence.)
  Clean exact-6.18.38 production build `Pf558-Cb831` and the freshly extracted
  unsigned 20260720 PPA source package carry both lifetime fixes with the
  non-debug AV1/RGA config but predate `0043`/`0044`. The Published kernel then
  stopped at `0040`, so RGA/GStreamer
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
- **Last checked:** 2026-07-29
- **State 2026-07-29:** Roadmap development is committed and pushed as
  `main@5d558fa`. The board now runs payload-matched
  `rockchip-vaapi 1.0.11+ysp5`, not ysp1. Measured working-tree gates close
  1080p 10-bit throughput, VLC Main10, linear two-object import, equal-row
  multi-slice, native WebRTC peer transport, same-process
  two-decode/two-encode normal/ASan/TSan, and the 7,200-second encode soak.
  Firefox Main10 is isolated to Panfrost rejecting Firefox's GR1616 EGL import;
  exact-source 152.0.6/153.0 consumer patches pass and the affected 152.0.6
  release object compiles. Exact Published MPP `3381fd2c` and FFmpeg
  `33a651a55b` binaries pass the isolated 163-vector sweep and full normal
  plus ASan/UBSan matrices; their 7,200-second 4K decode soak completes
  216,005 external frames with no RSS or fd growth. They are not installed.
  Signed final source
  `1.0.11+ysp6-0ubuntu1~rk1` and its exact binaries pass source/binary,
  Lintian-error, and isolated lifecycle gates but are not uploaded or
  installed. Upstream remains `woodyst/main@e8c64dd`.
- **State 2026-07-28:** Fork advanced to `main@db5e0f0`, fully pushed (the
  `fork` remote matches local HEAD exactly; note `origin` in that checkout is
  *upstream* `woodyst`, so an "unpushed" count measured against `origin` is
  meaningless). Seven commits past `03e6cb6`: `395c8f7` HEVC direct TILES
  backend reducer, `afe8873` P010 import backend boundary, `f30490b` AV1 decode
  plan, `4872b59` native WebRTC peer gate, `4d98eca` bounded AV1 platform
  capability probe, `464753b` structured leveled logging, `db5e0f0` isolated
  Debian package gate. Uncommitted in the working tree: a modified `Makefile`
  and three untracked fuzz harnesses (`tests/{h264,hevc,vp9}_fuzz.c`).
  **Upstream has not revived** — `origin/main` is still `e8c64dd`, unmoved since
  2026-05-28, which answers this entry's standing recheck question.
  **What is deployed lags badly:** the board carries `rockchip-vaapi 1.0.11+ysp1`
  with `rockchip_drv_video.so` dated 2026-07-21, predating the entire Phase 0/1
  renovation, both encode paths, and every commit above; and
  `librockchip-mpp1 1.5.0+git20260529.1375813c`, predating the HEVC TILES fix.
  `librga` is current at `2.2.0+git20260725.26a50ef`. The MPP fix
  `1.5.0+git20260727.d8c6b88a+ds-0ubuntu1~rk1` reached **Published** on
  2026-07-28, so that boundary is now an install rather than a build.
  **Caveat now recorded on all July gates:** they ran on
  `6.18.40-video-port-kasan-rockchip-rk3588`, which sets `DMABUF_DEBUG=n`. The
  driver calls `DMA_BUF_IOCTL_SYNC` directly (`src/surface.c:26`,
  `src/buffer.c:27`) — the ioctl that reaches the oopsing
  `system_heap_dma_buf_end_cpu_access()` path — so those results carry an
  implicit "on a `DMABUF_DEBUG=n` kernel" precondition that production only
  satisfies from `~rk2` onward. See
  [`the root cause`](./findings/2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md).
- **State 2026-07-26:** Public development is on
  `git@github.com:yisding/rockchip-vaapi.git` branch `main` at `03e6cb6`.
  Phase 0/1 renovation, experimental Main10/Profile 2 decode, opt-in H.264/HEVC
  encode, GStreamer/FFmpeg/VLC/RTP/soak gates, linear DRM PRIME encode import,
  and the source-pinned Firefox RDD policy are committed there. The exact
  Firefox source package is patched and partially compiled, but no browser
  package or live sandbox gate exists yet. P010/Main10 encoder input also
  remains unimplemented. The ysp source of truth for evidence is the dated
  [`findings index`](./findings/README.md); the code remains only in the fork.
  Re-check whether upstream has revived before release or offering the series
  back.
- **State 2026-07-21:** The phase-one correctness/packaging work was committed
  to branch `ysp/cleanup` and built as
  `rockchip-vaapi_1.0.11+ysp1_arm64.deb`. Upstream was
  `woodyst/rockchip-vaapi@e8c64dd` (v1.0.11), quiet since 2026-05-28.

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
