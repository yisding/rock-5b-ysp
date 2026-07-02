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
| 1 | Forward-port kernel tree | [`docs/01`](01-how-the-drivers-work.md), [`docs/03`](03-dev-uapis.md), [`docs/05`](05-vendor-forward-port.md), [`docs/06`](06-vendor-delta.md), [`docs/07`](07-device-tree.md); DKMS `KSRC` | `v6.18` + `patches/rk3588-rkvenc2-01…` (+ `02` for DT) |
| 2 | Audited tree (BSP audit) | [`docs/11`](11-bsp-audit.md), `patches/cleanup-draft/` line numbers | parent of `56e403ede081` = `5614909e5803` |
| 3 | `$OURS` / `$BSP` measurement pair | [`docs/06`](06-vendor-delta.md) "Reproduce the count" | tree 1 vs `rockchip-linux/kernel` `develop-6.1` @ `b4ef083dc0c3` |
| 4 | Userspace libraries + FFmpeg | [`docs/02`](02-how-the-userspace-libs-work.md), `ffmpeg/*` | table in §4 |
| 5 | GNOME Remote Desktop | `gnome-remote-desktop/CAPTURE-PATH.md` etc. | tag `50.1` = `5ef1a2aa6bef` |
| 6 | Register recipes | docs/01 §9, docs/02 §A3 | MPP HAL sources + RK3588 TRM (§6) |
| 7 | Canonical uAPI headers | docs/03 footer | inside patch 01 (§7) |
| 8 | Clean-room rewrite drivers | [`docs/13`](13-rewrite-drivers.md) | local commit `981a832452454a` — **not yet public**, see docs/13 §6 |

---

## 1. The forward-port tree (the primary anchor tree)

Everything in docs/01/03/05/06/07 that cites `mpp_*.c:NNN`, `rga_*.c:NNN`, or a
`compat/` header line resolves against **pristine mainline `v6.18` plus this
repo's two patches**:

```bash
git clone --branch v6.18 --depth 1 \
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.18
cd linux-6.18
git am /path/to/rock-5b-ysp/patches/rk3588-rkvenc2-01-vcodec-rga-drivers.patch
git am /path/to/rock-5b-ysp/patches/rk3588-rkvenc2-02-vcodec-rga-dt.patch   # DT anchors only
```

(`git am` works — both files are `git format-patch` output; `git apply` works
too, see [`patches/README.md`](../patches/README.md).) Driver anchors need only
patch 01; docs/07's DT anchors need patch 02. Note patch 02 *applies* to
pristine `v6.18` at the git level (it was committed there), but the resulting
DT only **compiles** on a tree that also carries Armbian's `media-0001` nodes —
its `&vdec0`/`&vdec1` overrides reference labels vanilla 6.18 doesn't define
([`docs/08`](08-armbian-packaging.md), [`docs/09`](09-vanilla-kernel.md)). For
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
[`docs/05`](05-vendor-forward-port.md) §B). Because every replacement is
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

## 2. The audited tree (docs/11 line-number pin)

[`docs/11`](11-bsp-audit.md) states its own pin: every `line:` number is
against **the forward-port HEAD before any cleanup patch is applied — the
parent of commit `56e403e`**. Concretely:

- Audit-assembly commit: `56e403ede081` "WIP: BSP audit cleanup edits
  (machine-generated, compile-tested)", sole commit on branch
  `bsp-audit-cleanup` of the dev linux repo — the working source of both
  [`patches/cleanup-split/`](../patches/cleanup-split/) and
  [`patches/cleanup-draft/`](../patches/cleanup-draft/).
- Its parent: `5614909e5803` — i.e. **exactly the forward-port tree of §1**
  (driver files identical to `v6.18` + patch 01, modulo the 9 same-line
  devfreq-guard rewrites noted above, which shift nothing).

