# HEVC NUT failures split into MPP RADL suppression and FFmpeg unused-RPS handling

> Scope: `rockchip-vaapi` HEVC Main conformance on RK3588, its
> `librockchip_mpp` dependency, and the YSP FFmpeg 8.0/8.1 source lines;
> support-coverage row C15.
> Source: byte-identical FFmpeg FATE samples `NUT_A_ericsson_4.bit` and
> `NUT_A_ericsson_5.bit`, SHA-256
> `d87dcae6353a680ff1c816395b578afae3ed9f1a88b56b07a24e62333e0621b7`;
> `yisding/mpp@ysp/main@d8c6b88a2211d08a4427abd3c5e8275905a934f5`
> (`mpp/codec/dec/h265/h265d_flow.c`, `h265d_nal_unit()` near the
> `max_ra` gate), fixed by `3381fd2c`; FFmpeg upstream fix
> `265d39e551956d911a0c1c52bff5186a6bae660e`, backported as
> `ffmpeg-80@ab675f19cf`, `ffmpeg-81@629f4968d2`, and the current package line
> `fix/rkmpp-output-timeout@33a651a55b`.
> Date: 2026-07-29
> Trust: **MEASURED** / **CODE-INSPECTED** / **CONFIRMED** /
> **ROOT-CAUSED** / **BOARD-REPRODUCED** / **FIX-COMPILE-VERIFIED** /
> **FIX-RUNTIME-VERIFIED**

## Result

The two names do not represent two different streams: both files are 302,142
bytes and byte-identical. The stream contains 36 VCL access units, of which two
RASL pictures are correctly suppressed at random access. A conformant decoder
therefore outputs 34 pictures.

Two independent decoder bugs obscured that result:

- MPP decoded only 27 pictures because `h265d_nal_unit()` suppressed every
  non-IRAP picture whose POC was below `max_ra`. That condition includes valid
  RADL pictures as well as RASL pictures.
- The YSP FFmpeg 8.0/8.1 lines decoded only 32 pictures without
  `-flags output_corrupt` because `add_candidate_ref()` rejected unavailable
  pictures even in the unused `ST_FOLL` and `LT_FOLL` reference sets.

MPP commit `3381fd2c` keeps the existing RASL test and removes the broader
non-IRAP/POC test. The rebuilt library returns all 34 pictures for both sample
names with zero error or discard flags and EOS.

The FFmpeg fix is the exact upstream commit `265d39e551`:
`ST_FOLL`/`LT_FOLL` entries are always generated when unavailable, as required
by HEVC section 8.3.3, while missing references in the current sets retain the
existing corruption policy. Upstream `main` already contains that commit. It
was backported to YSP's maintained 8.0, 8.1, and current 8.0 package branches.

## Root cause

### MPP: RADL was treated as RASL

For a BLA or CRA picture, MPP records the random-access picture POC in
`p->max_ra`. The parser already had the required test:

```c
if ((type == NAL_RASL_R || type == NAL_RASL_N) &&
    p->poc <= p->max_ra)
    /* do not decode */
```

It then applied a second test to every non-IRAP NAL when error handling was
enabled:

```c
if (p->poc < p->max_ra && !IS_IRAP(type))
    /* do not decode */
```

Leading-picture POC order does not identify whether a picture is decodable.
RADL pictures precede their associated IRAP picture in output order but are
decodable; RASL pictures are the pictures excluded by the random-access rule.
The second test dropped seven valid RADL pictures:

- POC 200, 190, and 210 around BLA POC 220;
- POC 34 and 44 around BLA POC 54; and
- POC 124 and 134 around BLA POC 144.

It also dropped RASL POC 24 and 14, but those two suppressions were already
covered by the explicit RASL test. Setting MPP's global `base:disable_error`
option made the stream produce 34 frames, which isolated the second branch,
but that option is not a fix because it disables unrelated decoder error
handling.

### FFmpeg: unused RPS entries were made fatal

FFmpeg commit `bc1a3bfd2cbc` made unavailable or corrupt references fatal
unless corrupt output is requested. The check was applied uniformly to all RPS
lists. HEVC section 8.3.3 instead requires unavailable following pictures in
`ST_FOLL` and `LT_FOLL` to be generated even though they are not used by the
current picture.

On this stream, the pre-fix default decode reported missing POCs and aborted two
pictures, yielding 32 frames. The FATE rule masked the issue by applying
`-flags output_corrupt` to every HEVC conformance test. Upstream commit
`265d39e551` passes the RPS list index into `add_candidate_ref()`, exempts
`ST_FOLL` and `LT_FOLL` from the fatal corruption check, and removes the global
FATE workaround. Its commit message names `NUT_A_ericsson_5` and
`RPS_D_ericsson_6` as the fixed tests.

## Evidence and reproduction

- **Board:** Radxa ROCK 5B / RK3588, production-shaped
  `6.18.40-ysp-rockchip64` kernel.
- **MPP baseline:** direct `tests/hevc_mpp_repro` against
  `mpp@d8c6b88a` accepted the packet and EOS but returned 27 clean frames.
- **Controlled MPP test:** enabling only `base:disable_error` returned 34 clean
  frames, proving that the broad recovery gate was causal.
- **MPP fix build:** the existing native CMake/Ninja tree rebuilt
  `h265d_flow.c`, `librockchip_mpp.so.0`, and the static library successfully at
  source commit `3381fd2c`.
