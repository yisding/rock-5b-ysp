# Source trees — reconstructing every cited tree

Reference appendix. Every `file:line` cite in `docs/` (and most in `video-libraries/ffmpeg/`,
`apps/gnome-remote-desktop/`) resolves against a specific tree state. This doc pins
each of those trees and gives the reconstruction recipe, so the anchors stay
auditable without access to the original dev box. Dev-box paths
(`/home/yi/Code/…`) appear below **only** as provenance records of where the
work was done; every tree is reconstructible from public sources + this repo's
patches unless explicitly marked otherwise.

| # | Tree | Anchors for | Pin |
|---|------|-------------|-----|
| 1 | Forward-port kernel tree | [kernel driver guide](../kernel-drivers/docs/how-the-drivers-work.md), [uAPI guide](../kernel-drivers/docs/dev-uapis.md), [forward-port guide](../kernel-versions/docs/vendor-forward-port.md), [vendor delta](../kernel-drivers/docs/vendor-delta.md), [device-tree guide](../kernel-drivers/docs/device-tree.md); DKMS `KSRC` | `v6.18` + `kernel-drivers/patches/rk3588-rkvenc2-01…` (+ `02` for DT) |
| 2 | Audited tree (BSP audit) | [BSP audit](../kernel-drivers/docs/bsp-audit.md), `kernel-drivers/patches/cleanup-draft/` line numbers | parent of `56e403ede081` = `5614909e5803` |
| 3 | `$OURS` / `$BSP` measurement pair | [vendor delta](../kernel-drivers/docs/vendor-delta.md) "Reproduce the count" | tree 1 vs `rockchip-linux/kernel` `develop-6.1` @ `b4ef083dc0c3` |
| 4 | Userspace libraries + FFmpeg | [userspace library guide](../vendor-libraries/docs/how-the-userspace-libs-work.md), `ffmpeg/*` | table in §4 |
| 5 | GNOME Remote Desktop | `apps/gnome-remote-desktop/docs/capture-path.md`, GRD PPA packaging | tag `50.1` = `5ef1a2aa6bef`; anchor/full-series base = `c14e09ef67e9`; current PPA source = `rdp-handover-reconnect-v2@eb91daf476dc`, see §5 |
| 6 | Register recipes | kernel/userspace driver docs | MPP HAL sources + RK3588 TRM (§6) |
| 7 | Canonical uAPI headers | kernel uAPI docs | inside patch 01 (§7) |
| 8 | Clean-room rewrite drivers | [rewrite-driver track](../kernel-drivers/docs/rewrite-drivers.md) | local branch `rk3588-rewrite-6.18` @ `563f329dd8c4` + branch `rk3588-rewrite-mainline` rebased to official `v7.2-rc2` @ `856743fc3c3d`, including the July 15 MPP/RGA lifetime, DMA/IOMMU, topology, recovery, and diagnostic hardening; see §8 |
| 9 | Upstream-style V4L2 RGA3 comparison | [rewrite-driver track](../kernel-drivers/docs/rewrite-drivers.md) §1 | `yisding/linux-rock5b` branch `rk3588-rewrite-mainline` history at `180ee72a9a80`, path `drivers/media/platform/rockchip/rga/`, see §9 |
| 10 | Expanded Rockchip conformance bundle | [kernel-driver rewrite-conformance](../kernel-drivers/tests/rewrite-conformance.md) § Expanded conformance bundle | tracked seed under `kernel-drivers/tests/conformance/`; runtime bundle defaults to external `../rockchip-conformance`, see §10 |
| 11 | RK3588 AV1 / VSI-IOMMU comparison | [AV1 kernel note](../kernel-drivers/av1/docs/av1-rk3588.md), FFmpeg AV1 note | local observations on 2026-07-02: forward-port tree `rk3588-rewrite-6.18` @ `a81feb1e2971`; sibling `../kernel/linux` `rk3588-rewrite-mainline` @ `839de47fcda2`; vendor BSP `rockchip-linux/kernel` `develop-6.1` @ `b4ef083dc0c3`, see §11 |

---

## 1. The forward-port tree (the primary anchor tree)

Everything in the kernel-driver docs that cites `mpp_*.c:NNN`, `rga_*.c:NNN`, or a
`compat/` header line resolves against **pristine mainline `v6.18` plus this
repo's two patches**:

```bash
git clone --branch v6.18 --depth 1 \
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.18
cd linux-6.18
git am /path/to/rock-5b-ysp/kernel-drivers/patches/rk3588-rkvenc2-01-vcodec-rga-drivers.patch
git am /path/to/rock-5b-ysp/kernel-drivers/patches/rk3588-rkvenc2-02-vcodec-rga-dt.patch   # DT anchors only
```

(`git am` works — both files are `git format-patch` output; `git apply` works
too, see [`kernel-drivers/patches/README.md`](../kernel-drivers/patches/README.md).) Driver anchors need only
patch 01; device-tree.md's DT anchors need patch 02. Note patch 02 *applies* to
pristine `v6.18` at the git level (it was committed there), but the resulting
DT only **compiles** on a tree that also carries Armbian's `media-0001` nodes —
its `&vdec0`/`&vdec1` overrides reference labels vanilla 6.18 doesn't define
([Armbian packaging guide](../packaging/docs/armbian-packaging.md), [vanilla-kernel guide](../kernel-versions/docs/vanilla-kernel.md)). For
*anchoring* line cites that doesn't matter.

