# debug-kernel

A heavy-debug Armbian `current` Rock 5B kernel for crash reproduction and driver
debugging — KASAN + lockdep/prove-locking + DMA-API checks + lockup/hung-task
detectors + ramoops console/pmsg/ftrace + DRM memory/modeset debug. Built native
(no Docker, no ccache) against the external Armbian build tree (`WORKSPACE`,
default `../../../../kernel/rock5b-kernel-build`), with the config seeded from the
running `/boot/config-$(uname -r)`.

The Armbian userpatch config is tracked here as
[`config-rock5b-debug-kernel.conf.sh`](config-rock5b-debug-kernel.conf.sh).
`build-debug-kernel.sh` installs it into
`$WORKSPACE/armbian-build/userpatches/` before invoking `compile.sh`; the
external build tree is scratch, not the source of truth.

> Perf numbers on this kernel are meaningless (KASAN instruments every access) —
> use the production forward-port build for benchmarking.

## Build

```bash
./build-debug-kernel.sh --install-deps      # --install-deps only needed once
```
Debs land in `$WORKSPACE/armbian-build/output/debs/`.

## Install + enable crash capture

```bash
./install-debug-kernel.sh                    # picks newest debs, backs up /boot,
                                             # dpkg -i, then apt-mark hold
sudo ./enable-ramoops-capture.sh             # ramoops DT overlay + panic_on_oops
sudo ./enable-persistent-journal.sh          # optional: journald survives reboots
sudo reboot
```

`install-debug-kernel.sh` runs `apt-mark hold` on the kernel packages so a routine
`apt upgrade` can't silently replace the debug build. Backups of the replaced
`/boot` artifacts go to `$WORKSPACE/boot-backups/<timestamp>/`.

## Reading a crash

After a panic/oops, pstore dumps land in `/sys/fs/pstore/`; pair them with
`journalctl -b -1`. Full workflow + config rationale:
`../../docs/debug-kernel.md`.

## Restore the stock kernel

`./disable-ramoops-capture.sh` reverses the ramoops overlay/sysctl, then undo the
apt hold and reinstall the stock package (this replaces the old
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

For a booting-again emergency (bad kernel won't boot), the forward-port
`../kernel-revert.sh` flips `/boot` symlinks or chroot-reinstalls a
good deb from an SD-card rescue — it works for any Armbian kernel, debug or not.
