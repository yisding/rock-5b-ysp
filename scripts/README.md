# scripts/

The build → install → validate trio for the combined kernel, plus the udev rule.

> **Paths.** These scripts contain absolute paths from the original dev box
> (`/home/yi/Code/rock5b-kernel-debug/...`). Treat them as reference and adjust
> the `BUILD_DIR` / `DEBS` / bundle paths near the top of each for your layout.
> The *logic* is what matters.

| Script | Runs as | What it does |
|--------|---------|--------------|
| `build-combined-kernel.sh` | user | Wraps `./compile.sh kernel BOARD=rock-5b BRANCH=current KERNEL_CONFIGURE=no USE_CCACHE=yes`. Crucially passes `USE_CCACHE` as an **argument** (env var wouldn't reach the Docker build — see [`docs/06`](../docs/06-gotchas.md)). Prints ccache growth + the new `P####-C####` hash. |
| `install-combined-kernel.sh` | root | Removes the obsolete `rkvdec2` boot overlay from `armbianEnv.txt` (backs it up), then `dpkg -i` the image + dtb + headers debs for the pinned `PHASH`. Old kernel stays selectable. |
| `validate-combined.sh` | root | Post-reboot: checks `/dev/mpp_service`, the four cores under `/proc/mpp_service` (`rkvenc-core0/1`, `rkvdec-core0/1`), `/dev/rga`, and greps boot dmesg for clean probes / no faults. |
| `99-rockchip-codec.rules` | (install to `/etc/udev/rules.d/`) | `GROUP="video" MODE="0660"` on `/dev/mpp_service` + `/dev/rga` so ffmpeg-rockchip runs **without sudo** (you must be in the `video` group). |

## Typical flow

```bash
# build (on a fast box or the board itself)
nohup bash build-combined-kernel.sh &            # ~80-90 min cold, ~10-15 warm
# set install-combined-kernel.sh PHASH to the printed hash, then:
sudo bash install-combined-kernel.sh
sudo reboot
sudo bash validate-combined.sh                   # expect 4 cores + /dev/rga, tainted 0

# non-sudo device access (optional)
sudo cp 99-rockchip-codec.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

`install-combined-kernel.sh` pins a specific build via `HASH`/`PHASH` so it can't
grab the wrong deb. Update `PHASH` after each build (the value is printed by
`build-combined-kernel.sh`).