Provenance: the patches were generated from the dev worktree
`/home/yi/Code/kernel/linux-6.18-rkvenc` (branch `rkvenc-fwport-6.18`), commits

```
924f4232546d  video: rockchip: RK3588 vendor MPP (rkvenc2/rkvdec2) + RGA3/RGA2 drivers  → patch 01
5614909e5803  arm64: dts: rockchip: rk3588: VEPU580 encoder, rkvdec2 decoder, RGA3 nodes → patch 02
```

**One deliberate divergence from commit `924f4232546d`:** rock-5b-ysp commit
`23cbe21` later folded the encoder **devfreq re-guard** directly into the
validated patch file (9 one-line, 1:1 replacements in `mpp_rkvenc2.c`:
`#ifdef CONFIG_PM_DEVFREQ` → `#if defined(CONFIG_PM_DEVFREQ) &&
defined(CONFIG_ROCKCHIP_MPP_RKVENC2_DEVFREQ)`), enabling the OOT/DKMS build
([`packaging/dkms/README.md`](../packaging/dkms/README.md),
[forward-port guide](../kernel-versions/docs/vendor-forward-port.md) §B). Because every replacement is
line-for-line, **all line numbers are unaffected** — a tree built from patch 01
anchors identically to the pre-guard dev tree. (The trailing comment text on
those 9 lines differs cosmetically between the patch — `/* governor.h: in-tree
only */` — and the dev worktree — `/* DKMS: drop private governor.h dep */`;
byte-level diffs of `mpp_rkvenc2.c` against the dev tree will show exactly
those 9 lines.)

This same tree is the **DKMS source input**: `packaging/dkms/build-deb.sh:14`
stages driver source from `KSRC` (default: the dev-box path
`…/linux-6.18-rkvenc/drivers/video/rockchip`) — point `KSRC` at
`<reconstructed-tree>/drivers/video/rockchip` on any other machine.

## 2. The audited tree (bsp-audit.md line-number pin)

[BSP audit](../kernel-drivers/docs/bsp-audit.md) states its own pin: every `line:` number is
against **the forward-port HEAD before any cleanup patch is applied — the
parent of commit `56e403e`**. Concretely:

- Audit-assembly commit: `56e403ede081` "WIP: BSP audit cleanup edits
  (machine-generated, compile-tested)", sole commit on branch
  `bsp-audit-cleanup` of the dev linux repo — the working source of both
  [`kernel-drivers/patches/cleanup-split`](../kernel-drivers/patches/cleanup-split) and
  [`kernel-drivers/patches/cleanup-draft`](../kernel-drivers/patches/cleanup-draft).
- Its parent: `5614909e5803` — i.e. **exactly the forward-port tree of §1**
  (driver files identical to `v6.18` + patch 01, modulo the 9 same-line
  devfreq-guard rewrites noted above, which shift nothing).

