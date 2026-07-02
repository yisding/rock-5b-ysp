# Packaging the greeter codec access — `gnome-remote-desktop-gdm-hwenc`

An **opt-in** companion to [`codec-udev`](../codec-udev/). That package grants the
**`video`** group access to the codec nodes, which covers the interactive login
user. This one grants the **`gdm`** group, so the **GDM login screen** is
hardware-encoded too — needed only if you run
[gnome-remote-desktop over RDP](../../gnome-remote-desktop/) and want the greeter
(not just the logged-in session) on the VEPU580.

It is a separate package on purpose: it widens video-codec access to the whole
`gdm` group, which is a deliberate security choice rather than a default. GRD does
**not** depend on it — without it the login screen simply falls back to software.
(Delivery-channel context: the deploy hub, [`../README.md`](../README.md); it also
ships as PPA source package #5, [`../ppa/`](../ppa/README.md).)

## What's here

| File | Role |
|------|------|
| `root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules` | The `setfacl g:gdm` udev rule — **tracked source** (unlike `codec-udev`, the rule is native to this package, not copied from `scripts/`). |
| `build-deb.sh` | Assembles the `.deb` from `root/`. |
| `root/DEBIAN/control` | Package metadata (`gnome-remote-desktop-gdm-hwenc`, `Depends: acl`, `Enhances: gnome-remote-desktop`). |
| `root/DEBIAN/postinst` | `udevadm control --reload-rules && udevadm trigger` on the codec nodes. |
| `gnome-remote-desktop-gdm-hwenc_1.0_all.deb` | *(gitignored, on-disk build residue)* — see the [binary policy](../README.md#binary-policy). |

## Why the greeter needs its own rule

The GDM greeter does not run as `gdm`. It runs as a **dynamic per-session user** —
`gdm-greeter`, `gdm-greeter-2`, … (uid 60578+) — that is a member of only the
**`gdm`** group, never `video`/`render`. So:

- `codec-udev`'s `GROUP="video"` rule doesn't reach it.
- `TAG+="uaccess"` doesn't reliably reach it either: logind refreshes the DRM seat
  node's ACL across GDM's dynamic-user churn, but leaves the **non-seat** codec
  nodes (`/dev/mpp_service`, `/dev/dma_heap/*`) stuck with whichever greeter user
  was *first* — so the *active* greeter (`gdm-greeter-2`) ends up without access.

Result: `gnome-remote-desktop`'s rkmpp encode session fails at the first
`open("/dev/dma_heap/system")` and silently falls back to software RFX for the
login screen. (The greeter still reaches the **GPU** — `renderD128` gets a DRM
`uaccess` ACL — which is why the buffer looks fine but the encoder won't start.)
The full diagnosis is in [`../../gnome-remote-desktop/README.md`](../../gnome-remote-desktop/README.md)
(bug #3).

The stable handle across the churn is the **`gdm` group** itself. The rule adds a
persistent group ACL with `setfacl`, guarded so it is a harmless no-op where GDM
isn't installed:

```udev
# root/usr/lib/udev/rules.d/70-gnome-remote-desktop-gdm-hwenc.rules
KERNEL=="mpp_service", RUN+="/bin/sh -c 'getent group gdm >/dev/null 2>&1 && /usr/bin/setfacl -m g:gdm:rw $devnode'"
KERNEL=="rga",         RUN+="…same…"
KERNEL=="iep",         RUN+="…same…"    # BSP-only IEP node — not created by this port; no-op here (see below)
SUBSYSTEM=="dma_heap",  RUN+="…same…"
```

> **`KERNEL=="iep"`**: IEP is the BSP's Image Enhancement Processor (video
> post-processing — see [`glossary.md`](../../glossary.md)). This port ships no
> IEP driver and **`/dev/iep` does not exist on the board** (verified
> 2026-07-01, kernel `6.18.37-current-rockchip64` #7); the line only matters on
> BSP/vendor kernels that create the node, mirroring the same forward-compat
> line in the base rule ([`codec-udev`](../codec-udev/)).

Prefix `70-` so it loads **after** the base `60-media` / `99-rockchip-codec` rule
that sets `GROUP="video"`. `setfacl` adds a group entry and does **not** disturb
logind's per-session user ACLs, so `g:gdm` coexists with the DRM `uaccess`
grants.

## Build & install

```bash
bash build-deb.sh                                       # → gnome-remote-desktop-gdm-hwenc_1.0_all.deb
sudo apt install ./gnome-remote-desktop-gdm-hwenc_1.0_all.deb
# postinst runs: udevadm control --reload-rules && udevadm trigger (codec nodes)
```

No reboot needed: the `setfacl` RUN fires on the trigger, and GDM re-attempts the
encode session on its next greeter anyway. Verify:

```bash
getfacl /dev/dma_heap/system     # must list  group:gdm:rw-
# then, at the login screen, the greeter daemon should run codec=1 (AVC420) with
# an mpp_h264e thread instead of software CAPROGRESSIVE.
```

`Depends: acl` (for `setfacl`); `Enhances: gnome-remote-desktop`. The built `.deb`
is gitignored — commit the source (`root/DEBIAN/*`, the rule, `build-deb.sh`),
build the artifact on demand.

## Relationship to the other codec udev rules

| Rule | Grants | Covers |
|------|--------|--------|
| Armbian `60-media.rules` / this repo's [`codec-udev`](../codec-udev/) | `GROUP="video"` on `mpp_service`, `dma_heap`, `rga` | the interactive login user (in `video`) |
| **this package** (`70-…gdm-hwenc`) | `setfacl g:gdm` on the same nodes | the GDM greeter's dynamic `gdm-greeter-*` users |
| systemd default (`uaccess` on DRM) | ACL for the active seat user | the GPU node only — not the codec nodes |

The base `video`-group grant is the [upstream-submitted Armbian
rule](https://github.com/armbian/build/pull/10085); this package is the greeter
delta on top. There is **no** Armbian/distro precedent for granting the `gdm`
group codec access — it's specific to running an encoder inside the greeter.
