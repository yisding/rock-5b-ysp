# ubuntu-rock-5b PPA upload log

> Scope: build and upload the userspace stack to `ppa:yi-ding/ubuntu-rock-5b`.
> Initial wave: `mpp`, `librga`, and `ffmpeg`.
> Source inputs:
>
> - `/home/yi/Code/rockchip-userspace/mpp-rockchip`
> - `/home/yi/Code/rockchip-userspace/librga-fork`
> - `/home/yi/Code/ffmpeg/ffmpeg-rockchip-81`
>
> Target series: `resolute` (Ubuntu 26.04 / Armbian 26.5.1 userspace).
> Target architecture: source upload to Launchpad; expected binary build is
> `arm64`.
> Date opened: 2026-07-06.

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
  - Requested source `/home/yi/Code/ffmpeg/ffmpeg-rockchip-81` reports
    `RELEASE=8.0.git` but library majors `libavcodec63`, `libavutil61`,
    `libavformat63`, `libavfilter12`, `libswscale10`, and `libswresample7`.
  - The older local Ubuntu packaging in `/home/yi/Code/ffmpeg/ffmpeg-ppa`
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
  - repository: `/home/yi/Code/rockchip-userspace/librga-fork`
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
  - repository: `/home/yi/Code/ffmpeg/ffmpeg-rockchip-81`
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
  `/home/yi/Code/gnome/grd/grd-ppa/ffmpeg_8.1.2-1+rk1_source.changes`.
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

## gnome-remote-desktop / grd-ffmpeg packaging prep

- Confirmed the requested GRD source tree is
  `/home/yi/Code/gnome/grd/grd-ffmpeg`, branch
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
  `/home/yi/Code/gnome/grd/grd-pkg/gnome-remote-desktop-50.1+rkmpp/debian`,
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
    `/home/yi/Code/gnome/grd/grd-ppa/ffmpeg_8.1.2-1+rk1_source.changes`,
    bump it to `7:8.1.2-1+rk2` (still sorts below the forward-port
    version), rebuild the source package, re-sign, and `dput`;
  - rebuild and re-sign the forward-port source package from the updated
    `debian/` in this repo before its (still held) upload.

## Baseline packaging recovered from Launchpad and checked in

- The upstream-baseline `7:8.1.2-1+rk1` `debian/` tree was never in git; it
  existed only at `/home/yi/Code/gnome/grd/grd-ppa/` on the board. A GitHub
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
