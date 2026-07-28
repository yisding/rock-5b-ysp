# findings/ — raw capture inbox

Low-ceremony landing zone for a technical fact you or an agent just learned while
reading code in one of the `../` source trees. **Drop first, sort later.** The bar
to add a file here is deliberately low: one fact, dated, with where it came from.

This is the write path that the polished per-project `docs/` do **not** offer —
depositing into a package doc means editing an index table and matching house
style, so hard-won detail gets re-derived instead of written down. Here you just
add a file.

## How to deposit

1. Copy [`TEMPLATE.md`](TEMPLATE.md) to `YYYY-MM-DD-<short-slug>.md`.
2. Fill the header (scope, source anchor, date, trust tag) and write the fact.
3. Run `python3 scripts/update-findings-index.py`. The generated index copies
   only the filename and H1; keep evidence detail and trust tags in the finding.

For promotion, status changes, and the repository handoff checklist, follow the
canonical [`CONTRIBUTING.md`](../CONTRIBUTING.md) workflow.

Trust tags state what kind of evidence supports each claim. Combine tags when a
finding mixes evidence types:

- **MEASURED** — observed on hardware or in a recorded run.
- **BINARY-INSPECTED** — checked directly against a pinned binary by
  disassembly, decompilation, or format-aware extraction.
- **CODE-INSPECTED**, **CONFIG-INSPECTED**, or **SOURCE-INSPECTED** — checked
  directly against the named pinned source.
- **COMPILE-VERIFIED** — the affected source compiled, but runtime behavior was
  not exercised.
- **CONFIRMED** — independent evidence corroborates the stated attribution.
- **INFERRED** — a conclusion supported by the recorded evidence but not
  observed directly.
- **HYPOTHESIS** — a candidate explanation that still needs a discriminating
  test.
- **DESIGN** — proposed behavior or an implementation plan, not an observed
  result.
- **UNVERIFIED** — copied from a comment, commit, or other source but not yet
  checked.

Outcome tags record what happened to the thing the finding is about, and combine
with the evidence tags above:

- **ROOT-CAUSED** — the mechanism is pinned, not just the symptom.
- **SOURCE-CONFIRMED** — settled against the vendor/BSP source of record.
- **BOOT-VERIFIED** — exercised on a booted board, with the build named.
- **KASAN-CLEAN** / **KASAN-UAF** — the sanitizer verdict on that boot.
- **BOARD-REPRODUCED** — a deterministic reproducer exists and was run.
- **FIX-COMPILE-VERIFIED** / **FIX-RUNTIME-VERIFIED** — scope of the fix's proof.
- **PACKAGE-VERIFIED** — the built package was inspected, not just compiled.
- **PREDICTION-HARDWARE-CONFIRMED** — a source-only prediction later held on
  silicon.
- **FALSIFIED** (or **FALSIFIED-AS-SOLE-CAUSE**) — the stated premise did not
  survive; keep the finding as the record of what was ruled out.
- **RESOLVED** / **SUPERSEDED** — closed here, with the successor linked.
- **PARTIAL** — some gates green, others explicitly still open.

Do not invent a tag when one of these fits; add a new one here first if none do.

## Lifecycle

A finding is raw by default. When it matures into durable reference, **graduate**
it: move the content into the owning project's `docs/`, and replace the file here
with a tombstone so the trail survives. All 17 tombstones share one shape — the
original H1 title, a blank line, `promoted → <path> (YYYY-MM-DD)`, a blank line,
and two to four lines naming what the target preserves, so a reader landing on
the stub knows whether following the link is worth it. Keep the index row.
Findings that turn out wrong get deleted with a one-line note in the index.

Small text artifacts that materially improve reproduction live under the
[`evidence/` hub](evidence/README.md). The bundle README records capture scope;
the dated finding still owns interpretation and trust classification.

**Boundary vs [`status.md`](../status.md) watchlist:** the watchlist tracks
*facts that go stale silently* (external PRs, distro versions, dev-box SPOFs).
`findings/` holds *newly-learned technical detail*. A finding with a follow-up
action belongs here; a stale-risk to re-check on every maintenance pass belongs
in the watchlist.

## Reconstruct an investigation

The generated index below answers **what was learned when**. These curated
trails answer a different question: **how did the explanation change?** They
are deliberately selective re-entry paths, not alternate summaries or a
tutorial sequence.

