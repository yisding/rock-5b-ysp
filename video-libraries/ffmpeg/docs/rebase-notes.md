# Rebasing ffmpeg-rockchip onto current FFmpeg — trees, method, ledger

How the 2026 rebase of nyanmisaka's ffmpeg-rockchip stack onto FFmpeg master
was staged and then recorded on master, 8.0, and 8.1 branches, and how to redo
it for the next FFmpeg bump. Section 7 is a frozen publication snapshot;
[W07](../../../status.md#watch-w07) owns later heads. Companion
to [`fix-candidates.md`](fix-candidates.md) (what the
rebase review found) and [`video-libraries/ffmpeg/patches/README.md`](../patches/README.md) (the exported diffs).
Sections 1–5 were verified 2026-07-01 against the working clones; sections 6–7
record the 2026-07-16 release replay, comparison, and publication pass.

## 1. Trees and pins, reconciled

The ffmpeg docs in this repo reference four different FFmpeg source points.
They relate like this:

| Pin | Commit | Date | What it is | Cited by |
|-----|--------|------|------------|----------|
| nyanmisaka fork tip (pre-rebase) | `40c412dacc` | 2026-04-23 | `github.com/nyanmisaka/ffmpeg-rockchip` as studied; preserved locally as branch `backup-pre-upgrade-master` | [`README.md`](../README.md) build recipe, [`implementation-comparison.md`](implementation-comparison.md) fork column |
| upstream release tag `n8.1.2` | `38b88335f99e` | 2026-06-17 | FFmpeg 8.1.2 release (branch `release/8.1`) | [`implementation-comparison.md`](implementation-comparison.md) upstream column; the PPA/GRD package base ([`packaging/ppa/README.md`](../../../packaging/ppa/README.md)) |
| upstream master | `87bd15dc3c` | 2026-06-26 | FFmpeg master commit used as the rebase base; branch `upstream` of the rebased repo | [`fix-candidates.md`](fix-candidates.md) source-points table |
| rebased tree | `6cf02ab253` | 2026-07-02 | **`github.com/yisding/ffmpeg-rockchip-81`**, branch `main` (branch `upstream` = `87bd15dc3c`); earlier states: `1c73bd8e65` = what the FIX-CANDIDATES write-up audited, `b59509b609` = the 2026-07-01 export point | [`fix-candidates.md`](fix-candidates.md), [`video-libraries/ffmpeg/patches/README.md`](../patches/README.md) |

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
`def08a047f`. The recorded public result is
**`github.com/yisding/ffmpeg-rockchip-81`** at the immutable pins named here.

## 3. Which tree the owner actually runs

Verified 2026-07-01 on the ROCK 5B (kernel `6.18.37-current-rockchip64` #7):

| Consumer | Tree/binary | Detail |
|----------|-------------|--------|
| System-wide / GRD | `ffmpeg 7:8.1.2-1+rk1` (installed deb) | Upstream 8.1.2 + rkmpp ABI drop-in from the local PPA-style packaging work — [`packaging/ppa/README.md`](../../../packaging/ppa/README.md). `librockchip-mpp1/-dev 1.5.0-1+rk1` and `librga2/-dev 2.2.0-1+rk1` installed alongside. |
| CLI hardware transcode / `tests/` | `~/Code/rock-5b/ffmpeg/ffmpeg-rockchip/ffmpeg` (dev box), built 2026-07-01 | Working tree clean at `def08a047f` (the rebased port, **without** the 28 review-fix commits — those live on `ffmpeg-rockchip-81 main`). Configured `--enable-version3 --enable-libdrm --enable-rkmpp --enable-rkrga --disable-doc` against the **system PPA libs** (no staging prefix), with Vulkan enabled (`CONFIG_VULKAN 1`, headers 1.4.341). Caveat: the binary's version string reads `N-125363-g53e76abdc7` (the last replayed fork commit, `def08a047f`'s parent) — whether it predates the port commit or just carries a stale cached `.version` is UNVERIFIED; rebuild before trusting it for regression comparisons. |

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
  patch-series baseline and `75638e7f0b17` as the latest local
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
[`fix-candidates.md`](fix-candidates.md)'s 14 groups. That directory is the
survival copy; this file and FIX-CANDIDATES are the narrative.

## 6. The real FFmpeg 8.1.2 replay

The repository name `ffmpeg-rockchip-81` became misleading as `main` advanced.
At the start of this comparison, then-current `main@be367abfe670` described
itself as `n8.2-dev-2123-gbe367abfe6`: a master-era replay, not an FFmpeg 8.1.x
branch.

To obtain a same-base comparison with Jellyfin, canonical `n8.1.2`
(`38b88335f99e`) was imported and the 65-commit `upstream..main` Rockchip stack
was replayed onto it. The result is local branch
`rockchip-8.1.2@53b3551b9176`, worktree
`/home/yi/Code/rock-5b/build/ffmpeg/ffmpeg-rockchip-812`, described as
`n8.1.2-63-g53b3551b91`. The existing `rockchip-8.0@463f542c3259` checkout and
its untracked build outputs were left untouched.

Two source commits did not become commits on the release branch:

- the `hwcontext_drm` preparation was already present on 8.1.2 and became
  empty;
- the fork-wide README replacement conflicted and was omitted as non-code
  documentation.

The first RKMPP replacement conflict preserved 8.1.2's OMX registration while
removing the small upstream RKMPP implementation. The V4L2 multi-planar changes
were translated onto 8.1.2 APIs, and the public libavutil change was versioned
as `60.27.100` rather than copying master's `61.3.100`. The resulting branch is
63 commits above `n8.1.2` and changes 37 files (+9,507/-991). Its ten core
RKMPP/RKRGA/hwcontext files were byte-for-byte identical to then-current
`main@be367abfe670`.

Both this branch and Jellyfin's effective 8.1.2 source compiled through the
core Rockchip, registration, and public pixel-format objects. This was not a
hardware test. The complete same-base comparison and the Jellyfin features to
port are in
[`rockchip-812-jellyfin-comparison.md`](rockchip-812-jellyfin-comparison.md).

## 7. Canonical three-branch publication

**Frozen 2026-07-16 snapshot.** W07 owns current heads and invalidates reused
compile evidence when they move.

On 2026-07-16 the old master tip, the local 8.1.2 comparison replay, and all
unique `refactor/section-c` work were consolidated into one logical patchset
and replayed onto the then-fetched upstream tips. Three branches were pushed
to `github.com/yisding/ffmpeg-rockchip-81`:

| Branch | Recorded upstream base | Recorded tip | Patch commits |
|--------|---------------|---------------|--------------:|
| `main` | `FFmpeg/master@ceabc9b306f5385d92efdd9cd18d210deb3055b3` (`n8.2-dev-2371-gceabc9b306`) | `8b57e531d1fc3b836dbf20a04e67ec9365cc4d1b` (`n8.2-dev-2444-g8b57e531d1`) | 73 |
| `ffmpeg-80` | `FFmpeg/release/8.0@435ae0581deb56c34c12a23056dcb1e9350a5a2f` (`n8.0.3-27-g435ae0581d`) | `be753f3bbb2c178402ade0e21370eecd2f0cc29c` (`n8.0.3-100-gbe753f3bbb`) | 73 |
| `ffmpeg-81` | `FFmpeg/release/8.1@94138f6973dd1ac6208ace92148ac0d172455d65` (`n8.1.2-22-g94138f6973`) | `8d3ca020b6a260d4de44e21301662f18d6a9669d` (`n8.1.2-93-g8d3ca020b6`) | 71 |

The canonical stack is the old 65-commit Rockchip replay plus all eight unique
commits from the refactor line. Those additions include the generic Jellyfin
correctness import and the final encoder static-format/concurrency fix. The
8.1 count is two lower because the already-satisfied `hwcontext_drm`
preparation and the non-code fork README replacement do not become release
commits. They are not missing implementation changes.

Integration kept each upstream line's native APIs rather than forcing a
master-shaped patch onto the releases:

- current master retains upstream CUARRAY and shader-build structure, appends
  `NV15`/`NV20_PACKED`, registers RKRGA in the current configure lists, and
  records the public API change as libavutil `61.6.100` dated 2026-07-16;
- 8.1 retains its release registrations and API surface while carrying the
  same ten core RKMPP/RKRGA/hwcontext files as `main`;
- 8.0 keeps its older filter-query, color-capability, and encoder-statistics
  APIs. Its only core-file difference from the other lines is the required
  `rkmppenc.c` statistics adaptation. A swscale mismatch patch is empty there
  because the 8.0 restriction it fixes is absent.

All three branches configured with RKMPP, RKRGA, libdrm, and `version3`
enabled. Every affected core Rockchip, registration, V4L2, CLI filter/demux,
swscale, DCA, and avformat object that was enabled in the builds compiled, and
`fate-source` passed on each branch. `libopusenc.o` was not enabled because the
host lacks `opus.h`; configure handled that optional dependency correctly.
This is source/compile validation, not board runtime proof.

This replay did not itself retarget or validate a package. Package input is
owned by [`build-source-packages.sh`](../../../packaging/ppa/build-source-packages.sh),
publication by [W05](../../../status.md#watch-w05), accumulated evidence by
[`validation.md`](validation.md), and the public runtime boundary by status
track 5.
