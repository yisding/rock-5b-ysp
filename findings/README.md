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
- **USER-REPORTED** — reported by the board operator but not independently
  observed; the finding must state what artifact or replay detail is absent.

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
with a tombstone so the trail survives. Every tombstone shares one shape — the
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
| Clean-room rewrite qualification | [Rewrite architecture](../kernel-drivers/docs/rewrite-driver-architecture/README.md) | [defect audit](2026-07-24-rewrite-driver-multi-agent-defect-audit.md) → [first complete KUnit failures](2026-07-26-rewrite-kunit-failure-root-causes.md) → [boot-lifecycle wedge](2026-07-27-rewrite-kunit-boot-lifecycle-wedge.md) → [fixture/lockdep boundary](2026-07-27-rewrite-reset-import-fixture-lockdep.md) → [rewrite counterfactual](2026-08-01-rewrite-driver-retrospective.md) → [current source/build boundary](2026-08-04-rewrite-kunit-request-rotation-repair.md) | [`status.md` track 4](../status.md) and [rewrite conformance contract](../kernel-drivers/tests/rewrite-conformance.md) |
| RGA memory and 10-bit ABI | [userptr/IOMMU model](../kernel-drivers/rga/docs/userptr-iommu.md) and [librga 10-bit contract](../vendor-libraries/rga/docs/librga-p010-p210-rkrga.md) | [conformance root causes](2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md) → [legacy byte-stride regression](2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md) → [UV-offset sibling defect](2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md) → [TILE correction](2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md) → [hardware validation](2026-07-25-forward-port-6-18-40-kasan-full-validation.md) | [`status.md` W13/W16](../status.md) |
| GNOME Remote Desktop end to end | [Capture path](../apps/gnome-remote-desktop/docs/capture-path.md) and [test gates](../apps/gnome-remote-desktop/docs/testing.md) | [MPP input backpressure](2026-07-19-grd-rkmpp-encoder-wedge-mpp-input-backpressure.md) → [RDPGFX ACK wedge](2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md) → [audio validation](2026-07-21-grd-rdp-audio-live-validation-and-codec-control.md) → [first-frame kernel oops](2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md) | [`status.md` track 7](../status.md) |
| SD/SPI/U-Boot diagnosis | [Boot-chain model](../boot-firmware/docs/u-boot-primer.md) and [artifact comparison](../boot-firmware/docs/version-comparison.md) | [SD boot investigation](2026-07-09-rock5b-armbian-sd-boot-investigation.md) → [FIT/DTB race](2026-07-13-rock5b-u-boot-fit-dtb-race.md) → [firmware-generation gap](2026-07-24-rock5b-spi-vs-radxa-bsp-firmware-generation-gap.md) | [`status.md` track 12](../status.md) |
| Ramoops retention | [Maintained retention explanation](../boot-firmware/docs/ramoops-retention.md) | [measured loss](2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md) → [BSP-premise correction](2026-07-24-bsp-vs-armbian-ramoops-gap.md) → [DDR/TPL audit](2026-07-26-rk3588-ddr-blob-ramoops-static-audit.md) → [SPL audit](2026-07-27-rk3588-spl-ramoops-binary-audit.md) → [next temporal experiment](2026-07-27-rk3588-ramoops-next-experiment-plan.md) | [Current evidence contract and next causal experiment](../boot-firmware/docs/ramoops-retention.md#current-evidence-contract) |
| Desktop VA-API and browser path | [VA-API capability/boundary model](../video-libraries/vaapi/README.md) and [app map](../docs/app-enablement.md) | [fork review](2026-07-21-rockchip-vaapi-driver-review.md) → [bitstream-reconstruction spectrum](2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md) → [Main10/AFBC/P010 validation](2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md) → [Firefox RDD policy](2026-07-26-firefox-rdd-rockchip-vaapi-policy.md) → [roadmap qualification and Firefox/Panfrost boundary](2026-07-29-rockchip-vaapi-roadmap-phase2-phase4-closure.md) → [installed ysp8 runtime and IEP2 warning](2026-08-02-rockchip-vaapi-ysp8-installed-runtime-validation.md) → [forward-port RGA3 small-geometry discriminator](2026-08-02-rga3-forward-port-small-geometry-discriminator.md) → [RK3588 IEP2/VDPP source audit](2026-08-02-rk3588-iep2-vdpp-source-audit.md) | [`status.md` track 14](../status.md) |
| Mesa/Panfrost blit precision | [Mesa project brief](../video-libraries/mesa/README.md) and [precision model](../video-libraries/mesa/docs/blit-precision.md) | [uncached readback cliff](2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md) → [varying erratum workaround](2026-07-22-mali-varying-depth-bias-erratum-workaround.md) → [oblong-triangle matrix](2026-07-24-mali-oblong-triangle-matrix.md) → [benchmark plan](2026-07-27-mali-blit-workaround-performance-benchmark-plan.md) → [bounded correctness pass; cost still open](2026-07-27-mesa-all-blit-workaround-benchmark-results.md) | [`status.md` track 8](../status.md) |
| CPU voltage binning | [Two-track PVTM/eFuse port model](../kernel-versions/docs/pvtm-opp-binning-plan.md) | [BSP/mainline comparison](2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md) → [this board's measured L5/L7/L7 selection](2026-07-27-rk3588-pvtm-volt-sel-measured.md) | [`status.md` track 15](../status.md) |

Maintain this table only when a thread gains a better re-entry point or its
canonical owner changes. Ordinary new findings belong in the generated index;
they do not all need a trail entry.

## Browse by subsystem

The generated chronology below answers *what was learned when*. This index
answers *what do we know about X* — every live finding, grouped by the layer it
belongs to, newest first inside each group. Tombstones are deliberately absent:
they are pointers, and the chronological index still lists them.

Coverage is mechanically enforced — `scripts/check-doc-consistency.py` fails if
a live finding is missing from these groups, appears in two, or names a file
that does not exist. When you add a finding, add its row here too.

<!-- findings-topics:start -->

### Boot chain, U-Boot, and firmware (7)

Power-on to Linux handoff: SPI/SD boot, FIT/DTB artifacts, and the vendor-vs-Armbian firmware gap.

- [`2026-07-24`](2026-07-24-rock5b-spi-vs-radxa-bsp-firmware-generation-gap.md) — The installed SPI is not U-Boot-incompatible with Radxa BSP images; the real gap is the firmware blob generation
- [`2026-07-20`](2026-07-20-armbian-radxa-image-fit-audit.md) — Armbian Radxa catalog: 21 zero-DTB images, 207 clean, 95 not applicable
- [`2026-07-20`](2026-07-20-armbian-non-radxa-radxa-uboot-audit.md) — Non-Radxa Radxa-U-Boot catalog: 17 zero-DTB images, 182 clean, 4 unavailable
- [`2026-07-13`](2026-07-13-rock5b-u-boot-fit-dtb-race.md) — ROCK 5B zero-DTB race: controlled proof, Noble `cp`, and KSpace amplification
- [`2026-07-09`](2026-07-09-rock5b-armbian-sd-boot-investigation.md) — ROCK 5B Armbian SD boot investigation summary
- [`2026-07-08`](2026-07-08-armbian-26.2.1-bl31-handoff-hang.md) — Armbian 26.2.1 ROCK 5B raw bootloader hangs after BL31 handoff
- [`2026-07-07`](2026-07-07-rock5b-spi-sd-boot-chain.md) — ROCK 5B SPI U-Boot changes how Radxa SD images boot

### Ramoops and crash retention (6)

Whether a crash record survives reset — and the four audits that relocated the cause.

- [`2026-07-28`](2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md) — Ramoops retention works on the 6.18.40-era kernels — the all-zero failure was kernel-generation-scoped, not firmware-scoped
- [`2026-07-27`](2026-07-27-rk3588-spl-ramoops-binary-audit.md) — Exact SPL audit closes the ordinary CPU zero-writer, not the DDR mechanism
- [`2026-07-27`](2026-07-27-rk3588-ramoops-next-experiment-plan.md) — Ramoops next experiments: find the first boot stage that changes the bytes
- [`2026-07-26`](2026-07-26-rk3588-ddr-blob-ramoops-static-audit.md) — RK3588 DDR blobs do not directly clear the Linux ramoops window
- [`2026-07-24`](2026-07-24-bsp-vs-armbian-ramoops-gap.md) — BSP vs. Armbian ramoops: provisioning is not proof of retention
- [`2026-07-21`](2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md) — Ramoops/pstore does not survive a warm reset on this ROCK 5B

### Boot hangs and board wedges (4)

Failures that stop the board rather than a driver.

- [`2026-07-30`](2026-07-30-boot-failure-retro-prevention-levers.md) — Wedge-week retrospective: what would have caught each failure class before boot
- [`2026-07-25`](2026-07-25-rock5b-zram-thrash-livelock-wedge.md) — The board wedges by thrash livelock, not by OOM — zram saturation plus a page-cache flood, with no daemon to break it
- [`2026-07-23`](2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md) — ROCK 5B boot hang recurred with the patched Plymouth provably in the boot path
- [`2026-07-22`](2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md) — ROCK 5B boot was held by an unresponsive initramfs Plymouth daemon

### Board platform: power, clocks, network (4)

RK3588 platform behaviour outside the media path.

- [`2026-08-01`](2026-08-01-armbian-rockchip64-defaults-tcp-reno.md) — Armbian's rockchip64 kernel configs default TCP congestion control to reno
- [`2026-07-27`](2026-07-27-rk3588-pvtm-volt-sel-measured.md) — This ROCK 5B's BSP voltage-select index measured: L5 little / L7 both big clusters
- [`2026-07-26`](2026-07-26-dwc-pcie-pmu-bus-notifier-lockdep-false-positive.md) — DWC PCIe PMU nests distinct same-class bus notifier locks and disables lockdep
- [`2026-07-25`](2026-07-25-rk3588-cpu-voltage-binning-bsp-vs-mainline.md) — RK3588 per-die voltage binning: the BSP selects voltage from eFuse, mainline ships only the worst-die column

### Kernel forward port: MPP and codec drivers (20)

Vendor MPP/rkvenc/rkvdec forward-ported to 6.18 — defects, audits, and whole-tip validation runs.

- [`2026-08-04`](2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md) — Forward-port 0090–0092 close the RGA job-task and decoder recovery lifetime gaps
- [`2026-08-04`](2026-08-04-rkvenc-encoder-rcb-sram-scope.md) — RK3588 encoder RCB is reachable only by >4096-wide H.264, so the absent encoder SRAM costs almost nothing
- [`2026-08-01`](2026-08-01-forward-port-uaf-oops-audit-round-2.md) — Forward-port UAF/oops audit round 2: 18 defects, 7 of them unprivileged memory corruption
- [`2026-07-29`](2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md) — MPP job-ISR IOMMU fault-handler clear takes sleeping locks and panicked the idle task
- [`2026-07-29`](2026-07-29-forward-port-warn-oops-audit-and-fixes.md) — Forward-port MPP/RGA WARN/oops audit: 18 defects found and fixed
- [`2026-07-28`](2026-07-28-rkvdec2-err23-picsize-oversize-width.md) — rkvdec2 `err 0x23`: an 8192-sample width inflection, BSP watchdog constants whose names are wrong, and VA-API caps that are wrong in both directions
- [`2026-07-25`](2026-07-25-forward-port-6-18-40-kasan-full-validation.md) — Forward-port 6.18.40 KASAN validation closes the 0074 and 0075 hardware gates
- [`2026-07-24`](2026-07-24-production-ppa-kernel-full-conformance-run.md) — Production PPA kernel (…20260723) — full driver conformance run, all gates green
- [`2026-07-23`](2026-07-23-forward-port-current-tip-full-validation-run.md) — Forward-port current tip (`0072`) full validation run — KASAN debug build
- [`2026-07-22`](2026-07-22-mpp-process-request-list-add-double-add-warn.md) — MPP `INIT_CLIENT_TYPE` double-call corrupts the workqueue session list
- [`2026-07-22`](2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md) — GStreamer conformance on the forward-port kernel — green modulo 4 userspace gaps
- [`2026-07-22`](2026-07-22-bsp-high-current-tip-port.md) — BSP-audit HIGH findings ported to the current forward-port tip
- [`2026-07-21`](2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md) — MPP client-less session NULL-deref hard crash — `RELEASE_FD` dereferences a NULL `session->dma`
- [`2026-07-21`](2026-07-21-forward-port-lifetime-resource-ownership-audit.md) — Forward-port MPP/RGA lifetime and resource-ownership audit
- [`2026-07-20`](2026-07-20-rkvenc2-slice-fifo-terminal-drop.md) — RKVENC2 silently drops the terminal slice when its per-task FIFO fills
- [`2026-07-18`](2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md) — KASAN: rkvenc2_wait_result reads task->state after freeing the task (forward-port-introduced)
- [`2026-07-18`](2026-07-18-mpp-reset-session-dma-double-free-kasan.md) — KASAN caught the preflight Oops: MPP_CMD_RESET_SESSION double-frees session->dma
- [`2026-07-17`](2026-07-17-mpp-procfs-session-teardown-oops.md) — MPP procfs session dump races private teardown and NULL-dereferences
- [`2026-07-17`](2026-07-17-forward-port-conformance-preflight-oops.md) — Forward-port conformance preflight Oopsed before the first MPP case
- [`2026-07-16`](2026-07-16-rockchip-bsp-driver-quality.md) — Rockchip BSP driver quality is feature-strong but below mature mainline robustness

### Kernel RGA: memory contracts and 10-bit ABI (16)

The `/dev/rga` driver — session lifetime, userptr/dma-buf imports, and the 10-bit stride convention.

- [`2026-08-02`](2026-08-02-rga3-forward-port-small-geometry-discriminator.md) — Forward-port RGA3 passes the repeated small-geometry AFBC-to-P010 dropped-write discriminator
- [`2026-07-31`](2026-07-31-rga3-afbc-p010-dropped-destination-write.md) — RGA3 AFBC NV15→P010 returns success without writing the destination at small picture sizes
- [`2026-07-31`](2026-07-31-rga-userptr-dmabuf-multisegment-contracts.md) — RGA multi-segment memory contract: the BSP relies on 5.10/6.1 IOMMU coalescing; newer drivers validate or remap
- [`2026-07-29`](2026-07-29-rga-no-core-match-narrow-afbc-10bit.md) — A narrow AFBC 10-bit frame has no RGA core: RGA3 needs width ≥ 68 and RGA2 cannot read AFBC
- [`2026-07-24`](2026-07-24-rga3-legacy-blit-10bit-stride-convention-fault.md) — RGA3 legacy-blit 10-bit stride convention fault — `0048` regressed legacy byte-stride callers
- [`2026-07-24`](2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md) — RGA 10-bit UV plane offset still pixel-scaled — `0072` fixed the stride but not `0049`'s sibling site
- [`2026-07-24`](2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md) — 10-bit `vir_w` is a byte stride in TILE too — the `* 8` is a line factor, not a depth scale
- [`2026-07-23`](2026-07-23-rga-scattered-userptr-unaligned-src-zero-output.md) — RGA scattered-userptr blit silently returns all-zero output for non-16-byte-aligned source offsets
- [`2026-07-22`](2026-07-22-rga-mm-session-debugfs-uaf-freed-task-struct.md) — RGA `mm_session` debugfs read is a use-after-free on a freed `task_struct` (+ unkillable D-state hang)
- [`2026-07-21`](2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md) — Scope: RGA2 page-table DMA ownership (0050) and DMA-API over-4G path (0051)
- [`2026-07-21`](2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md) — RGA `rga_request` completion races session-close: KASAN use-after-free on the current forward-port tip
- [`2026-07-21`](2026-07-21-rga-job-vs-session-close-uaf-kasan.md) — RGA in-flight job outlives its session: KASAN use-after-free on the session object
- [`2026-07-21`](2026-07-21-rga-forward-port-abi-gaps.md) — RGA forward-port ABI replay gaps are fixed and pass booted replay
- [`2026-07-21`](2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md) — Root causes for the FFmpeg 10-bit/AV1 diagnostics and librga smoke failures
- [`2026-07-20`](2026-07-20-rga2-unmapped-page-table-dma-sync.md) — RGA2 syncs page-table memory through an unmapped DMA address
- [`2026-07-17`](2026-07-17-rga-session-close-uaf.md) — RGA session-close force-free ignores refcounts; a leaked test handle exposed it as a kernel Oops

### Clean-room rewrite drivers (19)

The from-scratch MPP/RGA replacement: reviews, soft-CCU wedges, and reset/lifecycle races.

- [`2026-08-04`](2026-08-04-rewrite-kunit-request-rotation-repair.md) — Current rewrite tips repair request cleanup and rotation KUnit contracts
- [`2026-08-03`](2026-08-03-rewrite-rga-unreachable-iommu-irq-mask.md) — The RGA rewrite's IOMMU-IRQ-mask fallback was unreachable, and it blocked the mainline mirror
- [`2026-08-02`](2026-08-02-driver-probe-error-path-test-design.md) — Probe error paths are testable by DT alone, but -ENXIO and -ENODEV probe failures are silent by default
- [`2026-08-01`](2026-08-01-rkvdec-self-reset-and-iommu-restore-gaps.md) — The rkvdec2 hardware self-resets on error; the rewrite driver neither detects it nor restores the IOMMU
- [`2026-08-01`](2026-08-01-rewrite-soft-ccu-cross-core-reset-wedge.md) — Soft-CCU bus-stall wedge returns on the error-reset path; needs two cores of one group resetting
- [`2026-08-01`](2026-08-01-rewrite-driver-review-round-3.md) — Rewrite-driver review round 3: 11 defects, 8 of them holes in fixes already recorded as closed
- [`2026-08-01`](2026-08-01-rewrite-driver-retrospective.md) — Rewrite-driver retrospective: keep the ownership model, change the architecture and qualification order
- [`2026-07-31`](2026-07-31-rkvdec-sibling-reset-deassert-race.md) — rkvdec soft-CCU sibling power-on can cancel a peer core's recovery reset
- [`2026-07-31`](2026-07-31-rga-rewrite-multisg-dmabuf-cma-einval.md) — RGA rewrite rejects legal multi-SG DMA-BUFs; the CMA `EINVAL` is a separate untraced failure
- [`2026-07-31`](2026-07-31-rewrite-soft-ccu-iotlb-closes-vaapi-main10-packetized-failure.md) — The soft-CCU IOTLB flush closed the VA-API Main10 packetized decode failure
- [`2026-07-30`](2026-07-30-rewrite-soft-ccu-split-critical-section-h265-wedge.md) — Soft-CCU wedge survived the arm/start fix: the critical section was still split; whole-sequence lock applied
- [`2026-07-30`](2026-07-30-rewrite-rkvenc-dchs-producer-retirement-race.md) — RKVENC DCHS producer retirement raced a dependent consumer's START; lifecycle serialization applied
- [`2026-07-30`](2026-07-30-rewrite-av1-vsi-fault-afbc-lifecycle-races.md) — Rewrite AV1/VSI audit closes fault-admission and teardown races; AFBC retirement proof remains a hardware gate
- [`2026-07-29`](2026-07-29-rewrite-soft-ccu-dual-core-wedge.md) — Rewrite soft-CCU dual-core decode wedges the interconnect; arm/start split root-caused and fixed
- [`2026-07-29`](2026-07-29-rewrite-driver-review-round-2.md) — Rewrite-driver review round 2: 12 confirmed defects fixed, 4 items ledgered
- [`2026-07-29`](2026-07-29-av1-rewrite-branch-hardening-gap-and-backport.md) — rk3588-rewrite-av1-6.18 forked before 19 hardening commits; KUnit isolation and the ISR fault-handler panic fix are absent
- [`2026-07-29`](2026-07-29-av1-rewrite-backend-design-source-audit.md) — AV1 rewrite backend: three-region sparse ABI on the mpp-rewrite core with a kernel-owned AFBC block
- [`2026-07-24`](2026-07-24-rewrite-driver-multi-agent-defect-audit.md) — Multi-agent defect audit of the rewrite drivers: 17 confirmed, 4 refuted, all fixed
- [`2026-07-21`](2026-07-21-rga-rewrite-rust-counterfactual.md) — Rust counterfactual for the RGA clean-room rewrite: wrong call in 2026, right call once dma-buf/fence/IOMMU abstractions land

### Rewrite KUnit qualification (12)

The in-kernel test suite that gates the rewrite — mostly a record of fixture defects, not driver defects.

- [`2026-08-01`](2026-08-01-rewrite-kunit-boot-failures-and-suite-audit.md) — The two RGA KUnit boot failures were fixture lag; a full-suite audit tightened three more cases and pruned three
- [`2026-07-30`](2026-07-30-rewrite-kunit-gate-false-red-harness-defects.md) — First fully green rewrite KUnit boot failed the gate: four harness defects, zero kernel defects
- [`2026-07-29`](2026-07-29-rewrite-kunit-fixture-audit.md) — Rewrite KUnit fixture audit: 2 boot oopses fixed, full 232-case sweep, latent hazard inventory
- [`2026-07-28`](2026-07-28-rewrite-kunit-pre-phase-applied.md) — Rewrite KUnit pre-phase is applied with an 84/148 gate
- [`2026-07-27`](2026-07-27-rewrite-reset-import-fixture-lockdep.md) — Reset/import KUnit fixture missed the DCHS spinlock initialized in its sibling
- [`2026-07-27`](2026-07-27-rewrite-mpp-preflight-freeze.md) — MPP conformance froze in pre-workload state capture after KUnit poisoned the service
- [`2026-07-27`](2026-07-27-rewrite-kunit-lockdep-kmemleak-fixtures.md) — Final rewrite KUnit boot blockers were one uninitialized mutex and one nested allocation
- [`2026-07-27`](2026-07-27-rewrite-kunit-final-stack-fixture.md) — Final capped RGA KUnit stack fixture warning is fixed in both rewrite trees
- [`2026-07-27`](2026-07-27-rewrite-kunit-boot-lifecycle-wedge.md) — Rewrite KUnit boot wedge was live-singleton destruction after initcalls
- [`2026-07-26`](2026-07-26-rewrite-kunit-poisons-runtime-and-rga3-probe-fails.md) — Failed rewrite KUnit poisoned MPP runtime while overlapping resources disabled RGA3
- [`2026-07-26`](2026-07-26-rewrite-kunit-gate-passes.md) — Rewrite KUnit gate passes all 232 cases on the follow-up boot
- [`2026-07-26`](2026-07-26-rewrite-kunit-failure-root-causes.md) — Rewrite KUnit failures were stale fixtures plus six driver-contract defects

### dma-buf, heaps, and the system-heap scatterlist arc (8)

Memory plumbing under the codecs — including the corruption hunt that turned out to be an upstream debug option.

- [`2026-08-03`](2026-08-03-mainline-missing-uncached-dma32-heaps.md) — Mainline lacks the BSP uncached/dma32 dma-heaps; MPP absorbs it, librga samples do not
- [`2026-07-28`](2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md) — The DMABUF_DEBUG scatterlist defect is 100% upstream code, reported since 2022, and blocked on an unresolved dma-buf design argument
- [`2026-07-28`](2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md) — CONFIG_DMABUF_DEBUG's mangle_sg_table() is the system-heap page_link writer, and the dma-heap CPU-access sync dereferences it
- [`2026-07-27`](2026-07-27-grd-sg-writer-source-sweep-vendor-drivers-cleared.md) — Source sweep clears the vendor MPP driver of the GRD scatterlist write, and corrects three readings of the corrupt value
- [`2026-07-27`](2026-07-27-grd-sg-oops-third-repro-ioctl-window-measured.md) — Third GRD oops under live MPP tracing: one buffer import, an immediate fatal sync, and the fingerprint holds 3/3
- [`2026-07-27`](2026-07-27-grd-sg-corruption-reproduced-and-ioctl-capture-plan.md) — GRD system-heap oops reproduces 2/2 on production, and both corrupt pointers land 256 bytes below a 16 KiB boundary
- [`2026-07-27`](2026-07-27-grd-sg-corruption-kasan-non-reproduction.md) — The KASAN kernel does not reproduce the GRD system-heap oops, and is likely unable to
- [`2026-07-27`](2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md) — GRD's first RKMPP frame oopses on a corrupted system-heap scatterlist entry

### IEP2 deinterlacing (3)

The RK3588 deinterlacer: it exists, it is IEP2 not VDPP, and the 6.18 port omitted it.

- [`2026-08-04`](2026-08-04-iep2-field-parity-closed-and-i1o1-bff-bug.md) — IEP2 field parity settled: the mode suffix selects the field and `dil_order` does nothing, so MPP's hardcoded I1O1T is wrong for BFF streams
- [`2026-08-03`](2026-08-03-rk3588-iep2-nondeterministic-output.md) — RK3588 IEP2 runs clean under KASAN; its output non-determinism is a missing dma-buf cache sync in Rockchip's test harness, not the driver
- [`2026-08-02`](2026-08-02-rk3588-iep2-vdpp-source-audit.md) — RK3588 exposes IEP2 deinterlacing, not VDPP, and the YSP 6.18 port omits IEP2

### Mainline and maximum-mainline (6)

Where upstream already is, what it is missing, and where our port will collide with it.

- [`2026-08-02`](2026-08-02-vsi-iommu-mainline-convergence-and-resync-collision.md) — Mainline absorbed the VSI IOMMU driver and its RK3588 DT node in v7.2-rc1, and our forward port will collide with both
- [`2026-08-02`](2026-08-02-rk3588-maxline-proposal-refresh.md) — RK3588 maxline refreshed to current proposals, Linus master, and linux-next
- [`2026-08-02`](2026-08-02-mainline-tool-assisted-contribution-policy.md) — Mainline now has a written tool-assisted contribution policy, and its trailer is not the one this repo uses
- [`2026-08-02`](2026-08-02-mainline-codec-fix-series-self-review.md) — Three of the seven mainline codec-fix patches are defective
- [`2026-07-24`](2026-07-24-rknpu-forward-port-scoping.md) — RKNPU forward-port scoping: 8.6k lines, three hard spots, smaller than the MPP/RGA port
- [`2026-07-21`](2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md) — Mainline AV1/V4L2 vs VA-API, and why Firefox's only Rockchip hardware-decode route is VA-API

### GNOME Remote Desktop and RDP (12)

Hardware H.264 RDP encode end to end: encoder wedges, focus/resume, reconnect, and color.

- [`2026-08-04`](2026-08-04-grd-vaapi-encode-blocked-by-packed-slice-headers.md) — GRD has a native VA-API encoder and does not need FFmpeg — but it demands packed slice headers, which MPP cannot serve
- [`2026-08-01`](2026-08-01-grd-rdp-video-stall-transport-congestion.md) — GRD's fixed-QP encoder overruns the Tailscale RDP path, stalling video while audio continues
- [`2026-08-01`](2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md) — GRD hardware-encode recovery: forced IDR was implemented but unwired, and the detector could never see a hung encode
- [`2026-07-29`](2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md) — RDP reconnect after idle dies in the greeter→session handover, masquerading as the wake-watch wedge
- [`2026-07-29`](2026-07-29-rdp-black-screen-gsd-power-one-shot-wake-watch-wedge.md) — RDP session wedges black after idle lock: gsd-power's one-shot wake watch is unrecoverable
- [`2026-07-29`](2026-07-29-grd-fullrange-bt709-fixes-muted-colors.md) — Full-range BT.709 signaling fixes the muted GRD AVC colors after a clean reboot
- [`2026-07-28`](2026-07-28-grd-avc-fullrange-bt709-handover-boundary.md) — GRD AVC full-range BT.709 is package-verified; the live A/B stopped at handover
- [`2026-07-20`](2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md) — macOS focus return can wedge GRD in restored RDPGFX acknowledgement history
- [`2026-07-20`](2026-07-20-grd-focus-return-false-pipeline-starvation.md) — Focus return can falsely charge idle time as a GRD pipeline stall
- [`2026-07-19`](2026-07-19-grd-rkmpp-encoder-wedge-userspace-not-driver.md) — GRD's intermittent HW-encode wedge is userspace (rkmpp/ffmpeg), not the rkvenc2 driver
- [`2026-07-19`](2026-07-19-grd-rkmpp-encoder-wedge-mpp-input-backpressure.md) — GRD encoder wedge, pinned: MPP input-task backpressure + get_packet timeout (userspace flow control)
- [`2026-07-18`](2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md) — GRD's frame-starvation detector only warns — it never actuates recovery

### Desktop VA-API and browsers (21)

`rockchip-vaapi`: the bridge that makes Firefox, VLC, and mpv decode in hardware.

- [`2026-08-04`](2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md) — Enabling IEP2 broke interlaced VA-API decode by un-masking a driver defect: MPP's decoder deinterlacer is 1:N, VA-API decode is 1:1
- [`2026-08-04`](2026-08-04-rockchip-vaapi-capability-gap-triage.md) — rockchip-vaapi's remaining non-AV1 gaps split three ways: two are MPP walls, the size caps fail open below as well as closed above, and the sweep harness overwrites its own evidence
- [`2026-08-02`](2026-08-02-rockchip-vaapi-ysp9-rc-validation.md) — rockchip-vaapi ysp9 RC retires the VP9 quarantine and passes full sanitizer, RGA repeat, and package gates
- [`2026-08-02`](2026-08-02-rockchip-vaapi-ysp8-installed-runtime-validation.md) — rockchip-vaapi ysp8 is installed and green across decode, encode, GStreamer, VLC, mpv, and Firefox; one optional IEP2 probe is noisy
- [`2026-07-29`](2026-07-29-rockchip-vaapi-roadmap-phase2-phase4-closure.md) — rockchip-vaapi closes 10-bit throughput and the remaining Phase 4 qualification slices, while Firefox Main10 stops at Panfrost EGL import
- [`2026-07-28`](2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md) — rockchip-vaapi now measures green on the shipping stack, HEVC Main ships by default, and VLC and Firefox hardware-decode in a real session
- [`2026-07-28`](2026-07-28-vaapi-decode-readiness-and-remaining-work.md) — rockchip-vaapi decode is codec-complete except AV1; the remaining work is deployment, one confirmation run, promotion, and browser integration
- [`2026-07-26`](2026-07-26-vlc-headless-vaapi-device-boundary.md) — VLC headless playback cannot prove rockchip-vaapi hardware decode
- [`2026-07-26`](2026-07-26-rockchip-vaapi-webrtc-rtp-validation.md) — rockchip-vaapi H.264 reaches the WebRTC-compatible RTP boundary
- [`2026-07-26`](2026-07-26-rockchip-vaapi-planar-encode-upload-validation.md) — rockchip-vaapi planar VA uploads are normalized safely to MPP NV12
- [`2026-07-26`](2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md) — rockchip-vaapi 10-bit decode needs MPP AFBC plus crop metadata
- [`2026-07-26`](2026-07-26-rockchip-vaapi-hevc-va-encode-validation.md) — rockchip-vaapi HEVC VA encode requires the native RK3588 CTU64 contract
- [`2026-07-26`](2026-07-26-rockchip-vaapi-hevc-rps-and-p010-boundary.md) — rockchip-vaapi HEVC RPS boundary, with P010 fixed below it
- [`2026-07-26`](2026-07-26-rockchip-vaapi-h264-va-encode-validation.md) — rockchip-vaapi H.264 VA encode is interoperable through FFmpeg and GStreamer
- [`2026-07-26`](2026-07-26-rockchip-vaapi-dual-encode-soak-smoke.md) — rockchip-vaapi dual encode soak exposed HEVC visible/aligned geometry
- [`2026-07-26`](2026-07-26-rockchip-vaapi-drm-prime-rgb-encode-validation.md) — rockchip-vaapi imports linear RGB DMA-BUFs for checked RGA encode input
- [`2026-07-26`](2026-07-26-firefox-rdd-rockchip-vaapi-policy.md) — Firefox 152.0.6 RDD needs both Rockchip broker paths and ioctl requests
- [`2026-07-26`](2026-07-26-firefox-rdd-package-build-checkpoint.md) — Firefox 152.0.6 Rockchip RDD package build is configured but paused
- [`2026-07-21`](2026-07-21-vaapi-mpp-bitstream-reconstruction-av1.md) — Why AV1 is hard for the VA-API↔MPP bridge (and H.264/HEVC/VP9 are not): the bitstream-reconstruction spectrum
- [`2026-07-21`](2026-07-21-ubuntu-rockchip-piggyback-survey.md) — ubuntu-rockchip (Joshua Riek) survey: a working Chromium V4L2-stateful-over-MPP bridge exists, the project is archived, and per-app reuse is now mapped
- [`2026-07-21`](2026-07-21-rockchip-vaapi-driver-review.md) — rockchip-vaapi review: a working PoC VA-API-over-MPP driver exists; strategic architecture is right, two load-bearing shortcuts must be replaced; recommend fork-and-renovate

### FFmpeg, MPP userspace, and Kodi (5)

The userspace codec libraries and the media applications that consume them.

- [`2026-07-30`](2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md) — FFmpeg RKMPP async-frame lifetime fix clears reset/close double release
- [`2026-07-29`](2026-07-29-hevc-nut-radl-and-unused-rps-reference-fixes.md) — HEVC NUT failures split into MPP RADL suppression and FFmpeg unused-RPS handling
- [`2026-07-27`](2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md) — Rockchip MPP HEVC TILES failure: same-ID PPS changes never reach the HAL
- [`2026-07-11`](2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md) — Kodi 22 hardware video on RK3588 via ffmpeg-rockchip-81: MPP runtime, three fork-packaging bugs, and zero-patch decoder selection
- [`2026-07-09`](2026-07-09-ffmpeg-baseline-rk2-local-build-validation.md) — FFmpeg baseline `-1+rk2` local source-package build validates frei0r fix

### Mesa, Panfrost, and the Mali blob (8)

Mali-G610 transfer and interpolation work behind the GRD readback path.

- [`2026-07-28`](2026-07-28-mesa-blit-benchmark-timing-boundary.md) — Mesa single-context benchmark resolves MR !43161 workaround cost
- [`2026-07-27`](2026-07-27-mesa-all-blit-workaround-benchmark-results.md) — Mesa all-blit workaround benchmark validates correctness but not per-blit cost
- [`2026-07-27`](2026-07-27-mali-blit-workaround-performance-benchmark-plan.md) — Plan for measuring per-blit cost of the Mali workaround
- [`2026-07-24`](2026-07-24-mali-oblong-triangle-matrix.md) — Mali oblong-triangle matrix for MR !43161
- [`2026-07-24`](2026-07-24-mali-blit-workaround-size-results.md) — Mali blit workaround size results for Mesa MR !43161
- [`2026-07-22`](2026-07-22-mali-varying-depth-bias-erratum-workaround.md) — Mali-G610 varying erratum: zero-valued depth bias repairs GL, Vulkan, and ordinary TEX
- [`2026-07-18`](2026-07-18-mesa-panfrost-uncached-readpixels-convert-cliff.md) — Mesa/panfrost: glReadPixels convert fallback is catastrophic over uncached imported buffers
- [`2026-07-08`](2026-07-08-blit-precision-nir-migration.md) — Blit-precision fix: the TGSI→NIR migration and doing it with pixel_coord

### Build, packaging, and provenance (8)

How an artifact was actually built — and the times that turned out to be the bug.

- [`2026-08-04`](2026-08-04-forward-port-sd-rescue-rollback-used.md) — Forward-port kernel rollback has been performed through an SD rescue boot
- [`2026-08-01`](2026-08-01-stock-ubuntu-rock5b-successor-architecture.md) — A ROCK 5B-only Ubuntu successor should keep Resolute userspace stock and own the board kernel and firmware
- [`2026-07-29`](2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md) — The production 6.18.40 `20260725` orig is a rewrite-composite worktree snapshot, not the validated forward-port series
- [`2026-07-28`](2026-07-28-production-kernel-debug-option-audit.md) — Production kernel debug audit: four options above Armbian stock, and a 256 MiB debug allocation arriving from the shared boot environment
- [`2026-07-27`](2026-07-27-rewrite-kasan-fixed-source-package.md) — Fixed-source rewrite KASAN package is built and package-verified
- [`2026-07-27`](2026-07-27-kasan-vs-production-build-provenance-confound.md) — The KASAN non-reproduction is confounded by toolchain: production is a Launchpad gcc-15.2 build, the KASAN kernel is a local gcc-13.3 build
- [`2026-07-25`](2026-07-25-armbian-linuxfamily-rename-silent-patch-free-kernel.md) — One Armbian variable, `LINUXFAMILY`, silently built a patch-free kernel and threw away the whole kernel ccache
- [`2026-07-08`](2026-07-08-armbian-builder-setup.md) — ROCK 5B Armbian builder: native host, branch/release map, and remote-cache behavior

<!-- findings-topics:end -->

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
- [`2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md`](2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md) — Enabling IEP2 broke interlaced VA-API decode by un-masking a driver defect: MPP's decoder deinterlacer is 1:N, VA-API decode is 1:1
- [`2026-08-04-rockchip-vaapi-capability-gap-triage.md`](2026-08-04-rockchip-vaapi-capability-gap-triage.md) — rockchip-vaapi's remaining non-AV1 gaps split three ways: two are MPP walls, the size caps fail open below as well as closed above, and the sweep harness overwrites its own evidence
- [`2026-08-04-rkvenc-encoder-rcb-sram-scope.md`](2026-08-04-rkvenc-encoder-rcb-sram-scope.md) — RK3588 encoder RCB is reachable only by >4096-wide H.264, so the absent encoder SRAM costs almost nothing
- [`2026-08-04-rewrite-kunit-request-rotation-repair.md`](2026-08-04-rewrite-kunit-request-rotation-repair.md) — Current rewrite tips repair request cleanup and rotation KUnit contracts
- [`2026-08-04-iep2-field-parity-closed-and-i1o1-bff-bug.md`](2026-08-04-iep2-field-parity-closed-and-i1o1-bff-bug.md) — IEP2 field parity settled: the mode suffix selects the field and `dil_order` does nothing, so MPP's hardcoded I1O1T is wrong for BFF streams
- [`2026-08-04-grd-vaapi-encode-blocked-by-packed-slice-headers.md`](2026-08-04-grd-vaapi-encode-blocked-by-packed-slice-headers.md) — GRD has a native VA-API encoder and does not need FFmpeg — but it demands packed slice headers, which MPP cannot serve
- [`2026-08-04-forward-port-sd-rescue-rollback-used.md`](2026-08-04-forward-port-sd-rescue-rollback-used.md) — Forward-port kernel rollback has been performed through an SD rescue boot
- [`2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md`](2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md) — Forward-port 0090–0092 close the RGA job-task and decoder recovery lifetime gaps
- [`2026-08-03-rk3588-iep2-nondeterministic-output.md`](2026-08-03-rk3588-iep2-nondeterministic-output.md) — RK3588 IEP2 runs clean under KASAN; its output non-determinism is a missing dma-buf cache sync in Rockchip's test harness, not the driver
- [`2026-08-03-rewrite-rga-unreachable-iommu-irq-mask.md`](2026-08-03-rewrite-rga-unreachable-iommu-irq-mask.md) — The RGA rewrite's IOMMU-IRQ-mask fallback was unreachable, and it blocked the mainline mirror
- [`2026-08-03-mainline-missing-uncached-dma32-heaps.md`](2026-08-03-mainline-missing-uncached-dma32-heaps.md) — Mainline lacks the BSP uncached/dma32 dma-heaps; MPP absorbs it, librga samples do not
- [`2026-08-02-vsi-iommu-mainline-convergence-and-resync-collision.md`](2026-08-02-vsi-iommu-mainline-convergence-and-resync-collision.md) — Mainline absorbed the VSI IOMMU driver and its RK3588 DT node in v7.2-rc1, and our forward port will collide with both
- [`2026-08-02-rockchip-vaapi-ysp9-rc-validation.md`](2026-08-02-rockchip-vaapi-ysp9-rc-validation.md) — rockchip-vaapi ysp9 RC retires the VP9 quarantine and passes full sanitizer, RGA repeat, and package gates
- [`2026-08-02-rockchip-vaapi-ysp8-installed-runtime-validation.md`](2026-08-02-rockchip-vaapi-ysp8-installed-runtime-validation.md) — rockchip-vaapi ysp8 is installed and green across decode, encode, GStreamer, VLC, mpv, and Firefox; one optional IEP2 probe is noisy
- [`2026-08-02-rk3588-maxline-proposal-refresh.md`](2026-08-02-rk3588-maxline-proposal-refresh.md) — RK3588 maxline refreshed to current proposals, Linus master, and linux-next
- [`2026-08-02-rk3588-iep2-vdpp-source-audit.md`](2026-08-02-rk3588-iep2-vdpp-source-audit.md) — RK3588 exposes IEP2 deinterlacing, not VDPP, and the YSP 6.18 port omits IEP2
- [`2026-08-02-rga3-forward-port-small-geometry-discriminator.md`](2026-08-02-rga3-forward-port-small-geometry-discriminator.md) — Forward-port RGA3 passes the repeated small-geometry AFBC-to-P010 dropped-write discriminator
- [`2026-08-02-mainline-tool-assisted-contribution-policy.md`](2026-08-02-mainline-tool-assisted-contribution-policy.md) — Mainline now has a written tool-assisted contribution policy, and its trailer is not the one this repo uses
- [`2026-08-02-mainline-codec-fix-series-self-review.md`](2026-08-02-mainline-codec-fix-series-self-review.md) — Three of the seven mainline codec-fix patches are defective
- [`2026-08-02-librga-handle-plane-placeholder.md`](2026-08-02-librga-handle-plane-placeholder.md) — librga handle requests use uv_addr—not v_addr—as the separate-plane discriminator
- [`2026-08-02-driver-probe-error-path-test-design.md`](2026-08-02-driver-probe-error-path-test-design.md) — Probe error paths are testable by DT alone, but -ENXIO and -ENODEV probe failures are silent by default
- [`2026-08-01-stock-ubuntu-rock5b-successor-architecture.md`](2026-08-01-stock-ubuntu-rock5b-successor-architecture.md) — A ROCK 5B-only Ubuntu successor should keep Resolute userspace stock and own the board kernel and firmware
- [`2026-08-01-rkvdec-self-reset-and-iommu-restore-gaps.md`](2026-08-01-rkvdec-self-reset-and-iommu-restore-gaps.md) — The rkvdec2 hardware self-resets on error; the rewrite driver neither detects it nor restores the IOMMU
- [`2026-08-01-rewrite-soft-ccu-cross-core-reset-wedge.md`](2026-08-01-rewrite-soft-ccu-cross-core-reset-wedge.md) — Soft-CCU bus-stall wedge returns on the error-reset path; needs two cores of one group resetting
- [`2026-08-01-rewrite-kunit-boot-failures-and-suite-audit.md`](2026-08-01-rewrite-kunit-boot-failures-and-suite-audit.md) — The two RGA KUnit boot failures were fixture lag; a full-suite audit tightened three more cases and pruned three
- [`2026-08-01-rewrite-driver-review-round-3.md`](2026-08-01-rewrite-driver-review-round-3.md) — Rewrite-driver review round 3: 11 defects, 8 of them holes in fixes already recorded as closed
- [`2026-08-01-rewrite-driver-retrospective.md`](2026-08-01-rewrite-driver-retrospective.md) — Rewrite-driver retrospective: keep the ownership model, change the architecture and qualification order
- [`2026-08-01-grd-rdp-video-stall-transport-congestion.md`](2026-08-01-grd-rdp-video-stall-transport-congestion.md) — GRD's fixed-QP encoder overruns the Tailscale RDP path, stalling video while audio continues
- [`2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md`](2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md) — GRD hardware-encode recovery: forced IDR was implemented but unwired, and the detector could never see a hung encode
- [`2026-08-01-forward-port-uaf-oops-audit-round-2.md`](2026-08-01-forward-port-uaf-oops-audit-round-2.md) — Forward-port UAF/oops audit round 2: 18 defects, 7 of them unprivileged memory corruption
- [`2026-08-01-armbian-rockchip64-defaults-tcp-reno.md`](2026-08-01-armbian-rockchip64-defaults-tcp-reno.md) — Armbian's rockchip64 kernel configs default TCP congestion control to reno
- [`2026-07-31-rkvdec-sibling-reset-deassert-race.md`](2026-07-31-rkvdec-sibling-reset-deassert-race.md) — rkvdec soft-CCU sibling power-on can cancel a peer core's recovery reset
- [`2026-07-31-rga3-afbc-p010-dropped-destination-write.md`](2026-07-31-rga3-afbc-p010-dropped-destination-write.md) — RGA3 AFBC NV15→P010 returns success without writing the destination at small picture sizes
- [`2026-07-31-rga-userptr-dmabuf-multisegment-contracts.md`](2026-07-31-rga-userptr-dmabuf-multisegment-contracts.md) — RGA multi-segment memory contract: the BSP relies on 5.10/6.1 IOMMU coalescing; newer drivers validate or remap
- [`2026-07-31-rga-rewrite-multisg-dmabuf-cma-einval.md`](2026-07-31-rga-rewrite-multisg-dmabuf-cma-einval.md) — RGA rewrite rejects legal multi-SG DMA-BUFs; the CMA `EINVAL` is a separate untraced failure
- [`2026-07-31-rewrite-soft-ccu-iotlb-closes-vaapi-main10-packetized-failure.md`](2026-07-31-rewrite-soft-ccu-iotlb-closes-vaapi-main10-packetized-failure.md) — The soft-CCU IOTLB flush closed the VA-API Main10 packetized decode failure
- [`2026-07-30-rewrite-soft-ccu-split-critical-section-h265-wedge.md`](2026-07-30-rewrite-soft-ccu-split-critical-section-h265-wedge.md) — Soft-CCU wedge survived the arm/start fix: the critical section was still split; whole-sequence lock applied
- [`2026-07-30-rewrite-rkvenc-dchs-producer-retirement-race.md`](2026-07-30-rewrite-rkvenc-dchs-producer-retirement-race.md) — RKVENC DCHS producer retirement raced a dependent consumer's START; lifecycle serialization applied
- [`2026-07-30-rewrite-kunit-gate-false-red-harness-defects.md`](2026-07-30-rewrite-kunit-gate-false-red-harness-defects.md) — First fully green rewrite KUnit boot failed the gate: four harness defects, zero kernel defects
- [`2026-07-30-rewrite-av1-vsi-fault-afbc-lifecycle-races.md`](2026-07-30-rewrite-av1-vsi-fault-afbc-lifecycle-races.md) — Rewrite AV1/VSI audit closes fault-admission and teardown races; AFBC retirement proof remains a hardware gate
- [`2026-07-30-mainline-maxline-rockchip-codec-source-audit.md`](2026-07-30-mainline-maxline-rockchip-codec-source-audit.md) — Current mainline and maxline Rockchip codec audit found transferable ownership, DMA, and recovery defects
- [`2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md`](2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md) — FFmpeg RKMPP async-frame lifetime fix clears reset/close double release
- [`2026-07-30-boot-failure-retro-prevention-levers.md`](2026-07-30-boot-failure-retro-prevention-levers.md) — Wedge-week retrospective: what would have caught each failure class before boot
- [`2026-07-29-rockchip-vaapi-roadmap-phase2-phase4-closure.md`](2026-07-29-rockchip-vaapi-roadmap-phase2-phase4-closure.md) — rockchip-vaapi closes 10-bit throughput and the remaining Phase 4 qualification slices, while Firefox Main10 stops at Panfrost EGL import
- [`2026-07-29-rockchip-vaapi-direct-av1-mpp-service-design.md`](2026-07-29-rockchip-vaapi-direct-av1-mpp-service-design.md) — A direct `/dev/mpp_service` AV1 backend can bypass libmpp by owning a surface-keyed VDPU job compiler
- [`2026-07-29-rga-no-core-match-narrow-afbc-10bit.md`](2026-07-29-rga-no-core-match-narrow-afbc-10bit.md) — A narrow AFBC 10-bit frame has no RGA core: RGA3 needs width ≥ 68 and RGA2 cannot read AFBC
- [`2026-07-29-rewrite-soft-ccu-dual-core-wedge.md`](2026-07-29-rewrite-soft-ccu-dual-core-wedge.md) — Rewrite soft-CCU dual-core decode wedges the interconnect; arm/start split root-caused and fixed
- [`2026-07-29-rewrite-kunit-fixture-audit.md`](2026-07-29-rewrite-kunit-fixture-audit.md) — Rewrite KUnit fixture audit: 2 boot oopses fixed, full 232-case sweep, latent hazard inventory
- [`2026-07-29-rewrite-driver-review-round-2.md`](2026-07-29-rewrite-driver-review-round-2.md) — Rewrite-driver review round 2: 12 confirmed defects fixed, 4 items ledgered
- [`2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md`](2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md) — RDP reconnect after idle dies in the greeter→session handover, masquerading as the wake-watch wedge
- [`2026-07-29-rdp-black-screen-gsd-power-one-shot-wake-watch-wedge.md`](2026-07-29-rdp-black-screen-gsd-power-one-shot-wake-watch-wedge.md) — RDP session wedges black after idle lock: gsd-power's one-shot wake watch is unrecoverable
- [`2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md`](2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md) — The production 6.18.40 `20260725` orig is a rewrite-composite worktree snapshot, not the validated forward-port series
- [`2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md`](2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md) — MPP job-ISR IOMMU fault-handler clear takes sleeping locks and panicked the idle task
- [`2026-07-29-hevc-nut-radl-and-unused-rps-reference-fixes.md`](2026-07-29-hevc-nut-radl-and-unused-rps-reference-fixes.md) — HEVC NUT failures split into MPP RADL suppression and FFmpeg unused-RPS handling
- [`2026-07-29-grd-fullrange-bt709-fixes-muted-colors.md`](2026-07-29-grd-fullrange-bt709-fixes-muted-colors.md) — Full-range BT.709 signaling fixes the muted GRD AVC colors after a clean reboot
- [`2026-07-29-forward-port-warn-oops-audit-and-fixes.md`](2026-07-29-forward-port-warn-oops-audit-and-fixes.md) — Forward-port MPP/RGA WARN/oops audit: 18 defects found and fixed
- [`2026-07-29-av1-rewrite-branch-hardening-gap-and-backport.md`](2026-07-29-av1-rewrite-branch-hardening-gap-and-backport.md) — rk3588-rewrite-av1-6.18 forked before 19 hardening commits; KUnit isolation and the ISR fault-handler panic fix are absent
- [`2026-07-29-av1-rewrite-backend-design-source-audit.md`](2026-07-29-av1-rewrite-backend-design-source-audit.md) — AV1 rewrite backend: three-region sparse ABI on the mpp-rewrite core with a kernel-owned AFBC block
- [`2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md`](2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md) — rockchip-vaapi now measures green on the shipping stack, HEVC Main ships by default, and VLC and Firefox hardware-decode in a real session
- [`2026-07-28-vaapi-decode-readiness-and-remaining-work.md`](2026-07-28-vaapi-decode-readiness-and-remaining-work.md) — rockchip-vaapi decode is codec-complete except AV1; the remaining work is deployment, one confirmation run, promotion, and browser integration
- [`2026-07-28-rkvdec2-err23-picsize-oversize-width.md`](2026-07-28-rkvdec2-err23-picsize-oversize-width.md) — rkvdec2 `err 0x23`: an 8192-sample width inflection, BSP watchdog constants whose names are wrong, and VA-API caps that are wrong in both directions
- [`2026-07-28-rewrite-kunit-pre-phase-applied.md`](2026-07-28-rewrite-kunit-pre-phase-applied.md) — Rewrite KUnit pre-phase is applied with an 84/148 gate
- [`2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md`](2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md) — Ramoops retention works on the 6.18.40-era kernels — the all-zero failure was kernel-generation-scoped, not firmware-scoped
- [`2026-07-28-production-kernel-debug-option-audit.md`](2026-07-28-production-kernel-debug-option-audit.md) — Production kernel debug audit: four options above Armbian stock, and a 256 MiB debug allocation arriving from the shared boot environment
- [`2026-07-28-mesa-blit-benchmark-timing-boundary.md`](2026-07-28-mesa-blit-benchmark-timing-boundary.md) — Mesa single-context benchmark resolves MR !43161 workaround cost
- [`2026-07-28-grd-avc-fullrange-bt709-handover-boundary.md`](2026-07-28-grd-avc-fullrange-bt709-handover-boundary.md) — GRD AVC full-range BT.709 is package-verified; the live A/B stopped at handover
- [`2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md`](2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md) — The DMABUF_DEBUG scatterlist defect is 100% upstream code, reported since 2022, and blocked on an unresolved dma-buf design argument
- [`2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md`](2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md) — CONFIG_DMABUF_DEBUG's mangle_sg_table() is the system-heap page_link writer, and the dma-heap CPU-access sync dereferences it
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
- [`2026-07-27-kasan-vs-production-build-provenance-confound.md`](2026-07-27-kasan-vs-production-build-provenance-confound.md) — The KASAN non-reproduction is confounded by toolchain: production is a Launchpad gcc-15.2 build, the KASAN kernel is a local gcc-13.3 build
- [`2026-07-27-grd-sg-writer-source-sweep-vendor-drivers-cleared.md`](2026-07-27-grd-sg-writer-source-sweep-vendor-drivers-cleared.md) — Source sweep clears the vendor MPP driver of the GRD scatterlist write, and corrects three readings of the corrupt value
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
