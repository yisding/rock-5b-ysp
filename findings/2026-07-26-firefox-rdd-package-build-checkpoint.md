# Firefox 152.0.6 Rockchip RDD package build is configured but paused

> Scope: native arm64 build of Ubuntu Resolute's Firefox 152.0.6 package with
> the pinned Rockchip RDD sandbox patch from `rockchip-vaapi@03e6cb6`.
>
> Source: Ubuntu source package
> `152.0.6+build1-0ubuntu0.26.04.1~mt1`, local build workspace
> `~/Code/firefox-rdd-build`, and retained configure/build logs under its
> `artifacts/` directory.
>
> Date: 2026-07-26.
>
> Trust: **SOURCE-INSPECTED / CONFIG-INSPECTED / PARTIAL**.

## Result

The distribution package build advanced past source preparation, Rockchip
patch application, tool bootstrap, Mozilla configure, and build-backend
generation. The full compile was stopped on request after 31 minutes while
Cargo was compiling `toolkit/library`; it did not stop on a compiler error.
No Firefox binary package was produced, installed, or runtime-tested, so the
RDD browser gate remains open.

The local package version is
`152.0.6+build1-0ubuntu0.26.04.1~mt1+ysp1`. Its Debian patch series includes
`rockchip-rdd-vaapi.patch`, copied from the source-hash-pinned patch in
`rockchip-vaapi@03e6cb6`. The original source inputs retained beside the
unpacked tree are:

```text
firefox_152.0.6+build1-0ubuntu0.26.04.1~mt1.dsc
firefox_152.0.6+build1-0ubuntu0.26.04.1~mt1.debian.tar.xz
firefox_152.0.6+build1.orig.tar.xz
```

The `.dsc` SHA-256 is
`2ba6f650f3f862bdcc61e7953fce8131b3673c290ad3c6b50922bf3486307708`;
the Debian tarball SHA-256 is
`473e8801a117009d9db37445f4fc35bb7096cf38ed98b104807f014af82c8224`.

## Rootless build contract

Resolute's Firefox packaging expects a versioned toolchain that was not fully
installed on this login. The build was kept rootless by extracting required
packages under `~/Code/firefox-rdd-build/deps/root` and pointing the generated
`mozconfig` at those tools. The working contract was:

- Firefox's compatibility CDBS package
  `0.4.182+really0.4.181~mt1`, matching the source package's build environment;
- Rust/Cargo `1.93.1` from Resolute's `rustc-1.93`, `cargo-1.93`, and matching
  standard-library packages;
- Clang/Clang++ 21.1.8 and LLD 21, with LLVM 22 utilities selected by
  configure where available;
- private `libclang-21-dev` plus `libclang1-21`, with
  `--with-libclang-path` targeting the extracted LLVM 21 library directory;
- source-built `cbindgen 0.29.4` and `dump_syms 2.3.7` at the paths expected by
  the generated Ubuntu `mozconfig`;
- `/usr/bin/pkg-config`, not Homebrew's pkg-config, and `MOZ_MAKE_FLAGS=-j4`.

Two configure failures are worth preserving because their diagnostics are
easy to misread. With no private libclang, configure correctly reported that
libclang was absent. After only the development package was extracted, its
`libclang.so` target was missing and configure misleadingly called the library
"too old". Extracting the matching runtime package resolved the symlink and
the final configure accepted libclang 21.

The final configure generated 19,970 build descriptors. The final
`mach format` gate reported `0 problems (0 errors, 0 warnings, 0 fixed)`.
Source-built helper binaries and the incremental object tree remain in the
workspace for a later resume.

## Paused compile and estimate boundary

`artifacts/mach-build.log` records `/usr/bin/gmake -f client.mk -j4 -s` running
for 31:03. At the stop point it was still compiling Rust dependencies and
reported `Interrupt` through `force-cargo-library-build`; the accompanying
resource-monitor `KeyboardInterrupt` is a consequence of the requested stop,
not evidence of a Firefox defect. The log had accumulated 77 compiler warnings
but no terminal compile failure.

The estimate made at the stop point was approximately five to six additional
hours on this host. That was a throughput estimate from the observed milestone
relative to the distribution build, not a reproducible build-time guarantee.
Incremental state should shorten a resume, but package completion, tests,
installation, and live playback still have unknown duration.

## Remaining proof

Resume the preserved build rather than re-extracting the source. A completed
result still must pass all of these gates before the Firefox policy can be
called runtime-validated:

1. produce the expected arm64 Debian packages and inspect their patch/version
   provenance;
2. install them without weakening or globally disabling the RDD sandbox;
3. run in a real Wayland or X11 session with `MOZ_DISABLE_RDD_SANDBOX` unset;
4. prove hardware decode through MPP/RGA and surface export;
5. confirm the RDD process remains sandboxed and no additional denied path or
   ioctl request appears.

This checkpoint does not change the P010 verdict. The paired 6.18.40 kernel
and current librga are hardware-validated for the measured 10-bit conversion
paths, while Firefox application integration remains unfinished.
