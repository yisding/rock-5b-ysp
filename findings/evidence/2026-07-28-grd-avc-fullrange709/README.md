# GRD AVC full-range BT.709 experiment evidence

This bundle supports the promoted
[GRD full-range BT.709 validation result](../../../apps/gnome-remote-desktop/docs/validation.md#full-range-bt709-signaling).
It preserves the small, reconstructible inputs and outputs needed to rebuild or
repeat the experiment.

| File | Purpose |
|------|---------|
| [`fullrange-bt709.patch`](fullrange-bt709.patch) | Exact source and Debian-version delta from GRD `release/50.2-rkmpp@cf60b4d9d2c5`. |
| [`package-fingerprints.txt`](package-fingerprints.txt) | Board/package identity, build/inspection gates, hashes, and local ignored-artifact disposition. |
| [`h264-metadata.txt`](h264-metadata.txt) | One-frame `/usr/bin/ffmpeg` RKMPP A/B and `ffprobe` field output. |
| [`handover-timeline.txt`](handover-timeline.txt) | Curated system/user journal events that bound the failed activation before encoder creation. |
| [`rdp-color-test.html`](rdp-color-test.html) | Static sRGB range, color, and chroma-resolution chart for the post-reboot client comparison. |

Built `.deb`, `.ddeb`, `.buildinfo`, and `.changes` files are intentionally not
committed. On the measured board they are preserved under:

```text
/home/yi/Code/rock-5b-ysp/packaging/ppa/out/grd-fullrange709-exp1/
```

That directory is ignored by repository policy. The package is reconstructible
from the public GRD pin, the repository's PPA packaging, and
`fullrange-bt709.patch`; `package-fingerprints.txt` records the exact build
command and artifact checksums.
