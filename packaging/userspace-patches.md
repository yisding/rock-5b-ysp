# Userspace patch map

Where every patched userspace component's source lives, how its patches are
carried, what it is pinned to, which PPA ships it, and what to do to add a new
patch.

The machine-readable source of truth for every pin is the variable block at the
top of [`ppa/build-source-packages.sh`](ppa/build-source-packages.sh). This
document explains it; when the two disagree, the script is right and this file
is stale. For PPA layout and install paths see [`ppa/README.md`](ppa/README.md);
for how the external source trees are reconstructed see
[`external-workspaces.md`](external-workspaces.md).

## At a glance

| Component | Source tree (under `~/Code/`) | Patches carried as | Pinned at | Package version | PPA |
|---|---|---|---|---|---|
| **MPP** | `rockchip-userspace/mpp-rockchip` @ `ysp/main` | **fork branch**, 6 commits | `ad325345`, 6 past tag **`1.0.12`** (`1375813c`) | `1.5.0+git20260730.ad325345+ds-0ubuntu1~rk1` | `ubuntu-rock-5b` |
| **librga** | `rockchip-userspace/librga-fork` | **fork branch**, 11 commits | `26a50ef`, 11 past vendor base `2cffdf6` | `2.2.0+git20260725.26a50ef-0ubuntu1~rk1` | `ubuntu-rock-5b` |
| **FFmpeg 8.0** (system) | `ffmpeg/ffmpeg-rockchip-81` @ `rockchip-8.0` | **fork branch** | `da5befc806` | `7:8.0.3+rockchip+git20260719.da5befc806-0ubuntu1~rk1` | `ubuntu-rock-5b` |
| **FFmpeg 6.1** (co-installable) | `ffmpeg/ffmpeg-rockchip` (nyanmisaka) | upstream snapshot, no delta | `40c412dacc` | `6.1+git20260423.40c412dacc-0ubuntu1~rk1` | `ubuntu-rock-5b` |
| **GNOME Remote Desktop** | `gnome/grd/gnome-remote-desktop` @ `release/50.2-rkmpp` | **fork branch**, 17 commits | `c4ef3c9` | `50.2+rkmpp+git20260729.15.c4ef3c9-0ubuntu1~rk1` | `ubuntu-rock-5b` |
| **Plymouth** | (packaging-local) | **quilt**, 1 patch | — | see `ppa/plymouth/` | `ubuntu-rock-5b` |
| **FFmpeg 8.1** (baseline) | none — recovered `debian/` only | none (pristine upstream) | `8.1.2` | `7:8.1.2-1+rk2` | `rock5b-ffmpeg81-upstream` |
| **codec-udev** | native, in-repo | n/a | — | `1.1` | `ubuntu-rock-5b` |
| **gdm-hwenc** | native, in-repo | n/a | — | `1.0` | `ubuntu-rock-5b` |
| **rockchip-vaapi** | `yisding/rockchip-vaapi` @ `main` | fork branch | `5d558fa` | `1.0.11+ysp6-0ubuntu1~rk1` (signed locally) | `ubuntu-rock-5b` upload pending |

Two gaps worth knowing rather than rediscovering:

- **`ppa:yi-ding/rock5b-ffmpeg81-rockchip` has no tracked packaging directory.**
  The archive is Published and referenced from `ppa/README.md`, but no
  `packaging/ppa/*` tree reproduces it. Rebuilding that source package today
  would mean recovering the `debian/` tree from Launchpad, the way
  `ffmpeg-baseline` was recovered on 2026-07-07.
- **rockchip-vaapi now has an exact-commit source package but is not yet
  published.** `1.0.11+ysp6-0ubuntu1~rk1` is signed, source/binary
  Lintian-error-clean, and isolated-lifecycle validated; upload and Launchpad
  build/publication remain.

## Two ways patches are carried

This is the distinction that governs everything else.

**Fork branch** — the default, and everything except Plymouth. The delta lives
as commits on a branch of a fork on GitHub, and the packaging snapshots that
commit into the orig tarball. `debian/patches/` is absent. This keeps real git
history, survives rebases onto newer upstream, and lets the same branch be
pushed for review or a PR. The cost: **the delta is not visible in this repo** —
you must look at the fork to see what is patched.

**Quilt** — **Plymouth only.** Upstream source is used pristine and the delta
lives in the repo as DEP-3 patch files under `ppa/plymouth/debian/patches/`,
listed in `series`. This suits a single small patch against a distro package
that has no fork and does not need one.

MPP was converted from quilt to fork branch on 2026-07-25; its patches are
now the commits on `ysp/main`. Do not reintroduce `debian/patches/` for
it. Do not mix the two models for one component — that gives two places to look
and no single answer to "what is patched".

## Per component

### MPP — fork branch, 6 commits

- Packaging branch: **`ysp/main`** on `yisding/mpp`, based on upstream release
  tag `1.0.12` (`1375813c`). This is the branch the package builds from.
