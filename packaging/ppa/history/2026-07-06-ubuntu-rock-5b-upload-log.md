# ubuntu-rock-5b PPA upload log

> Scope: build and upload the userspace stack to `ppa:yi-ding/ubuntu-rock-5b`.
> Initial wave: `mpp`, `librga`, and `ffmpeg`.
> Source inputs:
>
> - `/home/yi/Code/rock-5b/rockchip-userspace/mpp-rockchip`
> - `/home/yi/Code/rock-5b/rockchip-userspace/librga-fork`
> - `/home/yi/Code/rock-5b/ffmpeg/ffmpeg-rockchip-81`
>
> Target series: `resolute` (Ubuntu 26.04 / Armbian 26.5.1 userspace).
> Target architecture: source upload to Launchpad; expected binary build is
> `arm64`.
> Date opened: 2026-07-06.

## Bottom line (as of the last entry)

This is a chronological working log, not a finished-state doc. Current state:

- **The recreated main PPA is fully published.** MPP, librga, co-installable
  FFmpeg 6.1, the forward-port kernel, FFmpeg 8.0.3, patched GRD, and
  `rk3588-codec-udev 1.1` all have current Published sources and binaries.
  FFmpeg build `33397317`, GRD build `33397319`, and codec-udev build
  `33399688` succeeded.
- **Four incompatible tracks are isolated in dedicated PPAs.** The upstream
  and Rockchip FFmpeg 8.1 archives each contain one Published source plus 29
  binaries; the Linux 6.18 and 7.2-rc2 rewrite archives each contain one
  Published source plus three binaries.
- **The experimental PPA is a holding archive, not an install source.** It
  retains five source sets and copied binaries from the deleted main archive,
  including the superseded FFmpeg-8.1-linked GRD build. The recreated main PPA
  has zero archive dependencies.
- **Open gates are runtime gates.** The optional GDM greeter ACL package is not
  uploaded, and the exact clean migration plus PPA kernel
  install/reboot/revert paths have not passed board validation.

The normal stack is available as a published **test path**. Do not present it
as the validated primary path until the board gates above pass; the combined
Armbian kernel remains the proven path described in
[`../../../install.md`](../../../install.md).

## Contents

