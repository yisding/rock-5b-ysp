# Crash-capture debug kernel — ramoops + KASAN workflow

How to build, install, and roll back a **heavily-instrumented Armbian kernel**
for the ROCK 5B that survives a hard crash with evidence: ramoops/pstore keeps
the console log across the reboot, KASAN/lockdep turn latent memory and locking
bugs into loud reports, and `panic_on_oops` + `panic=10` guarantee the box
comes back on its own.

> Provenance: this workflow lives in the (non-git, dev-box-only) workspace
> `/home/yi/Code/rock5b-kernel-debug/` — `build-rock5b-debug-kernel.sh`,
> `enable-/disable-ramoops-capture.sh`, `enable-persistent-journal.sh`,
> `install-rock5b-debug-kernel.sh`, `restore-stock-current-kernel.sh`, plus
> `boot-backups/` snapshots. This doc transcribes everything needed to
> reproduce it without that workspace. The same workspace's `armbian-build/`
> tree is the one `scripts/build-combined-kernel.sh` drives (see
> [`scripts/README.md`](../scripts/README.md)); its
> `userpatches/kernel/archive/rockchip64-6.18/` carries the two codec patches,
> so a debug build from it **also contains the codec drivers**.

## 1. When you need this

- **IOMMU faults / oopses in the codec or GPU path** that take the box down
  before you can read dmesg — ramoops preserves the final console output.
- **Reproducing [BSP audit](./bsp-audit.md) findings**: several HIGH findings
  (OOB writes, UAF/refcount bugs) are reachable from unprivileged ioctls;
  KASAN + `DEBUG_LIST`/`DMA_API_DEBUG` are what turn "occasionally weird"
  into a precise report with a stack trace. This is the natural runtime gate
  for the [`patches/cleanup-split/`](../patches/cleanup-split/) series.
- Hard-reset GPU crashes (the original motivation was Panthor crashes under
  accelerated Firefox/RDP rendering).
- Locking bugs: `PROVE_LOCKING` / `DEBUG_ATOMIC_SLEEP` catch e.g. the audit's
  sleep-in-atomic class statically at first execution.

## 2. Pin Armbian "current" to an exact upstream tag

Armbian's `current` branch floats. For a debug kernel you want **the exact
source of the installed kernel**, so module vermagic and line numbers match.
The recorded pinning (June 2026, Armbian 26.5.1): the installed
`linux-image-current-rockchip64` package metadata records commit
`acb7cf4c1184e27622be0faf89244d5001ed1e87`, which is the peeled commit of tag
**`v6.18.35`** — so the build config pins `KERNELBRANCH="tag:v6.18.35"`.
For a re-run today, re-derive: read the commit from the installed package's
changelog/metadata, find the stable tag whose peeled commit matches, pin that.
(The board currently runs the combined kernel `6.18.37` #7 — a *different*
build; verified 2026-07-01.)

The mechanism is a plain Armbian userpatches config
(`userpatches/config-rock5b-debug-kernel.conf.sh`):

```bash
BOARD="rock-5b"  BRANCH="current"  RELEASE="resolute"
INSTALL_HEADERS="yes"
KERNELBRANCH="tag:v6.18.35"     # ← the pin
KERNEL_BTF="yes"                # keep DWARF/BTF even if RAM looks tight
function custom_kernel_config__rock5b_hard_reboot_debug() {
    opts_y+=( ... )             # §3 below
}
```

plus the base config seeded from the running kernel: the wrapper copies
`/boot/config-$(uname -r)` to `userpatches/linux-rockchip64-current.config`
before building. Build: `PREFER_DOCKER=no ./compile.sh rock5b-debug-kernel
kernel` — output debs land in `armbian-build/output/debs/`. (Heavy build; the
KASAN+lockdep kernel takes a long while on the board itself.)

## 3. The debug config set — and what each piece catches

All applied via the `custom_kernel_config__…` hook (`opts_y+=` /
`opts_val[]`), so Armbian's own config stays untouched — same zero-edit
philosophy as [Armbian packaging guide](../../packaging/docs/armbian-packaging.md).

