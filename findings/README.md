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

A finding is raw by default. When it matures, promote its useful identity,
method, signal, trust classification, boundary, and reconstruction route into
the existing project explanation, runbook/test contract, patch catalog,
package document, audit, or status owner that fits. Repoint every maintained
inbound link, remove the finding, and regenerate both inbox views in the same
change. Do not leave a tombstone or preserve routine work chronology; Git
history already supplies forensic recovery.

Delete an obsolete or falsified finding only after confirming that no
maintained claim still depends on its unique negative result. If the negative
result remains a useful discriminator, promote that minimum evidence before
removal.

Small text artifacts that materially improve active reproduction may live
under the [`evidence/` hub](evidence/README.md). The bundle README records
capture scope; at least one live finding owns interpretation and trust. When
the last owning finding leaves the inbox, move still-useful artifacts to that
finding's durable project owner or remove the bundle in the same change.

**Boundary vs [`status.md`](../status.md) watchlist:** the watchlist tracks
*facts that go stale silently* (external PRs, distro versions, dev-box SPOFs).
`findings/` holds *newly-learned technical detail*. A finding with a follow-up
action belongs here; a stale-risk to re-check on every maintenance pass belongs
in the watchlist.

## Reconstruct an investigation

The live inbox is not repository history and does not maintain curated
investigation trails. Re-enter a subject through its project README or
[`docs/work-packages.md`](../docs/work-packages.md), read the maintained model
and evidence boundary, then consult Git history only when the evolution itself
matters. Current public verdicts and next proofs always come from
[`status.md`](../status.md), not from the age or ordering of findings.

The generated chronology below is a deposit view for still-live intake. Once a
finding is promoted or discarded, it disappears from both views; its durable
knowledge remains at the named owner and its old text remains recoverable from
Git.

## Browse by subsystem

The generated chronology below answers *what entered the live inbox when*.
This index groups the same live findings by subsystem, newest first. Promoted,
discarded, and obsolete files appear in neither view.

Coverage is mechanically enforced — `scripts/check-doc-consistency.py` fails if
a live finding is missing from these groups, appears in two, or names a file
that does not exist. When you add a finding, add its row here too.

<!-- findings-topics:start -->

### Boot chain, U-Boot, and firmware (8)

Power-on to Linux handoff: SPI/SD boot, FIT/DTB artifacts, and the vendor-vs-Armbian firmware gap.

- [`2026-08-06`](2026-08-06-armbian-rock5b-u-boot-console-options.md) — Armbian ROCK 5B vendor U-Boot disables its only interactive console
- [`2026-07-24`](2026-07-24-rock5b-spi-vs-radxa-bsp-firmware-generation-gap.md) — The installed SPI is not U-Boot-incompatible with Radxa BSP images; the real gap is the firmware blob generation
- [`2026-07-20`](2026-07-20-armbian-radxa-image-fit-audit.md) — Armbian Radxa catalog: 21 zero-DTB images, 207 clean, 95 not applicable
- [`2026-07-20`](2026-07-20-armbian-non-radxa-radxa-uboot-audit.md) — Non-Radxa Radxa-U-Boot catalog: 17 zero-DTB images, 182 clean, 4 unavailable
- [`2026-07-13`](2026-07-13-rock5b-u-boot-fit-dtb-race.md) — ROCK 5B zero-DTB race: controlled proof, Noble `cp`, and KSpace amplification
- [`2026-07-09`](2026-07-09-rock5b-armbian-sd-boot-investigation.md) — ROCK 5B Armbian SD boot investigation summary
- [`2026-07-08`](2026-07-08-armbian-26.2.1-bl31-handoff-hang.md) — Armbian 26.2.1 ROCK 5B raw bootloader hangs after BL31 handoff
- [`2026-07-07`](2026-07-07-rock5b-spi-sd-boot-chain.md) — ROCK 5B SPI U-Boot changes how Radxa SD images boot

### Ramoops and crash retention (1)

Whether a crash record survives reset — and the four audits that relocated the cause.

- [`2026-07-28`](2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md) — Ramoops retention works on the 6.18.40-era kernels — the all-zero failure was kernel-generation-scoped, not firmware-scoped

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

### Kernel forward port: MPP and codec drivers (21)

Vendor MPP/rkvenc/rkvdec forward-ported to 6.18 — defects, audits, and whole-tip validation runs.

- [`2026-08-08`](2026-08-08-forward-port-rga-mpp-ownership-audit-fixes.md) — Forward-port 0095–0096 close RGA/MPP ownership and fault-admission gaps
- [`2026-08-04`](2026-08-04-forward-port-6-18-42-0092-production-validation.md) — Forward-port 6.18.42 production validation boots 0092 and closes the functional recovery gates
- [`2026-08-04`](2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md) — Forward-port 0090–0092 close the RGA job-task and decoder recovery lifetime gaps
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

### Kernel RGA: memory contracts and 10-bit ABI (19)

The `/dev/rga` driver — session lifetime, userptr/dma-buf imports, and the 10-bit stride convention.

- [`2026-08-08`](2026-08-08-forward-port-rga2-dmabuf-staging.md) — Forward port stages exporter-owned high DMA-BUFs for RGA2-only work
- [`2026-08-08`](2026-08-08-forward-port-rga2-userptr-swiotlb-segments.md) — Forward-port 6.18.43 conformance isolates oversized RGA2 USERPTR SWIOTLB segments
- [`2026-08-06`](2026-08-06-librga-palette-demo-is-not-kernel-conformance.md) — librga's palette demo does not provide a kernel conformance signal
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

