# ffmpeg/patches/ — exported RKMPP/RKRGA review-fix series

The nine `git format-patch` files in this directory are the actual diffs behind
the 14 fix groups described in [`../fix-candidates.md`](../docs/fix-candidates.md).
They exist so the fixes survive independently of the dev box and of any
maintained fork: [`../fix-candidates.md`](../docs/fix-candidates.md) is the *why*,
this directory is the *what*.

## Provenance

Exported 2026-07-01 with `git format-patch --base=def08a047f def08a047f..main`
from a clone of **`github.com/yisding/ffmpeg-rockchip-81`** (branch `main`,
tip `b59509b609`, in sync with `origin/main` at export time). Tree topology,
pins, and replay method: [`../rebase-notes.md`](../docs/rebase-notes.md).

The series applies on top of:

| Layer | Commit | What it is |
|-------|--------|------------|
| Direct base (in the `base-commit:` trailer of each patch) | `def08a047f` | `avcodec/rkmpp: port Rockchip stack to current FFmpeg` — the final port commit of the fork replay. |
| Underneath that | 31 replayed nyanmisaka fork commits + removal commit `6fb4d1cd37` | The full RKMPP/RKRGA feature stack. |
| Bottom | FFmpeg master `87bd15dc3c` (2026-06-26) | The rebase base (see [`../rebase-notes.md`](../docs/rebase-notes.md) §1 for how it relates to `n8.1.2`). |

This is a **reference export pinned to a specific base, not a maintained
fork**. It will not apply cleanly to arbitrary future FFmpeg or
ffmpeg-rockchip trees; backport by behavior (per fix group) in that case, as
[`../fix-candidates.md`](../docs/fix-candidates.md) recommends for the older
nyanmisaka branch.

## Patch ↔ FIX-CANDIDATES group map

Group numbers are the `## N.` section numbers in
[`../fix-candidates.md`](../docs/fix-candidates.md). Most commits fix several
groups at once (they were review sweeps, not per-topic patches); the
NyanMisaka-facing 10-patch split suggested at the end of FIX-CANDIDATES is a
*re-slicing* of this same content, not a different series.

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
| `0009` | `b59509b609` | fix rkmpp/v4l2 code review issues | post-write-up — see below |

`0009` landed on 2026-07-01 *after* the FIX-CANDIDATES write-up (which audited
`1c73bd8e65`) and is not yet folded into its groups. Its commit message is the
authoritative summary; headline items: decoder input-queue-full deadlock
(return to caller instead of looping while all frames are held), MJPEG
in-flight frame tracking during drain, BSF-filtered extradata sent before the
first packet, errinfo frames surfaced as `AVERROR_INVALIDDATA` instead of a
clean EOF, decoder state/`last_pts` reset on flush, `AVERROR(EOF)`→
`AVERROR_EOF` sign fix, zero-pitch DRM-descriptor guards in encoder and RGA
(SIGFPE), V4L2 DV-timings validation + `mmap_free` leak fix, and
`drm_is_afbc`/`drm_is_rfbc` macro parenthesization.

## Fork-only vs upstream-candidate

| Content | Label |
|---------|-------|
| Everything touching `rkmppdec.*`, `rkmppenc.*`, `hwcontext_rkmpp.*`, `rkrga_common.c`, and the `NV15`/`NV20_PACKED` swscale/pixdesc work | **Fork-only.** Upstream FFmpeg has no `AV_HWDEVICE_TYPE_RKMPP` hwcontext, no RKRGA filters, and no compact 10-bit NV formats ([`../fix-candidates.md`](../docs/fix-candidates.md) summary table). |
| The `libavdevice/v4l2.c` / `v4l2-common.c` hunks in `0001`, `0002`, and `0009` (mplane `data_offset` payload accounting, `VIDIOC_G_DV_TIMINGS` framerate fallback + validation, `NV16`/`NV24` `#ifdef` guards, `mmap_free` leak) | **Upstream-candidate material** — the only two pieces FIX-CANDIDATES judges plausible as FFmpeg submissions, and even those need re-scoping to upstream's narrower single-plane mmap model before sending. |

None of it has been submitted anywhere as of 2026-07-01 — see the submission
ledger in [`../rebase-notes.md`](../docs/rebase-notes.md) §6.

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
series is already applied there (`def08a047f..b59509b609`). Use `git am`
against `def08a047f` only when rebuilding from upstream FFmpeg plus this
archive, or `git am -3` when porting to a nearby base.

Build recipe for the resulting tree: [`../README.md`](../README.md)
(Configure + build), noting the rebased tree no longer needs
`--disable-vulkan` ([`../rebase-notes.md`](../docs/rebase-notes.md) §3).
