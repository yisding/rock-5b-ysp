# Packaging the udev rule

The udev rule that makes `/dev/mpp_service` + `/dev/rga` usable without root
([`scripts/99-rockchip-codec.rules`](../../scripts/99-rockchip-codec.rules)) is a
**userspace** concern — it shouldn't ride inside the kernel deb. Three ways to
ship it, easiest-to-maintain first.

## 1. A standalone `.deb` (recommended) — this directory

A tiny `Architecture: all` package that drops the rule in
`/usr/lib/udev/rules.d/` (the package-owned location, no conffile prompts) and
reloads udev in its `postinst` — so it takes effect immediately, no reboot, and
**survives kernel updates** (it's independent of the kernel deb).

```bash
bash build-deb.sh                       # → rk3588-codec-udev_1.0_all.deb
sudo dpkg -i rk3588-codec-udev_1.0_all.deb
# postinst runs: udevadm control --reload-rules && udevadm trigger
```

`build-deb.sh` copies the canonical rule from `scripts/` so there's one source of
truth. The built `.deb` and the copied rule are gitignored — commit the *source*
(`root/DEBIAN/*`, `build-deb.sh`), build the artifact on demand.

> **Group membership still required.** The rule grants the **`video`** group
> access; users must be in it. Your login user usually already is; the Jellyfin
> service account is not — `sudo usermod -aG video jellyfin` (and often `render`).

## 2. Fold it into `install-combined-kernel.sh` (quickest)

If you only ever deploy via the install script, add two lines so the rule lands
whenever you install the kernel:

```sh
install -m0644 99-rockchip-codec.rules /etc/udev/rules.d/
udevadm control --reload-rules && udevadm trigger
```

No new artifact, but it's a script step, not a real package, and it re-copies on
every kernel install.

## 3. Bake it into a full Armbian image (only for image builds)

If you build a complete Armbian *image* (not just the kernel deb), Armbian's
build framework copies anything under `userpatches/overlay/` into the rootfs:

```
userpatches/overlay/99-rockchip-codec.rules        # the rule
# userpatches/customize-image.sh:
install -m0644 /tmp/overlay/99-rockchip-codec.rules /etc/udev/rules.d/
```

Doesn't apply to the kernel-only `compile.sh kernel` flow (which produces debs,
not an image), so it's the right answer only if you're rolling whole images.

## Which to use

- Shipping kernel debs + manual install (this project's flow) → **#1**, the
  standalone deb. Install once, forget. Optionally also do **#2** for convenience.
- Building full Armbian images → **#3**.