| Group | Options | Catches |
|-------|---------|---------|
| Persistent crash capture | `PSTORE`, `PSTORE_RAM`, `PSTORE_CONSOLE`, `PSTORE_PMSG`, `PSTORE_FTRACE`; `PSTORE_DEFAULT_KMSG_BYTES=262144` | console/ftrace/pmsg records preserved in RAM across a reboot (built-in so pstore exists before userspace) |
| Fail loudly, come back | `PANIC_ON_OOPS`, `SOFTLOCKUP_DETECTOR`, `HARDLOCKUP_DETECTOR`, `DETECT_HUNG_TASK` (timeout 60 s), `WQ_WATCHDOG`, `RCU_CPU_STALL_TIMEOUT=21` | stalls/wedges become panics ramoops can record, instead of a silent hang |
| Readable traces | `KALLSYMS_ALL`, `STACKTRACE`, `FRAME_POINTER`, `GDB_SCRIPTS` | symbolized stacks in the pstore dump |
| Memory sanitizers | `KASAN` (`GENERIC`, `INLINE`, `VMALLOC`), `PAGE_OWNER`, `PAGE_POISONING`, `DEBUG_PAGEALLOC`, `PAGE_TABLE_CHECK`, `DMA_API_DEBUG(_SG)`, `DEBUG_SG`, `DEBUG_LIST`, `DEBUG_PLIST`, `DEBUG_NOTIFIERS` | UAF/OOB (the bsp-audit.md HIGH class), DMA mapping misuse (dma-buf import paths, how-the-drivers-work.md §6), corrupted lists |
| Locking diagnostics | `PROVE_LOCKING`, `LOCK_STAT`, `DEBUG_ATOMIC_SLEEP`, `DEBUG_PREEMPT`, `DEBUG_{SPINLOCK,MUTEXES,RT_MUTEXES,RWSEMS,IRQFLAGS}`, `DEBUG_WW_MUTEX_SLOWPATH` | lock-order inversions, sleep-in-atomic |
| DRM/GPU | `DRM_DEBUG_MM`, `DRM_DEBUG_MODESET_LOCK`, `DRM_PANIC` | Panthor/display path corruption |
| Explicitly **off** | `KFENCE`, `KCSAN`, `DEBUG_INFO_NONE/REDUCED` | KASAN is the one sanitizer; lighter/race-oriented ones conflict or add noise |

## 4. Enable ramoops capture (+ persistent journal)

Ramoops needs a reserved-memory region the kernel can find at boot. On Armbian
this is a **user DT overlay** plus boot args — the enable script writes, the
disable script removes, both back up `/boot/armbianEnv.txt` first:

- Overlay `/boot/overlay-user/ramoops.dtbo` (from a ~20-line dts): under
  `/reserved-memory`, node `ramoops@4fe000000` — `reg = <0x4 0xfe000000 0x0
  0x00400000>` (4 MiB high in DRAM), `no-map`, `record-size = 0x40000`,
  `console-size = 0x100000`, `ftrace-size = 0x100000`, `pmsg-size = 0x40000`,
  `ecc-size = <16>`; `user_overlays=ramoops` in `armbianEnv.txt`.
- `extraargs` += `pstore.backend=ramoops pstore.kmsg_bytes=262144
  printk.always_kmsg_dump=1 panic=10`.
- `/etc/modules-load.d/ramoops.conf` (module autoload) and
  `/etc/sysctl.d/99-ramoops-panic-on-oops.conf` (`kernel.panic_on_oops=1`).

> This is a **runtime-applied-once-per-boot overlay**, which is fine — the
> deadlock trap in [gotchas](../../docs/gotchas.md) is about `rmdir`ing a live
> *configfs* overlay, not about boot-time `user_overlays`.

Verify after reboot: `lsmod | grep ramoops`, `sysctl kernel.panic_on_oops`,
`dmesg | grep -i 'ramoops\|pstore'`, `ls /sys/fs/pstore`.

**Persistent journal** (so the *previous boot's* userspace logs survive too):
point `/var/log/journal` at `/var/log.hdd/journal` (Armbian's zram log
layout otherwise discards it), set `Storage=persistent`, `SystemMaxUse=256M`,
`SystemMaxFileSize=64M`, `MaxRetentionSec=1month` in `journald.conf`, restart
`systemd-journald`, `journalctl --flush`. Then `journalctl -b -1` works after
a crash.

## 5. Install, hold, roll back

**Install** (`install-rock5b-debug-kernel.sh` logic): back up the current
`/boot` kernel artifacts (`Image`, `vmlinuz-*`, `initrd.img-*`, `uInitrd-*`,
`System.map-*`, `config-*`, `dtb-*`) into a timestamped `boot-backups/<stamp>/`
dir, `dpkg -i` the newest image+dtb+headers debs from
`armbian-build/output/debs/`, then **`apt-mark hold`**
`linux-{image,dtb,headers}-current-rockchip64` so an apt upgrade can't
silently replace the debug kernel mid-investigation.

**Restore stock** (`restore-stock-current-kernel.sh` logic):

1. `apt-mark unhold` the three packages.
2. `apt-get install --allow-downgrades --reinstall` **image, dtb, AND headers
   together at the same pinned version** (26.5.1 at the time). Installing
   headers separately with `|| true` once let a leftover locally-built KASAN
   headers package shadow the stock ones and silently break every out-of-tree
   module build — the lockstep reinstall is the fix.
3. Run the ramoops disable script (§4 removals).
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
- Don't build the [`packaging/dkms/`](../../packaging/dkms/README.md) package
  while debug headers are installed unless you intend to run it *on* the
  debug kernel.
- Moot for the combined `=y` kernel — nothing is built out-of-tree.

## 7. Reading a crash after reboot

Pstore mounts at `/sys/fs/pstore` (ramoops backend). After a captured crash:

```bash
sudo ls -l /sys/fs/pstore
# dmesg-ramoops-*    ← the oops/panic kmsg dump (what you usually want)
# console-ramoops-0  ← last console output (PSTORE_CONSOLE)
# ftrace-ramoops-0   ← function trace at crash (PSTORE_FTRACE)
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
[`tests/README.md`](../tests/README.md):102–103) were measured on the
**non-debug combined kernel** ([kernel status](./status.md)). The config's
own comment says it: this kernel is for reproducing the crash, not for daily
use. Capture the bug here; measure performance there.
