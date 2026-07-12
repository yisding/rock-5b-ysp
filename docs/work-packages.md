# Work packages — how this repo is organized

The work here improves ROCK 5B support on Armbian's Ubuntu 26.04 images. Most
project directories follow the RK3588 hardware-video path from kernel bases up
to real applications; cross-cutting board bring-up and boot-chain work is
captured through `findings/`, repo-wide scripts, and the status dashboard. The
whole-board [`support coverage inventory`](support-coverage.md) makes areas
outside that media-heavy project taxonomy explicit instead of silently treating
them as supported. The
repo is split **project-by-project**, grouped into categories; this page is the
detailed reading map and owns the canonical stack diagram (the root
[`README.md`](../README.md) carries the front-door taxonomy that links here).

Project-specific docs, patches, scripts, tests, and code artifacts live inside
the owning project. Each project directory answers the same questions near the
top of its `README.md`:

| Field | Meaning |
|-------|---------|
| Purpose | What this project covers and where its code lives (which `../` tree). |
| Developer focus | What someone changing, reviewing, or upstreaming code should learn here. |
| Owns | The files, patches, or docs for which this project is the front door. |
| Depends on | The lower layers or external projects that must already work. |
| Current state | The dated validation or known caveat, with [`../status.md`](../status.md) as the rollup. |

## Stack diagram

```mermaid
flowchart TB
  board["Radxa ROCK 5B<br/>RK3588"]

  subgraph kver["kernel-versions"]
    bsp["BSP overlay vs stock"]
    fport["forward-port + mainline-V4L2 notes"]
  end

  subgraph kernel["kernel-drivers"]
    mpp["mpp<br/>/dev/mpp_service<br/>rkvenc2 + rkvdec2"]
    rga["rga<br/>/dev/rga<br/>RGA3 + RGA2"]
    av1["av1<br/>rkvdec2 AV1 decode"]
    iommu["iommu<br/>CCU / dma-buf mapping"]
    kart["patches/ · scripts/ · tests/"]
  end

  subgraph libs["vendor-libraries"]
    libmpp["mpp<br/>librockchip_mpp"]
    librga["rga<br/>librga"]
  end

  subgraph video["video-libraries"]
    ffmpeg["ffmpeg<br/>h264_rkmpp · scale_rkrga"]
    mesa["mesa<br/>Mali-G610 transfer"]
  end

  subgraph apps["apps"]
    grd["gnome-remote-desktop<br/>RDP H.264 backend"]
    kodi["kodi<br/>DRM PRIME hardware decode"]
  end

  packaging["packaging<br/>delivery + verification"]

  board --> bsp
  bsp --> mpp
  fport -.-> mpp
  mpp --> libmpp --> ffmpeg --> grd
  ffmpeg --> kodi
  rga --> librga --> ffmpeg
  av1 --> libmpp
  iommu -.-> mpp
  iommu -.-> rga
  mesa --> grd
  packaging --> kernel
  packaging --> libs
  packaging --> video
  kart --> mpp
```

## Project map

| Category | Project | Purpose | Entry |
|----------|---------|---------|-------|
| kernel-versions | — | Kernel bases and moving between them: BSP overlay vs stock, forward-port narrative, mainline-V4L2 alternative. | [`../kernel-versions/`](../kernel-versions/README.md) |
| kernel-drivers | mpp / rga / av1 / iommu | In-kernel accelerator drivers. Shared driver model, DT, patches, scripts, tests at the top; per-block notes in each sub-project. | [`../kernel-drivers/`](../kernel-drivers/README.md) |
| vendor-libraries | mpp / rga | `librockchip_mpp` and `librga` userspace: library/kernel split, ioctls, dma-buf imports, ABI facts. | [`../vendor-libraries/`](../vendor-libraries/README.md) |
| video-libraries | ffmpeg / mesa | rkmpp codecs + rkrga filters, and the Mali-G610 transfer investigation behind GRD fallback. | [`../video-libraries/`](../video-libraries/README.md) |
| apps | gnome-remote-desktop / kodi | Real application integration: zero-copy RDP encode and DRM PRIME media playback. | [`../apps/`](../apps/README.md) |
| packaging | — | Installable delivery: DKMS, udev ACLs, PPA source packages, rollback, binary policy. | [`../packaging/`](../packaging/README.md) |
| scripts | — | Repo-wide maintenance checks (links, documentation contracts, whitespace) and board operations. | [`../scripts/`](../scripts/README.md) |