- **MPP fixed runtime:** both sample names report:

  ```text
  RESULT status=clean frames=34 expected=34 bad_frames=0 info_changes=1 eos=1 api_status=0
  ```

- **FFmpeg baseline:** the installed YSP-derived FFmpeg 8.0.3 and a separate
  FFmpeg 8.1.2 build each returned 32 frames under the default software HEVC
  decoder.
- **FFmpeg fix build:** a minimal native build from `ffmpeg-80@ab675f19cf`
  completed with the HEVC decoder, rawvideo encoder, HEVC demuxer/parser,
  framecrc muxer, file protocol, and scale filter enabled.
- **FFmpeg fixed runtime:** default decode, without `output_corrupt`, returned
  34 frames for each name. The two framecrc outputs are identical. After
  removing the generated `#software` header, the output is byte-identical to
  `tests/ref/fate/hevc-conformance-NUT_A_ericsson_5`.

The decisive MPP commands used the rebuilt library through the direct runner:

```bash
cd ../rockchip-vaapi

"$ROCK5B_WORKSPACE/build/vaapi/hevc-probe/hevc_mpp_repro.d8c6b88a" \
  tests/vectors/hevc-sweep/NUT_A_ericsson_4.bit 34
"$ROCK5B_WORKSPACE/build/vaapi/hevc-probe/hevc_mpp_repro.d8c6b88a" \
  tests/vectors/hevc-sweep/NUT_A_ericsson_5.bit 34
```

The FFmpeg check used the default software decoder and no corruption flag:

```bash
ffmpeg -v error -i NUT_A_ericsson_5.bit \
  -pix_fmt yuv420p -f framecrc nut5.framecrc
```

## Fix

MPP now suppresses only `NAL_RASL_R` and `NAL_RASL_N` pictures at or below the
random-access POC. The later `NAL_RASL_R` state transition is unchanged. RADL,
TRAIL, TSA, and STSA pictures no longer become collateral damage merely because
their POC is lower than the associated IRAP picture.

FFmpeg's backport preserves upstream authorship and the exact two-file change:

- `libavcodec/hevc/refs.c` distinguishes current references from
  `ST_FOLL`/`LT_FOLL`; and
- `tests/fate/hevc.mak` stops forcing `output_corrupt` for the complete HEVC
  conformance group.

## Packaging checkpoint

The YSP package pins now export MPP as
`1.5.0+git20260729.3381fd2c+ds-0ubuntu1~rk1` and FFmpeg as
`7:8.0.3+rockchip+git20260729.33a651a55b-0ubuntu1~rk1`. Both source packages
build and pass `dscverify`. MPP additionally completes its native arm64 binary
package build, produces all five expected packages, and passes Lintian's error
gate; the runtime deb SHA-256 is
`5dbced58b1ed76ec5103bdd766e4b3d838539364321a685a687c4e372312a7f2`.
Launchpad's FFmpeg arm64 build also completes successfully.

Both signed source packages were uploaded to
`ppa:yi-ding/ubuntu-rock-5b` and accepted by Launchpad. MPP source publication
[`18647958`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18647958)
dispatched arm64 build
[`33450621`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33450621);
FFmpeg source publication
[`18647960`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+sourcepub/18647960)
dispatched arm64 build
[`33450629`](https://launchpad.net/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+build/33450629).
Both sources are Published. MPP build `33450621` succeeded in 12m53s and all
five arm64 binary publications
[`247606929`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247606929)–[`247606933`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247606933)
are Published. FFmpeg build `33450629` succeeded in 28m19s and all 29 binary
publications
[`247606934`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247606934)–[`247606962`](https://api.launchpad.net/devel/~yi-ding/+archive/ubuntu/ubuntu-rock-5b/+binarypub/247606962)
are Published. Launchpad recorded the binary publication set at
2026-07-29 10:06:22 UTC.

The exact live-PPA runtime packages were then downloaded from the archive,
checked against the SHA-256 values in its `Packages.xz`, and extracted into an
isolated root. Loader inspection proved that the staged FFmpeg executable,
FFmpeg libraries, direct-MPP reproducer, and source-built
`rockchip_drv_video.so` all resolved the extracted `librockchip_mpp.so.1`
rather than the installed older library. On that exact package pair the
complete 163-candidate HEVC Main sweep reports:

```text
candidates=163 skipped=17 backend-failed=0 unsupported=2 driver-failed=0 bit-exact=144
ALL PINNED CLASSES MATCH
```

Both NUT aliases are among the 144 byte-exact results. The report SHA-256 is
`39c68fdf82773fb9bde47dbcde74abc3ea49271905b203aad1a1c81f1452cf89`;
the manifest-row SHA-256 is
`c2130ec492d8cdd05074454e2dd294107953012dbe152ae4e4f353668fea5671`.
The normal and complete ASan/UBSan-driver shipping-profile matrices also pass
on the exact package root, including the audited VP9 show-existing vector,
H.264 reference/B-frame matrix, 4K, five-run VP9 determinism, and VP8
fallback.

## Boundary

The fixes are published and their exact archive binaries pass the complete VA
sweep, but they are not yet installed through the host package manager.
System installation and an installed-payload identity/runtime confirmation
remain lifecycle gates; they are no longer correctness prerequisites for this
finding's fixed-package sweep result.

MPP still logs unavailable POCs for this stream. Those entries are in unused
RPS sets and are represented by reference-only placeholders; they do not set
frame error/discard flags or prevent the 34-frame result. This finding does not
claim that all missing-reference diagnostics are harmless.
