# DKMS package — `rk3588-vcodec-dkms`

Ship the vendor MPP codec (`rk_vcodec.ko`) + RGA (`rga3.ko`) drivers as a **DKMS**
package that builds out-of-tree against a *stock* kernel and **rebuilds itself on
every kernel update** — the alternative to patching + rebuilding the kernel
(`patches/` + `scripts/build-combined-kernel.sh`). Target range: **kernels 6.18 →
7.2**.

A DKMS module alone won't bind — the hardware needs device-tree nodes — so the
package also ships a **boot-time DT overlay**.

## What's here

| File | Role |
|------|------|
| `dkms.conf` | DKMS config — two modules (`rk_vcodec`, `rga3`), `AUTOINSTALL=yes`. |
| `kbuild/{Kbuild,mpp.Kbuild,rga3.Kbuild}` | Self-contained out-of-tree Kbuilds (see below). |
| `overlay/rk3588-rock5b-vcodec.dts` | Boot-time DT overlay (encoder + decoder + CCU + RGA + aliases). |
| `deb/DEBIAN/{control,postinst,prerm}` | The `.deb`: `dkms add/build/install` + overlay install. |
| `build-deb.sh` | Stages source from the kernel tree, compiles the overlay, assembles the `.deb`. |

## Build & install

```bash
# Build the .deb (stages driver source from the forward-port kernel tree —
# set KSRC if yours lives elsewhere; needs dtc + the kernel's dt-bindings headers):
bash build-deb.sh                      # -> build/rk3588-vcodec-dkms_1.0_arm64.deb

# On a STOCK-kernel ROCK 5B:
sudo apt install dkms device-tree-compiler
sudo dpkg -i build/rk3588-vcodec-dkms_1.0_arm64.deb     # postinst runs dkms build+install
# enable the overlay, then reboot:
#   add  rk3588-rock5b-vcodec  to  user_overlays=  in /boot/armbianEnv.txt
sudo reboot
# verify (same as the in-tree kernel):
sudo bash ../../scripts/validate-combined.sh
```

The udev rules (`packaging/codec-udev/`) still apply — install those too for
non-root `/dev/mpp_service` + `/dev/dma_heap/*` + `/dev/rga` access.

## How the out-of-tree build works (the non-obvious bits)

- **The vendor `CONFIG_ROCKCHIP_MPP_*` / `_RGA_*` symbols don't exist in a host
  kernel config**, so the in-tree `obj-$(CONFIG_…)` selection can't fire. The
  Kbuilds list the objects explicitly and `-D` the symbols the C code `#ifdef`s
  on (encoder + decoder + RGA + procfs; **devfreq off**).
- **`-I compat` + force-included QoS shim + `-DMPP_VERSION`** — same as the
  in-tree build (`docs/05`).
- **The devfreq re-guard is mandatory for OOT.** The encoder gated its custom
  devfreq governor — and the *private* `drivers/devfreq/governor.h` — on
  `CONFIG_PM_DEVFREQ` (host `=y`), which isn't shippable OOT and whose struct
  layout is unstable across 6.18→7.2. The forward-port patch now re-guards it
  behind the (off) `RKVENC2_DEVFREQ` (rock-5b-ysp `23cbe21`); `build-deb.sh`
  refuses to stage a tree that's missing it.

`build-deb.sh` stages **only `.c`/`.h`** (no stale `.o`/`.cmd`/`Module.symvers`)
so DKMS starts from clean source.

## Targeting 6.18 → 7.2

- **Tested:** compiles + links on 6.18 (`uname -r` 6.18.x). The same source builds
  in-tree (`=y`) and out-of-tree.
- **Forward-compat:** the known API drift (the `docs/06` §1 table — `Since`
  column) and the hazard ranking (`docs/12`, esp. the `mpp_iommu_dma_cookie`
  struct-layout shadow) are the re-sync checklist when a new kernel lands. DKMS
  surfaces a build break loudly on `apt upgrade`; consult `docs/12` to fix it.

## Caveats (read before relying on it)

1. **Targets a *stock* kernel** (no built-in vendor codec). On a kernel that has
   these drivers `=y` (e.g. our own combined kernel) the build fails `modpost`
   with `'…' exported twice` — that's the symbol clash with vmlinux, expected.
2. **The overlay is dtc-validated but not yet boot-validated.** It uses
   **string-path aliases** (`rkvdec0 = "/video-codec@fdc38000"`, …) rather than
   `&label`, because an overlay can't resolve a base label's path and an
   overlay-internal `&label` resolves to the *fragment* path — both of which break
   `of_alias_get_id()` (the MPP core_id source). The paths are taken from a live
   RK3588 tree; if a core comes up with the wrong `core_id` on your board, the
   alias fragment is the first thing to check.
3. **Stock-Armbian assumption:** the overlay *converts in place* Armbian's
   media-0001 V4L2 `vdec0`/`vdec1`/`rga` nodes (present on `rockchip64-current`).
   On a vanilla mainline kernel without those nodes, use the inline DT from
   `docs/09` instead.
