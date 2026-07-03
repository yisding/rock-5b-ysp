# Source trees — reconstructing every cited tree

Reference appendix. Every `file:line` cite in `docs/` (and most in `ffmpeg/`,
`gnome-remote-desktop/`) resolves against a specific tree state. This doc pins
each of those trees and gives the reconstruction recipe, so the anchors stay
auditable without access to the original dev box. Dev-box paths
(`/home/yi/Code/…`) appear below **only** as provenance records of where the
work was done; every tree is reconstructible from public sources + this repo's
patches unless explicitly marked otherwise.

| # | Tree | Anchors for | Pin |
|---|------|-------------|-----|
| 1 | Forward-port kernel tree | [kernel driver guide](../kernel-drivers/docs/how-the-drivers-work.md), [uAPI guide](../kernel-drivers/docs/dev-uapis.md), [forward-port guide](../kernel-drivers/docs/vendor-forward-port.md), [vendor delta](../kernel-drivers/docs/vendor-delta.md), [device-tree guide](../kernel-drivers/docs/device-tree.md); DKMS `KSRC` | `v6.18` + `kernel-drivers/patches/rk3588-rkvenc2-01…` (+ `02` for DT) |
| 2 | Audited tree (BSP audit) | [BSP audit](../kernel-drivers/docs/bsp-audit.md), `kernel-drivers/patches/cleanup-draft/` line numbers | parent of `56e403ede081` = `5614909e5803` |
| 3 | `$OURS` / `$BSP` measurement pair | [vendor delta](../kernel-drivers/docs/vendor-delta.md) "Reproduce the count" | tree 1 vs `rockchip-linux/kernel` `develop-6.1` @ `b4ef083dc0c3` |
| 4 | Userspace libraries + FFmpeg | [userspace library guide](../userspace-libraries/docs/how-the-userspace-libs-work.md), `ffmpeg/*` | table in §4 |
| 5 | GNOME Remote Desktop | `gnome-remote-desktop/docs/capture-path.md` etc. | tag `50.1` = `5ef1a2aa6bef` |
| 6 | Register recipes | kernel/userspace driver docs | MPP HAL sources + RK3588 TRM (§6) |
| 7 | Canonical uAPI headers | kernel uAPI docs | inside patch 01 (§7) |
| 8 | Clean-room rewrite drivers | [rewrite-driver track](../kernel-drivers/docs/rewrite-drivers.md) | `yisding/linux-rock5b` branch `rk3588-rewrite-6.18` @ `62de7d0d0503` + branch `rk3588-rewrite-mainline` @ `2ffef5f0bf9c`, see §8 |
| 9 | Upstream-style V4L2 RGA3 comparison | [rewrite-driver track](../kernel-drivers/docs/rewrite-drivers.md) §1 | `yisding/linux-rock5b` branch `rk3588-rewrite-mainline` history at `180ee72a9a80`, path `drivers/media/platform/rockchip/rga/`, see §9 |
| 10 | Expanded Rockchip conformance bundle | [kernel-driver tests](../kernel-drivers/tests/README.md) "Expanded conformance bundle" | local `../rockchip-conformance`, see §10 |
| 11 | RK3588 AV1 / VSI-IOMMU comparison | [AV1 kernel note](../kernel-drivers/docs/av1-rk3588.md), FFmpeg AV1 note | local observations on 2026-07-02: forward-port tree `rk3588-rewrite-6.18` @ `a81feb1e2971`; sibling `../linux` `rk3588-rewrite-mainline` @ `839de47fcda2`; vendor BSP `rockchip-linux/kernel` `develop-6.1` @ `b4ef083dc0c3`, see §11 |

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
([Armbian packaging guide](../packaging/docs/armbian-packaging.md), [vanilla-kernel guide](../kernel-drivers/docs/vanilla-kernel.md)). For
*anchoring* line cites that doesn't matter.

Provenance: the patches were generated from the dev worktree
`/home/yi/Code/linux-6.18-rkvenc` (branch `rkvenc-fwport-6.18`), commits

```
924f4232546d  video: rockchip: RK3588 vendor MPP (rkvenc2/rkvdec2) + RGA3/RGA2 drivers  → patch 01
5614909e5803  arm64: dts: rockchip: rk3588: VEPU580 encoder, rkvdec2 decoder, RGA3 nodes → patch 02
```

