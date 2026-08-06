# docs/ — cross-project references

Most technical documentation lives with the project that owns it (see the
categories in [`../README.md`](../README.md)). This directory keeps the small set
of repo-wide references that are not owned by one project.

## Cross-project docs

| File | Purpose |
|------|---------|
| [`status-ledger.md`](status-ledger.md) | Audit companion to `../status.md`: longer dated cross-track notes without crowding the status dashboard. |
| [`repository-organization-proposal.md`](repository-organization-proposal.md) | Draft repository-wide information-architecture proposal: canonical document roles, deliberate duplication, migration phases, enforcement, and completion criteria. |
| [`repository-organization-migration.md`](repository-organization-migration.md) | Temporary resumable ledger for executing the accepted organization proposal: baselines, compatibility and security review, assertion-owner mappings, slice status, validation, and unresolved risks. Remove it after every slice closes. |
| [`work-packages.md`](work-packages.md) | The project map, stack diagram, and operating/re-entry and developer reading paths. Start here when you are not sure which project owns a topic. |
| [`support-coverage.md`](support-coverage.md) | Whole-board scope inventory: which ROCK 5B areas are tracked, narrowly evidenced, or entirely unassessed, plus the first useful evidence for each gap. |
| [`ppa-support.md`](ppa-support.md) | New-user guide for `ppa:yi-ding/ubuntu-rock-5b`: recovery-first setup, package choices, MPV/FFmpeg, Chrome/VA-API and GNOME Remote Desktop verification, troubleshooting, and unsupported features. |
| [`app-enablement.md`](app-enablement.md) | Planning map for untracked applications (browsers, VLC, HandBrake, mpv, OBS): which plumbing layer each binds to and the estimated enablement cost on this stack. |
| [`ubuntu-rock5b-image-plan.md`](ubuntu-rock5b-image-plan.md) | Proposed ROCK 5B-only successor architecture: stock Ubuntu 26.04 userspace around a custom board kernel/firmware layer, with package boundaries, boot/update policy, proof ladder, and release gates. |
| [`system-baseline.md`](system-baseline.md) | Canonical capture contract separating target board, boot path, runtime kernel/userspace, and build host; points to the existing collector and dated truth owners. |
| [`source-trees.md`](source-trees.md) | Source pins and reconstruction recipes for the trees that `file:line` citations resolve against. Pins are corrected in place as provenance is re-measured; new trees are published to GitHub rather than added here. |
| [`gotchas.md`](gotchas.md) | Whole-repo trap index: kernel and FFmpeg traps live here; GRD, Mesa, packaging, and debug-kernel traps point to their project-owned write-ups. |

Repository-wide license status is not a cross-project doc; it lives at
[`../LICENSE.md`](../LICENSE.md).

## Everything else is project-owned

Project-specific material lives with the project that owns it, not here. The
category table in the root [`README.md`](../README.md#repository-structure) maps
every category to its front door, and [`work-packages.md`](work-packages.md)
carries the detailed project map. This page does not restate either — a third
copy of the taxonomy is how the three drifted apart before.

## Reading paths

The operating/re-entry and developer reading paths are owned by
[`work-packages.md`](work-packages.md) § Operating and re-entry paths /
§ Developer reading paths — see there rather than duplicating the table here.

## Conventions

The full evidence, ownership, status-update, and handoff workflow lives in
[`../CONTRIBUTING.md`](../CONTRIBUTING.md). The `docs/`-specific conventions are:

- **Anchors.** `file:line` citations resolve against a pinned source tree in
  [`source-trees.md`](source-trees.md). If a citation does not match what you see,
  check the tree pin before assuming drift.
- **Ownership.** New project-specific material belongs in the project directory,
  not here. New cross-project maps, source pins, or global trap indexes can live
  in `docs/`.
- **Vocabulary.** Cross-cutting terms live in [`../glossary.md`](../glossary.md);
  project-specific terms live in each project's `keywords.md`.