### Clean-room rewrite drivers (43)

The from-scratch MPP/RGA replacement: reviews, soft-CCU wedges, and reset/lifecycle races.

- [`2026-08-09`](2026-08-09-rewrite-phase-3a-mpp-activation-identity.md) — Rewrite Phase 3A embeds MPP current-attempt identity
- [`2026-08-09`](2026-08-09-rewrite-phase-3b-mpp-dispatch-owner.md) — Rewrite Phase 3B binds RKVDEC dispatch to exact activation storage
- [`2026-08-09`](2026-08-09-rewrite-phase-3c-mpp-selected-hardware.md) — Rewrite Phase 3C: activation-owned selected hardware
- [`2026-08-08`](2026-08-08-rewrite-phase-2-irq-register-epoch-lease.md) — Rewrite Phase 2 leases hard IRQ status to the live register epoch
- [`2026-08-08`](2026-08-08-rewrite-phase-2-hard-ccu-dma-recovery.md) — Rewrite Phase 2 types hard-CCU DMA-group recovery
- [`2026-08-08`](2026-08-08-rewrite-phase-2-single-core-recovery-result.md) — Rewrite Phase 2 types single-core reset and DMA recovery
- [`2026-08-08`](2026-08-08-rewrite-phase-2-cluster-ccu-ownership.md) — Rewrite Phase 2 makes the cluster the CCU list and publication owner
- [`2026-08-08`](2026-08-08-rewrite-phase-2-reset-domain-construction.md) — Rewrite Phase 2 constructs stable reset domains without claiming group recovery
- [`2026-08-08`](2026-08-08-rewrite-phase-2-cluster-construction.md) — Rewrite Phase 2 constructs a shadow CCU cluster without changing admission
- [`2026-08-08`](2026-08-08-rewrite-phase-2-hard-ccu-reset-ownership.md) — Rewrite Phase 2 makes the hard-CCU pulse one cluster-validated reset epoch
- [`2026-08-08`](2026-08-08-rewrite-phase-2-cluster-power-lease.md) — Rewrite Phase 2 replaces the hard-CCU powered-core array with a cluster lease
- [`2026-08-08`](2026-08-08-rewrite-phase-1-focused-build-gate.md) — Rewrite Phase 1 exact tips pass the full build matrix and 6.18 packaging
- [`2026-08-08`](2026-08-08-rewrite-rga2-dmabuf-staging-design.md) — Rewrite RGA2 DMA-BUF staging design for exporter SG entries larger than SWIOTLB
- [`2026-08-08`](2026-08-08-rga3-cross-process-contention-harness-plan.md) — Plan: a dedicated RGA3 cross-process contention harness that provokes and honestly detects the silent vpp corruption
- [`2026-08-07`](2026-08-07-rga3-cross-process-vpp-corruption-lead.md) — RGA3 vpp_rkrga output corruption — first seen cross-process, now reproduced solo; not root-caused
- [`2026-08-07`](2026-08-07-rewrite-rga-blend-chain-swiotlb-and-rga3-iommu-fault.md) — Rewrite RGA cannot run a valid overlay blend chain: RGA2 SWIOTLB segment limit and a deterministic RGA3 IOMMU fault
- [`2026-08-07`](2026-08-07-rewrite-rkvdec-drm-prime-duplicate-frame-regression.md) — Rewrite rkvdec zero-copy decode duplicates frames after the #8 scheduler/completion fixes
- [`2026-08-07`](2026-08-07-rewrite-mpp-same-session-dual-core-dispatch-race.md) — Rewrite MPP scheduler races same-session frames across both rkvdec cores; ordering + CCU-conformance fix committed
- [`2026-08-06`](2026-08-06-rewrite-rga-userptr-map-before-power-iommu-fault.md) — Rewrite RGA USERPTR imports mapped before core power and left a stale IOTLB entry
- [`2026-08-06`](2026-08-06-mpp-rewrite-missing-supports-device-proc.md) — MPP rewrite omitted the BSP `supports-device` proc inventory
- [`2026-08-06`](2026-08-06-rga-rop-identity-transform-gate.md) — RGA rewrite's ROP gate mistook librga's identity cosine for rotation
- [`2026-08-05`](2026-08-05-rewrite-rga2-dmabuf-userptr-bounce-followup.md) — RGA2 bounce follow-up: reroute incompatible DMA-BUFs and preserve USERPTR page offsets
- [`2026-08-05`](2026-08-05-rewrite-rga-librga-swiotlb-fence-status.md) — Rewrite RGA librga failures: SWIOTLB segments, fd-zero fences, and sample status
- [`2026-08-04`](2026-08-04-rewrite-kernel-rebase-6-18-42-7-2-rc6.md) — Rewrite kernels rebased cleanly onto v6.18.42 and v7.2-rc6
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

### Rewrite KUnit qualification (13)

The in-kernel test suite that gates the rewrite — mostly a record of fixture defects, not driver defects.

- [`2026-08-05`](2026-08-05-rewrite-kunit-fd-zero-boot-wedge.md) — A legacy fd-zero fence sentinel wedged the boot inside KUnit
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

### IEP2 deinterlacing (2)

