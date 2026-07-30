# Crash-debug kernel — KASAN, lockdep, and ramoops diagnostics

How to build, install, and roll back a **heavily-instrumented Armbian kernel**
for the ROCK 5B that survives a hard crash with evidence: ramoops/pstore keeps
the console log across the reboot, KASAN/lockdep turn latent memory and locking
bugs into loud reports, and `panic_on_oops` + `panic=10` guarantee the box
comes back on its own.

> Provenance: the tracked configs and install tooling live in
> [`scripts/debug-kernel/`](../scripts/debug-kernel/); the build itself runs
> through the unified [`scripts/build-kernel.sh`](../scripts/build-kernel.sh)
> (`forward-port-debug` / `rewrite-debug` flavors, see the
> [kernel-builds map](./kernel-builds.md)). Only the Armbian build tree and
> outputs live in the external `/home/yi/Code/rock-5b/kernel/rock5b-kernel-build/`
> scratch workspace. The entry point regenerates the complete flavor patch
> series and matching Armbian core-patch exclusions before every debug build
> instead of trusting leftover userpatch state.
> Build-cache behavior, including why a changed `.config` can force broad
> Kbuild work without deleting ccache, is documented in the
> [kernel build ccache guide](./kernel-build-ccache.md).

## 1. When you need this

- **IOMMU faults / oopses in the codec or GPU path** that take the box down
  before you can read dmesg — ramoops preserves the final console output.
- **Reproducing [BSP audit](./bsp-audit.md) findings**: several HIGH findings
  (OOB writes, UAF/refcount bugs) are reachable from unprivileged ioctls;
  KASAN + `DEBUG_LIST`/`DMA_API_DEBUG` are what turn "occasionally weird"
  into a precise report with a stack trace. This is the natural runtime gate
  for the [`kernel-drivers/patches/cleanup-split`](../patches/cleanup-split) series.
- Hard-reset GPU crashes (the original motivation was Panthor crashes under
  accelerated Firefox/RDP rendering).
- Locking bugs: `PROVE_LOCKING` / `DEBUG_ATOMIC_SLEEP` catch e.g. the audit's
  sleep-in-atomic class statically at first execution.

## 2. Choosing the Armbian kernel base

Armbian's `current` branch floats. For a debug kernel you generally want **the
same source as the installed kernel**, so line numbers and the driver patch
stack match.

The local flavors now carry **no** `KERNELBRANCH` pin: they inherit
Armbian's mainline-family default, which resolves to
`branch:linux-${KERNEL_MAJOR_MINOR}.y` — the rolling 6.18 stable branch. The
production/KASAN and forward-port/rewrite configs are deliberately kept in
step, so all local kernels track stable together and a KASAN trace still lines
up with the production kernel it is explaining.

The consequence is that the base moves between rebuilds. When a build has to be
reproducible, or directly comparable to an earlier one, pin it explicitly at the
wrapper:

```bash
ARMBIAN_KERNELBRANCH=commit:<sha> \
  bash kernel-drivers/scripts/build-kernel.sh rewrite-debug
```

`build-kernel.sh` passes `KERNELBRANCH` to `compile.sh` only when
`ARMBIAN_KERNELBRANCH` is non-empty; otherwise the flavor's config decides.

The mechanism is a plain Armbian userpatches config
(`userpatches/config-rock5b-debug-kernel.conf.sh`, or the
`config-rock5b-rewrite-debug-kernel.conf.sh` sibling for the rewrite flavor):

```bash
BOARD="rock-5b"  BRANCH="current"  RELEASE="resolute"
INSTALL_HEADERS="yes"
# no KERNELBRANCH: inherit branch:linux-${KERNEL_MAJOR_MINOR}.y (see §2)
KERNEL_BTF="yes"                # keep DWARF/BTF even if RAM looks tight
source ".../ysp-debug-instrumentation.conf.sh"  # defines the shared hook:
# custom_kernel_config__rock5b_hard_reboot_debug() { opts_y+=( ... ) }  # §3 below
```

plus the base config seeded from the running kernel: `build-kernel.sh` copies
`/boot/config-$(uname -r)` to `userpatches/linux-rockchip64-current.config`
before building. It first stages the flavor's patch series, then invokes
`PREFER_DOCKER=yes ./compile.sh rock5b-debug-kernel kernel` (or the rewrite
config name) by default; output debs land in `armbian-build/output/debs/`. Set
`PREFER_DOCKER=no` only when the native caller can satisfy Armbian's root
relaunch. (Heavy build; the KASAN+lockdep kernel takes a long while on the
board itself.)

