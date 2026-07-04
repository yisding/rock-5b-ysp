# librga P010/P210 patch series

This directory exports the source-only `librga` delta that was previously held
only in the sibling `../librga-src` worktree.

## Range

Base:

```text
2cffdf6 Merge branch 'linux-rga-multi' of github.com:JeffyCN/mirrors
```

Target:

```text
a632217 im2d: support P010 and P210 request generation
```

The first patch updates the source tree to the 1.10.6 vendor release that the
P010/P210 fixes were developed against. The remaining patches replay the
legacy-path 10-bit layout propagation fixes, RGA2/FBCE/full-CSC compatibility
fixes, and the local IM2D P010/P210 request-generation hardening.

## Apply

From a clean `librga` checkout at `2cffdf6`:

```bash
git am /path/to/rock-5b-ysp/vendor-libraries/rga/patches/*.patch
```

Expected final subject:

```text
im2d: support P010 and P210 request generation
```

The original source tip that produced this patch is `a632217`; applying with
`git am` may produce different local commit IDs because committer metadata
changes.

Minimum checks after applying the six fix commits:

```bash
git diff --check HEAD~6..HEAD
```

`git diff --check HEAD~7..HEAD` reports one inherited vendor-release warning in
`samples/cfa_demo/CMakeLists.txt`; the local fix commits are whitespace-clean.

Hardware validation is still required before treating padded P010/P210 RKRGA
paths as shipped.