So to re-derive any bsp-audit.md or cleanup-draft line number: build the §1 tree and
count there. After a cleanup patch lands in a file, later lines in that file
drift (bsp-audit.md's own warning); the stable anchor is function name + nearby
code.

## 3. The vendor-delta.md `$OURS` / `$BSP` measurement pair

[vendor delta](../kernel-drivers/docs/vendor-delta.md) "Reproduce the count" diffs two directories:

| Var | Tree | Pin |
|-----|------|-----|
| `$OURS` | `<forward-port tree §1>/drivers/video/rockchip` | dev-box provenance: `/home/yi/Code/kernel/linux-6.18-rkvenc/drivers/video/rockchip` |
| `$BSP` | `rockchip-linux/kernel` branch `develop-6.1`, `drivers/video/rockchip/` | clean checkout, observed @ `b4ef083dc0c3` (2026-07-01) |

The BSP donor floats (it is a live vendor branch); vendor-delta.md already notes the
measured integers drift against a future BSP while the ≈580-line / ≈1.7%
headline holds. If you need the *exact* counts to reproduce, use the
`b4ef083dc0c3` state of `develop-6.1`. (`radxa/kernel` `linux-7.0.11` also
exists as a dev-box reference checkout @ `45943c54ded4` but is **not** the
donor and is not cited by any doc.)

## 4. Userspace pins — libmpp, librga, FFmpeg

| Component | Repo | Pin | Cited by |
|-----------|------|-----|----------|
| libmpp (v1.3.9 how-doc study tree) | `rockchip-linux/mpp` | **v1.3.9** (how-the-userspace-libs-work.md:9). Commit-level pin **unrecorded** — see note below | how-the-userspace-libs-work.md Part A, [`video-libraries/ffmpeg/README.md`](../video-libraries/ffmpeg/README.md) |
| libmpp (KMPP-aware study tree) | `mpp-rockchip` | `1375813cbbae5ad6861b166475dd8fb672183220` — the KMPP-bearing tree the architecture/KMPP/Rust docs were read against; **distinct** from the v1.3.9 how-doc tree above | [`mpp-library-architecture.md`](../vendor-libraries/mpp/docs/mpp-library-architecture.md), [`mpp-kmpp-reverse-engineering.md`](../vendor-libraries/mpp/docs/mpp-kmpp-reverse-engineering.md), [`mpp-rust-rewrite-assessment.md`](../vendor-libraries/mpp/docs/mpp-rust-rewrite-assessment.md) |
| libmpp (PPA packaging tree) | `mpp-rockchip` | `1375813c`, exported as `1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1` with unused Windows binaries removed from the orig tarball | [`packaging/ppa/README.md`](../packaging/ppa/README.md) |
| librga source (fixed tree) | `github.com/yisding/librga` | branch `main`, tip `a6322179c944aced42e326519cd89483bf9da26b` (2026-07-03); preserves the `2cffdf6f332c` JeffyCN history, then `cc39281` as the latest-vendor-source layer matching `yisding/librga-mirror@32c3bf1`, then nyanmisaka/local fixes | [`vendor-libraries/rga/docs/librga-p010-p210-rkrga.md`](../vendor-libraries/rga/docs/librga-p010-p210-rkrga.md), [gotchas](./gotchas.md) |
| librga historical source base (study tree) | `tsukumijima/librga-rockchip` (JeffyCN `linux-rga-multi` lineage) | `2cffdf6f332c` (`v2.2.0`, the 2026-01-21 merge of `JeffyCN/mirrors:linux-rga-multi`); **recorded**, every librga file/function cite in how-the-userspace-libs-work.md re-verified against it 2026-07-01 (how-the-userspace-libs-work.md:11-14). Also the last open vendor-history tip used as the fixed-tree base above | how-the-userspace-libs-work.md Part B, [gotchas](./gotchas.md) |
| librga prebuilt | `airockchip/librga` | `2b32edc` ("Update librga version to 1.10.6_[3]") | ffmpeg/README.md librga row |
| ffmpeg-rockchip (documented build) | `nyanmisaka/ffmpeg-rockchip` | `40c412daccf0` (2026-04-23); preserved locally as branch `backup-pre-upgrade-master` | ffmpeg/README.md, [`video-libraries/ffmpeg/docs/implementation-comparison.md`](../video-libraries/ffmpeg/docs/implementation-comparison.md) |
| ffmpeg-rockchip-81 (master-era rebased successor) | `github.com/yisding/ffmpeg-rockchip-81` | current branch `main` = `be367abfe670` (`n8.2-dev-2123-gbe367abfe6`, 2026-07-11), **not FFmpeg 8.1.x**; exported review series remains `6cf02ab253` over original `upstream@87bd15dc3c`; package-validation tree remains local `refactor/section-c@75638e7f0b17` | [`video-libraries/ffmpeg/docs/fix-candidates.md`](../video-libraries/ffmpeg/docs/fix-candidates.md), [`video-libraries/ffmpeg/docs/rebase-notes.md`](../video-libraries/ffmpeg/docs/rebase-notes.md), [`video-libraries/ffmpeg/docs/submission-plan.md`](../video-libraries/ffmpeg/docs/submission-plan.md), [`video-libraries/ffmpeg/patches`](../video-libraries/ffmpeg/patches), [`findings/2026-07-06-ffmpeg-rockchip81-package-validation.md`](../findings/2026-07-06-ffmpeg-rockchip81-package-validation.md) |
| ffmpeg-rockchip real 8.1.2 replay | local branch `rockchip-8.1.2` in `github.com/yisding/ffmpeg-rockchip-81` | `53b3551b9176` (`n8.1.2-63-g53b3551b91`), 63 commits over canonical `n8.1.2@38b88335f99e`; clean worktree `/home/yi/Code/ffmpeg/ffmpeg-rockchip-812` | [`video-libraries/ffmpeg/docs/rockchip-812-jellyfin-comparison.md`](../video-libraries/ffmpeg/docs/rockchip-812-jellyfin-comparison.md), [`video-libraries/ffmpeg/docs/rebase-notes.md`](../video-libraries/ffmpeg/docs/rebase-notes.md) §7 |
| Jellyfin FFmpeg Rockchip reference | `jellyfin/jellyfin-ffmpeg` | `jellyfin@455bfe539220` (`v8.1.2-1-13-g455bfe53`); effective comparison applied all 96 Debian patches in scratch worktree `/home/yi/Code/ffmpeg/jellyfin-ffmpeg-applied` | [`video-libraries/ffmpeg/docs/rockchip-812-jellyfin-comparison.md`](../video-libraries/ffmpeg/docs/rockchip-812-jellyfin-comparison.md), [`video-libraries/ffmpeg/docs/jellyfin-ffmpeg-patch-survey.md`](../video-libraries/ffmpeg/docs/jellyfin-ffmpeg-patch-survey.md) |
| FFmpeg upstream release | `FFmpeg/FFmpeg` | tag `n8.1.2` = `38b88335f99e` (2026-06-17) | `video-libraries/ffmpeg/docs/implementation-comparison.md` baseline; the PPA/GRD ABI base |
| FFmpeg upstream master (rebase base) | `FFmpeg/FFmpeg` | `87bd15dc3c` = `n8.2-dev-2058-g87bd15dc3c` | `video-libraries/ffmpeg/docs/fix-candidates.md`, `video-libraries/ffmpeg/docs/rebase-notes.md` |

**How the upstream FFmpeg pins and replay branches relate:** `n8.1.2`
(`38b88335f99e`) sits on
the `release/8.1` branch; `87bd15dc3c` is FFmpeg `master` well past the 8.1
fork. Their merge-base is `67c886222f` ("Bump versions for release/8.1") — the
8.1 branch point. The repository's `main` continued to `be367abfe670`, while
the separate `rockchip-8.1.2` branch replays the same ten core Rockchip files
onto the release ABI. The full topology and both replay procedures live in
[`video-libraries/ffmpeg/docs/rebase-notes.md`](../video-libraries/ffmpeg/docs/rebase-notes.md).

> **The pins to watch.**
> - **libmpp v1.3.9 how-doc tree — unrecorded (flagged, not invented).**
>   how-the-userspace-libs-work.md records only "v1.3.9". No commit hash was
>   written down at study time, and the KMPP-aware/PPA-export tree
>   (`mpp-rockchip` @ `1375813cbbae`) is a *different* state.
>   **UNVERIFIED** which exact commit how-the-userspace-libs-work.md's Part A
>   line numbers were read against; treat its anchors as "v1.3.9-era, verify
>   against your checkout". (The architecture/KMPP/Rust docs, by contrast, record
>   their own `1375813cbbae` pin — see the study-tree row above.)
> - **librga — now recorded.** how-the-userspace-libs-work.md's Part B anchors
>   are pinned to `tsukumijima/librga-rockchip` `2cffdf6f332c` (`v2.2.0`, the
>   2026-01-21 JeffyCN `linux-rga-multi` merge) and were **re-verified against it
>   2026-07-01** (how-the-userspace-libs-work.md:11-14). The fixed dev tree
>   (`github.com/yisding/librga` `main` @ `a632217`) preserves that
>   `2cffdf6f332c` open history, adds one latest-release source layer matching
>   `yisding/librga-mirror@32c3bf1`, then the P010/P210 fix commits. Treat old
>   file/line anchors as `2cffdf6f332c`-era unless a doc explicitly names the
>   fixed tree.

