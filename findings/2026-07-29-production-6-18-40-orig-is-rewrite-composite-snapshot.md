# The production 6.18.40 `20260725` orig is a rewrite-composite worktree snapshot, not the validated forward-port series

> Scope: Launchpad PPA kernel packaging (`packaging/ppa/kernel-forward-port/`)
> and the shared Armbian kernel worktree exporter in
> `packaging/ppa/build-source-packages.sh`.
> Source: `packaging/ppa/out/artifacts/linux-rockchip64-ysp_6.18.40+rk3588av1fwport20260725.orig.tar.gz`
> and `…6.18.38+rk3588av1fwport20260723.orig.tar.gz` (format-aware
> extraction); forward-port tree `linux-6.18-rkvenc-av1-fwport @
> 12a7da02bea83` (`git log -L` on `rockchip_iommu_set_fault_handler`);
> rewrite tree `linux-6.18-rkvenc @ cd71f985a784c`; exported series
> `kernel-drivers/patches/forward-port-rk3588/`; live worktree
> `rock5b-kernel-build/armbian-build/cache/sources/linux-kernel-worktree/6.18__rockchip64__arm64`.
> Date: 2026-07-29
> Trust: **BINARY-INSPECTED** / **SOURCE-INSPECTED** / **INFERRED**
> (contamination mechanism)

## Result

The source package behind the installed production kernel
(`6.18.40+rk3588av1fwport20260725`, both `~rk1` and `~rk2`) is **not** a
snapshot of the forward-port line it is named after:

- Its `drivers/iommu/rockchip-iommu.c` is **byte-identical to the
  `rk3588-rewrite-6.18` branch** and differs from the forward-port tree.
  In particular it carries the rewrite hardening's sleeping
  clear-side tail in `rockchip_iommu_set_fault_handler()`, which
  [panicked the board on 2026-07-29](2026-07-29-mpp-isr-fault-handler-clear-sleeps-panics-idle-task.md).
  The forward-port series (`rk3588-fwport-0001…0075`) and tree never
  contained that tail: `git log -L` shows the function unchanged since
  `72ad822990fbe` (2026-07-03), and no series patch adds it.
- The orig contains 10 `mpp-rewrite`/`rga-rewrite` files that exist on
  the rewrite branches only. They are inert in this package (the swept
  `drivers/video/rockchip/{Makefile,Kconfig}` do not reference them),
  but they prove the snapshot's lineage.
- The previous production orig (`6.18.38+rk3588av1fwport20260723`) is
  clean on both counts, so the leak is unique to the 2026-07-25 export.

Mechanism (**INFERRED**): the exporter snapshots the *shared* Armbian
kernel worktree — deliberately including tracked patch modifications
**and untracked patch-added files** — so the export reproduces whatever
build last touched that worktree. On 2026-07-25 that was a
rewrite-composite build; its tracked `rockchip-iommu.c` state and
untracked rewrite driver directories were swept into the "fwport" orig.
As of today the worktree's tracked files are back to forward-port state
(`rockchip-iommu.c` matches the fwport tree byte-for-byte), but the
untracked `mpp-rewrite/` and `rga-rewrite/` directories **still linger**
and would be swept into any next export.

Consequences:

- The shipped `~rk1`/`~rk2` binaries are not the bytes the
  `0074`/`0075` KASAN hardware validation lineage describes; the crash
  bug they shipped with was never part of the validated series.
- The `~rk2` `DMABUF_DEBUG=n` config fix itself remains valid — it is a
  config-only change and `drivers/dma-buf` is untouched by either line —
  but its RDP login verification gate was interrupted by this panic:
  the 08:00:54 reconnect ran the `h264_rkmpp` encoder for ~45 s and then
  the box went down.

Repair path: purge the leftover untracked driver directories (or rebuild
the worktree) after a fresh forward-port Armbian build, verify
`rockchip-iommu.c` matches the fwport tree and no `*-rewrite` paths are
present in the export, then regenerate the orig under a new upstream
version (`FORCE_ORIG=1`, e.g. `…20260729`) and rebuild/sign/upload
(owner's GPG step). The rewrite-side code fix is already committed on
both rewrite tips (`35eb735d21dd8`, `2cf0126529c1c`) for everything that
intentionally builds rewrite content.

## Recurrence check, 2026-08-01

The hazard is not closed, and the worktree is in the bad state again. A
`build-kernel.sh rewrite-debug` run today repopulated
`…/linux-kernel-worktree/6.18__rockchip64__arm64` with the rewrite series:
`drivers/video/rockchip/mpp-rewrite/` and `rga-rewrite/` are present, and
`drivers/iommu/rockchip-iommu.c` again carries the hardened setter
(`platform_get_irq`/`synchronize_irq`). Cutting a forward-port orig from that
worktree right now would reproduce the 2026-07-25 contamination exactly — same
file, same mechanism, same panic.

Two things worth stating plainly, because both are easy to get wrong:

- **The exporter's rewrite-path exclusion does not protect against this.** It
  strips `*-rewrite` paths, which covers the inert driver directories that
  merely proved lineage. The file that actually panicked the board was
  `drivers/iommu/rockchip-iommu.c` — a *shared* path the exclusion never
  touches. The exclusion removes the evidence, not the defect.
- **The worktree is single-tenant.** `build-kernel.sh` stages whichever flavor's
  series into it, so its contents mean nothing except "what the last build put
  there". A forward-port export is only valid immediately after a forward-port
  build, and a rewrite build in flight makes the worktree unusable for export
  until then.

So the precondition on any future forward-port cut is mechanical: run
`build-kernel.sh forward-port`, then verify `rockchip-iommu.c` matches the
fwport tree byte-for-byte and no `*-rewrite` paths exist, and only then export.
Verifying the *export* is not enough on its own; verify the worktree first.

## Boundary

- Only `rockchip-iommu.c` and the rewrite-directory file list were
  compared file-by-file; the full extent of rewrite-branch drift inside
  the 20260725 orig (e.g. other shared files the composite modifies) has
  not been enumerated.
- The KASAN/video-port and rewrite-replacement package origs were not
  inspected; no claim about their provenance is made here.
- The exact build that left the worktree in composite state on
  2026-07-25 was not identified from logs; the mechanism is inferred
  from the exporter's documented copy semantics and the worktree's
  observed mixed state today.
