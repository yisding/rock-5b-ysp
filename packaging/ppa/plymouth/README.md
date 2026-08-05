# Plymouth incomplete-CSI boot-hang backport

This package is Ubuntu Resolute's unmodified
`plymouth 24.004.60+git20250831.4a3c171d-0ubuntu8` source plus upstream commit
[`45655f12`](https://gitlab.freedesktop.org/plymouth/plymouth/-/commit/45655f12fa2d5553ab4ba509f2e203c249191664).
The commit fixes a non-advancing loop in `on_key_event()` when a terminal read
ends partway through a CSI control sequence.

The backport version is
`24.004.60+git20250831.4a3c171d-0ubuntu8.1~rk1`. It sorts above Ubuntu's
`-0ubuntu8` and below a future Ubuntu `-0ubuntu9`.

## Build

The helper [`build-source-package.sh`](build-source-package.sh) downloads the
exact Ubuntu source files from Launchpad, verifies their pinned SHA-256 digests,
adds the single DEP-3 patch and changelog entry, and creates an unsigned source
package. Drive it through the packaging front door rather than directly:

```bash
bash packaging/ppa/build-source-packages.sh plymouth
```

Generated source and artifacts are written below `packaging/ppa/out/`, which is
git-ignored. The patch only changes `libply-splash-core`; rebuilding the full
source keeps all binary package versions synchronized.

For a local native binary validation, build the generated tree with the system
tool path required by this repository:

```bash
cd packaging/ppa/out/work/plymouth-24.004.60+git20250831.4a3c171d
PATH=/usr/sbin:/usr/bin:/sbin:/bin dpkg-buildpackage -b -us -uc
```

## Upload

Sign and upload the exact source changes file:

```bash
debsign -k 0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6 \
  packaging/ppa/out/artifacts/plymouth_24.004.60+git20250831.4a3c171d-0ubuntu8.1~rk1_source.changes
dput ppa:yi-ding/ubuntu-rock-5b \
  packaging/ppa/out/artifacts/plymouth_24.004.60+git20250831.4a3c171d-0ubuntu8.1~rk1_source.changes
```

The signed source upload was accepted on 2026-07-23 as Launchpad source
publication
[`18636085`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18636085).
Its arm64 build
[`33428910`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33428910)
completed successfully, and all nine binary publications are Published in the
normal PPA as rechecked through Launchpad's API on 2026-08-05.

Installing the rebuilt `plymouth` package queues Ubuntu's `update-initramfs`
trigger. Confirm that the target initramfs contains the PPA's rebuilt
`libply-splash-core.so.5` before rebooting.
