# ROCK 5B Armbian builder: native host, branch/release map, and remote-cache behavior

> Scope: standing up the YSP dev VM as the `armbian/build` builder for the ROCK 5B, and the branch/release/cache facts that decide what it actually compiles
> Source: `armbian/build` @ `VERSION` `26.08.0-trunk` (cloned `~/armbian-build`) — `config/boards/rock-5b.conf`, `config/sources/families/rockchip-rk3588.conf`, `config/sources/families/include/rockchip64_common.inc`, `config/distributions/resolute/support`; build host `ubuntu244` (`uname`, `lscpu`, `lsblk`, two `./compile.sh kernel` runs and their `output/logs`)
> Date: 2026-07-08
> Trust: MEASURED (host, disk grow, native compile reached, remote-cache hit) / CONFIG-INSPECTED (branch + release map) / HYPOTHESIS (BTF-on-8GB survival, unproven)

## The fact

### The builder is a Noble aarch64 VM, which is a first-class *native* Armbian host

"The box" is **not** the ROCK 5B — it is a VMware VM on Apple Silicon (`systemd-detect-virt` = `vmware`, `lscpu` Vendor `Apple`): Ubuntu **24.04.4 Noble aarch64**, 5 vCPU, **7.7 GiB RAM**, 4 GiB swap, host kernel `6.8.0-134-generic`. Noble aarch64 is an officially supported *native* `armbian/build` host (docs list `x86_64 / aarch64 / riscv64`, native on Ubuntu Noble, `~50 GB` disk, `≥8 GB` RAM). So **no Docker** is needed and the ROCK 5B target builds **arm64-on-arm64, no QEMU** — confirmed live: `Native compilation [ target arm64 on host arm64 ]`, `aarch64-linux-gnu-gcc 13.3.0`.

`compile.sh` run as a normal user **re-launches its whole self under sudo** (`sudo … bash compile.sh … ARMBIAN_RELAUNCHED=yes SET_OWNER_TO_UID=1000`), so the entire build runs as root. That is a **single** sudo auth at t=0, not per-step; the root process then runs to completion regardless of the sudo timestamp timeout. This box has **no passwordless sudo**, so that one auth is unavoidable.

### Disk had to grow first (the only real blocker)

Root LV was 48.47 GiB on a 96.9 GiB partition — the Ubuntu-installer default leaves ~half the VG unallocated. Grown **online, non-destructively** (ext4):

```
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```

48.47 → **96.95 GiB** (78 GB free), clearing Armbian's ~50 GB floor (only 33 GB was free before). With that headroom the build chose the full bare-tree kernel path (`enough disk space (78821 MiB)`).

### Branch → kernel map for `rock-5b` (family `rockchip-rk3588`)

`config/boards/rock-5b.conf` sets `BOARDFAMILY="rockchip-rk3588"`, `KERNEL_TARGET="current,edge,vendor"` (first = default). Versions come from `rockchip-rk3588.conf` (legacy/vendor cases) and `rockchip64_common.inc` (current/edge/bleedingedge cases):

| `BRANCH=` | Kernel | Source / config anchors |
|-----------|--------|-------------------------|
| `legacy` | 5.10 BSP (deprecated) | `KERNELBRANCH=branch:rk-5.10-rkr8`, `KERNELPATCHDIR=rk35xx-legacy` |
| `vendor` | **6.1** BSP → `6.1.115` | `branch:rk-6.1-rkr5.1`, `KERNELPATCHDIR=rk35xx-vendor-6.1`, `LINUXCONFIG=linux-rk35xx-vendor`; userpatch dir `userpatches/kernel/rk35xx-vendor-6.1` |
| **`current`** *(default)* | **6.18 mainline** | `KERNEL_MAJOR_MINOR=6.18`, `LINUXFAMILY=rockchip64`, `LINUXCONFIG=linux-rockchip64-current` |
| `edge` | 7.1 mainline | `KERNEL_MAJOR_MINOR=7.1` |
| `bleedingedge` | 7.2 mainline | `KERNEL_MAJOR_MINOR=7.2` |

The **vendor 6.1 BSP** is the tree the YSP MPP/RGA drivers are forward-ported *from*; **`current` = mainline 6.18** is the YSP forward-port *target*. So the builder base is `BRANCH=current`, not `edge`.

### Release: Ubuntu 26.04 = `resolute`, and Armbian supports it

`config/distributions/resolute/support` = `supported` (same tier as `noble`/`trixie`). So the real target invocation is:

```
BOARD=rock-5b  BRANCH=current  RELEASE=resolute   (+ userpatches)
```

### The remote artifact cache means an *unpatched* build does not compile

First run — `./compile.sh kernel BOARD=rock-5b BRANCH=vendor` — finished in **0:19 min** without compiling: it pulled prebuilt `.deb`s from `ghcr.io/armbian/os/kernel-rk35xx-vendor:6.1.115-S…-C43e3…` ("Artifact is available in remote cache" → "obtained from remote cache"). The artifact tag hashes drivers + patches + `.config` + config-hook + framework, so **any userpatch changes the hash → cache miss → local compile**. `ARTIFACT_IGNORE_CACHE=yes` forces a local build regardless (used to prove native compilation). Consequence: **once the MPP+RGA userpatches are wired in, every build compiles for real** — the cache stops shadowing the work.

### RAM is right at the BTF cliff (unproven)

Armbian gates `CONFIG_DEBUG_INFO_BTF` on available RAM (~`6451 MiB` threshold). On this box it cleared by only **19–45 MiB** (`Considering available RAM for BTF build [ 6470/6451 MiB ]`, and `6627/6451` on a later run) and enabled BTF. Early native compile peaked at only **1.9 GB used / 0 swap**, but both runs were aborted **before** the BTF/`pahole` link over `vmlinux` — which is the actual memory peak. So **BTF survival on 8 GB is not yet proven**. If it OOMs: grow swap, lower kernel `-j`, or disable `DEBUG_INFO_BTF`; cleanest is bumping the VM to 12–16 GB in VMware Fusion.

## Why it matters / follow-up

- **Target build (once patches are wired):** `./compile.sh build BOARD=rock-5b BRANCH=current RELEASE=resolute KERNEL_CONFIGURE=no …` with the MPP+RGA series under the `current` kernel userpatch dir. Confirm the exact dir from the build log line `User patches directory for kernel [ … ]`: vendor emitted `userpatches/kernel/rk35xx-vendor-6.1`; `current` is family `rockchip64` on 6.18, so it mirrors Armbian's `patch/kernel/archive/rockchip64-6.18/` (the same `rockchip64-6.18` branch this repo's `media-0001` watchlist row already tracks) under `userpatches/kernel/…`. The `userpatches/` scaffold already exists in the clone (`kernel/`, `u-boot/`, `customize-image.sh`).
- **Open:** prove the BTF link survives 8 GB on a full `current` (6.18) compile, or bump VM RAM. Also on the watchlist as dev-box state.
- **Open:** wire `kernel-drivers/patches/` (MPP + RGA forward-port) into the `current` userpatch dir so the cache misses and the box compiles the patched 6.18 kernel — this is work-package "Wire MPP+RGA patches into userpatches".
