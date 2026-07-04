# Armbian patch precedence — why you can't disable a core patch from userpatches

> Scope: Armbian `build` framework, `lib/tools/patching.py` + `lib/tools/common/patching_utils.py`.
> Source pin: `armbian/build` master @ `82b6430` (the tree that built our shipping
> kernel), read 2026-07. Line numbers drift; the stable anchors are the
> construct names (`ALL_DIR_PATCH_FILES_BY_NAME`, `CONST_PATCH_ROOT_DIRS`, `find_series_patch_files`).
> Trust: **MEASURED** (read the code + reproduced the build; forum/PR claims cited inline).

This is the companion to [`armbian-packaging.md`](./armbian-packaging.md). That doc
explains *what* we do about the `media-0001` DT collision; this one explains the
**patcher mechanics** behind it — specifically why the widely-documented "drop an
empty file in `userpatches/` to disable a patch" trick **does not work** on the
branch we build (`rockchip64-6.18`), and what does.

## TL;DR

- On a **glob** branch (like `rockchip64-6.18`) a same-name userpatch does **not**
  override a core patch — **core wins**. So you cannot disable a core patch from
  `userpatches/`; the documented empty-file method is stale (old bash behavior).
- The **only** ways to drop a core patch are to touch the core tree: **remove/rename
  the file** so it's not globbed (what our build does), redirect `KERNELPATCHDIR`,
  or — on a **series** branch only — comment/`-`-prefix it in `series.conf`.
- Restoring the documented behavior is a **~2-line** patch to `patching.py`, but it's
  a global precedence flip needing the whole board CI matrix, which is why nobody has.

## How precedence actually works (glob branches)

`patching.py` builds the applied-patch list like this:

