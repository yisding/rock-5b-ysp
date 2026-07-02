# docs/ — the spine

The numbered docs are the project's knowledge spine: how the stack works, what
was changed, and how to keep it alive. **Don't read them as a number line** —
`00` is a reference appendix, not the start. Read them as a path:

```
CORE (any audience)        01 → 02 → 03          drivers → userspace libs → /dev ABIs
SCORECARD                  04                    kernel-port status (whole project: ../STATUS.md)
PORT ENGINEERING           05 → 06 → 07 → 08 → 09   what changed, how much, DT, Armbian, vanilla
TRAPS                      10                    the whole-repo gotcha index
AUDIT                      11                    the BSP security/correctness audit
MAINTENANCE                12                    re-syncing to newer BSP/kernel
REFERENCE APPENDIX         00                    tree pins — open when an anchor needs resolving
ADVANCED / SECOND TRACK    13 → 14               clean-room rewrites; crash-capture kernels
```

## What each doc is

- **[`00-source-trees.md`](00-source-trees.md)** — the anchor appendix: pins and
  reconstruction recipes for **every tree that `file:line` cites resolve
  against** (forward-port tree, audited tree, `$OURS`/`$BSP` measurement pair,
  libmpp/librga/FFmpeg/GRD userspace pins, register-recipe sources, the
  canonical uAPI headers inside patch 01, the rewrite tree). Open it when a
  cite needs verifying, not as a first read.
- **[`01-how-the-drivers-work.md`](01-how-the-drivers-work.md)** — ⭐ **start
  here.** Guided tour of the kernel MPP + RGA drivers, each section "In plain
  terms" then "Under the hood": service/core model, task lifecycle, IOMMU,
  decoder CCU vs encoder DCHS, SRAM/RCB, link mode, the RGA fence path, and
  the register-programming reality.
- **[`02-how-the-userspace-libs-work.md`](02-how-the-userspace-libs-work.md)** —
  the companion: how `librockchip_mpp` (libmpp) and `librga` are structured,
  what they hide, and exactly where each meets the kernel — down to the ioctl
  call sites. Pinned to specific library commits (header note + docs/00 §4).
- **[`03-dev-uapis.md`](03-dev-uapis.md)** — the `/dev/mpp_service` and
  `/dev/rga` ioctl ABIs themselves: commands, structs, flags (including the
  rewrite-track discoveries `SET_ERR_REF_HACK`, `REG_NO_OFFSET`/
  `REG_OFFSET_ALONE`, `POLL_NON_BLOCK`), written for debugging, minimal
  clients, and security review.
- **[`04-status.md`](04-status.md)** — the **kernel-port** scorecard: what is
  hardware-validated (with numbers), what was deliberately skipped, and the
  known limitations (incl. the audit-findings warning and the
  `mpp_iommu_dma_cookie` hazard). Whole-project rollup:
  [`../STATUS.md`](../STATUS.md).
- **[`05-vendor-forward-port.md`](05-vendor-forward-port.md)** — the port
  narrative: the `compat/` shim layer, every 6.18 API adaptation, and the
  bring-up fixes — what each change is and *why*.
- **[`06-vendor-delta.md`](06-vendor-delta.md)** — the quantitative side:
  line-level accounting (~98% Rockchip / ~2% ours), the complete per-change
  table with W-tags, the API-drift ("Since") table, and how to reproduce the
  count.
- **[`07-device-tree.md`](07-device-tree.md)** — the DT design: addresses,
  aliases/core-ids, CCU nodes, SRAM/RCB carve-out, IRQs (decoder GIC SPIs
  verified on the board 2026-07-01), and the three decoder-DT variants
  (convert-in-place / inline / post-6.18 `&vdec0`/`&vdec1` override →
  [`13`](13-rewrite-drivers.md) §5).
- **[`08-armbian-packaging.md`](08-armbian-packaging.md)** — the `media-0001`
  collision and the convert-in-place fix that makes the port a zero-edit
  Armbian userpatch pair.
