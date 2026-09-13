# kernel-maxline/ - maximum-mainline Debian packaging

This directory owns only the Debian packaging overlay for the maximum-mainline
kernel profiles. The kernel-version project itself—its pinned integrations,
patches, config, source ledgers, design record, build entry point, and
verification evidence—lives in
[`kernel-versions/maxline/`](../../../kernel-versions/maxline/README.md).

## Contents

| Path | Responsibility |
|------|----------------|
| [`debian/`](debian/) | Templated source and binary package metadata, payload installation, and maintainer-script generation for the co-installable `public` and `wip` packages. |
| [`kernel-versions/maxline/build-kernel.sh`](../../../kernel-versions/maxline/build-kernel.sh) | Apply the pinned integration delta, overlay this packaging, and build the selected package profile. |

The out-of-tree package layout differs from the in-tree forward-port and
rewrite packages, so its `install-kernel-packages.sh` helper is intentionally a
separate implementation. The shared `write-maintainer-scripts.sh` helper is
still checked for byte-for-byte drift by the repository consistency gate.

Generated source trees and packages remain ignored under
`packaging/ppa/out/maxline/`. They are disposable build artifacts, not inputs
owned by this directory.

## Archive

Maxline source packages go to `ppa:yi-ding/ubuntu-rock-5b-experimental`, per
the [archive topology](../README.md#archive-topology). Both profiles are
co-installable: unique source names, unique binary names, and a unique kernel
release each, so neither can replace the normal system ABI or the recovery
kernel.

The build entry point emits binary packages by default. Pass
`MAXLINE_SOURCE_PACKAGE=1` to get the orig tarball, Debian tarball, `.dsc`, and
source `.changes` that Launchpad requires, written to
`packaging/ppa/out/artifacts`:

```sh
MAXLINE_SOURCE_PACKAGE=1 kernel-versions/maxline/build-kernel.sh public
MAXLINE_SOURCE_PACKAGE=1 kernel-versions/maxline/build-kernel.sh wip
```

Sign and upload with the [publication runbook](../docs/publishing.md). A
successful upload proves transfer only; the kernel-version project owns the
compile and hardware boundary, and no maxline profile has been booted.

First upload: 2026-09-13, `7.3.0~rc2+git20260913+rk3588maxline{public,wip}-0ubuntu1`,
both accepted as `Pending` source publications with no arm64 build result yet.
[W05](../../../status.md#watch-w05) owns the live archive record.
