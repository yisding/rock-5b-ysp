# Forward-port 0096 rejects high contiguous USERPTRs before the RGA2 remap

> Scope: RK3588 forward-port RGA2 USERPTR admission and production
> conformance on the installed `0001`–`0096` kernel
> Source: booted `6.18.43-ysp-rockchip64`, package
> `6.18.43+rk3588av1fwport20260808-0ubuntu1~rk1`, run
> `20260811-141205-conformance-results.tsv`; fixed
> `rk3588-video-6.18@e7ff978398825`, `rga_mm.c`
> `rga_mm_lookup_rga2_support()` / `rga_mm_is_need_mmu()` /
> `rga_mm_get_buffer_info()`
> Date: 2026-08-11
> Trust: **MEASURED** / **CODE-INSPECTED** / **ROOT-CAUSED** /
> **BOOT-VERIFIED** / **FIX-COMPILE-VERIFIED** / **PACKAGE-VERIFIED** /
> **PARTIAL**

## Result

The published `0001`–`0096` forward-port package is installed and booted with
its matching YSP DTB. Production conformance passed system identity, target and
configuration identity, ABI replay, and all 12 required MPP cases. Librga then
passed 30 of 31 required cases but failed
`rga_cvtcolor_gray256_demo`, so the fail-fast top-level runner did not reach
GStreamer or FFmpeg.

This is a different failure boundary from the installed `0092` package.
Patch `0093` removed the earlier 2 MiB SG-entry rejection: the new kernel log
contains no `swiotlb buffer is full` or `dma_map_sg failed` line. Instead, the
gray256 job is rejected during core selection before mapping or hardware start:

```text
rga: ID[60]: no core match: core[0x4] skipped by the under-4G memory limit; retry with below-4G (e.g. CMA/DMA32) buffers
rga: ID[60]: failed to assign task 0
rga: ID[60]: job assign failed
```

The suite's kernel interval remains clean: 18 new lines, zero fatal matches,
and zero change in every captured RGA staging/leak counter. The official
sample's missing `/data/in0w1280-h720-rgba8888.bin` is not causal; it generates
fallback pixels, as in prior passing runs.

## Root cause

The official gray256 sample imports two multi-megabyte `malloc()` allocations
as virtual-address handles. A high USERPTR may nevertheless look physically
contiguous when its pages were allocated as a transparent huge page. The
initial handle import maps against the RGA3/IOMMU scheduler, records
`RGA_MEM_PHYSICAL_CONTIGUOUS`, and retains the pinned USERPTR pages.

`rga_mm_lookup_rga2_support()` tested that generic contiguous flag before its
`RGA_VIRTUAL_ADDRESS` case. It therefore classified the remappable USERPTR as
raw direct-address memory and set `RGA_JOB_UNSUPPORT_RGA_MMU`. Gray256 output
is RGA2-only on RK3588, so policy had no remaining core and returned
`-EOPNOTSUPP`. This also explains the apparent intermittency across older
runs: page placement and coalescing, not the `/data` fixture, determined
whether the mistaken contiguous branch fired.

Two downstream decisions had the same stale assumption. Even if policy
admitted the job, `rga_mm_is_need_mmu()` would disable the RGA2 MMU and
`rga_mm_get_buffer_info()` would select the high physical address directly.
All three sites must distinguish remappable virtual memory from raw physical
imports.

## Evidence

- **Identity:** installed image, DTB, and headers all report
  `6.18.43+rk3588av1fwport20260808-0ubuntu1~rk1`; `/boot/Image` and `/boot/dtb`
  select the corresponding `6.18.43-ysp-rockchip64` artifacts. Launchpad source
  publication `18663042` is Published, arm64 build `33479597` succeeded, and
  binary publications `247936299`–`247936301` are Published.
- **Exercise:** `sudo bash kernel-drivers/tests/run-conformance.sh`, production
  forward-port profile.