- **[`09-vanilla-kernel.md`](09-vanilla-kernel.md)** — applying the port to
  vanilla mainline (no Armbian): what carries over, the inline decoder DT
  (verified IRQ/MMU values), and the mainline-V4L2 alternative's trade-offs.
- **[`10-gotchas.md`](10-gotchas.md)** — the whole-repo **trap index**: kernel
  and ffmpeg traps canonical here, one-line pointer rows to the GRD, Mesa,
  packaging, and debug-kernel traps that are canonical in their own trees.
- **[`11-bsp-audit.md`](11-bsp-audit.md)** — the multi-agent BSP audit: 89
  verified findings (16 HIGH; ~70 distinct sites) across the 15 shipped driver
  files, the finding→patch matrix, and how to consume the fixes
  ([`../patches/cleanup-split/`](../patches/cleanup-split/README.md) — runtime
  gate still pending, see [`../STATUS.md`](../STATUS.md)).
- **[`12-resyncing.md`](12-resyncing.md)** — maintenance: the shim-inclusion
  mechanisms, the forward-compat hazard ranking (the `iova_cookie` shadow
  first), the Armbian-bump checklist, and the §6 "when you touch X, update Y"
  propagation table.
- **[`13-rewrite-drivers.md`](13-rewrite-drivers.md)** — the second track:
  clean-room, public-API-only reimplementations of both `/dev` ABIs
  (`mpp-rewrite`/`rga-rewrite`), with full ABI ledgers, the new uAPI facts,
  and the post-6.18 mainline-master bring-up DT. Bring-up status; not the
  shipped stack.
- **[`14-debug-kernel.md`](14-debug-kernel.md)** — the crash-capture workflow:
  a ramoops/pstore + KASAN/lockdep Armbian kernel pinned to an exact upstream
  tag, install/rollback, and reading a crash after reboot.

## Audience shortcuts

| You are… | Read |
|----------|------|
| **Writing an app** on the codecs | [`02`](02-how-the-userspace-libs-work.md) → [`03`](03-dev-uapis.md) → [`../ffmpeg/`](../ffmpeg/README.md) |
| **Packaging / redistributing** | [`08`](08-armbian-packaging.md) → [`../INSTALL.md`](../INSTALL.md) → [`../packaging/`](../packaging/README.md) |
| **Porting / re-syncing** to a newer kernel or BSP | [`05`](05-vendor-forward-port.md) → [`06`](06-vendor-delta.md) → [`12`](12-resyncing.md), with [`00`](00-source-trees.md) open |
| **Security-reviewing / upstreaming** | [`03`](03-dev-uapis.md) → [`11`](11-bsp-audit.md) → [`../patches/cleanup-split/`](../patches/cleanup-split/README.md); rewrite track [`13`](13-rewrite-drivers.md) |
| **Debugging something broken** | [`10`](10-gotchas.md) → [`../tests/`](../tests/README.md) → [`14`](14-debug-kernel.md) |

## Conventions

- **Anchors.** Every `file:line` cite in these docs resolves against a
  specific pinned tree; [`00-source-trees.md`](00-source-trees.md) defines
  them all and gives reconstruction recipes. If a cite doesn't match what you
  see, check which tree you're in before assuming drift.
- **Format.** The core docs (01–03) open every section "In plain terms," then
  "Under the hood" — skim the former, mine the latter.

## What is deliberately NOT here

Subsystem depth lives with its subsystem, not in `docs/`:
[`../ffmpeg/`](../ffmpeg/README.md) (FFmpeg architecture, rebase, fix series),
[`../gnome-remote-desktop/`](../gnome-remote-desktop/README.md) (the GRD
backend, profiling, capture path),
[`../mesa-panfrost-g610/`](../mesa-panfrost-g610/README.md) (Mesa/Panfrost),
[`../packaging/`](../packaging/README.md) (delivery + operations),
[`../scripts/`](../scripts/README.md) + [`../tests/`](../tests/README.md)
(build/validate/smoke-test). `docs/10` indexes their traps; `../STATUS.md`
rolls up their state.