The RK3588 deinterlacer: IEP2 rather than VDPP, including runtime behavior and
userspace field selection.

- [`2026-08-04`](2026-08-04-iep2-field-parity-closed-and-i1o1-bff-bug.md) — IEP2 field parity settled: the mode suffix selects the field and `dil_order` does nothing, so MPP's hardcoded I1O1T is wrong for BFF streams
- [`2026-08-03`](2026-08-03-rk3588-iep2-nondeterministic-output.md) — RK3588 IEP2 runs clean under KASAN; its output non-determinism is a missing dma-buf cache sync in Rockchip's test harness, not the driver

### Mainline and maximum-mainline (6)

Where upstream already is, what it is missing, and where our port will collide with it.

- [`2026-08-02`](2026-08-02-vsi-iommu-mainline-convergence-and-resync-collision.md) — Mainline absorbed the VSI IOMMU driver and its RK3588 DT node in v7.2-rc1, and our forward port will collide with both
- [`2026-08-02`](2026-08-02-rk3588-maxline-proposal-refresh.md) — RK3588 maxline refreshed to current proposals, Linus master, and linux-next
- [`2026-08-02`](2026-08-02-mainline-tool-assisted-contribution-policy.md) — Mainline now has a written tool-assisted contribution policy, and its trailer is not the one this repo uses
- [`2026-08-02`](2026-08-02-mainline-codec-fix-series-self-review.md) — Three of the seven mainline codec-fix patches are defective
- [`2026-07-24`](2026-07-24-rknpu-forward-port-scoping.md) — RKNPU forward-port scoping: 8.6k lines, three hard spots, smaller than the MPP/RGA port
- [`2026-07-21`](2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md) — Mainline AV1/V4L2 vs VA-API, and why Firefox's only Rockchip hardware-decode route is VA-API

### GNOME Remote Desktop and RDP (2)

Hardware H.264 RDP encode end to end: encoder wedges, focus/resume, reconnect, and color.

- [`2026-08-01`](2026-08-01-grd-hw-encode-watchdog-forced-idr-bitrate-ceiling.md) — GRD hardware-encode recovery: forced IDR was implemented but unwired, and the detector could never see a hung encode
- [`2026-07-29`](2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md) — RDP reconnect after idle dies in the greeter→session handover, masquerading as the wake-watch wedge

### Desktop VA-API and browsers (2)

`rockchip-vaapi`: the bridge that serves Firefox, standard GStreamer and
libavcodec VA-API consumers without per-application RKMPP codec patches.

- [`2026-08-04`](2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md) — Google Chrome reaches rockchip-vaapi; green H.264 was a retained pre-decode DMA-BUF, and the source fix preserves that storage
- [`2026-08-04`](2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md) — Enabling IEP2 broke interlaced VA-API decode by un-masking a driver defect: MPP's decoder deinterlacer is 1:N, VA-API decode is 1:1

### FFmpeg, MPP userspace, and Kodi (3)

The userspace codec libraries and the media applications that consume them.

- [`2026-08-07`](2026-08-07-ffmpeg-rkrga-failures-are-latent-pts-and-checker-defects.md) — FFmpeg rkrga conformance failures are latent PTS and checker defects exposed by suite strictness; kernel #8 exonerated
- [`2026-08-06`](2026-08-06-rewrite-kasan-media-suite-userspace-fixes-and-intermittent-h264.md) — Rewrite KASAN media rerun fixes two GStreamer userspace gaps but exposes intermittent H.26x decode output
- [`2026-07-30`](2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md) — FFmpeg RKMPP async-frame lifetime fix clears reset/close double release

### Build, packaging, and provenance (9)

How an artifact was actually built — and the times that turned out to be the bug.

