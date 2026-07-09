# forward-port-rk3588-av1/

Split AV1/RK3588 forward-port patch series generated from the external Armbian
kernel build workspace and kept here as source text.

## Provenance

Imported from:

```text
/home/yi/Code/kernel/rock5b-kernel-build/forward-port/patches/
```

That external `forward-port/` directory also contains generated fallback and
official-source `.deb` files. Those binaries are intentionally not copied here.
Only the `git format-patch` text series is source material.

## Contents

The series targets Armbian `rockchip64-current` / Linux 6.18 and carries the
self-contained-DT RK3588 MPP/RGA/AV1 forward-port used by the PPA kernel source
package:

- `0001` imports the vendor RK3588 MPP/RGA driver base.
- `0002` adds VEPU580/rkvdec2/RGA device-tree plumbing.
- `0003` through `0017` carry the shared-domain, Verisilicon IOMMU, AV1, RGA,
  SRAM, and hardening forward-port work.
- `0018` through `0022` are diagnostic/debug patches for RGA3 import behavior
  and per-device IOMMU fault/debug counters.

There is no `0012` in the imported sequence.

## Relationship To Other Patch Sets

The older top-level pair
`../rk3588-rkvenc2-01-vcodec-rga-drivers.patch` and
`../rk3588-rkvenc2-02-vcodec-rga-dt.patch` remains the validated non-AV1 base
described by the main patch README. This directory records the newer forward
port used for the co-installable PPA kernel source package.

Do not commit Armbian `output/debs/`, fallback `.deb`s, generated source
packages, or the exported patched kernel worktree here. Regenerate those from
the scripts and source inputs.
