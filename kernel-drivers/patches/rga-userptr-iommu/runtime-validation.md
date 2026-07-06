# RGA userptr-IOMMU fallback Runtime Validation

This is the hardware gate for the RGA userptr-IOMMU fallback patch series. Static checks prove the
patches apply, pass style, and build; they do not prove that RGA3 can now run
the scattered `virt_addr` cases that previously failed closed.

## Build A Forward-Port Test Kernel

Patch 0001 is the forward-port runtime artifact. Build from a source tree whose
checked-out commit already contains that patch, or apply patch 0001 to a
pre-RGA-userptr-IOMMU base worktree first. Do not apply patch 0001 a second time on top of
a RGA-userptr-IOMMU branch. Do not use patch 0002 for this kernel; patch 0002 is
rewrite-only.

There are two useful forward-port source profiles:

- **RGA-userptr-IOMMU-only:** the publishable branch has RGA userptr-IOMMU fallback without temporary
  diagnostics. It is the right profile for normal kernel builds and GitHub
  publication. Its runtime artifacts prove behavior and absence of faults, but
  they do not identify which import entered the silent fallback.
- **Debug tip:** the local development branch can keep temporary diagnostic
  commits above RGA userptr-IOMMU fallback. Build this profile only when you need direct fallback
  attribution from a one-run breadcrumb/counter. Keep those commits at the tip so
  they can be dropped cleanly before publishing.

Use a temporary git worktree so the source tree stays clean after the test.
`build-armbian-deb.sh` intentionally mutates the external Armbian build
workspace: it resets the generated userpatch archive, stages patches generated
from `KERNEL_TREE`, and disables the colliding built-in media patches for this
self-contained DT build. `KERNEL_TREE` must therefore name a source tree whose
final checked-out source already contains the RGA userptr-IOMMU fallback commit.

The local forward-port tree state recorded on 2026-07-05 was:

```text
rkvenc-fwport-6.18-rga-userptr-iommu           clean RGA userptr-IOMMU fallback, tip 2b52e8174c12
rkvenc-fwport-6.18                   RGA userptr-IOMMU fallback plus temporary DIAG commits
rkvenc-fwport-6.18-rga-userptr-iommu-debug-tip RGA userptr-IOMMU fallback plus temporary DIAG commits
```

For a normal clean RGA-userptr-IOMMU-only build, use the RGA-userptr-IOMMU branch directly:

```bash
FW=/home/yi/Code/kernel/linux-6.18-rkvenc-av1-fwport
TEST=/tmp/rga-userptr-iommu-fw-runtime

git -C "$FW" worktree add "$TEST" rkvenc-fwport-6.18-rga-userptr-iommu

git -C "$TEST" log --oneline -1
if rg -n 'DIAG rga_dma_map_sgt|TEMP DIAGNOSTIC' "$TEST/drivers/video/rockchip/rga3"; then
  echo "unexpected temporary RGA diagnostics in final source"
  exit 1
fi

KERNEL_TREE="$TEST" \
PATCH_PREFIX=rk3588-av1-rga-userptr-iommu \
STAGING=/tmp/rga-userptr-iommu-fw-runtime-patches \
  bash /home/yi/Code/rock-5b-ysp/kernel-drivers/scripts/build-armbian-deb.sh
```

If you are starting from a pre-RGA-userptr-IOMMU base instead of the prepared local branch,
apply patch 0001 once in that temporary worktree before running the same
`KERNEL_TREE=... build-armbian-deb.sh` command:

```bash
BASE=backup/rkvenc-fwport-6.18-before-rga-userptr-iommu-20260705-180636

git -C "$FW" worktree add "$TEST" "$BASE"
git -C "$TEST" am \
  /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/rga-userptr-iommu/0001-media-rockchip-rga3-map-scattered-userptr-through-IOMMU.patch
```

The build script regenerates the Armbian userpatches from `KERNEL_TREE`, disables
the self-contained-DT collisions, builds the debs, and prints the `P####-C####`
hash. Install that exact build:

```bash
sudo PHASH='P####-C####' \
  bash /home/yi/Code/rock-5b-ysp/kernel-drivers/scripts/install-combined-kernel.sh
sudo reboot
```

A previously prepared patched tree may be used instead of `$TEST` only if all of
these checks pass:

```bash
PREPARED=/tmp/rga-userptr-iommu-fw-runtime-codex

git -C "$PREPARED" diff --quiet
git -C "$PREPARED" diff --cached --quiet
git -C "$PREPARED" log --oneline -1
git -C "$PREPARED" merge-base --is-ancestor 2b52e8174c12 HEAD
if rg -n 'DIAG rga_dma_map_sgt|TEMP DIAGNOSTIC' "$PREPARED/drivers/video/rockchip/rga3"; then
  echo "unexpected temporary RGA diagnostics in final source"
  exit 1
fi
```

The reproducible worktree flow above is the source of truth. Do not build a
clean RGA-userptr-IOMMU-only image from a prepared tree that lacks the RGA userptr-IOMMU fallback commit or
contains the temporary diagnostic commits.

After the test, remove the temporary worktree:

```bash
git -C "$FW" worktree remove "$TEST"
```

If you are done with this build profile, restore the Armbian built-in patch
archive and clear generated userpatches before switching to another kernel
build:

```bash
bash /home/yi/Code/rock-5b-ysp/kernel-drivers/scripts/build-armbian-deb.sh --restore
```

## Forward-Port Runtime Gate

After booting the RGA userptr-IOMMU fallback kernel:

```bash
cd /home/yi/Code/rock-5b-ysp

sudo bash kernel-drivers/scripts/validate-combined.sh

bash kernel-drivers/tests/librga-smoke.sh

sudo env RGA_FAIL_ON_CASE_FAILURE=1 \
  RGA_CASES='rga_copy_demo rga_resize_rect_demo rga_transform_rotate_demo' \
  bash kernel-drivers/tests/rga-mmu-debug.sh
```

Pass criteria:

- `validate-combined.sh` sees `/dev/rga`, `/dev/mpp_service`, and the expected
  cores without probe-time RGA/IOMMU faults.
- `librga-smoke.sh` exits 0 and still covers the maintained im2d paths that
  were already working before RGA userptr-IOMMU fallback.
- `rga-mmu-debug.sh` exits 0 with every row in `summary.tsv` reporting `pass`.
- The per-case filtered dmesg files contain no new `INTR[0x2]`, page fault, bus
  error, or `finished N failed M` RGA fault signature.

The commands above prove the user-visible behavior and fault-free regression
surface. They do not, by themselves, prove that the silent RGA userptr-IOMMU fallback path
was taken. To claim RGA userptr-IOMMU fallback itself is runtime-proven, capture route-specific
evidence for at least one selected case, for example a one-run temporary debug
print/counter in `rga_dma_map_sgt_iommu()` showing a fallback mapping, along with
the same case passing without RGA/IOMMU faults. If this evidence is missing,
record the result as a behavioral pass, not as RGA userptr-IOMMU fallback proof.

Record the printed `rga-mmu-debug` artifact directory, the installed PHASH, and
`uname -a` in a new dated finding if this passes.

## 2026-07-05 RGA-userptr-IOMMU-Only Smoke Evidence

The installed test image was:

```text
Linux rock-5b 6.18.38-current-rockchip64 #14 SMP PREEMPT Sat Jul  4 11:44:22 UTC 2026 aarch64 GNU/Linux
```

`strings /boot/vmlinuz-6.18.38-current-rockchip64` found RGA userptr-IOMMU fallback strings
(`driver-owned IOMMU`, `iommu_dma_get_iova_domain`) and did not find the
temporary `DIAG rga_dma_map_sgt` string. That means this was a clean
RGA-userptr-IOMMU-only image, not the debug-tip image.

Repeated `rga-mmu-debug.sh` runs all passed:

```text
../rockchip-conformance/logs/rga-mmu-debug/20260705-182754
../rockchip-conformance/logs/rga-mmu-debug/20260705-182758
../rockchip-conformance/logs/rga-mmu-debug/20260705-182801
../rockchip-conformance/logs/rga-mmu-debug/20260705-182803
../rockchip-conformance/logs/rga-mmu-debug/20260705-182806
../rockchip-conformance/logs/rga-mmu-debug/20260705-182808
```

Each run selected:

```text
rga_copy_demo
rga_resize_rect_demo
rga_transform_rotate_demo
```

and each `summary.tsv` row reported `pass`. The filtered logs for these runs
contained no `DIAG rga_dma_map_sgt`, no `reject sg_table DMA mapping`, no
`INTR[0x2]`, no IOMMU page fault, and no `finished N failed M` fault signature
with `M > 0`.

The latest run also showed the expected RK3588 RGA hardware model:

```text
rga3, core 1 ... mmu: RK_IOMMU
rga3, core 2 ... mmu: RK_IOMMU
rga2, core 4 ... mmu: RGA_MMU
```

The RGA3 command dumps still printed internal command MMU bits as
`mmu: win0 = 00 win1 = 00 wr = 00`, which is expected for RGA3 using the
external RK_IOMMU. The same logs showed external IOVA handles such as
`iova = 0xdd800000, dma_addr = 0xdd800000, offset = 0x10` and jobs finishing as
`finished 1 failed 0`.

This is strong indirect evidence that RGA userptr-IOMMU fallback handled the selected scattered
`virt_addr` cases, because the earlier debug run at
`../rockchip-conformance/logs/rga-mmu-debug/20260705-151723` showed the same demo
family failing closed with non-contiguous `orig_nents == nents` mappings:

```text
orig_nents=895 nents=895 contiguous=0 gaps=894 ... reject sg_table DMA mapping
orig_nents=386 nents=386 contiguous=0 gaps=9   ... reject sg_table DMA mapping
orig_nents=367 nents=367 contiguous=0 gaps=306 ... reject sg_table DMA mapping
orig_nents=492 nents=492 contiguous=0 gaps=68  ... reject sg_table DMA mapping
orig_nents=390 nents=390 contiguous=0 gaps=367 ... reject sg_table DMA mapping
orig_nents=389 nents=389 contiguous=0 gaps=36  ... reject sg_table DMA mapping
```

Because the RGA-userptr-IOMMU-only image had no positive fallback breadcrumb, record this
as **behavioral smoke passed; direct RGA userptr-IOMMU fallback attribution still pending**.

## Rewrite Runtime Gate

Patches 0002 and 0003 apply to both rewrite trees, but the rewrite still needs a
booted kernel profile before RGA userptr-IOMMU fallback can be runtime-proven there. Patch 0003
adds the development-only `rk_rga_rewrite/userptr_iommu` debugfs directory used for
direct attribution. When a rewrite kernel with both patches is booted, run at
minimum:

```bash
cd /home/yi/Code/rock-5b-ysp

sudo PROFILE=rewrite \
  LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 \
  RGA_REQUIRED_CASES='ysp_librga_smoke rga_copy_demo rga_resize_rect_demo rga_transform_rotate_demo' \
  bash kernel-drivers/tests/librga-suite.sh

sudo PROFILE=rewrite \
  RUN_SYSTEM_INFO=0 RUN_ABI_REPLAY=0 RUN_MPP_SUITE=0 \
  RUN_GSTREAMER_SUITE=0 RUN_FFMPEG_SUITE=0 RUN_LIBRGA_SUITE=1 \
  RUN_COUNTER_CHECKS=1 \
  LIBRGA_FORCE_RGA_USERPTR_IOMMU=1 \
  RGA_REQUIRED_CASES='ysp_librga_smoke rga_copy_demo rga_resize_rect_demo rga_transform_rotate_demo' \
  bash kernel-drivers/tests/rewrite-conformance-run.sh
```

Pass criteria:

- all selected librga cases pass;
- `ysp_librga_smoke` artifacts remain deterministic against the selected
  forward-port baseline where comparable;
- rewrite debugfs counter deltas show RGA hardware starts and busy time;
- `/sys/kernel/debug/rk_rga_rewrite/userptr_iommu/attempt` and `ok` increase for at
  least one selected direct-virtual-address case, while `active` returns to 0 at
  rest;
- dmesg has no new RGA/IOMMU fault signature.

`LIBRGA_FORCE_RGA_USERPTR_IOMMU=1` makes the suite set the rewrite
`userptr_iommu/force_remap` debugfs knob for the run and restore its previous value at
exit. The conformance runner then adds `rga_userptr_iommu:attempt` and
`rga_userptr_iommu:ok` to the required positive counter set and requires
`rga_userptr_iommu:active` to be zero after the run, so a passing userspace case
cannot be mistaken for proof if it stayed on the normal DMA segment path or
leaked a RGA userptr-IOMMU fallback IOVA mapping.

## Completion Rule

Forward-port RGA userptr-IOMMU fallback has now passed the behavioral RK3588 smoke gate for the
selected scattered `virt_addr` demos. Direct forward-port fallback-path proof
still requires route-specific evidence that the fallback executed for at least
one selected case. Rewrite runtime evidence is still required before promoting
patches 0002/0003 from build-verified parity to runtime-proven parity.