## 5. GNOME Remote Desktop base

All `file:line` anchors in
[`apps/gnome-remote-desktop/docs/capture-path.md`](../apps/gnome-remote-desktop/docs/capture-path.md)
(and the complete patch series in `apps/gnome-remote-desktop/patches/`) resolve
against **upstream GRD commit `c14e09ef67e916ae83a4eddee6a56591078e78e0`**
(`50.1` + 16), *before* this repo's patches. Both the full series and the
backend-only `0001`–`0008` subset require this base: `0003` needs upstream
`cf250ed`, while `0009` reverts `5230bf3`. Pristine **tag `50.1` =
`5ef1a2aa6bef`** is recorded for lineage but is not a valid replay base for the
exported patches.

The public shipping branch is
[`rdp-handover-reconnect-v2`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/commits/rdp-handover-reconnect-v2),
tip `eb91daf476dc1c4ba23ccfdd8c077b8b83e84773`. It carries the backend,
backpressure guard, GNOME 50.2's official `5230bf3` revert, and the corrected
handover ownership/coalescing series. See
`apps/gnome-remote-desktop/patches/README.md` and
[`apps/gnome-remote-desktop/docs/profiling.md`](../apps/gnome-remote-desktop/docs/profiling.md).

The current GRD PPA source package exports that clean commit directly as
`50.1+rkmpp+git20260714.eb91daf-0ubuntu1~exp1`; no source delta is applied.
The historical `a59c904` dirty snapshot remains reconstructible: commit
`a59c904c99088235eb4de31ca340747d334494f3` plus the delta at
[`packaging/ppa/gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch`](../packaging/ppa/gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch).
That legacy patch was generated from the worktree used for the
`50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1` source export and
`git apply --check` passed against a clean archive of `a59c904c99088235eb4de31ca340747d334494f3`.

## 6. Where the register recipes live

