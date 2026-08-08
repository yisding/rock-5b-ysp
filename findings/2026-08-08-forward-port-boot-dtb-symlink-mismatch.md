# Forward-port kernel booted the mainline DTB: `/boot/dtb` and `/boot/Image` split across co-installed branches

> Scope: Armbian/YSP kernel packaging on the ROCK 5B; `/boot` symlink management when two `linux-image`/`linux-dtb` branches are co-installed; first hardware bring-up of the installed 6.18.43 forward-port
> Source: board `6.18.43-ysp-rockchip64`; `/boot` symlinks, `/proc/device-tree`, `/var/log/dpkg.log` 2026-08-07 20:37–20:49, and `/var/lib/dpkg/info/linux-{dtb,image}-{ysp,current}-rockchip64.postinst`
> Date: 2026-08-08
> Trust: **MEASURED** / **SOURCE-INSPECTED** / **ROOT-CAUSED** /
> **FIX-RUNTIME-VERIFIED** / **PARTIAL**

> **Runtime update 2026-08-08:** after repointing `/boot/dtb` and rebooting,
> the 11:36 conformance capture records `/boot/dtb ->
> /boot/dtb-6.18.43-ysp-rockchip64`, both vendor device nodes, a passing ABI
> stage, and all 12 required MPP cases passing. Full conformance later stopped
> at an unrelated RGA2 USERPTR mapping defect recorded in the
> [follow-up finding](2026-08-08-forward-port-rga2-userptr-swiotlb-segments.md).

## Result

A full `run-conformance.sh` on the forward-port/production profile failed
immediately at the ABI stage — `SKIP: neither /dev/mpp_service nor /dev/rga is
present` (exit 77, which the runner correctly treats as a required-device
failure). The MPP and RGA drivers are compiled `=y` (identity check confirmed
`CONFIG_ROCKCHIP_MPP_SERVICE=y`, `CONFIG_ROCKCHIP_MULTI_RGA=y`), yet they created
no character devices and no `/proc/mpp_service`.

**Cause: the `ysp` forward-port kernel booted with the `current` (mainline)
kernel's device tree, which has no vendor codec/RGA nodes.** The vendor MPP/RGA
drivers therefore had nothing to bind to. The GPU came up (`/dev/dri/*`) because
that node is identical in both trees.

### Evidence chain

- **Running DT is mainline.** `rga@fdb80000` carries `rockchip,rk3588-rga`
  (mainline V4L2 RGA), the codec nodes are `fdb50000/fdba0000/fdc70000.video-codec`
  bound to `hantro-vpu`, and a scan for vendor compatibles
  (`rockchip,mpp-service|rkvdec|rkvenc|rga3`) returned nothing.
- **Driver binding confirms it.** `mpp_service` bound **0 devices**; the mainline
  V4L2 `rockchip-rga` claimed `fdb80000.rga` → `/dev/video0` (not `/dev/rga`);
  `hantro-vpu` claimed the three codec nodes → `/dev/video1,2,4`.
- **Wrong symlink.** `/boot/Image -> vmlinuz-6.18.43-ysp-rockchip64` (correct)
  but `/boot/dtb -> dtb-6.18.43-current-rockchip64` (wrong); with
  `fdtfile=rockchip/rk3588-rock-5b.dtb` the boot loaded the mainline DTB. The
  correct `dtb-6.18.43-ysp-rockchip64/` set is present on disk.
- **The two DTBs are different media stacks.** `dtb-6.18.43-ysp-…/rockchip/rk3588-rock-5b.dtb`
  contains `rockchip,mpp-service`, `rockchip,rga2`, `rockchip,rga3`;
  `dtb-6.18.43-current-…/…` (the one booted) contains only
  `rockchip,rk3588-rga`/`rockchip,rk3288-rga` and no MPP service node.

## Root cause — why the symlink was "not changed" (it was, then overwritten)

