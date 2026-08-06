# FFmpeg Rockchip validation scorecard

This page owns accumulated FFmpeg/RKMPP/RKRGA validation conclusions and the
boundary between evidence classes. It does not own moving branch heads
([W07](../../../status.md#watch-w07)), Ubuntu-version drift
([W04](../../../status.md#watch-w04)), publication
([W05](../../../status.md#watch-w05)), or the public verdict/next proof
([status track 5](../../../status.md)).

## Evidence ladder

| Class | What a pass establishes | What it does not establish |
|-------|-------------------------|----------------------------|
| Source/replay | Patch lineage and intended code are reconstructable at an immutable pin | The pin still matches a moving branch |
| Compile/source checks | Enabled objects compile and `fate-source` passes | Codec hardware, ABI pairing, or application behavior |
| Registration | Expected codecs, hwdevices, pixel formats, and filters enumerate | A packet or frame crossed hardware |
| Focused hardware | A named RKMPP/RKRGA path ran with hardware markers and bounded output | Installed-package identity or application integration |
| Package artifact | Debian metadata/payload and lifecycle are verified | The board/app selected that exact artifact |
| Installed runtime | The intended package and MPP/RGA ABI pair run focused gates | GRD/Kodi/container behavior not exercised by those gates |
| Application integration | A real consumer passes its timeout, fallback, recreation, container, or display contract | Other consumers or formats |

Do not transfer a result upward merely because codec names or version strings
match. In particular, a same-version local package and PPA binary are distinct
artifacts until metadata/payload identity and replay prove otherwise.

## Accumulated evidence

| Evidence point | Trust and signal | Durable conclusion | Boundary / successor |
|----------------|------------------|--------------------|----------------------|
| `40c412dacc` fork snapshot | Source-inspected and hardware-used | Full RKMPP decode/encode plus RKRGA pipeline model is reconstructable | Historical build recipe, not a moving-tip claim |
| `def08a047f..6cf02ab253` review series | Source replay plus exported 28-patch set | Fourteen fix groups and public code-review lessons survive independently of branch movement | [Patch owner](../patches/README.md), [fix groups](fix-candidates.md) |
| Recorded three-line replay (2026-07-16 pins) | All enabled affected objects compiled; `fate-source` passed | Master, 8.0, and 8.1 adaptations were source-valid at recorded commits | W07 marks later moved heads stale until replayed |
| `75638e7f0b17` package audit | Measured package build, registration, encode, upload/RGA/encode, and H.264 decode with matching source MPP | FFmpeg path was sound; the installed MPP mismatch, device namespace, command shape, and demo ABI were independent failure classes | [Frozen audit](rockchip81-package-validation.md) |
| Local FFmpeg baseline package audit | Source-package build and package-policy checks | Packaging-specific build correction is reproducible | [Dated finding](../../../findings/2026-07-09-ffmpeg-baseline-rk2-local-build-validation.md) |
| Asynchronous frame-lifetime repair | Source analysis, focused immediate-close and flush/reuse hardware loops | Encoder reset/close no longer double-releases a frame on the exercised fix | [Maintained finding](../../../findings/2026-07-30-ffmpeg-rkmpp-async-frame-lifetime-fix.md) owns exact pin, commands, counts, and app gate |

## Durable failure classifications

- A sandbox without the real MPP/RGA/DMA-heap/DRM namespace cannot produce a
  hardware verdict.
- An FFmpeg binary and MPP demo must load the MPP library matching the source
  they were built against; an unversioned SONAME match is insufficient.
- `scale_rkrga` consumes DRM PRIME hardware frames. Software input needs an
  explicit compatible hwdevice, format, and upload step.
- Source compilation and `fate-source` cannot carry forward after a branch
  moves; rerun on the returned W07 head.
- Registration proves discovery only. Require hardware markers and bounded
  output for a codec result.
- Immediate-close/flush loops prove the frame-lifetime fix directly; GRD
  timeout/fallback/recreation and AV1 MP4/MKV exercise different boundaries.

## Canonical operations

| Goal | Route |
|------|-------|
| Build the immutable historical fork snapshot | [Project build recipe](../README.md#build-mpp-the-first-input) |
| Replay onto a newer FFmpeg line | [Rebase method](rebase-notes.md#2-the-replay-method) |
| Apply/audit the public review fixes | [Patch series](../patches/README.md), [fix candidates](fix-candidates.md) |
| Run generic hardware transcode | [Project verification](../README.md#verify-transcode), [kernel test owner](../../../kernel-drivers/tests/README.md) |
| Reproduce the dated package audit | [Package audit](rockchip81-package-validation.md) |
| Act on the current public gate | [Status track 5](../../../status.md#next-gates) |

## Freshness contract

Recheck W04 before changing distro replacement policy, W07 before reusing a
branch result, W05 before install/publication claims, and artifact metadata
before equating local and PPA packages. Update this scorecard only when a new
result changes a durable conclusion or evidence boundary; keep run detail in a
finding until promotion.