**One deliberate divergence from commit `924f4232546d`:** rock-5b-ysp commit
`23cbe21` later folded the encoder **devfreq re-guard** directly into the
shipped patch file (9 one-line, 1:1 replacements in `mpp_rkvenc2.c`:
`#ifdef CONFIG_PM_DEVFREQ` → `#if defined(CONFIG_PM_DEVFREQ) &&
defined(CONFIG_ROCKCHIP_MPP_RKVENC2_DEVFREQ)`), enabling the OOT/DKMS build
([`packaging/dkms/README.md`](../packaging/dkms/README.md),
[forward-port guide](../kernel-drivers/docs/vendor-forward-port.md) §B). Because every replacement is
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
  [`kernel-drivers/patches/cleanup-split/`](../kernel-drivers/patches/cleanup-split/) and
  [`kernel-drivers/patches/cleanup-draft/`](../kernel-drivers/patches/cleanup-draft/).
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
| `$OURS` | `<forward-port tree §1>/drivers/video/rockchip` | dev-box provenance: `/home/yi/Code/linux-6.18-rkvenc/drivers/video/rockchip` |
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
| libmpp (study tree) | `rockchip-linux/mpp` | **v1.3.9** (how-the-userspace-libs-work.md:9). Commit-level pin **unrecorded** — see note below | how-the-userspace-libs-work.md Part A, [`ffmpeg/README.md`](../ffmpeg/README.md) |
| libmpp (PPA packaging tree) | `tsukumijima/mpp-rockchip` (tracks HermanChen `develop`) | `750e76e`, packaged as `1.5.0-1+rk1` | [`packaging/ppa/README.md`](../packaging/ppa/README.md) |
| librga source (study tree) | `tsukumijima/librga-rockchip` (JeffyCN `linux-rga-multi` lineage) | Commit-level pin **unrecorded** — candidate `2cffdf6` (see note) | how-the-userspace-libs-work.md Part B, [gotchas](./gotchas.md) |
| librga prebuilt | `airockchip/librga` | `2b32edc` ("Update librga version to 1.10.6_[3]") | ffmpeg/README.md librga row |
| ffmpeg-rockchip (documented build) | `nyanmisaka/ffmpeg-rockchip` | `40c412daccf0` (2026-04-23); preserved locally as branch `backup-pre-upgrade-master` | ffmpeg/README.md, [`ffmpeg/docs/implementation-comparison.md`](../ffmpeg/docs/implementation-comparison.md) |
| ffmpeg-rockchip-81 (rebased successor) | `github.com/yisding/ffmpeg-rockchip-81` | branch `main` (tip `b59509b609` as of 2026-07-01); branch `upstream` = `87bd15dc3c` | [`ffmpeg/docs/fix-candidates.md`](../ffmpeg/docs/fix-candidates.md), [`ffmpeg/docs/rebase-notes.md`](../ffmpeg/docs/rebase-notes.md), [`ffmpeg/patches/`](../ffmpeg/patches/) |
| FFmpeg upstream release | `FFmpeg/FFmpeg` | tag `n8.1.2` = `38b88335f99e` (2026-06-17) | `ffmpeg/docs/implementation-comparison.md` baseline; the PPA/GRD ABI base |
| FFmpeg upstream master (rebase base) | `FFmpeg/FFmpeg` | `87bd15dc3c` = `n8.2-dev-2058-g87bd15dc3c` | `ffmpeg/docs/fix-candidates.md`, `ffmpeg/docs/rebase-notes.md` |

**How the two upstream FFmpeg pins relate:** `n8.1.2` (`38b88335f99e`) sits on
the `release/8.1` branch; `87bd15dc3c` is FFmpeg `master` well past the 8.1
fork. Their merge-base is `67c886222f` ("Bump versions for release/8.1") — the
8.1 branch point. So the rebased Rockchip stack (`main` on
`87bd15dc3c`) is *ahead of* the 8.1.2 ABI the packaged GRD stack uses; the
full topology and replay procedure live in
[`ffmpeg/docs/rebase-notes.md`](../ffmpeg/docs/rebase-notes.md).

