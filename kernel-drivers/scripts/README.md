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
> (`rock5b-kernel-build`, holding `armbian-build` plus its caches and outputs).
> `bootstrap-workspaces.sh` clones that workspace. Every script derives the
> grouped root from `ROCK5B_WORKSPACE` (default `../../../rock-5b`), defaults
> `WORKSPACE` to `$ROCK5B_WORKSPACE/build/kernel/rock5b-kernel-build`, and takes
> `ARMBIAN_BUILD=` / `WORKSPACE=` overrides.

## Build-host modes

The Ubuntu 26.04 Resolute system being built **is not the same thing as the
build host**. Armbian currently supports native builds on Armbian or Ubuntu
24.04 Noble; any current Docker-capable Linux can use the containerized path.
`compile.sh` prefers Docker when it is usable and falls back to a sudo relaunch
when it is not. Pass `PREFER_DOCKER=no` as an extra wrapper argument to force a
supported native build:

```bash
bash build-kernel.sh forward-port                    # Docker when available
bash build-kernel.sh forward-port PREFER_DOCKER=no   # native Armbian/Noble host
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
| Owns | `build-kernel.sh` (the unified kernel-build entry point, see [`../docs/kernel-builds.md`](../docs/kernel-builds.md)), `prune-kernel-artifacts.py` (bounded external-output retention), `docker-clean-armbian-state.sh` (allowlisted removal of Docker-owned artifacts/worktrees), `install-kernel.sh` (+ the `install-combined-kernel.sh` shim), `install-kernel-hooks.sh` (installs the rewrite KUnit manifest-drift pre-commit guard into the shared kernel git dir), `validate-combined.sh`, `kernel-revert.sh`, `make-fallback-kernel-deb.sh`, `99-rockchip-codec.rules`, `bootstrap-workspaces.sh`, and the [`debug-kernel/`](debug-kernel/README.md) configs. |
| Depends on | Kernel patches in [`../patches/`](../patches/README.md), Armbian build tree setup from [`install.md`](../../install.md), and validation expectations from [`../tests/`](../tests/README.md). |
| Current state | The combined-kernel flow produced the hardware-validated board state recorded in [`status.md`](../../status.md). |

> **⚠️ Mutually exclusive with DKMS.** Do **not** install the
> [`packaging/dkms/README.md`](../../packaging/dkms/README.md) package on top of this
> kernel: the drivers are built in, and DKMS modpost fails with
> `'…' exported twice` (symbol clash with vmlinux). Pick one delivery path.
> The udev rule is needed on **both** paths.

## Prerequisite: the external build workspace

The local build scripts expect an Armbian build tree at
**`$WORKSPACE/armbian-build`** and PPA staging uses its linked Git worktree at
**`$WORKSPACE/armbian-build-ppa`** (default
`WORKSPACE=$ROCK5B_WORKSPACE/build/kernel/rock5b-kernel-build`, gitignored, outside
this repo). Get it with the bootstrap:

```bash
bash bootstrap-workspaces.sh          # Armbian branch + pinned conformance sources
```

Stage the port patches per [`packaging/docs/armbian-packaging.md`](../../packaging/docs/armbian-packaging.md)
(`build-kernel.sh` regenerates + stages them for you). Debs land in
`$WORKSPACE/armbian-build/output/debs`, which is exactly where
`install-combined-kernel.sh` looks by default — the build → install handoff
needs no path edits. Override `ARMBIAN_BUILD=`/`WORKSPACE=` for another layout.
Override `ROCK5B_WORKSPACE=` once when the entire grouped board workspace lives
somewhere else.

## The scripts

| Script | Runs as | What it does |
|--------|---------|--------------|
| `install-kernel.sh` | root | **The kernel installer** for every local flavor. You name one build with `PHASH=` and the **slot is inferred** from the deb filename (`SLOT=` only disambiguates). Refuses `current-rockchip64` (Armbian's) and `ysp-rockchip64` (the PPA). Runs the U-Boot load-address preflight, captures the current boot state, drops the obsolete rkvdec2 overlay, installs, and holds the packages. |
| `install-combined-kernel.sh` | root | Shim → `install-kernel.sh` with `SLOT=video-port`. Kept because docs and dated findings cite it. |
| `build-kernel.sh` | user | **Unified entry point for every ysp kernel build and source-package cut.** Local flavors build production or KASAN/lockdep kernels; `ppa-*` flavors cut source packages; `maxline-*` flavors delegate to the pinned maximum-mainline build. `ppa-forward-port` routes through `armbian-build-ppa`, stages and verifies production patches in its dedicated `KERNEL_EXTRA_DIR=ppa-forward-port` kernel lane, and can overlap a compile because each Armbian checkout owns its mutable patch state and lock. See the complete flavor, worktree, ccache, tmpfs, patch-only, and install behavior in [`../docs/kernel-builds.md`](../docs/kernel-builds.md). |
| `prune-kernel-artifacts.py` | user | Applies the local kernel-artifact retention rule across `output/debs/` and `output/packages-hashed/`. It groups matching image/DTB/header/libc and hashed-cache files by slot plus exact build identity, keeps the two newest recoverable groups per slot, preserves installed matches, explicit `--protect` identities, and groups less than 24 hours old, and leaves unrecognized files untouched. It is a dry run unless host `--apply` or Docker-backed `--docker-apply` is supplied. |
| `docker-clean-armbian-state.sh` | user + Docker | Deletes only explicitly selected artifacts, the two foreign rewrite-driver directories in one lane, or one complete named kernel worktree through the existing local Armbian Docker image. It uses narrow `cache/` or `output/` mounts, no network, a read-only container root, shared build/PPA locks, and a dry run unless `--apply` is supplied. |
| `kernel-revert.sh` | root (SD rescue) | Get a bad board booting again: flip `/boot` symlinks (`switch`) or chroot-reinstall a good deb (`reinstall`) on the internal disk from an SD-card rescue. Subcommands `list`/`switch`/`reinstall`; target via `--auto`/`--device`/`--root`. |
| `make-fallback-kernel-deb.sh` | user | Repackage a kernel deb (rename `Package:`, drop `Provides:`) into a **co-installable** fallback that won't clobber the primary `linux-image-current-rockchip64` — a permanent recovery kernel `kernel-revert.sh` can `switch` to. Defaults to the official 6.18.35 (26.5.1) debs. |
| `setup-ppa-armbian-worktree.sh` | user | Creates or checks the linked `armbian-build-ppa` Git worktree. It shares only the primary Armbian `cache/` (one kernel mirror and central ccache), keeps mutable patch/output state independent, advances only a clean PPA track to the primary HEAD, and refuses unmanaged or dirty state. |
| `bootstrap-workspaces.sh` | user | Reconstruct the external workspaces: clone `ARMBIAN_BRANCH` (`main` by default), create/check the separate PPA Armbian worktree, harden the persistent Armbian ccache with compiler-content identity while preserving an existing size policy, clone the five conformance sources at `../tests/conformance/MANIFEST.tsv` commits, and deploy the tracked conformance skeleton. Existing source checkouts are never moved; `--check` reports only. Cache rationale: [`../docs/kernel-build-ccache.md`](../docs/kernel-build-ccache.md). |
| `validate-combined.sh` | root | Post-reboot: checks `/dev/mpp_service`, the four cores under `/proc/mpp_service` (`rkvenc-core0/1` + the two decoder cores, see naming note below), `/dev/rga`, and greps boot dmesg for clean probes / no faults. **Fails closed** — any ✗ exits 1, so it can gate the on-hardware tests rather than only inform a reader. |
| `99-rockchip-codec.rules` | (install to `/etc/udev/rules.d/`) | `GROUP="video" MODE="0660"` on `/dev/mpp_service`, `/dev/dma_heap/*`, and `/dev/rga` so ffmpeg-rockchip runs **without sudo** (you must be in the `video` group; the dma-heap line is **required** — rkmpp allocates buffers there, see [gotchas](../../docs/gotchas.md)). Packaged as a deb by [`packaging/codec-udev/README.md`](../../packaging/codec-udev/README.md), which copies this file at build time — this copy is canonical. |

> **Decoder core naming.** The self-contained-DT forward-port names the decoder
> cores `/proc/mpp_service/rkvdec-core0` and `rkvdec-core1`. The older
> convert-in-place kernel kept Armbian's `video-codec0/1` node names.
> `validate-combined.sh` accepts both forms.

## Kernel artifact retention

Armbian retains each local kernel build twice: the installable package set under
`output/debs/` and a hashed package archive under `output/packages-hashed/`.
Retention is by complete **slot + build identity**, not individual filename, so
the image, DTB, headers, libc headers, hashed tar, and hashed-cache copies stay
together.

The default rule keeps the two newest recoverable groups per slot. It also keeps
an older group when its image payload matches an installed package, when its
identity matches a repeatable `--protect TOKEN`, or while it is less than 24
hours old. Groups with no image or hashed tar are treated as partial orphans.
Unknown files are reported and never removed. A live `.ysp-build-marker.*`
blocks pruning, and all selected paths are identity- and permission-checked
before the first deletion.

Review the exact keep/delete plan first:

```bash
python3 prune-kernel-artifacts.py
```

Preserve a build cited by an active investigation, then permanently apply the
reviewed plan:

```bash
python3 prune-kernel-artifacts.py --protect P7215-Cad24
python3 prune-kernel-artifacts.py --protect P7215-Cad24 --apply
python3 prune-kernel-artifacts.py --protect P7215-Cad24 --docker-apply
```

Protection tokens apply to that invocation, so repeat them on the corresponding
apply command. `--apply` unlinks through the host and is sufficient when the
artifact parent directories are writable; `--docker-apply` sends the same
identity-checked retention plan through `docker-clean-armbian-state.sh`, using
the local Armbian image for root-owned Docker directories. Use `--drop-slot
SLOT` when a renamed or retired package slot should not retain its otherwise
newest build. Use `--keep N` or `--min-age-hours HOURS` only for a deliberate
one-off policy change. Both apply modes permanently unlink the selected
external artifacts rather than moving them to trash, because retaining a
second copy would not reclaim build space.

## Docker-owned Armbian state cleanup

Do not recursively `chown` Armbian's kernel cache: the next containerized build
would create root-owned files again, and mixed ownership makes failure modes
harder to reason about. Use the same local Armbian build image to remove a
suspect lane completely, including its Git worktree registration. Review first:

```bash
bash docker-clean-armbian-state.sh worktree 6.18__rockchip64__arm64
bash docker-clean-armbian-state.sh --apply worktree 6.18__rockchip64__arm64
```

The next build recreates that lane from the shared bare kernel repository. To
remove only stale rewrite directories that block a forward-port provenance
check, keep the lane and use the narrower action:

```bash
bash docker-clean-armbian-state.sh foreign-rewrite 6.18__rockchip64__arm64
bash docker-clean-armbian-state.sh --apply foreign-rewrite 6.18__rockchip64__arm64
```

Every action shares the state lock for its owning Armbian track; deleting the
dedicated `__ppa-forward-port` lane also shares the complete PPA stage/export
lock. The
canonical `build-kernel.sh ppa-forward-port` flow automatically performs this
complete PPA-lane removal before each fresh patch-only stage. The
helper refuses absolute paths, traversal, symlinks, arbitrary worktree names,
and artifact paths outside `output/debs/` and `output/packages-hashed/`. It
resolves the configured image tag to an existing local immutable image ID and
never pulls during cleanup. The container drops every Linux capability except
`DAC_OVERRIDE`, the one permission needed for container root to unlink a
root-owned child from an otherwise user-owned Armbian cache/output directory.

Point `--armbian-build` at the owning track. This selects that track's state
lock while still using the same local Docker image:

```bash
bash docker-clean-armbian-state.sh \
  --armbian-build "$WORKSPACE/armbian-build-ppa" \
  worktree 6.18__rockchip64__arm64__ppa-forward-port
bash docker-clean-armbian-state.sh \
  --armbian-build "$WORKSPACE/armbian-build-ppa" --apply \
  worktree 6.18__rockchip64__arm64__ppa-forward-port
```

## Typical flow

```bash
# build (on Docker-capable Linux, or native Armbian/Ubuntu Noble)
nohup bash build-kernel.sh forward-port &        # ~80-90 min cold, ~10-15 warm
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
