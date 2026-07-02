# scripts/

The **build → install → validate** trio for the combined kernel (all three
accelerators `=y`), plus the canonical udev rule. This is delivery path (a) of
the project — see [`../INSTALL.md`](../INSTALL.md) for the chooser between the
combined kernel, DKMS, and the PPA.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Build the combined Armbian kernel, install the exact intended debs, validate device probing, and install the canonical codec udev rule. |
| Developer focus | Preserve the assumptions in the Armbian wrapper flow: userpatch location, `USE_CCACHE` handling, PHASH pinning, validation signals, and device-node policy. |
| Owns | `build-combined-kernel.sh`, `install-combined-kernel.sh`, `validate-combined.sh`, and `99-rockchip-codec.rules`. |
| Depends on | Kernel patches in [`../patches/`](../patches/README.md), Armbian build tree setup from [`../INSTALL.md`](../INSTALL.md), and validation expectations from [`../tests/`](../tests/README.md). |
| Current state | The combined-kernel flow produced the hardware-validated board state recorded in [`../STATUS.md`](../STATUS.md). |

> **⚠️ Mutually exclusive with DKMS.** Do **not** install the
> [`../packaging/dkms/`](../packaging/dkms/README.md) package on top of this
> kernel: the drivers are built in, and DKMS modpost fails with
> `'…' exported twice` (symbol clash with vmlinux). Pick one delivery path.
> The udev rule is needed on **both** paths.

## Prerequisite: `<repo>/armbian-build`

`build-combined-kernel.sh` expects an Armbian build tree at
**`<repo>/armbian-build`** (a sibling of this directory, gitignored):

```bash
git clone https://github.com/armbian/build "$(git rev-parse --show-toplevel)/armbian-build"
```

with the port patches staged per [`../docs/08`](../docs/08-armbian-packaging.md).
Debs land in `<repo>/armbian-build/output/debs`, which is exactly where
`install-combined-kernel.sh` looks by default — the build → install handoff
needs no path edits.

## The scripts

| Script | Runs as | What it does |
|--------|---------|--------------|
| `build-combined-kernel.sh` | user | Wraps `./compile.sh kernel BOARD=rock-5b BRANCH=current KERNEL_CONFIGURE=no USE_CCACHE=yes`. Crucially passes `USE_CCACHE` as an **argument** (env var wouldn't reach the Docker build — see [`docs/10`](../docs/10-gotchas.md)). Prints ccache growth + the new `P####-C####` hash. |
| `install-combined-kernel.sh` | root | Removes the obsolete `rkvdec2` boot overlay from `armbianEnv.txt` (backs it up), then `dpkg -i` the image + dtb + headers debs for the pinned `PHASH`. Old kernel stays selectable. `DEBS`/`HASH`/`PHASH` are env-overridable. |
| `validate-combined.sh` | root | Post-reboot: checks `/dev/mpp_service`, the four cores under `/proc/mpp_service` (`rkvenc-core0/1` + the two decoder cores, see naming note below), `/dev/rga`, and greps boot dmesg for clean probes / no faults. |
| `99-rockchip-codec.rules` | (install to `/etc/udev/rules.d/`) | `GROUP="video" MODE="0660"` on `/dev/mpp_service`, `/dev/dma_heap/*`, and `/dev/rga` so ffmpeg-rockchip runs **without sudo** (you must be in the `video` group; the dma-heap line is **required** — rkmpp allocates buffers there, see [`docs/10`](../docs/10-gotchas.md)). Packaged as a deb by [`../packaging/codec-udev/`](../packaging/codec-udev/README.md), which copies this file at build time — this copy is canonical. |

> **Decoder core naming.** On the combined kernel the decoder cores appear as
> `/proc/mpp_service/video-codec0` and `video-codec1` — DT patch 02 converts
> Armbian's mainline `video-codec@…` nodes **in place** and keeps the node name
> (the driver dispatches by compatible, see
> [`docs/07`](../docs/07-device-tree.md)). Verified 2026-07-01 on
> 6.18.37-current-rockchip64 #7. Earlier standalone-node/overlay revisions named
> them `rkvdec-core0/1`; `validate-combined.sh` accepts both.

## Typical flow

```bash
# build (on a fast box or the board itself)
nohup bash build-combined-kernel.sh &            # ~80-90 min cold, ~10-15 warm
# set install-combined-kernel.sh PHASH to the printed hash (or pass it), then:
sudo PHASH='P####-C####' bash install-combined-kernel.sh
sudo reboot
sudo bash validate-combined.sh                   # expect 2+2 cores + /dev/rga, tainted 0

# non-sudo device access (optional but recommended)
sudo cp 99-rockchip-codec.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Then run the on-hardware smoke tests in [`../tests/`](../tests/README.md).

## PHASH pinning

`install-combined-kernel.sh` pins a specific build via `HASH`/`PHASH` so it
can't grab the wrong deb. Update `PHASH` after each build (the value is printed
by `build-combined-kernel.sh`); the hash↔patch-revision log lives in
[`../INSTALL.md`](../INSTALL.md).
