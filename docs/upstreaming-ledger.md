# Upstreaming ledger — cross-package submission decisions

This is the single cross-package record of which patches, reports and questions
this project submits to which upstreams, and in what order. It was decided on
2026-07-29 by a multi-agent evaluate/verify pass over every tracked package.
Each package keeps its own consistent list in an `UPSTREAMING.md` next to its
README — [`kernel-drivers`](../kernel-drivers/UPSTREAMING.md),
[`vendor-libraries/mpp`](../vendor-libraries/mpp/UPSTREAMING.md),
[`vendor-libraries/rga`](../vendor-libraries/rga/UPSTREAMING.md),
[`video-libraries/ffmpeg`](../video-libraries/ffmpeg/UPSTREAMING.md),
[`video-libraries/mesa`](../video-libraries/mesa/UPSTREAMING.md),
[`video-libraries/vaapi`](../video-libraries/vaapi/UPSTREAMING.md),
[`apps/gnome-remote-desktop`](../apps/gnome-remote-desktop/UPSTREAMING.md),
[`boot-firmware`](../boot-firmware/UPSTREAMING.md),
[`packaging`](../packaging/UPSTREAMING.md) and
[`kernel-versions`](../kernel-versions/UPSTREAMING.md) — and this ledger is the
place where those lists are reconciled against each other. Every dated claim
here must be re-verified before acting on it; upstream state moves, and several
rows were already wrong about it once. Review chronology for in-flight items
belongs in [`../status.md`](../status.md)'s watchlist, not here.

## Decision vocabulary

| Decision | Meaning |
|----------|---------|
| SUBMIT-NOW | Evidence and target readiness support preparing the submission immediately. |
| SUBMIT-AFTER-GATE | Worth submitting; send once the named gates close. |
| IN-FLIGHT | Submitted, awaiting review. |
| MERGED | Accepted upstream. |
| HOLD | Worth submitting but blocked or unripe; the revisit condition is named on the row. |
| NEVER | Deliberately not submitting. |

## First wave — ordered next submissions