1. Each patch dir is discovered with `find_files_patch_files()`, which takes **only
   files ending in `.patch`** (top-level, non-recursive) — `patching_utils.py`.
   *(Corollary: any other suffix, e.g. `.patch.disabled`, is invisible. `.disabled`
   is not magic — nothing special-cases it; it simply isn't `*.patch`.)*
2. All patches are folded into `ALL_DIR_PATCH_FILES_BY_NAME`, a dict **keyed by
   basename** — so `dict[name] = patch`, **last write wins**.
3. Root dirs are appended **user-first, core-last** (`CONST_PATCH_ROOT_DIRS`:
   userpatches root, then `SRC/patch/...` root), so when two dirs hold the same
   basename, **core is written last and wins**.
4. The final list is then **re-sorted alphabetically by basename**
   (`NORMAL_PATCH_FILES = list(dict(sorted(...)).values())`).

Consequences:

| Question | Answer |
|----------|--------|
| Does a same-name userpatch shadow a core patch? | **No** — core wins the dict overwrite. |
| Can an empty userpatch disable a core patch? | **No** (glob branch) — it's discarded before it can. |
| Does userpatch order/naming change the *apply sequence*? | Only the collision **winner**; the sequence is always alphabetical-by-basename (step 4). |

> **⚑ The trap: configs and patches resolve in *opposite* directions.** The same
> file resolves `0000.patching_config.yaml` with `CONST_ROOT_TYPES_CONFIG_ORDER =
> ['core','user']` — **user overrides core** for *config*. But *patch files* (above)
> are **core-wins**. So "userpatches override core" is true for the YAML config and
> false for patches. This inconsistency is almost certainly how the regression slipped in.

## The documented behavior is stale

Armbian's [User Configurations docs](https://docs.armbian.com/Developer-Guide_User-Configurations/)
still say *"To disable a patch, create an empty file in the corresponding directory
in `userpatches`."* That was true in the **old bash** patcher; the **Python rewrite**
(armbian-next) inverted it to core-wins. Igor confirms on the forum
([topic 26732](https://forum.armbian.com/topic/26732-unable-to-disable-armbian-patch-by-creating-a-blank-file-in-userpatches/)):
*"Creating a blank file doesn't work in the current master branch"* — and his
recommended workaround is *"remove it within build script — remove file
`patch/kernel/archive/...`"*, i.e. exactly what our build does.

## What actually disables a core patch

All of these touch the core tree or a copy of it — there is **no** userpatch-only or
config-only exclusion:

| Method | How | Scope / cost |
|--------|-----|--------------|
| **Rename/remove in the archive dir** *(what we use)* | rename `foo.patch` → `foo.patch.disabled` (any non-`.patch` suffix). Content untouched — not a reverse diff. | Any branch. Edits Armbian's `patch/` tree; reversible. See [`armbian-packaging.md`](./armbian-packaging.md) § self-contained DT. |
| **`series.conf` comment / minus** | prefix the line with `#` or `-` (`parse_series_conf` skips both). | **Series branches only** — the archive glob dirs have no `series.conf`. e.g. [PR #9493](https://github.com/armbian/build/pull/9493) disabled 3 rockchip-6.19 patches this way. |
| **`KERNELPATCHDIR` redirect** | point the kernel patch dir list at your own copy of the archive minus the patch. | Keeps Armbian's tree pristine; you now fork/maintain the dir. |
| **`DISABLE_KERNEL_PATCHES=yes`** | clears `KERNELPATCHDIR` entirely → vanilla kernel. Added by [PR #8149](https://github.com/armbian/build/pull/8149). | **All-or-nothing**, and a blunt instrument — it also force-sets `EXTRAWIFI=no`. Not per-patch. |
| ~~empty file in userpatches~~ | ~~documented~~ | **Broken on glob branches** (above). |

## Restoring the documented behavior — the ~2-line fix

The collision winner is decided at the dict build in `patching.py`:

```python
# current: user inserted first, core last -> core overwrites -> core wins
for one_patch_file in ALL_DIR_PATCH_FILES:
    ALL_DIR_PATCH_FILES_BY_NAME[one_patch_file.file_name] = one_patch_file
```

Insert **core first, user last** so the userpatch wins:

```python
# core first, user last -> a same-named userpatch overrides the core patch
for one_patch_file in sorted(ALL_DIR_PATCH_FILES,
                             key=lambda p: 0 if p.patch_dir.root_type == "core" else 1):
    ALL_DIR_PATCH_FILES_BY_NAME[one_patch_file.file_name] = one_patch_file
```

`p.patch_dir.root_type` is a real attribute (`"core"`/`"user"`); `sorted` is stable.
**Apply order is unaffected** because the list is re-sorted alphabetically right after
— only the *winner* of a name clash flips.

The empty-file "disable" then works downstream **with no further change**: a 0-byte
userpatch → `mailbox.mbox` sees 0 messages → the diff-only branch builds one bare
patch with `diff=""` → `PatchSet("")` parses to an empty patchset (no exception) →
applies as a **no-op**. (Only for a genuinely empty/plain file; an *mbox* file whose
fragments are all empty instead raises `"No valid patches found"`.)

Why it's stayed unfixed — the cost is validation, not code:

- **It's a global precedence flip** for every board/family/u-boot/ATF build. Any
  existing userpatch that happens to share a basename with a core patch (today
  silently ignored) would suddenly take effect → matrix-wide regression risk.
- **The key is basename, not path**, while the docs promise "same file name *and*
  path." A reviewer would likely want the key tightened to the relative path first.
- Series branches are unaffected (next section), so the PR must scope its claim.

## Why the fix wouldn't touch series branches

Series and glob patches run through **two independent pipelines** that meet only at
the final concatenation `ALL_PATCH_FILES_SORTED = PATCH_FILES_FIRST + SERIES_PATCH_FILES + NORMAL_PATCH_FILES`:

| | Glob branch (`rockchip64-*`) | Series branch (`rockchip-*`, `sunxi-*`) |
|---|---|---|
| Discovery | `find_files_patch_files()` (top-level `*.patch`) | `find_series_patch_files()` reads `series.conf` (patches often in subdirs, e.g. `megous/…`) |
| Collected into | `ALL_DIR_PATCH_FILES_BY_NAME` (**dedup dict** ← override lives here) | `SERIES_PATCH_FILES` (**separate list, no basename dedup**) |
| Order | alphabetical by basename | `series.conf` order, applied **first** |
| Per-patch disable | none built-in | `#` / `-` in `series.conf` |

The reorder only changes the dict winner, and series patches never enter that dict —
so it can't affect them, and they don't need it (they have `series.conf`). A userpatch
sharing a basename with a series patch doesn't replace it; it's globbed into
`NORMAL_PATCH_FILES` and applied *after* all series patches as an additional patch.

## Is everything moving to series style? No.

Series and glob **coexist across the same kernel versions**, chosen per-family — this
is the tell that it is *not* a version-gated migration (this tree @ `82b6430`):

| Style | Families |
|-------|----------|
| **series.conf** | `sunxi-*`, `rockchip-*` (mainline), `filogic-*` (~10 branches) |
| **plain glob** | `rockchip64-*` (ours), `meson64-*`, `sm8250-*`, `mvebu-*`, `imx*`, `spacemit-*`, `starfive-*`, `uefi-*`, `cix-*`, … (~45+, incl. the newest 7.1) |

The series families are the ones that **import a large, order-sensitive upstream
stack** (sunxi pulls the megous tree — historically ~651 patches; rockchip the
mainline/Collabora stack; filogic the MTK stack), where explicit total order,
subdir layout, and per-line disable are load-bearing. Glob is fine for a curated set
of mostly-independent BSP patches (even `rockchip64-6.18`'s ~177).

The actual forward direction is **git-managed patches for everyone**, not series for
everyone: [PR #7651 "rewrite all kernel patches and configs"](https://github.com/armbian/build/pull/7651)
(rpardini, merged 2025-01-05) round-tripped *every* family's patches through the new
apply-to-git → rebase → rewrite-from-git pipeline (body: "rewrite-kernel-patches, no
changes" per family — a format normalization). That workflow is orthogonal to
series-vs-glob; series just pairs naturally with it for the imported stacks.

## Sources

- Code: `lib/tools/patching.py`, `lib/tools/common/patching_utils.py` (`armbian/build` @ `82b6430`).
- [Forum 26732 — empty-file disable doesn't work (Igor)](https://forum.armbian.com/topic/26732-unable-to-disable-armbian-patch-by-creating-a-blank-file-in-userpatches/)
- [User Configurations docs — the stale empty-file claim](https://docs.armbian.com/Developer-Guide_User-Configurations/)
- [PR #8149 — `DISABLE_KERNEL_PATCHES`](https://github.com/armbian/build/pull/8149) · [PR #9493 — series.conf disable in practice](https://github.com/armbian/build/pull/9493) · [PR #7651 — git-based patch rewrite](https://github.com/armbian/build/pull/7651)
