# Rebasing ffmpeg-rockchip onto current FFmpeg — trees, method, ledger

How the 2026 rebase of nyanmisaka's ffmpeg-rockchip stack onto FFmpeg master
was actually staged, which tree is current, and how to redo it for the next
FFmpeg bump. Companion to [`fix-candidates.md`](fix-candidates.md) (what the
rebase review found) and [`patches/`](../patches/README.md) (the exported diffs).
All branch/commit facts below verified 2026-07-01 against the working clones.

## 1. Trees and pins, reconciled

The ffmpeg docs in this repo reference four different FFmpeg source points.
They relate like this:

| Pin | Commit | Date | What it is | Cited by |
|-----|--------|------|------------|----------|
| nyanmisaka fork tip (pre-rebase) | `40c412dacc` | 2026-04-23 | `github.com/nyanmisaka/ffmpeg-rockchip` as studied; preserved locally as branch `backup-pre-upgrade-master` | [`README.md`](../README.md) build recipe, [`implementation-comparison.md`](implementation-comparison.md) fork column |
| upstream release tag `n8.1.2` | `38b88335f99e` | 2026-06-17 | FFmpeg 8.1.2 release (branch `release/8.1`) | [`implementation-comparison.md`](implementation-comparison.md) upstream column; the PPA/GRD package base ([`../packaging/ppa/`](../../packaging/ppa/README.md)) |
| upstream master | `87bd15dc3c` | 2026-06-26 | FFmpeg master commit used as the rebase base; branch `upstream` of the rebased repo | [`fix-candidates.md`](fix-candidates.md) source-points table |
| rebased tree | `b59509b609` | 2026-07-01 | **`github.com/yisding/ffmpeg-rockchip-81`**, branch `main` (branch `upstream` = `87bd15dc3c`); `1c73bd8e65` is the same branch one commit earlier, the state the FIX-CANDIDATES write-up audited | [`fix-candidates.md`](fix-candidates.md), [`patches/`](../patches/README.md) |

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
         └─ 021c7102d8 … b59509b609   9 review-fix commits (all 2026-07-01)
                                  = ffmpeg-rockchip-81 main
                                  = the exported patches/0001–0009
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
| System-wide / GRD | `ffmpeg 7:8.1.2-1+rk1` (installed deb) | Upstream 8.1.2 + rkmpp ABI drop-in from the PPA packaging work — [`../packaging/ppa/`](../../packaging/ppa/README.md). `librockchip-mpp1/-dev 1.5.0-1+rk1` and `librga2/-dev 2.2.0-1+rk1` installed alongside. |
| CLI hardware transcode / `tests/` | `~/Code/ffmpeg-rockchip/ffmpeg` (dev box), built 2026-07-01 | Working tree clean at `def08a047f` (the rebased port, **without** the 9 review-fix commits — those live on `ffmpeg-rockchip-81 main`). Configured `--enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga --disable-doc` against the **system PPA libs** (no staging prefix), with Vulkan enabled (`CONFIG_VULKAN 1`, headers 1.4.341). Caveat: the binary's version string reads `N-125363-g53e76abdc7` (the last replayed fork commit, `def08a047f`'s parent) — whether it predates the port commit or just carries a stale cached `.version` is UNVERIFIED; rebuild before trusting it for regression comparisons. |

Two consequences worth stating plainly:

- **The fixed tree (`b59509b609`) is published but is not what is currently
  installed or built anywhere on the board.** Anything exercised at runtime so
  far ran either upstream-8.1.2 rkmpp code or the pre-fix rebased stack.
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
3. Replay the Rockchip stack: cherry-pick `6fb4d1cd37..b59509b609` from
   `yisding/ffmpeg-rockchip-81` (removal commit excluded, fixes included), or
   replay the 31 fork commits and `git am` [`patches/`](../patches/README.md) on
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
7. Validate on hardware: [`../tests/transcode-test.sh`](../../kernel-drivers/tests/transcode-test.sh)
   (no software fallback ⇒ a pass proves the HW ran).
8. Update the pins here, in [`fix-candidates.md`](fix-candidates.md), and
   re-export [`patches/`](../patches/README.md); note the bump in `status.md`.

## 5. The exported fix series

[`patches/`](../patches/README.md) holds the nine review-fix commits
(`def08a047f..b59509b609`) as `git format-patch` files with `base-commit`
trailers, plus the patch↔fix-group map onto
[`fix-candidates.md`](fix-candidates.md)'s 14 groups and fork-only vs
upstream-candidate labeling. That directory is the survival copy; this file
and FIX-CANDIDATES are the narrative.

## 6. Submission ledger

Status of every outbound piece, as of **2026-07-01: nothing has been sent
anywhere.** Update this table (with dates) when that changes; `status.md`
carries the one-line rollup.

| Item | Target | Sent | Landed | Notes |
|------|--------|------|--------|-------|
| 10-patch backport series ([`fix-candidates.md`](fix-candidates.md) "Suggested patch split") | nyanmisaka/ffmpeg-rockchip | no | — | Needs backport-by-behavior; the old branch predates current FFmpeg internals. |
| V4L2 mplane `data_offset` payload accounting (group 1) | FFmpeg upstream | no | — | Must be re-scoped to upstream's single-plane mmap model first. |
| V4L2 `VIDIOC_G_DV_TIMINGS` framerate fallback (group 2) | FFmpeg upstream | no | — | Generic; needs overflow/zero-field review per FIX-CANDIDATES. |
| `NV15`/`NV20_PACKED` pixel formats | FFmpeg upstream | no | — | Only viable as a full feature series (formats + swscale + tests), not as fixes. |
| Post-write-up fixes ([`patches/0009`](../patches/README.md)) | nyanmisaka/ffmpeg-rockchip | no | — | Not yet folded into the FIX-CANDIDATES groups either. |
