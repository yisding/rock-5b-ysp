# ffmpeg/patches/ — exported RKMPP/RKRGA review-fix series

The 28 `git format-patch` files in this directory are the actual diffs behind
the fix work described in [`video-libraries/ffmpeg/docs/fix-candidates.md`](../docs/fix-candidates.md)
(the 14 originally-audited groups). They exist so the fixes survive
independently of the dev box and of any maintained fork: that doc is the *why*,
this directory is the *what*.

## Provenance

Exported 2026-07-02 with `git format-patch --base=def08a047f def08a047f..main`
from the working clone of **`github.com/yisding/ffmpeg-rockchip-81`** (branch
`main`, tip `6cf02ab253`, in sync with `origin/main` at export time; replaces
the 2026-07-01 nine-patch export of the same series' first commits). Tree
topology, pins, and replay method:
[`video-libraries/ffmpeg/docs/rebase-notes.md`](../docs/rebase-notes.md).

The series applies on top of:

| Layer | Commit | What it is |
|-------|--------|------------|
| Direct base (in the `base-commit:` trailer of each patch) | `def08a047f` | `avcodec/rkmpp: port Rockchip stack to current FFmpeg` — the final port commit of the fork replay. |
| Underneath that | 31 replayed nyanmisaka fork commits + removal commit `6fb4d1cd37` | The full RKMPP/RKRGA feature stack. |
| Bottom | FFmpeg master `87bd15dc3c` (2026-06-26) | The rebase base (see [`video-libraries/ffmpeg/docs/rebase-notes.md`](../docs/rebase-notes.md) §1 for how it relates to `n8.1.2`). |

This is a **reference export pinned to a specific base, not a maintained
fork**. It will not apply cleanly to arbitrary future FFmpeg or
ffmpeg-rockchip trees; backport by behavior (per fix group, using
[`video-libraries/ffmpeg/docs/fix-candidates.md`](../docs/fix-candidates.md)) in that case. The older
`origin/nyanmisaka` branch in particular predates current FFmpeg internals, so
its equivalents have to be ported by behavior rather than cherry-picked.

## Patch ↔ FIX-CANDIDATES group map

Group numbers are the `## N.` section numbers in
[`video-libraries/ffmpeg/docs/fix-candidates.md`](../docs/fix-candidates.md). Most commits fix several
groups at once (they were review sweeps, not per-topic patches).

| Patch | Commit | Subject | FIX-CANDIDATES groups |
|-------|--------|---------|-----------------------|
| `0001` | `021c7102d8` | Fix RKMPP and V4L2 review regressions | 1, 2, 3, 6, 7, 11 |
| `0002` | `c44cc876db` | Fix Rockchip encoder review issues | 1, 8, 9, 10, 11 |
| `0003` | `5c0c56e8c8` | Fix RKMPP async poll and frame mapping | 6, 9, 12 |
| `0004` | `275f06843a` | fix rockchip review issues | 3, 9, 10, 13 |
| `0005` | `93891823df` | fix rkmpp review regressions | 3, 4, 7 |
| `0006` | `383bd2a4f3` | fix rkmpp review cleanup issues | 5, 12, 13 |
| `0007` | `9319172196` | fix rkmpp frame ownership cleanup | 5, 9, 12 |
| `0008` | `1c73bd8e65` | fix rkmpp code review issues | 3, 5, 9, 10, 12, 13, 14 |
| `0009` | `b59509b609` | fix rkmpp/v4l2 code review issues | post-write-up |

Patches `0010`–`0028` (2026-07-01/02) landed after the FIX-CANDIDATES write-up
and are **not** mapped onto its groups. By theme:

| Patch range | Commits | Theme |
|-------------|---------|-------|
| `0010`–`0012` | `290be4a8a5..2c5ed87e26` | RGA overlay preproc/blend rework, crop defaults + `global_alpha=0`, encoder async send-queue rework + flush support |
| `0013`–`0020` | `d1eb7f66ac..1c75fe327d` | DRM descriptor/layout validation frameworks (rkmppenc + rkrga + hwcontext_rkmpp), AFBC modifier whitelist + `afbc_offset_y` descriptor field, RFBC removal (`0018`), v4l2 m2m format-negotiation + copy rework |
| `0021`–`0027` | `deb5047b03..a7f67c4cf4` | AFBC/capture fallback regression fixes, v4l2 mplane padded-raw validation, NV21 mapping, RGA compact 10-bit input fallback, v4l2 MPLANE-first retry + buffer release |
| `0028` | `6cf02ab253` | 2026-07-02 review: decode drain/EOS/errinfo fixes, v4l2 copy source bounds, SAR transpose, DRM descriptor provenance, MJPEG SOF sizing, capture pixel-format two-pass fallback |

## Rockchip-specific vs generic-FFmpeg code

Which half of the series sits on vendor-specific code and which half sits on
vanilla upstream code. This is the distinction that matters when backporting by
behavior onto a different tree:

| Content | Where it sits |
|---------|---------------|
| Everything touching `rkmppdec.*`, `rkmppenc.*`, `hwcontext_rkmpp.*`, `rkrga_*`, and the `NV15`/`NV20_PACKED` swscale/pixdesc work | **Rockchip-specific.** Upstream FFmpeg has no `AV_HWDEVICE_TYPE_RKMPP` hwcontext, no RKRGA filters, and no compact 10-bit NV formats, so this code only exists in a Rockchip fork. |
| The `libavcodec/v4l2_buffers.c`/`v4l2_context.c`/`v4l2_fmt.*` work (mostly in `0020`, `0028`) and the generic `libavdevice/v4l2.c` hunks (device_caps, bounds guards, two-pass format fallback, NV21) | **Generic FFmpeg code.** nyanmisaka's series never touches the m2m stack, so these hunks sit on vanilla upstream code and fix defects that are present there too (NULL deref, source overreads, format clobbering). |

## Applying

Onto the exact base (full reconstruction of `yisding/ffmpeg-rockchip-81`
`main` without network access to it):

```bash
git clone https://github.com/FFmpeg/FFmpeg.git && cd FFmpeg
git checkout -b rkmpp 87bd15dc3c
# reconstruct def08a047f: removal commit + 31-commit fork replay + port commit
# (see ../rebase-notes.md §2; or just clone yisding/ffmpeg-rockchip-81)
git am /path/to/rock-5b-ysp/ffmpeg/patches/00*.patch
```

In practice the simpler path is `git clone
https://github.com/yisding/ffmpeg-rockchip-81 && git checkout main` — the
series is already applied there (`def08a047f..6cf02ab253`). Use `git am`
against `def08a047f` only when rebuilding from upstream FFmpeg plus this
archive, or `git am -3` when porting to a nearby base.

Build recipe for the resulting tree: [`../README.md`](../README.md)
(Configure + build), noting the rebased tree no longer needs
`--disable-vulkan` ([`video-libraries/ffmpeg/docs/rebase-notes.md`](../docs/rebase-notes.md) §3).