## 3. The debug config set — and what each piece catches

All applied via the `custom_kernel_config__…` hook (`opts_y+=` /
`opts_val[]`), so Armbian's own config stays untouched — same zero-edit
philosophy as [Armbian packaging guide](../../packaging/docs/armbian-packaging.md).

| Group | Options | Catches |
|-------|---------|---------|
| Persistent crash capture | `PSTORE`, `PSTORE_RAM`, `PSTORE_CONSOLE`, `PSTORE_PMSG`, `PSTORE_FTRACE`; `PSTORE_DEFAULT_KMSG_BYTES=262144` | dmesg/console/pmsg records preserved in RAM across a reboot (built-in so pstore exists before userspace; the ftrace frontend stays compiled but has no DT RAM zone) |
| Fail loudly, stay up | `SOFTLOCKUP_DETECTOR`, `HARDLOCKUP_DETECTOR`, `DETECT_HUNG_TASK` (timeout 60 s), `WQ_WATCHDOG`, `RCU_CPU_STALL_TIMEOUT=21` — **`PANIC_ON_OOPS` deliberately OFF** (`opts_n`) | detectors log stalls/wedges; with `panic_on_oops=0` a process-context oops prints its full trace and the board stays up for journald to capture it live, instead of panic-rebooting into a ramoops region RK3588 discards on reset |
| Readable traces | `KALLSYMS_ALL`, `STACKTRACE`, `FRAME_POINTER`, `GDB_SCRIPTS` | symbolized stacks in the pstore dump |
| Memory sanitizers | `KASAN` (`GENERIC`, `INLINE`, `VMALLOC`), `PAGE_OWNER`, `PAGE_POISONING`, `DEBUG_PAGEALLOC`, `PAGE_TABLE_CHECK`, `DMA_API_DEBUG(_SG)`, `DEBUG_SG`, `DEBUG_LIST`, `DEBUG_PLIST`, `DEBUG_NOTIFIERS` | UAF/OOB (the bsp-audit.md HIGH class), DMA mapping misuse (dma-buf import paths, how-the-drivers-work.md §6), corrupted lists |
| Fault injection | `FAULT_INJECTION`, `FAULT_INJECTION_DEBUG_FS`, `FAILSLAB`, `FAIL_PAGE_ALLOC`, `FAULT_INJECTION_USERCOPY`, `FUNCTION_ERROR_INJECTION` | scoped allocation/usercopy failure tests for rewrite parser/import/control unwind paths via `ioctl-fuzz-smoke.sh` `IOCTL_FUZZ_FAIL_NTH_MAX`, plus the broader recovery-matrix work in `rewrite-validation-plan.md` §4 |
| Locking diagnostics | `PROVE_LOCKING`, `LOCK_STAT`, `DEBUG_ATOMIC_SLEEP`, `DEBUG_PREEMPT`, `DEBUG_{SPINLOCK,MUTEXES,RT_MUTEXES,RWSEMS,IRQFLAGS}`, `DEBUG_WW_MUTEX_SLOWPATH` | lock-order inversions, sleep-in-atomic |
| DRM/GPU | `DRM_DEBUG_MM`, `DRM_DEBUG_MODESET_LOCK`, `DRM_PANIC` | Panthor/display path corruption |
| Explicitly **off** | `KFENCE`, `KCSAN`, `DEBUG_INFO_NONE/REDUCED` | KASAN is the one sanitizer; lighter/race-oriented ones conflict or add noise |

For a device-free preflight before building/installing this kernel,
[`../tests/rewrite-build-gate.sh`](../tests/rewrite-build-gate.sh) now has
`REWRITE_BUILD_PROFILES=memory` for KASAN/fault-injection object coverage and
`REWRITE_BUILD_PROFILES=race` for the separate KCSAN/lockdep object coverage.
Those profiles only prove the rewrite objects compile with the instrumentation;
booted runtime evidence still comes from this debug kernel plus the separate
KCSAN race kernel in [`rewrite-validation-plan.md`](./rewrite-validation-plan.md).

## 4. Configure ramoops diagnostics (+ persistent journal)

Ramoops needs a reserved-memory region the boot chain preserves. This firmware
stack does **not** preserve the configured interval across a warm reset, so the
setup below is a diagnostic/experiment fixture, not a proven crash-capture
channel. Use serial or netconsole for any gate that may reset the board; the
maintained evidence boundary is the
[boot-firmware retention guide](../../boot-firmware/docs/ramoops-retention.md).

