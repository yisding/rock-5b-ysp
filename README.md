# rock-5b-ysp — RK3588 hardware video codecs + RGA on mainline-ish Linux 6.18

Forward-port of the Rockchip **vendor MPP** hardware video codec stack and the
**RGA** 2D accelerator from the Rockchip 6.1 BSP to **Linux 6.18**, packaged for
**Armbian** on the **Radxa ROCK 5B** (RK3588), plus a working
[`ffmpeg-rockchip`](https://github.com/nyanmisaka/ffmpeg-rockchip) userspace —
and everything learned building on top of it: a hardware H.264 encode backend
for GNOME Remote Desktop, Mesa/Panfrost Mali-G610 debugging, a BSP security
audit with a staged fix series, DKMS/PPA packaging, and a clean-room driver
rewrite track.

The core result is a single Armbian kernel with all three accelerators **built
in (`=y`)** and **validated on real hardware** (dated, whole-project scoreboard:
[`STATUS.md`](STATUS.md)):

| Accelerator | Block | Nodes | Status |
|-------------|-------|-------|--------|
| **Encoder** | VEPU580 / `rkvenc2` | `fdbd0000`, `fdbe0000` | ✅ H.264 + H.265, 256² + 720p, PSNR 47–62 dB |
| **Decoder** | VDPU381 / `rkvdec2` | CCU `fdc30000`, cores `fdc38000` / `fdc40000` | ✅ H.264 + H.265 decode, both cores |
| **RGA** | RGA3 ×2 + RGA2 | `fdb60000`, `fdb70000`, `fdb80000` | ✅ probes + IOMMU + scale/CSC via ffmpeg |
| **End-to-end** | ffmpeg-rockchip | `h264_rkmpp` / `hevc_rkmpp` / `scale_rkrga` | ✅ full HW transcode (decode → RGA → encode) |
| **BSP audit fixes** | 65-patch review series | [`patches/cleanup-split/`](patches/cleanup-split/README.md) | ⚠️ staged, **runtime gate pending** ([`STATUS.md`](STATUS.md)) |

Userspace talks to the vendor MPP framework via `/dev/mpp_service` (the
Rockchip `rockchip-linux/mpp` library — **not** V4L2) and to RGA via `/dev/rga`
(`librga`). This is the same stack `ffmpeg-rockchip` expects.

> **Why the vendor stack and not mainline V4L2?** Mainline's `hantro`/`rkvdec`
> V4L2 drivers don't cover H.265 **encode**, and the RGA3 V4L2 driver is still
> a subset (scale/CSC only) and not yet merged for RK3588. The vendor MPP +
> RGA stack gives the full feature set today. See
> [`docs/09-vanilla-kernel.md`](docs/09-vanilla-kernel.md) for the mainline-V4L2
> alternative and its trade-offs.

## Choose your path

| Your goal | Start at | What you'll find |
|-----------|----------|------------------|
| **Get hardware codecs working on my ROCK 5B** | [`INSTALL.md`](INSTALL.md) | The delivery-model chooser (combined kernel vs DKMS vs userspace), the canonical quickstart, PHASH pinning, validation, userspace handoff |
| **Understand how the stack works** | [`docs/README.md`](docs/README.md) | The reading path — [`docs/01`](docs/01-how-the-drivers-work.md) → [`02`](docs/02-how-the-userspace-libs-work.md) → [`03`](docs/03-dev-uapis.md) (drivers → libraries → `/dev` ABIs) |
| **Write an app / use FFmpeg** | [`ffmpeg/README.md`](ffmpeg/README.md) | Building MPP + librga + ffmpeg-rockchip; with [`docs/02`](docs/02-how-the-userspace-libs-work.md)+[`03`](docs/03-dev-uapis.md) for the library/ABI depth. Player caveat: rkmpp codecs are standalone AVCodecs — mpv needs `--vd=h264_rkmpp`, VLC 3.x can't use them ([`packaging/README.md`](packaging/README.md) § Player caveat) |
| **Package or redistribute** | [`packaging/README.md`](packaging/README.md) | The four delivery channels, operations runbook (apt holds, rollback), binary policy, PPA; mechanism background in [`docs/08`](docs/08-armbian-packaging.md) |
| **Port / re-sync to a newer kernel or BSP** | [`docs/05`](docs/05-vendor-forward-port.md) → [`06`](docs/06-vendor-delta.md) → [`12`](docs/12-resyncing.md) | What was changed and why, the hazard ranking, the bump checklist; tree pins in [`docs/00`](docs/00-source-trees.md); deliverables in [`patches/`](patches/README.md) |
| **Audit or upstream** | [`docs/11`](docs/11-bsp-audit.md) | 89 verified findings → the fix series [`patches/cleanup-split/`](patches/cleanup-split/README.md); the rewrite track [`docs/13`](docs/13-rewrite-drivers.md); FFmpeg fixes [`ffmpeg/FIX-CANDIDATES.md`](ffmpeg/FIX-CANDIDATES.md) + [`ffmpeg/patches/`](ffmpeg/patches/README.md); Mesa [`mesa-panfrost-g610/`](mesa-panfrost-g610/README.md) |
| **Something is broken** | [`docs/10`](docs/10-gotchas.md) | The whole-repo trap index → [`tests/`](tests/README.md), [`gnome-remote-desktop/TESTING.md`](gnome-remote-desktop/TESTING.md), crash capture [`docs/14`](docs/14-debug-kernel.md) |

## Repository map

One line per directory; **each directory's `README.md` owns the full file-level
index** (the "hub contract").

```
INSTALL.md      ⭐ get codecs working: delivery chooser + canonical quickstart + PHASH log
STATUS.md       whole-project dated scoreboard + staleness watchlist
GLOSSARY.md     the vocabulary (MPP, CCU/DCHS, RCB, PHASH, IEP, AFBC, …)
patches/        kernel deliverables: the two forward-port userpatches (drivers ~980 KB + DT)
  cleanup-split/   THE reviewable BSP-audit fix series (65 mailbox patches; gate pending)
  cleanup-draft/   historical per-file bundles + VERIFICATION.md (the verification record)
docs/           the knowledge spine, 00–14 — see docs/README.md for the reading path
scripts/        build → install → validate the combined kernel + the canonical udev rule
tests/          on-hardware smoke tests: decode, encode (PSNR/fps), full HW transcode
ffmpeg/         userspace how-to + architecture, the 2026 rebase (REBASE-NOTES.md),
                FIX-CANDIDATES.md (14 fix groups) and patches/ (the exported 9-patch series)
gnome-remote-desktop/  real app #1: HW H.264 RDP encode — runtime story (README), design,
                capture path, baseline, PROFILING (60 fps), patches/ (7-patch series), bench/
mesa-panfrost-g610/    Mesa/Panfrost Mali-G610: BLIT precision root cause, validation,
                textureQueryLevels, reproducers/ (C probes + archived Mesa patch)
packaging/      the deploy hub: codec-udev + gdm-hwenc debs, dkms/, ppa/ (Launchpad
                source packages — moved here from ppa/, 2026-07), ops runbook, binary policy
```

> **Maintenance rule:** any commit that adds a file must touch the owning
> directory's hub README (and this map if it adds a directory) — restated in
> the [`docs/12` §6](docs/12-resyncing.md) propagation table. Self-check
> (prints unindexed files; series `.patch` dirs are indexed by number/glob in
> their READMEs and are excluded):
>
> ```bash
> git ls-files | grep -vE '(^|/)(README\.md|\.gitignore)$' | grep -vE '(cleanup-(split|draft)|ffmpeg/patches|gnome-remote-desktop/patches)/.*\.patch$' | while read -r f; do d=$(dirname "$f"); until [ -f "$d/README.md" ] || [ "$d" = . ]; do d=$(dirname "$d"); done; grep -qF "$(basename "$f")" "$d/README.md" || echo "unindexed: $f"; done
> ```

## Quickstart (Armbian, ROCK 5B)

The canonical walkthrough (prerequisites, PHASH pinning, DKMS alternative,
udev, userspace) is [`INSTALL.md`](INSTALL.md); the shape of it:

```bash
git clone https://github.com/armbian/build armbian-build
mkdir -p armbian-build/userpatches/kernel/archive/rockchip64-6.18
cp patches/rk3588-rkvenc2-0*.patch armbian-build/userpatches/kernel/archive/rockchip64-6.18/
bash scripts/build-combined-kernel.sh                              # prints P####-C####
sudo PHASH='P####-C####' bash scripts/install-combined-kernel.sh && sudo reboot
sudo bash scripts/validate-combined.sh   # 2 encoder + 2 decoder cores + /dev/rga
```

Then [`tests/`](tests/README.md) exercises real frames, and
[`INSTALL.md` §8](INSTALL.md) gets you an encoder binary.

## Glossary

[`GLOSSARY.md`](GLOSSARY.md) has the full vocabulary. Three disambiguations are
load-bearing enough to repeat here:

- **CCU vs DCHS** — the per-cluster *core coordination unit*: the **decoder's
  CCU is a real MMIO block** (`@fdc30000`); the **encoder's is software-only**
  (**DCHS** = dual-core hand-shake, no registers). See
  [`docs/01` §7](docs/01-how-the-drivers-work.md).
- **RCB: SRAM vs DRAM** — *Row Cache Buffer*, per-row codec scratch: the
  **decoder** backs it with on-chip **SRAM**, the **encoder** with **DRAM**.
  See [`docs/07`](docs/07-device-tree.md).
- **convert-in-place** — the packaging trick of *retyping* Armbian's existing
  V4L2 decoder DT nodes to the vendor binding instead of adding new ones —
  what makes the port zero-edit on Armbian. See
  [`docs/08`](docs/08-armbian-packaging.md).

## Provenance & licensing

- The driver code is forward-ported from Rockchip's GPL-2.0 BSP MPP framework
  (`rockchip-kernel` `drivers/video/rockchip/mpp/`) and `airockchip/librga`'s
  kernel driver. It is GPL-2.0, like the kernel.
- `librga`'s **userspace** library **is** open source (Apache-2.0) — the official
  `airockchip/librga` repo only ships a prebuilt `.so`, so we link that for
  convenience, but the source is published (JeffyCN mirror lineage) and you can
  build from it. Full lineage in [`docs/10`](docs/10-gotchas.md); build notes in
  [`ffmpeg/README.md`](ffmpeg/README.md).
- The mainline RGA-in-U-Boot / RGA-V4L2 context is courtesy of Collabora's
  RK3588 upstreaming work.
- **License of this repo's own prose/scripts: TODO — owner decision pending.**
  (The kernel patches are GPL-2.0 as derived works; nothing else is licensed
  yet.)

This repo is the *integration + analysis*; the heavy lifting on the drivers is
Rockchip's.

> **Moved (2026-07):** `ppa/` is now [`packaging/ppa/`](packaging/ppa/README.md).
