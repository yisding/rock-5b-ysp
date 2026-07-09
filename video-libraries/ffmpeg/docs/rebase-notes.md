# Rebasing ffmpeg-rockchip onto current FFmpeg — trees, method, ledger

How the 2026 rebase of nyanmisaka's ffmpeg-rockchip stack onto FFmpeg master
was actually staged, which tree is current, and how to redo it for the next
FFmpeg bump. Companion to [`fix-candidates.md`](fix-candidates.md) (what the
rebase review found) and [`video-libraries/ffmpeg/patches/README.md`](../patches/README.md) (the exported diffs).
All branch/commit facts below verified 2026-07-01 against the working clones.

## 1. Trees and pins, reconciled

The ffmpeg docs in this repo reference four different FFmpeg source points.
They relate like this:

| Pin | Commit | Date | What it is | Cited by |
|-----|--------|------|------------|----------|
| nyanmisaka fork tip (pre-rebase) | `40c412dacc` | 2026-04-23 | `github.com/nyanmisaka/ffmpeg-rockchip` as studied; preserved locally as branch `backup-pre-upgrade-master` | [`README.md`](../README.md) build recipe, [`implementation-comparison.md`](implementation-comparison.md) fork column |
| upstream release tag `n8.1.2` | `38b88335f99e` | 2026-06-17 | FFmpeg 8.1.2 release (branch `release/8.1`) | [`implementation-comparison.md`](implementation-comparison.md) upstream column; the PPA/GRD package base ([`packaging/ppa/README.md`](../../../packaging/ppa/README.md)) |
| upstream master | `87bd15dc3c` | 2026-06-26 | FFmpeg master commit used as the rebase base; branch `upstream` of the rebased repo | [`fix-candidates.md`](fix-candidates.md) source-points table |
| rebased tree | `6cf02ab253` | 2026-07-02 | **`github.com/yisding/ffmpeg-rockchip-81`**, branch `main` (branch `upstream` = `87bd15dc3c`); earlier states: `1c73bd8e65` = what the FIX-CANDIDATES write-up audited, `b59509b609` = the 2026-07-01 export point | [`fix-candidates.md`](fix-candidates.md), [`submission-plan.md`](submission-plan.md), [`video-libraries/ffmpeg/patches/README.md`](../patches/README.md) |