- **Pass/fail signal:** system, matrix identity, ABI, and MPP pass; librga fails
  only `rga_cvtcolor_gray256_demo`; overall exit 1 after 13.174 seconds.
- **Artifacts:** external run root
  `../rock-5b/build/rockchip-conformance/logs/forward-port/20260811-141205-*`.
  SHA-256: conformance result
  `6fc2d289101d17d3987096bc598358f46dbb1aa1896105735a7ffd4090ce64cf`;
  system snapshot
  `7c0622a180e28325fddbf6c4f5e74a4617282218a284b2241e0c824993547262`;
  librga summary
  `b18f7b6d2bb90132abf31da9ff4127a032e376a14e90e3ef14757068405541f3`;
  new dmesg
  `fb276f1bfa6c63dd150c17a33f541567848ce842d55ae9ba6992a12a2948ca56`.

## Fix

Forward-port patch `0097`, commit `e7ff978398825`, makes high contiguous
virtual imports follow the same transient RGA2 MMU path as scattered USERPTRs.
It changes all three decisions consistently:

- handle admission recognizes a pinned `RGA_VIRTUAL_ADDRESS` before rejecting
  raw high physical memory;
- RGA2 MMU selection remains enabled for high contiguous virtual imports; and
- address preparation uses the virtual handle path instead of programming the
  high physical address directly.

Below-4-GiB contiguous buffers retain their direct path. High raw physical
imports remain rejected, and high DMA-BUFs retain the alias-safe `0095` staging
path.

The exported patch passes `git diff --check` and strict `checkpatch.pl` with
zero errors, warnings, or checks. The complete production-config
`drivers/video/rockchip/rga3/` directory builds with arm64 GCC, central ccache,
`W=1`, and `WERROR=1`; `rga_mm.o` SHA-256 is
`95eecd9b951efebeef72c4a7816ef35cb8848f5c90cc4097533cfeda9f8be741`
and `built-in.a` is
`777b06995e8934c37b333728338ae5a53a367c17d2952e542add9aaf5750ce69`.

Exact `0001`–`0097` is also packaged on Linux 6.18.44 as
`6.18.44+rk3588av1fwport20260811-0ubuntu1~rk1`. The signed source passed
`dscverify`, fresh extraction, package-version/config checks, and direct GPG
verification; extracted `rga_mm.c` is byte-identical to `e7ff978398825`.
`dput --check-only` passed and `dput` transferred all five artifacts at 17:30
PDT. An immediate exact-version Launchpad API query returned no source record,
then a later recheck found exact source publication `18669946` in `Pending`
state. Archive acceptance is confirmed; the arm64 build, binary publication,
installation, boot, and runtime remain unverified. The package owner records
the signed hashes and upload marker in the
[PPA kernel record](../packaging/ppa/kernel-forward-port/README.md).

## Verification gate

Confirm the arm64 build and publication, then install and boot exact
`0001`–`0097` with a recovery kernel retained. First run
`rga_cvtcolor_gray256_demo` repeatedly and require every
iteration to pass with no under-4-GiB policy rejection, SWIOTLB mapping failure,
IOMMU fault, warning, or non-zero residual counter. Then rerun the other two
historically intermittent RGA2-only USERPTR cases
(`rga_transform_center_rotate_demo` and `rga_rop_demo`) and the full production
conformance matrix.

The remaining `0095` DMA-BUF alias/staging, RGA/MPP ownership,
provider-fault-admission, hard-CCU fallback, sanitizer/lockdep, hostile,
root-counter, and display gates remain separate requirements.

## Boundary

The `0001`–`0096` package has boot and partial functional evidence, but its
complete production conformance result is red. Patch `0097` is source-, style-,
compile-, and signed-source-package verified on Linux 6.18.44 and is
accepted as Pending source publication `18669946`. No Launchpad build, binary
publication, boot, or runtime result is verified.
This result does not validate GStreamer, FFmpeg, sanitizer behavior, DMA-BUF
staging aliases, concurrent SWIOTLB pressure, or fault recovery on the new
tail.
