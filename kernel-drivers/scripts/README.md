# scripts/

The kernel **build → install → validate** tooling. Two build variants (the
combined `=y` kernel and the self-contained-DT **av1 forward-port** deb) plus the
shared ops scripts (revert, co-installable fallback, the canonical udev rule),
the [`debug-kernel/`](debug-kernel/README.md) KASAN build, and
[`bootstrap-workspaces.sh`](bootstrap-workspaces.sh) which reconstructs the
external build/conformance workspaces from their pins. This is delivery path (a)
of the project — see [`install.md`](../../install.md) for the chooser between the
combined kernel, DKMS, and the PPA.

> **Where the scripts run vs. build.** These scripts are the tracked source of
> truth here; they drive an **external, gitignored build workspace**
> (`rock5b-kernel-build`, holding the 31 GB `armbian-build` + all outputs).
> `bootstrap-workspaces.sh` clones that workspace. Every script defaults
> `WORKSPACE` to `../../../kernel/rock5b-kernel-build` and takes `ARMBIAN_BUILD=`
> / `WORKSPACE=` overrides.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Build the combined Armbian kernel, install the exact intended debs, validate device probing, and install the canonical codec udev rule. |
| Developer focus | Preserve the assumptions in the Armbian wrapper flow: userpatch location, `USE_CCACHE` handling, PHASH pinning, validation signals, and device-node policy. |
| Owns | `build-combined-kernel.sh` + `build-armbian-deb.sh` (the two build variants), `install-combined-kernel.sh`, `validate-combined.sh`, `kernel-revert.sh`, `make-fallback-kernel-deb.sh`, `99-rockchip-codec.rules`, `bootstrap-workspaces.sh`, and the [`debug-kernel/`](debug-kernel/README.md) build. |
| Depends on | Kernel patches in [`../patches/`](../patches/README.md), Armbian build tree setup from [`install.md`](../../install.md), and validation expectations from [`../tests/`](../tests/README.md). |
| Current state | The combined-kernel flow produced the hardware-validated board state recorded in [`status.md`](../../status.md). |

> **⚠️ Mutually exclusive with DKMS.** Do **not** install the
> [`packaging/dkms/README.md`](../../packaging/dkms/README.md) package on top of this
> kernel: the drivers are built in, and DKMS modpost fails with
> `'…' exported twice` (symbol clash with vmlinux). Pick one delivery path.
> The udev rule is needed on **both** paths.

## Prerequisite: the external build workspace

The build scripts expect an Armbian build tree at
**`$WORKSPACE/armbian-build`** (default `WORKSPACE=../../../kernel/rock5b-kernel-build`,
gitignored, outside this repo). Get it with the bootstrap:

```bash
bash bootstrap-workspaces.sh          # clones armbian-build + conformance sources from pins
```

Stage the port patches per [`packaging/docs/armbian-packaging.md`](../../packaging/docs/armbian-packaging.md)
(the av1 `build-armbian-deb.sh` regenerates + stages them for you). Debs land in
`$WORKSPACE/armbian-build/output/debs`, which is exactly where
`install-combined-kernel.sh` looks by default — the build → install handoff
needs no path edits. Override `ARMBIAN_BUILD=`/`WORKSPACE=` for another layout.

## The scripts

| Script | Runs as | What it does |
|--------|---------|--------------|
| `build-combined-kernel.sh` | user | Wraps `./compile.sh kernel BOARD=rock-5b BRANCH=current KERNEL_CONFIGURE=no USE_CCACHE=yes`. Crucially passes `USE_CCACHE` as an **argument** (env var wouldn't reach the Docker build — see [gotchas](../../docs/gotchas.md)). Prints ccache growth + the new `P####-C####` hash. |
| `install-combined-kernel.sh` | root | Removes the obsolete `rkvdec2` boot overlay from `armbianEnv.txt` (backs it up), then `dpkg -i` the image + dtb + headers debs for the pinned `PHASH`. Old kernel stays selectable. `DEBS`/`HASH`/`PHASH` are env-overridable. |
| `build-armbian-deb.sh` | user | The **av1 forward-port** build variant. Regenerates the port patches from the kernel git tree (`KERNEL_TREE`, `git format-patch v6.18..HEAD`), restores/cleans the selected built-in Armbian kernel patch archive, clears the matching userpatch archive, stages the generated patch set, **disables** the two colliding Armbian core media patches (this tree's DT is self-contained), then the same ccache-correct `compile.sh`. `--restore` performs only the built-in archive reset. |
| `kernel-revert.sh` | root (SD rescue) | Get a bad board booting again: flip `/boot` symlinks (`switch`) or chroot-reinstall a good deb (`reinstall`) on the internal disk from an SD-card rescue. Subcommands `list`/`switch`/`reinstall`; target via `--auto`/`--device`/`--root`. |
| `make-fallback-kernel-deb.sh` | user | Repackage a kernel deb (rename `Package:`, drop `Provides:`) into a **co-installable** fallback that won't clobber the primary `linux-image-current-rockchip64` — a permanent recovery kernel `kernel-revert.sh` can `switch` to. Defaults to the official 6.18.35 (26.5.1) debs. |
| `bootstrap-workspaces.sh` | user | Reconstruct the external build + conformance workspaces from their pins: clone `armbian-build` and the 5 conformance source checkouts (from `../tests/conformance/MANIFEST.tsv`), deploy the tracked conformance skeleton. Idempotent; `--check` reports only. |
| `validate-combined.sh` | root | Post-reboot: checks `/dev/mpp_service`, the four cores under `/proc/mpp_service` (`rkvenc-core0/1` + the two decoder cores, see naming note below), `/dev/rga`, and greps boot dmesg for clean probes / no faults. |
| `99-rockchip-codec.rules` | (install to `/etc/udev/rules.d/`) | `GROUP="video" MODE="0660"` on `/dev/mpp_service`, `/dev/dma_heap/*`, and `/dev/rga` so ffmpeg-rockchip runs **without sudo** (you must be in the `video` group; the dma-heap line is **required** — rkmpp allocates buffers there, see [gotchas](../../docs/gotchas.md)). Packaged as a deb by [`packaging/codec-udev/README.md`](../../packaging/codec-udev/README.md), which copies this file at build time — this copy is canonical. |

> **Decoder core naming.** On the combined kernel the decoder cores appear as
> `/proc/mpp_service/video-codec0` and `video-codec1` — DT patch 02 converts
> Armbian's mainline `video-codec@…` nodes **in place** and keeps the node name
> (the driver dispatches by compatible, see
> [device-tree guide](../docs/device-tree.md)). Verified 2026-07-01 on
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
[`install.md`](../../install.md).
