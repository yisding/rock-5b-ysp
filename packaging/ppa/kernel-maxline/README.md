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
