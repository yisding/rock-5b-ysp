# FFmpeg baseline `-1+rk2` local source-package build validates frei0r fix

> Scope: `packaging/ppa/ffmpeg-baseline` / Launchpad `ffmpeg 7:8.1.2-1+rk2`
> Source: local regenerated `.dsc` build from `ffmpeg_8.1.2.orig.tar.xz` sha256 `464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c` + [`packaging/ppa/ffmpeg-baseline/debian`](../packaging/ppa/ffmpeg-baseline/debian/changelog); binary build log at `downloads/ffmpeg-rk2-dsc-build-20260709-074722/ffmpeg-rk2-dsc-binary-build.log`
> Date: 2026-07-09
> Trust: MEASURED

## The fact

The `7:8.1.2-1+rk2` baseline packaging locally rebuilt successfully on the
ROCK 5B from a regenerated source package, then a fresh `dpkg-source -x` of that
`.dsc`:

- `dpkg-buildpackage -B -us -uc -d` completed successfully on arm64.
- The FATE source check ran and passed: `TEST source`.
- The two tests that failed in Launchpad build `33366878` ran and passed:
  `TEST filter-frei0r-filter` and
  `TEST filter-frei0r-filter-unaligned`.
- The log contains no `Could not find module 'distort0r'` failure.
- The build emitted 32 `.deb` / `.ddeb` binary artifacts plus
  `ffmpeg_8.1.2-1+rk2_arm64.{buildinfo,changes}` under
  `downloads/ffmpeg-rk2-dsc-build-20260709-074722/rebuild/`.
- The built standard binary reports `ffmpeg version 8.1.2-1+rk2`, includes
  `--enable-rkmpp --enable-frei0r`, exposes `h264_rkmpp` and `hevc_rkmpp`
  encoders, and exposes `h264_rkmpp`, `hevc_rkmpp`, `vp8_rkmpp`, and
  `vp9_rkmpp` decoders.

This is strong validation that adding
`frei0r-plugins <!nocheck !pkg.ffmpeg.stage1>` to `Build-Depends` fixes the
runtime plugin side of the FFmpeg 8.1 frei0r FATE tests, because `distort0r.so`
is provided by the runtime package, not by `frei0r-plugins-dev`.

## Reproduction caveats

This was source-package accurate, not a byte-for-byte Launchpad chroot
replica. The build ran on the live Armbian/Ubuntu `resolute` arm64 host, not in
a clean Launchpad-style `sbuild` chroot. Because `frei0r-plugins` is not
installed on the host, the package was extracted locally and the build was run
with:

```bash
FREI0R_PATH=/home/yi/Code/rock-5b-ysp/downloads/ffmpeg-rk2-local-build/frei0r-root/usr/lib/aarch64-linux-gnu/frei0r-1
```

That models the fixed runtime availability for FATE, but a true Launchpad
replica would install `frei0r-plugins` through apt inside a clean chroot.

When building inside this repository's `downloads/` directory, set
`GIT_CEILING_DIRECTORIES` to the per-build workspace. Without that guard,
upstream `tests/fate/source-check.sh` can discover the enclosing
`rock-5b-ysp/.git` repository, run `git grep` against the wrong tree, and report
a bogus `fate-source` failure. Building from the extracted `.dsc` with
`GIT_CEILING_DIRECTORIES=$WORK` made `fate-source` behave as expected.

## Why it matters / follow-up

Launchpad build `33381225` was still queued when this was checked; the local
result removes the most likely package-level concern for the `-1+rk2` retry.
If that Launchpad build fails anyway, inspect the Launchpad log for a new
chroot-specific issue rather than re-investigating the original missing
`distort0r.so` failure first.