**How `n8.1.2` relates to `87bd15dc3c`:** they are siblings, not
ancestor/descendant. `release/8.1` forked from master at `67c886222f` ("Bump
versions for release/8.1", 2026-03-08); `n8.1.2` is that branch plus backports,
while `87bd15dc3c` is master ~3.5 months past the fork point (verified via
`git merge-base` in the upstream FFmpeg clone). So
[`implementation-comparison.md`](implementation-comparison.md) (upstream =
`n8.1.2`) and [`fix-candidates.md`](fix-candidates.md) (upstream =
`87bd15dc3c`) compare against two branches of the same 8.x-era codebase; for
the rkmpp/V4L2 surfaces discussed, no divergence between the two pins has been
observed (UNVERIFIED exhaustively — re-diff `libavcodec/rkmpp*` if it starts
to matter).

## 2. The replay method

The rebase was **not** a `git rebase` of the fork's 12k-commit-old history. It
was a staged replay on a clean master base:

```text
87bd15dc3c                       FFmpeg master (branch upstream)
└─ 6fb4d1cd37                    "Remove upstream RKMPP implementation before
                                  fork replay" — deletes upstream's
                                  rkmppdec.c/rkmppenc.c (~1192 lines, 5 files)
                                  so fork files can land without collision
   └─ 31 replayed fork commits   b1049034b2 (NV15) … 53e76abdc7 (intra-refresh
                                  GDR) — nyanmisaka's RKMPP/RKRGA feature stack
      └─ def08a047f              "avcodec/rkmpp: port Rockchip stack to
                                  current FFmpeg" — the squash-port of the
                                  remaining mismatches (10 files, +56/−34)
         └─ 021c7102d8 … 6cf02ab253   28 review-fix commits (2026-07-01/02)
                                  = ffmpeg-rockchip-81 main
                                  = the exported patches/0001–0028
```

What the port commit `def08a047f` covers (the parts that did not replay
cleanly onto current internals):

- restored FFmpeg's endian-neutral `NV20` alias while keeping the fork's
  compact format registered separately as `NV20_PACKED` (the name-collision
  story in [`fix-candidates.md`](fix-candidates.md) §3);
- ported codec/filter registrations to current FFmpeg internals;
- updated the `imgutils` FATE reference for the new pixel-format table.

The staging branches live in the local `ffmpeg-rockchip` clone (remote
`origin` = nyanmisaka, remote `fork` = `yisding/ffmpeg-rockchip-81`):
`backup-pre-upgrade-master` = `40c412dacc` (the untouched fork tip),
`upgrade-upstream-no-rkmpp` = `6fb4d1cd37` (the removal point), `master` =
`def08a047f`. The canonical published result is
**`github.com/yisding/ffmpeg-rockchip-81`** (`main` in sync with origin as of
2026-07-01).

## 3. Which tree the owner actually runs

Verified 2026-07-01 on the ROCK 5B (kernel `6.18.37-current-rockchip64` #7):

| Consumer | Tree/binary | Detail |
|----------|-------------|--------|
| System-wide / GRD | `ffmpeg 7:8.1.2-1+rk1` (installed deb) | Upstream 8.1.2 + rkmpp ABI drop-in from the local PPA-style packaging work — [`packaging/ppa/README.md`](../../../packaging/ppa/README.md). `librockchip-mpp1/-dev 1.5.0-1+rk1` and `librga2/-dev 2.2.0-1+rk1` installed alongside. |
| CLI hardware transcode / `tests/` | `~/Code/ffmpeg/ffmpeg-rockchip/ffmpeg` (dev box), built 2026-07-01 | Working tree clean at `def08a047f` (the rebased port, **without** the 28 review-fix commits — those live on `ffmpeg-rockchip-81 main`). Configured `--enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga --disable-doc` against the **system PPA libs** (no staging prefix), with Vulkan enabled (`CONFIG_VULKAN 1`, headers 1.4.341). Caveat: the binary's version string reads `N-125363-g53e76abdc7` (the last replayed fork commit, `def08a047f`'s parent) — whether it predates the port commit or just carries a stale cached `.version` is UNVERIFIED; rebuild before trusting it for regression comparisons. |

This is a dated runtime snapshot. A later 2026-07-06 package-validation pass
used the `ffmpeg-rockchip-81` `refactor/section-c` branch at `75638e7f0b17`:
that tree built a self-contained package, registered the RKMPP/RKRGA features,
and passed H.264 encode plus RKMPP hwupload -> RGA -> HEVC encode smoke tests.
Its `h264_rkmpp` decode path fails only with the board's installed `/usr`
`librockchip_mpp.so.1`; a clean `mpp-rockchip` 1.0.12 build supplies the missing
parser registration and makes decode pass. Full build/package/on-board
validation record, including the deb sha256 and the four documented failures, is
in [`rockchip81-package-validation.md`](rockchip81-package-validation.md).

Two consequences worth stating plainly:

- **The exported review series (`6cf02ab253`) and the package-validation tree
  (`75638e7f0b17`) are different snapshots.** Treat `6cf02ab253` as the
  submission-plan/patch-series baseline and `75638e7f0b17` as the latest local
  package-validation baseline recorded in this repo.
- **`--disable-vulkan` is a `40c412dacc`-era requirement only.** The old fork's
  `vulkan_av1.c` used provisional MESA Vulkan-AV1 types; the rebased tree
  inherits master's KHR types and builds with Vulkan on (verified in the
  2026-07-01 build's `config.h`). [`README.md`](../README.md)'s build recipe keeps
  the flag because it documents the 40c412d build.

## 4. Redo checklist for the next FFmpeg bump

Mirrors the method in §2; run [`implementation-comparison.md`](implementation-comparison.md)
§8's fact re-checks alongside.

1. Pick the new base commit on FFmpeg master; branch `upstream` there.
2. Recreate the removal commit: delete upstream's rkmpp files (mirror
   `6fb4d1cd37` — `libavcodec/rkmppdec.c`, `libavcodec/rkmppenc.c` and their
   Makefile/allcodecs registrations) so the fork's files can't collide.