- [Packaging Policy](#packaging-policy) · [Environment Snapshot](#environment-snapshot)
- Source-package passes: [mpp/running log](#running-log) · [librga](#librga-source-package-pass) · [ffmpeg](#ffmpeg-source-package-pass)
- Launchpad back-and-forth: [signing/first upload](#signing-and-first-upload-attempt) · [arch correction](#launchpad-architecture-correction) · [orig-tarball rejection](#launchpad-orig-tarball-rejection) · [arm64 enablement](#launchpad-arm64-enablement-retry) · [MPP published, librga retry](#mpp-published-and-librga-retry)
- FFmpeg: [staging strategy](#ffmpeg-staging-strategy) · [8.1.2 build polling](#upstream-ffmpeg-812-build-polling) · [arm64 build failure](#upstream-ffmpeg-812-baseline-arm64-build-failure-build-33366878) · [baseline recovered + checked in](#baseline-packaging-recovered-from-launchpad-and-checked-in)
- GRD: [packaging prep](#gnome-remote-desktop-and-grd-ffmpeg-packaging-prep) · [local binary validation](#gnome-remote-desktop-local-binary-validation)
- Kernels and final 8.1 publication: [kernel source uploads](#kernel-source-uploads-and-alpha-rc2-refresh) · [final publication](#final-publication-and-build-update)
- Six-PPA rebuild: [FFmpeg 8.0 compatibility and split](#ffmpeg-80-compatibility-port-and-ppa-split) · [review corrections](#pr-review-corrections) · [final live recheck](#final-six-ppa-publication-recheck)

## Packaging Policy

This run follows the current Ubuntu/Debian source-package model:

- upload source packages to the PPA and let Launchpad build binaries;
- keep `debian/` packaging reproducible in this repo and build work in `/tmp`;
- use `3.0 (quilt)` for non-native packages;
- use debhelper compat 13 through `debhelper-compat (= 13)`;
- use `Rules-Requires-Root: no` unless a package proves otherwise;
- keep generated `.deb`, `.dsc`, `.changes`, orig tarballs, and build trees out
  of git.

References checked:

- Ubuntu Packaging Guide, last updated 2025-06-17, with source/PPA upload
  workflow sections.
- Debian Policy Manual 4.7.4.1, released 2026-03-31.
- Launchpad PPA upload documentation for source uploads via signed `.changes`
  files.

## Environment Snapshot

Host:

```text
Distributor ID: Ubuntu
Description:    Armbian 26.5.1 resolute
Release:        26.04
Codename:       resolute
```

Installed packaging tools observed at start:

```text
build-essential 12.12ubuntu2.26.04.1
debhelper       13.31ubuntu1
devscripts      2.26.7
dpkg-dev        1.23.7ubuntu1
fakeroot        1.37.2-1
gnupg           2.4.8-4ubuntu3
quilt           0.69-0.1
```

`dput`, `equivs`, and `lintian` are installed but `dpkg-query` did not print
versions for them in the initial package check.

## Running Log

### 2026-07-06

- Started from YSP repo `/home/yi/Code/rock-5b-ysp`.
- Confirmed existing `packaging/ppa/README.md` describes an older dev-box-only
  staging flow and older source basis. This run will replace that with
  reproducible package material based on the latest requested local source
  trees.
- Added this log before making packaging/upload changes, per the request to
  document everything in the YSP repo.
- Source inventory:
  - `mpp-rockchip`: clean worktree at `1375813c`, branch `develop`, tag
    `1.0.12`; has an in-tree `debian/` directory.
  - `librga-fork`: tip `a632217`, branch `main`; has an in-tree `debian/`
    directory but the worktree contains untracked generated debhelper/build
    output under `debian/`. Use a clean archive/export copy, not the working
    directory, for source packaging.
  - `ffmpeg-rockchip-81`: tip `75638e7f0b17`, branch `refactor/section-c`;
    worktree has an unrelated untracked `kernel-drivers/` directory and no
    `debian/` packaging. Packaging must be supplied in YSP or generated from a
    template.
- FFmpeg ABI check:
  - Installed PPA-style package on the board is `ffmpeg 7:8.1.2-1+rk1` with
    `libavcodec62`, `libavutil60`, and `libavformat62`.
  - Requested source `/home/yi/Code/rock-5b/ffmpeg/ffmpeg-rockchip-81` reports
    `RELEASE=8.0.git` but library majors `libavcodec63`, `libavutil61`,
    `libavformat63`, `libavfilter12`, `libswscale10`, and `libswresample7`.
  - The older local Ubuntu packaging in `/home/yi/Code/rock-5b/ffmpeg/ffmpeg-ppa`
    cannot be reused unchanged because its binary package names and symbols
    metadata target the older `libav*62/60/...` ABI.
- Packaging/upload environment check:
  - Git identity is `Yi Ding <yi.s.ding@gmail.com>`.
  - `gpg --list-secret-keys` failed inside the managed sandbox because GnuPG
    needs to create lock/socket files under `~/.gnupg`, which is read-only in
    the sandbox. Signing will need an unsandboxed command.
  - `dput` is not available on `PATH` even though the earlier package-query
    probe included the name. Upload will need `dput`/`dput-ng` installed or an
    equivalent Launchpad upload tool.
- User installed `dput-ng` after the initial environment check. Upload should
  use that path if `dput`/`dput-ng` resolves correctly.
- Rechecked upload tool after installation: `/usr/bin/dput` exists and
  `dput-ng` is installed at `1.44ubuntu3`.
- Imported clean packaging snapshots under `packaging/ppa/mpp/debian` and
  `packaging/ppa/librga/debian`.
- The librga source worktree had stale generated build output under `debian/`.
  The copied `.debhelper`, `debian/tmp`, `debian/librga2`, and
  `debian/librga-dev` directories were removed from the YSP snapshot.
- Wave A packaging metadata updates:
  - `mpp` version set to
    `1.5.0+git20260529.1375813c-0ubuntu1~rk1`, which sorts above the
    previously installed `1.5.0-1+rk1` while recording the real source commit.
  - `librga` version set to
    `2.2.0+git20260703.a632217-0ubuntu1~rk1`, which sorts above
    `2.2.0-1+rk1`.
  - Both packages now use `debhelper-compat (= 13)`, `Standards-Version:
    4.7.4.1`, and `Rules-Requires-Root: no`.
  - Library/dev package metadata was tightened with `Multi-Arch: same`,
    explicit development-package dependencies, and fuller package
    descriptions.
  - For `mpp`, unversioned linker symlinks were moved to
    `librockchip-mpp-dev`; runtime packages keep only the versioned shared
    libraries.
- Added `packaging/ppa/build-source-packages.sh`:
  - exports clean upstream trees with `git archive`;
  - removes upstream `debian/` from the orig tarball material;
  - applies the YSP `debian/` snapshots;
  - builds unsigned source packages with `dpkg-buildpackage -S -sa -us -uc`;
  - writes artifacts under `/tmp/ubuntu-rock-5b-ppa/artifacts`.
- First `build-source-packages.sh mpp librga` run failed during `mpp`
  source-package creation:

```text
dpkg-source: error: cannot build with source format '3.0 (quilt)':
no upstream tarball found at ../mpp_1.5.0+git20260529.1375813c.orig.tar.{bz2,gz,lzma,xz}
```

  Root cause: the script wrote the orig tarball only to the artifacts
  directory, not to the parent of the source build tree where
  `dpkg-buildpackage` expects it. The script was corrected to create the orig
  tarball under the build parent and copy it into artifacts after source
  package generation.
- Second Wave A source export completed for `mpp` and `librga`, producing
  source-only uploads with orig source included. `dpkg-source` warned:

```text
version number suggests Ubuntu vendor changes, but the Maintainer field does
not have Ubuntu vendor address
```

  Packaging was corrected to use `Maintainer: Ubuntu Developers
  <ubuntu-devel-discuss@lists.ubuntu.com>` while preserving upstream maintainers
  in `XSBC-Original-Maintainer`; changelog `Changed-By` remains
  `Yi Ding <yi.s.ding@gmail.com>`.
- Rechecked lintian after the user installed it: `lintian` is available as
  `Lintian v2.129.0ubuntu2.1`.
- Rebuilt Wave A source packages after the Ubuntu maintainer correction and
  verified both `.dsc` files extract with `dpkg-source -x`.
- Local binary validation of the extracted `mpp` source package failed during
  `dpkg-buildpackage -b -us -uc` on Ubuntu/Armbian 26.04. The failing compiler
  diagnostic was:

```text
osal/test/mpp_runtime_test.c:197:35: error: passing argument 3 of
'pthread_create' from incompatible pointer type [-Wincompatible-pointer-types]
```

  Root cause: `wait_thread` was declared as `void *wait_thread()` but
  `pthread_create` requires `void *(*)(void *)`. Added a Debian quilt patch
  `debian/patches/0001-fix-pthread-runtime-test-entry-point.patch` to change
  the test helper signature to `void *wait_thread(void *unused)`. This is a
  source/toolchain compatibility fix, not a kernel failure.
- First attempt to regenerate the patched MPP source package failed before
  build because the new quilt patch hunk header was off by one line:

```text
dpkg-source: info: the patch has fuzz which is not allowed, or is malformed
```

  Corrected the patch hunk header from `@@ -135,8 +135,10 @@` to
  `@@ -136,8 +136,10 @@`.
- A second MPP regeneration attempt still failed because the hunk count was
  malformed: the header declared eight original lines while the body contained
  seven. Added the missing `struct tm *tm_info;` context line to make the quilt
  patch well-formed.
- Regenerated the MPP source package successfully after fixing the quilt patch,
  then extracted the `.dsc` into `/tmp/ubuntu-rock-5b-ppa/extract-mpp-patched-check`.
- Local MPP binary validation then failed at `dh_missing` after successful
  compilation/install staging:

```text
dh_missing: warning: usr/lib/aarch64-linux-gnu/librockchip_mpp.a exists in
debian/tmp but is not installed to anywhere
dh_missing: error: missing files, aborting
```

  Root cause: upstream CMake installs a static archive, while the YSP packaging
  intentionally packages the shared runtime libraries and development symlinks
  needed by FFmpeg/gnome-remote-desktop. Added `debian/not-installed` for
  `usr/lib/${DEB_HOST_MULTIARCH}/librockchip_mpp.a`.
- MPP local binary validation succeeded after the static archive was listed in
  `debian/not-installed`. Built local arm64 packages under
  `/tmp/ubuntu-rock-5b-ppa/`:
  - `librockchip-mpp1`
  - `librockchip-mpp-dev`
  - `librockchip-vpu0`
  - `rockchip-mpp-demos`
- Lintian on the MPP source package then reported:

```text
E: mpp source: readme-source-is-dh_make-template [debian/README.source]
W: mpp source: debian-rules-uses-unnecessary-dh-argument 13 >= 10 dh ... --parallel
W: mpp source: dh-exec-script-without-dh-exec-features [debian/rockchip-mpp-demos.install]
W: mpp source: newer-standards-version 4.7.4.1 (current is 4.7.3)
W: mpp source: source-contains-prebuilt-windows-binary [tools/AStyle.exe]
W: mpp source: source-contains-prebuilt-windows-binary [tools/TextEncoding.exe]
```

  Packaging responses:
  - replaced the template `debian/README.source` with a real source-package
    note;
  - removed the redundant `--parallel` argument from `debian/rules`;
  - removed unused `dh-exec` shebangs and the `dh-exec` build dependency;
  - changed the MPP upstream version to
    `1.5.0+git20260529.1375813c+ds` and updated the source export script to
    remove `tools/AStyle.exe` and `tools/TextEncoding.exe` before creating the
    orig tarball.
  The `newer-standards-version` warning is expected on this host because
  lintian `2.129.0ubuntu2.1` knows Policy 4.7.3, while this run intentionally
  follows Debian Policy 4.7.4.1.
- Lintian on the regenerated `+ds` MPP source package then reported executable
  mode bits on `.install` files after their `dh-exec` shebangs were removed:

```text
E: mpp source: executable-debhelper-file-without-being-executable
```

  Cleared the executable bit on `librockchip-mpp-dev.install`,
  `librockchip-mpp1.install`, and `librockchip-vpu0.install`.
- Final MPP `+ds` source lintian result was clean except for the expected
  `newer-standards-version 4.7.4.1 (current is 4.7.3)` warning from this
  host lintian.
- Final MPP `+ds` binary build succeeded. Lintian on the binary `.changes`
  then reported:

```text
E: copyright-not-using-common-license-for-apache2
W: package-name-doesnt-match-sonames librockchip-vpu1
W: readme-debian-contains-debmake-template
W: debug-file-with-no-debug-symbols
W: no-manual-page
W: package-has-long-file-name
```

  Packaging responses:
  - replaced the embedded Apache-2.0 license text in `debian/copyright` with a
    reference to `/usr/share/common-licenses/Apache-2.0`;
  - renamed the VPU runtime binary package from `librockchip-vpu0` to
    `librockchip-vpu1` to match SONAME `librockchip_vpu.so.1`, keeping
    `librockchip-vpu0` as an empty transitional package;
  - replaced the template `debian/README.Debian`;
  - removed the duplicate `readme.txt` line from `debian/docs`;
  - stopped forcing `-DCMAKE_BUILD_TYPE=Release` so debhelper/dpkg build flags
    can provide debug information.
  The demo-program `no-manual-page` warnings are intentionally left for now
  because these tools are diagnostics/examples, not the primary API surface.
- Rebuilt the MPP source package after those fixes. Source lintian result:

```text
W: mpp source: newer-standards-version 4.7.4.1 (current is 4.7.3)
```

  This is accepted for this run for the Policy-version reason noted above.
- Rebuilt final MPP arm64 binary packages from the extracted `.dsc`. The build
  now uses dpkg flags including `-g`, and produced:
  - `librockchip-mpp1`
  - `librockchip-mpp-dev`
  - `librockchip-vpu1`
  - `librockchip-vpu0` transitional package
  - `rockchip-mpp-demos`
- Final MPP binary lintian result has no errors. Remaining warnings:
  - `rockchip-mpp-demos` demo binaries have no manpages;
  - `librockchip-mpp-dev` has a long filename because the package version
    records the upstream git date/hash and `+ds` repack marker.

## librga source package pass

- Source basis:
  - repository: `/home/yi/Code/rock-5b/rockchip-userspace/librga-fork`
  - git commit: `a632217`
  - source version: `2.2.0+git20260703.a632217-0ubuntu1~rk1`
- Packaging basis:
  - source format: `3.0 (quilt)`
  - binary packages: `librga2`, `librga-dev`
  - build system: Meson through debhelper compat 13
  - distro target: `resolute`
  - `Rules-Requires-Root: no`
  - `Standards-Version: 4.7.4.1`
- The upstream working tree had stale generated `debian/` build output from a
  previous local package build. The PPA source export ignores upstream
  `debian/` and overlays the YSP packaging copy onto a clean `git archive`.
- Built the librga source package with
  `packaging/ppa/build-source-packages.sh librga`. Artifacts:
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/librga_2.2.0+git20260703.a632217.orig.tar.gz`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/librga_2.2.0+git20260703.a632217-0ubuntu1~rk1.debian.tar.xz`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/librga_2.2.0+git20260703.a632217-0ubuntu1~rk1.dsc`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/librga_2.2.0+git20260703.a632217-0ubuntu1~rk1_source.buildinfo`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/librga_2.2.0+git20260703.a632217-0ubuntu1~rk1_source.changes`
- Lintian on the librga source package reports only:

```text
W: librga source: newer-standards-version 4.7.4.1 (current is 4.7.3)
```

  This is accepted for the same reason as MPP: this host lintian version knows
  Policy 4.7.3, while this run intentionally follows Policy 4.7.4.1.
- Binary build from the extracted `.dsc` succeeded. Upstream Meson reports
  project version `2.1.0`, while the package version is
  `2.2.0+git20260703.a632217-0ubuntu1~rk1`; the built shared library and SONAME
  are `librga.so.2.1.0` and `librga.so.2`.
- First librga binary lintian run failed with:

```text
E: librga-dev: copyright-contains-dh_make-todo-boilerplate
E: librga2: copyright-contains-dh_make-todo-boilerplate
```

  Packaging response:
  - removed the remaining dh_make TODO boilerplate from `debian/copyright`;
  - changed Apache-2.0 entries to reference
    `/usr/share/common-licenses/Apache-2.0`;
  - documented the GPL-3-or-later `Android.mk` license;
  - documented the MIT/Expat-style license on the vendored libdrm header
    snapshots included in the source.
- Regenerated the librga source package, re-ran source lintian, extracted the
  regenerated `.dsc`, and rebuilt the binary packages.
- Final librga binary lintian result is clean: no errors and no warnings.

## Signing and first upload attempt

- GPG secret key available for upload signing:
  - fingerprint: `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`
  - long key id: `8F3025C4AA2228E6`
  - uid: `Yi Ding <yi.s.ding@gmail.com>`
- Signed the final MPP source upload:
  `/tmp/ubuntu-rock-5b-ppa/artifacts/mpp_1.5.0+git20260529.1375813c+ds-0ubuntu1~rk1_source.changes`.
  `debsign` succeeded. It warned that long key IDs are discouraged, so later
  signing used the full fingerprint.
- Signed the final librga source upload:
  `/tmp/ubuntu-rock-5b-ppa/artifacts/librga_2.2.0+git20260703.a632217-0ubuntu1~rk1_source.changes`.
  `debsign` succeeded with the full fingerprint.
- First MPP `dput` attempt failed before any upload because the Ubuntu
  supported-distribution hook could not import `distro_info`:

```text
Uploading to Ubuntu requires python3-distro-info to be installed
failed to resolve path dput.hooks.distro_info_checks.check_supported_distribution: No module named 'distro_info'
Error: no such hook 'supported-distribution'
```

  User installed `python3-distro-info` afterward. Note: the interactive shell's
  `python3` is currently mise Python 3.14 and still does not see distro Python
  modules, but `/usr/bin/dput` has a `/usr/bin/python3` shebang and
  `/usr/bin/python3` can import `/usr/lib/python3/dist-packages/distro_info.py`.
- Retried the final MPP source upload after `python3-distro-info` was
  installed. `dput` succeeded from the client side and uploaded:
  - `mpp_1.5.0+git20260529.1375813c+ds-0ubuntu1~rk1.dsc`
  - `mpp_1.5.0+git20260529.1375813c+ds.orig.tar.gz`
  - `mpp_1.5.0+git20260529.1375813c+ds-0ubuntu1~rk1.debian.tar.xz`
  - `mpp_1.5.0+git20260529.1375813c+ds-0ubuntu1~rk1_source.buildinfo`
  - `mpp_1.5.0+git20260529.1375813c+ds-0ubuntu1~rk1_source.changes`
- Uploaded the final librga source package. `dput` succeeded from the client
  side and uploaded:
  - `librga_2.2.0+git20260703.a632217-0ubuntu1~rk1.dsc`
  - `librga_2.2.0+git20260703.a632217.orig.tar.gz`
  - `librga_2.2.0+git20260703.a632217-0ubuntu1~rk1.debian.tar.xz`
  - `librga_2.2.0+git20260703.a632217-0ubuntu1~rk1_source.buildinfo`
  - `librga_2.2.0+git20260703.a632217-0ubuntu1~rk1_source.changes`

## Launchpad architecture correction

- After the first source uploads, Launchpad showed amd64 builds. Root cause in
  the packaging: MPP and librga still declared their binary packages as
  `Architecture: any`, so Launchpad was allowed to build them for any enabled
  PPA architecture. That is not useful for this ROCK 5B PPA.
- Packaging response:
  - changed all MPP binary packages to `Architecture: arm64`;
  - changed all librga binary packages to `Architecture: arm64`;
  - bumped MPP to `1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1`;
  - bumped librga to `2.2.0+git20260703.a632217-0ubuntu2~rk1`;
  - changed ffmpeg binary packages to `Architecture: arm64`, including
    `ffmpeg-doc`, to avoid Launchpad scheduling an amd64 arch-independent
    documentation build that would still run the arm64 Rockchip configure path.
- Important Launchpad-side note: package metadata can prevent unwanted amd64
  binary builds, but the PPA itself still must have arm64 enabled in its
  processor architecture list. If Launchpad continues to show no arm64 build
  after the arm64-only source uploads are accepted, that is a PPA configuration
  issue rather than a Debian packaging issue.
- Rebuilt the corrected MPP and librga source packages:
  - `mpp_1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1_source.changes`
  - `librga_2.2.0+git20260703.a632217-0ubuntu2~rk1_source.changes`
- Source lintian on both corrected uploads again reported only the expected
  local `newer-standards-version 4.7.4.1 (current is 4.7.3)` warning.
- Signed both corrected source uploads with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`.
- Uploaded both corrected source packages with `dput` to
  `ppa:yi-ding/ubuntu-rock-5b`. Client-side upload succeeded for:
  - `mpp_1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1`
  - `librga_2.2.0+git20260703.a632217-0ubuntu2~rk1`

## ffmpeg source package pass

- Source basis:
  - repository: `/home/yi/Code/rock-5b/ffmpeg/ffmpeg-rockchip-81`
  - branch: `refactor/section-c`
  - git commit: `75638e7f0b1775193381af0c3187838f6c51dbd1`
  - commit subject: `table-drive rga format/size/scale capability checks`
- Packaging direction after review:
  - use the full Ubuntu/Debian ffmpeg packaging surface so this can replace the
    normal Ubuntu ffmpeg package, including standard and extra flavors,
    `ffmpeg-doc`, `ffplay`, `qt-faststart`, and Ubuntu's optional
    codec/filter/protocol build dependencies;
  - layer the Rockchip forward-port source and RKMPP/RKRGA flags on top;
  - update binary package names for this source's ABI:
    `libavcodec63`, `libavdevice63`, `libavfilter12`, `libavformat63`,
    `libavutil61`, `libswresample7`, and `libswscale10`;
  - restrict all ffmpeg binary packages to `Architecture: arm64` for the
    ROCK 5B PPA.
- First ffmpeg source-package build attempt failed during local dependency
  checking:

```text
dpkg-checkbuilddeps: error: unmet build dependencies:
librockchip-mpp-dev (>= 1.5.0+git20260529.1375813c+ds)
librga-dev (>= 2.2.0+git20260703.a632217)
```

  Root cause: the machine still has older locally installed development
  packages (`librockchip-mpp-dev 1.5.0-1+rk1`, `librga-dev 2.2.0-1+rk1`), while
  this ffmpeg source package intentionally requires the new PPA source versions.
  Packaging response: changed the source export helper to pass `-d` to
  `dpkg-buildpackage -S`; this permits source-only package generation locally
  without weakening Launchpad's binary-build dependency enforcement.
- Initial ffmpeg source lintian then reported:

```text
E: ffmpeg source: build-depends-indep-without-arch-indep
W: ffmpeg source: orig-tarball-missing-upstream-signature
```

  Packaging response:
  - moved `ffmpeg-doc`'s documentation build dependencies from
    `Build-Depends-Indep` into `Build-Depends`, because this Rock 5B PPA marks
    `ffmpeg-doc` as `Architecture: arm64` to avoid amd64 arch-independent
    Launchpad builds;
  - removed the stale upstream signing key from `debian/upstream/`, because the
    orig tarball is a local git archive rather than a signed upstream release
    tarball.
- The next ffmpeg source lintian run reported:

```text
E: ffmpeg source: debian-watch-file-pubkey-file-is-missing [debian/watch]
```

  Packaging response: removed the stale `debian/watch` file as well; it pointed
  at the upstream release import workflow and no longer applies to the
  git-snapshot Rockchip source package.
- Regenerated the ffmpeg source package after those fixes. Final source
  lintian result has no errors. Remaining warnings:
  - `newer-standards-version 4.7.4.1 (current is 4.7.3)`, expected on this
    host lintian;
  - long source `.changes` / `.buildinfo` filenames because the version records
    `rockchip81`, commit date, and git hash;
  - superfluous Debian copyright patterns for files absent from this Rockchip
    branch.
- The final ffmpeg source artifacts are:
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b.orig.tar.gz`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk1.debian.tar.xz`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk1.dsc`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk1_source.buildinfo`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk1_source.changes`
- Do not upload ffmpeg until the corrected arm64-only MPP and librga packages
  have been accepted and published in the PPA; otherwise Launchpad will fail
  ffmpeg on missing build-dependencies and will not automatically retry.

## Launchpad orig tarball rejection

- Launchpad rejected the corrected librga upload:

```text
File librga_2.2.0+git20260703.a632217.orig.tar.gz already exists in Ubuntu Rock 5B Support, but uploaded version has different contents.
Files specified in DSC are broken or missing, skipping package unpack verification.
```

- This is a real source-upload packaging problem, but it is not a librga source
  code or kernel problem. Launchpad keys the upstream orig tarball by filename;
  every Debian revision for the same upstream version must reference the exact
  same orig tarball bytes that were accepted on the first upload.
- Local checksum comparison confirmed the mismatch:
  - accepted `librga -0ubuntu1` `.dsc` orig SHA256:
    `1e1d12fb4eacd7dcbfdddf316691b2026c0e020f59aef1a84b932f483ad71679`
    with size `8040158`;
  - rejected `librga -0ubuntu2` `.dsc` orig SHA256:
    `5f8083361c895198b12bc883a5f93a61d030a8163167c55a606194974aa92c72`
    with size `8040176`.
- MPP had the same latent issue:
  - accepted `mpp -0ubuntu1` `.dsc` orig SHA256:
    `d096f57c355e70437f95e224c1f4a53d23ad96f8bed399aa7c8bb1351eefb321`
    with size `3824069`;
  - rebuilt `mpp -0ubuntu2` `.dsc` orig SHA256:
    `c8607e4bca78e1b7b5441202287faec8ada3fc75e76d8b07dea84c44d79ffd94`
    with size `3824068`.
- Root cause in the YSP helper:
  `packaging/ppa/build-source-packages.sh` regenerated and overwrote
  `.orig.tar.gz` on every run. The gzip/tar stream was not byte-for-byte stable,
  so a packaging-only Debian revision created a different upstream tarball.
- Corrective action:
  - downloaded the already-accepted orig tarballs from the PPA pool;
  - verified that their SHA256 values match the original `-0ubuntu1` `.dsc`
    records;
  - changed `build-source-packages.sh` to reuse an existing orig tarball from
    the artifact directory unless `FORCE_ORIG=1` is set;
  - changed new-orig generation to use sorted tar entries, fixed owner/group,
    the upstream commit timestamp as mtime, and `gzip -n`.
- Replaced the local artifact orig tarballs with the accepted PPA copies and
  rebuilt the corrected source packages. The rebuilt `-0ubuntu2` `.dsc` files
  now reference the accepted orig checksums:
  - librga:
    `1e1d12fb4eacd7dcbfdddf316691b2026c0e020f59aef1a84b932f483ad71679`;
  - MPP:
    `d096f57c355e70437f95e224c1f4a53d23ad96f8bed399aa7c8bb1351eefb321`.
- Re-ran source lintian on both corrected source uploads. Remaining warnings
  are only `newer-standards-version 4.7.4.1 (current is 4.7.3)`.
- Checked the PPA source index before retrying the uploads. At that time it
  still published only:
  - `librga 2.2.0+git20260703.a632217-0ubuntu1~rk1`;
  - `mpp 1.5.0+git20260529.1375813c+ds-0ubuntu1~rk1`.
- Re-signed the corrected `-0ubuntu2` source uploads with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`.
- Retried the `mpp` and `librga` `-0ubuntu2` uploads with `dput --force`
  because the local `*.ppa.upload` markers still recorded the earlier rejected
  upload attempts. Client-side upload checks and FTP transfer succeeded for
  both packages. Launchpad acceptance remains asynchronous and must be confirmed
  by the PPA source index or Launchpad email.
- Refreshed the PPA `resolute/main/source/Sources.gz` index roughly one minute
  after the retry. It still listed only the previously accepted `-0ubuntu1`
  source versions for MPP and librga. Treat the corrected `-0ubuntu2` uploads as
  transferred but not yet publication-confirmed. Keep ffmpeg held back until the
  corrected MPP and librga source versions are accepted/published.

## Launchpad status check

- Checked the PPA repository indexes and Launchpad API at
  `2026-07-06T13:51:21-07:00`.
- Published source versions were still the original uploads:
  - `mpp 1.5.0+git20260529.1375813c+ds-0ubuntu1~rk1`;
  - `librga 2.2.0+git20260703.a632217-0ubuntu1~rk1`.
- The corrected `-0ubuntu2~rk1` uploads did not yet appear as `Published`,
  `Pending`, or `Deleted` source publications in the anonymous Launchpad API.
  The only local evidence remains the successful `dput --force` FTP transfer.
- Current binary publication state:
  - no arm64 MPP or librga binary packages are present in the PPA index;
  - old MPP `-0ubuntu1~rk1` amd64 binary packages are present;
  - no librga amd64 binary packages were published.
- Launchpad build records for the original `-0ubuntu1~rk1` uploads:
  - MPP amd64 build `33365950`: `Successfully built`;
  - librga amd64 build `33365951`: `Failed to build`.
- Downloaded the failed librga amd64 build log. The failure is from building
  the old `Architecture: any` upload on amd64:

```text
../core/NormalRga.cpp:1198:36: error: cast from 'void*' to 'unsigned int' loses precision [-fpermissive]
ninja: build stopped: subcommand failed.
dh_auto_build: error: cd obj-x86_64-linux-gnu && LC_ALL=C.UTF-8 ninja -j4 -v returned exit code 1
dpkg-buildpackage: error: debian/rules binary subprocess failed with exit status 2
```

  This is an amd64 portability failure in the upstream source, not a kernel
  failure. It is consistent with the decision to restrict the Rockchip RGA PPA
  binary packages to arm64.
- Queried the PPA processor configuration. The archive currently lists only:

```text
amd64    AMD x86-64
```

  No restricted processors, including arm64, are enabled. Even after the
  corrected `Architecture: arm64` sources are accepted, Launchpad cannot produce
  arm64 binaries for this PPA until arm64 is enabled for the archive.

## Launchpad arm64 enablement retry

- User changed the PPA details to enable arm64 builds.
- Rechecked the PPA processor list at `2026-07-06T13:55:26-07:00`. It now
  lists:

```text
arm64    ARM ARMv8
```

- The source index still published only the original `-0ubuntu1~rk1` MPP and
  librga source versions before the retry.
- Re-uploaded both corrected arm64-only source packages with `dput --force`:
  - `mpp_1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1_source.changes`;
  - `librga_2.2.0+git20260703.a632217-0ubuntu2~rk1_source.changes`.
- Client-side `dput` checks and FTP transfer succeeded for both uploads.
- Checked Launchpad API at `2026-07-06T13:57:17-07:00`:
  - `mpp 1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1` is `Pending`;
  - `librga 2.2.0+git20260703.a632217-0ubuntu2~rk1` is `Pending`;
  - MPP arm64 build `33366257` is `Currently building`.
- Checked again at `2026-07-06T13:58:54-07:00`:
  - both corrected source versions were still `Pending`;
  - MPP arm64 build `33366257` was `Needs building`;
  - no new librga arm64 build record was visible yet in the anonymous build
    record API.

## Old amd64 publication removal attempt

- User asked whether the earlier amd64 packages can be removed from the PPA.
- Correct deletion target: delete the old source publications, which also
  removes their associated binary publications from the PPA:
  - `mpp 1.5.0+git20260529.1375813c+ds-0ubuntu1~rk1`
    source publication `18601507`;
  - `librga 2.2.0+git20260703.a632217-0ubuntu1~rk1`
    source publication `18601508`.
- Status checked at `2026-07-06T14:05:42-07:00`:
  - corrected `mpp -0ubuntu2~rk1` source publication `18601758` was
    `Pending`;
  - corrected `librga -0ubuntu2~rk1` source publication `18601759` was
    `Pending`;
  - MPP arm64 build `33366257` was `Gathering build output`;
  - old MPP amd64 build `33365950` was `Successfully built`;
  - old librga amd64 build `33365951` was `Failed to build`.
- Confirmed through anonymous `launchpadlib` introspection that the source
  publication API exposes `requestDeletion`.
- Attempted to start an authenticated Launchpad OAuth flow using a file-backed
  credential cache because the local Python environment lacks the `keyring`
  module. The OAuth flow printed an authorization URL and waited for browser
  approval, but authorization did not complete during the session. The wait was
  interrupted, and no deletion request was sent.
- User manually deleted the earlier `-0ubuntu1~rk1` packages from Launchpad.
- Checked Launchpad API again at `2026-07-06T14:15:26-07:00`:
  - `mpp 1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1` source publication
    `18601758` was still `Pending`;
  - `librga 2.2.0+git20260703.a632217-0ubuntu2~rk1` source publication
    `18601759` was still `Pending`;
  - MPP arm64 build `33366257` was `Gathering build output`;
  - librga arm64 build `33366258` was `Currently building`;
  - the public arm64 `Packages.gz` index did not yet list MPP or librga
    binaries.
- At that same API check, the old `-0ubuntu1~rk1` source publications still
  appeared as `Published` through the anonymous Launchpad API. Treat this as
  possibly stale or not yet propagated until the repository indexes stop listing
  the old packages.
- Follow-up status-filtered API queries showed the manual deletion did take
  effect:
  - old MPP source publication `18601507` is `Deleted`;
  - old librga source publication `18601508` is `Deleted`;
  - neither old source publication appeared as `Superseded`.
- Checked direct arm64 build records at `2026-07-06T14:17:59-07:00` after the
  package-level build list briefly gave inconsistent results:
  - MPP arm64 build `33366257` is `Successfully built`, completed at
    `2026-07-06T21:05:43.908459+00:00`, duration `0:08:55.745170`;
  - librga arm64 build `33366258` is `Currently building`;
  - the public arm64 `Packages.gz` index still did not list MPP or librga
    binaries yet, so publication had not propagated.

## MPP published and librga retry

- Checked Launchpad again at `2026-07-06T14:51:58-07:00`:
  - `mpp 1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1` source was `Published`
    at `2026-07-06T21:14:39.076833+00:00`;
  - `librga 2.2.0+git20260703.a632217-0ubuntu2~rk1` source was `Published`
    at `2026-07-06T21:14:39.076833+00:00`;
  - old `-0ubuntu1~rk1` source publications showed as `Deleted`;
  - MPP arm64 build `33366257` was `Successfully built`;
  - librga arm64 build `33366258` was `Failed to build`, completed at
    `2026-07-06T21:24:19.513676+00:00`, duration `0:26:51.731724`;
  - Launchpad did not attach a `build_log_url`, `upload_log_url`,
    `changesfile_url`, or `buildinfo_url` to the failed librga build record;
  - the public arm64 `Packages.gz` index was still empty, but the MPP binary
    publications were visible through the source-publication API as `Pending`.
- Since the local arm64 librga binary build already succeeded and Launchpad
  provided no failure log, treated the failed arm64 build as a retry case.
- Added a no-change librga changelog entry:
  `2.2.0+git20260703.a632217-0ubuntu3~rk1`.
- First `-0ubuntu3~rk1` source build lintian run failed because the new
  changelog entry timestamp was older than the existing `-0ubuntu2~rk1`
  timestamp. Corrected the top changelog timestamp and rebuilt.
- Final `-0ubuntu3~rk1` source lintian result only reports:

```text
W: librga source: newer-standards-version 4.7.4.1 (current is 4.7.3)
```

- Verified that the `-0ubuntu3~rk1` `.dsc` still references the accepted orig
  tarball SHA256:
  `1e1d12fb4eacd7dcbfdddf316691b2026c0e020f59aef1a84b932f483ad71679`.
- Signed and uploaded
  `librga_2.2.0+git20260703.a632217-0ubuntu3~rk1_source.changes` with `dput`.
  Client-side checks and FTP transfer succeeded.
- Checked Launchpad at `2026-07-06T14:56:45-07:00`:
  - `librga 2.2.0+git20260703.a632217-0ubuntu3~rk1` source was `Pending`;
  - fresh librga arm64 build `33366345` was `Currently building`;
  - previous librga arm64 build `33366258` remained `Failed to build`;
  - MPP arm64 binary publications from source publication `18601758` were still
    `Pending`;
  - the public arm64 `Packages.gz` index still did not list MPP or librga
    binaries.
- Checked Launchpad again at `2026-07-06T15:22:49-07:00`:
  - librga arm64 no-change rebuild `33366345` was `Successfully built` on
    builder `bos03-arm64-045`, completed at
    `2026-07-06T22:08:39.280299+00:00`, duration `0:12:27.016930`;
  - the successful `-0ubuntu3~rk1` build has a normal build log URL;
  - the earlier failed `-0ubuntu2~rk1` arm64 build `33366258` had run on
    `bos03-arm64-009` and still has no build log URL;
  - because `-0ubuntu3~rk1` was a no-change rebuild against the same accepted
    upstream orig tarball, and local arm64 librga binaries also built
    successfully, classify the `-0ubuntu2~rk1` arm64 failure as a Launchpad
    builder/infrastructure transient unless a delayed failure log appears;
  - `librga -0ubuntu3~rk1` source remained `Pending`;
  - MPP arm64 binary publications were still `Pending`;
  - the public arm64 `Packages.gz` index still did not list MPP or librga
    binaries.
- Checked Launchpad again at `2026-07-06T15:27:15-07:00`:
  - `librga -0ubuntu3~rk1` source was still `Pending`;
  - librga arm64 build `33366345` was still `Successfully built`;
  - MPP arm64 binary publications were still `Pending`;
  - the public arm64 `Packages.gz` index still did not list MPP or librga
    binaries.
- Do not upload ffmpeg yet; Launchpad's ffmpeg build dependencies will not be
  satisfiable until `librockchip-mpp-dev` and `librga-dev` are published in the
  PPA arm64 package index.

## ffmpeg staging strategy

- User asked to publish both upstream FFmpeg 8.1.2 and the
  `ffmpeg-rockchip-81` forward-port so GNOME Remote Desktop can be validated
  against both.
- Packaging constraint: both tracks naturally provide the same binary package
  names (`ffmpeg`, `ffmpeg-doc`, `libav*-dev`, and some runtime libraries). In a
  single PPA series, only one version of a given binary package name can be the
  active candidate at a time.
- Staging approach for this PPA:
  - first use the upstream FFmpeg 8.1.2 package as a baseline replacement build;
  - validate GNOME Remote Desktop against that baseline;
  - then upload the higher-version `ffmpeg-rockchip-81` forward-port package so
    it supersedes the baseline for the standard `ffmpeg` package names;
  - validate GNOME Remote Desktop again against the forward-port.
- If simultaneous installable upstream/fork FFmpeg stacks are required later,
  that should be done with separate PPAs or with an explicitly renamed/private
  FFmpeg stack, not with two active providers of the same stock Ubuntu package
  names in one PPA.
- Found an existing local upstream FFmpeg 8.1.2 source package:
  `/home/yi/Code/rock-5b/gnome/grd/grd-ppa/ffmpeg_8.1.2-1+rk1_source.changes`.
  It targets `resolute`, source version `7:8.1.2-1+rk1`, source package
  `ffmpeg`, and the binary package set uses the upstream 8.1.2 ABI
  (`libavcodec62`, `libavformat62`, `libavfilter11`, `libavutil60`,
  `libswresample6`, `libswscale9`).
- Confirmed version ordering: `7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk1`
  sorts higher than `7:8.1.2-1+rk1`, so the forward-port will supersede the
  upstream-baseline `ffmpeg` binaries when uploaded later.
- `dpkg-checkbuilddeps` on the local upstream FFmpeg 8.1.2 source tree is
  satisfied on this host; Launchpad still needs the PPA's MPP build-dependency
  to publish before the source should be uploaded.
- Source lintian for the upstream FFmpeg 8.1.2 package reports warnings only:

```text
W: ffmpeg source: orig-tarball-missing-upstream-signature ffmpeg_8.1.2.orig.tar.xz
W: ffmpeg source: superfluous-file-pattern libavfilter/vf_fspp.h [debian/copyright:606]
W: ffmpeg source: superfluous-file-pattern tests/checkasm/llviddspenc.c [debian/copyright:606]
```

- Checked Launchpad again at `2026-07-06T15:30:34-07:00`:
  - `librga -0ubuntu3~rk1` source was still `Pending`;
  - MPP arm64 binary publications were still `Pending`;
  - the public arm64 `Packages.gz` index still did not list MPP or librga
    binaries.
- Staged the upstream FFmpeg 8.1.2 source artifacts into
  `/tmp/ubuntu-rock-5b-ppa/artifacts/`:
  - `ffmpeg_8.1.2.orig.tar.xz`;
  - `ffmpeg_8.1.2-1+rk1.debian.tar.xz`;
  - `ffmpeg_8.1.2-1+rk1.dsc`;
  - `ffmpeg_8.1.2-1+rk1_source.buildinfo`;
  - `ffmpeg_8.1.2-1+rk1_source.changes`.
- Signed the staged upstream FFmpeg 8.1.2 source upload with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`. Do not upload until the MPP
  build-dependency is public in the arm64 PPA index.
- Re-ran lintian on the prepared `ffmpeg-rockchip-81` source upload:

```text
W: ffmpeg source: newer-standards-version 4.7.4.1 (current is 4.7.3)
W: ffmpeg changes: package-has-long-file-name ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk1_source.changes
W: ffmpeg buildinfo: package-has-long-file-name ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk1_source.buildinfo
W: ffmpeg source: superfluous-file-pattern libavfilter/vf_fspp.h [debian/copyright:606]
W: ffmpeg source: superfluous-file-pattern libavfilter/vf_pp7.h [debian/copyright:606]
W: ffmpeg source: superfluous-file-pattern tests/checkasm/aarch64/* [debian/copyright:606]
W: ffmpeg source: superfluous-file-pattern tests/checkasm/arm/* [debian/copyright:606]
W: ffmpeg source: superfluous-file-pattern tests/checkasm/llviddspenc.c [debian/copyright:606]
W: ffmpeg source: superfluous-file-pattern tests/checkasm/riscv/* [debian/copyright:606]
W: ffmpeg source: superfluous-file-pattern tests/checkasm/x86/* [debian/copyright:606]
```

- Signed the prepared `ffmpeg-rockchip-81` source upload
  `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk1_source.changes`
  with `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`. Do not upload until both
  `librockchip-mpp-dev` and `librga-dev` are public in the arm64 PPA index.
- Checked Launchpad again at `2026-07-06T15:37:58-07:00`:
  - MPP arm64 binary publications were still `Pending`; example
    `librockchip-mpp-dev` binary publication `246516236` was created at
    `2026-07-06T21:31:14.146430+00:00`, had no scheduled deletion/removal
    fields, and was still waiting for `date_published`;
  - `librga -0ubuntu3~rk1` source publication `18601847` was still `Pending`,
    created at `2026-07-06T21:55:11.225265+00:00`;
  - the related librga source upload `38574402` was `Done`;
  - the PPA itself was `Active`, `publish=true`, publishing method `Local`,
    repository format `Debian`;
  - the public arm64 `Packages.gz` index still did not list MPP or librga.
- Conclusion: MPP and librga are blocked on Launchpad publication latency, not
  on a packaging/build failure. Keep ffmpeg uploads staged but do not upload
  until the build dependencies are visible in the arm64 package index.
- Checked Launchpad again at `2026-07-06T15:48:06-07:00`:
  - MPP arm64 binary publications were still `Pending`;
  - `librga -0ubuntu3~rk1` source publication was still `Pending`;
  - the public arm64 `Packages.gz` index still did not list MPP or librga.
- After the publication records remained pending, uploaded the upstream FFmpeg
  8.1.2 baseline source package anyway so it can enter Launchpad's build queue
  or dependency-wait path while MPP publishes:
  `ffmpeg_8.1.2-1+rk1_source.changes`.
- Client-side `dput` checks and FTP transfer succeeded. Hold the
  `ffmpeg-rockchip-81` upload until the upstream-baseline FFmpeg build has had
  a chance to run, because the forward-port version sorts higher and will
  supersede the baseline `ffmpeg` binary package names in this PPA.
- Checked Launchpad at `2026-07-06T15:50:49-07:00`:
  - upstream FFmpeg source `7:8.1.2-1+rk1` was `Pending`;
  - upstream FFmpeg arm64 build `33366878` was `Needs building`;
  - the build record did not show dependency-wait at this point.
- Checked again at `2026-07-06T15:53:31-07:00`:
  - upstream FFmpeg arm64 build `33366878` was still `Needs building`;
  - the build record still did not show dependency-wait;
  - MPP arm64 binary publications were still `Pending`;
  - the public arm64 `Packages.gz` index still did not list MPP, librga, or
    ffmpeg binaries.
- Checked again at `2026-07-06T15:59:17-07:00`:
  - upstream FFmpeg arm64 build `33366878` was still `Needs building`;
  - the build record still did not show dependency-wait;
  - MPP arm64 binary publications were still `Pending`;
  - the public arm64 `Packages.gz` index still did not list MPP, librga, or
    ffmpeg binaries.

## Public APT index recheck

- Checked the public PPA APT indexes at `2026-07-06T15:29:31-07:00`:
  - `dists/resolute/main/source/Sources.gz` publishes:
    - `mpp 1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1`;
    - `librga 2.2.0+git20260703.a632217-0ubuntu2~rk1`;
  - `ffmpeg` is not present in the public source index;
  - the no-change `librga -0ubuntu3~rk1` retry is not yet present in the
    public source index, even though the earlier Launchpad build check showed
    its arm64 build succeeded;
  - `dists/resolute/main/binary-arm64/Packages.gz` is empty;
  - `dists/resolute/main/binary-amd64/Packages.gz` is empty.
- Install-facing conclusion: the PPA is **not apt-installable yet**. The current
  public repository contains MPP/librga source publications but no public arm64
  binary packages, and FFmpeg is still intentionally held back until
  `librockchip-mpp-dev` and `librga-dev` publish.

## Public APT index recheck for public-facing docs

- Checked the public PPA APT indexes again at `2026-07-06T15:51:26-07:00`:
  - `dists/resolute/main/source/Sources.gz` still publishes:
    - `mpp 1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1`;
    - `librga 2.2.0+git20260703.a632217-0ubuntu2~rk1`;
  - no FFmpeg source is present in the public APT source index yet;
  - `dists/resolute/main/binary-arm64/Packages.gz` is empty;
  - `dists/resolute/main/binary-amd64/Packages.gz` is empty.
- This is consistent with the earlier Launchpad API state: the upstream FFmpeg
  baseline source upload was pending/needs-building, while the higher-version
  `ffmpeg-rockchip-81` upload remained held. Install-facing conclusion remains
  unchanged: **do not tell users to install from this PPA yet**.

## Public APT index recheck before docs handoff

- Checked the public PPA APT indexes again at `2026-07-06T15:56:55-07:00`.
  State was unchanged from the public-facing-docs recheck:
  - `dists/resolute/main/source/Sources.gz` still publishes:
    - `mpp 1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1`;
    - `librga 2.2.0+git20260703.a632217-0ubuntu2~rk1`;
  - no FFmpeg source is present in the public APT source index;
  - `dists/resolute/main/binary-arm64/Packages.gz` is empty;
  - `dists/resolute/main/binary-amd64/Packages.gz` is empty.
- Install-facing conclusion remains unchanged: **do not tell users to install
  from this PPA yet**.

## Upstream FFmpeg 8.1.2 build polling

- Started a one-minute poll loop for upstream FFmpeg arm64 build `33366878`.
- Observed the following Launchpad states:
  - `2026-07-06T16:08:11-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:09:12-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:10:12-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:11:13-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:12:13-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:13:14-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:14:15-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:15:15-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:16:16-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:17:17-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:18:17-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:19:18-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:20:19-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:21:19-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:22:20-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:23:21-07:00`: `Needs building`, no dependency-wait text,
    no build log yet.
  - `2026-07-06T16:24:21-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:25:22-07:00`: `Needs building`, no dependency-wait text,
    no build log yet. This appears to be a transient Launchpad state wobble
    after the first `Currently building` observation.
  - `2026-07-06T16:26:23-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:27:23-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:28:24-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:29:25-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:30:26-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:31:26-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:32:27-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:33:28-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:34:28-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:35:29-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:36:29-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:37:30-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:38:31-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:39:31-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:40:32-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:41:33-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:42:33-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:43:34-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:44:35-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:45:35-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:46:36-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:47:37-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:48:37-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:49:38-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.
  - `2026-07-06T16:50:38-07:00`: `Currently building`, no dependency-wait
    text, no build log URL exposed yet.

## gnome-remote-desktop and grd-ffmpeg packaging prep

- Confirmed the requested GRD source tree is
  `/home/yi/Code/rock-5b/gnome/grd/grd-ffmpeg`, branch
  `ffmpeg-rkmpp-encode-backend`, HEAD
  `a59c904c99088235eb4de31ca340747d334494f3`.
- The source tree is intentionally dirty and was treated as a working-tree
  snapshot, not as a clean git-archive export:

```text
 M src/grd-encode-session.c
 M src/grd-encode-session.h
 M src/grd-rdp-frame.c
 M src/grd-rdp-frame.h
 M src/grd-rdp-render-context.c
 M src/grd-rdp-renderer.c
 M src/grd-rdp-renderer.h
 M src/grd-rdp-surface-renderer.c
 M src/grd-rdp-surface-renderer.h
?? _run/
?? src/shaders/grd-avc-dual-view.spv
?? src/shaders/grd-avc-dual-view_opt.spv
```

- Captured the tracked-file dirty delta in
  `packaging/ppa/gnome-remote-desktop/source-deltas/dirty20260706-worktree.patch`
  so the PPA source snapshot can be reconstructed without the original dev-box
  worktree. The patch covers the 9 modified source files above and excludes
  `_run/` plus generated `*.spv` files, matching the source-package exporter.
- Verified the captured delta with `git apply --check` against a clean archive
  of commit `a59c904c99088235eb4de31ca340747d334494f3`.
- Updated `packaging/ppa/build-source-packages.sh` so the default GRD path now
  archives `GRD_COMMIT` and applies `GRD_DELTA`; it no longer requires the
  source tree to be dirty before export.
- Tightened orig-tarball reuse: when an artifact-directory orig tarball exists,
  the helper now extracts it and checks that it matches the freshly exported
  source tree before reusing it. This preserves Launchpad's byte-identical-orig
  requirement while catching stale source/orig mismatches locally.
- Re-ran the GRD source export through that reconstructed path:

```text
OUT=/tmp/rock5b-ysp-grd-source-test FORCE_ORIG=1 \
  bash packaging/ppa/build-source-packages.sh grd
```

  `dpkg-buildpackage -S -sa -us -uc -d` completed successfully and produced:

```text
gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706.orig.tar.gz
gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1.debian.tar.xz
gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1.dsc
gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_source.buildinfo
gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_source.changes
```

- Re-ran the same command without `FORCE_ORIG=1` against the same output
  directory. The helper reused the existing orig tarball after the new
  source-vs-orig content check, and `dpkg-buildpackage -S` completed again.

- Reused the known working rkmpp GRD packaging from
  `/home/yi/Code/rock-5b/gnome/grd/grd-pkg/gnome-remote-desktop-50.1+rkmpp/debian`,
  but copied it into YSP at `packaging/ppa/gnome-remote-desktop/debian`
  without generated debhelper output and without the older quilt patch stack.
- Rationale for dropping the quilt patches in this YSP packaging copy:
  `grd-ffmpeg` already has the rkmpp backend and the mainline `h264_rkmpp`
  workaround commits applied in git, so replaying
  `debian/patches/0001-*` and `0002-*` would duplicate already-applied source
  changes.
- Set the binary package architecture to `arm64` for the ROCK 5B PPA.
- Added a PPA snapshot changelog entry:
  `50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1`.
  This sorts newer than the existing local debug build
  `50.1+rkmpp-4~ackdbg5`.
- Earlier in this run, `packaging/ppa/build-source-packages.sh` first gained a
  `gnome-remote-desktop` / `grd` target that exported the current working tree
  with `rsync` so uncommitted GRD validation changes were included. That
  interim exporter was superseded by the `GRD_COMMIT` + `GRD_DELTA` path
  recorded above; the exclusion list is retained here as historical context:
  - `.git/`;
  - `debian/`;
  - `_run/`;
  - common build directories;
  - generated `*.spv` shader outputs.
- Confirmed `src/shaders/grd-avc-dual-view.comp` is in the orig tarball and
  `src/shaders/grd-avc-dual-view_opt.spv` is not. Meson regenerates the SPIR-V
  outputs at build time using the existing `glslc` and `spirv-tools`
  Build-Depends.
- Built the unsigned GRD source package with:

```text
packaging/ppa/build-source-packages.sh grd
```

- Produced these artifacts in `/tmp/ubuntu-rock-5b-ppa/artifacts/`:

```text
gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706.orig.tar.gz
gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1.debian.tar.xz
gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1.dsc
gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_source.buildinfo
gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_source.changes
```

- The generated `.dsc` reports:
  - `Format: 3.0 (quilt)`;
  - `Architecture: arm64`;
  - Build-Depends include `libavcodec-dev (>= 7:8.1.2~)` and
    `libavutil-dev (>= 7:8.1.2~)`;
  - `Package-List` contains `gnome-remote-desktop deb gnome optional arch=arm64`.
- `lintian` on the GRD source upload reported only filename-length warnings:

```text
W: gnome-remote-desktop source: package-has-long-file-name gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1.dsc
W: gnome-remote-desktop changes: package-has-long-file-name gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_source.changes
W: gnome-remote-desktop buildinfo: package-has-long-file-name gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_source.buildinfo
W: gnome-remote-desktop source: source-package-component-has-long-file-name gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1.debian.tar.xz
```

- Local command failure noted: an attempted `dpkg-source --print-format` command
  was pointed at the `.dsc` file as if it were a directory and failed. This was
  an operator command error only; direct inspection of the generated `.dsc`
  confirmed the source package format and metadata.
- GRD upload status: prepared and lintian-checked, but not signed or uploaded
  yet. Hold until the upstream FFmpeg baseline has either built or reached a
  useful dependency-wait state, because this GRD package intentionally validates
  against FFmpeg 8.1.2 first and then against the higher-version
  `ffmpeg-rockchip-81` upload after it supersedes the baseline.

## gnome-remote-desktop local binary validation

- Extracted the generated GRD `.dsc` into
  `/tmp/ubuntu-rock-5b-ppa/extract-grd`; extraction succeeded. The only warning
  was that the source package is unsigned, which is expected before `debsign`.
- Confirmed the extracted source has no `debian/patches` directory.
- `dpkg-checkbuilddeps` succeeded in the extracted source tree.
- Local FFmpeg headers used for this validation:

```text
pkg-config --modversion libavcodec -> 62.28.102
pkg-config --modversion libavutil   -> 60.26.102
ffmpeg                              -> 7:8.1.2-1+rk1
libavcodec-dev:arm64                -> 7:8.1.2-1+rk1
libavcodec62:arm64                  -> 7:8.1.2-1+rk1
libavutil-dev:arm64                 -> 7:8.1.2-1+rk1
libavutil60:arm64                   -> 7:8.1.2-1+rk1
```

- Local `dpkg-query` also reported no installed `libavcodec63` or `libavutil61`,
  confirming this local build validates against the upstream FFmpeg 8.1.2
  baseline ABI, not the ffmpeg-rockchip-81 ABI.
- First local binary build attempt:

```text
DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -us -uc
```

- That build configured successfully with `-Dffmpeg=enabled`, found
  `libavcodec 62.28.102`, `libavutil 60.26.102`, `glslc`, and `spirv-opt`,
  and compiled the FFmpeg backend objects. It failed at manpage generation:

```text
/home/yi/.local/share/mise/installs/python/latest/bin/python3: Error while finding module specification for 'asciidoc.a2x' (ModuleNotFoundError: No module named 'asciidoc')
```

- Root cause of that failure: `/usr/bin/a2x` is a shell wrapper that executes
  `python3 -m asciidoc.a2x`, and the interactive environment resolved
  `python3` to `~/.local/share/mise/installs/python/latest/bin/python3`, which
  does not have the distro `asciidoc` module. With a system PATH,
  `python3` resolves to `/usr/bin/python3`, where `asciidoc` is installed.
  This is a local environment issue, not a GRD, FFmpeg, MPP, RGA, or kernel
  failure.
- Retried the local binary build with a sanitized PATH:

```text
PATH=/usr/sbin:/usr/bin:/sbin:/bin DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage -b -us -uc
```

- The sanitized local build succeeded and produced:

```text
/tmp/ubuntu-rock-5b-ppa/gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_arm64.deb
/tmp/ubuntu-rock-5b-ppa/gnome-remote-desktop-dbgsym_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_arm64.ddeb
```

- The successful local build installed the regenerated shader artifact into the
  package:

```text
/usr/share/gnome-remote-desktop/shaders/grd-avc-dual-view_opt.spv
```

- The successful local build emitted two non-fatal packaging warnings:
  - `dh_translations: warning: more than one build.ninja file found, don't know
    which one to use`;
  - `dpkg-shlibdeps: warning: diversions involved - output may be incorrect`
    for the `libc6` usr-merge dynamic-linker diversion.
- The built binary package depends on the upstream baseline FFmpeg libraries:

```text
libavcodec62 (>= 7:8.1.2), libavutil60 (>= 7:8.1.2)
```

- Binary `lintian` on the local GRD `.changes` reported only filename-length
  warnings:

```text
W: gnome-remote-desktop: package-has-long-file-name gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_arm64.deb
W: gnome-remote-desktop changes: package-has-long-file-name gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_arm64.changes
W: gnome-remote-desktop buildinfo: package-has-long-file-name gnome-remote-desktop_50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk1_arm64.buildinfo
```

- Packaging conclusion: no GRD packaging changes appear necessary for the
  upstream FFmpeg 8.1.2 baseline. The same source package should rebuild against
  `ffmpeg-rockchip-81` when its higher-version `libavcodec-dev` and
  `libavutil-dev` supersede the baseline in the PPA; that second validation will
  be needed after the fork packages publish.

## Public APT index recheck after watchlist update

- Checked the public PPA APT indexes again at `2026-07-06T16:43:41-07:00`.
  Public APT state was still not installable:
  - `dists/resolute/main/source/Sources.gz` still publishes:
    - `mpp 1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1`;
    - `librga 2.2.0+git20260703.a632217-0ubuntu2~rk1`;
  - no FFmpeg or GRD source is present in the public APT source index;
  - `dists/resolute/main/binary-arm64/Packages.gz` is empty;
  - `dists/resolute/main/binary-amd64/Packages.gz` is empty.
- Checked Launchpad's source-publication API at the same time:
  - `librga 2.2.0+git20260703.a632217-0ubuntu3~rk1` source publication is
    still `Pending`;
  - upstream baseline `ffmpeg 7:8.1.2-1+rk1` source publication is still
    `Pending`;
  - `gnome-remote-desktop` has no source publication entries.
- Install-facing conclusion remains unchanged: **do not tell users to install
  from this PPA yet**.

### 2026-07-07

## Upstream FFmpeg 8.1.2 baseline arm64 build failure (build 33366878)

- Launchpad arm64 build `33366878` of the upstream baseline
  `ffmpeg 7:8.1.2-1+rk1` failed on `bos03-arm64-098` after ~22 minutes.
- Not a compile error: compilation and linking succeeded; the failure is in
  the FATE test suite run by `override_dh_auto_test-arch`. Exactly two tests
  failed:
  - `fate-filter-frei0r-filter`
  - `fate-filter-frei0r-filter-unaligned`
- Both fail with:

```text
[Parsed_frei0r_1 @ ...] Could not find module 'distort0r'.
[AVFilterGraph @ ...] Error initializing filters
```

- Root cause: these FATE tests are new in FFmpeg 8.1 and load the real
  `distort0r.so` frei0r plugin at runtime. The build chroot only had
  `frei0r-plugins-dev` (headers, from Build-Depends) installed, not
  `frei0r-plugins`, which ships the plugin modules. Ubuntu resolute's archive
  never hit this because it is still on FFmpeg 8.0.1, and Debian's 8.1.x
  changelog shows no frei0r-related build-dep fix yet.
- Verified resolute's arm64 `frei0r-plugins` package ships
  `/usr/lib/aarch64-linux-gnu/frei0r-1/distort0r.so` and provides the
  `/usr/lib/frei0r-1` path that ffmpeg's frei0r filter searches.
- The `mpp_soc: open /proc/device-tree/compatible error` lines in the build
  log are harmless: the MPP runtime probing for Rockchip hardware that does
  not exist on the Launchpad builder.
- Fix applied to the forward-port packaging in this repo
  (`packaging/ppa/ffmpeg/debian/`):
  - `debian/control`: added `frei0r-plugins <!nocheck !pkg.ffmpeg.stage1>`
    to Build-Depends next to `frei0r-plugins-dev`;
  - `debian/changelog`: bumped to
    `7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2` (the ~rk1
    source upload was signed but never uploaded, so it is superseded before
    upload).
- Remaining work on the board (`/home/yi`, not reachable from the Mac where
  this entry was written):
  - apply the same `frei0r-plugins <!nocheck>` Build-Depends change to the
    upstream-baseline `8.1.2-1+rk1` tree used for
    `/home/yi/Code/rock-5b/gnome/grd/grd-ppa/ffmpeg_8.1.2-1+rk1_source.changes`,
    bump it to `7:8.1.2-1+rk2` (still sorts below the forward-port
    version), rebuild the source package, re-sign, and `dput`;
  - rebuild and re-sign the forward-port source package from the updated
    `debian/` in this repo before its (still held) upload.

## Baseline packaging recovered from Launchpad and checked in

- The upstream-baseline `7:8.1.2-1+rk1` `debian/` tree was never in git; it
  existed only at `/home/yi/Code/rock-5b/gnome/grd/grd-ppa/` on the board. A GitHub
  search confirmed no other repo carries it.
- Recovered it from the Launchpad source publication (`+sourcepub/18602029`,
  status `Published`): downloaded `ffmpeg_8.1.2-1+rk1.debian.tar.xz` and the
  `.dsc`, and verified the tarball sha256
  `88d622f3090478439cebb30d1ded7b966012a21362982d8101b99a7463742b07` against
  the `.dsc` checksums.
- Checked the tree into this repo at `packaging/ppa/ffmpeg-baseline/debian/`
  with the frei0r fix applied and the changelog bumped to `7:8.1.2-1+rk2`:
  - `debian/control`: `frei0r-plugins <!nocheck !pkg.ffmpeg.stage1>` added to
    Build-Depends (same fix as the forward-port tree);
  - provenance and rebuild instructions in
    `packaging/ppa/ffmpeg-baseline/README.md`.
- Version ordering re-checked: `7:8.1.2-1+rk2` still sorts below
  `7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2`, so the baseline →
  forward-port supersede plan is unchanged.
- Remaining board-side work: rebuild the baseline source package from
  `ffmpeg-baseline/debian/` plus the existing byte-identical
  `ffmpeg_8.1.2.orig.tar.xz`, `debsign`, `dput`; then rebuild and re-sign the
  forward-port `~rk2` source from `packaging/ppa/ffmpeg/debian/`.

### 2026-07-08

## Fixed FFmpeg baseline upload

- Rechecked current Launchpad/PPA state before upload:
  - MPP `1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1` is `Published`;
  - librga `2.2.0+git20260703.a632217-0ubuntu3~rk1` is `Published`;
  - public `binary-arm64/Packages.gz` contains `librockchip-mpp-dev`,
    `librockchip-mpp1`, `librockchip-vpu0`, `librockchip-vpu1`,
    `rockchip-mpp-demos`, `librga-dev`, and `librga2`;
  - baseline FFmpeg `7:8.1.2-1+rk1` is `Published`, but arm64 build
    `33366878` is `Failed to build`.
- Rebuilt the fixed upstream-baseline source package from the checked-in
  `packaging/ppa/ffmpeg-baseline/debian/` tree and the existing orig tarball
  `/home/yi/Code/rock-5b/gnome/grd/grd-ppa/ffmpeg_8.1.2.orig.tar.xz`.
- Verified the orig tarball is the byte-identical known input:

```text
464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c  ffmpeg_8.1.2.orig.tar.xz
```

- Version ordering was rechecked locally:

```text
7:8.1.2-1+rk2 < 7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2
```

- `dpkg-buildpackage -S -sa -us -uc -d` succeeded and produced:
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2.orig.tar.xz`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2-1+rk2.debian.tar.xz`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2-1+rk2.dsc`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2-1+rk2_source.buildinfo`
  - `/tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2-1+rk2_source.changes`
- `lintian` on the fixed source upload reported only the already-known
  baseline warnings:

```text
W: ffmpeg source: orig-tarball-missing-upstream-signature ffmpeg_8.1.2.orig.tar.xz
W: ffmpeg source: superfluous-file-pattern libavfilter/vf_fspp.h [debian/copyright:606]
W: ffmpeg source: superfluous-file-pattern tests/checkasm/llviddspenc.c [debian/copyright:606]
```

- Signed the source upload with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`; `debsign` successfully signed
  the `.dsc`, `.buildinfo`, and `.changes` files.
- Uploaded with:

```text
dput ppa:yi-ding/ubuntu-rock-5b /tmp/ubuntu-rock-5b-ppa/artifacts/ffmpeg_8.1.2-1+rk2_source.changes
```

- Client-side `dput` checks and FTP transfer succeeded for:
  - `ffmpeg_8.1.2-1+rk2.dsc`
  - `ffmpeg_8.1.2.orig.tar.xz`
  - `ffmpeg_8.1.2-1+rk2.debian.tar.xz`
  - `ffmpeg_8.1.2-1+rk2_source.buildinfo`
  - `ffmpeg_8.1.2-1+rk2_source.changes`
- Launchpad accepted the upload into Pending source publication
  `18610234`; related package upload is `38591474`.
- The new arm64 build record is `33381225`, currently `Needs building`, with no
  dependency-wait text and no build log yet.
- Remaining FFmpeg work:
  - wait for baseline build `33381225` to finish or reach a useful failure
    state;
  - then rebuild and re-sign the higher-version `ffmpeg-rockchip-81`
    `7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2` source package
    from `packaging/ppa/ffmpeg/debian/` before uploading it.

### 2026-07-09

## Prepared held `ffmpeg-rockchip-81` `~rk2` source upload

- Rechecked Launchpad arm64 build `33381225` via the API before preparing the
  forward-port upload. It still reports `buildstate: Needs building`, with no
  builder, no first dispatch time, and no build log. The Rockchip-81 upload
  remains held.
- Regenerated the higher-version Rockchip-81 source package from the pinned
  source checkout:
  - repo: `/home/yi/Code/rock-5b/ffmpeg/ffmpeg-rockchip-81`
  - commit: `75638e7f0b1775193381af0c3187838f6c51dbd1`
  - packaging: `packaging/ppa/ffmpeg/debian/`
  - command: `bash packaging/ppa/build-source-packages.sh ffmpeg`
- Produced unsigned artifacts under `packaging/ppa/out/artifacts/`:
  - `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b.orig.tar.gz`
  - `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2.debian.tar.xz`
  - `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2.dsc`
  - `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2_source.buildinfo`
  - `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2_source.changes`
- Verified version ordering locally:

```text
7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2 > 7:8.1.2-1+rk2
```

- Verified the generated `.dsc` unpacks and contains the expected fixes:
  - changelog top entry is
    `7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2`;
  - `debian/control` contains
    `frei0r-plugins <!nocheck !pkg.ffmpeg.stage1>`;
  - `debian/rules` still enables
    `--enable-rkmpp --enable-rkrga --enable-version3`.
- `lintian` on
  `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2_source.changes`
  completed with warnings only:
  - `newer-standards-version 4.7.4.1`
  - long generated `.changes` / `.buildinfo` filenames
  - stale `debian/copyright` file patterns inherited from the upstream packaging
- Next action when baseline build `33381225` finishes or produces a useful log:
  sign and upload
  `packaging/ppa/out/artifacts/ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2_source.changes`.

## FFmpeg 6 helper package coexistence

- The existing FFmpeg 6-style helper artifact found locally is
  `gnome-remote-desktop-ffmpeg-rk_6.1+rkmpp1_arm64.deb`, not a distro-style
  `ffmpeg` package.
- Its binary package name is `gnome-remote-desktop-ffmpeg-rk`; it installs
  private FFmpeg libraries under
  `/usr/lib/gnome-remote-desktop/ffmpeg-rk/lib/`.
- Its control metadata conflicts only with
  `gnome-remote-desktop-ffmpeg-mainline` and provides
  `gnome-remote-desktop-ffmpeg`.
- That package shape does not conflict with the PPA's normal `ffmpeg` source or
  distro-style `ffmpeg`/`libav*` binaries. A source package named `ffmpeg` that
  builds normal `ffmpeg`/`libav*` binaries would not coexist; Debian version
  ordering would decide which one supersedes the other.
- Launchpad PPAs accept source uploads, not copied local `.deb` binaries, so
  publishing that helper through the PPA still requires a source package wrapper.

### 2026-07-10

## Baseline succeeded and Rockchip-81 source uploaded

- Rechecked baseline build `33381225` through the Launchpad API. It completed
  successfully:
  - source version: `7:8.1.2-1+rk2`
  - first dispatched: `2026-07-10T04:00:45.378167+00:00`
  - built: `2026-07-10T04:25:31.853230+00:00`
  - builder: `bos03-arm64-020`
- Signed the prepared Rockchip-81 source upload with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`; `debsign` successfully signed
  the `.dsc`, `.buildinfo`, and `.changes` files. The only warning was that the
  running `gpg-agent` was older than the `gpg` client.
- Uploaded with:

```text
dput ppa:yi-ding/ubuntu-rock-5b packaging/ppa/out/artifacts/ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2_source.changes
```

- Client-side `dput` checks and FTP transfer succeeded for:
  - `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2.dsc`
  - `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b.orig.tar.gz`
  - `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2.debian.tar.xz`
  - `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2_source.buildinfo`
  - `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2_source.changes`
- Launchpad accepted the source into Pending source publication `18614542`;
  related package upload is `38609150`.
- The new arm64 build record is `33387355`, currently `Needs building`.

## Co-installable nyanmisaka FFmpeg Rockchip source package

- Confirmed Ubuntu resolute's primary archive publishes system FFmpeg
  `7:8.0.1-3ubuntu2`, while the board currently has local/PPA
  `7:8.1.2-1+rk1` installed.
- Confirmed `/home/yi/Code/rock-5b/ffmpeg/ffmpeg-rockchip` is nyanmisaka's
  `ffmpeg-rockchip` fork:
  - repo: `https://github.com/nyanmisaka/ffmpeg-rockchip.git`
  - commit: `40c412daccf08164493da0de990eb99a8948116b`
  - `RELEASE`: `6.1`
  - ABI family: `libavcodec60`, `libavutil58`, `libavformat60`,
    `libavfilter9`, `libavdevice60`, `libswscale7`, `libswresample4`,
    `libpostproc57`
- Conclusion: this fork is too old to be a normal Ubuntu 26.04 system
  `ffmpeg` replacement. Packaging it as source package `ffmpeg` would either be
  a downgrade or collide with the existing baseline/Rockchip-81 `ffmpeg`
  package plan.
- Added source package `ffmpeg-rockchip` instead. It installs private tools
  under `/opt/ffmpeg-rockchip` and exposes non-shadowing commands
  `ffmpeg-rockchip`, `ffprobe-rockchip`, and `ffplay-rockchip`.
- Built unsigned source artifacts with:

```text
bash packaging/ppa/build-source-packages.sh ffmpeg-rockchip
```

- `dpkg-source -x` and source `lintian` validation passed.
- Local arm64 binary validation passed after two packaging adjustments:
  - disabled LTO with `DEB_BUILD_MAINT_OPTIONS = hardening=+all optimize=-lto` because the first static link consumed too many local resources;
  - made `override_dh_auto_test` a no-op because upstream FATE HLS list generation segfaulted with Error 139 in this fork.
- The resulting package installs `/opt/ffmpeg-rockchip/bin/{ffmpeg,ffprobe,ffplay}` plus `/usr/bin/{ffmpeg-rockchip,ffprobe-rockchip,ffplay-rockchip}` and depends only on external runtime libraries such as `librockchip-mpp1`, `librga2`, `libdrm2`, `libsdl2-2.0-0`, `zlib1g`, and `libbz2-1.0`. Feature checks found the expected RKMPP encoders/decoders and RKRGA filters.
- Signed and uploaded `ffmpeg-rockchip_6.1+git20260423.40c412dacc-0ubuntu1~rk1_source.changes` to `ppa:yi-ding/ubuntu-rock-5b`. Launchpad accepted it as Pending source publication `18614552`; arm64 build `33387375` successfully built on `bos03-arm64-043`.

## Kernel source uploads and alpha rc2 refresh

- Verified the official kernel.org `v7.2-rc2` tag before updating the alpha
  mainline rewrite branch:
  - tag ref: `4c45e14df2f4e77982ad70d6d8e3fe750edd4c37 refs/tags/v7.2-rc2`;
  - peeled commit observed locally after fetch: `8cdeaa50eae8` ("Linux 7.2-rc2").
- Rebased `/home/yi/Code/rock-5b/kernel/linux` branch `rk3588-rewrite-mainline` from
  `v7.2-rc1` to `v7.2-rc2` with backup branch
  `ysp-backup/rk3588-rewrite-mainline-before-7.2-rc2`. The rebased tip is
  `083bdb98e715` and `git describe` reports `v7.2-rc2-224-g083bdb98e715`.
- Signed and uploaded the forward-port kernel source package:
  - `linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk1_source.changes`;
  - `dput ppa:yi-ding/ubuntu-rock-5b` completed client-side FTP upload.
- Added and built alpha rewrite kernel source packages:
  - `linux-rockchip64-ysp-alpha-6.18_6.18.0+rk3588rewritealpha20260710-0ubuntu1~rk1_source.changes`;
  - `linux-rockchip64-ysp-alpha-7.2-rc2_7.2.0~rc2+rk3588rewritealpha20260710-0ubuntu1~rk1_source.changes`.
- Source validation passed for both alpha packages:
  - source package helper export and `dpkg-buildpackage -S`;
  - `dpkg-source -x` of each generated `.dsc`;
  - `debian/rules override_dh_auto_configure` in each extracted source;
  - resolved configs keep the rewrite MPP/RGA drivers and KUnit suites built in,
    disable stock RGA, and keep `CONFIG_VSI_IOMMU=y`.
- Signed both alpha `.changes` files with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6` and uploaded them with `dput`.
- Launchpad API check at 2026-07-10 23:05 PDT:
  - forward-port kernel source publication `18614540` is `Published`; arm64
    build `33387353` is `Currently building` on `bos03-arm64-094`;
  - alpha 6.18 source publication `18614549` is `Pending`; arm64 build
    `33387366` is `Needs building`;
  - alpha 7.2-rc2 source publication `18614550` is `Pending`; arm64 build
    `33387367` is `Needs building`;
  - Rockchip-81 FFmpeg source publication `18614542` is `Published`; arm64
    build `33387355` is `Currently building` on `bos03-arm64-113`.
- Pending kernel work: wait for Launchpad builds/publication, run any local
  binary/payload comparisons still missing for the alpha packages, and validate
  board install, reboot, rollback, and `kernel-revert.sh` recovery before giving
  install guidance.

## Rockchip-81 FFmpeg `~rk2` build failure and `~rk3` packaging fix

- Launchpad arm64 build `33387355` for
  `7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk2` failed during
  `override_dh_auto_configure` on 2026-07-11 UTC.
- The build log shows `../../configure` rejected `--disable-omx` before writing
  `ffbuild/config.log`:

```text
Unknown option "--disable-omx".
See ../../configure --help for available options.
```

- Prepared local package revision
  `7:8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk3` by removing
  `--disable-omx` from `packaging/ppa/ffmpeg/debian/rules`.
- Validation before committing the packaging fix:
  - `dpkg-source --before-build packaging/ppa/ffmpeg` passed;
  - `git diff --check` passed;
  - `make -f packaging/ppa/ffmpeg/debian/rules -n override_dh_auto_configure`
    dry-run output no longer includes `--disable-omx` in the generated
    configure commands.
- Rebuilt the `~rk3` source package with `bash packaging/ppa/build-source-packages.sh ffmpeg`; it reused the existing orig tarball and produced `ffmpeg_8.1.2+rockchip81+git20260703.75638e7f0b-0ubuntu1~rk3_source.changes`.
- Source `lintian` completed with warnings only: known newer-standards-version, long source artifact names, and inherited stale copyright file-pattern warnings.
- Signed the `~rk3` `.dsc`, `.buildinfo`, and `.changes` files with `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`; the only warning was the older local `gpg-agent`.
- Uploaded `~rk3` with `dput ppa:yi-ding/ubuntu-rock-5b`. Launchpad accepted it as Pending source publication `18614555` and created arm64 build `33387380`, currently `Currently building` on `bos03-arm64-014`.

## Kernel Launchpad build state update

- Launchpad API/log check at 2026-07-10 23:30 PDT:
  - forward-port kernel source publication `18614540` remains `Published`, but
    arm64 build `33387353` failed. The log shows `/bin/sh: 1: mkimage: not
    found` while generating
    `arch/arm64/boot/dts/rockchip/overlay/rockchip-fixup.scr`;
  - alpha 6.18 source publication `18614549` remains `Pending`; arm64 build
    `33387366` is `Currently building` on `bos03-arm64-032`;
  - alpha 7.2-rc2 source publication `18614550` remains `Pending`; arm64 build
    `33387367` is `Currently building` on `bos03-arm64-008`.
- Next forward-port kernel retry likely needs the `mkimage` provider in
  Build-Depends before rebuilding and uploading a new Debian revision.

## Kernel `~rk2` retry uploads for `mkimage`

- Added `u-boot-tools` to Build-Depends for all three PPA kernel source
  packages so Launchpad provides `mkimage` while generating Rockchip overlay
  fixup scripts.
- Bumped Debian revisions and rebuilt source packages with existing orig
  tarballs:
  - `linux-rockchip64-ysp_6.18.38+rk3588av1fwport20260709-0ubuntu1~rk2_source.changes`;
  - `linux-rockchip64-ysp-alpha-6.18_6.18.0+rk3588rewritealpha20260710-0ubuntu1~rk2_source.changes`;
  - `linux-rockchip64-ysp-alpha-7.2-rc2_7.2.0~rc2+rk3588rewritealpha20260710-0ubuntu1~rk2_source.changes`.
- Validation before upload:
  - `dpkg-source --before-build` passed for all three packaging directories;
  - all three generated `.dsc` files extracted cleanly;
  - extracted `debian/control` files contain `u-boot-tools`.
- Signed all three retry uploads with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6` and uploaded them with `dput`.
- Launchpad API check at 2026-07-10 23:49 PDT found the retry uploads accepted
  as Pending source publications:
  - forward-port source `18614559`, arm64 build `33387391` `Currently building` on `bos03-arm64-047`;
  - alpha 6.18 source `18614560`, arm64 build `33387392` `Currently building` on `bos03-arm64-110`;
  - alpha 7.2-rc2 source `18614561`, arm64 build `33387393` `Currently building` on `bos03-arm64-074`.

## FFmpeg correctness fixes on main and replacement source upload

- Applied the two RKMPP correctness fixes directly to `ffmpeg-rockchip-81`
  `main` and pushed them:
  - `8356739686` — drop the invalid static decoder `pix_fmts` advertisement;
  - `be367abfe6` — mark codec extradata packets with MPP's extra-data flag.
- Merged the updated main into `refactor/section-c` without a tree change and
  pushed merge `844d95e047`, keeping PR #1 clean and mergeable while avoiding a
  history rewrite.
- Advanced `FFMPEG_COMMIT` to full main commit
  `be367abfe67045b9c68812ecee3b6162c92f9776` and source version to
  `8.1.2+rockchip81+git20260711.be367abfe6`.
- Removed both Debian quilt backports; the exported source contains both fixes
  directly and has no `debian/patches/series`.
- Built source version
  `7:8.1.2+rockchip81+git20260711.be367abfe6-0ubuntu1~rk1`; verified version
  ordering over public `~rk5`, source contents, and the absent quilt series.
- Source lintian exited 0 with the existing standards-version, long-filename,
  and stale copyright-pattern warnings only.
- Signed the `.dsc`, `.buildinfo`, and `.changes` with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6` and uploaded with `dput`.
- Launchpad accepted the upload at 2026-07-11 21:10 PDT as pending source
  publication `18615674`; no build record existed at that first API check.

## Final publication and build update

- Launchpad API and public arm64 index check at 2026-07-11 21:44 PDT:
  - replacement Rockchip-81 FFmpeg source `18615674` is Published; arm64 build
    `33388714` succeeded, and the `ffmpeg`/`libav*63` packages are indexed;
  - co-installable `ffmpeg-rockchip` source `18614552` and successful arm64
    build `33387375` are public;
  - forward-port kernel source `18614559` and arm64 build `33387391` succeeded;
  - alpha 6.18 source `18614560` and arm64 build `33387392` succeeded;
  - alpha 7.2-rc2 source `18614561` and arm64 build `33387393` succeeded;
  - all three kernel image/DTB/header sets appear in the public arm64 index.
- Publication/build waiting gates are therefore closed. Remaining kernel gates
  are board install, reboot, rollback, and recovery validation; GRD and GDM ACL
  remain held.

### 2026-07-14

## FFmpeg 8.0 compatibility port and PPA split

- Created `ffmpeg-rockchip-81` branch `rockchip-8.0` from official tag
  `n8.0.3` and ported the RKMPP/RKRGA feature and hardening series back to the
  FFmpeg 8.0 ABI. The tested tip is
  `463f542c325942f3e6b390cb940c32812570957d`.
- The resulting distro-style package retains `libavcodec62`, `libavutil60`,
  `libavformat62`, `libavfilter11`, `libavdevice62`, `libswscale9`, and
  `libswresample6`. A full local binary build, executable/media FATE tests,
  extracted-package smoke tests, and RK3588 RKMPP encode/decode plus zero-copy
  RKMPP-to-RGA-to-RKMPP tests passed.
- Replaced the temporary rollback version with the honest source version
  `7:8.0.3+rockchip+git20260713.463f542c-0ubuntu1~rk1`. The source package was
  built under `packaging/ppa/out/`, extracted successfully, linted with only
  the inherited newer-standards-version warning, and signed with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`.
- Created four arm64-only PPAs and copied source plus existing binaries:
  - `ppa:yi-ding/rock5b-ffmpeg81-upstream`: upstream FFmpeg 8.1.2 source
    publication `18619544`, 29 binary publications;
  - `ppa:yi-ding/rock5b-ffmpeg81-rockchip`: Rockchip FFmpeg 8.1.2 source
    publication `18619545`, 29 binary publications;
  - `ppa:yi-ding/rock5b-kernel618-rewrite`: Linux 6.18 rewrite source
    publication `18619546`, three binary publications;
  - `ppa:yi-ding/rock5b-kernel72rc2-rewrite`: Linux 7.2-rc2 rewrite source
    publication `18619548`, three binary publications.
- An uncached Launchpad API check on 2026-07-14 PDT found all four dedicated
  source publications and every copied binary `Published`.
- Requested temporary source-plus-binary copies of MPP, librga, co-installable
  FFmpeg 6.1, the 6.18 forward-port kernel, and patched GNOME Remote Desktop in
  `ppa:yi-ding/ubuntu-rock-5b-experimental`. These holding copies protect the
  stable package set while the old main archive is deleted and recreated.
- Prepared GNOME Remote Desktop revision
  `50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk2` for the recreated
  main PPA. It lowers the FFmpeg development-package floor from 8.1.2 to 8.0.1.
  The source extracts cleanly, and source lintian reports only long-filename
  warnings.
- Compiled and linked the GRD RKMPP backend against the isolated libraries from
  the locally built FFmpeg 8.0 package. Meson selected `libavcodec 62.11.103`
  and `libavutil 60.9.100`; the resulting daemon has `NEEDED` entries for
  `libavcodec.so.62` and `libavutil.so.60`. A local `dpkg-shlibdeps` check with
  the isolated package metadata generated matching `libavcodec62` and
  `libavutil60` dependencies. Signed the GRD `~rk2` source upload with the same
  PPA upload key.
- Before deletion, downloaded the exact 12 stable arm64 binary packages from
  the old main PPA into workspace storage and verified their package, version,
  architecture, and SHA-256 checksums. The pending holding source records also
  expose independent source-file URLs under the experimental PPA.
- Launchpad accepted deletion of `ppa:yi-ding/ubuntu-rock-5b` on 2026-07-14 at
  approximately 09:10 PDT. The API now exposes the old archive only as a
  disabled/redacted tombstone. Immediate recreation correctly fails while
  Launchpad's deletion grace period still reserves the name.
- Added a native PPA source wrapper for `rk3588-codec-udev 1.0`, which installs
  the canonical MPP/RGA/DMA-heap access rule. Its source and arm64-hosted `all`
  binary builds pass, both source and binary lintian are clean, package contents
  and dependencies are correct, and the source upload is signed. The main-stack
  installer now installs this package and adds the invoking login user to the
  `video` group when needed.
- Launchpad released the deleted `ubuntu-rock-5b` name at 2026-07-14 09:56 PDT,
  about 46 minutes after deletion. Recreated it with a fresh archive identity,
  configured only the arm64 processor, and retained the owner-wide signing key
  `EA233A9BF99005077CDDAE7ACB968BDF039404E2`.
- Configured `ppa:yi-ding/rock5b-ffmpeg81-rockchip` to use the fresh main PPA
  as an archive dependency for future MPP/librga build dependencies.
- Restored source plus existing binaries from the holding PPA into the fresh
  main archive:
  - MPP source publication `18619785`;
  - librga source publication `18619786`;
  - co-installable FFmpeg 6.1 source publication `18619787`;
  - 6.18 forward-port kernel source publication `18619788`.
  The old GRD binary was deliberately not restored: inspection confirmed it
  needs `libavcodec.so.63` and `libavutil.so.61`.
- Uploaded signed `rk3588-codec-udev 1.0`; Launchpad accepted source
  publication `18619789`, and arm64-hosted `Architecture: all` build `33397244`
  succeeded.
- Temporarily added the published holding PPA as a build dependency so the
  honest FFmpeg upload could not race pending MPP/librga publication. Uploaded
  `7:8.0.3+rockchip+git20260713.463f542c-0ubuntu1~rk1`; Launchpad accepted
  source publication `18619822` and started arm64 build `33397317` on
  `bos03-arm64-101`.
- Uploaded GRD
  `50.1+rkmpp+git20260630.a59c904+dirty20260706-0ubuntu1~rk2`. Launchpad
  accepted source publication `18619824` and queued arm64 build `33397319`.
  Building against Ubuntu's native 8.0 development headers is valid because
  the backend uses the 8.0 public ABI and resolves `h264_rkmpp` at runtime; the
  exact Rockchip-library link was already tested locally.
- Removed the temporary main-to-holding archive dependency after FFmpeg started
  with its dependencies resolved. An API check shows the fresh main PPA has
  zero extra archive dependencies.

## PR review corrections

- Reordered the clean migration so it adds the main PPA, refreshes APT, and
  verifies the complete exact-version target set before removing any prior
  split or experimental PPA source.
- Added a removal allowlist to the APT simulation. The migration now rejects
  any `Remv` or `Purg` action outside the explicitly discovered conflict set,
  including reverse-dependencies that APT would otherwise remove under
  `--yes`.
- Added an exact post-transaction FFmpeg check. The migration invokes
  `/usr/bin/ffmpeg` rather than trusting `PATH` and requires it to advertise
  `h264_rkmpp`, preventing a private helper binary from masking a broken system
  package install.
- Advanced `rk3588-codec-udev` to `1.1`. Its post-install action now retriggers
  the live `/sys/class` paths for MPP, RGA, IEP, and each DMA heap, waits for
  udev, and verifies `root:video 0660` on every device exposed by the running
  kernel.
- Source and binary builds and lintian pass for `1.1`. Installing the local
  package on the ROCK 5B successfully retriggered `/dev/mpp_service`,
  `/dev/rga`, and the `reserved`, `system`, and `system-uncached` DMA heaps;
  every node verified as `root:video 0660`.
- Signed `rk3588-codec-udev_1.1_source.changes` with upload key
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`, verified the `.changes` and
  `.dsc` signatures, and uploaded it to `ppa:yi-ding/ubuntu-rock-5b` on
  2026-07-14 at approximately 19:00 PDT. Launchpad acceptance/publication was
  not monitored.

## Final six-PPA publication recheck

- Anonymous Launchpad API recheck at `2026-07-14T20:28:21-07:00` found every
  current source and binary in the recreated main PPA Published:
  - MPP source `18619785` plus five arm64 binaries;
  - librga source `18619786` plus two arm64 binaries;
  - co-installable FFmpeg 6.1 source `18619787` plus its arm64 tool package;
  - forward-port kernel source `18619788` plus image, DTB, and headers;
  - FFmpeg 8.0.3 source `18619822`, successful arm64 build `33397317`, and 29
    binary publications;
  - GRD source `18619824`, successful arm64 build `33397319`, and its arm64
    binary;
  - codec-udev 1.1 source `18620729`, successful arm64-hosted build
    `33399688`, and its architecture-independent binary. Version 1.0 is
    Superseded.
- The four dedicated archives remain complete:
  - `rock5b-ffmpeg81-upstream`: source `18619544` and 29 binaries Published;
  - `rock5b-ffmpeg81-rockchip`: source `18619545` and 29 binaries Published;
  - `rock5b-kernel618-rewrite`: source `18619546` and three binaries Published;
  - `rock5b-kernel72rc2-rewrite`: source `18619548` and three binaries
    Published.
- The holding archive `ubuntu-rock-5b-experimental` still has five Published
  source sets and their copied binaries: MPP, librga, co-installable FFmpeg
  6.1, the forward-port kernel, and GRD `~rk1`. The GRD holding binary requires
  `libavcodec.so.63`/`libavutil.so.61` and must not be used as the normal-stack
  GRD package.
- The recreated main PPA has zero archive dependencies. The temporary holding
  dependency used during the FFmpeg build has not leaked into the final
  archive configuration.
- Publication/build waiting gates are closed. Remaining work is the optional
  GDM ACL upload and board validation of the clean migration and all PPA kernel
  install/reboot/revert paths.

## GRD reconnect-v2 experimental candidate — 2026-07-14

- Re-audited the old `rdp-handover-reconnect@a3a1a32` patch after the macOS
  Windows App stalled at “Configuring remote PC.” The old global
  `client_taken` state rejected the legitimate second GDM→session leg because
  the routing token is reused. Its preserve-on-abort path also explained the
  observed zombie remote displays.
- Built a replacement on packaged GRD base `a59c904`. The public fork branch
  [`rdp-handover-reconnect-v2`](https://gitlab.gnome.org/yding/gnome-remote-desktop/-/commits/rdp-handover-reconnect-v2)
  ends at `eb91daf476dc1c4ba23ccfdd8c077b8b83e84773` and contains:
  - `9347fee` — commit the already-validated hardware encode backpressure guard;
  - `ba0e75c` — GNOME 50.2's official revert of `5230bf3`, restoring
    `SetRemoteId` and the two-stage reconnect contract;
  - `d5689a5` — sink the floating `RedirectClient` `GVariant` before signal
    emission consumes it;
  - `75dbc7c` — release the socket returned by `TakeClient` in the handover
    daemon;
  - `13fc01d` — guard a missing socket and make abort-timer ownership explicit;
  - `eb91daf` — replace only a concurrently pending redirected socket, leaving
    the routing token reusable after `TakeClient`.
- A clean Meson/Ninja build passed, as did the GRD RDP test; TPM and hardware
  EGL tests skipped because those devices were unavailable. A full native
  arm64 `dpkg-buildpackage -b` completed and produced the package. Source and
  binary lintian reported only long-filename warnings from the descriptive
  version.
- Built and signed source version
  `50.1+rkmpp+git20260714.eb91daf-0ubuntu1~exp1` with upload key
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`. `dput` passed checksum and GPG
  checks and uploaded it to `ppa:yi-ding/ubuntu-rock-5b-experimental`.
- SHA-256 of the signed upload set:
  - orig tarball: `a72245614d8267154a71287e1e72d42bbd62277c16df1fb6a7736a19470ae825`;
  - Debian tarball: `cf6f45caeb360c6be3a4c7e119122dbfb4e5e86dd200fba02f719f4b997a7c22`;
  - signed `.dsc`: `c87fe0957611d00e9212e94ec5b1f0eab88b0feef67f5658a41a6047f55379a9`;
  - signed source `.buildinfo`: `5d4c5cbcf0e3ff7c2f06dabdaceadf9906fb48b11998fbb9d43b84fc52324119`;
  - signed source `.changes`: `baefc19eb0ffc2cf06ac6a3203792fb2c0a93e013dc634da77dfda84622fc690`.
- Launchpad accepted upload `38656891` as source publication
  [`18620800`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+sourcepub/18620800)
  and arm64 build
  [`33399816`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+build/33399816).
  By 21:27 PDT the builder run had completed and Launchpad reported
  `Uploading build`; a 2026-07-15 recheck confirmed `Successfully built`.
- Remaining gate: reproduce the original reconnect from the macOS Windows App
  against `~exp1`. Do not promote it to the normal PPA or submit the upstream MR
  solely on compile/test coverage.

## Armbian-based rewrite kernel publication — 2026-07-16

- Revalidated the exact 6.18.38 and 7.2-rc3 source upload sets with
  `dscverify --nosigcheck`; every `.dsc`, orig tarball, Debian tarball, and
  source `.buildinfo` checksum passed. `lintian --fail-on error` passed for
  both source `.changes` files.
- Signed both source sets with upload key
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`. Direct `gpg --verify` reported a
  good signature from `Yi Ding <yi.s.ding@gmail.com>` on each signed
  `.changes` file.
- `dput` passed its supported-distribution, required-field, checksum,
  suite-mismatch, source-only, and GPG checks and uploaded:
  - `linux-rockchip64-ysp-alpha-6.18`
    `6.18.38+rk3588rewritealpha20260715-0ubuntu1` to
    `ppa:yi-ding/rock5b-kernel618-rewrite`;
  - `linux-rockchip64-ysp-alpha-7.2-rc3`
    `7.2.0~rc3+rk3588rewritealpha20260715-0ubuntu1` to the legacy-named
    `ppa:yi-ding/rock5b-kernel72rc2-rewrite`.
- Launchpad accepted upload `38664613` as 6.18.38 source publication
  [`18623665`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+sourcepub/18623665)
  and started arm64 build
  [`33406491`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel618-rewrite/+build/33406491).
  It accepted upload `38664614` as 7.2-rc3 source publication
  [`18623666`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+sourcepub/18623666)
  and started arm64 build
  [`33406492`](https://launchpad.net/~yi-ding/+archive/ubuntu/rock5b-kernel72rc2-rewrite/+build/33406492).
  Both builds were `Currently building` at `2026-07-16T12:37:41-07:00`; the
  historical 6.18.0 and 7.2-rc2 binaries remain Published while the
  replacements build.
- Documented the boot contract and runtime gate. Booting the 6.18.38 package
  selects built-in `ROCKCHIP_MPP_REWRITE` and `ROCKCHIP_RGA_REWRITE` while the
  conflicting vendor MPP/RGA drivers are disabled. The post-reboot checklist
  now requires exact release/config identity, both device nodes, both rewrite
  debugfs owners, boot-log review, the decode/encode/transcode smoke, a full
  rewrite run with hardware counter assertions, and a paired forward-port
  comparison before treating the kernel as validated.

## Forward-port 5.10 reconciliation publication — 2026-07-16

- Built the 6.18.38 Armbian integration tree with the 37-patch forward-port
  series. The production-config image, DTBs, headers, and libc development
  packages completed successfully with build identity `Pf618-Cb831`.
- Generated source version
  `6.18.38+rk3588av1fwport20260716-0ubuntu1~rk1` with a fresh deterministic
  orig tarball. `dpkg-buildpackage -S -sa` completed, and `dpkg-source -x`
  verified all checksums.
- Inspected the extracted source rather than relying on the live worktree. It
  contains sequential RGA batching, both RK3588 low-voltage workarounds,
  config/parse-error reporting, cache-line shadow pages, request/fence and
  IOMMU/register corrections, the RKVENC2 multi-slice terminal-error fix, and
  the existing AV1/VSI-IOMMU/shared-domain/RCB series. The production config
  enables `ROCKCHIP_MPP_SERVICE`, `ROCKCHIP_MPP_RKVENC2`,
  `ROCKCHIP_MPP_RKVDEC2`, `ROCKCHIP_MPP_AV1DEC`, `ROCKCHIP_MULTI_RGA`,
  `ROCKCHIP_IOMMU`, and `VSI_IOMMU`.
- Signed the `.dsc`, source `.buildinfo`, and source `.changes` with key
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`. Direct verification reported a
  good EDDSA signature from `Yi Ding <yi.s.ding@gmail.com>`.
- Final SHA-256 upload set:
  - orig tarball: `85852d5cb9f31ccb464ea8346333b4ba252cc4427ed5ae9839afb2dd3313519e`;
  - Debian tarball: `089486ad4c4de36786ed293c0a964db74b341a0590c34dd234ae5ce436bcb4b8`;
  - signed `.dsc`: `0352de749acaea1955dc03eaab31f96cec6d8c9e8615d12b6e0d0fbbcd045b41`;
  - signed source `.buildinfo`: `06bffff3b9f4b23d007e6c71d9005129a7cafb5eb8c7cc59a059e23e90123df6`;
  - signed source `.changes`: `7ee408054748f01ad627d5a8eaafaacfbbe3236ef8b89c68bccce78139c5e6df`.
- `dput` passed distribution, field, checksum, suite, source-only, and GPG
  checks and uploaded all five artifacts to `ppa:yi-ding/ubuntu-rock-5b`.
  Launchpad accepted upload `38666840` as source publication
  [`18624245`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18624245)
  and started arm64 build
  [`33407351`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33407351)
  on `bos03-arm64-097`. It was `Currently building` at
  `2026-07-16T16:07:14-07:00`; the previous kernel source/binaries remain
  Published until this replacement completes.

## Forward-port RGA physical-import hardening — 2026-07-16

- Advanced the source package to
  `6.18.38+rk3588av1fwport20260716.1-0ubuntu1~rk1`. It carries forward-port
  commit `1c9a110129fef3ca8ed2c5af15658666742774d0`, which validates every raw
  RGA physical-import page as mapped System RAM before DMA cache maintenance,
  checks both relevant range additions for overflow, and removes the
  user-triggerable warning from the invalid-input path. The raw physical ABI,
  librga, ioctl-fuzz, and syzkaller probes are now opt-in.
- The Docker-backed Armbian integration build applied the complete 38-patch
  series and produced image, DTB, and headers packages with build identity
  `P4825-Cb831`. Local Armbian package SHA-256 values:
  - image: `ecff3339043dcce6dcdbb0331d983c23d2cb325dd447a55441436be141d4c062`;
  - DTB: `8346d6722f2080494e0b39926dae8c0f8494bbafe71af7d4543de0fc69ae2e94`;
  - headers: `e1f0e19187a12d7e1e4969a9aa83abb3021d1ec2acf0c56ca5c9e9740e3b1512`.
- Generated the PPA source with `dpkg-buildpackage -S -sa`.
  `dscverify --nosigcheck` validated all source checksums, a fresh
  `dpkg-source -x` succeeded, and inspection of the extracted source confirmed
  the per-page linear-map check plus both overflow guards. The hardened
  `rga_mm.o` also compiled during both full builds.
- Built all three arm64 binaries from that freshly extracted `.dsc`, using a
  workspace-local cold ccache. `dpkg-buildpackage -b` exited 0 and produced:
  - `linux-image-ysp-rockchip64` (57 MiB), SHA-256
    `960ee91fdbde134f5b2fe0aa86410d51f0b0b8c491311ef1c5ef7ca45ed2ed57`;
  - `linux-dtb-ysp-rockchip64` (1.3 MiB), SHA-256
    `7a6f656345067ddfee40e9f35270f4e9f203776fe01b7d1467ab33afd606e4c6`;
  - `linux-headers-ysp-rockchip64` (16 MiB), SHA-256
    `7a54115d43907d12ca4f1f31adc71bdf50c77b98c5dec3043c1cfb70249461d3`.
  Stable local copies are under
  `packaging/ppa/out/artifacts/local-binaries/6.18.38+rk3588av1fwport20260716.1/`.
  Both source and binary `lintian` scans remained silent for several minutes
  and were stopped rather than delaying the release; neither completed.
- Signed the `.dsc`, source `.buildinfo`, and source `.changes` with key
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`. Direct `gpg --verify` reported a
  good EDDSA signature from `Yi Ding <yi.s.ding@gmail.com>` on all three.
  `dscverify` without an explicit personal keyring could not locate that public
  key, but its earlier checksum-only pass and the direct signature checks both
  succeeded.
- Final signed source SHA-256 upload set:
  - orig tarball: `d00b14468710d9c12fa2be90769129c909767076ed241ffebd0545c931ebc20c`;
  - Debian tarball: `47b8c48006655633c969f8f37de730513bbdf33e91f628c2aee6f1ab06f016db`;
  - signed `.dsc`: `3c9daf92fda6e2538609fb803f1a11044fe29b2753cc64eda5d2a8edff42f21c`;
  - signed source `.buildinfo`: `d90537b716dc9c844e8815dfbc8e53079eb9039b9137d037f1e12e63af50ded7`;
  - signed source `.changes`: `e0ea15b122bc67d27053e523460ec8a3ec216842e7e4d452bf7204fb7825049b`.
- `dput` passed its distribution, required-field, checksum, suite, source-only,
  and GPG checks, transferred all five artifacts to
  `ppa:yi-ding/ubuntu-rock-5b`, and exited 0 at approximately 22:46 PDT.
  Launchpad accepted the upload as pending source publication
  [`18624583`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18624583)
  and started arm64 build
  [`33407863`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33407863)
  on `bos03-arm64-036`. It was `Currently building` at
  `2026-07-16T22:52:17-07:00`. The preceding build `33407351` completed
  successfully at 16:50 PDT.
- Runtime status: the currently published `20260716` package predates the fix.
  Do not enable raw RGA physical-address probes until `.1` is published,
  installed, and booted. The first board gate is an invalid-import negative
  test that must return an errno without a warning, oops, reboot, or new
  RGA/IOMMU fault.

## GRD pipeline-diagnostics candidate — 2026-07-17

- The live handover session running reconnect-v2 `~exp1` froze after Firefox
  opened. The board and kernel remained responsive and the kernel journal had
  no new oops, warning, RGA/IOMMU fault, or codec fault, leaving userspace frame
  starvation as the leading hypothesis rather than a proven cause.
- Added diagnostic-only commit `1c870bc82d1920edfac1e1544b61bd7c7b9a1873`
  on public branch `debug/exp1-frame-starvation`, directly on top of
  `rdp-handover-reconnect-v2@eb91daf`. It emits rate-limited
  `[RDP.PIPELINE]` summaries for buffer, queued-frame, view, stale-drop,
  encode, submission, full-refresh, render-context-reset, and hardware-cooldown
  progress. A warning fires after two seconds of outstanding queued work while
  buffers continue arriving without a submitted frame, then at most once
  every five seconds. The commit does not change scheduling or drop policy.
- Clean Meson/Ninja validation succeeded with `/usr` as the install prefix.
  The isolated GRD RDP integration test passed; TPM and hardware-EGL tests
  skipped because their required devices were unavailable. `git diff --check`
  passed.
- Generated source package
  `50.1+rkmpp+git20260717.1c870bc-0ubuntu1~exp2` and built the arm64 binary from
  its exported source with `DEB_BUILD_OPTIONS=nocheck`. The binary contains the
  daemon and optimized AVC shader and depends on the normal PPA's exact
  Rockchip FFmpeg 8.0 ABI (`libavcodec62`/`libavutil60`). Source and binary
  lintian completed without errors; the only findings were long-filename
  warnings caused by the descriptive package version.
- Local arm64 package:
  `packaging/ppa/out/work/gnome-remote-desktop_50.1+rkmpp+git20260717.1c870bc-0ubuntu1~exp2_arm64.deb`,
  SHA-256 `851b638d3982d7b038def33ebe2ecc0d4e663e1196710b7c1e6c99d331ab31f1`.
- Signed the `.dsc`, source `.buildinfo`, and source `.changes` with key
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`; direct `gpg --verify` reported a
  good EDDSA signature from `Yi Ding <yi.s.ding@gmail.com>` on all three.
  `dscverify` without an explicit personal keyring could not locate the public
  key, while its checksum-only validation and the direct signature checks
  passed.
- Final source SHA-256 upload set:
  - orig tarball: `fe3ed45e85473cfdde50873e43b20842074e5b1930e827a971bbcad213441784`;
  - Debian tarball: `761f39e43c43711d09f1312ec314fe6cc3dc30249b29c308235cabd0caad507f`;
  - signed `.dsc`: `0ded95475482776b33dc7d8d8f2117d5f097722a63a36fe94e44df5f98e6f720`;
  - signed source `.buildinfo`: `89055e8853e6cbc83d0c36f202847b0c47eb1454bb031f0cafb034c4173f0675`;
  - signed source `.changes`: `797cb68357d48260856eb9bb6586eff95f62fe1ebf15ea8ed96e517cd3b1a852`.
- `dput` passed its distribution, required-field, checksum, suite, source-only,
  and GPG checks and uploaded all five source artifacts to
  `ppa:yi-ding/ubuntu-rock-5b-experimental`. Launchpad accepted pending source
  publication
  [`18625943`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+sourcepub/18625943)
  and started arm64 build
  [`33411510`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+build/33411510)
  on `bos03-arm64-050`. The uncached Launchpad API reported `Successfully
  built` at `2026-07-17T11:43:57-07:00` after 6m24s. Source publication
  `18625943` remained Pending and no binary publication was visible at
  `2026-07-17T11:46:55-07:00`.
- No package was installed or daemon restarted during the build/upload. The
  active session remained on `~exp1`; after `~exp2` publishes, the next gate is
  to reproduce the Firefox transition while preserving several seconds of
  `[RDP.PIPELINE]` journal output before and after the freeze.

## Bounded FFmpeg, session-lifetime kernel, and GRD recovery candidate — 2026-07-17

- Prepared normal-stack FFmpeg
  `7:8.0.3+rockchip+git20260717.540657970e-0ubuntu1~rk1` from commit
  `540657970efd7ae774c49259fa3fa6553bdf950b`. Synchronous low-delay and drain
  packet waits now use a 500 ms bound instead of `MPP_TIMEOUT_BLOCK`; the
  ordinary asynchronous path remains nonblocking.
- `dscverify --nosigcheck` and a clean `dpkg-source -x` passed for the FFmpeg
  source. A minimal extracted-source build with the system MPP headers compiled
  `libavcodec/rkmppenc.o`. Source lintian exited 0 with only the inherited
  newer-standards-version and long-filename warnings.
- Signed the FFmpeg `.dsc`, source `.buildinfo`, and source `.changes` with key
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`; direct verification reported a
  good signature from `Yi Ding <yi.s.ding@gmail.com>`. Final SHA-256 upload
  set:
  - orig tarball: `18447bdddab5ce42cef706b2b13b199a097fec863f5d19190223863569e1c5f3`;
  - Debian tarball: `e0a45b0ec6a636f2830ddb613f36be0722ca1090a6e5a74d883c1a22cede1ac5`;
  - signed `.dsc`: `797466858ccde2c119b799727223d4d48b1432e9f2ceeb6210d596d6b013cd14`;
  - signed source `.buildinfo`: `6aa5d4ebb28d2c5635b9bb760ec3ee0d6b34c22fb7ba6c65ce885f776932c5cd`;
  - signed source `.changes`: `04558c010b954a25e6f18ebd567dcbfb02623eeb844dc1f8474c84e2930d1770`.
- `dput` uploaded FFmpeg to `ppa:yi-ding/ubuntu-rock-5b`. Launchpad accepted
  pending source publication
  [`18626515`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18626515)
  and started arm64 build
  [`33412598`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33412598)
  on `bos03-arm64-082` at 17:38 PDT.
- FFmpeg build `33412598` completed successfully. Its final log reports a
  16m42s package build, and the live arm64 PPA index contains the exact
  `libavcodec-dev` and runtime packages.
- Advanced the forward-port kernel to
  `6.18.38+rk3588av1fwport20260717-0ubuntu1~rk1`, carrying RGA fix
  `bc086cbe03d7` and MPP fix `df0d7037213c`. The former drops a closing
  session's buffer reference through kref instead of force-freeing an object
  that can still be shared or in flight. The latter removes a session from the
  service list before device-private teardown so procfs cannot inspect freed
  encoder state.
- The Docker-backed Armbian integration build applied 40 shipped patches (41
  forward-port commits minus the libbpf fix already in the Armbian base),
  rebuilt the changed MPP/RGA objects, and completed image, modules, DTBs,
  headers, and Debian packaging in eight minutes. Build identity:
  `Pbc61-C40aa`.
- Generated the kernel source with `dpkg-buildpackage -S -sa`.
  `dscverify --nosigcheck`, fresh extraction, changed-source inspection, and
  packaged-config `olddefconfig` regeneration passed. The extracted config
  retains `CONFIG_ROCKCHIP_MPP_AV1DEC=y` and
  `CONFIG_VIDEO_ROCKCHIP_RGA=m`.
- Signed and uploaded the kernel source to the normal PPA. Final SHA-256 set:
  - orig tarball: `e3ea94609795205630be394fe70f572ad3c909432ac52c05d94fb194ddc9e305`;
  - Debian tarball: `e2355782aae0b62b4a0028d944c6e9b06419774ab29fdcebd8018b5389f3508e`;
  - signed `.dsc`: `ecfab23462756b21ac2ff6751e12fbc854d3e3b3e98d62f767961dee2923a1b2`;
  - signed source `.buildinfo`: `2509834c593784d65e676e152831502bcd9eab626a8f58ad62b5c27e27830eb6`;
  - signed source `.changes`: `ff7aaf9fb6fd17f95bb141f77093e7f54450ef0080b731493790a5ce42023f2a`.
  Launchpad accepted pending source publication
  [`18626523`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18626523)
  and started arm64 build
  [`33412608`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33412608).
- Kernel build `33412608` completed successfully. Its final log reports a
  41m45s build, and the live PPA index contains the exact
  `linux-image-ysp-rockchip64` package and pool artifact.
- Prepared experimental GRD
  `50.1+rkmpp+git20260717.2571326-0ubuntu1~exp3` from commit
  `2571326322c754de7608ef4afb1dff8e4d031cbd`. It reuses the smoke-tested
  RKMPP context, uses forced-IDR full refreshes instead of repeated reopen,
  recovers to software after a bounded hardware encode failure, and runs the
  pipeline watchdog on an independent main context.
- GRD source generation, checksum validation, extraction, Meson/Ninja build,
  signing, and source lintian pass. The local RDP integration test timed out
  after Mutter started but before the test daemon listened on localhost; it
  never reached the changed encode path. TPM and EGL tests skipped for missing
  hardware. Final signed source SHA-256 set:
  - orig tarball: `af1645bb6581f7f96d7710c308541a44383db94cbcca0ad15a998334453b52e9`;
  - Debian tarball: `7c5e9b74f72c64766f03d487c6a5ce27a70ba697721e8419ab33273a3ee73c82`;
  - signed `.dsc`: `560e4a396deefab24b68d9b7938d87fc1f218697db2e83748b0faf5e6804c5fe`;
  - signed source `.buildinfo`: `40cee4d8f797757393713bcef67ccbf8f304ee8f13bfef5e72f40d1dee47a0ff`;
  - signed source `.changes`: `79161dfb7bef80c248922e31a005de1d9a07b6716358f97add3fa73b0094825f`.
- The experimental PPA initially had no archive dependencies. Added the
  normal PPA as a one-way `Release/main` build dependency and confirmed it in
  the authenticated Launchpad view. The normal PPA has no dependency on the
  experimental archive.
- Held the GRD upload until the live normal-PPA arm64 index exposed the exact
  new `libavcodec-dev`, avoiding a non-retrying dependency failure. `dput`
  then uploaded all five signed source artifacts to the experimental PPA.
  Launchpad accepted source publication
  [`18626586`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+sourcepub/18626586)
  and arm64 build
  [`33412698`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b-experimental/+build/33412698)
  completed successfully in 6m39s. Its build-time RDP test passed; TPM and EGL
  skipped on unavailable devices. Binary publication is pending at this check.

## FFmpeg input-backpressure fix and publication recheck — 2026-07-19

- Advanced the normal-PPA FFmpeg source to
  `7:8.0.3+rockchip+git20260719.da5befc806-0ubuntu1~rk1` from
  `ffmpeg-rockchip-81@da5befc806c5a6179da3df825c9423918c9a10d3`. The wrapper
  now retries a synchronous `MPP_NOK` input handoff within the existing shared
  500 ms deadline instead of waiting for output from a frame that was never
  submitted, and maps an elapsed packet wait to `EAGAIN`.
- Generated, signed, and uploaded the source package to
  `ppa:yi-ding/ubuntu-rock-5b`; source lintian produced warnings only.
  Launchpad Published source
  [`18628833`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18628833),
  arm64 build
  [`33417109`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33417109)
  completed successfully in 14m53s, and an exact-version API query confirmed
  the `ffmpeg` arm64 binary is Published. Board installation and the sustained
  GRD workload remain pending.
- Rechecked the other formerly pending package lines through Launchpad's devel
  API and exact-version binary queries. Experimental GRD `~exp3` source
  `18626586`, successful build `33412698`, and its arm64 binary are Published.
  Rewrite-kernel sources `18623665`/`18623666` and builds
  `33406491`/`33406492` are Published/successful. These publication results do
  not replace the open GRD or kernel board-runtime gates.

## GNOME Remote Desktop 50.2 normal-PPA upload — 2026-07-21

- Advanced the clean package export to public branch
  `release/50.2-rkmpp@cf60b4d9d2c5adb6ea9f4b7f3397449895f069f2`, containing
  15 release commits on upstream 50.2 commit `60423c896a54`. The official
  reconnect revert is now part of the upstream base; the retained RKMPP,
  handover ownership, cached-readback, bounded encode-recovery, and
  progress-gated ACK-recovery changes are otherwise unchanged.
- Built source package
  `50.2+rkmpp+git20260721.13.cf60b4d-0ubuntu1~rk1`, extracted it fresh, and
  completed an exact native arm64 binary build with `/usr/bin/pkg-config`.
  The RDP integration test passed; TPM and EGL skipped on unavailable hardware.
  Source and binary Lintian runs reported only long-filename warnings.
- The binary package contains the optimized AVC shader, depends on
  `libavcodec62` at the published bounded-wait FFmpeg revision, and was not
  installed during this upload workflow.
- Signed the `.dsc`, source `.buildinfo`, and source `.changes` with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`; direct verification reported a
  good signature from `Yi Ding <yi.s.ding@gmail.com>`. Final SHA-256 upload set:
  - orig tarball: `1384e294bea1265685136fed4679b9f3e1704169b1b574a909fe90a40e2d8ef8`;
  - Debian tarball: `1475e152663547d1b00de9b66dd225d029709c473f641872bb7b141f4c44a6ef`;
  - signed `.dsc`: `0dc8672c3febd55cad268f3c89bf5988e8d9fcd93ccc99ea10fd1963dadddd1b`;
  - signed source `.buildinfo`: `91e474985e4fc276dc37ba68de85b02c1bad768088a17ea835daedf5ec99bbe8`;
  - signed source `.changes`: `3934a232d94d9135fa90354bf9b7259da54ca5b7efd04e44164583ba580260dd`.
- `dput` passed distribution, required-field, checksum, suite, source-only,
  and GPG checks and transferred all five source artifacts to
  `ppa:yi-ding/ubuntu-rock-5b`. Launchpad accepted source publication
  [`18632058`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18632058)
  and started arm64 build
  [`33422570`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33422570)
  on `bos03-arm64-015`. The source is Pending and the build is running at this
  check.

## GNOME Remote Desktop full-range BT.709 promotion — 2026-07-29

- The clean post-reboot package experiment closed the visual gate: changing
  the FFmpeg encoder context from limited/unspecified color signaling to
  full-range BT.709 fixed the muted colors on the tested Microsoft macOS RDP
  client. The result is visual rather than colorimetric and does not establish
  behavior on other clients.
- Promoted the exact tested source delta to public branch
  `release/50.2-rkmpp@24f4392bb0daa40b9c411de1b1bcb9d0078e506a`, the
  sixteenth release commit on upstream 50.2 `60423c896a54`. Package
  `50.2+rkmpp+git20260729.14.24f4392-0ubuntu1~rk1` archives that commit
  directly with no `GRD_DELTA`.
- Generated the source package, extracted it fresh, and completed an exact
  native arm64 binary build with `/usr/bin/pkg-config`. The RDP integration
  test passed; TPM and hardware-EGL skipped on unavailable hardware. The
  sandboxed first test attempt could not bind D-Bus sockets and exercised no
  test body; the unrestricted host rerun produced the recorded pass/skip
  result.
- Source and binary Lintian runs returned success with only the expected
  long-filename warnings. The packaged daemon is an aarch64 PIE, all `ldd`
  dependencies resolve, and the package depends on the bounded-wait
  `libavcodec62` revision. Local binary SHA-256 set:
  - `.deb`: `7b1790b6424afa9a5654b5eaacb82441fe23cbecd6b37dd532a4425f5eeb84bf`;
  - `.ddeb`: `1a3496e854ec0d2f7bb7144e99369c9ebeed6f7582eb7524be350753b27392c7`;
  - arm64 `.buildinfo`: `b0ccad3b3b8ef8c0e85c99dbdd2edc6b8dfa6ed0a6e1a37ac46b3850fdbf8aa8`;
  - arm64 `.changes`: `53c848a36178be02ed838d67f55671e63e604415a569987c22806d760fb53401`.
- Signed the `.dsc`, source `.buildinfo`, and source `.changes` with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`; direct verification reported
  good signatures from `Yi Ding <yi.s.ding@gmail.com>`. Final SHA-256 upload
  set:
  - orig tarball: `f257ec332493bbdef4dfb5c78c3b1363b0b7dbb375a69d23b49e7483b4103158`;
  - Debian tarball: `017edbe5f8c0f8d6541c2dd9fcdd5d4d5ec7040c1bd0415c7bae2b727c52b165`;
  - signed `.dsc`: `599c891ff900437f4fd0fa56b1b3ef914de73e363b0644fa4faba797d4895e3e`;
  - signed source `.buildinfo`: `1d7f103ac7a60af39fe4e7e9846f1bbb59d0f92be87bb0044484b88cdd1297bc`;
  - signed source `.changes`: `db82e7eec7b3cf537fd9a36438ca90a87a1e94ee0f993fbab32f313300dff3a7`.
- `dput` passed distribution, required-field, checksum, suite, source-only,
  and GPG checks and transferred all five source artifacts to
  `ppa:yi-ding/ubuntu-rock-5b`. The local
  `gnome-remote-desktop_50.2+rkmpp+git20260729.14.24f4392-0ubuntu1~rk1_source.ppa.upload`
  marker exists.
- Launchpad accepted source publication
  [`18647901`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18647901)
  and dispatched arm64 build
  [`33450532`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33450532)
  to `bos03-arm64-101`; the source is Pending and the build is running at this
  check.

## MPP RADL and FFmpeg unused-RPS uploads — 2026-07-29

- Advanced MPP to `ysp/main@3381fd2c` and package
  `1.5.0+git20260729.3381fd2c+ds-0ubuntu1~rk1`. The source package and native
  arm64 binary build pass; all five expected packages were produced. Source
  and binary Lintian returned success with only inherited standards-version,
  missing demo man-page, and long-filename warnings.
- Advanced the normal-PPA FFmpeg line to
  `fix/rkmpp-output-timeout@33a651a55b` and package
  `7:8.0.3+rockchip+git20260729.33a651a55b-0ubuntu1~rk1`. Source construction,
  `dscverify`, and Lintian's error gate pass. The native binary build is
  delegated to Launchpad.
- Signed both `.dsc`, source `.buildinfo`, and source `.changes` files with
  `0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`. MPP upload SHA-256 set:
  - orig tarball: `757d1e40078413d12c3f06b4658bb0c3a617ee79b598fe225cefee571f05fbc8`;
  - Debian tarball: `2671ae8ef15cc90fe2867980ec8abf4c884ce53879b2437d939aea4e24722540`;
  - signed `.dsc`: `5d46b471d24318a7756ae110bddc6a9358b8477c007af5881c8713e7fc7cd06f`;
  - signed source `.buildinfo`: `96d70cd8dd135662a85124a67722a030ec0f2e16fd8333e4c5ca529c1e7e7bb9`;
  - signed source `.changes`: `71edbb039a0d9ff8c5fc6819bfb1661bd175e6907dd9858ca21e2075f3922541`.
- FFmpeg upload SHA-256 set:
  - orig tarball: `4a183db31bad455cb169e37a2e4baf778ae9367667f718d09467c961bcc50c26`;
  - Debian tarball: `92a66f508b6228982cb6a52a73b3518b0d068f2b1b484e30ce8c533949103175`;
  - signed `.dsc`: `d9f481696abe76961735aa9809287c575eb139d66ab1f5ac8e0bd77e335c72b1`;
  - signed source `.buildinfo`: `eacd0e8fdc57c126a99f06069603105236bee7aa0c837aadfa39e11e7d376c27`;
  - signed source `.changes`: `13fd97c494a7a3c3fc484ba03cee25f947b8b886f6934ef37516351932b7840a`.
- `dput` passed its distribution, field, checksum, suite, source-only, and GPG
  checks and transferred both five-file source sets to
  `ppa:yi-ding/ubuntu-rock-5b`; both local `.ppa.upload` markers exist.
- Launchpad accepted MPP source publication
  [`18647958`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18647958)
  and queued arm64 build
  [`33450621`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33450621).
  It accepted FFmpeg source publication
  [`18647960`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18647960)
  and queued arm64 build
  [`33450629`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33450629).
  Both sources became Published. MPP build `33450621` succeeded in 12m53s and
  produced five Published arm64 binaries, publications
  [`247606929`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247606929)–[`247606933`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247606933).
  FFmpeg build `33450629` succeeded in 28m19s and produced all 29 Published
  binary records, publications
  [`247606934`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247606934)–[`247606962`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247606962).
  Launchpad recorded the complete binary publication set at
  `2026-07-29T10:06:22.212012+00:00`.

## librga TILE-stride publication closure — 2026-07-29

- The previously pending librga
  `2.2.0+git20260725.26a50ef-0ubuntu1~rk1` source publication
  [`18641905`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18641905)
  is Published.
- Its arm64 build
  [`33440960`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33440960)
  succeeded in 6m02s. Both expected binaries are Published:
  `librga-dev` publication
  [`247477790`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247477790)
  and `librga2` publication
  [`247477791`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247477791).
- `apt-cache policy` resolves both exact packages from the normal PPA, and
  `dpkg-query` confirms they are installed on the qualification host.
