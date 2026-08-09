# Forward-port capability and evidence scorecard

Project-local evidence basis for the RK3588 kernel codec/RGA forward port. It
answers what the series has demonstrated, which dated evidence supports that
claim, and which boundaries remain. It is not the live install recommendation
or publication ledger:

- [`status.md` tracks 1–2](../../status.md#dashboard) own the public verdict and
  one next proof;
- [W16](../../status.md#watch-w16) owns the dated moving source/package cache;
- the [patch series README](../patches/forward-port-rk3588/README.md) owns
  mechanical order;
- the [patch catalog](./patch-catalog.md) owns fix provenance and backport
  relationships;
- fresh observations remain [findings](../../findings/README.md) until promoted.

Target hardware is Radxa ROCK 5B (RK3588) under Armbian. Exact source,
package, config, and boot identity must be taken from the linked evidence for
each claim rather than inferred from a later branch head.

## Capability scorecard

| Capability | Strongest maintained evidence | Material boundary |
|------------|-------------------------------|-------------------|
| Built-in MPP/RGA stack | MPP encode/decode and RGA probe/function paths run with all accelerators built in; no overlay or out-of-tree module is required | Evidence is specific to the recorded ROCK 5B/Armbian artifacts |
| H.264/H.265 encode/decode | Both encoder and decoder core families have real-workload results; decode correctness and production conformance are recorded in the [tests guide](../tests/README.md) and [production finding](../../findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md) | Static clocks replace BSP-only PVTM/system-monitor DVFS |
| VP9 and AV1 decode | Both have bit-exact software-reference evidence; AV1 uses the distinct VPU981/VSI-IOMMU path documented by the [AV1 note](../av1/docs/av1-rk3588.md) | This does not qualify the separate mainline stateless/Hantro path |
| RGA2/RGA3 operations | Direct librga, FFmpeg RKRGA, preprocessing-shaped, 10-bit, async/fence, forced-core, and recovery cases have hardware evidence across the linked campaigns | Installed 6.18.43/`0092` fails three RGA2-only large-USERPTR official samples at SWIOTLB mapping; source `0093` fixes driver-owned USERPTR segmentation, while `0095` supersedes `0094` by staging every high-address RGA2 DMA-BUF and closes related ownership gaps. The `0093`–`0096` tail is compile/review- and signed-source-package-verified, but Launchpad build and boot remain unverified. Unsupported raw physical imports and several legacy/RGA2-Pro modes remain deliberately rejected |
| ABI and consumer conformance | ABI replay, official MPP, FFmpeg, GStreamer, and direct librga suites have dated results; the exact 6.18.42/`0092` production campaign is the latest fully integrated record in this document | The 6.18.43 rerun passed identity, ABI, and MPP, then stopped at librga before GStreamer/FFmpeg; the older campaign retained two classified GStreamer userspace failures |
| Memory/lifetime safety | Multiple KASAN/lockdep campaigns closed RGA/MPP lifetime defects through the recorded patch ranges | A production-profile pass is not sanitizer evidence; the exact live tail still needs the gate named by status |
| Recovery and soak | Decoder/RGA recovery stress and a two-hour encode soak passed in the 0092 campaign | The 4K decode workload/kernel scan passed but its strict userspace fd-span oracle remained red; systematic fault injection and longer soak remain qualification debt |
| Packaging and rollback | Armbian patch injection, Debian packages, exact boot fingerprinting, SD rescue, and `kernel-revert.sh` have operator evidence | Publication and installed identity can drift and therefore belong to W16/status/package metadata |
| Application integration | Headless codecs and broad VA-API paths have evidence | Authenticated RDP/reconnect and physical-display integration remain separate environment gates |

## Current release boundary, 2026-08-04

This heading is retained as a compatibility anchor. It is a **frozen dated
boundary**, not a live “current” claim.

The 2026-08-04 production record used source
`rk3588-video-6.18@7d53bc7a3adc`, patches `0001`–`0092`, and source package
`6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1`. Its exact image, DTB, and
headers were installed and booted as `6.18.42-ysp-rockchip64`.

That artifact passed ABI replay, official MPP, required/diagnostic FFmpeg,
direct librga/RGA completion, bit-exact decode, IOMMU machinery, VP9/RGA
recovery stress, broad VA-API, bounded kernel-log scans, and a two-hour encode
soak. GStreamer recorded 100/102 required cases, with the two failures
classified above. The two-hour 4K decode workload and kernel scan passed, while
the strict userspace fd-span oracle failed at loop-boundary transients.

Use the [production validation finding](../../findings/2026-08-04-forward-port-6-18-42-0092-production-validation.md)
for method and signals, the
[source/fix finding](../../findings/2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md)
for the final safety tail, and the
[rollback finding](../../findings/2026-08-04-forward-port-sd-rescue-rollback-used.md)
for operator recovery. Status and W16 supersede this snapshot for live state.

## Historical validation chronology

The former run diary is condensed to milestones that changed the maintained
capability or evidence boundary. Git history retains the full chronology.

| Milestone | Durable conclusion and route |
|-----------|------------------------------|
| 6.18.37 `Pb6ab-Cb831` / predecessor `P8c75` | First exact combined-kernel H.264/H.265 hardware scorecard; [tests observed results](../tests/README.md) |
| AV1 superset `P1c9d` | VPU981/VSI AV1 became bit-exact on hardware; [AV1 note](../av1/docs/av1-rk3588.md) |
| Patches `0041`–`0044` | KASAN lifetime repairs and full ABI replay closed the initial package/preflight failures; [patch catalog](./patch-catalog.md) |
| Patches `0045`–`0050` | RGA legacy virtual import, 10-bit layout, DMA ownership, and over-4G bounce behavior were corrected and hardware-gated; [RGA conformance finding](../../findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md) and [DMA finding](../../findings/2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md) |
| Patches `0051`–`0057` / `Pd222-C4ad2` | Session/job/request lifetime and client-less release defects received booted KASAN plus ABI/media gates; public records retain bounded outcomes while the working hostile harnesses remain private |
| Patches `0058`–`0075` | BSP-audit, RGA, encoder, and recovery fixes accumulated into a broad 6.18.40 KASAN campaign; [validation finding](../../findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md) |
| Patches `0076`–`0092` | Adversarial safety/recovery tail reached the dated production artifact above; broad ordinary integration is green, while exact-tail sanitizer and targeted hostile proof remain scoped open gates |
| Patch `0093` | The first correct-DTB 6.18.43 run isolated merged 2 MiB RGA2 USERPTR entries exceeding SWIOTLB's per-map limit; the [source fix](../../findings/2026-08-08-forward-port-rga2-userptr-swiotlb-segments.md) is strict-checkpatch, affected-object compile-, and signed-source-package-verified, with archive-build/boot replay pending |
| Patch `0094` | The same 256 KiB constraint cannot be repaired by splitting exporter-owned DMA-BUF attachment tables. This first staging implementation entered only after exact `-EIO`; `0095` supersedes that incomplete forward-port trigger |
| Patch `0095` | The [ownership audit fix](../../findings/2026-08-08-forward-port-rga-mpp-ownership-audit-fixes.md) stages every high-address RGA2 DMA-BUF through one bounded shared job object and closes RGA request, fence, import, PM, and shutdown ownership gaps. Production and async-disabled full-RGA `W=1 WERROR=1` builds, final independent reviews, and signed-source-package validation pass; archive-build/boot replay is pending |
| Patch `0096` | MPP session/result/DMA state and Rockchip/VSI fault admission are serialized; post-START pending faults are preserved, and hard RKVDEC2 CCU requests fall back to soft mode before worker selection. Full MPP/IOMMU `W=1 WERROR=1` builds, independent reviews, and signed-source-package validation pass; archive-build/boot replay is pending |
| 2026-08-04 rollback exercise | SD rescue and `kernel-revert.sh` were used successfully; [rollback finding](../../findings/2026-08-04-forward-port-sd-rescue-rollback-used.md) |

Patch-by-patch identities, dependencies, validation classes, and BSP-backport
relationships belong in the [patch catalog](./patch-catalog.md), not here.

## ✅ Done — validated on real hardware

The following are durable capability claims, each bounded by its cited
artifact:

- H.264/H.265 RKVENC2 encode and RKVDEC2 decode on both core families.
- Bit-exact H.264/H.265/VP9 and VPU981/VSI AV1 decode.
- RGA2/RGA3 probe plus real transform paths through FFmpeg and direct librga.
- Built-in combined-kernel operation with stable device nodes and udev access.
- ABI replay and representative MPP/librga/GStreamer/FFmpeg consumer coverage.
- Multiple booted KASAN/lockdep campaigns for the named historical patch
  ranges.
- Package install/boot identity checks and operator-tested rollback.

“Done” means the named scope has evidence; it does not make a later package,
different kernel configuration, sanitizer profile, application environment, or
unexercised hostile path equivalent.

## ⏭️ Skipped / deferred (intentionally)

| Item | Durable disposition |
|------|---------------------|
| Encoder/decoder DVFS, OPP, and system monitor | BSP-only PVTM/system-monitor dependencies are not carried; fixed DT clocks are the supported model |
| JPEG codec blocks | Not a project goal and not wired/qualified as part of this forward-port profile |
| Broad historical codec/legacy ioctl surface | A name exposed by old userspace does not become supported without hardware, DT, ownership, and caller evidence |
| RGA genpool and unsupported legacy/RGA2-Pro modes | Not needed for the maintained Rock 5B capability; reject unsafe/unimplemented paths |
| Same-boot forward-port ↔ rewrite A/B | The two implementations own the same device families and require separate boots |
| Netboot/diskless workflow | Operationally possible but not part of the codec/RGA support contract |

VP9, AV1, and expanded consumer conformance were once listed here but are no
longer deferred; their bounded results moved to the capability scorecard.

## ⚠️ Known limitations

| Boundary | Interpretation / owner |
|----------|------------------------|
| Live source/package/publication identity | Volatile; recheck W16 and package metadata |
| Exact-tail memory safety | Ordinary production conformance cannot replace the current KASAN/lockdep and targeted hostile gates in status |
| 4K decode resource oracle | Workload and kernel scan passed in the 0092 finding; the userspace fd-span policy did not |
| RDP and physical display | Headless codec/VA-API evidence does not establish authenticated session, reconnect, focus, or display-plane behavior |
| GStreamer classified failures | The 0092 campaign retained two userspace caps/flush failures; kernel-log evidence remained clean |
| RGA2 high USERPTR and DMA-BUF mapping | Installed 6.18.43/`0092` fails three RGA2-only official librga samples before hardware start when merged 2 MiB USERPTR entries exceed SWIOTLB's per-map ceiling; `0093` shapes driver-owned SG entries and `0095` supersedes `0094` by staging every CPU-accessible high-address DMA-BUF for RGA2-only work. The exact `0096` tail is source-packaged and client-uploaded but still needs archive-build/boot replay; secure/non-vmap, raw-physical, and over-cap inputs still fail closed |
| Fixed clocks | No BSP PVTM/system-monitor DVFS; performance/thermal behavior is specific to the configured fixed rates |
| JPEG and out-of-scope hardware | No support claim |
| Systematic fault/fuzz/long soak | Remain wider qualification work; public results must not import private triggers |

Resolved defect narratives no longer live in this section. Their patch identity
and provenance are in the catalog; their decisive dated evidence remains in
the linked findings until findings promotion.

## Where the series stands, 2026-08-04

Compatibility anchor for the former dated rollup. At that checkpoint the exact
0092 production artifact supported the broad functional/recovery boundary
recorded above, while exact-tail sanitizer/hostile proof, the strict decode
resource oracle, root-only counters, RDP/display integration, systematic fault
injection, and longer soak remained open.

For any later decision, use status tracks 1–2 and W16. Do not extend this dated
section with new package chronology.

## What "done" means here

A forward-port claim is complete only when its evidence records:

1. exact source/patch, package, configuration, installed, and boot identity;
2. real workload plus an output or semantic correctness signal;
3. the kernel-log, counter, sanitizer, or recovery boundary relevant to the
   claim;
4. the environment and unsupported paths;
5. the smallest remaining proof, routed through status when it affects the
   public contract.

Compile success, a device node, one green userspace exit code, or an older
sanitizer run cannot silently satisfy a broader or newer claim. Use the
[kernel validation runbook](./kernel-validation-runbook.md) for operations and
the [validation router](./validation-index.md) to select the correct owner.