The debug DTB package carries `/reserved-memory/ramoops@118000`: `reg = <0x0 0x118000 0x0
0xd0000>`, `no-map`, `record-size = 0x40000`, `console-size = 0x80000`,
`pmsg-size = 0x10000`, and `ecc-size = <16>`. Rockchip's pinned 6.1 BSP
(`develop-6.1@b4ef083dc0c3`, `rk3588-linux.dtsi`) reserves
`0x110000-0x1f0000` for ramoops, uses the first 32 KiB for its firmware boot
log, and starts a separate minidump slot at `0x1f0000`. The upstream node uses
`0x118000-0x1e8000`, deliberately excluding both vendor-only areas and leaving
the last 32 KiB unassigned. Linux RAM starts at `0x200000`. Upstream ramoops
does not support Rockchip's vendor-only `boot-log-size` property.

The old overlay at `0x4fe000000` was wrong: that top-of-DRAM range is rewritten
across an RK3588 reset. Its ten persistent-RAM zones consequently failed ECC
validation on every boot and `/sys/fs/pstore` stayed empty. The enable script
now verifies the fixed node in `/boot/dtb/rockchip/rk3588-rock-5b.dtb`, removes
the obsolete managed overlay and its `user_overlays=ramoops` selection, then
configures the remaining boot/sysctl policy:

- `extraargs` += `pstore.backend=ramoops pstore.kmsg_bytes=262144
  printk.always_kmsg_dump=1 panic=10`.
- `/etc/modules-load.d/ramoops.conf` (harmless with the built-in driver) and
  `/etc/sysctl.d/99-ramoops-panic-on-oops.conf` (`kernel.panic_on_oops=0` —
  debug builds keep the board up on a process-context oops so journald captures
  the live trace; ramoops does not survive an RK3588 reset).

Verify after reboot: `test -d /sys/module/ramoops`, `sysctl kernel.panic_on_oops`,
`dmesg | grep -i 'ramoops\|pstore'`, `ls /sys/fs/pstore`.

> **Validation state (2026-07-27):** the replacement DTB and ramoops Linux
> configuration register correctly, but the interval returns all-zero after a
> software warm reset. Exact TPL/SPL/BL31/U-Boot audits found no direct writer;
> the destructive actor remains unresolved. Do not treat this as a working
> persistent store or attribute the loss to DDR training without the planned
> early-stage witness.

