# Upstreaming decisions — librga

This package holds the userspace `librga` fork and its exported patch series against the airockchip/librga lineage. This file is librga's upstream submission disposition, decided 2026-07-29; cross-package ordering and coupling constraints live in the central [upstreaming ledger](../../docs/upstreaming-ledger.md). Dated claims below must be re-verified before acting on them.

## Decision list

| ID | Item | Artifact | Upstream target | Decision | Priority | Gates / prerequisites |
|----|------|----------|------------------|----------|----------|------------------------|
| RGA-1 | im2d: submit 10-bit vir_w as a byte stride (raster + tile; FBC excluded) | yisding/librga@c80eea7 + b8def3e + 4c26ddf | Issue on airockchip/librga; reach jellyfin-rga author via nyanmisaka/ffmpeg-rockchip or jellyfin/jellyfin-ffmpeg | SUBMIT-NOW | P1 | — |
| RGA-2 | Legacy path: propagate 10-bit layout flags in color-fill/palette and fix the palette ioctl argument | yisding/librga@1dbf1b2; patches/0006 | Issue on airockchip/librga, cross-posted to nyanmisaka/ffmpeg-rockchip | SUBMIT-NOW | P2 | — |
| RGA-3 | Reject padded 10-bit and non-raster rd_mode on the RGA1/RGA2 legacy compatibility path instead of lossily converting | yisding/librga@1dbf1b2 + a632217 | Follow-on issue on airockchip/librga plus nyanmisaka/ffmpeg-rockchip, after RGA-2 | SUBMIT-AFTER-GATE | P3 | RGA-2's issue draws a maintainer response — "land RGA-2 first" is not achievable at a mirror with no review channel; decide and document whether compact NV15/NV20 stays allowed on the RGA2 fallback so the rejection cannot be read as "no 10-bit on RGA2" |
| RGA-4 | im2d: implement RK_FORMAT_P010/P210 request generation against the BSP kernel contract | yisding/librga@a632217; patches/0007 | Issue on airockchip/librga plus nyanmisaka/ffmpeg-rockchip, as a feature built on RGA-1 | SUBMIT-AFTER-GATE | P2 | RGA-1 sent first, or carried as the leading commits of the same series; confirm against airockchip/librga main that the vendor source drop does not already implement direct P010/P210 request generation |
| RGA-5 | build: define LINUX for every cmake target, and check fread() results | yisding/librga@26a50ef | airockchip/librga issue with diff inline, plus nyanmisaka/ffmpeg-rockchip issue | SUBMIT-NOW | P3 | — |
| RGA-6 | Replayed nyanmisaka commits: meson static-target revert, blit 10-bit propagation, RGA2 full-CSC fix, RGA3 FBCE RGB/BGR fix | yisding/librga@a4db07b, 68aa084, eee4774, d6a6e4c; patches/0002-0005 | n/a — origin is nyanmisaka/rk-mirrors jellyfin-rga@1d330cc2 | NEVER | P3 | — |
| RGA-7 | Vendor 1.10.6 source-release import layer | yisding/librga@cc39281; patches/0001 | n/a — vendor release content | NEVER | P3 | — |
| RGA-8 | imcheck() cannot express per-core storage-mode limits: narrow AFBC 10-bit is accepted by librga and refused by the kernel as an opaque IM_STATUS_FAILED | No patch — root cause only | airockchip/librga (issue); alternatively nyanmisaka/rk-mirrors (PR) once a per-core matcher exists | HOLD | P3 | Implement per-core, per-storage-mode matching in imcheck() and gate it on hardware; bisect the RGA3 68-pixel floor on silicon; revisit if/when VAProfileHEVCMain10 is unhidden |
| RGA-9 | Official librga samples: success is returned as exit status 1, and demos hardcode dma-heap names that do not exist off the BSP | No patch yet — two measured defects | airockchip/librga GitHub issue with the patch inline; mirror to tsukumijima/librga-rockchip only if that mirror revives | SUBMIT-AFTER-GATE | P3 | Write the patch (process status independent of IM_STATUS enum; dma-heap fallback); re-run the official sample matrix and quantify how many of the 38 failures the two fixes convert |
| RGA-10 | gstreamer-rockchip: dmabuf-feature transcode fails caps negotiation, and the plugin's internal legacy RGA path returns EACCES for 10-bit | No patch — two measured failures | JeffyCN gstreamer-rockchip (GitHub issue — no fix is held) | HOLD | P3 | Establish whether the EACCES is librga policy or plugin misuse before choosing the target; reproduce both on the current shipping librga rather than the sweep's build |

## Rationale and evidence

### RGA-1 — im2d: submit 10-bit vir_w as a byte stride (raster + tile; FBC excluded)

