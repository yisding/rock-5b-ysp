# findings/evidence/ — reproducible evidence bundles

Small, reviewable inputs that support dated findings but are not themselves
current-state documentation. Each bundle has a README that records capture
scope and reconstructibility; downloaded images, source trees, binaries, and
build output remain outside Git.

| Bundle | Supports | Contents |
|--------|----------|----------|
| [`2026-08-04-chromium-151-gpu/`](2026-08-04-chromium-151-gpu/README.md) | [Chromium 151 GPU/V4L2-only boundary](../2026-08-04-chromium-151-gpu-working-v4l2-only.md) and [Google Chrome retained-export failure](../2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md) | Complete Chromium and Google Chrome `chrome://gpu` exports, artifact fingerprints, scope, and host-probe commands |
| [`2026-07-28-grd-avc-fullrange709/`](2026-07-28-grd-avc-fullrange709/README.md) | [Promoted GRD AVC full-range BT.709 result](../../apps/gnome-remote-desktop/docs/validation.md#full-range-bt709-signaling) | Exact package delta, fingerprints, VPU metadata A/B, handover timeline, and static client chart |
| [`2026-07-13-u-boot-fit-dtb-race/`](2026-07-13-u-boot-fit-dtb-race/README.md) | [ROCK 5B zero-DTB race](../2026-07-13-rock5b-u-boot-fit-dtb-race.md) | Controlled pre/post logs, minimal fixes, and the Jammy/Noble copy-path appendix |
| [`2026-07-20-armbian-non-radxa-radxa-uboot-audit/`](2026-07-20-armbian-non-radxa-radxa-uboot-audit/README.md) | [Non-Radxa Radxa-U-Boot catalog](../2026-07-20-armbian-non-radxa-radxa-uboot-audit.md) | Board scope, config resolution, and the 203-row audit catalog |
| [`2026-07-20-armbian-radxa-image-fit-audit/`](2026-07-20-armbian-radxa-image-fit-audit/README.md) | [Armbian Radxa image audit](../2026-07-20-armbian-radxa-image-fit-audit.md) | The 244-row image catalog and source-excluded-board inventory |
| [`2026-08-01-armbian-default-tcp-cubic/`](2026-08-01-armbian-default-tcp-cubic/README.md) | [Armbian's reno default](../2026-08-01-armbian-rockchip64-defaults-tcp-reno.md) | Upstream-bound patch restoring CUBIC across nine kernel configs, with its Kconfig-resolution verification |

Evidence belongs here only when committing the small text artifact materially
improves reproducibility. The owning dated finding interprets it during intake;
after promotion, the bundle links directly to the project document that owns
the durable conclusion.
