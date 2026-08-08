# PPA maintainer documentation

These pages own the cross-package mechanics for building and publishing the
ROCK 5B Launchpad archives. Package directories own details unique to one
source package; live archive state remains in
[W05](../../../status.md#watch-w05), not in these runbooks.

## Choose a task

| Task | Maintained owner |
|------|------------------|
| Select inputs, export sources, and create unsigned source packages | [`building.md`](building.md) |
| Respect dependency waves, sign and upload, recover a rejected upload, or reconstruct an exact published artifact | [`publishing.md`](publishing.md) |
| Understand what each userspace/native package overlay changes | [`package-notes.md`](package-notes.md) |
| Change or qualify a kernel package | The package-specific README linked from the [PPA front door](../README.md#repository-layout) |
| Check what Launchpad publishes now | [W05](../../../status.md#watch-w05) and Launchpad |
| Install the normal PPA as a user | The [PPA support guide](../../../docs/ppa-support.md) |

Start at the [`ppa/` front door](../README.md) for archive topology, ownership
boundaries, and the complete directory index.