Both kernel branches — `ysp` (forward-port, upgraded 6.18.42→6.18.43) and
`current` (Armbian mainline fallback, upgraded →26.8.1) — were configured in one
dpkg transaction. Each package's postinst **unconditionally claims a shared
global symlink for its own version**, with no concept of a selected default:

- `linux-dtb-ysp` postinst: `ln -sfTv "dtb-6.18.43-ysp-rockchip64" dtb`
- `linux-dtb-current` postinst: `ln -sfTv "dtb-6.18.43-current-rockchip64" dtb`
- `linux-image-ysp` postinst: `ln -sfv vmlinuz-6.18.43-ysp-rockchip64 /boot/Image`

`/boot/dtb` is owned by the **dtb** package; `/boot/Image` by the **image**
package. dpkg configured them in *opposite relative order*, so "last writer wins"
resolved each symlink to a different branch:

| Time | dpkg configure | Effect |
|------|----------------|--------|
| 20:41:39 | `linux-dtb-ysp` installed | `/boot/dtb` → **ysp** |
| 20:41:39→20:43:57 | `linux-image-current` installed | `/boot/Image` → current |
| **20:44:12** | `linux-dtb-current` installed | `/boot/dtb` → **current** (overwrites ysp) |
| **20:47:46→20:49:57** | `linux-image-ysp` installed | `/boot/Image` → **ysp** (overwrites current) |

Net: `/boot/Image` → ysp, `/boot/dtb` → current — a kernel from one branch with
a DTB from another. The interleave is driven by the expensive per-image
`update-initramfs` trigger and the header→image dependency ordering, not by
alphabetical order, so it is not reliably reproducible run to run — but the
last-writer-wins design makes a split *possible* on any multi-branch upgrade.
Note `/boot/vmlinuz` and `/boot/initrd.img` (+`.old`) are managed separately by
Debian `linux-update-symlinks` (version-aware); `/boot/Image`, `/boot/uInitrd`,
and `/boot/dtb` are raw `ln -sf` in the Armbian/YSP postinsts (not version-aware),
and the bootloader consumes the raw set.

## Fix

Repoint the DTB symlink to the running kernel's set and reboot (needs root):

```
sudo ln -sfn dtb-6.18.43-ysp-rockchip64 /boot/dtb
sudo reboot
```

This fix is runtime-verified but **fragile**: the next upgrade that reconfigures
either dtb package can re-flip `/boot/dtb` by the same last-writer-wins rule.
Durable options, in order of preference: remove the unused `current` branch
(`apt purge linux-image-current-rockchip64 linux-dtb-current-rockchip64`) if it
is only an unused fallback; or `apt-mark hold` the `current` dtb/image packages;
or add a boot-time guard that asserts `/boot/dtb` resolves to the `-$(uname -r`
branch`)` set before trusting a conformance run.

## Verification gate

Passed on the 2026-08-08 reboot: `/dev/mpp_service`, `/dev/rga`, and
`/proc/mpp_service/` are present; `run-conformance.sh` cleared system identity,
matrix identity, ABI replay, and MPP. The separate librga failure does not
weaken this DTB/device-binding proof.

## Boundary

The diagnosis and one repair cycle are proven from the running DT, driver
binding, dpkg.log, postinst scripts, direct DTB comparison, and the successful
post-reboot device/ABI/MPP stages. This does not make the raw shared symlink
scheme durable: another package transaction can recreate the split, and other
Armbian boot configurations may flatten or select DTBs differently.

## Why it matters

Every prior forward-port conformance pass ran with `/boot/dtb` and `/boot/Image`
coincidentally on the same branch. With two branches co-installed, that
coincidence is not guaranteed, and a mismatch presents as "the drivers are gone"
rather than as an obvious boot error — an expensive misdiagnosis waiting to
happen. It belongs in the [status.md](../status.md) watchlist as a stale-risk on
every kernel package operation, alongside [W16](../status.md#watch-w16).