The kernel drivers never construct codec register values
([kernel driver guide](../kernel-drivers/docs/how-the-drivers-work.md) §9 — "the userspace library knows the
recipe"). The recipes live in:

- **MPP HAL sources** — `rockchip-linux/mpp` `mpp/hal/rkenc/` +
  `mpp/hal/rkdec/` (per-codec register builders `hal_h264e`, `hal_h265e`,
  `hal_h264d`, `hal_h265d`; how-the-userspace-libs-work.md §A3). Register-layout headers sit next to
  each HAL (VEPU580 / VDPU381 register structs).
- **RK3588 TRM** — the address map in device-tree.md ("Address Mapping" table, the
  `fdc40000`-vs-`fdc48000` resolution). Reference gap: the docs cite "the
  RK3588 TRM" without recording the exact TRM part/version number —
  **UNVERIFIED** which TRM revision was consulted; record it here when known.

## 7. Canonical uAPI headers (dev-uapis.md's definitions)

Both headers are included **inside patch 01**, so the §1 reconstruction gives you the
exact bytes dev-uapis.md documents:

| Header | In-tree path (after patch 01) | Size in patch |
|--------|-------------------------------|---------------|
| MPP uAPI | `include/uapi/linux/rk-mpp.h` | +82 lines (`enum MPP_DEV_COMMAND_TYPE`, `struct mpp_request`, `MPP_IOC_CFG_V*`, `MPP_FLAGS_*`) |
| RGA uAPI | `drivers/video/rockchip/rga3/include/rga.h` | +1007 lines (`rga_req`, `RGA_IOC_*`, image descriptors) |

Note the **rewrite-driver uAPI extensions** (`MPP_CMD_SET_ERR_REF_HACK`,
`MPP_FLAGS_REG_OFFSET_ALONE`, `MPP_FLAGS_POLL_NON_BLOCK`) are **not** in patch
01's `rk-mpp.h` — they exist only in the rewrite commit documented in
[rewrite-driver track](../kernel-drivers/docs/rewrite-drivers.md) §4 and cross-folded into
[uAPI guide](../kernel-drivers/docs/dev-uapis.md).

## 8. Rewrite-driver tree

The clean-room MPP/RGA rewrite ([rewrite-driver track](../kernel-drivers/docs/rewrite-drivers.md))
is reconstructible from the committed local branch tips targeting
`github.com/yisding/linux-rock5b` as
of 2026-07-15:

- branch `rk3588-rewrite-6.18`, commit `563f329dd8c4` ("media: rockchip:
  harden rewrite drivers"), committed in the dev worktree
  `/home/yi/Code/kernel/linux-6.18-rkvenc`. The sibling 6.18 forward-port
  oracle referenced by this rewrite track was
  `/home/yi/Code/kernel/linux-6.18-rkvenc-av1-fwport` at
  `rkvenc-fwport-6.18` tip `e059aad8d68b` when these pins were recorded.
- branch `rk3588-rewrite-mainline`, commit `856743fc3c3d` ("media: rockchip:
  harden rewrite drivers"), rebased to official kernel.org `v7.2-rc2`
  in the sibling worktree `/home/yi/Code/kernel/linux`. The pre-rebase tip is
  preserved as `ysp-backup/rk3588-rewrite-mainline-before-7.2-rc2`.

Both trees contain `drivers/video/rockchip/mpp-rewrite/` and
`drivers/video/rockchip/rga-rewrite/`. The 6.18 tree is the line-count source
for rewrite-drivers.md's current rewrite-size snapshot; the mainline tree is the
post-6.18 DT/wiring state. The 6.18 pin also includes the Rock 5B DTB
self-containment fix: disabled RK3588 `vdec0`/`vdec1` decoder nodes, decoder
IOMMUs, and decoder SRAM pools in the base DTS, allowing the board include to
retype them to RKMPP without an external Armbian media-label dependency. These
pins include the large RGA feature-coverage
push, RGA request-config staging and reconfiguration
resource/acquire-fence/gauss replacement coverage, request-config ioctl
acquire-fd ownership/no-release-fence-export coverage, configured request
cancel/file-close cleanup, legacy async blit and modern request-submit
acquire/release-fence coverage, legacy sync blit wait/no-fence ioctl coverage,
RGA async close cleanup for jobs pending on
acquire fences and jobs queued on hardware, last-hardware pending-acquire
cleanup, RGA3 pattern-channel rotate rejection, mixed-task RGA3-to-RGA2
core handoff/requeue coverage, the RK3588
`im2d_slt` RGB/RGBA three-channel alpha-blend coverage, and the debugfs
scheduler-core counters needed to check RGA2/RGA3 forced-core and
load-balancing behaviour on hardware, followed by focused MPP coverage for
selected-core removal races,
`RELEASE_FD`, nonblocking poll, public `RESET_SESSION`/file-close cleanup,
hardware-active reset cleanup, and
CCU coordinator removal cleanup for queued and active dependent-core jobs, plus
RGA2 packed-YUV422 color-fill coverage, packed-YUV420 fill emission, and
Y4/Y8 dither-output coverage, BPP palette source coverage, current
RGB-to-Y4/Y8 full-CSC dither-output coverage, AFBC-to-AFBC ffmpeg filter
copy coverage, and `immakeBorder()` reflect/wrap top/bottom and left/right
side-edge command coverage, plus RGA2 OSD external-flag, default-background,
channel-invert, invert-calibration, and external-color register coverage for
current `imosd` requests, plus MPP DT `rockchip,normal-rates` application
through the public clock framework, plus RGA2 `IM_PRE_INTR` read/write line
interrupt programming and line-only IRQ handling for current `librga` requests,
plus aggregate and per-core MPP/RGA debugfs `hw_total_ns*` and `hw_max_ns*`
counters plus the YSP `debugfs-counter-check.sh` gate for hardware busy-time
evidence during rewrite-vs-forward-port runs,
plus KUnit coverage for per-core timing-counter routing and warning-free RGA
scheduler KUnit stack usage, plus RGA2 packed-YUV420 fill emission for all four
packed orderings, plus named and matrix JeffyCN GStreamer legacy
`c_RkRgaBlit()` conversion coverage for RGB-family/NV16/NV61-to-NV12,
NV12/NV21/NV16/NV61/compact-10-bit decoder output to RGB-family, compact
NV12_10LE40/NV16_10LE40 decoder output to scaled 8-bit NV12/NV16, and planar
I420/YV12 RGA2 fallback profiles, plus explicit 8-bit decoder-output coverage
for the GStreamer RGBA/BGRA/RGBx/BGRx diagnostic formats, plus GStreamer
180/270-degree public rotation-value coverage, plus named RKNN/RKNPU RGA3
preprocessing coverage for RGB888 resize, RGB888-to-NV12 resize/convert, and
NV12/NV21-to-RGB resize/convert profiles, plus RGBA crop/letterbox resize
coverage for the same public RKNN/RKNPU profile, plus direct `librga-smoke`
coverage for an `rkmppenc`-shaped fd-backed crop/CSC/resize
acquire-fence/release-fence chain, plus VP9 RKVDEC fd-to-IOVA register
translation/validation KUnit coverage, plus
`MPP_CMD_SET_ERR_REF_HACK` initialized-session copy/discard KUnit coverage for
the current libmpp VDPU382 probe path, plus legacy RGA flush/result no-op ioctl
dispatch KUnit coverage for current librga's post-blit compatibility path, plus
dormant MPP batch-server wait-array recognition/rejection with `-EOPNOTSUPP`,
RGA2-Pro RFBC64x4/AFBC32x8 source profiles now rejected with `-EOPNOTSUPP`
instead of carrying an executable FBCIN path, plus RGA3 userptr RGA userptr-IOMMU fallback mapping
through a driver-owned contiguous IOMMU IOVA while keeping dma-buf imports
fail-closed unless they resolve to one 32-bit-safe segment, plus
`rk_rga_rewrite/userptr_iommu/{attempt,ok,active,force_remap}` debugfs attribution
for development/runtime validation, and the
RKVDEC2 CCU-mode update that
keeps HARD opt-in while the RK3588 DT selects BSP-style soft CCU, plus a named
RGA direct-buffer classifier and KUnit coverage for current `librga`/GStreamer
direct fd-vs-virtual-address encoding, plus Rockchip IOMMU `map_pages`/
`unmap_pages` count handling for dma-buf mappings that cross a 4 MiB page-table
boundary, plus zero-count RGA import/release buffer-pool KUnit coverage that
preserves the BSP-style valid-pointer no-op and null-pointer `-EFAULT`
boundary, plus RGA3 display-tail BGRA partial alpha-blend and RGB565
180-degree command-emission coverage plus RGA2 XRGB 270-degree command-emission
coverage for the opt-in public UI/display smoke shape, plus explicit invalid
public scheduler-core mask rejection coverage for bitblit, fill, palette, and
update-palette request shapes. The 6.18 branch also has the forward-port recovery cleanup that moves
the Rockchip IOMMU hooks into `include/soc/rockchip/rockchip_iommu.h`, restores
real fault masking/pagefault-done/reset hooks for the BSP-derived MPP driver,
adds 32-bit `MPP_IOC_CFG_V1` compat parsing, propagates IOMMU-refresh failures
through reset paths, and records minimal vendor DT bindings for the RKMPP/RGA
nodes. The latest pins also route the rewrite MPP/RGA IOMMU fault handlers
through the Rockchip provider-local public hook. MPP deliberately does not use
the legacy generic `iommu_set_fault_handler` fallback because it is set-once
and cannot be safely unregistered from the long-lived default DMA domain;
MPP and RGA cores with an attached domain fail probe when the provider hook is
unavailable. RGA now also requires an exact physical source match inside a
shared domain and clears every core's provider callback independently; provider
unregistration waits for callbacks already running in the IOMMU IRQ path. Its
queue-on-hardware declaration is no longer hidden inside the KUnit-only block,
so a mainline configuration with RGA KUnit disabled also compiles. RGA
acquire-fence callbacks now use the fence-lock-held status helper instead of
recursively locking from callback context. Abort also atomically transfers each
waiter and delays completion until the pending count's callback-arming sentinel
and callback shares drain, so last-core removal cannot release the shared work
reference while submit is still registering callbacks.
For HARD-CCU decoder faults, the forward port preserves the exact physical
provider source but derives the software recovery owner from that source
link's `CFG_ADDR` descriptor IOVA. If no active same-coordinator job matches,
it schedules any active HARD-CCU peer so the CCU force-stop and dependent-job
abort path still runs rather than targeting only an empty per-core job slot.
The software owner is published with one-copy semantics and ordered ahead of
the `CFG_DONE` start doorbell, closing the immediate descriptor-fault window.
If that peer's run lock is contended, the abort path now queues immediate work
holding the exact active-job and hardware references; the worker rechecks the
target after taking the lock, avoiding both the ordinary 500 ms timeout delay
and an abort of a replacement job. The target snapshot now precedes the failed
lock attempt, and both immediate and deferred paths cancel the timeout only
after claiming that exact job, so a stale abort cannot strip a replacement
job's watchdog.
MPP dma-buf translation also now proves that the mapped SG entries form one
full-size byte-contiguous 32-bit DMA span and rejects cumulative embedded plus
separate register offsets that leave the buffer before hardware submission.
Cache lookup resolves the current dma-buf before matching, so integer-fd reuse cannot
select an obsolete mapping; stale cache owners are dropped while job-held
references remain valid. Session reset now also advances a per-session epoch,
cancels earlier same-ioctl staged jobs, rejects stale import/admission, and
publishes active plus scheduler ownership atomically. Staged work snapshots
client type, translation table, codec info, and RCB state so later controls do
not retroactively change it; initialized sessions reject encoder/decoder
rebinding with `-EBUSY`. RKVENC2 slice overflow is now a one-shot poll error
rather than a permanent head-job poison, and non-split/empty `POLL_HW_IRQ`
selects its full-frame/`-EIO` result before interpreting slice-only memory. The
active-job hardware pointer is also pinned/detached under the session lock, so
reset/close abort cannot race completion plus platform removal into an
unpinned devm-hardware use. The mainline branch carries the minimal
`include/soc/rockchip/rockchip_iommu.h` hook to match the 6.18 provider. The
support repo's
`kernel-drivers/tests/rewrite-build-gate.sh` reproduces the clean-source
KUnit-enabled provider/rewrite/DTB build. On 2026-07-15 its default `normal`
profile completed warning-free for the current pins
`../kernel/linux-6.18-rkvenc@563f329dd8c4` and
`../kernel/linux@856743fc3c3d`, building `drivers/iommu/rockchip-iommu.o`, both
rewrite objects, and `rockchip/rk3588-rock-5b.dtb`. The Published alpha packages
remain reconstructible from the pre-hardening parents
`../kernel/linux-6.18-rkvenc@d1d15a3d052a` and
`../kernel/linux@083bdb98e715`; their source extraction/config coverage does not
cover the July 15 heads. The broader
`normal`, `memory`, and `race` archive build
profiles last passed warning-free at the immediately earlier
`../kernel/linux-6.18-rkvenc@0a35c26a0fd7` and
`../kernel/linux@938b1d2032c3` pins after display-tail RGB565 and XRGB rotation
coverage was added. The build gate now removes each per-profile archive
checkout after a passing profile unless `KEEP_TMP=1`; after that change, the combined
`REWRITE_BUILD_PROFILES="normal memory race" kernel-drivers/tests/rewrite-build-gate.sh all`
invocation completed all six profiles in one run and left no
`rkcompat-rewrite-build.*` scratch directories under `/tmp`.
`VALIDATE_ONLY=1
kernel-drivers/tests/rewrite-conformance-run.sh` also passed the device-free
syzlang ABI-marker, case-builder, and comparator validation, including 26
Rockchip syzlang ABI markers and 143 GStreamer case builders. The
counter-enabled `VALIDATE_ONLY=1 PROFILE=rewrite RUN_COUNTER_CHECKS=1` mode
plus the `LIBRGA_FORCE_RGA_USERPTR_IOMMU=1` variant passed the rewrite counter-default
wiring checks. See rewrite-drivers.md §6.
The older `180ee72a9a80` mainline pin is still used by §9 for the
upstream-style V4L2 RGA3 comparison that was measured before the latest rewrite
commits landed.

## 9. Upstream-style V4L2 RGA3 comparison tree

The upstream-style RGA comparison in rewrite-drivers.md §1 reads the media driver
from `drivers/media/platform/rockchip/rga/` on branch
`rk3588-rewrite-mainline` at commit `180ee72a9a80`. That commit is now reachable
in the public `yisding/linux-rock5b` `rk3588-rewrite-mainline` history. The tree
contains the mainline V4L2 mem2mem RGA driver plus local RK3588/RGA3 patches,
including the RGA3 command path in `rga3-hw.c` and the temporary
multicore-disable logic in `rga.c`. It measured 3,168 lines across `*.c`, `*.h`,
`Kconfig`, and `Makefile` on 2026-07-02.

## 10. Expanded Rockchip conformance bundle

The reproducible seed for the conformance bundle now lives in this repo under
[`kernel-drivers/tests/conformance/`](../kernel-drivers/tests/conformance/README.md).
The generated runtime bundle still defaults to an external path,
`../rockchip-conformance` (`/home/yi/Code/rockchip-conformance` on the dev box),
because third-party source checkouts, build directories, logs, and test assets
do not belong in git. The tracked seed's `MANIFEST.tsv` records the exact
shallow checkouts staged on 2026-07-02 and
`scripts/bootstrap-sources.sh` reconstructs the missing `sources/` trees:

| Component | Path inside bundle | Pin |
|-----------|--------------------|-----|
| JeffyCN GStreamer Rockchip plugins | `sources/jeffycn-gstreamer-rockchip` | `JeffyCN/mirrors.git`, branch `gstreamer-rockchip`, commit `dcbcd6454ef892e385b3a782600369eb6c0719db` |
| Rockchip MPP official library/tests | `sources/rockchip-mpp` | `rockchip-linux/mpp.git`, branch `develop`, commit `c2c1ee502b3a26efebcf843f7a0aeb4d172c6237` |
| Official librga + IM2D samples | `sources/airockchip-librga` | `airockchip/librga.git`, branch `main`, commit `2b32edcb97b601b25683e2941d888c8515da6d55` |
| Linux MPP/RGA/DRM demo | `sources/mpp-linux-cpp-demo` | `WainDing/mpp_linux_cpp.git`, branch `master`, commit `3d7cca63c4f5f0febacef0b0d0cdb36394fb5ca0` |
| Android RKMediaCodecDemo | `sources/rkmediacodec-demo` | `c-xh/RKMediaCodecDemo.git`, branch `master`, commit `38b85b3c160bf58f2237d5f49b601c1636d484a5` |

The tracked seed also carries helper scripts to build MPP, generate a local
`librga.pc` shim, build librga samples, build JeffyCN's Meson-based GStreamer
plugin tree, collect system/device state, and write per-profile logs under
`logs/rewrite/` and `logs/forward-port/`. The YSP-side
`rewrite-conformance-run.sh` wrapper
sequences those profile logs across ABI replay, MPP, librga, GStreamer, FFmpeg,
and optional forward-port-vs-rewrite comparator steps. See
[kernel-driver rewrite-conformance](../kernel-drivers/tests/rewrite-conformance.md)
for the test matrix and pass/fail interpretation.

A 2026-07-03 source review of the staged JeffyCN GStreamer plugin found no
existing conformance logs yet.  Its rewrite-relevant hot paths are libmpp
decode/encode lifecycle operations, MPP allocator import/export of dma-bufs,
optional AFBC decode/encode negotiation, and legacy `c_RkRgaBlit()` scale,
format-convert, and rotate operations between fd-backed MPP/GStreamer buffers.
The kernel trees now have focused KUnit coverage for the highest-value legacy
RGA conversion profiles, the broader GStreamer-visible format matrix, the
remaining 180/270-degree public rotation values, and VP9 RKVDEC fd-to-IOVA
register translation/validation. The
support repo's direct `librga-smoke.sh` mirrors the public RKNN/RKNPU
preprocessing shapes plus the `c_RkRgaBlit()` calls for encoder-side
virtual-source conversion, decode-side fd-backed rotate/format conversion, and
planar fallback, while `gstreamer-suite.sh` carries a diagnostic
format matrix for advertised GStreamer encoder input formats, decoder output
formats, the optional `GST_MPP_VP8ENC_FAKE_VP8ENC` VP8 alias, JPEG decoder
explicit/default BGRx output selection, VP8 QP and JPEG quality-factor property
setters, `GST_MPP_DEC_FBC_IS_RFBC=1` RFBC caps negotiation, RGA conversions,
and opt-in display/DMABuf sink plus `KMSSINK_DISABLE_VSYNC=1`,
`GST_RKXIMAGE_USE_COLORKEY=1`, and `GST_KMSSRC_DMA_FEATURE=1` KMS capture cases
against JeffyCN's `rkximagesink` and `kmssrc`. The GStreamer wrapper now also
caches generated H.264/H.265, VP9, opt-in AV1, opt-in legacy VP8/H.263/MPEG,
and H.265 Main10 inputs under
the shared conformance assets directory and records `artifacts.tsv` SHA-256s for generated
decode/transcode
outputs so the comparator can fail required forward-port vs rewrite pixel or
bitstream mismatches. The FFmpeg wrapper now also validates current
ffmpeg-rockchip decoder/encoder/RGA filter option discovery, decoder-option
null-output paths, H.264/H.265 encoder-option encodes, `scale_rkrga`
forced-core/async/AFBC-output transcodes, `vpp_rkrga` crop/transpose, and
diagnostic decoder `afbc=rga` plus `overlay_rkrga` alpha composition.
GStreamer and FFmpeg pipeline conformance on a booted rewrite
kernel, including real display-plane and forward-port vs rewrite timing data,
remain the next userspace-visible priorities before chasing diagnostic-only RGA
sample profiles.

## 11. RK3588 AV1 / VSI-IOMMU comparison trees

The AV1 note was written from three local trees on 2026-07-02:

| Tree | Local path | Pin used for the observation | Relevant files |
|------|------------|------------------------------|----------------|
| Forward-port / rewrite 6.18 tree | `/home/yi/Code/kernel/linux-6.18-rkvenc` | branch `rk3588-rewrite-6.18`, commit `a81feb1e2971`, 125 commits ahead of `linux-rock5b/rk3588-rewrite-6.18` | `drivers/video/rockchip/mpp/`, `drivers/video/rockchip/mpp/compat/soc/rockchip/rockchip_iommu.h`, `arch/arm64/boot/dts/rockchip/rk3588-base.dtsi` |
| Upstream-style comparison tree | `/home/yi/Code/kernel/linux` | branch `rk3588-rewrite-mainline`, commit `839de47fcda2`, 125 commits ahead of `linux-rock5b/rk3588-rewrite-mainline` | `drivers/iommu/vsi-iommu.c`, `Documentation/devicetree/bindings/iommu/verisilicon,iommu.yaml`, `drivers/media/platform/verisilicon/`, `arch/arm64/boot/dts/rockchip/rk3588-base.dtsi` |
| Rockchip BSP donor | `/home/yi/Code/kernel/rockchip-kernel` | `develop-6.1` commit `b4ef083dc0c3` | `drivers/video/rockchip/mpp/mpp_av1dec.c`, `drivers/iommu/rockchip-iommu-av1d.c`, `drivers/iommu/rockchip-iommu.c`, `arch/arm64/boot/dts/rockchip/rk3588s.dtsi` |

The upstream-style tree contains the AV1 IOMMU work as ordinary upstream commits:

| Commit | Subject |
|--------|---------|
| `90d50734815a` | `dt-bindings: iommu: verisilicon: Add binding for VSI IOMMU` |
| `917ace84b770` | `iommu: Add verisilicon IOMMU driver` |
| `6ddfbec80077` | `arm64: dts: rockchip: Add verisilicon IOMMU node on RK3588` |
| `80b0d3546ce1` | `iommu: vsi: avoid -Wformat-security warning` |
| `3040784f8721` | `iommu/vsi: Use list_for_each_entry()` |

Those commits are the likely source to reuse for any RKMPP AV1 forward-port
experiment. The YSP repo does **not** vendor those files today; this section is
a provenance record for the analysis in
[`kernel-drivers/av1/docs/av1-rk3588.md`](../kernel-drivers/av1/docs/av1-rk3588.md).
