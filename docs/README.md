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

## Reading Paths

| Goal | Path |
|------|------|
| Get the board working | [`../install.md`](../install.md) -> [`../kernel-drivers/`](../kernel-drivers/README.md) -> [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md) |
| Understand the kernel stack | [`../kernel-drivers/docs/how-the-drivers-work.md`](../kernel-drivers/docs/how-the-drivers-work.md) -> [`../userspace-libraries/docs/how-the-userspace-libs-work.md`](../userspace-libraries/docs/how-the-userspace-libs-work.md) -> [`../kernel-drivers/docs/dev-uapis.md`](../kernel-drivers/docs/dev-uapis.md) |
| Build userspace media tools | [`../userspace-libraries/`](../userspace-libraries/README.md) -> [`../ffmpeg/`](../ffmpeg/README.md) |
| Package or redistribute | [`../packaging/`](../packaging/README.md) -> [`../packaging/docs/armbian-packaging.md`](../packaging/docs/armbian-packaging.md) -> [`../kernel-drivers/docs/resyncing.md`](../kernel-drivers/docs/resyncing.md) |
| Debug a failure | [`gotchas.md`](gotchas.md) -> [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md) -> [`../kernel-drivers/docs/debug-kernel.md`](../kernel-drivers/docs/debug-kernel.md) |

## Conventions

- **Anchors.** Every `file:line` citation resolves against a pinned source tree
  in [`source-trees.md`](source-trees.md). If a citation does not match what you
  see, check the tree pin before assuming drift.
- **Ownership.** New package-specific material belongs in the package directory,
  not here. New cross-project maps, source pins, or global trap indexes can live
  in `docs/`.