So to re-derive any docs/11 or cleanup-draft line number: build the §1 tree and
count there. After a cleanup patch lands in a file, later lines in that file
drift (docs/11's own warning); the stable anchor is function name + nearby
code.

## 3. The docs/06 `$OURS` / `$BSP` measurement pair

[`docs/06`](06-vendor-delta.md) "Reproduce the count" diffs two directories:

| Var | Tree | Pin |
|-----|------|-----|
| `$OURS` | `<forward-port tree §1>/drivers/video/rockchip` | dev-box provenance: `/home/yi/Code/linux-6.18-rkvenc/drivers/video/rockchip` |
| `$BSP` | `rockchip-linux/kernel` branch `develop-6.1`, `drivers/video/rockchip/` | clean checkout, observed @ `b4ef083dc0c3` (2026-07-01) |

The BSP donor floats (it is a live vendor branch); docs/06 already notes the
measured integers drift against a future BSP while the ≈580-line / ≈1.7%
headline holds. If you need the *exact* counts to reproduce, use the
`b4ef083dc0c3` state of `develop-6.1`. (`radxa/kernel` `linux-7.0.11` also
exists as a dev-box reference checkout @ `45943c54ded4` but is **not** the
donor and is not cited by any doc.)

## 4. Userspace pins — libmpp, librga, FFmpeg

| Component | Repo | Pin | Cited by |
|-----------|------|-----|----------|
| libmpp (study tree) | `rockchip-linux/mpp` | **v1.3.9** (docs/02:9). Commit-level pin **unrecorded** — see note below | docs/02 Part A, [`ffmpeg/README.md`](../ffmpeg/README.md) |
| libmpp (PPA packaging tree) | `tsukumijima/mpp-rockchip` (tracks HermanChen `develop`) | `750e76e`, packaged as `1.5.0-1+rk1` | [`packaging/ppa/README.md`](../packaging/ppa/README.md) |
| librga source (study tree) | `tsukumijima/librga-rockchip` (JeffyCN `linux-rga-multi` lineage) | Commit-level pin **unrecorded** — candidate `2cffdf6` (see note) | docs/02 Part B, [`docs/10`](10-gotchas.md) |
| librga prebuilt | `airockchip/librga` | `2b32edc` ("Update librga version to 1.10.6_[3]") | ffmpeg/README.md librga row |
| ffmpeg-rockchip (documented build) | `nyanmisaka/ffmpeg-rockchip` | `40c412daccf0` (2026-04-23); preserved locally as branch `backup-pre-upgrade-master` | ffmpeg/README.md, [`ffmpeg/IMPLEMENTATION-COMPARISON.md`](../ffmpeg/IMPLEMENTATION-COMPARISON.md) |
| ffmpeg-rockchip-81 (rebased successor) | `github.com/yisding/ffmpeg-rockchip-81` | branch `main` (tip `b59509b609` as of 2026-07-01); branch `upstream` = `87bd15dc3c` | [`ffmpeg/FIX-CANDIDATES.md`](../ffmpeg/FIX-CANDIDATES.md), [`ffmpeg/REBASE-NOTES.md`](../ffmpeg/REBASE-NOTES.md), [`ffmpeg/patches/`](../ffmpeg/patches/) |
| FFmpeg upstream release | `FFmpeg/FFmpeg` | tag `n8.1.2` = `38b88335f99e` (2026-06-17) | IMPLEMENTATION-COMPARISON baseline; the PPA/GRD ABI base |
| FFmpeg upstream master (rebase base) | `FFmpeg/FFmpeg` | `87bd15dc3c` = `n8.2-dev-2058-g87bd15dc3c` | FIX-CANDIDATES, REBASE-NOTES |

**How the two upstream FFmpeg pins relate:** `n8.1.2` (`38b88335f99e`) sits on
the `release/8.1` branch; `87bd15dc3c` is FFmpeg `master` well past the 8.1
fork. Their merge-base is `67c886222f` ("Bump versions for release/8.1") — the
8.1 branch point. So the rebased Rockchip stack (`main` on
`87bd15dc3c`) is *ahead of* the 8.1.2 ABI the packaged GRD stack uses; the
full topology and replay procedure live in
[`ffmpeg/REBASE-NOTES.md`](../ffmpeg/REBASE-NOTES.md).

> **The unrecorded pins (flagged, not invented).**
> - **libmpp:** docs/02 records only "v1.3.9". No commit hash was written down
>   at study time, and the only mpp checkout on the dev box today
>   (`mpp-rockchip` @ `750e76e`, the 1.5.0-era PPA packaging tree) is *newer*
>   than the study state. **UNVERIFIED** which exact commit docs/02's Part A
>   line numbers were read against; treat its anchors as "v1.3.9-era, verify
>   against your checkout".
> - **librga:** docs/02 names the repo but no commit. The dev-box study
>   checkout `librga-src` sits at `2cffdf6` (merge of JeffyCN
>   `linux-rga-multi`; tag lineage `v2.2.0-1-20260121-2cffdf6`, packaged as
>   `2.2.0-1+rk1`) — the **candidate** study pin, recorded here as the best
>   available evidence. **UNVERIFIED** that the tree wasn't updated between
>   study and today.

## 5. GNOME Remote Desktop base

All `file:line` anchors in
[`gnome-remote-desktop/CAPTURE-PATH.md`](../gnome-remote-desktop/CAPTURE-PATH.md)
(and the patch series in `gnome-remote-desktop/patches/`) resolve against
**upstream GRD tag `50.1` = commit `5ef1a2aa6bef`**
(`gitlab.gnome.org/GNOME/gnome-remote-desktop`), *before* this repo's patches.
The dev working branch `rdp-handover-reconnect` (tip `a3a1a32`, 17 commits atop
`50.1`) carries the backend + the parked handover-reconnect fix — see
`gnome-remote-desktop/patches/README.md` and
[`gnome-remote-desktop/PROFILING.md`](../gnome-remote-desktop/PROFILING.md).

## 6. Where the register recipes live

The kernel drivers never construct codec register values
([`docs/01`](01-how-the-drivers-work.md) §9 — "the userspace library knows the
recipe"). The recipes live in:

- **MPP HAL sources** — `rockchip-linux/mpp` `mpp/hal/rkenc/` +
  `mpp/hal/rkdec/` (per-codec register builders `hal_h264e`, `hal_h265e`,
  `hal_h264d`, `hal_h265d`; docs/02 §A3). Register-layout headers sit next to
  each HAL (VEPU580 / VDPU381 register structs).
- **RK3588 TRM** — the address map in docs/07 ("Address Mapping" table, the
  `fdc40000`-vs-`fdc48000` resolution). TODO: the docs cite "the RK3588 TRM"
  without recording the exact TRM part/version number — **UNVERIFIED** which
  TRM revision was consulted; record it here when known.

## 7. Canonical uAPI headers (docs/03's definitions)

Both headers ship **inside patch 01**, so the §1 reconstruction gives you the
exact bytes docs/03 documents:

| Header | In-tree path (after patch 01) | Size in patch |
|--------|-------------------------------|---------------|
| MPP uAPI | `include/uapi/linux/rk-mpp.h` | +82 lines (`enum MPP_DEV_COMMAND_TYPE`, `struct mpp_request`, `MPP_IOC_CFG_V*`, `MPP_FLAGS_*`) |
| RGA uAPI | `drivers/video/rockchip/rga3/include/rga.h` | +1007 lines (`rga_req`, `RGA_IOC_*`, image descriptors) |

Note the **rewrite-driver uAPI extensions** (`MPP_CMD_SET_ERR_REF_HACK`,
`MPP_FLAGS_REG_OFFSET_ALONE`, `MPP_FLAGS_POLL_NON_BLOCK`) are **not** in patch
01's `rk-mpp.h` — they exist only in the rewrite commit documented in
[`docs/13`](13-rewrite-drivers.md) §4 and cross-folded into
[`docs/03`](03-dev-uapis.md).

## 8. Rewrite-driver tree

The clean-room MPP/RGA rewrite ([`docs/13`](13-rewrite-drivers.md)) lives in a
**local-only** commit `981a832452454a` on the dev worktree's
`rkvenc-fwport-6.18` branch, plus an uncommitted mainline-master DT bring-up
diff. It is **not yet reconstructible from public sources** — docs/13 §6
carries the pin, the state snapshot, and the TODO to publish a citable branch.