- Working tree: `rockchip-userspace/mpp-rockchip`. Note this tree is the
  **`HermanChen/mpp` vendor mirror** with a `yisding` remote added, rather than
  a separate fork clone like `librga-fork`. Push ysp work to `yisding`; **never
  to `origin`**. Local `develop` stays at the packaging base.
- The six commits on `ysp/main`:
  - `osal/test: fix the pthread start routine signature` — needed for newer
    GCC/glibc. **Upstream fixed this independently after `1.0.12`**, so it
    exists only because the base is `1.0.12` itself.
  - `hal: rkenc: harden encoder slice poll loops against poll failure` — the
    eight vepu5xx split-output poll loops.
  - `hal: h264e: fix the poll cfg allocation size and its single cfg indexing`.
  - `fix[h265d]: refresh same-id PPS updates` — consumes the parser's existing
    PPS-change bitmap so changed tile layouts reach the decoder HAL even when
    the stream reuses the same PPS ID.
  - `fix[h265d]: keep RADL pictures before random access POC` — stops
    suppressing decodable RADL pictures whose POC precedes a BLA/CRA.
  - `fix[hal_h265e]: set the bitstream top address to size - 1 on vepu580` —
    finishes upstream `264553f9`, which introduced the `size - 1` bitstream-top
    convention for reg 172 but missed the non-tiled H.265 vepu580 call site.
    Without it every ordinary HEVC encode programs base + size, which the
    rewrite driver rejects per frame and the vendor driver turns into the page
    fault `264553f9` set out to remove.
- `ysp/main` is the only ysp branch on the fork. `develop` there tracks upstream
  and is 55 commits past the packaging base; it is not a build input.
- The `1.5.0` in the package version is **not** the upstream tag. It comes from
  Rockchip's own in-tree `debian/changelog`, which runs a `1.5.x` packaging
  lineage independent of the `1.0.x` git tags. The `+git<date>.<sha>` suffix is
  what actually pins the source.

### librga — fork branch

- Tree: `rockchip-userspace/librga-fork`. Push remote is `librga` →
  `yisding/librga`; `origin` is `yisding/librga-mirror` and is
  **vendor-mirror-only — never push work there**.
- `rockchip-userspace/librga-rockchip-github` is a read-only upstream checkout
  (`airockchip/librga`), not a build input.
- No quilt patches. `git describe` gives
  `v2.2.0-1-20260121-2cffdf6-11-g26a50ef`: 11 commits past vendor base
  `2cffdf6`.

### FFmpeg — three separate lineages

They exist as separate archives because Launchpad will not accept an earlier
source version into an archive that already accepted a later one.

- **8.0 system** (`ffmpeg/ffmpeg-rockchip-81`, branch `rockchip-8.0`, remote
  `yisding/ffmpeg-rockchip-81`) — the only FFmpeg in the normal system stack.
- **6.1 co-installable** (`ffmpeg/ffmpeg-rockchip`, nyanmisaka) — snapshot with
  no local delta; ships as separate tool binaries so it cannot conflict.
- **8.1 baseline** — pristine upstream `8.1.2` in its own comparison archive;
  the `debian/` tree was recovered from Launchpad, not authored here.

`ffmpeg/FFmpeg` (`rkmpp-cqp`) and `ffmpeg/jellyfin-ffmpeg` are investigation
checkouts, not packaging inputs.

### GNOME Remote Desktop — fork branch

The package archives branch `release/50.2-rkmpp` at `c4ef3c9` directly — 17
authored commits on latest GNOME 50 stable (`18cc5f7`) — and **applies no source
delta**. The final two commits signal the shader's existing full-range BT.709
conversion in the H.264 VUI and retain the persistent GDM user-display
subscription after a reassigned reconnect handover times out.

The June `a3a1a32` cleanup is not restored wholesale. Its global
`client_taken` flag made a routing token single-use and broke the legitimate
second handover leg; its broad preservation predicate could retain greeter
state. The current branch retains the corrected July ownership, socket,
timeout, and pending-only coalescing commits, then preserves only a display
explicitly reassigned into the destination user handover.

> **The 16-patch directory at
> [`apps/gnome-remote-desktop/patches/`](../apps/gnome-remote-desktop/patches/)
> is OUTDATED. It is not what the package builds, and it is a release behind.**
> It is a **50.1**-era replay that applies to upstream `c14e09ef` (50.1 + 16
> commits), with its own tip `5f61bb6` on `release/50.1-rkmpp`. The shipped
> package is **50.2**. The two have diverged: upstream 50.2 already contains the
> reconnect revert that replay patch `0009` exists to apply, so the replay is
> not merely stale, parts of it are now wrong against the current base.
>
> Editing those files changes nothing about the package. Treat the directory as
> history: it is useful for porting the work to a different base, and for
> reading what the delta *was*, not for changing what ships. `GRD_DELTA` exists
> only for reconstructing a historical package and is empty by default.

## Build procedure