For a returning thread:

1. Rebuild the vocabulary and mechanism from the maintained model.
2. Read the dated turning points in order, including any **FALSIFIED**,
   **SUPERSEDED**, or **PARTIAL** disposition.
3. Finish at the live boundary before treating an older result as current.

| Thread | Maintained model | Dated turning points | Live boundary |
|--------|------------------|----------------------|---------------|
| Forward-port safety and ownership | [Driver task/lifetime model](../kernel-drivers/docs/how-the-drivers-work.md) and [forward-port status](../kernel-drivers/docs/forward-port-status.md) | [ownership audit](2026-07-21-forward-port-lifetime-resource-ownership-audit.md) → [HIGH fixes](2026-07-22-bsp-high-current-tip-port.md) → [6.18.40 KASAN validation](2026-07-25-forward-port-6-18-40-kasan-full-validation.md) → [current scatterlist-corruption trace](2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md) | [`status.md` track 1](../status.md) and [long-form ledger](../docs/status-ledger.md) |
| Clean-room rewrite qualification | [Rewrite architecture](../kernel-drivers/docs/rewrite-driver-architecture/README.md) | [defect audit](2026-07-24-rewrite-driver-multi-agent-defect-audit.md) → [first complete KUnit failures](2026-07-26-rewrite-kunit-failure-root-causes.md) → [boot-lifecycle wedge](2026-07-27-rewrite-kunit-boot-lifecycle-wedge.md) → [current fixture/lockdep boundary](2026-07-27-rewrite-reset-import-fixture-lockdep.md) | [`status.md` track 4](../status.md) and [rewrite conformance contract](../kernel-drivers/tests/rewrite-conformance.md) |
| RGA memory and 10-bit ABI | [userptr/IOMMU model](../kernel-drivers/rga/docs/userptr-iommu.md) and [librga 10-bit contract](../vendor-libraries/rga/docs/librga-p010-p210-rkrga.md) | [conformance root causes](2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md) → [legacy byte-stride regression](2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md) → [UV-offset sibling defect](2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md) → [TILE correction](2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md) → [hardware validation](2026-07-25-forward-port-6-18-40-kasan-full-validation.md) | [`status.md` W13/W16](../status.md) |
| GNOME Remote Desktop end to end | [Capture path](../apps/gnome-remote-desktop/docs/capture-path.md) and [test gates](../apps/gnome-remote-desktop/docs/testing.md) | [MPP input backpressure](2026-07-19-grd-rkmpp-encoder-wedge-mpp-input-backpressure.md) → [RDPGFX ACK wedge](2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md) → [audio validation](2026-07-21-grd-rdp-audio-live-validation-and-codec-control.md) → [first-frame kernel oops](2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md) | [`status.md` track 7](../status.md) |
| SD/SPI/U-Boot diagnosis | [Boot-chain model](../boot-firmware/docs/u-boot-primer.md) and [artifact comparison](../boot-firmware/docs/version-comparison.md) | [SD boot investigation](2026-07-09-rock5b-armbian-sd-boot-investigation.md) → [FIT/DTB race](2026-07-13-rock5b-u-boot-fit-dtb-race.md) → [firmware-generation gap](2026-07-24-rock5b-spi-vs-radxa-bsp-firmware-generation-gap.md) | [`status.md` track 12](../status.md) |
| Ramoops retention | [Maintained retention explanation](../boot-firmware/docs/ramoops-retention.md) | [measured loss](2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md) → [BSP-premise correction](2026-07-24-bsp-vs-armbian-ramoops-gap.md) → [DDR/TPL audit](2026-07-26-rk3588-ddr-blob-ramoops-static-audit.md) → [SPL audit](2026-07-27-rk3588-spl-ramoops-binary-audit.md) → [next temporal experiment](2026-07-27-rk3588-ramoops-next-experiment-plan.md) | [Current evidence contract and next causal experiment](../boot-firmware/docs/ramoops-retention.md#current-evidence-contract) |
| Desktop VA-API and browser path | [VA-API capability/boundary model](../video-libraries/vaapi/README.md) and [app map](../docs/app-enablement.md) | [fork review](2026-07-21-rockchip-vaapi-driver-review.md) → [bitstream-reconstruction spectrum](2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md) → [Main10/AFBC/P010 validation](2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md) → [Firefox RDD policy](2026-07-26-firefox-rdd-rockchip-vaapi-policy.md) | [`status.md` track 14](../status.md) |
| Mesa/Panfrost blit precision | [Mesa project brief](../video-libraries/mesa/README.md) and [precision model](../video-libraries/mesa/docs/blit-precision.md) | [uncached readback cliff](2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md) → [varying erratum workaround](2026-07-22-mali-varying-depth-bias-erratum-workaround.md) → [oblong-triangle matrix](2026-07-24-mali-oblong-triangle-matrix.md) → [benchmark plan](2026-07-27-mali-blit-workaround-performance-benchmark-plan.md) → [bounded correctness pass; cost still open](2026-07-27-mesa-all-blit-workaround-benchmark-results.md) | [`status.md` track 8](../status.md) |
| CPU voltage binning | [Two-track PVTM/eFuse port model](../kernel-versions/docs/pvtm-opp-binning-plan.md) | [BSP/mainline comparison](2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md) → [this board's measured L5/L7/L7 selection](2026-07-27-rk3588-pvtm-volt-sel-measured.md) | [`status.md` track 15](../status.md) |

Maintain this table only when a thread gains a better re-entry point or its
canonical owner changes. Ordinary new findings belong in the generated index;
they do not all need a trail entry.

## Index (newest first)

Each generated row is a link plus the finding's exact H1 title. Detailed
summaries, evidence classifications, and trust tags stay in the finding rather
than being duplicated here. After adding or renaming a finding, run:

```bash
python3 scripts/update-findings-index.py
```

Forward-port patch numbers in dated findings are the numbers that were current
when the finding was written. The series was renumbered on 2026-07-23 (old `N` →
new `N−1` for `N ≥ 13`; old `0012` removed), so resolve any bare number through
the [renumber map](../kernel-drivers/patches/forward-port-rk3588/README.md#renumber-map-2026-07-23).
`status.md` always uses current numbers.

<!-- findings-index:start -->
- [`2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md`](2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md) — Rockchip MPP HEVC TILES failure: same-ID PPS changes never reach the HAL
- [`2026-07-27-rk3588-spl-ramoops-binary-audit.md`](2026-07-27-rk3588-spl-ramoops-binary-audit.md) — Exact SPL audit closes the ordinary CPU zero-writer, not the DDR mechanism
- [`2026-07-27-rk3588-ramoops-next-experiment-plan.md`](2026-07-27-rk3588-ramoops-next-experiment-plan.md) — Ramoops next experiments: find the first boot stage that changes the bytes
- [`2026-07-27-rk3588-pvtm-volt-sel-measured.md`](2026-07-27-rk3588-pvtm-volt-sel-measured.md) — This ROCK 5B's BSP voltage-select index measured: L5 little / L7 both big clusters
- [`2026-07-27-rewrite-reset-import-fixture-lockdep.md`](2026-07-27-rewrite-reset-import-fixture-lockdep.md) — Reset/import KUnit fixture missed the DCHS spinlock initialized in its sibling
- [`2026-07-27-rewrite-mpp-preflight-freeze.md`](2026-07-27-rewrite-mpp-preflight-freeze.md) — MPP conformance froze in pre-workload state capture after KUnit poisoned the service
- [`2026-07-27-rewrite-kunit-lockdep-kmemleak-fixtures.md`](2026-07-27-rewrite-kunit-lockdep-kmemleak-fixtures.md) — Final rewrite KUnit boot blockers were one uninitialized mutex and one nested allocation
- [`2026-07-27-rewrite-kunit-final-stack-fixture.md`](2026-07-27-rewrite-kunit-final-stack-fixture.md) — Final capped RGA KUnit stack fixture warning is fixed in both rewrite trees
- [`2026-07-27-rewrite-kunit-boot-lifecycle-wedge.md`](2026-07-27-rewrite-kunit-boot-lifecycle-wedge.md) — Rewrite KUnit boot wedge was live-singleton destruction after initcalls
- [`2026-07-27-rewrite-kasan-fixed-source-package.md`](2026-07-27-rewrite-kasan-fixed-source-package.md) — Fixed-source rewrite KASAN package is built and package-verified
- [`2026-07-27-mesa-all-blit-workaround-benchmark-results.md`](2026-07-27-mesa-all-blit-workaround-benchmark-results.md) — Mesa all-blit workaround benchmark validates correctness but not per-blit cost
- [`2026-07-27-mali-blit-workaround-performance-benchmark-plan.md`](2026-07-27-mali-blit-workaround-performance-benchmark-plan.md) — Plan for measuring per-blit cost of the Mali workaround
- [`2026-07-27-grd-sg-oops-third-repro-ioctl-window-measured.md`](2026-07-27-grd-sg-oops-third-repro-ioctl-window-measured.md) — Third GRD oops under live MPP tracing: one buffer import, an immediate fatal sync, and the fingerprint holds 3/3
- [`2026-07-27-grd-sg-corruption-reproduced-and-ioctl-capture-plan.md`](2026-07-27-grd-sg-corruption-reproduced-and-ioctl-capture-plan.md) — GRD system-heap oops reproduces 2/2 on production, and both corrupt pointers land 256 bytes below a 16 KiB boundary
- [`2026-07-27-grd-sg-corruption-kasan-non-reproduction.md`](2026-07-27-grd-sg-corruption-kasan-non-reproduction.md) — The KASAN kernel does not reproduce the GRD system-heap oops, and is likely unable to
- [`2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md`](2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md) — GRD's first RKMPP frame oopses on a corrupted system-heap scatterlist entry
- [`2026-07-26-vlc-headless-vaapi-device-boundary.md`](2026-07-26-vlc-headless-vaapi-device-boundary.md) — VLC headless playback cannot prove rockchip-vaapi hardware decode
- [`2026-07-26-rockchip-vaapi-webrtc-rtp-validation.md`](2026-07-26-rockchip-vaapi-webrtc-rtp-validation.md) — rockchip-vaapi H.264 reaches the WebRTC-compatible RTP boundary
- [`2026-07-26-rockchip-vaapi-planar-encode-upload-validation.md`](2026-07-26-rockchip-vaapi-planar-encode-upload-validation.md) — rockchip-vaapi planar VA uploads are normalized safely to MPP NV12
- [`2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md`](2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md) — rockchip-vaapi 10-bit decode needs MPP AFBC plus crop metadata
- [`2026-07-26-rockchip-vaapi-hevc-va-encode-validation.md`](2026-07-26-rockchip-vaapi-hevc-va-encode-validation.md) — rockchip-vaapi HEVC VA encode requires the native RK3588 CTU64 contract
- [`2026-07-26-rockchip-vaapi-hevc-rps-and-p010-boundary.md`](2026-07-26-rockchip-vaapi-hevc-rps-and-p010-boundary.md) — rockchip-vaapi HEVC RPS boundary, with P010 fixed below it
- [`2026-07-26-rockchip-vaapi-h264-va-encode-validation.md`](2026-07-26-rockchip-vaapi-h264-va-encode-validation.md) — rockchip-vaapi H.264 VA encode is interoperable through FFmpeg and GStreamer
- [`2026-07-26-rockchip-vaapi-dual-encode-soak-smoke.md`](2026-07-26-rockchip-vaapi-dual-encode-soak-smoke.md) — rockchip-vaapi dual encode soak exposed HEVC visible/aligned geometry
- [`2026-07-26-rockchip-vaapi-drm-prime-rgb-encode-validation.md`](2026-07-26-rockchip-vaapi-drm-prime-rgb-encode-validation.md) — rockchip-vaapi imports linear RGB DMA-BUFs for checked RGA encode input
- [`2026-07-26-rk3588-ddr-blob-ramoops-static-audit.md`](2026-07-26-rk3588-ddr-blob-ramoops-static-audit.md) — RK3588 DDR blobs do not directly clear the Linux ramoops window
- [`2026-07-26-rewrite-kunit-poisons-runtime-and-rga3-probe-fails.md`](2026-07-26-rewrite-kunit-poisons-runtime-and-rga3-probe-fails.md) — Failed rewrite KUnit poisoned MPP runtime while overlapping resources disabled RGA3
- [`2026-07-26-rewrite-kunit-gate-passes.md`](2026-07-26-rewrite-kunit-gate-passes.md) — Rewrite KUnit gate passes all 232 cases on the follow-up boot
- [`2026-07-26-rewrite-kunit-failure-root-causes.md`](2026-07-26-rewrite-kunit-failure-root-causes.md) — Rewrite KUnit failures were stale fixtures plus six driver-contract defects
- [`2026-07-26-firefox-rdd-rockchip-vaapi-policy.md`](2026-07-26-firefox-rdd-rockchip-vaapi-policy.md) — Firefox 152.0.6 RDD needs both Rockchip broker paths and ioctl requests
- [`2026-07-26-firefox-rdd-package-build-checkpoint.md`](2026-07-26-firefox-rdd-package-build-checkpoint.md) — Firefox 152.0.6 Rockchip RDD package build is configured but paused
- [`2026-07-26-dwc-pcie-pmu-bus-notifier-lockdep-false-positive.md`](2026-07-26-dwc-pcie-pmu-bus-notifier-lockdep-false-positive.md) — DWC PCIe PMU nests distinct same-class bus notifier locks and disables lockdep
- [`2026-07-25-rock5b-zram-thrash-livelock-wedge.md`](2026-07-25-rock5b-zram-thrash-livelock-wedge.md) — The board wedges by thrash livelock, not by OOM — zram saturation plus a page-cache flood, with no daemon to break it
- [`2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md`](2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md) — RK3588 per-die voltage binning: the BSP selects voltage from eFuse, mainline ships only the worst-die column
- [`2026-07-25-forward-port-6-18-40-kasan-full-validation.md`](2026-07-25-forward-port-6-18-40-kasan-full-validation.md) — Forward-port 6.18.40 KASAN validation closes the 0074 and 0075 hardware gates
- [`2026-07-25-armbian-linuxfamily-rename-silent-patch-free-kernel.md`](2026-07-25-armbian-linuxfamily-rename-silent-patch-free-kernel.md) — One Armbian variable, `LINUXFAMILY`, silently built a patch-free kernel and threw away the whole kernel ccache
- [`2026-07-24-rock5b-spi-vs-radxa-bsp-firmware-generation-gap.md`](2026-07-24-rock5b-spi-vs-radxa-bsp-firmware-generation-gap.md) — The installed SPI is not U-Boot-incompatible with Radxa BSP images; the real gap is the firmware blob generation
- [`2026-07-24-rknpu-forward-port-scoping.md`](2026-07-24-rknpu-forward-port-scoping.md) — RKNPU forward-port scoping: 8.6k lines, three hard spots, smaller than the MPP/RGA port
- [`2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md`](2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md) — RGA3 legacy-blit 10-bit stride convention fault — `0048` regressed legacy byte-stride callers
- [`2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md`](2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md) — RGA 10-bit UV plane offset still pixel-scaled — `0072` fixed the stride but not `0049`'s sibling site
- [`2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md`](2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md) — 10-bit `vir_w` is a byte stride in TILE too — the `* 8` is a line factor, not a depth scale
- [`2026-07-24-rewrite-driver-multi-agent-defect-audit.md`](2026-07-24-rewrite-driver-multi-agent-defect-audit.md) — Multi-agent defect audit of the rewrite drivers: 17 confirmed, 4 refuted, all fixed
- [`2026-07-24-production-ppa-kernel-full-conformance-run.md`](2026-07-24-production-ppa-kernel-full-conformance-run.md) — Production PPA kernel (…20260723) — full driver conformance run, all gates green
- [`2026-07-24-mali-oblong-triangle-matrix.md`](2026-07-24-mali-oblong-triangle-matrix.md) — Mali oblong-triangle matrix for MR !43161
- [`2026-07-24-mali-blit-workaround-size-results.md`](2026-07-24-mali-blit-workaround-size-results.md) — Mali blit workaround size results for Mesa MR !43161
- [`2026-07-24-bsp-vs-armbian-ramoops-gap.md`](2026-07-24-bsp-vs-armbian-ramoops-gap.md) — BSP vs. Armbian ramoops: provisioning is not proof of retention
- [`2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md`](2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md) — ROCK 5B boot hang recurred with the patched Plymouth provably in the boot path
- [`2026-07-23-rga-scattered-userptr-unaligned-src-zero-output.md`](2026-07-23-rga-scattered-userptr-unaligned-src-zero-output.md) — RGA scattered-userptr blit silently returns all-zero output for non-16-byte-aligned source offsets
- [`2026-07-23-forward-port-current-tip-full-validation-run.md`](2026-07-23-forward-port-current-tip-full-validation-run.md) — Forward-port current tip (`0072`) full validation run — KASAN debug build
- [`2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md`](2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md) — ROCK 5B boot was held by an unresponsive initramfs Plymouth daemon
- [`2026-07-22-rga-mm-session-debugfs-uaf-freed-task-struct.md`](2026-07-22-rga-mm-session-debugfs-uaf-freed-task-struct.md) — RGA `mm_session` debugfs read is a use-after-free on a freed `task_struct` (+ unkillable D-state hang)
- [`2026-07-22-mpp-process-request-list-add-double-add-warn.md`](2026-07-22-mpp-process-request-list-add-double-add-warn.md) — MPP `INIT_CLIENT_TYPE` double-call corrupts the workqueue session list
- [`2026-07-22-mali-varying-depth-bias-erratum-workaround.md`](2026-07-22-mali-varying-depth-bias-erratum-workaround.md) — Mali-G610 varying erratum: zero-valued depth bias repairs GL, Vulkan, and ordinary TEX
- [`2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md`](2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md) — GStreamer conformance on the forward-port kernel — green modulo 4 userspace gaps
- [`2026-07-22-bsp-high-current-tip-port.md`](2026-07-22-bsp-high-current-tip-port.md) — BSP-audit HIGH findings ported to the current forward-port tip
- [`2026-07-22-bsp-bug-upstream-submission-priority.md`](2026-07-22-bsp-bug-upstream-submission-priority.md) — Which patched BSP bugs are critical enough to report upstream immediately
- [`2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md`](2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md) — Why AV1 is hard for the VA-API↔MPP bridge (and H.264/HEVC/VP9 are not): the bitstream-reconstruction spectrum
- [`2026-07-21-ubuntu-rockchip-piggyback-survey.md`](2026-07-21-ubuntu-rockchip-piggyback-survey.md) — ubuntu-rockchip (Joshua Riek) survey: a working Chromium V4L2-stateful-over-MPP bridge exists, the project is archived, and per-app reuse is now mapped
- [`2026-07-21-rockchip-vaapi-driver-review.md`](2026-07-21-rockchip-vaapi-driver-review.md) — rockchip-vaapi review: a working PoC VA-API-over-MPP driver exists; strategic architecture is right, two load-bearing shortcuts must be replaced; recommend fork-and-renovate
- [`2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md`](2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md) — Scope: RGA2 page-table DMA ownership (0050) and DMA-API over-4G path (0051)
- [`2026-07-21-rga-rewrite-rust-counterfactual.md`](2026-07-21-rga-rewrite-rust-counterfactual.md) — Rust counterfactual for the RGA clean-room rewrite: wrong call in 2026, right call once dma-buf/fence/IOMMU abstractions land
- [`2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md`](2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md) — RGA `rga_request` completion races session-close: KASAN use-after-free on the current forward-port tip
- [`2026-07-21-rga-job-vs-session-close-uaf-kasan.md`](2026-07-21-rga-job-vs-session-close-uaf-kasan.md) — RGA in-flight job outlives its session: KASAN use-after-free on the session object
- [`2026-07-21-rga-forward-port-abi-gaps.md`](2026-07-21-rga-forward-port-abi-gaps.md) — RGA forward-port ABI replay gaps are fixed and pass booted replay
- [`2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md`](2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md) — Root causes for the FFmpeg 10-bit/AV1 diagnostics and librga smoke failures
- [`2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md`](2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md) — Ramoops/pstore does not survive a warm reset on this ROCK 5B
- [`2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md`](2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md) — MPP client-less session NULL-deref hard crash — `RELEASE_FD` dereferences a NULL `session->dma`
- [`2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md`](2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md) — Mainline AV1/V4L2 vs VA-API, and why Firefox's only Rockchip hardware-decode route is VA-API
- [`2026-07-21-grd-rdp-audio-live-validation-and-codec-control.md`](2026-07-21-grd-rdp-audio-live-validation-and-codec-control.md) — GRD audio is audible as PCM; Windows uses the same SVC fallback
- [`2026-07-21-forward-port-lifetime-resource-ownership-audit.md`](2026-07-21-forward-port-lifetime-resource-ownership-audit.md) — Forward-port MPP/RGA lifetime and resource-ownership audit
- [`2026-07-20-rkvenc2-slice-fifo-terminal-drop.md`](2026-07-20-rkvenc2-slice-fifo-terminal-drop.md) — RKVENC2 silently drops the terminal slice when its per-task FIFO fills
- [`2026-07-20-rga2-unmapped-page-table-dma-sync.md`](2026-07-20-rga2-unmapped-page-table-dma-sync.md) — RGA2 syncs page-table memory through an unmapped DMA address
- [`2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md`](2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md) — macOS focus return can wedge GRD in restored RDPGFX acknowledgement history
- [`2026-07-20-grd-rdp-audio-split-stack.md`](2026-07-20-grd-rdp-audio-split-stack.md) — RDP audio negotiated successfully but PulseAudio bypassed GRD's PipeWire graph
- [`2026-07-20-grd-focus-return-false-pipeline-starvation.md`](2026-07-20-grd-focus-return-false-pipeline-starvation.md) — Focus return can falsely charge idle time as a GRD pipeline stall
- [`2026-07-20-armbian-radxa-image-fit-audit.md`](2026-07-20-armbian-radxa-image-fit-audit.md) — Armbian Radxa catalog: 21 zero-DTB images, 207 clean, 95 not applicable
- [`2026-07-20-armbian-non-radxa-radxa-uboot-audit.md`](2026-07-20-armbian-non-radxa-radxa-uboot-audit.md) — Non-Radxa Radxa-U-Boot catalog: 17 zero-DTB images, 182 clean, 4 unavailable
- [`2026-07-19-grd-rkmpp-encoder-wedge-userspace-not-driver.md`](2026-07-19-grd-rkmpp-encoder-wedge-userspace-not-driver.md) — GRD's intermittent HW-encode wedge is userspace (rkmpp/ffmpeg), not the rkvenc2 driver
- [`2026-07-19-grd-rkmpp-encoder-wedge-mpp-input-backpressure.md`](2026-07-19-grd-rkmpp-encoder-wedge-mpp-input-backpressure.md) — GRD encoder wedge, pinned: MPP input-task backpressure + get_packet timeout (userspace flow control)
- [`2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md`](2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md) — KASAN: rkvenc2_wait_result reads task->state after freeing the task (forward-port-introduced)
- [`2026-07-18-mpp-reset-session-dma-double-free-kasan.md`](2026-07-18-mpp-reset-session-dma-double-free-kasan.md) — KASAN caught the preflight Oops: MPP_CMD_RESET_SESSION double-frees session->dma
- [`2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md`](2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md) — Mesa/panfrost: glReadPixels convert fallback is catastrophic over uncached imported buffers
- [`2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md`](2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md) — GRD's frame-starvation detector only warns — it never actuates recovery
- [`2026-07-17-rk3588-maxline-implementation-and-build-record.md`](2026-07-17-rk3588-maxline-implementation-and-build-record.md) — RK3588 maxline implementation and build record
- [`2026-07-17-rk3588-maximum-mainline-kernel-plan.md`](2026-07-17-rk3588-maximum-mainline-kernel-plan.md) — Maximum-mainline RK3588 kernel plan for this Armbian ROCK 5B
- [`2026-07-17-rga-session-close-uaf.md`](2026-07-17-rga-session-close-uaf.md) — RGA session-close force-free ignores refcounts; a leaked test handle exposed it as a kernel Oops
- [`2026-07-17-mpp-procfs-session-teardown-oops.md`](2026-07-17-mpp-procfs-session-teardown-oops.md) — MPP procfs session dump races private teardown and NULL-dereferences
- [`2026-07-17-forward-port-conformance-preflight-oops.md`](2026-07-17-forward-port-conformance-preflight-oops.md) — Forward-port conformance preflight Oopsed before the first MPP case
- [`2026-07-16-rockchip-bsp-driver-quality.md`](2026-07-16-rockchip-bsp-driver-quality.md) — Rockchip BSP driver quality is feature-strong but below mature mainline robustness
- [`2026-07-13-rock5b-u-boot-fit-dtb-race.md`](2026-07-13-rock5b-u-boot-fit-dtb-race.md) — ROCK 5B zero-DTB race: controlled proof, Noble `cp`, and KSpace amplification
- [`2026-07-11-rock5b-u-boot-four-way-comparison.md`](2026-07-11-rock5b-u-boot-four-way-comparison.md) — ROCK 5B U-Boot comparison: Armbian 26.2, Armbian 26.5, Radxa, upstream
- [`2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md`](2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md) — Kodi 22 hardware video on RK3588 via ffmpeg-rockchip-81: MPP runtime, three fork-packaging bugs, and zero-patch decoder selection
- [`2026-07-09-rock5b-armbian-sd-boot-investigation.md`](2026-07-09-rock5b-armbian-sd-boot-investigation.md) — ROCK 5B Armbian SD boot investigation summary
- [`2026-07-09-ffmpeg-baseline-rk2-local-build-validation.md`](2026-07-09-ffmpeg-baseline-rk2-local-build-validation.md) — FFmpeg baseline `-1+rk2` local source-package build validates frei0r fix
- [`2026-07-08-blit-precision-nir-migration.md`](2026-07-08-blit-precision-nir-migration.md) — Blit-precision fix: the TGSI→NIR migration and doing it with pixel_coord
- [`2026-07-08-armbian-builder-setup.md`](2026-07-08-armbian-builder-setup.md) — ROCK 5B Armbian builder: native host, branch/release map, and remote-cache behavior
- [`2026-07-08-armbian-26.2.1-bl31-handoff-hang.md`](2026-07-08-armbian-26.2.1-bl31-handoff-hang.md) — Armbian 26.2.1 ROCK 5B raw bootloader hangs after BL31 handoff
- [`2026-07-08-arm-mali-blob-interp-drift-bit-identical-to-mesa.md`](2026-07-08-arm-mali-blob-interp-drift-bit-identical-to-mesa.md) — ARM Mali blob reproduces the varying-interpolation drift bit-for-bit identically to Mesa/Panfrost
- [`2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md`](2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md) — ARM Mali blob GBM path kernel-Oopses in drm_setversion on the Radxa 5.10 vendor kernel
- [`2026-07-07-rock5b-spi-sd-boot-chain.md`](2026-07-07-rock5b-spi-sd-boot-chain.md) — ROCK 5B SPI U-Boot changes how Radxa SD images boot
- [`2026-07-07-arm-mali-blob-reproducer-readiness.md`](2026-07-07-arm-mali-blob-reproducer-readiness.md) — ARM Mali blob interp reproducer readiness on the Radxa Bullseye 5.10 vendor distro
- [`2026-07-06-rga3-dmabuf-scatter-bsp-contract.md`](2026-07-06-rga3-dmabuf-scatter-bsp-contract.md) — RGA3 dma-buf scatter contract vs BSP
- [`2026-07-06-ffmpeg-rockchip81-package-validation.md`](2026-07-06-ffmpeg-rockchip81-package-validation.md) — ffmpeg-rockchip-81 package validation failures and MPP root cause
- [`2026-07-05-rkvenc-rcb-sram.md`](2026-07-05-rkvenc-rcb-sram.md) — RK3588 RKVENC RCB/SRAM support is ABI-plumbed but not SRAM-backed in DT
- [`2026-07-05-rga3-userptr-iommu-runtime-smoke.md`](2026-07-05-rga3-userptr-iommu-runtime-smoke.md) — RGA3 userptr-IOMMU runtime smoke: behavior passes, fallback attribution still indirect
- [`2026-07-05-rga3-userptr-iommu-design.md`](2026-07-05-rga3-userptr-iommu-design.md) — RGA3 userptr-IOMMU fallback design: driver-owned contiguous IOVA for scattered userptr
- [`2026-07-05-rga3-scattered-iova-mechanism.md`](2026-07-05-rga3-scattered-iova-mechanism.md) — Why RGA3 userptr imports get non-contiguous IOVAs: per-segment mapping, not the guard band
- [`2026-07-05-rga3-memory-import-contract.md`](2026-07-05-rga3-memory-import-contract.md) — RGA3 memory import contract: fd, userptr, physical address, and mmap paths
- [`2026-07-04-rga3-im2d-error-irq.md`](2026-07-04-rga3-im2d-error-irq.md) — RGA3 MMU interrupt on direct im2d samples: RGA DMA/IOMMU IOVA contract gaps
- [`2026-07-04-librga-consumer-survey.md`](2026-07-04-librga-consumer-survey.md) — Public librga consumer survey: RKNN is the main additional Linux signal
<!-- findings-index:end -->
