# Jellyfin FFmpeg Patch Survey

Date: 2026-07-11

> **2026-07-16 follow-up:** this document surveys Jellyfin's packaging delta and
> generic patch policy at the older pins below. A later pass materialized all 96
> Jellyfin patches at `455bfe539220`, created a real
> `rockchip-8.1.2@53b3551b9176` release replay, and compared the effective source
> trees directly. That local replay has since been replaced by published
> `ffmpeg-81@8d3ca020b6a2`; the generic correctness import and every other
> unique refactor commit are also integrated into canonical `main` and
> `ffmpeg-80`. See
> [`rockchip-812-jellyfin-comparison.md`](rockchip-812-jellyfin-comparison.md)
> for the core line counts, validation/lifecycle differences, Jellyfin-only
> DOVI/`reset_sar`/OpenCL/Vulkan features, API hazards, compile checks, and the
> selective-port recommendation. The newer comparison supersedes the sentence
> "No Jellyfin Rockchip-specific code needed to be imported" for feature parity;
> that sentence remains correct only for the two sync fixes examined here.

## Source Points

| Tree | Pin | Notes |
|------|-----|-------|
| Jellyfin FFmpeg | `172f1454c4bc4dd9a3754e9db024708ef7a83f0c` (`v8.1.2-1`, `origin/jellyfin`) | Local clone: `/home/yi/Code/ffmpeg/jellyfin-ffmpeg`; clean and current with `origin/jellyfin` after fetch. |
| Jellyfin upstream import base | `621dde56` ("New upstream version 8.1.2") | Used as the baseline for Jellyfin's FFmpeg 8.1.2 delta. |
| Our forward port | `75638e7f0b1775193381af0c3187838f6c51dbd1` before this pass | Local clone: `/home/yi/Code/ffmpeg/ffmpeg-rockchip-81`, branch `refactor/section-c`. |
| FFmpeg upstream master check | `6bae3bd` (2026-07-11, `avformat/wavdec: move ID3v2 auto-parsing flag from w64 to wav`) | Temporary clone under `/tmp/ffmpeg-upstream-master`; used only for dry-run compatibility checks. |

Jellyfin's `621dde56..172f1454` delta is mostly package/builder maintenance and
refreshing its Debian patch queue for FFmpeg 8.1.2: 60 files changed, 503
insertions, 1026 deletions.

## Rockchip-Specific Result

Jellyfin's post-8.1.2 Rockchip sync commit is `24bd5c9f`:

- replace `mpp_packet_get_data()` with `mpp_packet_get_pos()`;
- fix RKRGA scale-ratio validation after width/height swapping for 90/270 degree rotation.

Both fixes are already present in our forward-port tree:

- `libavcodec/rkmppenc.c` uses `mpp_packet_get_pos()` for encoder packets and headers;
- `libavfilter/rkrga_common.c` factors rotated-dimension handling through
  `rga_rotates_dimensions()` and swaps the source dimensions before scale-ratio
  validation.

No Jellyfin Rockchip-specific code needed to be imported.

## Patch Policy

### Apply Directly

These are general correctness fixes and are suitable for the system
`ffmpeg-rockchip-81` forward-port, not just Jellyfin's private FFmpeg build.

| Jellyfin patch | Classification | Rationale |
|----------------|----------------|-----------|
| `0001-add-fixes-for-segment-muxer.patch` | correctness | Corrects segment timing when the first reference-stream packet PTS is not zero. |
| `0058-fix-the-sub2video-perf-regressions.patch` | correctness/performance | Avoids pushing subtitle heartbeat frames unless the buffersrc requested one. |
| `0065-fix-ass-incorrect-null-copy.patch` | correctness/safety | Writes only the non-NUL ASS extradata prefix instead of copying embedded/trailing NUL bytes. |
| `0067-fix-auto-inserting-sw-color-conv-filters-between-hw-fmts.patch` | hardware correctness | Prevents automatic software color/range/alpha conversion filters between hardware pixel formats. |
| `0068-fix-dummy-hw-frame-missing-hw-frames-ctx.patch` | hardware correctness | Ensures EOF/dummy hardware frames carry the sink `hw_frames_ctx`. |
| `0074-fix-mapped-hwframe-to-swframe-swscale-conversion.patch` | hardware correctness | Allows mapped hardware frames to be converted as software frames by swscale. |
| `0075-fix-hwupload-filter-cannot-use-devices-created-by-hwaccel.patch` | hardware correctness | Moves hwupload device setup into format query so devices created by hwaccel can be used. |
| `0077-fix-readrate-catchup-caused-remuxing-to-stall.patch` | correctness | Tracks readrate lag at the demuxer level so one stalled stream does not make remux pacing stick. |
| `0087-add-dtsx-detect-for-dts-hd-hra.patch` | metadata correctness | Extends DTS-HD HRA profile reporting for DTS:X / DTS:X IMAX. |
| `0088-add-webp-to-matroskadec-image-mime-types.patch` | metadata correctness | Maps Matroska `image/webp` attachments to `AV_CODEC_ID_WEBP`. |

### Apply Directly With Extra Validation

These are still reasonable to carry in the forward port, but they change media
metadata/container behavior and should be tested with representative samples.

