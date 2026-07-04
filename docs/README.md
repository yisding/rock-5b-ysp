# docs/ — cross-project references

Most technical documentation lives with the project that owns it (see the
categories in [`../README.md`](../README.md)). This directory keeps the small set
of repo-wide references that are not owned by one project.

## Cross-project docs

| File | Purpose |
|------|---------|
| [`work-packages.md`](work-packages.md) | The project map, stack diagram, and user/developer reading paths. Start here when you are not sure which project owns a topic. |
| [`source-trees.md`](source-trees.md) | Source pins and reconstruction recipes for the trees that `file:line` citations resolve against. Frozen — not actively expanded (useful trees are being published to GitHub instead). |
| [`gotchas.md`](gotchas.md) | Whole-repo trap index: kernel and FFmpeg traps live here; GRD, Mesa, packaging, and debug-kernel traps point to their project-owned write-ups. |

## Where the rest went

| Topic | Now lives in |
|-------|--------------|
| What the Rockchip 6.1 BSP adds vs stock Linux (13-file subtree) | [`../kernel-versions/bsp/`](../kernel-versions/bsp/README.md) |
| Forward-port narrative, review log, vanilla / mainline-V4L2 notes | [`../kernel-versions/docs/`](../kernel-versions/README.md) |
| MPP/RGA driver architecture, uAPI, DT, audit, resync, rewrite | [`../kernel-drivers/`](../kernel-drivers/README.md) |
| `librockchip_mpp` and `librga` architecture | [`../vendor-libraries/`](../vendor-libraries/README.md) |
| FFmpeg build/use, rebase, fix candidates; Mesa transfer investigation | [`../video-libraries/`](../video-libraries/README.md) |
| Hardware H.264 RDP backend | [`../apps/gnome-remote-desktop/`](../apps/gnome-remote-desktop/README.md) |
| Armbian packaging and convert-in-place DT strategy | [`../packaging/`](../packaging/README.md) |

## Reading paths

The user and developer reading paths are owned by
[`work-packages.md`](work-packages.md) § User reading paths / § Developer reading
paths — see there rather than duplicating the table here.

## Conventions

- **Anchors.** `file:line` citations resolve against a pinned source tree in
  [`source-trees.md`](source-trees.md). If a citation does not match what you see,
  check the tree pin before assuming drift.
- **Ownership.** New project-specific material belongs in the project directory,
  not here. New cross-project maps, source pins, or global trap indexes can live
  in `docs/`.
- **Vocabulary.** Cross-cutting terms live in [`../glossary.md`](../glossary.md);
  project-specific terms live in each project's `keywords.md`.