Stock librga against the stock vendor kernel silently produces wrong output: BSP develop-5.10 and develop-6.1 are byte-identical on the rga3_reg_info.c stride math and rga_convert_addr(), so 10-bit vir_w is a byte stride on the kernel ordinary airockchip users run, and upstream im2d passing wstride through in pixels under-reports the row by 20% (compact) or 50% (incompact). Both halves are hardware-measured on BSP-semantics kernels: broken-before on the pre-0048 forward port (Main10→P010 PSNR ~6.96 dB) and fixed-after on the 2026-07-25 KASAN kernel (P010→P010 bit-exact, P010→NV12 neutral chroma, NV15 bit-exact). Any tree carrying a kernel that scales 10-bit RGA3 strides by pixel depth must ship kernel and librga together, so the PR must state that coupling explicitly; the fix has never been run on a literal Rockchip BSP image, and it is im2d-only — the legacy c_RkRgaBlit() path is untouched.

- Evidence: [findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md](../../findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md), [findings/2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md](../../findings/2026-07-24-rga-10bit-tile-byte-stride-and-fbc-exception.md), [findings/2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md](../../findings/2026-07-24-rga-10bit-uv-plane-offset-still-pixel-scaled.md), [findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md](../../findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md), [docs/librga-p010-p210-rkrga.md](docs/librga-p010-p210-rkrga.md), [../../docs/source-trees.md](../../docs/source-trees.md), [../../status.md](../../status.md)
- Coupled with: RGA-4, KFP-5

### RGA-2 — Legacy path: propagate 10-bit layout flags in color-fill/palette and fix the palette ioctl argument

Completes the fix nyanmisaka's jellyfin-rga branch started: that patch copied the 10-bit layout fields only in the blit builder, and an audit found two more builders (color fill, color palette) that assign rd_mode and drop is_10b_compact/is_10b_endian, silently reinterpreting padded P010/P210 destinations as compact. The palette path also passed a pointer-to-pointer to the kernel. This is source-confirmed and built, not hardware-exercised — this project has no 10-bit color-fill or palette gate — so it should be presented as correctness-by-construction, in the same shape as the accepted blit patch, rather than a measured result.

- Evidence: [patches/0006-normal-harden-legacy-10-bit-request-handling.patch](patches/0006-normal-harden-legacy-10-bit-request-handling.patch), [patches/README.md](patches/README.md), [docs/librga-p010-p210-rkrga.md](docs/librga-p010-p210-rkrga.md)
- Coupled with: RGA-3

### RGA-3 — Reject padded 10-bit and non-raster rd_mode on the RGA1/RGA2 legacy compatibility path instead of lossily converting

The old RGA_BLIT_SYNC struct has no rd_mode/compact_mode/is_10b_endian fields, so a padded P010/P210 request converted onto that path is accepted as generic 10-bit semiplanar and produces corrupt pixels rather than an error. This is the one change in the series that turns a currently-"working" (silently wrong) call into a hard failure for third-party callers, so it is sequenced after RGA-2 lands rather than sent in the same thread. No hardware evidence exists for the RGA1/RGA2 fallback on this board (RGA3/RGA2 are always scheduled through the multi-RGA ioctl), so it must be offered as a fail-closed hardening argument, not a measured regression fix.

- Evidence: [docs/librga-p010-p210-rkrga.md](docs/librga-p010-p210-rkrga.md), [patches/0006-normal-harden-legacy-10-bit-request-handling.patch](patches/0006-normal-harden-legacy-10-bit-request-handling.patch)
- Coupled with: RGA-2

### RGA-4 — im2d: implement RK_FORMAT_P010/P210 request generation against the BSP kernel contract

The public 1.10.6 API advertises RK_FORMAT_P010/P210 while the open source lineage has no request-generation path for them, leaving the enums dead on any source-built librga — exactly the Jellyfin decode-to-RGA-to-tonemap use case. Hardware evidence covers the exercised subset only: im2d P010→NV12 and P210→NV16 pass in librga-smoke, and P010→P010/P010→NV12 are bit-exact/chroma-neutral on the direct probes (2026-07-25). The padded 4:2:2 leg has no real 4:2:2 workload behind it, and the vendor-format normalization is inferred from disassembly and BSP field tracing, not vendor source, so it should be submitted as a feature built on RGA-1's stride fix with that boundary stated.

- Evidence: [patches/0007-im2d-support-P010-and-P210-request-generation.patch](patches/0007-im2d-support-P010-and-P210-request-generation.patch), [docs/librga-p010-p210-rkrga.md](docs/librga-p010-p210-rkrga.md), [findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md](../../findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md), [../../status.md](../../status.md)
- Coupled with: RGA-1

### RGA-5 — build: define LINUX for every cmake target, and check fread() results