> **The unrecorded pins (flagged, not invented).**
> - **libmpp:** how-the-userspace-libs-work.md records only "v1.3.9". No commit hash was written down
>   at study time, and the only mpp checkout on the dev box today
>   (`mpp-rockchip` @ `750e76e`, the 1.5.0-era PPA packaging tree) is *newer*
>   than the study state. **UNVERIFIED** which exact commit how-the-userspace-libs-work.md's Part A
>   line numbers were read against; treat its anchors as "v1.3.9-era, verify
>   against your checkout".
> - **librga:** how-the-userspace-libs-work.md names the repo but no commit. The dev-box study
>   checkout `librga-src` sits at `2cffdf6` (merge of JeffyCN
>   `linux-rga-multi`; tag lineage `v2.2.0-1-20260121-2cffdf6`, packaged as
>   `2.2.0-1+rk1`) — the **candidate** study pin, recorded here as the best
>   available evidence. **UNVERIFIED** that the tree wasn't updated between
>   study and today.

## 5. GNOME Remote Desktop base

All `file:line` anchors in
[`gnome-remote-desktop/docs/capture-path.md`](../gnome-remote-desktop/docs/capture-path.md)
(and the patch series in `gnome-remote-desktop/patches/`) resolve against
**upstream GRD tag `50.1` = commit `5ef1a2aa6bef`**
(`gitlab.gnome.org/GNOME/gnome-remote-desktop`), *before* this repo's patches.
The dev working branch `rdp-handover-reconnect` (tip `a3a1a32`, 17 commits atop
`50.1`) carries the backend + the parked handover-reconnect fix — see
`gnome-remote-desktop/patches/README.md` and
[`gnome-remote-desktop/docs/profiling.md`](../gnome-remote-desktop/docs/profiling.md).

## 6. Where the register recipes live

