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
3. Add one line to the index below. That's it — no other file needs editing.

Trust tags (state how sure you are): **MEASURED** (observed on hardware / in a
run), **HYPOTHESIS** (reasoned but unverified), **UNVERIFIED** (copied from a
comment/commit, not checked).

## Lifecycle

A finding is raw by default. When it matures into durable reference, **graduate**
it: move the content into the owning project's `docs/`, and replace the file here
with a one-line tombstone (`promoted → <path> (YYYY-MM-DD)`) so the trail survives.
Findings that turn out wrong get deleted with a one-line note in the index.

**Boundary vs [`status.md`](../status.md) watchlist:** the watchlist tracks
*facts that go stale silently* (external PRs, distro versions, dev-box SPOFs).
`findings/` holds *newly-learned technical detail*. A finding with a follow-up
action belongs here; a stale-risk to re-check on every maintenance pass belongs
in the watchlist.

## Index (newest first)

Each row: `` `YYYY-MM-DD-slug.md` `` — one-line summary — trust tag.

- `` `2026-07-08-arm-mali-blob-interp-drift-bit-identical-to-mesa.md` `` — promoted → [`video-libraries/mesa/docs/arm-mali-blob-stack.md`](../video-libraries/mesa/docs/arm-mali-blob-stack.md) "Runtime Results" (2026-07-08). ARM blob drift is bit-identical to Mesa → the drift is hardware.
- `` `2026-07-08-armbian-builder-setup.md` `` — the YSP ROCK 5B Armbian builder is the Noble 24.04 aarch64 VMware VM (5 vCPU / 7.7 GiB / root LV grown 48→97 GB), a supported *native* `armbian/build` host (arm64→arm64, `gcc 13.3.0`, no QEMU; `compile.sh` self-relaunches under sudo, no passwordless sudo); for `rock-5b` (family `rockchip-rk3588`) the branch map is legacy 5.10 / vendor 6.1 BSP (`rk-6.1-rkr5.1`→6.1.115) / **current = 6.18 mainline (default, the forward-port target)** / edge 7.1 / bleedingedge 7.2, and Ubuntu 26.04 = `resolute` (`supported`); an unpatched `kernel` build pulls prebuilt `.deb`s from `ghcr.io/armbian/os/…` in 0:19 so only `ARTIFACT_IGNORE_CACHE=yes` or a userpatch hash-change forces local compilation, and 8 GB RAM clears Armbian's BTF gate by only ~19–45 MiB so BTF-link survival is unproven — MEASURED / CONFIG-INSPECTED / BTF-risk HYPOTHESIS.
- `` `2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md` `` — promoted → [`video-libraries/mesa/docs/arm-mali-blob-stack.md`](../video-libraries/mesa/docs/arm-mali-blob-stack.md) "Runtime Results" (2026-07-08). GBM path NULL-derefs `drm_setversion` and wedges DRM; use the X11-client reproducer.
- `` `2026-07-07-arm-mali-blob-reproducer-readiness.md` `` — promoted → [`video-libraries/mesa/docs/arm-mali-blob-stack.md`](../video-libraries/mesa/docs/arm-mali-blob-stack.md) "Runtime Results" (2026-07-08). GLES stack wired, link `-lmali`, Vulkan unavailable from the g6p0 repos.
- `` `2026-07-07-rock5b-spi-sd-boot-chain.md` `` — ROCK 5B SPI contains a valid Armbian/Radxa U-Boot image matching the packaged `rkspi_loader.img`; the Radxa Bookworm SD card has bootable p2/p3, p3 contains standard extlinux with matching root UUID and a Rock 5B DTB, so SPI U-Boot should be able to attempt the SD kernel but bypasses the SD raw bootloader chain; remaining boot-loop cause needs serial capture, likely DTB/kernel handoff/console/vendor-firmware mismatch — MEASURED / INFERRED where noted.
- `` `2026-07-06-rga3-dmabuf-scatter-bsp-contract.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §5 (2026-07-08). dma-buf single-span DESIGN-CONSTRAINT vs BSP.
- `` `2026-07-06-ffmpeg-rockchip81-package-validation.md` `` — `ffmpeg-rockchip-81` commit `75638e7f0b17` clean-builds and packages as a self-contained `/opt` runtime; feature registration, H.264 RKMPP encode, and RKMPP hwupload -> `scale_rkrga` -> HEVC RKMPP encode passed, but default sandbox `/dev` masking blocks in-sandbox hardware tests, installed-MPP rkmpp decode fails with `mpp_parser_init parser h264 is not registered`, direct software-frame input to `scale_rkrga` is an invalid command shape, and local MPP demo binaries fail with `mpp_sgln_base_add` symbol mismatch — MEASURED / INFERRED where noted.
- `` `2026-07-05-rkvenc-rcb-sram.md` `` — RK3588 RKVENC has real RCB descriptor plumbing in userspace, the 6.1 BSP driver, and the 7.2 rewrite, but neither studied RK3588 DT wires encoder `rockchip,sram`/`rockchip,rcb-iova`; decoder RCB SRAM is wired, encoder RCB is optional/dormant, so the forward-port must treat missing encoder RCB backing as best-effort like the BSP and must not borrow decoder SRAM without TRM/vendor evidence — CODE-INSPECTED / MEASURED live procfs/sysfs / ONLINE-SURVEY-NEGATIVE.
- `` `2026-07-05-rga3-userptr-iommu-runtime-smoke.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §6 + Status (2026-07-08). Six 18:28 smoke runs pass; fallback attribution still indirect.
- `` `2026-07-05-rga3-userptr-iommu-design.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §4 (2026-07-08). Driver-owned contiguous-IOVA fallback design (guard band, `iommu_map_sg`, 32-bit/granule guards).
- `` `2026-07-05-rga3-scattered-iova-mechanism.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §3 (2026-07-08). Descending-IOVA fingerprint (`contiguous=0`), per-segment-not-coalesced; bounce trigger UNRESOLVED.
- `` `2026-07-05-rga3-memory-import-contract.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §2 (2026-07-08). Import-contract ABI (fd/userptr/phys/mmap); superseded-for-implementation by §4.
- `` `2026-07-04-librga-consumer-survey.md` `` — public `librga` users outside the current conformance set, including RKNN/RKNPU, GStreamer/RKNN, BELABOX GStreamer-MPP, Orbbec, OpenCV/RKAIQ capture, HDMI/RTSP capture, BrightSign-style RTSP/RKNN preprocessing, RetroArch/SDL/LVGL-style display paths, Weston/GStreamer-base/Xorg/Qt/pixman desktop patches, Rust/Zig/C#/G2D wrappers, and runtime wrappers, mostly reinforce RGB/NV12/NV21/RGBA crop preprocessing plus fd/virtual legacy blit/fill/display-rotate/simple-blend paths; no current Linux-media signal promotes RFBC64x4/AFBC32x8, per-channel rotation, tile alpha/pattern/color-key, or broad RGA2-Pro modes into the required RK3588 profile, so the rewrite now rejects the RGA2-Pro FBC source modes with `-EOPNOTSUPP` — UNVERIFIED public-source survey.
- `` `2026-07-04-rga3-im2d-error-irq.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §1 (2026-07-08). `INTR[0x2]` MMU-IRQ root cause + the three BSP-derived fixes (`13afe70c8271`/`6b9dba7abcd0`/`590c9ef297ce`).