Pure build/robustness fix with zero ABI or behaviour risk: a bare `cmake` configure (no CMAKE_BUILD_TARGET) previously defined LINUX nowhere, so the build died with four undeclared-identifier errors in core/RgaUtils.cpp, and four fread() sites in core/RgaUtils.cpp and samples/utils/utils.cpp handed back an uninitialised buffer on a short read instead of failing. Verified compile-clean on all three build paths (bare cmake, cmake -DCMAKE_BUILD_TARGET=buildroot, meson/ninja). Compile-only evidence is the right and sufficient class for a build fix, and the fork commit itself is the artifact since this predates the patches/ export cutoff.

- Evidence: [../../docs/source-trees.md](../../docs/source-trees.md), [../../packaging/userspace-patches.md](../../packaging/userspace-patches.md), [patches/README.md](patches/README.md)

### RGA-6 — Replayed nyanmisaka commits

These four commits are verbatim replays of nyanmisaka's top jellyfin-rga commits onto the history-preserving base, kept only so the local tree and exported patch series are self-contained. Submitting them anywhere would be re-offering someone else's patches; if the wider vendor lineage wants them they should come from their author. Recorded here so a future reader does not mistake patches 0002-0005 for upstreamable local delta.

- Evidence: [patches/README.md](patches/README.md), [docs/librga-p010-p210-rkrga.md](docs/librga-p010-p210-rkrga.md)

### RGA-7 — Vendor 1.10.6 source-release import layer

A vendor import, not a change: it exists so the local fixes apply to the latest released source while preserving the open JeffyCN history. Nothing to upstream — the upstreams already have it. Recorded to keep the patch-series accounting honest.

- Evidence: [patches/README.md](patches/README.md), [../../docs/source-trees.md](../../docs/source-trees.md)

### RGA-8 — imcheck() cannot express per-core storage-mode limits

A 64x240 AFBC 10-bit job is a pincer: only RGA3 reads AFBC and RGA3's minimum input/output width is 68, while RGA2 is raster-only, so librga accepts the job and the kernel scheduler emits "no core match," surfacing to callers as IM_STATUS_FAILED (0) rather than IM_STATUS_NOT_SUPPORTED (-1). The refusal itself is inherited BSP kernel policy dating to 2021/2022, not a librga bug per se, and the librga-side fix (per-core, per-storage-mode matching) is unimplemented and non-trivial. Diagnosed 2026-07-29; held because a report to a prebuilt-only repo with no fix attached buys little, and the user-visible failure is already closed one layer up in rockchip-vaapi.

- Evidence: [findings/2026-07-29-rga-no-core-match-narrow-afbc-10bit.md](../../findings/2026-07-29-rga-no-core-match-narrow-afbc-10bit.md), [../../status.md](../../status.md)
- Coupled with: MPP-8

### RGA-9 — Official librga samples report success as exit status 1, and hardcode absent dma-heap names

Two defects measured against the shipped samples (run 20260725-223239-librga-suite): demos print "running success!" then exit(IM_STATUS_SUCCESS) == 1, and others open /dev/dma_heap/system-uncached or system-uncached-dma32 (vendor dma-heap driver, not upstream) and fail before submitting any work on a kernel exposing only default_cma_region/reserved/system. Both are small, obviously correct, and zero-risk, and this is the only source airockchip publishes, so it is a useful low-cost probe of whether that repo takes patches at all — but no patch has been written yet and the payoff is developer experience, not shipped-pixel correctness, so it stays gated and at P3. The DMA32 half is partly an environment gap: full BSP userspace compatibility would need the vendor system-dma32/system-uncached-dma32 heaps, tracked as a candidate kernel forward-port addition rather than a librga bug.

- Evidence: [findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md](../../findings/2026-07-25-forward-port-6-18-40-kasan-full-validation.md), [findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md](../../findings/2026-07-21-rga-ffmpeg-librga-conformance-root-causes.md), [../../kernel-drivers/tests/conformance/README.md](../../kernel-drivers/tests/conformance/README.md)

### RGA-10 — gstreamer-rockchip dmabuf caps negotiation and legacy-path EACCES

Two measured failures from the 2026-07-22 GStreamer sweep on a clean-journal boot: the dmabuf-feature h264-to-h265 transcode fails caps negotiation at h264parse while the non-dmabuf variant passes, and two 10-bit RGA-scale cases fail with "RGA_BLIT fail: Permission denied" (EACCES) from the plugin's internal c_RkRgaBlit, while the same 10-bit conversion is bit-exact through im2d scale_rkrga. Held rather than filed: the EACCES may be librga's own policy adjacent to RGA-2/RGA-3 rather than a plugin defect, and the shipped librga may already have moved past the sweep's build, so both gates must close before a report goes anywhere.

- Evidence: [findings/2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md](../../findings/2026-07-22-gstreamer-suite-forward-port-userspace-gaps.md), [docs/librga-p010-p210-rkrga.md](docs/librga-p010-p210-rkrga.md)
- Coupled with: RGA-2, RGA-3
