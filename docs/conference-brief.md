# Conference brief

Use this as the presenter-facing front door. It is intentionally shorter than
the project map and status ledger: it states the claim, the proof, and the
caveats a conference audience should hear.

## One-sentence claim

The ROCK 5B can run a Rockchip vendor MPP + RGA hardware-video stack on an
Armbian Linux 6.18 kernel, with H.264/H.265 encode and decode, RGA
scale/color-convert, full hardware transcode, and a real GNOME Remote Desktop
hardware H.264 encode backend validated on board.

## What is ready to show

| Demo or artifact | Current presenter claim | Evidence |
|------------------|-------------------------|----------|
| Combined Armbian kernel | Primary validated install path. MPP/RGA are built in and tested on ROCK 5B. | [`../install.md`](../install.md), [`../kernel-drivers/docs/forward-port-status.md`](../kernel-drivers/docs/forward-port-status.md) |
| Codec smoke and transcode | H.264/H.265 encode and decode plus FFmpeg RKMPP/RKRGA transcode have run on hardware. | [`../kernel-drivers/tests/README.md`](../kernel-drivers/tests/README.md), [`../status.md`](../status.md) |
| GNOME Remote Desktop | The patch series applies to GRD 50.1 and sustains 60 fps in the measured hardware path. | [`../apps/gnome-remote-desktop/README.md`](../apps/gnome-remote-desktop/README.md), [`../apps/gnome-remote-desktop/docs/profiling.md`](../apps/gnome-remote-desktop/docs/profiling.md) |
| Source delivery | Kernel patches, scripts, package recipes, tests, and findings are in this repo; heavy source trees live externally. | [`../README.md`](../README.md), [`source-trees.md`](source-trees.md) |
| PPA packaging | MPP/librga/FFmpeg/GRD source packaging is imported and upload work is underway. | [`../packaging/ppa/README.md`](../packaging/ppa/README.md) |

## Do not overclaim

- Do not present the PPA as an install path yet. At the last public APT index
  and Launchpad API check (`2026-07-06T16:43:41-07:00`), MPP/librga source
  existed in the public source index, but the arm64/amd64 binary indexes were
  empty and no FFmpeg source was public in the APT index. An upstream FFmpeg
  baseline upload was `Pending` in Launchpad; the higher-version
  `ffmpeg-rockchip-81` source and GRD upload were still held.
- Do not present DKMS as equivalent to the combined kernel. It compiles on the
  documented 6.18 target, but the overlay has not replaced the validated kernel
  path.
- Do not present the BSP audit cleanup series as shippable. It is staged review
  material and still has compile/runtime gates in [`../status.md`](../status.md).
- Do not present the clean-room rewrite as the validated replacement. It has broad
  device-free validation but no booted hardware-validation record yet.
- Do not imply mainline V4L2 provides the same RK3588 H.264/H.265 encode path.
  The validated path here is vendor MPP plus RGA.
- Do not present the repository itself as a polished redistributable release
  until the repo-level license decision is made. Current license state is
  recorded in [`../LICENSE.md`](../LICENSE.md): kernel-derived patches keep
  their inherited licenses, but the repo's own prose/scripts still need an owner
  decision before public redistribution.

## Demo path

1. Start with the stack diagram in [`work-packages.md`](work-packages.md).
2. State that the validated path is the combined Armbian kernel, not DKMS or the
   PPA.
3. Show the board support table in [`../README.md`](../README.md) and the
   dashboard in [`../status.md`](../status.md).
4. For install mechanics, use [`../install.md`](../install.md) and point out the
   udev/dma-heap rule before userspace.
5. For application impact, jump to
   [`../apps/gnome-remote-desktop/docs/profiling.md`](../apps/gnome-remote-desktop/docs/profiling.md).

## Pre-talk checklist

- Re-check the [`../status.md`](../status.md) dashboard and watchlist on the day
  of the talk. Update dates only for facts actually re-verified.
- Run `python3 ../scripts/check-markdown-links.py ..` from this directory, or
  `python3 scripts/check-markdown-links.py` from the repo root, before sharing
  the repo snapshot.
- Re-check the public PPA APT indexes before saying anything install-facing.
  The `2026-07-06T16:43:41-07:00` check still had MPP/librga source only and
  empty public binary indexes.
- Keep the live demo on the combined Armbian kernel path and record the exact
  `PHASH` if a new kernel build is used.
- Do not show generated `.deb`, `.dsc`, `.changes`, `.ko`, or `.dtbo` files as
  source artifacts; generated outputs stay outside git.
- Confirm the license caveat in [`../LICENSE.md`](../LICENSE.md) is acceptable
  for the venue before distributing repo snapshots.
- Re-check upstream/mainline status before making any current comparison with
  mainline V4L2 support; this repo's validated claim is vendor MPP plus RGA.

## Key technical points

- Userspace talks to `/dev/mpp_service` through `librockchip_mpp` and to
  `/dev/rga` through `librga`.
- RGA and MPP also need `/dev/dma_heap/*`; granting only `/dev/mpp_service` is
  not enough for non-root users.
- Decoder CCU is real hardware; encoder DCHS is a software coordination model.
- Decoder RCB is SRAM-backed on RK3588; encoder RCB plumbing is optional and not
  wired in the studied DT.
- The Armbian port converts existing DT nodes in place rather than replacing
  Armbian's base files.

## Current public caveats

The public caveats that can change silently are centralized in
[`../status.md`](../status.md) under the watchlist. Re-check that table before a
talk, especially Launchpad PPA publication, external MRs/PRs, and distro package
versions.
