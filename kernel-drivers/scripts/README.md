# scripts/

The kernel **build → install → validate** tooling. The self-contained-DT **AV1
forward-port** build plus the shared ops scripts (revert, co-installable
fallback, the canonical udev rule),
the [`debug-kernel/`](debug-kernel/README.md) KASAN build, and
[`bootstrap-workspaces.sh`](bootstrap-workspaces.sh) which reconstructs the
external build/conformance workspaces from Armbian's configured branch plus the
pinned conformance manifest. This is delivery path (a)
of the project — see [`install.md`](../../install.md) for the chooser between the
combined kernel, DKMS, and the PPA.

> **Where the scripts run vs. build.** These scripts are the tracked source of
> truth here; they drive an **external, gitignored build workspace**
> (`rock5b-kernel-build`, holding the 31 GB `armbian-build` + all outputs).
> `bootstrap-workspaces.sh` clones that workspace. Every script defaults
> `WORKSPACE` to `../../../kernel/rock5b-kernel-build` and takes `ARMBIAN_BUILD=`
> / `WORKSPACE=` overrides.

## Build-host modes

The Ubuntu 26.04 Resolute system being built **is not the same thing as the
build host**. Armbian currently supports native builds on Armbian or Ubuntu
24.04 Noble; any current Docker-capable Linux can use the containerized path.
`compile.sh` prefers Docker when it is usable and falls back to a sudo relaunch
when it is not. Pass `PREFER_DOCKER=no` as an extra wrapper argument to force a
supported native build:

```bash
bash build-armbian-deb.sh                    # Docker when available
bash build-armbian-deb.sh PREFER_DOCKER=no   # native Armbian/Noble host
```

Both modes need roughly 8 GB RAM and 50 GB free disk. The aarch64 Noble native
path and its tight BTF memory margin are recorded in the
[`armbian-builder-setup` finding](../../findings/2026-07-08-armbian-builder-setup.md).
The full prerequisite and mode chooser is canonical in
[`install.md`](../../install.md) §2.

## Package brief

