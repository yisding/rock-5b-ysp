# debug-kernel

A heavy-debug Armbian `current` Rock 5B kernel for crash reproduction and driver
debugging — KASAN + lockdep/prove-locking + DMA-API checks + fault injection +
lockup/hung-task detectors + built-in ramoops dmesg/console/pmsg + DRM
memory/modeset debug. Built through Armbian's Docker path by default against the
external Armbian build tree (`WORKSPACE`, default
`../../../../kernel/rock5b-kernel-build`), with the config seeded from the
running `/boot/config-$(uname -r)`.

The Armbian userpatch config is tracked here as
[`config-rock5b-debug-kernel.conf.sh`](config-rock5b-debug-kernel.conf.sh).
`build-debug-kernel.sh` first regenerates and stages the complete forward-port
series through `build-armbian-deb.sh --stage-only`, then installs the config
and the debug-only ROCK 5B ramoops DT patch into
`$WORKSPACE/armbian-build/userpatches/` before invoking `compile.sh`. The base
is pinned to Armbian's exact 6.18.38 commit `e46dc0adfe39`; the external build
tree is scratch, not the source of truth.

> Perf numbers on this kernel are meaningless (KASAN instruments every access) —
> use the production forward-port build for benchmarking.

## Build

```bash
./build-debug-kernel.sh --install-deps      # --install-deps only needed once
```
Debs land in `$WORKSPACE/armbian-build/output/debs/`; the build prints the exact
`P####-C####` needed by the installer.

Set `PREFER_DOCKER=no` only on a supported host where the caller is already
root or can satisfy Armbian's native `sudo` relaunch.

## Prepare recovery before install

A debug build uses the same `linux-*-current-rockchip64` package names as the
daily kernel and can replace its files. ROCK 5B's Armbian boot flow has no
kernel-selection menu. Complete the baseline, rescue-media, known-good-deb, and
`kernel-revert.sh` preparation in [`../../../install.md` §3](../../../install.md)
before continuing.

`install-debug-kernel.sh` captures the running kernel's selected `/boot` files
and package manifest for diagnosis, but that directory is **not** a bootable
rollback and cannot replace the known-good image/DTB debs.

## Install + enable crash capture

```bash
RECOVERY_READY=1 PHASH='P####-C####' \
  ./install-debug-kernel.sh                  # exact debs, diagnostic capture,
                                             # dpkg -i, then apt-mark hold
sudo ./enable-ramoops-capture.sh             # verify packaged DT + panic_on_oops
sudo ./enable-persistent-journal.sh          # optional: journald survives reboots
sudo reboot
```

`install-debug-kernel.sh` runs `apt-mark hold` on the kernel packages so a routine
`apt upgrade` can't silently replace the debug build. The diagnostic capture of
the running release, package versions, boot selectors, and selected artifacts
goes to `$WORKSPACE/boot-backups/<timestamp>/`.

## Reading a crash

> ⚠️ **ramoops/pstore does not survive a reset on this board — do not rely on
> it.** Measured 2026-07-21: even a clean `panic=10` self-reboot leaves
> `/sys/fs/pstore` empty (the continuously-written console zone vanishes too),
> because RK3588 re-initializes/re-trains DRAM on every `SYSTEM_RESET` and this
> Armbian firmware stack (`ddr-v1.20 / bl31-v1.48 / uboot-rmbian`) does not
> preserve the `0x118000` window the way the Rockchip BSP firmware does. See
> [`ramoops-not-preserved-across-warm-reset-rk3588`](../../../findings/2026-07-21-ramoops-not-preserved-across-warm-reset-rk3588.md).
> For an actual call trace use **off-board capture** — serial console on
> `ttyS2` (1500000 baud, USB-TTL adapter) or netconsole to a listener — which
> records the oops before the board resets. `journalctl -b -1` still gives the
> pre-crash tail and usually the oops *header*, but not the trace.

After a panic/oops, `journalctl -b -1` holds the pre-crash tail; the pstore
dumps that *would* pair with it are lost to the reset (above). Full workflow +
config rationale: `../../docs/debug-kernel.md`.

## Restore the stock kernel

`./disable-ramoops-capture.sh` reverses the crash-policy sysctl/boot arguments
and removes the obsolete overlay selection. The fixed ramoops node remains in
the debug DTB until the stock DTB is restored. Then undo the apt hold and
reinstall the stock package (this replaces the old
`restore-stock-current-kernel.sh`, removed in the 2026-07-04 consolidation):

```bash
sudo ./disable-ramoops-capture.sh
sudo apt-mark unhold linux-image-current-rockchip64 linux-dtb-current-rockchip64 linux-headers-current-rockchip64
sudo apt-get install --reinstall --allow-downgrades \
    linux-image-current-rockchip64=26.5.1 \
    linux-dtb-current-rockchip64=26.5.1 \
    linux-headers-current-rockchip64=26.5.1
sudo reboot
```

Adjust `=26.5.1` to the stock version you want. After restoring, confirm
`/boot/config-$(uname -r)` and `/lib/modules/$(uname -r)/build/.config` agree on
`CONFIG_KASAN` — a debug/stock mismatch there means out-of-tree modules won't load
(the vermagic/uname-collision gotcha).

For a booting-again emergency (bad kernel won't boot), the shared
[`../kernel-revert.sh`](../kernel-revert.sh) flips `/boot` symlinks to a distinct
installed release or chroot-reinstalls known-good debs from the prepared SD
rescue — it works for any Armbian kernel, debug or not.
