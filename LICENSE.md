# Licensing

This repository uses different licenses for different kinds of material. The
license grants below are grants by **Yi Ding for Yi Ding's own original
copyrightable contributions only**. They do not license any contribution by an
upstream author or another person, relicense third-party material, or broaden
permissions that another copyright holder granted. Other authors' contributions
remain available only under the notices or permissions supplied by those
authors.

## Documentation and non-code

Yi Ding's original documentation and non-code contributions are licensed under
the **Creative Commons Attribution-ShareAlike 4.0 International** license
(`CC-BY-SA-4.0`). This includes Markdown and other prose, diagrams, evidence
records, manifests, tabular data, configuration, workflow definitions, and
packaging metadata, to the extent those files are copyrightable and are not
covered by a more specific upstream notice.

The complete terms are in
[`LICENSES/CC-BY-SA-4.0.txt`](LICENSES/CC-BY-SA-4.0.txt).
When attribution is required, identify Yi Ding as the creator, name this
repository, link to the source when reasonably practicable, and indicate
whether changes were made.

## Code

Yi Ding's original code contributions follow the license of the project they
modify or are intended to accompany:

| Target or scope of Yi Ding's original contribution | License | Typical in-repository locations |
|----------------------------------------------------|---------|---------------------------------|
| Additions to Linux kernel source, including original kernel-code hunks carried in patches | `GPL-2.0-or-later` | only the copyrightable kernel-source portions authored by Yi Ding |
| Standalone kernel packaging, test, and build tooling | The existing file/package notice or the license of its direct upstream target | portions of `kernel-drivers/`, `packaging/dkms/`, and `packaging/ppa/kernel-*/` that are not kernel source |
| U-Boot/boot-firmware tooling, GNOME Remote Desktop code, Plymouth code, and general cross-project operational code | `GPL-2.0-or-later` | Yi Ding-authored portions of `boot-firmware/scripts/`, `apps/gnome-remote-desktop/`, `packaging/ppa/gnome-remote-desktop/`, `packaging/ppa/plymouth/`, and `scripts/` |
| FFmpeg code and patches | `LGPL-2.1-or-later`, unless the affected upstream file or configured build carries a more specific compatible license | Yi Ding-authored portions of `video-libraries/ffmpeg/` and FFmpeg packaging helpers |
| Rockchip VA-API code and patches | `LGPL-2.1-or-later` | Yi Ding-authored portions targeting `rockchip-vaapi` |
| Mesa code, patches, and reproducers | `MIT` | Yi Ding-authored portions of `video-libraries/mesa/` |
| Rockchip MPP and librga code and patches | `Apache-2.0` | Yi Ding-authored portions of `vendor-libraries/mpp/`, `vendor-libraries/rga/`, their conformance patches, and packaging helpers |
| Code with no closer upstream target | `GPL-2.0-or-later` | Yi Ding's shared maintenance and integration code |

The complete primary license texts are in [`LICENSES/`](LICENSES/):

- [`GPL-2.0-or-later`](LICENSES/GPL-2.0-or-later.txt)
- [`GPL-2.0-only`](LICENSES/GPL-2.0-only.txt)
- [`LGPL-2.1-or-later`](LICENSES/LGPL-2.1-or-later.txt)
- [`LGPL-3.0-or-later`](LICENSES/LGPL-3.0-or-later.txt)
- [`MIT`](LICENSES/MIT.txt)
- [`Apache-2.0`](LICENSES/Apache-2.0.txt)

Standalone source files carry an `SPDX-License-Identifier` header where one
license governs the file. That header does not assert ownership of imported
material. In mixed-origin patch files, the table above grants the stated license
only for Yi Ding's original added or changed lines; license notices inside the
payload remain attached to the upstream code they describe.

## Kernel exception and upstream GPL-2.0-only code

Yi Ding's own original kernel contributions are offered under
`GPL-2.0-or-later`, rather than `GPL-2.0-only`. This grant is limited to the
copyrightable lines and portions authored by Yi Ding. It does **not** apply to
the Linux kernel, Rockchip code, patch context, or anyone else's contribution.
Existing upstream files and patch context retain their original notices,
including `GPL-2.0-only` and dual-license expressions. A combined kernel remains
subject to every applicable upstream term; the broader grant does not change
the license of the upstream kernel or of any imported code.

Kernel Debian copyright files continue to identify both the upstream Linux
source and the separately authored packaging in `debian/*` as `GPL-2`; merely
packaging a kernel does not place those standalone files within this exception.

## Third-party and generated material

- An explicit SPDX header, license block, or adjacent upstream license notice
  remains authoritative for the material it identifies.
- Imported Debian packaging retains the licenses recorded in its
  `debian/copyright`; package descriptions of an unpacked upstream source do not
  relicense unrelated repository material.
- Upstream code quoted as patch context retains its upstream license. The
  grants in this file apply only to Yi Ding's original additions.
- Evidence may contain command output, hardware data, or short third-party
  excerpts. Rights Yi Ding does not own are excluded from these grants.
- External source trees, firmware, binaries, and proprietary SDKs referenced by
  the repository are not included in this license grant. Their own terms must
  be checked before redistribution.
- The standard license texts in `LICENSES/` are reproduced as license documents
  and are not themselves relicensed by this policy.

When a file-level notice and this policy differ, preserve the more specific
notice and investigate provenance before copying or changing the file.