| Field | Contents |
|-------|----------|
| User outcome | Build the combined Armbian kernel, install the exact intended debs, validate device probing, and install the canonical codec udev rule. |
| Developer focus | Preserve the assumptions in the Armbian wrapper flow: userpatch location, `USE_CCACHE` handling, PHASH pinning, validation signals, and device-node policy. |
| Owns | `build-armbian-deb.sh`, `install-combined-kernel.sh`, `validate-combined.sh`, `kernel-revert.sh`, `make-fallback-kernel-deb.sh`, `99-rockchip-codec.rules`, `bootstrap-workspaces.sh`, and the [`debug-kernel/`](debug-kernel/README.md) build. |
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
bash bootstrap-workspaces.sh          # Armbian branch + pinned conformance sources
```

Stage the port patches per [`packaging/docs/armbian-packaging.md`](../../packaging/docs/armbian-packaging.md)
(the av1 `build-armbian-deb.sh` regenerates + stages them for you). Debs land in
`$WORKSPACE/armbian-build/output/debs`, which is exactly where
`install-combined-kernel.sh` looks by default — the build → install handoff
needs no path edits. Override `ARMBIAN_BUILD=`/`WORKSPACE=` for another layout.

## The scripts

| Script | Runs as | What it does |
|--------|---------|--------------|
| `install-combined-kernel.sh` | root | After `RECOVERY_READY=1`, removes the obsolete `rkvdec2` boot overlay from `armbianEnv.txt` (backs it up), then `dpkg -i` the image + dtb + headers debs for the pinned `PHASH`. A same-name/version install can clobber the prior files; there is no boot menu, so prepare `kernel-revert.sh` and known-good debs first. `DEBS`/`PHASH` are env-overridable; `HASH` is an optional extra version filter. |
| `build-armbian-deb.sh` | user | Builds the **AV1 forward-port** kernel. Regenerates the port patches from the kernel git tree (`KERNEL_TREE`, `git format-patch v6.18..HEAD`), restores/cleans the selected built-in Armbian kernel patch archive, clears the matching userpatch archive, stages the generated patch set, **disables** the two colliding Armbian core media patches (this tree's DT is self-contained), rejects stale heavy-debug user configs, pins the KASAN-verified 6.18.38 source commit unless `ARMBIAN_KERNELBRANCH` is deliberately overridden, then runs `compile.sh` and prints the new `P####-C####` hash. Removing a tracked debug config automatically requests `CLEAN_LEVEL=make-kernel` so stale Kbuild metadata cannot leak across config classes. Ccache is on by default; set `ARMBIAN_USE_CCACHE=no` or explicitly set `ARMBIAN_CLEAN_LEVEL=make-kernel` for a clean retry. `--restore` performs only the built-in archive reset. |
| `kernel-revert.sh` | root (SD rescue) | Get a bad board booting again: flip `/boot` symlinks (`switch`) or chroot-reinstall a good deb (`reinstall`) on the internal disk from an SD-card rescue. Subcommands `list`/`switch`/`reinstall`; target via `--auto`/`--device`/`--root`. |
| `make-fallback-kernel-deb.sh` | user | Repackage a kernel deb (rename `Package:`, drop `Provides:`) into a **co-installable** fallback that won't clobber the primary `linux-image-current-rockchip64` — a permanent recovery kernel `kernel-revert.sh` can `switch` to. Defaults to the official 6.18.35 (26.5.1) debs. |
| `bootstrap-workspaces.sh` | user | Reconstruct the external workspaces: clone `ARMBIAN_BRANCH` (`main` by default), harden the persistent Armbian ccache with compiler-content identity while preserving an existing size policy, clone the five conformance sources at `../tests/conformance/MANIFEST.tsv` commits, and deploy the tracked conformance skeleton. Existing checkouts are never moved and are reported as `branch@commit`; `--check` reports only. Cache rationale: [`../docs/kernel-build-ccache.md`](../docs/kernel-build-ccache.md). |
| `validate-combined.sh` | root | Post-reboot: checks `/dev/mpp_service`, the four cores under `/proc/mpp_service` (`rkvenc-core0/1` + the two decoder cores, see naming note below), `/dev/rga`, and greps boot dmesg for clean probes / no faults. |
| `99-rockchip-codec.rules` | (install to `/etc/udev/rules.d/`) | `GROUP="video" MODE="0660"` on `/dev/mpp_service`, `/dev/dma_heap/*`, and `/dev/rga` so ffmpeg-rockchip runs **without sudo** (you must be in the `video` group; the dma-heap line is **required** — rkmpp allocates buffers there, see [gotchas](../../docs/gotchas.md)). Packaged as a deb by [`packaging/codec-udev/README.md`](../../packaging/codec-udev/README.md), which copies this file at build time — this copy is canonical. |

> **Decoder core naming.** The self-contained-DT forward-port names the decoder
> cores `/proc/mpp_service/rkvdec-core0` and `rkvdec-core1`. The older
> convert-in-place kernel kept Armbian's `video-codec0/1` node names.
> `validate-combined.sh` accepts both forms.

## Typical flow

```bash
# build (on Docker-capable Linux, or native Armbian/Ubuntu Noble)
nohup bash build-armbian-deb.sh &                # ~80-90 min cold, ~10-15 warm
# set install-combined-kernel.sh PHASH to the printed hash (or pass it), then:
sudo RECOVERY_READY=1 PHASH='P####-C####' bash install-combined-kernel.sh
sudo reboot
sudo bash validate-combined.sh                   # expect 2+2 cores + /dev/rga, tainted 0

# non-sudo device access (optional but recommended)
sudo cp 99-rockchip-codec.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Then run the on-hardware smoke tests in [`../tests/`](../tests/README.md).

## PHASH pinning

`install-combined-kernel.sh` pins a specific build via `PHASH` so it can't grab
the wrong deb while still tolerating Armbian minor kernel bumps such as
`6.18.37` → `6.18.38`. Pass `HASH=...` only when you want an additional kernel
version filter. `PHASH` is printed by the build script; the hash↔patch-revision log lives in
[`install.md`](../../install.md).
