# Crash-capture debug kernel — ramoops + KASAN workflow

How to build, install, and roll back a **heavily-instrumented Armbian kernel**
for the ROCK 5B that survives a hard crash with evidence: ramoops/pstore keeps
the console log across the reboot, KASAN/lockdep turn latent memory and locking
bugs into loud reports, and `panic_on_oops` + `panic=10` guarantee the box
comes back on its own.

> Provenance: the tracked workflow lives in
> [`scripts/debug-kernel/`](../scripts/debug-kernel/); only the Armbian build
> tree and outputs live in the external
> `/home/yi/Code/kernel/rock5b-kernel-build/` scratch workspace. The wrapper
> calls `build-armbian-deb.sh --stage-only`, so it regenerates the complete
> forward-port patch series and matching Armbian core-patch exclusions before
> every debug build instead of trusting leftover userpatch state.

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

## 2. Pin Armbian "current" to an exact upstream tag

Armbian's `current` branch floats. For a debug kernel you want **the exact
source of the installed kernel**, so line numbers and the driver patch stack
match. The 2026-07-17 forward-port package uses Armbian's 6.18.38 stable-branch
commit `e46dc0adfe39724bcf52cea47b8f9c9aed86a394`, so the tracked config pins that
commit and the wrapper regenerates the forward-port commits as userpatches.
Re-derive and update both inputs whenever the production kernel base moves.

The mechanism is a plain Armbian userpatches config
(`userpatches/config-rock5b-debug-kernel.conf.sh`):

```bash
BOARD="rock-5b"  BRANCH="current"  RELEASE="resolute"
INSTALL_HEADERS="yes"
KERNELBRANCH="commit:e46dc0adfe39724bcf52cea47b8f9c9aed86a394"
KERNEL_BTF="yes"                # keep DWARF/BTF even if RAM looks tight
function custom_kernel_config__rock5b_hard_reboot_debug() {
    opts_y+=( ... )             # §3 below
}
```

plus the base config seeded from the running kernel: the wrapper copies
`/boot/config-$(uname -r)` to `userpatches/linux-rockchip64-current.config`
before building. It first runs `build-armbian-deb.sh --stage-only`, then invokes
`PREFER_DOCKER=yes ./compile.sh rock5b-debug-kernel kernel` by default; output
debs land in `armbian-build/output/debs/`. Set `PREFER_DOCKER=no` only when the
native caller can satisfy Armbian's root relaunch. (Heavy build; the
KASAN+lockdep kernel takes a long while on the board itself.)

## 3. The debug config set — and what each piece catches

All applied via the `custom_kernel_config__…` hook (`opts_y+=` /
`opts_val[]`), so Armbian's own config stays untouched — same zero-edit
philosophy as [Armbian packaging guide](../../packaging/docs/armbian-packaging.md).

| Group | Options | Catches |
|-------|---------|---------|
| Persistent crash capture | `PSTORE`, `PSTORE_RAM`, `PSTORE_CONSOLE`, `PSTORE_PMSG`; `PSTORE_DEFAULT_KMSG_BYTES=262144` | dmesg/console/pmsg records preserved in RAM across a reboot (built-in so pstore exists before userspace) |
| Fail loudly, come back | `PANIC_ON_OOPS`, `SOFTLOCKUP_DETECTOR`, `HARDLOCKUP_DETECTOR`, `DETECT_HUNG_TASK` (timeout 60 s), `WQ_WATCHDOG`, `RCU_CPU_STALL_TIMEOUT=21` | stalls/wedges become panics ramoops can record, instead of a silent hang |
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

## 4. Enable ramoops capture (+ persistent journal)

Ramoops needs a reserved-memory region the boot chain preserves. The debug DTB
package carries `/reserved-memory/ramoops@118000`: `reg = <0x0 0x118000 0x0
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
  `/etc/sysctl.d/99-ramoops-panic-on-oops.conf` (`kernel.panic_on_oops=1`).

Verify after reboot: `test -d /sys/module/ramoops`, `sysctl kernel.panic_on_oops`,
`dmesg | grep -i 'ramoops\|pstore'`, `ls /sys/fs/pstore`.

> **Validation state (2026-07-19):** the high-DRAM ECC failure is measured and
> the replacement range is source-inspected against the pinned BSP. The tracked
> patch is structurally validated, but the rebuilt DTB and a crash-across-reset
> pstore record still need an on-board re-test before this is treated as a
> proven capture path.

**Persistent journal** (so the *previous boot's* userspace logs survive too):
point `/var/log/journal` at `/var/log.hdd/journal` (Armbian's zram log
layout otherwise discards it), set `Storage=persistent`, `SystemMaxUse=256M`,
`SystemMaxFileSize=64M`, `MaxRetentionSec=1month` in `journald.conf`, restart
`systemd-journald`, `journalctl --flush`. Then `journalctl -b -1` works after
a crash.

## 5. Install, hold, roll back

**Install** (`install-debug-kernel.sh` logic): back up the current
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

Pstore mounts at `/sys/fs/pstore` (ramoops backend). After a captured crash:

```bash
sudo ls -l /sys/fs/pstore
# dmesg-ramoops-*    ← the oops/panic kmsg dump (what you usually want)
# console-ramoops-0  ← last console output (PSTORE_CONSOLE)
# pmsg-ramoops-0     ← userspace-written records (PSTORE_PMSG)
sudo cat /sys/fs/pstore/dmesg-ramoops-0 | less
```

Copy the files out, **then delete them** (`sudo rm /sys/fs/pstore/*`) to free
the ramoops slots for the next crash. Pair with `journalctl -b -1` (§4
persistent journal) for the userspace side of the timeline. With
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