- [`2026-08-08`](2026-08-08-forward-port-boot-dtb-symlink-mismatch.md) — Forward-port kernel booted the mainline DTB: `/boot/dtb` and `/boot/Image` split across co-installed branches
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
- [`2026-08-09-rewrite-phase-3c-mpp-selected-hardware.md`](2026-08-09-rewrite-phase-3c-mpp-selected-hardware.md) — Rewrite Phase 3C: activation-owned selected hardware
- [`2026-08-09-rewrite-phase-3b-mpp-dispatch-owner.md`](2026-08-09-rewrite-phase-3b-mpp-dispatch-owner.md) — Rewrite Phase 3B binds RKVDEC dispatch to exact activation storage
- [`2026-08-09-rewrite-phase-3a-mpp-activation-identity.md`](2026-08-09-rewrite-phase-3a-mpp-activation-identity.md) — Rewrite Phase 3A embeds MPP current-attempt identity
- [`2026-08-08-rga3-cross-process-contention-harness-plan.md`](2026-08-08-rga3-cross-process-contention-harness-plan.md) — Plan: a dedicated RGA3 cross-process contention harness that provokes and honestly detects the silent vpp corruption
- [`2026-08-08-rewrite-rga2-dmabuf-staging-design.md`](2026-08-08-rewrite-rga2-dmabuf-staging-design.md) — Rewrite RGA2 DMA-BUF staging design for exporter SG entries larger than SWIOTLB
- [`2026-08-08-rewrite-phase-2-single-core-recovery-result.md`](2026-08-08-rewrite-phase-2-single-core-recovery-result.md) — Rewrite Phase 2 types single-core reset and DMA recovery
- [`2026-08-08-rewrite-phase-2-reset-domain-construction.md`](2026-08-08-rewrite-phase-2-reset-domain-construction.md) — Rewrite Phase 2 constructs stable reset domains without claiming group recovery
- [`2026-08-08-rewrite-phase-2-irq-register-epoch-lease.md`](2026-08-08-rewrite-phase-2-irq-register-epoch-lease.md) — Rewrite Phase 2 leases hard IRQ status to the live register epoch
- [`2026-08-08-rewrite-phase-2-hard-ccu-reset-ownership.md`](2026-08-08-rewrite-phase-2-hard-ccu-reset-ownership.md) — Rewrite Phase 2 makes the hard-CCU pulse one cluster-validated reset epoch
- [`2026-08-08-rewrite-phase-2-hard-ccu-dma-recovery.md`](2026-08-08-rewrite-phase-2-hard-ccu-dma-recovery.md) — Rewrite Phase 2 types hard-CCU DMA-group recovery
- [`2026-08-08-rewrite-phase-2-cluster-power-lease.md`](2026-08-08-rewrite-phase-2-cluster-power-lease.md) — Rewrite Phase 2 replaces the hard-CCU powered-core array with a cluster lease
- [`2026-08-08-rewrite-phase-2-cluster-construction.md`](2026-08-08-rewrite-phase-2-cluster-construction.md) — Rewrite Phase 2 constructs a shadow CCU cluster without changing admission
- [`2026-08-08-rewrite-phase-2-cluster-ccu-ownership.md`](2026-08-08-rewrite-phase-2-cluster-ccu-ownership.md) — Rewrite Phase 2 makes the cluster the CCU list and publication owner
- [`2026-08-08-rewrite-phase-1-focused-build-gate.md`](2026-08-08-rewrite-phase-1-focused-build-gate.md) — Rewrite Phase 1 exact tips pass the full build matrix and 6.18 packaging
- [`2026-08-08-forward-port-rga2-userptr-swiotlb-segments.md`](2026-08-08-forward-port-rga2-userptr-swiotlb-segments.md) — Forward-port 6.18.43 conformance isolates oversized RGA2 USERPTR SWIOTLB segments
- [`2026-08-08-forward-port-rga2-dmabuf-staging.md`](2026-08-08-forward-port-rga2-dmabuf-staging.md) — Forward port stages exporter-owned high DMA-BUFs for RGA2-only work
- [`2026-08-08-forward-port-rga-mpp-ownership-audit-fixes.md`](2026-08-08-forward-port-rga-mpp-ownership-audit-fixes.md) — Forward-port 0095–0096 close RGA/MPP ownership and fault-admission gaps
- [`2026-08-08-forward-port-boot-dtb-symlink-mismatch.md`](2026-08-08-forward-port-boot-dtb-symlink-mismatch.md) — Forward-port kernel booted the mainline DTB: `/boot/dtb` and `/boot/Image` split across co-installed branches
- [`2026-08-07-rga3-cross-process-vpp-corruption-lead.md`](2026-08-07-rga3-cross-process-vpp-corruption-lead.md) — RGA3 vpp_rkrga output corruption — first seen cross-process, now reproduced solo; not root-caused
- [`2026-08-07-rewrite-rkvdec-drm-prime-duplicate-frame-regression.md`](2026-08-07-rewrite-rkvdec-drm-prime-duplicate-frame-regression.md) — Rewrite rkvdec zero-copy decode duplicates frames after the #8 scheduler/completion fixes
- [`2026-08-07-rewrite-rga-blend-chain-swiotlb-and-rga3-iommu-fault.md`](2026-08-07-rewrite-rga-blend-chain-swiotlb-and-rga3-iommu-fault.md) — Rewrite RGA cannot run a valid overlay blend chain: RGA2 SWIOTLB segment limit and a deterministic RGA3 IOMMU fault
- [`2026-08-07-rewrite-mpp-same-session-dual-core-dispatch-race.md`](2026-08-07-rewrite-mpp-same-session-dual-core-dispatch-race.md) — Rewrite MPP scheduler races same-session frames across both rkvdec cores; ordering + CCU-conformance fix committed
- [`2026-08-07-ffmpeg-rkrga-failures-are-latent-pts-and-checker-defects.md`](2026-08-07-ffmpeg-rkrga-failures-are-latent-pts-and-checker-defects.md) — FFmpeg rkrga conformance failures are latent PTS and checker defects exposed by suite strictness; kernel #8 exonerated
- [`2026-08-06-rga-rop-identity-transform-gate.md`](2026-08-06-rga-rop-identity-transform-gate.md) — RGA rewrite's ROP gate mistook librga's identity cosine for rotation
- [`2026-08-06-rewrite-rga-userptr-map-before-power-iommu-fault.md`](2026-08-06-rewrite-rga-userptr-map-before-power-iommu-fault.md) — Rewrite RGA USERPTR imports mapped before core power and left a stale IOTLB entry
- [`2026-08-06-rewrite-kasan-media-suite-userspace-fixes-and-intermittent-h264.md`](2026-08-06-rewrite-kasan-media-suite-userspace-fixes-and-intermittent-h264.md) — Rewrite KASAN media rerun fixes two GStreamer userspace gaps but exposes intermittent H.26x decode output
- [`2026-08-06-mpp-rewrite-missing-supports-device-proc.md`](2026-08-06-mpp-rewrite-missing-supports-device-proc.md) — MPP rewrite omitted the BSP `supports-device` proc inventory
- [`2026-08-06-librga-palette-demo-is-not-kernel-conformance.md`](2026-08-06-librga-palette-demo-is-not-kernel-conformance.md) — librga's palette demo does not provide a kernel conformance signal
- [`2026-08-06-armbian-rock5b-u-boot-console-options.md`](2026-08-06-armbian-rock5b-u-boot-console-options.md) — Armbian ROCK 5B vendor U-Boot disables its only interactive console
- [`2026-08-05-rewrite-rga2-dmabuf-userptr-bounce-followup.md`](2026-08-05-rewrite-rga2-dmabuf-userptr-bounce-followup.md) — RGA2 bounce follow-up: reroute incompatible DMA-BUFs and preserve USERPTR page offsets
- [`2026-08-05-rewrite-rga-librga-swiotlb-fence-status.md`](2026-08-05-rewrite-rga-librga-swiotlb-fence-status.md) — Rewrite RGA librga failures: SWIOTLB segments, fd-zero fences, and sample status
- [`2026-08-05-rewrite-kunit-fd-zero-boot-wedge.md`](2026-08-05-rewrite-kunit-fd-zero-boot-wedge.md) — A legacy fd-zero fence sentinel wedged the boot inside KUnit
- [`2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md`](2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md) — Enabling IEP2 broke interlaced VA-API decode by un-masking a driver defect: MPP's decoder deinterlacer is 1:N, VA-API decode is 1:1
- [`2026-08-04-rewrite-kunit-request-rotation-repair.md`](2026-08-04-rewrite-kunit-request-rotation-repair.md) — Current rewrite tips repair request cleanup and rotation KUnit contracts
- [`2026-08-04-rewrite-kernel-rebase-6-18-42-7-2-rc6.md`](2026-08-04-rewrite-kernel-rebase-6-18-42-7-2-rc6.md) — Rewrite kernels rebased cleanly onto v6.18.42 and v7.2-rc6
- [`2026-08-04-iep2-field-parity-closed-and-i1o1-bff-bug.md`](2026-08-04-iep2-field-parity-closed-and-i1o1-bff-bug.md) — IEP2 field parity settled: the mode suffix selects the field and `dil_order` does nothing, so MPP's hardcoded I1O1T is wrong for BFF streams
- [`2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md`](2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md) — Installed ysp13 fixes Google Chrome's green H.264; VP9 selects VA-API above Chromium's software cutoff
- [`2026-08-04-forward-port-sd-rescue-rollback-used.md`](2026-08-04-forward-port-sd-rescue-rollback-used.md) — Forward-port kernel rollback has been performed through an SD rescue boot
- [`2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md`](2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md) — Forward-port 0090–0092 close the RGA job-task and decoder recovery lifetime gaps
- [`2026-08-04-forward-port-6-18-42-0092-production-validation.md`](2026-08-04-forward-port-6-18-42-0092-production-validation.md) — Forward-port 6.18.42 production validation boots 0092 and closes the functional recovery gates
- [`2026-08-03-rk3588-iep2-nondeterministic-output.md`](2026-08-03-rk3588-iep2-nondeterministic-output.md) — RK3588 IEP2 runs clean under KASAN; its output non-determinism is a missing dma-buf cache sync in Rockchip's test harness, not the driver
- [`2026-08-03-rewrite-rga-unreachable-iommu-irq-mask.md`](2026-08-03-rewrite-rga-unreachable-iommu-irq-mask.md) — The RGA rewrite's IOMMU-IRQ-mask fallback was unreachable, and it blocked the mainline mirror
- [`2026-08-03-mainline-missing-uncached-dma32-heaps.md`](2026-08-03-mainline-missing-uncached-dma32-heaps.md) — Mainline lacks the BSP uncached/dma32 dma-heaps; MPP absorbs it, librga samples do not
- [`2026-08-02-vsi-iommu-mainline-convergence-and-resync-collision.md`](2026-08-02-vsi-iommu-mainline-convergence-and-resync-collision.md) — Mainline absorbed the VSI IOMMU driver and its RK3588 DT node in v7.2-rc1, and our forward port will collide with both
- [`2026-08-02-rk3588-maxline-proposal-refresh.md`](2026-08-02-rk3588-maxline-proposal-refresh.md) — RK3588 maxline refreshed to current proposals, Linus master, and linux-next
- [`2026-08-02-rga3-forward-port-small-geometry-discriminator.md`](2026-08-02-rga3-forward-port-small-geometry-discriminator.md) — Forward-port RGA3 passes the repeated small-geometry AFBC-to-P010 dropped-write discriminator
- [`2026-08-02-mainline-tool-assisted-contribution-policy.md`](2026-08-02-mainline-tool-assisted-contribution-policy.md) — Mainline now has a written tool-assisted contribution policy, and its trailer is not the one this repo uses
- [`2026-08-02-mainline-codec-fix-series-self-review.md`](2026-08-02-mainline-codec-fix-series-self-review.md) — Three of the seven mainline codec-fix patches are defective
- [`2026-08-02-driver-probe-error-path-test-design.md`](2026-08-02-driver-probe-error-path-test-design.md) — Probe error paths are testable by DT alone, but -ENXIO and -ENODEV probe failures are silent by default
- [`2026-08-01-stock-ubuntu-rock5b-successor-architecture.md`](2026-08-01-stock-ubuntu-rock5b-successor-architecture.md) — A ROCK 5B-only Ubuntu successor should keep Resolute userspace stock and own the board kernel and firmware
- [`2026-08-01-rkvdec-self-reset-and-iommu-restore-gaps.md`](2026-08-01-rkvdec-self-reset-and-iommu-restore-gaps.md) — The rkvdec2 hardware self-resets on error; the rewrite driver neither detects it nor restores the IOMMU
- [`2026-08-01-rewrite-soft-ccu-cross-core-reset-wedge.md`](2026-08-01-rewrite-soft-ccu-cross-core-reset-wedge.md) — Soft-CCU bus-stall wedge returns on the error-reset path; needs two cores of one group resetting
- [`2026-08-01-rewrite-kunit-boot-failures-and-suite-audit.md`](2026-08-01-rewrite-kunit-boot-failures-and-suite-audit.md) — The two RGA KUnit boot failures were fixture lag; a full-suite audit tightened three more cases and pruned three
- [`2026-08-01-rewrite-driver-review-round-3.md`](2026-08-01-rewrite-driver-review-round-3.md) — Rewrite-driver review round 3: 11 defects, 8 of them holes in fixes already recorded as closed
- [`2026-08-01-rewrite-driver-retrospective.md`](2026-08-01-rewrite-driver-retrospective.md) — Rewrite-driver retrospective: keep the ownership model, change the architecture and qualification order
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
- [`2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md`](2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md) — FFmpeg RKMPP async-frame lifetime fix clears reset/close double release
- [`2026-07-30-boot-failure-retro-prevention-levers.md`](2026-07-30-boot-failure-retro-prevention-levers.md) — Wedge-week retrospective: what would have caught each failure class before boot
- [`2026-07-29-rga-no-core-match-narrow-afbc-10bit.md`](2026-07-29-rga-no-core-match-narrow-afbc-10bit.md) — A narrow AFBC 10-bit frame has no RGA core: RGA3 needs width ≥ 68 and RGA2 cannot read AFBC
- [`2026-07-29-rewrite-soft-ccu-dual-core-wedge.md`](2026-07-29-rewrite-soft-ccu-dual-core-wedge.md) — Rewrite soft-CCU dual-core decode wedges the interconnect; arm/start split root-caused and fixed
- [`2026-07-29-rewrite-kunit-fixture-audit.md`](2026-07-29-rewrite-kunit-fixture-audit.md) — Rewrite KUnit fixture audit: 2 boot oopses fixed, full 232-case sweep, latent hazard inventory
- [`2026-07-29-rewrite-driver-review-round-2.md`](2026-07-29-rewrite-driver-review-round-2.md) — Rewrite-driver review round 2: 12 confirmed defects fixed, 4 items ledgered
- [`2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md`](2026-07-29-rdp-reconnect-handover-redirect-race-and-inhibitor-idletime-reset.md) — RDP reconnect after idle dies in the greeter→session handover, masquerading as the wake-watch wedge
- [`2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md`](2026-07-29-production-6-18-40-orig-is-rewrite-composite-snapshot.md) — The production 6.18.40 `20260725` orig is a rewrite-composite worktree snapshot, not the validated forward-port series
- [`2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md`](2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md) — MPP job-ISR IOMMU fault-handler clear takes sleeping locks and panicked the idle task
- [`2026-07-29-forward-port-warn-oops-audit-and-fixes.md`](2026-07-29-forward-port-warn-oops-audit-and-fixes.md) — Forward-port MPP/RGA WARN/oops audit: 18 defects found and fixed
- [`2026-07-29-av1-rewrite-branch-hardening-gap-and-backport.md`](2026-07-29-av1-rewrite-branch-hardening-gap-and-backport.md) — rk3588-rewrite-av1-6.18 forked before 19 hardening commits; KUnit isolation and the ISR fault-handler panic fix are absent
- [`2026-07-29-av1-rewrite-backend-design-source-audit.md`](2026-07-29-av1-rewrite-backend-design-source-audit.md) — AV1 rewrite backend: three-region sparse ABI on the mpp-rewrite core with a kernel-owned AFBC block
- [`2026-07-28-rkvdec2-err23-picsize-oversize-width.md`](2026-07-28-rkvdec2-err23-picsize-oversize-width.md) — rkvdec2 `err 0x23`: an 8192-sample width inflection, BSP watchdog constants whose names are wrong, and VA-API caps that are wrong in both directions
- [`2026-07-28-rewrite-kunit-pre-phase-applied.md`](2026-07-28-rewrite-kunit-pre-phase-applied.md) — Rewrite KUnit pre-phase is applied with an 84/148 gate
- [`2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md`](2026-07-28-ramoops-retention-works-on-6-18-40-kernels.md) — Ramoops retention works on the 6.18.40-era kernels — the all-zero failure was kernel-generation-scoped, not firmware-scoped
- [`2026-07-28-production-kernel-debug-option-audit.md`](2026-07-28-production-kernel-debug-option-audit.md) — Production kernel debug audit: four options above Armbian stock, and a 256 MiB debug allocation arriving from the shared boot environment
- [`2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md`](2026-07-28-dmabuf-debug-upstream-provenance-and-fix-options.md) — The DMABUF_DEBUG scatterlist defect is 100% upstream code, reported since 2022, and blocked on an unresolved dma-buf design argument
- [`2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md`](2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md) — CONFIG_DMABUF_DEBUG's mangle_sg_table() is the system-heap page_link writer, and the dma-heap CPU-access sync dereferences it
- [`2026-07-27-rk3588-pvtm-volt-sel-measured.md`](2026-07-27-rk3588-pvtm-volt-sel-measured.md) — This ROCK 5B's BSP voltage-select index measured: L5 little / L7 both big clusters
- [`2026-07-27-rewrite-reset-import-fixture-lockdep.md`](2026-07-27-rewrite-reset-import-fixture-lockdep.md) — Reset/import KUnit fixture missed the DCHS spinlock initialized in its sibling
- [`2026-07-27-rewrite-mpp-preflight-freeze.md`](2026-07-27-rewrite-mpp-preflight-freeze.md) — MPP conformance froze in pre-workload state capture after KUnit poisoned the service
- [`2026-07-27-rewrite-kunit-lockdep-kmemleak-fixtures.md`](2026-07-27-rewrite-kunit-lockdep-kmemleak-fixtures.md) — Final rewrite KUnit boot blockers were one uninitialized mutex and one nested allocation
- [`2026-07-27-rewrite-kunit-final-stack-fixture.md`](2026-07-27-rewrite-kunit-final-stack-fixture.md) — Final capped RGA KUnit stack fixture warning is fixed in both rewrite trees
- [`2026-07-27-rewrite-kunit-boot-lifecycle-wedge.md`](2026-07-27-rewrite-kunit-boot-lifecycle-wedge.md) — Rewrite KUnit boot wedge was live-singleton destruction after initcalls
- [`2026-07-27-rewrite-kasan-fixed-source-package.md`](2026-07-27-rewrite-kasan-fixed-source-package.md) — Fixed-source rewrite KASAN package is built and package-verified
- [`2026-07-27-kasan-vs-production-build-provenance-confound.md`](2026-07-27-kasan-vs-production-build-provenance-confound.md) — The KASAN non-reproduction is confounded by toolchain: production is a Launchpad gcc-15.2 build, the KASAN kernel is a local gcc-13.3 build
- [`2026-07-27-grd-sg-writer-source-sweep-vendor-drivers-cleared.md`](2026-07-27-grd-sg-writer-source-sweep-vendor-drivers-cleared.md) — Source sweep clears the vendor MPP driver of the GRD scatterlist write, and corrects three readings of the corrupt value
- [`2026-07-27-grd-sg-oops-third-repro-ioctl-window-measured.md`](2026-07-27-grd-sg-oops-third-repro-ioctl-window-measured.md) — Third GRD oops under live MPP tracing: one buffer import, an immediate fatal sync, and the fingerprint holds 3/3
- [`2026-07-27-grd-sg-corruption-reproduced-and-ioctl-capture-plan.md`](2026-07-27-grd-sg-corruption-reproduced-and-ioctl-capture-plan.md) — GRD system-heap oops reproduces 2/2 on production, and both corrupt pointers land 256 bytes below a 16 KiB boundary
- [`2026-07-27-grd-sg-corruption-kasan-non-reproduction.md`](2026-07-27-grd-sg-corruption-kasan-non-reproduction.md) — The KASAN kernel does not reproduce the GRD system-heap oops, and is likely unable to
- [`2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md`](2026-07-27-grd-rkmpp-system-heap-sg-corruption-oops.md) — GRD's first RKMPP frame oopses on a corrupted system-heap scatterlist entry
- [`2026-07-26-rewrite-kunit-poisons-runtime-and-rga3-probe-fails.md`](2026-07-26-rewrite-kunit-poisons-runtime-and-rga3-probe-fails.md) — Failed rewrite KUnit poisoned MPP runtime while overlapping resources disabled RGA3
- [`2026-07-26-rewrite-kunit-gate-passes.md`](2026-07-26-rewrite-kunit-gate-passes.md) — Rewrite KUnit gate passes all 232 cases on the follow-up boot
- [`2026-07-26-rewrite-kunit-failure-root-causes.md`](2026-07-26-rewrite-kunit-failure-root-causes.md) — Rewrite KUnit failures were stale fixtures plus six driver-contract defects
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
- [`2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md`](2026-07-23-rock5b-boot-hang-recurred-with-patched-plymouth.md) — ROCK 5B boot hang recurred with the patched Plymouth provably in the boot path
- [`2026-07-23-rga-scattered-userptr-unaligned-src-zero-output.md`](2026-07-23-rga-scattered-userptr-unaligned-src-zero-output.md) — RGA scattered-userptr blit silently returns all-zero output for non-16-byte-aligned source offsets
- [`2026-07-23-forward-port-current-tip-full-validation-run.md`](2026-07-23-forward-port-current-tip-full-validation-run.md) — Forward-port current tip (`0072`) full validation run — KASAN debug build
- [`2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md`](2026-07-22-rock5b-boot-hang-plymouth-initramfs-daemon.md) — ROCK 5B boot was held by an unresponsive initramfs Plymouth daemon
- [`2026-07-22-rga-mm-session-debugfs-uaf-freed-task-struct.md`](2026-07-22-rga-mm-session-debugfs-uaf-freed-task-struct.md) — RGA `mm_session` debugfs read is a use-after-free on a freed `task_struct` (+ unkillable D-state hang)
- [`2026-07-22-mpp-process-request-list-add-double-add-warn.md`](2026-07-22-mpp-process-request-list-add-double-add-warn.md) — MPP `INIT_CLIENT_TYPE` double-call corrupts the workqueue session list
- [`2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md`](2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md) — GStreamer conformance on the forward-port kernel — green modulo 4 userspace gaps
- [`2026-07-22-bsp-high-current-tip-port.md`](2026-07-22-bsp-high-current-tip-port.md) — BSP-audit HIGH findings ported to the current forward-port tip
- [`2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md`](2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md) — Scope: RGA2 page-table DMA ownership (0050) and DMA-API over-4G path (0051)
- [`2026-07-21-rga-rewrite-rust-counterfactual.md`](2026-07-21-rga-rewrite-rust-counterfactual.md) — Rust counterfactual for the RGA clean-room rewrite: wrong call in 2026, right call once dma-buf/fence/IOMMU abstractions land
- [`2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md`](2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md) — RGA `rga_request` completion races session-close: KASAN use-after-free on the current forward-port tip
- [`2026-07-21-rga-job-vs-session-close-uaf-kasan.md`](2026-07-21-rga-job-vs-session-close-uaf-kasan.md) — RGA in-flight job outlives its session: KASAN use-after-free on the session object
- [`2026-07-21-rga-forward-port-abi-gaps.md`](2026-07-21-rga-forward-port-abi-gaps.md) — RGA forward-port ABI replay gaps are fixed and pass booted replay
- [`2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md`](2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md) — Root causes for the FFmpeg 10-bit/AV1 diagnostics and librga smoke failures
- [`2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md`](2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md) — MPP client-less session NULL-deref hard crash — `RELEASE_FD` dereferences a NULL `session->dma`
- [`2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md`](2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md) — Mainline AV1/V4L2 vs VA-API, and why Firefox's only Rockchip hardware-decode route is VA-API
- [`2026-07-21-forward-port-lifetime-resource-ownership-audit.md`](2026-07-21-forward-port-lifetime-resource-ownership-audit.md) — Forward-port MPP/RGA lifetime and resource-ownership audit
- [`2026-07-20-rkvenc2-slice-fifo-terminal-drop.md`](2026-07-20-rkvenc2-slice-fifo-terminal-drop.md) — RKVENC2 silently drops the terminal slice when its per-task FIFO fills
- [`2026-07-20-rga2-unmapped-page-table-dma-sync.md`](2026-07-20-rga2-unmapped-page-table-dma-sync.md) — RGA2 syncs page-table memory through an unmapped DMA address
- [`2026-07-20-armbian-radxa-image-fit-audit.md`](2026-07-20-armbian-radxa-image-fit-audit.md) — Armbian Radxa catalog: 21 zero-DTB images, 207 clean, 95 not applicable
- [`2026-07-20-armbian-non-radxa-radxa-uboot-audit.md`](2026-07-20-armbian-non-radxa-radxa-uboot-audit.md) — Non-Radxa Radxa-U-Boot catalog: 17 zero-DTB images, 182 clean, 4 unavailable
- [`2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md`](2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md) — KASAN: rkvenc2_wait_result reads task->state after freeing the task (forward-port-introduced)
- [`2026-07-18-mpp-reset-session-dma-double-free-kasan.md`](2026-07-18-mpp-reset-session-dma-double-free-kasan.md) — KASAN caught the preflight Oops: MPP_CMD_RESET_SESSION double-frees session->dma
- [`2026-07-17-rga-session-close-uaf.md`](2026-07-17-rga-session-close-uaf.md) — RGA session-close force-free ignores refcounts; a leaked test handle exposed it as a kernel Oops
- [`2026-07-17-mpp-procfs-session-teardown-oops.md`](2026-07-17-mpp-procfs-session-teardown-oops.md) — MPP procfs session dump races private teardown and NULL-dereferences
- [`2026-07-17-forward-port-conformance-preflight-oops.md`](2026-07-17-forward-port-conformance-preflight-oops.md) — Forward-port conformance preflight Oopsed before the first MPP case
- [`2026-07-16-rockchip-bsp-driver-quality.md`](2026-07-16-rockchip-bsp-driver-quality.md) — Rockchip BSP driver quality is feature-strong but below mature mainline robustness
- [`2026-07-13-rock5b-u-boot-fit-dtb-race.md`](2026-07-13-rock5b-u-boot-fit-dtb-race.md) — ROCK 5B zero-DTB race: controlled proof, Noble `cp`, and KSpace amplification
- [`2026-07-09-rock5b-armbian-sd-boot-investigation.md`](2026-07-09-rock5b-armbian-sd-boot-investigation.md) — ROCK 5B Armbian SD boot investigation summary
- [`2026-07-08-armbian-builder-setup.md`](2026-07-08-armbian-builder-setup.md) — ROCK 5B Armbian builder: native host, branch/release map, and remote-cache behavior
- [`2026-07-08-armbian-26.2.1-bl31-handoff-hang.md`](2026-07-08-armbian-26.2.1-bl31-handoff-hang.md) — Armbian 26.2.1 ROCK 5B raw bootloader hangs after BL31 handoff
- [`2026-07-07-rock5b-spi-sd-boot-chain.md`](2026-07-07-rock5b-spi-sd-boot-chain.md) — ROCK 5B SPI U-Boot changes how Radxa SD images boot
<!-- findings-index:end -->