| # | ID | Item | Package | Target | Why now |
|---|----|------|---------|--------|---------|
| 1 | MESA-5 | Mali-G610 varying-erratum characterization for MR !43161 | [mesa](../video-libraries/mesa/UPSTREAMING.md) | Mesa MR !43161 discussion (plus the same data on !42679) | Decaying window and now confirmed live: !43161 was updated 2026-07-29, it is actively choosing a size/aspect cutoff our board data shows is wrong, and the contribution is a comment plus already-tracked reproducers, not a patch. |
| 2 | KFP-1 | Coordinated unprivileged memory-corruption disclosure for vendor MPP/RGA (P0 tier) | [kernel-drivers](../kernel-drivers/UPSTREAMING.md) | rockchip-linux/kernel issue + radxa/kernel `linux-6.1-stan-rkr5.1` PR; CVE via MITRE | Highest severity and best evidence in the repo (KASAN-observed UAF/double-free plus five unprivileged PoCs), and it opens the vendor channel every other kernel security item is sequenced behind — now correctly split into an issue plus a radxa PR, with KFP-22's two Tier-1 lifetime fixes folded in. |
| 3 | KFP-2 | RGA raw physical-address import crash reaching `dma_map_sg()` | [kernel-drivers](../kernel-drivers/UPSTREAMING.md) | rockchip-linux/kernel issue + radxa/kernel PR (rides KFP-1's thread) | S-effort one-file fix with a booted oops trace and a clean three-branch BSP analysis; ride the KFP-1 issue and radxa PR so it costs almost nothing extra. |
| 4 | MPP-2 | h264e poll cfg allocation size and vepu511a `reg_idx` indexing | [mpp](../vendor-libraries/mpp/UPSTREAMING.md) | rockchip-linux/mpp PR against `develop` | Cheapest memory-safety fix in the set (sizeof-pointer allocation under-sizing a kernel-written buffer), confirmed still present at the develop tip, reviewable in minutes — open it as an issue as well as a PR, since rockchip-linux/mpp merges only ~3 of 48 PRs. |
| 5 | MPP-1 | Harden the eight vepu5xx split-output encoder slice poll loops | [mpp](../vendor-libraries/mpp/UPSTREAMING.md) | rockchip-linux/mpp PR against `develop` | Unbounded encoder spin in shipping vepu5xx HALs with booted forced-split hardware evidence; stack it on MPP-2 since it touches the same four files, and pair it with an issue for the same merge-rate reason. |
| 6 | RGA-1 | im2d: submit 10-bit `vir_w` as a byte stride (raster + tile; FBC excluded) | [rga](../vendor-libraries/rga/UPSTREAMING.md) | airockchip/librga issue with the patch inline + nyanmisaka/ffmpeg-rockchip issue | Silent 10-bit wrong-output against stock vendor kernels, bit-exact before/after evidence, and it is the community-known Jellyfin P010 corruption — file it as an issue with the patch inline, naming the KFP-5 kernel half, since neither librga tree accepts PRs. |
| 7 | FF-1 | v4l2_buffers copy-bounds rewrite (multiplanar NULL deref, source overread, linesize corruption) | [ffmpeg](../video-libraries/ffmpeg/UPSTREAMING.md) | FFmpeg upstream — confirm the channel (code.ffmpeg.org PR vs ffmpeg-devel) | Reachable NULL deref plus source overread in vanilla upstream v4l2 m2m code, no fork dependency, and the plan's designated first series — it establishes the channel FF-2/FF-3 wait on, so confirm whether FFmpeg now takes pull requests at code.ffmpeg.org before sending. |
| 8 | GRD-3 | AVC420 color signaling: full-range BT.709 shader against a limited/unspecified VUI | [gnome-remote-desktop](../apps/gnome-remote-desktop/UPSTREAMING.md) | GNOME gnome-remote-desktop GitLab issue, then MR against the VA-API encode session | Unambiguous upstream-only bug (upstream's own full-range BT.709 shader against a limited/unspecified VUI) with spec citation and runtime proof; issue-first costs a day and needs no VA-API hardware here. |

## Coupling constraints

- KFP-5, RGA-1 and RGA-4 are one ABI decision split across two upstreams. Neither upstream accepts PRs in practice, so submit them as explicitly cross-referenced issue threads (a radxa/kernel PR plus a rockchip-linux issue for the kernel half, an airockchip/librga issue for the librga half), each citing the other: a vendor landing only one half leaves 10-bit output wrong by 20-50% with no error, only wrong chroma.
- KFP-6, MPP-1 and MPP-2 go to different upstreams but must reference each other; the kernel RKVENC2 slice-FIFO reservation alone still leaves the userspace infinite loop, and the userspace poll-loop hardening alone still drops the terminal record. Within MPP, send MPP-2 first and stack MPP-1 on top since they touch the same four h264e files, and open a companion issue for each because rockchip-linux/mpp merges only ~3 of 48 PRs.
- MPP-7 is a caller-side problem, so nothing is filed against MPP; the fix belongs in the FFmpeg rkmpp wrapper (FF-8), and the GRD encode backend MR (GRD-8) should not be offered until FF-8 and the rkmppenc rate-control work (FF-5) are upstream, or its bitrate-triplet workarounds become the review.
- KFP-1, KFP-2, KFP-3, KFP-7, KFP-22 and PKG-1 form one vendor disclosure with two venues: the report is a GitHub issue on rockchip-linux/kernel (whose PR channel has never merged anything) and the patches are a PR on radxa/kernel `linux-6.1-stan-rkr5.1`. KFP-1 opens it with KFP-2 and KFP-22 riding the same thread, KFP-3 follows once its F4 leak remediation is folded in, and KFP-7 (D01/D02, plus D04/D05 in its second wave) must be written and reproduced fast enough not to look withheld. The disclosure cites the merged Armbian udev rule (PKG-1) as the reachability premise and verifies exposure per downstream.
- KRW-2, KRW-3, KRW-4 and KFP-16 contend for the same forward-port patch files `rk3588-fwport-0005` and `-0012`; KFP-16's NEVER scope excludes those hunks and now points back at all three, and the IOMMU series must be posted once with the forward-port/AV1 track so vsi-iommu is not submitted twice.
- KFP-11, KFP-12 and KFP-19 are one dma-buf review thread on dri-devel + linaro-mm-sig + linux-media with one shared control: the evidence report (KFP-11) opens it, the Kconfig one-liner (KFP-12) follows as the modest concrete ask, nothing goes to Armbian (KFP-19, since stock Armbian never sets `DMA_API_DEBUG`), and all three depend on the same ~rk2 boot A/B to remove the compiler confound.
- PKG-2, PKG-9, PKG-3 and KFP-15 are the Armbian patch-mechanism cluster: PKG-2's docs correction goes now, PKG-9's missing-`KERNELPATCHDIR` assertion is the same silent-wrong-artifact class and can ride alongside, PKG-3's precedence flip waits for maintainer appetite, and KFP-15 stays shelved regardless because its blocker is Armbian's mainline-media policy, not the patch mechanism.
- RGA-8 and MPP-8 are one root cause with two possible upstream asks (librga per-core storage-mode matching, MPP AFBC geometry control); neither is filed until MPP's allocation path is read, because the user-visible failure is already closed downstream in rockchip-vaapi and a speculative pair of reports would expose that the cheaper alternatives were not checked.
- MESA-12, MESA-13 and GRD-5 span the uncached-readback cliff across three projects: report the generic core-Mesa conversion path and the Panfrost linear-import map as linked issues, and have the GNOME MR cite them so reviewers see the GRD cached-GPU-copy as a consumer workaround for a driver-layer problem rather than an unexplained extra copy.
- MESA-1, MESA-2, MESA-3 and MESA-4 are a strict MR stack with a fragile topology: !42563 (MESA-1) is independent and can be assigned to Marge now, but !42679 (MESA-2) must be rebased and its CI rerun before !42613 (MESA-3) is regenerated from its tip, and !42614 (MESA-4) moves only when MESA-3 moves. !42679 is not an ancestor of !42613 today, so regenerating in any other order breaks the stack.
- MESA-5, MESA-6 and MESA-7 make the Valhall varying-erratum contribution data on someone else's MR, not code: post the size/aspect predicate results and the fixed-clock A/B cost to !43161 (updated 2026-07-29, so the window is live), and keep the benchmark override patch fork-local unless reviewers explicitly ask for a reproducible A/B knob.
- GRD-14, PKG-6 and PKG-7 are one greeter codec-access measurement with three candidate owners; report it once to systemd (PKG-7) after a generic reproducer exists, keep the `g:gdm` ACL rule fork-only (PKG-6), and mention the greeter gap only as context inside the GRD backend RFC (GRD-14/GRD-7).
- VA-1, VA-3 and VA-5: nothing external to the vaapi track can be asked for until the driver is publicly identifiable and installable. The successor announcement gates both the Firefox sandbox bug and any GStreamer allowlist request, since Mozilla and GStreamer will both ask who ships this driver.

## Full disposition by package

### kernel-drivers

Package list: [`../kernel-drivers/UPSTREAMING.md`](../kernel-drivers/UPSTREAMING.md)

| ID | Item | Target | Decision | Priority |
|----|------|--------|----------|----------|
| KFP-1 | Coordinated unprivileged memory-corruption disclosure for vendor MPP/RGA (P0 tier) | rockchip-linux/kernel issue + radxa/kernel PR; MITRE CVE | SUBMIT-NOW | P1 |
| KFP-2 | RGA raw physical-address import crash: unvalidated userspace PFN reaches `dma_map_sg()` | rockchip-linux/kernel issue + radxa/kernel PR | SUBMIT-NOW | P1 |
| KFP-3 | Second-batch memory-safety: RKVDEC2 RCB index OOB, RKVENC2 fan-out OOB, device-less-task NULL deref, RCB unmap-after-free | Follow-up on the KFP-1 issue + second radxa/kernel PR | SUBMIT-AFTER-GATE | P1 |
| KFP-4 | BSP-audit HIGH remainder: RGA lifetime/policy correctness and MPP allocation-failure handling | radxa/kernel PR, mirrored as a rockchip-linux/kernel issue | SUBMIT-AFTER-GATE | P2 |
| KFP-5 | 10-bit P010/NV15 byte-literal raster strides and UV plane offsets | radxa/kernel PR + rockchip-linux issue; librga half via RGA-1 | SUBMIT-AFTER-GATE | P2 |
| KFP-6 | RKVENC2 silently drops the terminal slice record when the 256-entry FIFO fills | radxa/kernel PR + rockchip-linux issue | SUBMIT-NOW | P2 |
| KFP-7 | Unbounded user-controlled reg-offset index (D01) and u32-wrap size underflow (D02) | rockchip-linux security issue + radxa/kernel PR; CVE via MITRE | SUBMIT-AFTER-GATE | P1 |
| KFP-8 | RGA2 DMA-API page-table ownership, above-4G reject, over-4G service via swiotlb bounce | radxa/kernel PR + rockchip-linux issue | HOLD | P3 |
| KFP-9 | Defensive RGA input validation: staged REQUEST_CONFIG checks and under-4G exclusion reporting | Batched radxa/kernel correctness PR, mirrored as an issue | HOLD | P3 |
| KFP-10 | The 65-patch BSP-audit MEDIUM/LOW/cleanup series | None as a series | HOLD | P3 |
| KFP-11 | CONFIG_DMABUF_DEBUG x dma-heap CPU-access incompatibility, with the first user-visible failure | dri-devel + linaro-mm-sig + linux-media | SUBMIT-AFTER-GATE | P2 |
| KFP-12 | `drivers/dma-buf/Kconfig`: stop auto-enabling DMABUF_DEBUG from DMA_API_DEBUG | Same dma-buf thread as KFP-11 | SUBMIT-AFTER-GATE | P3 |
| KFP-15 | The RK3588 vendor MPP/RGA/AV1 forward-port series as an Armbian patch-archive addition | armbian/build PR | HOLD | P3 |
| KFP-16 | Forward-port infrastructure, port-introduced fixes, and our own regressions | none — no external upstream applies | NEVER | P3 |
| KFP-17 | The Rockchip develop-5.10 RGA reconciliation cherry-picks | none — Rockchip already owns these commits | NEVER | P3 |
| KFP-18 | Debug-only instrumentation: system-heap sg guard, IOMMU/RGA diagnostics, ramoops DT | none — diagnostic-only | NEVER | P3 |
| KFP-19 | The CONFIG_DMABUF_DEBUG config fix as an Armbian submission | armbian/build (considered and rejected) | NEVER | P3 |
| KFP-20 | rkvdec2 CCU watchdog: misnamed timeout constants, misleading reset log, pixel-count bucket cliff | Informational rockchip-linux issue; cleanup to radxa/kernel | HOLD | P3 |
| KFP-21 | RKNPU trusts a userspace-supplied kernel object pointer; task buffers and per-open state unvalidated | rockchip-linux security issue; airockchip/rknn-toolkit2 | HOLD | P3 |
| KFP-22 | Two unowned Tier-1 BSP lifetime fixes: RGA session-close force-free, MPP procfs session unlink order | KFP-1's issue + radxa/kernel PR | SUBMIT-NOW | P1 |
| KFP-23 | DWC PCIe PMU nests two bus-notifier rwsems of one lockdep class, disabling lockdep for the boot | linux-pci + linux-perf-users | SUBMIT-AFTER-GATE | P3 |
| KRW-1 | Clean-room mpp-rewrite + rga-rewrite drivers as a mainline kernel submission | Linux mainline (linux-media / linux-rockchip) | NEVER | P3 |
| KRW-2 | iommu/rockchip: restore the 32-bit max DMA segment size; guard release_device against a NULL link | iommu@lists.linux.dev | SUBMIT-NOW | P1 |
| KRW-3 | iommu/rockchip: honor multi-page map/unmap counts, add flush_iotlb_all, report BUS_ERROR | iommu@lists.linux.dev | SUBMIT-NOW | P2 |
| KRW-4 | iommu/vsi: fix `vsi_iommu_probe()` error paths | iommu@lists.linux.dev | SUBMIT-NOW | P2 |
| KRW-5 | Per-device, unregisterable IOMMU fault handler for media drivers | RFC to iommu@lists.linux.dev | HOLD | P3 |
| KRW-6 | DT binding + IOMMU group sharing for multicore decoder clusters | devicetree@vger.kernel.org + iommu@lists.linux.dev | HOLD | P2 |
| KRW-7 | `iommu_dma_get_iova_domain()` export and the RGA Route B userptr IOVA fallback | Linux IOMMU/DMA core — declined | NEVER | P3 |
| KRW-8 | Mainline RGA vehicle judgment: contribute RK3588 features to the V4L2 RGA driver | linux-media + linux-rockchip | HOLD | P2 |
| KRW-9 | RK3588 decoder-MMU interrupt discrepancy (mainline SPI 98 vs shared SPI 96) | linux-rockchip DT bug report | HOLD | P3 |
| KRW-10 | Vendor RKMPP/RGA DT bindings, the `rk-mpp.h` uAPI header, and vendor-node DT enablement | Linux mainline DT — declined | NEVER | P3 |
| KRW-11 | Rewrite ABI ledgers and the recovered BSP uAPI facts | no viable external upstream | NEVER | P3 |

### vendor-libraries/mpp

Package list: [`../vendor-libraries/mpp/UPSTREAMING.md`](../vendor-libraries/mpp/UPSTREAMING.md)

| ID | Item | Target | Decision | Priority |
|----|------|--------|----------|----------|
| MPP-1 | Harden the eight vepu5xx split-output encoder slice poll loops against poll failure | rockchip-linux/mpp PR against `develop` | SUBMIT-NOW | P1 |
| MPP-2 | Fix the h264e poll cfg allocation size and the vepu511a `reg_idx` indexing | rockchip-linux/mpp PR against `develop` | SUBMIT-NOW | P1 |
| MPP-3 | HEVC same-ID PPS update never reaches the HAL (stale tile table on TILES_A_Cisco_2) | rockchip-linux/mpp — no longer needed | NEVER | P3 |
| MPP-4 | `mpp_runtime_test` pthread start-routine signature (GCC 15 / newer glibc) | rockchip-linux/mpp — not needed | NEVER | P3 |
| MPP-5 | HEVC RADL pictures suppressed at random access (NUT_A_ericsson) | rockchip-linux/mpp issue | SUBMIT-AFTER-GATE | P2 |
| MPP-6 | Modernize the in-tree `debian/` packaging | rockchip-linux/mpp PR against `develop` | HOLD | P3 |
| MPP-7 | MPP async encoder input backpressure with no documented flow-control contract | rockchip-linux/mpp — not filing | NEVER | P3 |
| MPP-8 | Ask MPP for a wider AFBC decode geometry so narrow 10-bit surfaces can be RGA-converted | rockchip-linux/mpp issue / feature question | HOLD | P3 |

### vendor-libraries/rga

Package list: [`../vendor-libraries/rga/UPSTREAMING.md`](../vendor-libraries/rga/UPSTREAMING.md)

| ID | Item | Target | Decision | Priority |
|----|------|--------|----------|----------|
| RGA-1 | im2d: submit 10-bit `vir_w` as a byte stride (raster + tile; FBC excluded) | airockchip/librga issue + nyanmisaka/ffmpeg-rockchip issue | SUBMIT-NOW | P1 |
| RGA-2 | Legacy path: propagate 10-bit layout flags in color-fill/palette; fix the palette ioctl argument | airockchip/librga issue, cross-posted to nyanmisaka/ffmpeg-rockchip | SUBMIT-NOW | P2 |
| RGA-3 | Reject padded 10-bit and non-raster `rd_mode` on the RGA1/RGA2 legacy path | Follow-on airockchip/librga issue after RGA-2 | SUBMIT-AFTER-GATE | P3 |
| RGA-4 | im2d: implement RK_FORMAT_P010/P210 request generation against the BSP kernel contract | airockchip/librga + nyanmisaka/ffmpeg-rockchip issues | SUBMIT-AFTER-GATE | P2 |
| RGA-5 | build: define `LINUX` for every cmake target, and check `fread()` results | airockchip/librga issue with the diff inline | SUBMIT-NOW | P3 |
| RGA-6 | Replayed nyanmisaka commits (meson revert, blit 10-bit, RGA2 full-CSC, RGA3 FBCE RGB/BGR) | n/a — origin is nyanmisaka/rk-mirrors | NEVER | P3 |
| RGA-7 | Vendor 1.10.6 source-release import layer | n/a — vendor release content | NEVER | P3 |
| RGA-8 | `imcheck()` cannot express per-core storage-mode limits (narrow AFBC 10-bit) | airockchip/librga issue | HOLD | P3 |
| RGA-9 | Official samples: success returned as exit status 1; hardcoded dma-heap names | airockchip/librga issue with the patch inline | SUBMIT-AFTER-GATE | P3 |
| RGA-10 | gstreamer-rockchip: dmabuf transcode caps negotiation, legacy RGA path EACCES for 10-bit | JeffyCN/gstreamer-rockchip issue | HOLD | P3 |

### video-libraries/ffmpeg

Package list: [`../video-libraries/ffmpeg/UPSTREAMING.md`](../video-libraries/ffmpeg/UPSTREAMING.md)

| ID | Item | Target | Decision | Priority |
|----|------|--------|----------|----------|
| FF-1 | v4l2_buffers copy-bounds rewrite (multiplanar NULL deref, source overread, linesize corruption) | FFmpeg upstream — confirm the channel first | SUBMIT-NOW | P1 |
| FF-2 | v4l2_context negotiation fixes + mplane-aware fourcc selection and format-table rows | FFmpeg upstream — inherit FF-1's channel | SUBMIT-AFTER-GATE | P2 |
| FF-3 | `libavdevice/v4l2.c` generics: device_caps, planes[] init and bytesused bounds, format fallback, NV21 | FFmpeg upstream — inherit FF-1's channel | SUBMIT-AFTER-GATE | P3 |
| FF-4 | pixdesc big-endian x-offset fix plus fate-pixdesc test hookup | FFmpeg upstream — parallel with FF-1 | SUBMIT-NOW | P3 |
| FF-5 | rkmppenc constant-QP rate control for upstream's own RKMPP encoder | FFmpeg upstream | SUBMIT-AFTER-GATE | P1 |
| FF-6 | rkmpp/rkrga memory-safety class (double-frees, submit unwind, RGA error-path lifecycle, overreads) | nyanmisaka/ffmpeg-rockchip PR | SUBMIT-NOW | P1 |
| FF-7 | rkmpp hang/deadlock class (EOS eof latch, send_eos busy-loop, receive EAGAIN deadlock, async drop) | nyanmisaka/ffmpeg-rockchip PR | SUBMIT-NOW | P1 |
| FF-8 | rkmppenc bounded synchronous output wait plus transient input-backpressure absorption | nyanmisaka/ffmpeg-rockchip PR | SUBMIT-AFTER-GATE | P1 |
| FF-9 | rkmppdec out-of-band extradata marked as MPP extra-data (fixes AV1 from MP4/MKV) | nyanmisaka/ffmpeg-rockchip PR | SUBMIT-AFTER-GATE | P2 |
| FF-10 | Wrong-output class: SAR/transpose, AFBC 10-bit strides, RGA core-mask literals, crop, NV15 tails | nyanmisaka/ffmpeg-rockchip PR | SUBMIT-AFTER-GATE | P2 |
| FF-11 | Restore the endian-neutral AV_PIX_FMT_NV20 alias and repair the broken fate-imgutils reference | nyanmisaka/ffmpeg-rockchip PR | SUBMIT-NOW | P2 |
| FF-12 | Small-fixes bundle (~20 items: AVERROR_EOF sign, precedence, MJPEG gaps, flush, cache-sync flags) | nyanmisaka/ffmpeg-rockchip PR | SUBMIT-AFTER-GATE | P3 |
| FF-13 | DRM descriptor/layout validation frameworks, `afbc_offset_y` as a descriptor field | nyanmisaka/ffmpeg-rockchip design issue, then PR | HOLD | P3 |
| FF-14 | NV15 / NV20_PACKED compact 10-bit pixel formats as a full upstream feature series | FFmpeg upstream (ffmpeg-devel) | HOLD | P3 |
| FF-15 | `libavformat/id3v2` sliver: reject unknown text encodings instead of falling through | FFmpeg upstream (ffmpeg-devel) | HOLD | P3 |
| FF-16 | FFmpeg-8.x port glue and self-inflicted regression fixes | none | NEVER | P3 |
| FF-17 | Removal of unsafe RFBC DRM modifiers | none | NEVER | P3 |

### video-libraries/mesa

Package list: [`../video-libraries/mesa/UPSTREAMING.md`](../video-libraries/mesa/UPSTREAMING.md)

| ID | Item | Target | Decision | Priority |
|----|------|--------|----------|----------|
| MESA-1 | panfrost: clear shader image mask on trailing unbinds | Mesa MR !42563 | IN-FLIGHT | P1 |
| MESA-2 | u_blitter: use fragment position for unscaled TXF blits | Mesa MR !42679 | IN-FLIGHT | P1 |
| MESA-3 | panfrost: enable blit-based texture transfers | Mesa MR !42613 | IN-FLIGHT | P2 |
| MESA-4 | u_tests: wide unscaled format-changing blit precision test + glsl_type singleton reference | Mesa MR !42614 | IN-FLIGHT | P3 |
| MESA-5 | Mali-G610 varying-erratum characterization: size/aspect predicate data, PanVK and blob cross-checks | Mesa MR !43161 discussion | SUBMIT-NOW | P1 |
| MESA-6 | Fixed-clock, single-context A/B cost of the MR !43161 all-blit depth-bias workaround | Mesa MR !43161 discussion | SUBMIT-NOW | P2 |
| MESA-7 | MR !43161 benchmark override: remove the size/aspect gate, add `PAN_BLIT_DEPTH_BIAS` controls | Mesa — would be a patch on someone else's MR | NEVER | P3 |
| MESA-8 | Archived panfrost BLIT+COMPUTE transfer-mode advertising patch | Mesa — none intended | NEVER | P3 |
| MESA-9 | panfrost: lower `textureQueryLevels` on Valhall (arch >= 9) | Mesa MR, panfrost label | SUBMIT-AFTER-GATE | P2 |
| MESA-10 | mesa,dri: skip zero-sized blits before Gallium | Mesa MR, core Mesa/DRI | SUBMIT-NOW | P3 |
| MESA-11 | lavapipe: skip zero-sized image blit and resolve regions | Mesa MR, lavapipe | SUBMIT-NOW | P3 |
| MESA-12 | core Mesa: glReadPixels fallback converts per-pixel out of an uncached/WC source map | Mesa GitLab issue against core readpixels | SUBMIT-AFTER-GATE | P2 |
| MESA-13 | panfrost: imported linear buffers CPU-read through a direct uncached map | Mesa GitLab issue, panfrost label | SUBMIT-NOW | P2 |
| MESA-14 | PanVK: install zero-valued depth bias on internal meta draws | Mesa MR, panvk | HOLD | P3 |
| MESA-15 | panfrost: `GALLIUM_TESTS` aborts in `util_test_constant_buffer` | Mesa GitLab issue, panfrost label | SUBMIT-NOW | P3 |
| MESA-16 | libmali GBM path: `DRM_IOCTL_SET_VERSION` NULL-deref then `rockchip_drm_lastclose` deadlock | Radxa/Rockchip BSP kernel or dri-devel — target is the gate | SUBMIT-AFTER-GATE | P3 |
| MESA-17 | Superseded transfer-avoidance directions (COMPUTE-only cap; pure-integer targeted fallback) | Mesa — none | NEVER | P3 |

### video-libraries/vaapi

Package list: [`../video-libraries/vaapi/UPSTREAMING.md`](../video-libraries/vaapi/UPSTREAMING.md)

| ID | Item | Target | Decision | Priority |
|----|------|--------|----------|----------|
| VA-1 | Declare yisding/rockchip-vaapi the maintained successor to the dormant woodyst/rockchip-vaapi | woodyst/rockchip-vaapi issue + fork release/README notice | SUBMIT-NOW | P2 |
| VA-2 | Offer the whole Phase 0/1/2/4 renovation back as a pull request | woodyst/rockchip-vaapi PR | NEVER | P3 |
| VA-3 | Firefox RDD sandbox: broker paths and seccomp ioctl requests for MPP/RGA/dma-heap | Mozilla Bugzilla (Core :: Security: Process Sandboxing) | SUBMIT-AFTER-GATE | P1 |
| VA-4 | Carry the Rockchip RDD sandbox patch in the distro Firefox package for arm64 | Ubuntu firefox source package / mozillateam PPA | HOLD | P3 |
| VA-5 | Let GStreamer's `va` plugin register the Rockchip VA driver without `GST_VA_ALL_DRIVERS=1` | GStreamer gst-plugins-bad MR | HOLD | P3 |
| VA-6 | Chromium cannot create a GL context on Mali-G610/Panfrost, so no VA-API path is reachable | crbug.com or Mesa/Panfrost — chosen after triage | HOLD | P3 |
| VA-8 | VLC VA-API hardware-decoder fallback on Rockchip — do not report as a VLC bug | VideoLAN — not filed | NEVER | P3 |

### apps/gnome-remote-desktop

Package list: [`../apps/gnome-remote-desktop/UPSTREAMING.md`](../apps/gnome-remote-desktop/UPSTREAMING.md)

| ID | Item | Target | Decision | Priority |
|----|------|--------|----------|----------|
| GRD-1 | Handover ownership and timeout-lifetime hardening in the system daemon | GNOME gnome-remote-desktop MR | SUBMIT-NOW | P1 |
| GRD-2 | Coalesce duplicate pending redirected connections instead of overwriting the pending socket | GNOME gnome-remote-desktop MR | SUBMIT-AFTER-GATE | P2 |
| GRD-3 | AVC420 color signaling: full-range BT.709 shader against a limited/unspecified VUI | GNOME issue, then MR against the VA-API encode session | SUBMIT-NOW | P1 |
| GRD-4 | Vulkan capability assumptions that silently disable all hardware encode | GNOME gnome-remote-desktop MR | SUBMIT-NOW | P2 |
| GRD-5 | EGL thread: read back through a driver-owned cached GPU copy | GNOME gnome-remote-desktop MR | SUBMIT-NOW | P2 |
| GRD-6 | RDPGFX frame-acknowledgement resume wedge; progress-gated bounded recovery | GNOME issue with the captured wedge state, then MR | SUBMIT-AFTER-GATE | P1 |
| GRD-7 | RFC: an FFmpeg-based H.264 encode-session backend for SoCs with no usable VA-API driver | GNOME issue / discussion | SUBMIT-NOW | P2 |
| GRD-8 | FFmpeg/rkmpp H.264 encode-session backend | GNOME gnome-remote-desktop MR | SUBMIT-AFTER-GATE | P2 |
| GRD-9 | Hardware-encode backpressure bounding, stale-view dropping, bounded software cooldown | GNOME MR, after GRD-8 | HOLD | P3 |
| GRD-10 | Fresh watchdog window for newly outstanding work | GNOME MR — not applicable | NEVER | P3 |
| GRD-11 | Pipeline starvation diagnostics, diagnostics thread, watchdog actuator, ACK logging | GNOME MR — not applicable | NEVER | P3 |
| GRD-12 | Audio client-format dump, playback trace with Opus suppression, legacy-format probe | GNOME MR — not applicable | NEVER | P3 |
| GRD-13 | Warn when RDP audio negotiates but no PipeWire Audio/Sink appears; headless fallback sink | GNOME issue, then MR | HOLD | P3 |
| GRD-14 | GDM greeter cannot reach codec device nodes, so the login screen falls back to software encode | GNOME issue, folded into the GRD-7 discussion | HOLD | P3 |
| GRD-15 | Revert "daemon-system: Simplify remote display reconnection handling" | GNOME MR 403 — upstream's own change | MERGED | P3 |
| GRD-16 | Superseded experiments: single-use routing token reconnect, async-PBO and memfd readback | GNOME MR — not applicable | NEVER | P3 |

### boot-firmware

Package list: [`../boot-firmware/UPSTREAMING.md`](../boot-firmware/UPSTREAMING.md)

| ID | Item | Target | Decision | Priority |
|----|------|--------|----------|----------|
| BOOT-1 | Armbian: order `u-boot.itb` after `u-boot.dtb` in the Radxa rk35xx U-Boot patch dir | armbian/build PR #10196 | MERGED | P1 |
| BOOT-2 | Radxa U-Boot: the same one-line Makefile prerequisite on the branch Armbian builds | radxa/u-boot PR, or a backport request on PR #189 | SUBMIT-NOW | P2 |
| BOOT-3 | Report the published-image blast radius: 38 shipping Armbian images carry a zero-byte FIT DTB | armbian/build issue #8227 follow-up | SUBMIT-NOW | P2 |
| BOOT-4 | Armbian build-time gate: fail the artifact when a required FIT FDT component is zero bytes | armbian/build PR adding an artifact assertion | HOLD | P3 |

### packaging

Package list: [`../packaging/UPSTREAMING.md`](../packaging/UPSTREAMING.md)

| ID | Item | Target | Decision | Priority |
|----|------|--------|----------|----------|
| PKG-1 | Rockchip codec/dma-heap udev rule for Armbian images | armbian/build PR #10085 | MERGED | P2 |
| PKG-2 | Armbian docs: the empty-userpatch "disable a patch" instruction is stale on glob branches | armbian/documentation PR | SUBMIT-NOW | P3 |
| PKG-3 | Armbian patcher: restore userpatch-over-core precedence | armbian/build PR against `lib/tools/patching.py` | HOLD | P3 |
| PKG-4 | Plymouth incomplete-CSI keyboard hang patch carried in the PPA | Plymouth upstream / distro — nothing of ours | NEVER | P3 |
| PKG-5 | Report the boot-transaction defect: an unresponsive inherited plymouthd wedges sysinit.target | Plymouth upstream GitLab issue | HOLD | P3 |
| PKG-6 | gdm-hwenc: the `setfacl g:gdm` codec-node udev rule itself | Any distro or GNOME channel | NEVER | P3 |
| PKG-7 | logind uaccess does not follow GDM's dynamic-greeter-user churn on non-seat device nodes | systemd issue (logind/udev uaccess) | HOLD | P3 |
| PKG-8 | rk3588-vcodec-dkms out-of-tree build (Kbuilds, devfreq re-guard, DT overlay) | No external upstream | NEVER | P3 |
| PKG-9 | Armbian builds a patch-free kernel with zero errors when `KERNELPATCHDIR` does not exist | armbian/build issue, then a small assertion PR | SUBMIT-NOW | P3 |
| PKG-10 | Debian/Ubuntu ffmpeg source package omits `frei0r-plugins` from Build-Depends | Debian ffmpeg BTS or Ubuntu Launchpad | SUBMIT-NOW | P3 |

### kernel-versions

Package list: [`../kernel-versions/UPSTREAMING.md`](../kernel-versions/UPSTREAMING.md)

| ID | Item | Target | Decision | Priority |
|----|------|--------|----------|----------|
| KV-1 | RK3588 SKU-bin OPP selection: OTP cells, rockchip-cpufreq driver, platdev blocklist, derated tables | linux-pm / linux-rockchip | SUBMIT-AFTER-GATE | P2 |
| KV-2 | RK3588 per-die voltage: PVTPLL process monitor plus per-die `opp-microvolt-L*` columns | linux-rockchip / linux-pm RFC | HOLD | P3 |
| KV-3 | Track A vendor straight port of `rockchip_opp_select.c` / `rockchip-cpufreq.c` onto 6.18 and 7.2 | None — internal kernels and the PPA only | NEVER | P3 |

## Triage notes

- Three cross-track duplicates were dropped: VA-7 into MPP-5, KFP-13 into PKG-1, KFP-14 into PKG-2/PKG-3. No other item pair covers the same underlying change.
- One evidence contradiction was resolved: KFP-16 declared forward-port patches 0001-0017 unsubmittable while KRW-2/3/4 verified `rk3588-fwport-0012` and the IOMMU hunks of `-0005` against v7.2-rc5 as live mainline fixes. KFP-16's scope was narrowed; the KRW rows keep their SUBMIT-NOW.
- A patch-numbering hazard was confirmed in `kernel-drivers/docs/patch-catalog.md`: catalog 0045/0046/0047 are the staged-config pair plus the under-4G diagnostic (KFP-9), while KFP-5's "0047/0048" are series numbers for catalog 0048/0049 (the 10-bit stride pair). Whoever composes the net kernel change must state which scheme it uses.
- The rockchip-linux/kernel channel correction was applied to all twelve KFP rows that named it as a PR target (KFP-1..KFP-10, KFP-20, KFP-21): 0 of 39 PRs merged and develop-6.1 unmoved since 2025-12-26, so the issue tracker carries the report and radxa/kernel `linux-6.1-stan-rkr5.1` carries the patches. No decision changed, only the venue.
- The librga channel correction was applied to RGA-1..RGA-5 and RGA-9: airockchip/librga takes issues, not PRs, and both nyanmisaka/rk-mirrors and tsukumijima/librga-rockchip are mirrors. RGA-9's "cheapest probe of whether that repo takes PRs" framing was dropped, since it was gating two higher-priority rows on an experiment whose answer is already measured.
- BOOT-1 moved IN-FLIGHT to MERGED on a live check (armbian/build #10196 merged into main on 2026-07-17, twelve days before this pass). BOOT-2 was rescoped accordingly: it now serves non-Armbian downstreams rather than closing our own exposure, which strengthens the case for commenting on the open Radxa PR #189 over opening a competing PR.
- MPP-1's stated "46 of 48 PRs merged" was measured false (3 of 48); the repo is active but rarely merges outside contributions, so every MPP submission opens a companion issue.
- FF-6/FF-13's "the fork may be dead" premise was measured false: nyanmisaka/ffmpeg-rockchip master is 388741a3544b (2026-07-18). The real risk is a ~1-in-14 merge rate, with jellyfin/jellyfin-ffmpeg as a validated fallback.
- MPP-5 was rewritten: the HOLD was contradicted by same-day 2026-07-29 work that root-caused, fixed and runtime-verified the RADL suppression. It stays SUBMIT-AFTER-GATE rather than SUBMIT-NOW because MPP-3 is the cautionary precedent — our 1.0.12 baseline predates four upstream h265d fixes, and the upstream-content check must be a local diff of a fetched `develop`, not a summarised web fetch.
- Overruled: the FFmpeg rows (FF-1..FF-5, FF-14, FF-15) kept their decisions rather than gating on the code.ffmpeg.org channel question — confirming where a project takes patches is a pre-flight step, not a gate. The target text now names both channels and requires confirmation via FF-1.
- Five rows were added by the completeness sweep: KFP-22 (two unowned Tier-1 BSP lifetime fixes, catalog 0040/0041), KFP-23 (DWC PCIe PMU lockdep class collision), PKG-9 (silent patch-free Armbian kernel), PKG-10 (ffmpeg frei0r Build-Depends), RGA-10 (gstreamer-rockchip, HOLD behind an attribution gate). PKG-10 and RGA-10 are thin; RGA-10 may dissolve on a rerun against the shipped librga 2.2.0.
- KFP-7's D04/D05 stay inside that row rather than becoming a separate item: they are already named there, share all three of its gates, and splitting them would create a row with no artifact and no evidence of its own.
- A coupling row for the Mesa MR stack (MESA-1..MESA-4) and a MESA-2 gate on MESA-3 were added: the strict regeneration order lived only in prose, so nothing structurally prevented !42613 being pushed before !42679 was rebased.
- Next up behind the first wave, all cheap: KRW-4 (three-line vsi-iommu probe fixes to a demonstrably receptive maintainer), GRD-1, BOOT-2 and BOOT-3, MESA-13, PKG-2, then the FF-6/FF-7 fork crash and hang waves. KFP-11 is the SUBMIT-AFTER-GATE worth watching, since its only gate is an owner action rather than new work.
- Two rows carry stale external state that must be re-checked over the network before acting: MESA-1's MR status (last live-checked 2026-07-11) and, more generally, any Mesa MR state quoted in this pass.
- VA-6 (Chromium GL init failure on Panfrost) stays in the vaapi track; no mesa item covers it, so there is nothing to deduplicate into, but its triage gate is a Mesa question.
- Several corrections could not be written into structured fields and live in the owning rows' prose: GRD-1's mis-cited handover proof, GRD-6's nonexistent patch filename, GRD-16's missing `reference/README.md`, and KRW-1's stale branch tips and line counts. All four were re-checked on disk.

## Maintenance

- Changing a decision means updating the owning package's `UPSTREAMING.md` **and** this ledger in the same pass. A decision that exists in only one of the two is a bug.
- Keep dates honest: re-verify a dated claim before acting on it, and correct it — do not re-date it to today because it is being read today.
- When new upstream-worthy work appears, record it here and in the owning package file at the same time, with its decision, target and gates.
- IN-FLIGHT review status — who replied, what they asked for, what the next push must contain — belongs in [`../status.md`](../status.md)'s watchlist, not in this ledger.
