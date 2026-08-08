# Build PPA source packages

This runbook selects intended source inputs, creates unsigned Debian source
packages, and records the boundaries that matter before publication. The
executable defaults in [`build-source-packages.sh`](../build-source-packages.sh)
are canonical; this page explains how to operate them without copying mutable
pins into prose.

## Source inputs

| Input family | Variables or fixed inputs |
|--------------|---------------------------|
| Workspace layout | `ROCK5B_WORKSPACE`, `WORKSPACE_ROOT`, `OUT` |
| MPP | `MPP_REPO`, `MPP_COMMIT`, `MPP_UPSTREAM_VERSION` |
| librga | `LIBRGA_REPO`, `LIBRGA_COMMIT`, `LIBRGA_UPSTREAM_VERSION` |
| System FFmpeg | `FFMPEG_REPO`, `FFMPEG_COMMIT`, `FFMPEG_UPSTREAM_VERSION` |
| Co-installable FFmpeg tool | `FFMPEG_ROCKCHIP_REPO`, `FFMPEG_ROCKCHIP_COMMIT`, `FFMPEG_ROCKCHIP_UPSTREAM_VERSION` |
| GNOME Remote Desktop | `GRD_REPO`, `GRD_COMMIT`, `GRD_UPSTREAM_VERSION`; `GRD_DELTA` is historical reconstruction only |
| Forward-port and sg-guard kernels | `KERNEL_PPA_*`, `KERNEL_SGGUARD_*`, and their checked-in configs |
| Rewrite kernels | Matching `KERNEL_ALPHA_*` source, repository, commit, version, and checked-in config inputs |
| Native rule packages | `CODEC_UDEV_*`, `GDM_HWENC_*`, and their canonical checked-in rule files |

Override a repository, commit, and upstream version as one provenance tuple.
Do not advance librga independently of the kernel stride convention it targets,
and do not change a kernel source name or version without reviewing
co-installability and upgrade behavior. A source-build retry for the same
upstream version must reuse the accepted orig tarball byte-for-byte.

## Build the sources

Build the default userspace dependency chain:

```bash
bash packaging/ppa/build-source-packages.sh
```

Build selected targets by passing their names, for example:

```bash
bash packaging/ppa/build-source-packages.sh mpp librga ffmpeg
bash packaging/ppa/build-source-packages.sh ffmpeg-rockchip gnome-remote-desktop
bash packaging/ppa/build-source-packages.sh plymouth gdm-hwenc
bash kernel-drivers/scripts/build-kernel.sh ppa-forward-port
bash packaging/ppa/build-source-packages.sh kernel-alpha-6.18 kernel-alpha-7.2-rc3
```

The forward-port wrapper routes through the separate `armbian-build-ppa` Git
worktree, then stages and verifies its dedicated source-only kernel lane before
exporting it. Its mutable Armbian inputs and lock are independent from a local
compile. Use `build-source-packages.sh kernel` directly only to rebuild from an
already-staged lane.

For native Debian builds, keep the system toolchain first so Meson sees Ubuntu
multiarch metadata:

```bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  OUT=../rock-5b/build/ppa-source \
  bash packaging/ppa/build-source-packages.sh mpp
```

The helper exports clean pinned commits for normal userspace sources, overlays
the checked-in packaging, and writes artifacts beneath `OUT/artifacts/`. It
reuses an existing orig tarball unless `FORCE_ORIG=1`; before reuse it extracts
the tarball and rejects a content mismatch. GRD's maintained path exports a
clean commit without `GRD_DELTA`. The native rule packages have no orig
tarball.

The forward-port kernel target is intentionally outside the default set. It
exports the patched Armbian worktree, including its deliberate tracked delta,
and applies provenance guards because `git archive` cannot represent that
source state. Each rewrite target instead archives its explicit commit and
checked-in package config. Their project READMEs own qualification results.

Generated `.dsc`, `.changes`, `.buildinfo`, orig tarballs, binary packages, and
build trees are ignored under `packaging/ppa/out/` by default. Set `OUT` to a
task-specific directory under `../rock-5b/build/` when output should live
outside the checkout.

Continue with the [publication runbook](publishing.md) after the unsigned
source package and its provenance checks pass.

## Reproduce the frozen FFmpeg 8.1 packages

The maintained `ffmpeg` target builds the normal system ABI. The upstream 8.1
comparison recipe remains in
[`ffmpeg-baseline/`](../ffmpeg-baseline/README.md). The exact helper and Debian
packaging for the historical Rockchip 8.1 source are frozen at repository
commit `8522426`.

Use a detached worktree so reconstruction does not replace current packaging:

```bash
git worktree add --detach ../rock-5b/build/ffmpeg81-packaging 8522426
FFMPEG_REPO=/path/to/ffmpeg-rockchip-81 \
OUT=../rock-5b/build/ffmpeg81-source \
  bash ../rock-5b/build/ffmpeg81-packaging/packaging/ppa/build-source-packages.sh ffmpeg
git worktree remove ../rock-5b/build/ffmpeg81-packaging
```

The snapshot itself owns its source commit, version, and ABI package names.
For a Debian-revision retry, obtain and reuse the accepted orig tarball; that
older helper predates the current automatic source-tree comparison.

<a id="ffmpeg81-package-lessons"></a>
### Frozen FFmpeg 8.1 package lessons

The historical forward-port package needed three mechanical corrections before
its full local arch+indep build, FATE run, and Launchpad arm64 build passed:

- drop the RKMPP decoder's static `pix_fmts` metadata because
  `libavcodec-avcodec` rejects it for a hardware decoder; the separate DRM
  PRIME `AVCodecHWConfig` used by Kodi remains intact;
- stop installing the absent upstream `RELEASE_NOTES` file; and
- publish the generated Doxygen `ffmpeg-doc` payload as `Architecture: all`,
  because it is built in the architecture-independent pass.

These are reconstruction rules for that frozen FFmpeg 8.1 package, not current
branch or archive state. The
[FFmpeg validation scorecard](../../../video-libraries/ffmpeg/docs/validation.md)
owns the evidence classification, and the
[Kodi decoder analysis](../../../apps/kodi/docs/decoder-selection.md) owns why
the metadata change does not alter decoder selection.