The kernel drivers never construct codec register values
([kernel driver guide](../kernel-drivers/docs/how-the-drivers-work.md) §9 — "the userspace library knows the
recipe"). The recipes live in:

- **MPP HAL sources** — `rockchip-linux/mpp` `mpp/hal/rkenc/` +
  `mpp/hal/rkdec/` (per-codec register builders `hal_h264e`, `hal_h265e`,
  `hal_h264d`, `hal_h265d`; how-the-userspace-libs-work.md §A3). Register-layout headers sit next to
  each HAL (VEPU580 / VDPU381 register structs).
- **RK3588 TRM** — the address map in device-tree.md ("Address Mapping" table, the
  `fdc40000`-vs-`fdc48000` resolution). TODO: the docs cite "the RK3588 TRM"
  without recording the exact TRM part/version number — **UNVERIFIED** which
  TRM revision was consulted; record it here when known.

## 7. Canonical uAPI headers (dev-uapis.md's definitions)

Both headers ship **inside patch 01**, so the §1 reconstruction gives you the
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
is reconstructible from public branches in `github.com/yisding/linux-rock5b` as
of 2026-07-03:

- branch `rk3588-rewrite-6.18`, commit `62de7d0d0503` ("media: rockchip:
  apply mpp rewrite normal clock rates"), matching the clean dev worktree
  `/home/yi/Code/linux-6.18-rkvenc`.
- branch `rk3588-rewrite-mainline`, commit `2ffef5f0bf9c` (same subject),
  matching the clean sibling worktree `/home/yi/Code/linux`.

Both trees contain `drivers/video/rockchip/mpp-rewrite/` and
`drivers/video/rockchip/rga-rewrite/`. The 6.18 tree is the line-count source
for rewrite-drivers.md's current rewrite-size snapshot; the mainline tree is the
post-6.18 DT/wiring state. These pins include the large RGA feature-coverage
push, RGA request-config staging and reconfiguration
resource/acquire-fence/gauss replacement coverage, request-config ioctl
acquire-fd ownership/no-release-fence-export coverage, configured request
cancel/file-close cleanup, legacy async blit and modern request-submit
acquire/release-fence coverage, RGA async close cleanup for jobs pending on
acquire fences and jobs queued on hardware, last-hardware pending-acquire
cleanup, RGA3 pattern-channel rotate rejection, mixed-task RGA3-to-RGA2
core handoff/requeue coverage, the RK3588
`im2d_slt` RGB/RGBA three-channel alpha-blend coverage, and the debugfs
scheduler-core counters needed to check RGA2/RGA3 forced-core and
load-balancing behaviour on hardware, followed by focused MPP coverage for
selected-core removal races,
`RELEASE_FD`, nonblocking poll, public `RESET_SESSION`/file-close cleanup, and
CCU coordinator removal cleanup for queued and active dependent-core jobs, plus
RGA2 packed-YUV422 color-fill coverage, packed-YUV420 fill rejection, and
Y4/Y8 dither-output coverage, BPP palette source coverage, current
RGB-to-Y4/Y8 full-CSC dither-output coverage, AFBC-to-AFBC ffmpeg filter
copy coverage, and `immakeBorder()` reflect/wrap top/bottom and left/right
side-edge command coverage, plus RGA2 OSD external-flag, default-background,
channel-invert, and invert-calibration register coverage for current `imosd`
requests, plus MPP DT `rockchip,normal-rates` application through the public
clock framework.
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

The external conformance bundle lives at `/home/yi/Code/rockchip-conformance`
(`../rockchip-conformance` from the kernel/YSP worktrees). It is **not** a git
repo and is not vendored here because it contains third-party source checkouts,
build directories, logs, and test assets. Its own `MANIFEST.tsv` records the
exact shallow checkouts staged on 2026-07-02:

| Component | Path inside bundle | Pin |
|-----------|--------------------|-----|
| JeffyCN GStreamer Rockchip plugins | `sources/jeffycn-gstreamer-rockchip` | `JeffyCN/mirrors.git`, branch `gstreamer-rockchip`, commit `dcbcd6454ef892e385b3a782600369eb6c0719db` |
| Rockchip MPP official library/tests | `sources/rockchip-mpp` | `rockchip-linux/mpp.git`, branch `develop`, commit `c2c1ee502b3a26efebcf843f7a0aeb4d172c6237` |
| Official librga + IM2D samples | `sources/airockchip-librga` | `airockchip/librga.git`, branch `main`, commit `2b32edcb97b601b25683e2941d888c8515da6d55` |
| Linux MPP/RGA/DRM demo | `sources/mpp-linux-cpp-demo` | `WainDing/mpp_linux_cpp.git`, branch `master`, commit `3d7cca63c4f5f0febacef0b0d0cdb36394fb5ca0` |
| Android RKMediaCodecDemo | `sources/rkmediacodec-demo` | `c-xh/RKMediaCodecDemo.git`, branch `master`, commit `38b85b3c160bf58f2237d5f49b601c1636d484a5` |

The bundle adds helper scripts to build MPP, generate a local `librga.pc` shim,
build librga samples, build JeffyCN's Meson-based GStreamer plugin tree, collect
system/device state, and write per-profile logs under `logs/rewrite/` and
`logs/forward-port/`. See [kernel-driver tests](../kernel-drivers/tests/README.md)
for the test matrix and pass/fail interpretation.

## 11. RK3588 AV1 / VSI-IOMMU comparison trees

The AV1 note was written from three local trees on 2026-07-02:

| Tree | Local path | Pin used for the observation | Relevant files |
|------|------------|------------------------------|----------------|
| Forward-port / rewrite 6.18 tree | `/home/yi/Code/linux-6.18-rkvenc` | branch `rk3588-rewrite-6.18`, commit `a81feb1e2971`, 125 commits ahead of `linux-rock5b/rk3588-rewrite-6.18` | `drivers/video/rockchip/mpp/`, `drivers/video/rockchip/mpp/compat/soc/rockchip/rockchip_iommu.h`, `arch/arm64/boot/dts/rockchip/rk3588-base.dtsi` |
| Upstream-style comparison tree | `/home/yi/Code/linux` | branch `rk3588-rewrite-mainline`, commit `839de47fcda2`, 125 commits ahead of `linux-rock5b/rk3588-rewrite-mainline` | `drivers/iommu/vsi-iommu.c`, `Documentation/devicetree/bindings/iommu/verisilicon,iommu.yaml`, `drivers/media/platform/verisilicon/`, `arch/arm64/boot/dts/rockchip/rk3588-base.dtsi` |
| Rockchip BSP donor | `/home/yi/Code/rockchip-kernel` | `develop-6.1` commit `b4ef083dc0c3` | `drivers/video/rockchip/mpp/mpp_av1dec.c`, `drivers/iommu/rockchip-iommu-av1d.c`, `drivers/iommu/rockchip-iommu.c`, `arch/arm64/boot/dts/rockchip/rk3588s.dtsi` |

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
[`kernel-drivers/docs/av1-rk3588.md`](../kernel-drivers/docs/av1-rk3588.md).