**Persistent journal** (so the *previous boot's* userspace logs survive too):
point `/var/log/journal` at `/var/log.hdd/journal` (Armbian's zram log
layout otherwise discards it), set `Storage=persistent`, `SystemMaxUse=256M`,
`SystemMaxFileSize=64M`, `MaxRetentionSec=1month` in `journald.conf`, restart
`systemd-journald`, `journalctl --flush`. Then `journalctl -b -1` works after
a crash.

## 5. Install, hold, roll back

> ⚠️ **A debug kernel can outgrow the U-Boot load map and die with no output
> at all.** Stock RK3588 U-Boot leaves 127.0 MiB between `kernel_addr_r`
> (`0x00400000`) and `fdt_addr_r` (`0x08300000`). An arm64 `Image` reserves
> `image_size` bytes there — text **plus BSS**, which is much larger than the
> file — so a kernel past that gap zeroes the loaded device tree while clearing
> BSS and dies before console init: no HDMI, no serial, no ramoops, no journal
> boot entry. Measured 2026-07-24: the `P4052-C40aa-H7883` rewrite debug build
> (`image_size` 132.4 MiB) failed exactly this way, while the 2026-07-23
> `P3695` build (113.4 MiB) booted. Raise the addresses once with
> [`set-boot-load-addresses.sh`](../scripts/debug-kernel/set-boot-load-addresses.sh)
> (fdt → 192 MiB, scratch → 200 MiB, initrd → 208 MiB, giving the kernel
> 188 MiB); it only rewrites `/boot/boot.cmd` + `boot.scr`, and **no kernel,
> initrd, or DTB needs regenerating** — `uInitrd` carries load/entry `0`, the
> `Image` header sets the 2 MiB-anywhere placement flag, and DTBs hold no load
> address. `install-kernel.sh` now refuses an oversize image up front
> rather than letting you find out at the next reboot. The revert takes
> `kernel-revert.sh`'s target flags (`--auto` / `--device` / `--root`) and runs
> on a bare rescue image: `--apply` leaves both a copy of the script and a
> `boot.{cmd,scr}.stock-loadaddr` snapshot in the target `/boot`, so
> `sudo bash set-boot-load-addresses.sh --auto --revert` restores stock
> addresses from an SD-card rescue boot even with no `mkimage` installed.

**Install** (`install-kernel.sh` logic): back up the current
`/boot` kernel artifacts (`Image`, `vmlinuz-*`, `initrd.img-*`, `uInitrd-*`,
`System.map-*`, `config-*`, `dtb-*`) into a timestamped `boot-backups/<stamp>/`
dir, `dpkg -i` the newest image+dtb+headers debs from
`armbian-build/output/debs/`, then **`apt-mark hold`**
`linux-{image,dtb,headers}-current-rockchip64` so an apt upgrade can't
silently replace the debug kernel mid-investigation.

**Restore stock** (`(restore recipe in debug-kernel/README.md)` logic):

1. `apt-mark unhold` the three packages.
2. `apt-get install --allow-downgrades --reinstall` **image, dtb, AND headers
   together at the same pinned version** (26.5.1 at the time). Installing
   headers separately with `|| true` once let a leftover locally-built KASAN
   headers package shadow the stock ones and silently break every out-of-tree
   module build — the lockstep reinstall is the fix.
3. Run the ramoops disable script (§4 policy/obsolete-overlay removals).
4. **Verify header/kernel agreement**: diff the `CONFIG_KASAN`/
   `CONFIG_MODVERSIONS` lines of `/boot/config-$(uname -r)` vs
   `/lib/modules/$(uname -r)/build/.config`; if they differ, out-of-tree
   modules built against those headers will not load (§6).

## 6. The KASAN/vermagic uname-collision gotcha

> **2026-07-29 update:** largely historical. The per-slot BRANCHes already
> give every flavor its own `uname -r`, and `build-kernel.sh` now appends
> ` g<sha12>` of the `KERNEL_TREE` HEAD to the build timestamp — `uname -v`,
> via the always-on `ysp-build-stamp` extension — so successive builds
> *within* a slot are source-identified too; `rewrite-kunit-log-check.sh`'s
> identity gate parses it from there. (The release string cannot carry the
> sha: Armbian's deb packaging derives `${kernel_version_family}`
> independently as `${version}-${BRANCH}-${LINUXFAMILY}` and hard-fails on
> any `LOCALVERSION` divergence — measured 2026-07-30.) The collision below
> only applies to the legacy shared-slot era.

The debug kernel and the stock kernel share the same `uname -r`
(`6.18.35-current-rockchip64`), so they **collide** in `/lib/modules` and
`/usr/src`: whichever headers package was installed last is what DKMS and
manual module builds compile against, and a KASAN-instrumented `.ko` will not
load on the stock kernel (and vice versa). Canonical entry:
[gotchas](../../docs/gotchas.md) § Runtime ("KASAN/vermagic kernel-variant
collision"). Consequences here:

- After restoring stock, always run the §5 step-4 header check.
- Don't build the [`packaging/dkms/README.md`](../../packaging/dkms/README.md) package
  while debug headers are installed unless you intend to run it *on* the
  debug kernel.
- Moot for the combined `=y` kernel — nothing is built out-of-tree.

## 7. Reading a crash after reboot

Pstore mounts at `/sys/fs/pstore` (ramoops backend). On firmware where
retention is independently proven, a captured crash appears as:

```bash
sudo ls -l /sys/fs/pstore
# dmesg-ramoops-*    ← the oops/panic kmsg dump (what you usually want)
# console-ramoops-0  ← last console output (PSTORE_CONSOLE)
# pmsg-ramoops-0     ← userspace-written records (PSTORE_PMSG)
sudo cat /sys/fs/pstore/dmesg-ramoops-0 | less
```

Copy the files out, **then delete them** (`sudo rm /sys/fs/pstore/*`) to free
the ramoops slots for the next crash. Pair with `journalctl -b -1` (§4
persistent journal) for the userspace side of the timeline. On the current
ROCK 5B stack these files are expected to be absent after reset; an empty
directory does not prove that no oops occurred. With
`GDB_SCRIPTS` (§3) and BTF (§2) kept, addresses in the dump symbolize against
the debug build's `vmlinux` in the Armbian build tree.

## 8. Perf caveat — never benchmark under this kernel

KASAN-inline instruments every memory access; lockdep instruments every lock;
`DEBUG_PAGEALLOC`/`PAGE_OWNER` add per-page work. Codec throughput numbers on
this kernel are meaningless — the validated figures (720p encode ~359 fps
H.264 / ~297 fps H.265, transcode 17–42× realtime,
[`kernel-drivers/tests/README.md`](../tests/README.md) § Observed results) were measured on the
**non-debug combined kernel** ([kernel status](./forward-port-status.md)). The config's
own comment says it: this kernel is for reproducing the crash, not for daily
use. Capture the bug here; measure performance there.