3. Replay the Rockchip stack: cherry-pick `6fb4d1cd37..6cf02ab253` from
   `yisding/ffmpeg-rockchip-81` (removal commit excluded, fixes included), or
   replay the 31 fork commits and `git am` [`video-libraries/ffmpeg/patches/README.md`](../patches/README.md) on
   top.
4. Expect the port-commit surface to need redoing by hand: codec/filter
   registration internals, pixel-format descriptor tables (`NV20` alias vs
   `NV20_PACKED`), and FATE refs (`imgutils`, `sws-pixdesc-query`) are the
   three things that broke last time.
5. Re-test `--disable-vulkan`: drop it if the tree builds with current Vulkan
   headers (it does as of `def08a047f`, §3).
6. Run [`implementation-comparison.md`](implementation-comparison.md) §8
   (did upstream grow RKMPP hwcontext / RGA filters / QP-profile-IDR options?
   — if yes, the removal-commit scope and the GRD workaround story change).
7. Validate on hardware: [`kernel-drivers/tests/transcode-test.sh`](../../../kernel-drivers/tests/transcode-test.sh)
   (no software fallback ⇒ a pass proves the HW ran).
8. Update the pins here, in [`fix-candidates.md`](fix-candidates.md), and
   re-export [`video-libraries/ffmpeg/patches/README.md`](../patches/README.md); note the bump in `status.md`.

## 5. The exported fix series

[`video-libraries/ffmpeg/patches/README.md`](../patches/README.md) holds the 28 review-fix commits
(`def08a047f..6cf02ab253`, re-exported 2026-07-02) as `git format-patch`
files with `base-commit` trailers, plus the patch↔fix-group map onto
[`fix-candidates.md`](fix-candidates.md)'s 14 groups and fork-only vs
upstream-candidate labeling. That directory is the survival copy; this file,
FIX-CANDIDATES, and [`submission-plan.md`](submission-plan.md) (the 2026-07-02
full-branch targeting analysis) are the narrative.

## 6. Submission ledger

Status of every outbound piece, as of **2026-07-02: nothing has been sent
anywhere.** The item list below follows the 2026-07-02 full-branch targeting
analysis in [`submission-plan.md`](submission-plan.md) (which supersedes the
earlier five-item list). Update this table (with dates) when anything is sent;
`status.md` carries the one-line rollup.

| Item | Target | Sent | Landed | Notes |
|------|--------|------|--------|-------|
| v4l2_buffers copy-bounds rewrite ([`submission-plan.md`](submission-plan.md) A1) | FFmpeg upstream | no | — | Strongest candidate: fixes a reachable NULL deref + source overreads in vanilla upstream m2m code. |
| v4l2_context negotiation fixes + mplane-aware fourcc selection (A2, A3) | FFmpeg upstream | no | — | Real upstream bugs (TRY_FMT unverified, `*p` unset → YUV420P clobber). |
| libavdevice/v4l2.c generics (A4: device_caps, bounds guards, two-pass fallback, NV21) | FFmpeg upstream | no | — | Separable small patches. |
| pixdesc BE `x`-offset fix + `fate-pixdesc` hookup (A5, A6) | FFmpeg upstream | no | — | Slivers; optional. |
| Crash/hang class (~10 patches: export-frame double-free, buffer-group double-free, EOS/drain trio, encoder queue drop, get_packet pos, overlay uninit blend, …) | nyanmisaka/ffmpeg-rockchip | no | — | First wave; all verified present in his tree. Backport-by-behavior. |
| Wrong-output class (~14 patches: SAR/transpose, AFBC strides, core masks, colorspace defaults, …) | nyanmisaka/ffmpeg-rockchip | no | — | Second wave; transpose rotate-mode fix needs RGA runtime verification first. |
| NV20 alias restoration + fate-imgutils ref fix | nyanmisaka/ffmpeg-rockchip | no | — | Fixes API break / broken FATE ref that exist only in his tree. |
| DRM descriptor validation frameworks + `afbc_offset_y` descriptor field | nyanmisaka/ffmpeg-rockchip | no | — | Design proposal, not a patch dump; needs his buy-in (public-struct change, behavior changes). |
| `NV15`/`NV20_PACKED` pixel formats | FFmpeg upstream | no | — | Only viable as a full feature series (formats + swscale + tests), not as fixes. |