## User reading paths

| Goal | Path |
|------|------|
| Check the repo before handoff | [`../CONTRIBUTING.md`](../CONTRIBUTING.md) -> `bash scripts/check-repo.sh` |
| Find an unassessed board subsystem or choose the next intake test | [`support-coverage.md`](support-coverage.md) -> [`system-baseline.md`](system-baseline.md) -> [`../findings/`](../findings/README.md) |
| Diagnose SD/SPI boot behavior | [`../status.md`](../status.md) track 12 -> [boot investigation](../findings/2026-07-09-rock5b-armbian-sd-boot-investigation.md) -> [`../scripts/`](../scripts/README.md) |
| Capture a reproducible board/runtime baseline | [`system-baseline.md`](system-baseline.md) -> [`../kernel-drivers/tests/conformance/`](../kernel-drivers/tests/conformance/README.md) |
| Get codecs working on a board | [`../install.md`](../install.md) -> [`../kernel-drivers/`](../kernel-drivers/README.md) -> [`../kernel-drivers/scripts/`](../kernel-drivers/scripts/README.md) -> [`../kernel-drivers/tests/`](../kernel-drivers/tests/README.md) |
| Build a command-line media stack | [`../vendor-libraries/`](../vendor-libraries/README.md) -> [`../video-libraries/ffmpeg/`](../video-libraries/ffmpeg/README.md) -> [`../kernel-drivers/tests/transcode-test.sh`](../kernel-drivers/tests/transcode-test.sh) |
| Run accelerated RDP | [`../install.md`](../install.md) -> [`../packaging/`](../packaging/README.md) -> [`../apps/gnome-remote-desktop/`](../apps/gnome-remote-desktop/README.md) |
| Build and test Kodi hardware decode | [`../apps/kodi/`](../apps/kodi/README.md) -> [`../apps/kodi/docs/build-hwaccel.md`](../apps/kodi/docs/build-hwaccel.md) |
| Recover from a failure | [`../status.md`](../status.md) -> [`status-ledger.md`](status-ledger.md) -> [`gotchas.md`](gotchas.md) -> [`debug-kernel.md`](../kernel-drivers/docs/debug-kernel.md) |

## Developer reading paths

| Goal | Path |
|------|------|
| Review the kernel port | [`../kernel-drivers/`](../kernel-drivers/README.md) -> [`how-the-drivers-work.md`](../kernel-drivers/docs/how-the-drivers-work.md) -> [`vendor-forward-port.md`](../kernel-versions/docs/vendor-forward-port.md) -> [`vendor-delta.md`](../kernel-drivers/docs/vendor-delta.md) |
| Review userspace ABI compatibility | [`../vendor-libraries/`](../vendor-libraries/README.md) -> [`how-the-userspace-libs-work.md`](../vendor-libraries/docs/how-the-userspace-libs-work.md) -> [`dev-uapis.md`](../kernel-drivers/docs/dev-uapis.md) -> [`rewrite-drivers.md`](../kernel-drivers/docs/rewrite-drivers.md) |
| Maintain the package set | [`../packaging/`](../packaging/README.md) -> [`armbian-packaging.md`](../packaging/docs/armbian-packaging.md) -> [`resyncing.md`](../kernel-drivers/docs/resyncing.md) |
| Upstream or rebase application work | [`../video-libraries/ffmpeg/docs/rebase-notes.md`](../video-libraries/ffmpeg/docs/rebase-notes.md), [`../video-libraries/ffmpeg/docs/fix-candidates.md`](../video-libraries/ffmpeg/docs/fix-candidates.md), [`../apps/gnome-remote-desktop/patches/`](../apps/gnome-remote-desktop/patches/README.md), [`../video-libraries/mesa/docs/validation.md`](../video-libraries/mesa/docs/validation.md) |

## Maintenance rule

[`../CONTRIBUTING.md`](../CONTRIBUTING.md) is the canonical update contract. It
owns the file-placement rules, evidence lifecycle, status/ledger procedure, and
handoff checks; this page owns only the project taxonomy and reading paths.
