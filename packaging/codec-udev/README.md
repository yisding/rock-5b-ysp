# Packaging the udev rule

The udev rule that makes `/dev/mpp_service`, the DMA-heaps (`/dev/dma_heap/*`),
and `/dev/rga` usable without root
([`scripts/99-rockchip-codec.rules`](../../scripts/99-rockchip-codec.rules)) is a
**userspace** concern — it shouldn't ride inside the kernel deb. Three ways to
ship it, easiest-to-maintain first.

> **Why dma-heap too?** `rkmpp` allocates every frame/stream buffer from a kernel
> DMA-heap, so granting only `mpp_service` is **not enough** — the encoder still
> dies at MPP init (`MppBufferService get_group failed ... type 1`) because it
> can't open `/dev/dma_heap/system`. The rule grants the `video` group all three
> device classes (`mpp_service`, `dma_heap`, `rga`). See [`docs/06`](../../docs/06-gotchas.md).

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

```bash
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

## Doesn't Armbian already ship these?

Partly — but with a gap that's exactly our device. Armbian's BSP carries
`packages/bsp/rockchip/{60-media,50-vpu,50-hevc,50-mali}.rules`, e.g.:

```
# 60-media.rules
KERNEL=="media*", MODE="0660", GROUP="video"
KERNEL=="rga",    MODE="0660", GROUP="video"
# 50-vpu.rules:  KERNEL=="vpu-service" …    50-hevc.rules: KERNEL=="hevc-service" …
```

Two reasons they don't solve our case:

1. **No `mpp_service` and no `dma_heap` — the rules never caught up to the device
   model.** The `50-vpu`/`50-hevc` rules (`vpu-service`, `hevc-service`) are
   *legacy* — devices from the old `vcodec_service` driver (Rockchip ~3.x/4.4 era,
   pre-MPP-service). The current Rockchip BSP — including the 6.1 vendor kernel —
   replaced all of that with the unified **`mpp_service`** device
   (`MPP_SERVICE_NAME="mpp_service"`, no `vcodec_service.c` left), and its userspace
   allocates buffers from the **`dma_heap`** subsystem. Armbian's rule set never
   added *either* line (`grep -r 'mpp_service\|dma_heap'` over the whole Armbian
   tree finds nothing), and `KERNEL=="media*"` matches neither. So a 6.1-vendor
   Armbian image would hit the *same* gap. (Armbian's `60-media.rules` *does* cover
   `rga`, so that third overlaps harmlessly.)
2. **And this board runs `-current` anyway.** Armbian's everyday rock-5b configs
   (`rockchip64-current/edge`) are mainline-based and use V4L2, not `mpp_service`;
   `armbian-bsp-cli-rock-5b-current` installs only power/wifi/net rules — no media
   rules at all. We're grafting vendor MPP onto a `current` kernel, which Armbian
   doesn't anticipate.

Our rule uses Armbian's exact convention (`GROUP="video" MODE="0660"`) and simply
adds the `mpp_service` and `dma_heap` lines. The *upstream-correct* fix — adding
both to Armbian's `60-media.rules` — is submitted as
[**armbian/build#10085**](https://github.com/armbian/build/pull/10085); this deb is
the local equivalent until/unless that lands.

## Which group — `video` or `render`?

Granting the dma-heaps to a group is standard practice; distros just disagree on
*which* group. The four patterns in the wild:

| Approach | Used by | Headless services (Jellyfin/Plex)? |
|----------|---------|:---:|
| **`GROUP="video"`** (ours) | Jellyfin's Rockchip HWA docs, Raspberry Pi (picamera), postmarketOS | ✅ |
| **`GROUP="render"`** | Armbian's Seeed reComputer (Mali GBM), some libcamera configs | ✅ |
| **`TAG+="uaccess"`** | Fedora / desktop (systemd 257 does it natively for udmabuf) | ❌ logged-in seat user only |
| **world-rw** (`0666` / `chmod a+rw`) | Rockchip vendor configs; Jellyfin's belt-and-suspenders line | ✅ (weakest) |

We use **`video`** because:

- It matches the sibling rules in the same file (`mpp_service`, `rga`, `media*`
  are all `video`), so a codec user needs a single group.
- [Jellyfin's Rockchip HWA guide](https://jellyfin.org/docs/general/post-install/transcoding/hardware-acceleration/rockchip/)
  — the canonical rkmpp consumer, our exact use case — grants the `system*`
  dma-heaps to `video` too. (Ours improves on it: one `SUBSYSTEM=="dma_heap"` line
  covers every heap name vs. their enumerated `system*`, and a clean `0660` group
  rule instead of `0666` + `chmod a+rw`.)
- `uaccess` — the "modern" desktop direction (systemd now udmabuf-tags it
  natively) — is deliberately **avoided**: it only grants the physically
  logged-in seat user, so it does **not** cover a headless `jellyfin`/`plex`
  service account, which is the usual consumer here.

The one nuance: Armbian's *only* pre-existing dma-heap rule (Seeed reComputer,
`render`) targets **Mali GBM** — a render-node concern, not codec buffers — which
is why it picked `render`. On a reComputer board our `60-media.rules` (loaded
after `50-mali-dma-heap.rules`) would set the heaps to `video`; harmless because
the documented setup puts users in **both** `video` *and* `render` (Jellyfin tells
you to join both). See [`docs/06`](../../docs/06-gotchas.md).

## Which to use

- Shipping kernel debs + manual install (this project's flow) → **#1**, the
  standalone deb. Install once, forget. Optionally also do **#2** for convenience.
- Building full Armbian images → **#3**.
