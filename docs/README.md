# docs/ - cross-project references

Most technical documentation now lives with the package that owns it:
[`kernel-drivers/`](../kernel-drivers/README.md),
[`userspace-libraries/`](../userspace-libraries/README.md),
[`ffmpeg/`](../ffmpeg/README.md),
[`gnome-remote-desktop/`](../gnome-remote-desktop/README.md),
[`mesa-panfrost-g610/`](../mesa-panfrost-g610/README.md), and
[`packaging/`](../packaging/README.md).

This directory keeps the small set of repo-wide references that are not owned
by one package.

## Cross-project docs

| File | Purpose |
|------|---------|
| [`work-packages.md`](work-packages.md) | The package map, stack diagram, and user/developer reading paths. Start here when you are not sure which package owns a topic. |
| [`bsp/`](bsp/README.md) | User and kernel-developer explanation of what the Rockchip 6.1 BSP kernel adds compared with stock Linux, split into area-specific pages with diagrams. |
| [`source-trees.md`](source-trees.md) | Source pins and reconstruction recipes for every tree that `file:line` citations resolve against. Keep it open when checking anchors. |
| [`gotchas.md`](gotchas.md) | Whole-repo trap index: kernel and FFmpeg traps live here, while GRD, Mesa, packaging, and debug-kernel traps point to their package-owned write-ups. |

## Package docs

| Package | Main docs moved out of `docs/` |
|---------|--------------------------------|
| [`kernel-drivers/`](../kernel-drivers/README.md) | Driver architecture, uAPI, kernel-port status, forward-port narrative, vendor delta, device tree, vanilla-kernel notes, BSP audit, resyncing, rewrite drivers, debug kernel. |
| [`userspace-libraries/`](../userspace-libraries/README.md) | `librockchip_mpp` and `librga` architecture and kernel boundary. |
| [`packaging/`](../packaging/README.md) | Armbian packaging and convert-in-place DT strategy. |
| [`ffmpeg/`](../ffmpeg/README.md) | FFmpeg build/use guide, architecture, implementation comparison, rebase notes, fix candidates, patches. |
| [`gnome-remote-desktop/`](../gnome-remote-desktop/README.md) | Hardware H.264 RDP backend runtime story, design, capture path, profiling, testing, patches. |
| [`mesa-panfrost-g610/`](../mesa-panfrost-g610/README.md) | Mali-G610 transfer investigation, validation, and reproducers. |

## Reading paths

The user and developer reading paths are owned by
[`work-packages.md`](work-packages.md) § User reading paths / § Developer
reading paths — see there rather than duplicating the table here.

## Conventions

- **Anchors.** Every `file:line` citation resolves against a pinned source tree
  in [`source-trees.md`](source-trees.md). If a citation does not match what you
  see, check the tree pin before assuming drift.
- **Ownership.** New package-specific material belongs in the package directory,
  not here. New cross-project maps, source pins, or global trap indexes can live
  in `docs/`.
