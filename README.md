# rock-5b-ysp — ROCK 5B RK3588 support record

This repository is the public integration, evidence, and patch-delivery record
for Radxa ROCK 5B support on Armbian's Ubuntu 26.04 (Resolute) images. It covers
board bring-up and packaging, with the deepest evidence following the RK3588
media stack from kernel drivers through vendor libraries, FFmpeg/VA-API, and
applications. Dated claims and the next proof always live in
[`status.md`](status.md).

The source trees and build outputs live in the sibling `rock-5b/` workspace;
this repository contains maintained explanations, patches, tests, operations,
and fresh findings. Start from the task routes below. Use
[`docs/work-packages.md`](docs/work-packages.md) when you need the complete
project map, stack diagram, or a multi-document reading path.

## Local workspace layout

```text
~/Code/
├── rock-5b-ysp/       # this public integration and evidence record
├── rock-5b-security/  # private disclosure and memory-safety material
├── rock-5b/           # external source trees, builds, packages, evidence
├── tmp/               # shared scratch
└── .ccache/           # the only compiler-cache store for ~/Code builds
```

Relative external paths such as `../rock-5b/kernel/…` resolve from this
repository root. `ROCK5B_WORKSPACE` may relocate the grouped board workspace;
component-specific variables such as `CONFORMANCE_ROOT`, `WORKSPACE`,
`WORKSPACE_ROOT`, `MESA_BUILD`, and `FFDIR` take precedence. Build directories
belong under `../rock-5b/build/`; the compiler cache remains `~/Code/.ccache`.
Exact source pins and reconstruction routes live in
[`docs/source-trees.md`](docs/source-trees.md).

## Start here

Choose the shortest route for the job. These links point to maintained owners
instead of repeating status, commands, or the project taxonomy here.

### Resume or operate the board

| Goal | Start here |
|------|------------|
| Resume work or find the next proof | [`status.md`](status.md) |
| Decide whether the public PPA fits and verify the stack | [`docs/ppa-support.md`](docs/ppa-support.md) |
| Install, validate, switch, or recover a kernel/media path | [`install.md`](install.md) |
| Capture exact board, boot, kernel, and userspace identity | [`docs/system-baseline.md`](docs/system-baseline.md) |
| Diagnose a known trap or unexplained failure | [`docs/gotchas.md`](docs/gotchas.md) |
| See unassessed board areas and the first useful evidence | [`docs/support-coverage.md`](docs/support-coverage.md) |

### Recover the technical model

| Goal | Start here |
|------|------------|
| Choose a project or follow the whole stack | [`docs/work-packages.md`](docs/work-packages.md) |
| Understand the boot chain | [`boot-firmware/`](boot-firmware/README.md) |
| Compare BSP, forward-port, and maximum-mainline kernels | [`kernel-versions/`](kernel-versions/README.md) |
| Understand or test the kernel accelerator drivers | [`kernel-drivers/`](kernel-drivers/README.md) |
| Follow the userspace ABI and vendor libraries | [`vendor-libraries/`](vendor-libraries/README.md) |
| Trace FFmpeg, VA-API, Mesa, and application integration | [`video-libraries/`](video-libraries/README.md) → [`apps/`](apps/README.md) |
| Understand package delivery and recovery | [`packaging/`](packaging/README.md) |
| Decode shared terms such as MPP, RGA, CCU, and DCHS | [`glossary.md`](glossary.md) |

### Maintain or extend the record

| Goal | Start here |
|------|------------|
| Record a fresh gap, observation, or unresolved result | [`findings/`](findings/README.md) |
| Place a change, promote evidence, or hand off work | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| Review the maintained kernel patch deliverables | [`kernel-drivers/patches/`](kernel-drivers/patches/README.md) |
| Reconstruct external sources or resolve code citations | [`docs/source-trees.md`](docs/source-trees.md) |
| Run repository or board operations | [`scripts/`](scripts/README.md) |
| Review environment-specific agent instructions | [`AGENTS.md`](AGENTS.md) |

This is an integration record, not a source monorepo. A subsystem absent from
the dashboard is not implicitly working or broken; check support coverage and
create a finding rather than guessing.

## Repository structure

The detailed category/project taxonomy, canonical stack diagram, and operator
and developer reading paths are maintained in
[`docs/work-packages.md`](docs/work-packages.md). Each category and project has
a local `README.md` that owns its scope, dependencies, evidence boundary, and
complete local file index. The top-level categories are:

[`boot-firmware/`](boot-firmware/README.md) ·
[`kernel-versions/`](kernel-versions/README.md) ·
[`kernel-drivers/`](kernel-drivers/README.md) ·
[`vendor-libraries/`](vendor-libraries/README.md) ·
[`video-libraries/`](video-libraries/README.md) ·
[`apps/`](apps/README.md) ·
[`packaging/`](packaging/README.md)

Cross-project references enter through [`docs/`](docs/README.md). Small
tracked forensic inputs enter through
[`downloads/armbian-rock5b-uboot-compare/`](downloads/armbian-rock5b-uboot-compare/README.md);
generated and bulky artifacts stay outside Git.

## Canonical owners

This is the compact read view; the authoritative placement and update contract
is [`CONTRIBUTING.md`](CONTRIBUTING.md#where-a-change-belongs).

| Information | Owner |
|-------------|-------|
| Dated public state, next proof, and volatile external facts | [`status.md`](status.md) |
| Whole-board tracked, narrow, and unassessed scope | [`docs/support-coverage.md`](docs/support-coverage.md) |
| Commands and recovery | [`install.md`](install.md), then the owning project/runbook |
| Fresh observations and unresolved explanations | [`findings/`](findings/README.md) |
| Stable models, patches, tests, and project evidence | The nearest project front door in [`docs/work-packages.md`](docs/work-packages.md) |
| Evidence lifecycle, file placement, and handoff checks | [`CONTRIBUTING.md`](CONTRIBUTING.md) |

## Provenance and licensing

[`LICENSE.md`](LICENSE.md) owns the repository license policy: documentation
and non-code are CC BY-SA 4.0; imported code retains its upstream license and
notices; Yi Ding's original kernel contributions are GPL-2.0-or-later. Project
front doors and [`docs/source-trees.md`](docs/source-trees.md) own source
lineage and immutable reconstruction pins. Proprietary RKNN compiler/runtime
boundaries are documented in the
[`RKNPU/RKNN guide`](kernel-drivers/rknpu/docs/how-rknpu-works.md#4-what-is-open-and-what-is-closed).

This public repository may contain technical fix and bounded validation facts.
Disclosure coordination, memory-corruption reproducers, and private upstream
planning belong in `rock-5b-security/` under the rules in
[`CONTRIBUTING.md`](CONTRIBUTING.md).
