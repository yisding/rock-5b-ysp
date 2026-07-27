# docs/ — cross-project references

Most technical documentation lives with the project that owns it (see the
categories in [`../README.md`](../README.md)). This directory keeps the small set
of repo-wide references that are not owned by one project.

## Cross-project docs

| File | Purpose |
|------|---------|
| [`status-ledger.md`](status-ledger.md) | Audit companion to `../status.md`: longer dated cross-track notes without crowding the status dashboard. |
| [`work-packages.md`](work-packages.md) | The project map, stack diagram, and user/developer reading paths. Start here when you are not sure which project owns a topic. |
| [`support-coverage.md`](support-coverage.md) | Whole-board scope inventory: which ROCK 5B areas are tracked, narrowly evidenced, or entirely unassessed, plus the first useful evidence for each gap. |
| [`app-enablement.md`](app-enablement.md) | Planning map for untracked applications (browsers, VLC, HandBrake, mpv, OBS): which plumbing layer each binds to and the estimated enablement cost on this stack. |
| [`system-baseline.md`](system-baseline.md) | Canonical capture contract separating target board, boot path, runtime kernel/userspace, and build host; points to the existing collector and dated truth owners. |
| [`source-trees.md`](source-trees.md) | Source pins and reconstruction recipes for the trees that `file:line` citations resolve against. Pins are corrected in place as provenance is re-measured; new trees are published to GitHub rather than added here. |
| [`gotchas.md`](gotchas.md) | Whole-repo trap index: kernel and FFmpeg traps live here; GRD, Mesa, packaging, and debug-kernel traps point to their project-owned write-ups. |

Repository-wide license status is not a cross-project doc; it lives at
[`../LICENSE.md`](../LICENSE.md).

## Where the rest went

| Topic | Now lives in |
|-------|--------------|
| U-Boot, RK3588 boot stages, firmware lineage comparison, and boot debugging | [`../boot-firmware/`](../boot-firmware/README.md) |
| What the Rockchip 6.1 BSP adds vs stock Linux (13-file subtree) | [`../kernel-versions/bsp/`](../kernel-versions/bsp/README.md) |
| Forward-port narrative, review log, vanilla/mainline-V4L2 notes, and the maximum-mainline build comparison | [`../kernel-versions/`](../kernel-versions/README.md), then [`../packaging/ppa/kernel-maxline/`](../packaging/ppa/kernel-maxline/README.md) |
| MPP/RGA driver architecture, uAPI, DT, audit, resync, rewrite; end-to-end RKNPU/RKNN architecture | [`../kernel-drivers/`](../kernel-drivers/README.md) |
| `librockchip_mpp` and `librga` architecture | [`../vendor-libraries/`](../vendor-libraries/README.md) |
| FFmpeg build/use and fixes; rockchip-vaapi desktop bridge; Mesa transfer investigation | [`../video-libraries/`](../video-libraries/README.md) |
| Hardware H.264 RDP backend | [`../apps/gnome-remote-desktop/`](../apps/gnome-remote-desktop/README.md) |
| Kodi RKMPP / DRM PRIME hardware decode | [`../apps/kodi/`](../apps/kodi/README.md) |
| Armbian packaging and convert-in-place DT strategy | [`../packaging/`](../packaging/README.md) |

## Reading paths

The user and developer reading paths are owned by
[`work-packages.md`](work-packages.md) § User reading paths / § Developer reading
paths — see there rather than duplicating the table here.

## Conventions

The full evidence, ownership, status-update, and handoff workflow lives in
[`../CONTRIBUTING.md`](../CONTRIBUTING.md). The `docs/`-specific conventions are:

- **Anchors.** `file:line` citations resolve against a pinned source tree in
  [`source-trees.md`](source-trees.md). If a citation does not match what you see,
  check the tree pin before assuming drift.
- **Ownership.** New project-specific material belongs in the project directory,
  not here. New cross-project maps, source pins, or global trap indexes can live
  in `docs/`.
- **Vocabulary.** Cross-cutting terms live in [`../glossary.md`](../glossary.md);
  project-specific terms live in each project's `keywords.md`.
