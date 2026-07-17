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

For promotion, status changes, and the repository handoff checklist, follow the
canonical [`CONTRIBUTING.md`](../CONTRIBUTING.md) workflow.

Trust tags state what kind of evidence supports each claim. Combine tags when a
finding mixes evidence types:

- **MEASURED** — observed on hardware or in a recorded run.
- **CODE-INSPECTED**, **CONFIG-INSPECTED**, or **SOURCE-INSPECTED** — checked
  directly against the named pinned source.
- **INFERRED** — a conclusion supported by the recorded evidence but not
  observed directly.
- **HYPOTHESIS** — a candidate explanation that still needs a discriminating
  test.
- **DESIGN** — proposed behavior or an implementation plan, not an observed
  result.
- **UNVERIFIED** — copied from a comment, commit, or other source but not yet
  checked.

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

- `` `2026-07-17-rga-session-close-uaf.md` `` — an ABI-probe test leak chained into a kernel Oops: `RGA_IOC_IMPORT_BUFFER` returns the positive handle as its retval, so the dma-buf probe's `if (!ret)` never released it (fixed to `if (ret >= 0)`), and on `/dev/rga` close `rga_mm_session_release_buffer()` force-frees session buffers ignoring their kref, so a buffer still referenced by another session (imports dedup globally) or an in-flight job is freed underneath a live reference; driver fix `linux-6.18-rkvenc-av1-fwport@bc086cbe03d7` drops the reference through the kref path and detaches `->session` when a reference survives — the exact faulting function is unproven (journal truncated, pstore empty) — MEASURED (the Oops) / CODE-INSPECTED / INFERRED (attribution).
- `` `2026-07-16-rockchip-bsp-driver-quality.md` `` — Rockchip's BSP is feature-strong and functionally effective on fixed hardware, but its private MPP/RGA/RKNPU stacks remain below mature mainline drivers in hostile-input validation, resource lifetimes, client isolation, framework integration, review traceability, and branch maintenance; the RKNPU deep dive finds a capable fixed vendor stack whose render-node ABI exposes/trusts kernel object pointers while the matching compiler/runtime are proprietary prebuilts, whereas upstream-derived areas such as DRM display are materially healthier — CODE-INSPECTED / SOURCE-INSPECTED / MEASURED / INFERRED for comparative ratings.
- `` `2026-07-13-rock5b-u-boot-fit-dtb-race.md` `` — controlled delay proves the missing FIT prerequisite; current Armbian Jammy and Noble images use the same Make 4.3 but coreutils 8.32 uses direct read/write while 9.4 first tries FICLONE and copy_file_range; KSpace exposed 64 Docker CPUs, 24 co-located runners, a host-bind-mounted U-Boot worktree, and an inferred `-j96`, while its backing filesystem remains unknown; includes the [source/trace appendix](evidence/2026-07-13-u-boot-fit-dtb-race/coreutils-copy-path-comparison.md), Mac container precedents, and a ready one-line Armbian test patch — MEASURED / SOURCE-INSPECTED / CONFIG-INSPECTED / INFERRED.
- `` `2026-07-11-rock5b-u-boot-four-way-comparison.md` `` — promoted → [`../boot-firmware/docs/version-comparison.md`](../boot-firmware/docs/version-comparison.md) (2026-07-11).
- `` `2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md` `` — stock Kodi 22 can auto-select the fork's RKMPP decoders through DRM PRIME without a Kodi patch; the PPA MPP runtime fixes missing parser registration, three FFmpeg packaging failures were fixed, and the AV1 MP4/MKV extradata flag fix is built/published but still needs an RK3588 playback re-test — MEASURED, except for the pending hardware re-test.
- `` `2026-07-09-ffmpeg-baseline-rk2-local-build-validation.md` `` — locally regenerated the `ffmpeg 7:8.1.2-1+rk2` source package from the byte-identical 8.1.2 orig tarball plus `packaging/ppa/ffmpeg-baseline/debian`, extracted that `.dsc`, and completed an arm64 binary build on the ROCK 5B; `fate-source` passed, `fate-filter-frei0r-filter` and `fate-filter-frei0r-filter-unaligned` both ran without the prior `Could not find module 'distort0r'` failure, 32 binary artifacts were produced, and the built standard binary exposes the expected RKMPP encoders/decoders; caveat: source-package accurate but not a clean Launchpad `sbuild` replica because `frei0r-plugins` was provided via extracted package + `FREI0R_PATH`, and local builds under `downloads/` need `GIT_CEILING_DIRECTORIES` to keep upstream `fate-source` from seeing the enclosing repo — MEASURED.
- `` `2026-07-09-rock5b-armbian-sd-boot-investigation.md` `` — consolidated ROCK 5B Armbian SD boot investigation: original 26.2.1 raw SD path stops after BL31 with `ddr-v1.18` and no HDMI, SD image/rootfs/`/boot` verify cleanly, 26.5.1 vendor kernel transplant does not fix the intact raw-loader case, zeroing SD sectors 64..32767 makes the same SD rootfs boot through known-good SPI, 26.5.1 vendor raw U-Boot initializes HDMI but still does not complete boot, and the next discriminator is writing the known-good-family 26.5.1 `current` raw artifacts to SD — MEASURED / SOURCE-INSPECTED / HYPOTHESIS for exact raw-loader preemption mechanism.
- `` `2026-07-08-armbian-26.2.1-bl31-handoff-hang.md` `` — Armbian 26.2.1 Minimal Debian 13 / 6.1.115 on ROCK 5B uses Armbian build commit `5abb97453`, Radxa U-Boot `6c807...`, RK3588 DDR blob `v1.18`, and a vendor U-Boot config with `CONFIG_DISABLE_CONSOLE=y`, so the UART stop after BL31 handoff does not by itself prove BL33 crashed; the card write and `/boot` payload verify cleanly, a 26.5.1 vendor kernel/initrd transplant still failed, disabling `/boot/boot.scr` still hung instead of falling through to NVMe, but backing up and zeroing the SD raw-loader gap at sectors 64..32767 made the SD boot successfully via the known-good SPI path; Radxa source diff `6c807...`→`39cd...` does not touch ROCK 5B files, while Armbian `1bac6d97` switches RK3588 DDR blob v1.18→v1.20 — MEASURED / SOURCE-INSPECTED / HYPOTHESIS for exact raw-loader preemption mechanism.
- `` `2026-07-08-blit-precision-nir-migration.md` `` — the clean home for the wide-blit precision fix is **NIR, not TGSI**, because NIR has `nir_load_pixel_coord` (`SYSTEM_VALUE_PIXEL_COORD`) as a first-class integer intrinsic while TGSI's only fragment position is float `POSITION` (adding an integer one means growing a legacy IR), and NIR also has `nir_load_frag_coord`, so the whole shader lives in one `nir_builder` with no `tgsi_to_nir` round-trip; the in-review !42679 is authored in TGSI for good reasons (inherited `u_blitter`/`ureg` code, exactness reachable via downstream `nir_lower_frag_coord_to_pixel_coord`, surgical/arch-gateable) but still routes through a `u2f32` round-trip and fixes only the TXF path. The maintainer's `nir_blit_helpers.c` diff migrates the blit FS generator to `nir_builder` (the enabling refactor) but is **not** the precision fix — as written it reads the interpolated `VARYING_SLOT_VAR0` coord, so on its own it leaves the drift in place (nothing "regresses" since neither approach is landed; the exactness has to be folded into the shader it generates). The fix (both fetch modes): pass the affine map `src = scale·dst + translate` as **flat** coefficients and reconstruct per fragment — TXF → `load_pixel_coord` + int translate (bit-exact), TEX → `ffma(load_frag_coord, scale, translate)` (float ALU, ~2⁻²⁴); fixing only TXF leaves scaled wide blits drifted (progressive warp) and a consistency hazard where 1:1 copies that fall back to TEX-nearest still corrupt — CODE-INSPECTED (diff) / DESIGN (proposed fix). Builds on [`../video-libraries/mesa/docs/blit-precision.md`](../video-libraries/mesa/docs/blit-precision.md).
- `` `2026-07-08-arm-mali-blob-interp-drift-bit-identical-to-mesa.md` `` — promoted → [`video-libraries/mesa/docs/arm-mali-blob-stack.md`](../video-libraries/mesa/docs/arm-mali-blob-stack.md) "Runtime Results" (2026-07-08). ARM blob drift is bit-identical to Mesa → the drift is hardware.
- `` `2026-07-08-armbian-builder-setup.md` `` — the YSP ROCK 5B Armbian builder is the Noble 24.04 aarch64 VMware VM (5 vCPU / 7.7 GiB / root LV grown 48→97 GB), a supported *native* `armbian/build` host (arm64→arm64, `gcc 13.3.0`, no QEMU; `compile.sh` self-relaunches under sudo, no passwordless sudo); for `rock-5b` (family `rockchip-rk3588`) the branch map is legacy 5.10 / vendor 6.1 BSP (`rk-6.1-rkr5.1`→6.1.115) / **current = 6.18 mainline (default, the forward-port target)** / edge 7.1 / bleedingedge 7.2, and Ubuntu 26.04 = `resolute` (`supported`); an unpatched `kernel` build pulls prebuilt `.deb`s from `ghcr.io/armbian/os/…` in 0:19 so only `ARTIFACT_IGNORE_CACHE=yes` or a userpatch hash-change forces local compilation, and 8 GB RAM clears Armbian's BTF gate by only ~19–45 MiB so BTF-link survival is unproven — MEASURED / CONFIG-INSPECTED / BTF-risk HYPOTHESIS.
- `` `2026-07-08-arm-mali-blob-gbm-setversion-kernel-oops.md` `` — promoted → [`video-libraries/mesa/docs/arm-mali-blob-stack.md`](../video-libraries/mesa/docs/arm-mali-blob-stack.md) "Runtime Results" (2026-07-08). GBM path NULL-derefs `drm_setversion` and wedges DRM; use the X11-client reproducer.
- `` `2026-07-07-arm-mali-blob-reproducer-readiness.md` `` — promoted → [`video-libraries/mesa/docs/arm-mali-blob-stack.md`](../video-libraries/mesa/docs/arm-mali-blob-stack.md) "Runtime Results" (2026-07-08). GLES stack wired, link `-lmali`, Vulkan unavailable from the g6p0 repos.
- `` `2026-07-07-rock5b-spi-sd-boot-chain.md` `` — ROCK 5B SPI contains a valid Armbian/Radxa U-Boot image matching the packaged `rkspi_loader.img`; the Radxa Bookworm SD card has bootable p2/p3, p3 contains standard extlinux with matching root UUID and a Rock 5B DTB, so SPI U-Boot should be able to attempt the SD kernel, but the later Armbian SD experiment showed the "SPI bypasses raw SD loader" assumption is not reliable: zeroing the SD raw-loader gap can be necessary to force the known-good SPI path — MEASURED / INFERRED where noted.
- `` `2026-07-06-rga3-dmabuf-scatter-bsp-contract.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §5 (2026-07-08). dma-buf single-span DESIGN-CONSTRAINT vs BSP.
- `` `2026-07-06-ffmpeg-rockchip81-package-validation.md` `` — promoted → [`video-libraries/ffmpeg/docs/rockchip81-package-validation.md`](../video-libraries/ffmpeg/docs/rockchip81-package-validation.md) (2026-07-08). Package build + on-board smoke passes and the four failures (incl. the incomplete-`/usr`-MPP decode root cause).
- `` `2026-07-05-rkvenc-rcb-sram.md` `` — promoted → [`kernel-drivers/mpp/docs/rcb-sram.md`](../kernel-drivers/mpp/docs/rcb-sram.md) (2026-07-08). RKVENC RCB is ABI-plumbed but not SRAM-backed in DT; keep encoder RCB alloc best-effort, don't borrow decoder SRAM.
- `` `2026-07-05-rga3-userptr-iommu-runtime-smoke.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §6 + Status (2026-07-08). Six 18:28 smoke runs pass; fallback attribution still indirect.
- `` `2026-07-05-rga3-userptr-iommu-design.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §4 (2026-07-08). Driver-owned contiguous-IOVA fallback design (guard band, `iommu_map_sg`, 32-bit/granule guards).
- `` `2026-07-05-rga3-scattered-iova-mechanism.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §3 (2026-07-08). Descending-IOVA fingerprint (`contiguous=0`), per-segment-not-coalesced; bounce trigger UNRESOLVED.
- `` `2026-07-05-rga3-memory-import-contract.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §2 (2026-07-08). Import-contract ABI (fd/userptr/phys/mmap); superseded-for-implementation by §4.
- `` `2026-07-04-librga-consumer-survey.md` `` — promoted → [`kernel-drivers/rga/userspace-consumers.md`](../kernel-drivers/rga/userspace-consumers.md) (2026-07-08). Public consumer survey (RKNN-dominated required profile; RGA2-Pro/FBC tail modes rejected `-EOPNOTSUPP`).
- `` `2026-07-04-rga3-im2d-error-irq.md` `` — promoted → [`kernel-drivers/rga/userptr-iommu.md`](../kernel-drivers/rga/userptr-iommu.md) §1 (2026-07-08). `INTR[0x2]` MMU-IRQ root cause + the three BSP-derived fixes (`13afe70c8271`/`6b9dba7abcd0`/`590c9ef297ce`).