```bash
bash packaging/ppa/build-source-packages.sh <target> [<target> ...]
```

Targets: `mpp`, `librga`, `ffmpeg`, `ffmpeg-rockchip`,
`gnome-remote-desktop` (or `grd`), `plymouth`, `codec-udev`, `gdm-hwenc`,
`kernel`, `kernel-alpha-6.18`, `kernel-alpha-7.2-rc3`.

Artifacts land in `packaging/ppa/out/artifacts` (override with `OUT=`). Source
trees resolve below `WORKSPACE_ROOT`, which defaults to `ROCK5B_WORKSPACE`;
that grouped root defaults to the sibling `rock-5b` workspace. Each
component also honours `<PROJ>_REPO`, `<PROJ>_COMMIT`, and
`<PROJ>_UPSTREAM_VERSION`.

Existing orig tarballs are **reused** by default. That is required, not an
optimisation: uploading a new Debian revision of an upstream version Launchpad
has already accepted must reuse the byte-identical tarball. Set `FORCE_ORIG=1`
only when the upstream version itself changes.

### Adding a patch to a fork-branch component (everything except Plymouth)

1. Commit on the fork branch and push to the **fork** remote, never to a vendor
   mirror's `origin`.
2. Update that component's `_COMMIT` and `_UPSTREAM_VERSION` defaults in
   `ppa/build-source-packages.sh`. The version convention is
   `<upstream>+git<YYYYMMDD>.<short-sha>`, plus `+ds` where the orig tarball is
   repacked (MPP strips two Windows binaries).
3. Add a `debian/changelog` entry — the upstream version changed, so the Debian
   revision resets to `-0ubuntu1~rk1`.
4. Rebuild with `FORCE_ORIG=1`, since the upstream version changed.
5. Verify the orig tarball actually contains the change. It is easy to build a
   package that silently snapshots the wrong commit:
   ```bash
   tar -xzOf <pkg>.orig.tar.gz --wildcards '*/path/to/file.c' | grep <marker>
   ```

### Adding a patch to Plymouth (the only quilt component)

1. Make the change in the source tree on a local branch. Never commit to a
   vendor mirror's own branch.
2. Generate the patch body and prepend a DEP-3 header
   (`Description:` / `Author:` / `Forwarded:` / `Last-Update:`) matching the
   existing files.
3. Write it to `ppa/plymouth/debian/patches/NNNN-<slug>.patch` and append the
   filename to `series`.
4. Verify it applies in order against pristine upstream:
   ```bash
   git -C <source-tree> archive <base> | tar -x -C ~/Code/tmp/applytest
   cd ~/Code/tmp/applytest
   for p in $(cat .../debian/patches/series); do patch -p1 -i .../$p || echo "FAIL $p"; done
   ```
   Apply the series **sequentially for real** — `--dry-run` tests each patch
   against pristine source and will falsely fail any patch that depends on an
   earlier one.
5. Rebuild the source package. The upstream version does not change, so reuse
   the existing orig tarball and bump only the Debian revision.

## Traps

- **librga and the kernel ship as a pair on the 10-bit path.** `LIBRGA_COMMIT`
  must track the tip matching the shipped kernel's 10-bit stride convention.
  This has already gone wrong once: the default lagged behind
  `c80eea7`/`b8def3e`/`4c26ddf` after kernel `0072`/`0074` moved 10-bit `vir_w`
  to a byte stride, so the documented build command produced a mismatched pair
  whose failure mode is **silent wrong chroma, not an error**. The warning
  comment above `LIBRGA_COMMIT` in the script is load-bearing.
- **MPP has three different bases in play.** Packaging builds `ysp/main`, based
  on tag `1.0.12` (`1375813c`); `yisding/mpp` `develop` is 55 commits past that
  tag; and the optional legacy-conformance checkout
  (`kernel-drivers/tests/conformance/MANIFEST.tsv`) is pinned to `c2c1ee5`, an
  *untagged* commit from 2026-03-09 that predates `1.0.12` entirely. Normal
  conformance now uses the installed package; the old checkout is selected only
  through explicit `MPP_BIN_DIR`/`MPP_LIBDIR` overrides. A change written
  against one base will not apply to the others. This is why the older encoder
  fixes also have a repo-owned bootstrap patch under
  `kernel-drivers/tests/conformance/patches/rockchip-mpp/`. Porting `ysp/main`
  onto `develop` is not mechanical — upstream relocated the encoder status
  check out of `wait()` into `ret_task()`, which is exactly the code the
  poll-loop hardening interacts with.
- **A vendor mirror's working tree is not storage.** Uncommitted fixes in
  `rockchip-conformance/sources/*` are one `git checkout` from vanishing, and a
  conformance run against reverted userspace misreports a good kernel fix as a
  failure. Put the change in a patch file that `bootstrap-sources.sh` applies.
- **`/tmp` is tmpfs on this board.** Build output directories under `/tmp` are
  resident RAM, not disk. Use `~/Code/tmp`.
