# Work packages - how this repo is organized

This page is the package-oriented reading map. The main split of the project is
the set of work packages below: kernel drivers, userspace libraries, FFmpeg,
GNOME Remote Desktop, Mesa/Panfrost, and packaging. Package-specific docs,
patches, scripts, tests, and code artifacts live inside the owning package.

Every package page should answer the same questions near the top:

| Field | Meaning |
|-------|---------|
| User outcome | What a board user can accomplish from this package. |
| Developer focus | What someone changing, reviewing, or upstreaming code should learn here. |
| Owns | The files, patches, or docs for which this package is the front door. |
| Depends on | The lower layers or external projects that must already work. |
| Current state | The dated validation or known caveat, with [`../status.md`](../status.md) as the rollup. |

## Stack diagram

```mermaid
flowchart TB
  board["Radxa ROCK 5B<br/>RK3588"]

  subgraph kernel["kernel-drivers package"]
    dt["device tree"]
    mpp["/dev/mpp_service<br/>rkvenc2 + rkvdec2"]
    rga["/dev/rga<br/>RGA3 + RGA2"]
    kpatches["patches/"]
    ktools["scripts/ + tests/"]
  end

  subgraph libs["userspace-libraries package"]
    libmpp["librockchip_mpp"]
    librga["librga"]
  end

  subgraph ff["ffmpeg package"]
    codecs["h264_rkmpp / hevc_rkmpp"]
    filters["scale_rkrga / vpp_rkrga"]
  end

  subgraph apps["application packages"]
    grd["gnome-remote-desktop<br/>RDP H.264 backend"]
    mesa["mesa-panfrost-g610<br/>Mali transfer work"]
  end

  subgraph ops["delivery and verification"]
    packaging["packaging"]
  end

  board --> dt
  dt --> mpp
  dt --> rga
  mpp --> libmpp --> codecs --> grd
  rga --> librga --> filters
  mesa --> grd
  packaging --> kernel
  packaging --> libs
  packaging --> ff
  kpatches --> dt
  ktools --> mpp
  ktools --> rga
```

## Package map

| Package | User outcome | Developer focus | Canonical entry |
|---------|--------------|-----------------|-----------------|
| Kernel drivers | Boot and validate `/dev/mpp_service` + `/dev/rga` on RK3588. | MPP/RGA driver model, DT, forward-port deltas, patches, scripts, tests, audit fixes, rewrite track. | [`../kernel-drivers/`](../kernel-drivers/README.md) |
| Userspace libraries | Build or install `librockchip_mpp` and `librga` for apps. | Library/kernel responsibility split, ioctls, dma-buf imports, ABI facts. | [`../userspace-libraries/`](../userspace-libraries/README.md) |
| FFmpeg | Build and use rkmpp codecs plus RGA filters. | FFmpeg hardware frames, fork vs upstream behavior, rebase fixes. | [`../ffmpeg/`](../ffmpeg/README.md) |
| GNOME Remote Desktop | Use the codec stack in a real RDP application. | Backend design, RDP frame flow, zero-copy encode, panvk conversion, greeter ACL. | [`../gnome-remote-desktop/`](../gnome-remote-desktop/README.md) |
| Mesa/Panfrost | Understand the Mali-G610 transfer investigation behind GRD fallback performance. | Panfrost BLIT/COMPUTE transfer correctness, validation, reproducers. | [`../mesa-panfrost-g610/`](../mesa-panfrost-g610/README.md) |
| Packaging | Choose and operate installable delivery channels. | DKMS, udev ACLs, PPA source packages, rollback, binary policy. | [`../packaging/`](../packaging/README.md) |

## User reading paths

| Goal | Path |
|------|------|
| Get codecs working on a board | [`../install.md`](../install.md) -> [`../kernel-drivers/`](../kernel-drivers/README.md) -> [`../kernel-drivers/scripts/`](../kernel-drivers/scripts/README.md) -> [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md) |
| Build a command-line media stack | [`../userspace-libraries/`](../userspace-libraries/README.md) -> [`../ffmpeg/`](../ffmpeg/README.md) -> [`../kernel-drivers/tests/transcode-test.sh`](../kernel-drivers/tests/transcode-test.sh) |
| Run accelerated RDP | [`../install.md`](../install.md) -> [`../packaging/`](../packaging/README.md) -> [`../gnome-remote-desktop/`](../gnome-remote-desktop/README.md) |
| Recover from a failure | [`../status.md`](../status.md) -> [`gotchas.md`](gotchas.md) -> [`debug-kernel.md`](../kernel-drivers/docs/debug-kernel.md) |

## Developer reading paths

| Goal | Path |
|------|------|
| Review the kernel port | [`../kernel-drivers/`](../kernel-drivers/README.md) -> [`how-the-drivers-work.md`](../kernel-drivers/docs/how-the-drivers-work.md) -> [`vendor-forward-port.md`](../kernel-drivers/docs/vendor-forward-port.md) -> [`vendor-delta.md`](../kernel-drivers/docs/vendor-delta.md) |
| Review userspace ABI compatibility | [`../userspace-libraries/`](../userspace-libraries/README.md) -> [`how-the-userspace-libs-work.md`](../userspace-libraries/docs/how-the-userspace-libs-work.md) -> [`dev-uapis.md`](../kernel-drivers/docs/dev-uapis.md) -> [`rewrite-drivers.md`](../kernel-drivers/docs/rewrite-drivers.md) |
| Maintain the package set | [`../packaging/`](../packaging/README.md) -> [`armbian-packaging.md`](../packaging/docs/armbian-packaging.md) -> [`resyncing.md`](../kernel-drivers/docs/resyncing.md) |
| Upstream or rebase application work | [`../ffmpeg/docs/rebase-notes.md`](../ffmpeg/docs/rebase-notes.md), [`../ffmpeg/docs/fix-candidates.md`](../ffmpeg/docs/fix-candidates.md), [`../gnome-remote-desktop/patches/`](../gnome-remote-desktop/patches/README.md), [`../mesa-panfrost-g610/docs/validation.md`](../mesa-panfrost-g610/docs/validation.md) |

## Maintenance rule

When a package gains a new user-facing file, update that package's `README.md`.
When a new top-level package is added, update this page and the repository map
in [`../README.md`](../README.md). When status changes, update
[`../status.md`](../status.md) with a real verification date rather than only
changing prose elsewhere.