| Jellyfin patch | Classification | Rationale |
|----------------|----------------|-----------|
| `0025-add-multiple-values-tags-and-webp-support-for-id3v2.patch` | metadata behavior | Adds multi-value ID3v2 text tag handling; our tree already has the WebP MIME table entry. |
| `0027-pass-dovi-sidedata-to-hlsenc-and-mpegtsenc.patch` | container correctness | Preserves Dolby Vision configuration side-data through HLS/MPEG-TS muxing after validation. |
| `0052-opus-allow-5point1-side-inputs.patch` | audio interop | Lets libopus accept 5.1(side) input by mapping side channels to back channels. |

### Hold As Sidecar Or Revisit Separately

These should not be folded into the system FFmpeg forward port by default.

| Jellyfin patch | Disposition | Rationale |
|----------------|-------------|-----------|
| `0061-add-remove-dovi-hdr10plus-bsf.patch` | sidecar/manual port | Feature knobs for removing Dolby Vision/HDR10+ metadata; useful but not a correctness fix. Conflicts with current upstream/our tree. |
| `0089-relax-to-allow-safe-filenames-in-mkv-attachments.patch` | sidecar/security policy | Changes attachment filename acceptance and failure behavior. Keep strict system-default behavior unless a consumer needs this. |
| `0028-add-pause-support-for-ffmpeg-cli.patch` | sidecar | Interactive operator feature, not distro/system correctness. |
| `0066-add-first-vframe-only-to-ffprobe.patch` | sidecar | Jellyfin probing optimization, not general FFmpeg behavior. |
| `0054-add-ac4-decoder-for-atsc-3-0.patch` | licensing/feature review | Large Librempeg-derived GPLv3 decoder/parser import. Our tree already identifies AC-4 streams in MPEG-TS but does not decode them. |

## Upstream Compatibility Check

Dry-run `git apply --check -p1` against FFmpeg upstream master `6bae3bd`:

- Applies cleanly upstream and to our tree: `0001`, `0025`, `0027`, `0052`,
  `0054`, `0058`, `0065`, `0067`, `0068`, `0070`, `0074`, `0075`, `0087`,
  `0088`, `0089`.
- Conflicts/diverges upstream: `0061`, `0077`.
- Already present or equivalent in our tree from the prior scan: AC-4 MPEG-TS
  stream identification and the codec-parameter `sw_pix_fmt` fix.

Mechanically applying upstream does not mean the patch is upstream-ready:
Jellyfin-specific CLI/probing behavior, relaxed filename policy, and GPLv3
Librempeg imports still need separate policy decisions.

## Application Result

Applied to `/home/yi/Code/ffmpeg/ffmpeg-rockchip-81` on branch
`refactor/section-c` on top of `75638e7f0b1775193381af0c3187838f6c51dbd1`:

- `0001-add-fixes-for-segment-muxer.patch`
- `0025-add-multiple-values-tags-and-webp-support-for-id3v2.patch`
- `0027-pass-dovi-sidedata-to-hlsenc-and-mpegtsenc.patch`
- `0052-opus-allow-5point1-side-inputs.patch`
- `0058-fix-the-sub2video-perf-regressions.patch`
- `0065-fix-ass-incorrect-null-copy.patch`
- `0067-fix-auto-inserting-sw-color-conv-filters-between-hw-fmts.patch`
- `0068-fix-dummy-hw-frame-missing-hw-frames-ctx.patch`
- `0074-fix-mapped-hwframe-to-swframe-swscale-conversion.patch`
- `0075-fix-hwupload-filter-cannot-use-devices-created-by-hwaccel.patch`
- `0077-fix-readrate-catchup-caused-remuxing-to-stall.patch`
- `0087-add-dtsx-detect-for-dts-hd-hra.patch`
- `0088-add-webp-to-matroskadec-image-mime-types.patch`

Validation after applying:

- `git diff --check` passed.
- Rebuilt `ffmpeg` and `ffprobe` with the existing configured tree:
  `make -C /home/yi/Code/ffmpeg/ffmpeg-rockchip-81 -j$(nproc) ffmpeg ffprobe`
  passed.
- Rebuilt binaries start, report the expected RKMPP codecs and RKRGA filters,
  and a small `lavfi` test source to null muxer pipeline succeeds.
- Runtime startup still prints `mpp_platform: client 12 driver is not ready`;
  this matches the previously recorded installed-MPP/runtime-selection issue and
  is not introduced by the Jellyfin patch import.
- `make ... fate-filter-overlay-dvdsub-2397` was attempted because the sub2video
  reference changed, but that target requires external FFmpeg samples and the
  local tree has no `SAMPLES` path configured.

The external `ffmpeg-rockchip-81` patch import was originally committed as
`214772cbdb86374dd70470e2df2801da3ded4224` on `refactor/section-c`. Its unique
work is now part of all three published canonical branches:
`main@8b57e531d1fc`, `ffmpeg-80@be753f3bbb2c`, and
`ffmpeg-81@8d3ca020b6a2`. The YSP PPA export metadata still targets the earlier
packaged commit until a separate versioned source-package pass retargets
`FFMPEG_COMMIT`, updates version metadata, and generates a new changelog entry.
