# DKMS package — `rk3588-vcodec-dkms`

Ship the vendor MPP codec (`rk_vcodec.ko`) + RGA (`rga3.ko`) drivers as a **DKMS**
package that builds out-of-tree against a *stock* kernel and **rebuilds itself on
every kernel update** — the alternative to patching + rebuilding the kernel
(`patches/` + `scripts/build-combined-kernel.sh`; chooser in
[`../../INSTALL.md`](../../INSTALL.md)).

> ⚠️ **Mutually exclusive with the combined kernel.** On a kernel that already
> has these drivers `=y` (our combined Armbian kernel), the DKMS build fails
> `modpost` with `'…' exported twice` — the module exports clash with vmlinux.
> That failure is expected; run DKMS **only on a stock kernel**. (Restated in
> the deploy hub, [`../README.md`](../README.md).)

**Validation reality** (tracked in [`../../STATUS.md`](../../STATUS.md)):
compiles + links on **6.18 only**; the DT overlay is **dtc-validated but not
boot-validated**. "6.18 → 7.2" is the *intended* tracking range (the
[`docs/06`](../../docs/06-vendor-delta.md) §1 API-drift table says nothing in
that window should break the build), not a tested one.

A DKMS module alone won't bind — the hardware needs device-tree nodes — so the
package also ships a **boot-time DT overlay**.

## What's here

| File | Role |
|------|------|
| `dkms.conf` | DKMS config — two modules (`rk_vcodec`, `rga3`), `AUTOINSTALL=yes`. |
| `kbuild/{Kbuild,mpp.Kbuild,rga3.Kbuild}` | Self-contained out-of-tree Kbuilds (see below). |
| `overlay/rk3588-rock5b-vcodec.dts` | Boot-time DT overlay (encoder + decoder + CCU + RGA + aliases). |
| `deb/DEBIAN/{control,postinst,prerm}` | The `.deb`: `dkms add/build/install` + overlay install. |
| `build-deb.sh` | Stages source from the kernel tree, compiles the overlay, assembles the `.deb`. `clean` removes `build/`. |
| `build/` | *(gitignored, disposable)* staging tree + built `.deb`/`.dtbo` from the last run — never committed ([binary policy](../README.md#binary-policy)). |

## Build & install

`build-deb.sh` stages the driver source from a **forward-port kernel tree**
(`KSRC`). If you don't have one, reconstruct it first — this is the same tree
every kernel doc anchors into ([`docs/00`](../../docs/00-source-trees.md) §1):

```bash
git clone --branch v6.18 --depth 1 \
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-6.18-rkvenc
cd linux-6.18-rkvenc
git am /path/to/rock-5b-ysp/patches/rk3588-rkvenc2-01-vcodec-rga-drivers.patch
# (patch 02 is DT-only — not needed for KSRC; the overlay covers DT here)
```

Then build and install:

```bash
# Build the .deb (needs dtc + the kernel tree's dt-bindings headers):
KSRC=/path/to/linux-6.18-rkvenc/drivers/video/rockchip \
  bash build-deb.sh                    # -> build/rk3588-vcodec-dkms_1.0_arm64.deb
# (KSRC defaults to the dev-box path /home/yi/Code/linux-6.18-rkvenc/…;
#  KROOT, for the dt-bindings headers, is derived from KSRC.)
bash build-deb.sh clean                # remove build/ (staging tree + .deb)

# On a STOCK-kernel ROCK 5B:
sudo apt install dkms device-tree-compiler
sudo dpkg -i build/rk3588-vcodec-dkms_1.0_arm64.deb     # postinst runs dkms build+install
# enable the overlay, then reboot:
#   add  rk3588-rock5b-vcodec  to  user_overlays=  in /boot/armbianEnv.txt
sudo reboot
# verify (same as the in-tree kernel):
sudo bash ../../scripts/validate-combined.sh
```

The udev rules ([`../codec-udev/`](../codec-udev/)) still apply — install those
too for non-root `/dev/mpp_service` + `/dev/dma_heap/*` + `/dev/rga` access.

## How the out-of-tree build works (the non-obvious bits)

- **The vendor `CONFIG_ROCKCHIP_MPP_*` / `_RGA_*` symbols don't exist in a host
  kernel config**, so the in-tree `obj-$(CONFIG_…)` selection can't fire. The
  Kbuilds list the objects explicitly and `-D` the symbols the C code `#ifdef`s
  on (encoder + decoder + RGA + procfs; **devfreq off**).
- **`-I compat` + force-included QoS shim + `-DMPP_VERSION`** — same as the
  in-tree build ([`docs/05`](../../docs/05-vendor-forward-port.md)).
- **The devfreq re-guard is mandatory for OOT.** The encoder gated its custom
  devfreq governor — and the *private* `drivers/devfreq/governor.h` — on
  `CONFIG_PM_DEVFREQ` (host `=y`), which isn't shippable OOT and whose struct
  layout is unstable across 6.18→7.2. The forward-port patch now re-guards it
  behind the (off) `RKVENC2_DEVFREQ` (rock-5b-ysp `23cbe21`); `build-deb.sh`
  refuses to stage a tree that's missing it.

`build-deb.sh` stages **only `.c`/`.h`** into `build/` (no stale
`.o`/`.cmd`/`Module.symvers`) so DKMS starts from clean source. (Files DKMS
itself later generates *inside* an on-disk `build/` — e.g. `rk_vcodec.mod.c`
after a module build — are post-staging residue; `bash build-deb.sh clean`
resets it.)

## Targeting 6.18 → 7.2 (intended, not tested)

- **Tested:** compiles + links on 6.18 (`uname -r` 6.18.x) — nothing newer has
  been tried. The same source builds in-tree (`=y`) and out-of-tree.
- **Forward-compat:** the known API drift (the [`docs/06`](../../docs/06-vendor-delta.md)
  §1 table — `Since` column) and the hazard ranking
  ([`docs/12`](../../docs/12-resyncing.md), esp. the `mpp_iommu_dma_cookie`
  struct-layout shadow) are the re-sync checklist when a new kernel lands. DKMS
  surfaces a build break loudly on `apt upgrade`; consult `docs/12` to fix it —
  and note this package is a **second consumer** of every resync fix made for
  the combined kernel.

## Caveats (read before relying on it)

1. **Targets a *stock* kernel** (no built-in vendor codec) — see the
   mutual-exclusion warning at the top; the `modpost` `'…' exported twice`
   failure on a combined kernel is the expected symptom.
2. **The overlay is dtc-validated but not yet boot-validated**
   ([`STATUS.md`](../../STATUS.md) tracks this gate). It uses
   **string-path aliases** (`rkvdec0 = "/video-codec@fdc38000"`, …) rather than
   `&label`, because an overlay can't resolve a base label's path and an
   overlay-internal `&label` resolves to the *fragment* path — both of which break
   `of_alias_get_id()` (the MPP core_id source). The paths are taken from a live
   RK3588 tree; if a core comes up with the wrong `core_id` on your board, the
   alias fragment is the first thing to check.
3. **Stock-Armbian assumption:** the overlay *converts in place* Armbian's
   media-0001 V4L2 `vdec0`/`vdec1`/`rga` nodes (present on `rockchip64-current`).
   On a vanilla mainline kernel without those nodes, use the inline DT from
   [`docs/09`](../../docs/09-vanilla-kernel.md) instead.
