# Route B Runtime Validation

This is the hardware gate for the Route B patch series. Static checks prove the
patches apply, pass style, and build; they do not prove that RGA3 can now run
the scattered `virt_addr` cases that previously failed closed.

## Build A Forward-Port Test Kernel

Patch 0001 is the forward-port runtime artifact. Apply it to the current
forward-port tree first, then build from that patched source tree. Do not use
patch 0002 for this kernel; patch 0002 is rewrite-only.

Use a temporary git worktree so the source tree stays clean after the test.
`build-armbian-deb.sh` intentionally mutates the external Armbian build
workspace: it resets the generated userpatch archive, stages patches generated
from `KERNEL_TREE`, and disables the colliding built-in media patches for this
self-contained DT build. `KERNEL_TREE` must therefore name a source tree whose
final checked-out source already contains the Route B commit.

```bash
FW=/home/yi/Code/kernel/linux-6.18-rkvenc-av1-fwport
TEST=/tmp/rga-route-b-fw-runtime

git -C "$FW" worktree add "$TEST" HEAD
git -C "$TEST" am \
  /home/yi/Code/rock-5b-ysp/kernel-drivers/patches/route-b/0001-media-rockchip-rga3-map-scattered-userptr-through-IOMMU.patch

git -C "$TEST" log --oneline -1
if rg -n 'DIAG rga_dma_map_sgt|TEMP DIAGNOSTIC' "$TEST/drivers/video/rockchip/rga3"; then
  echo "unexpected temporary RGA diagnostics in final source"
  exit 1
fi

KERNEL_TREE="$TEST" \
PATCH_PREFIX=rk3588-av1-route-b \
STAGING=/tmp/rga-route-b-fw-runtime-patches \
  bash /home/yi/Code/rock-5b-ysp/kernel-drivers/scripts/build-armbian-deb.sh
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
PREPARED=/tmp/rga-route-b-fw-runtime-codex

git -C "$PREPARED" diff --quiet
git -C "$PREPARED" diff --cached --quiet
test "$(git -C "$PREPARED" rev-parse HEAD^)" = "$(git -C "$FW" rev-parse HEAD)"
git -C "$PREPARED" log --oneline -1
if rg -n 'DIAG rga_dma_map_sgt|TEMP DIAGNOSTIC' "$PREPARED/drivers/video/rockchip/rga3"; then
  echo "unexpected temporary RGA diagnostics in final source"
  exit 1
fi
```

The reproducible worktree flow above is the source of truth. Do not build from a
prepared tree whose parent is not the current forward-port `HEAD`.

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

After booting the Route B kernel:

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
  were already working before Route B.
- `rga-mmu-debug.sh` exits 0 with every row in `summary.tsv` reporting `pass`.
- The per-case filtered dmesg files contain no new `INTR[0x2]`, page fault, bus
  error, or `finished N failed M` RGA fault signature.

The commands above prove the user-visible behavior and fault-free regression
surface. They do not, by themselves, prove that the silent Route B fallback path
was taken. To claim Route B itself is runtime-proven, capture route-specific
evidence for at least one selected case, for example a one-run temporary debug
print/counter in `rga_dma_map_sgt_iommu()` showing a fallback mapping, along with
the same case passing without RGA/IOMMU faults. If this evidence is missing,
record the result as a behavioral pass, not as Route B fallback proof.

Record the printed `rga-mmu-debug` artifact directory, the installed PHASH, and
`uname -a` in a new dated finding if this passes.

## Rewrite Runtime Gate

Patch 0002 applies to both rewrite trees, but the rewrite still needs a booted
kernel profile before Route B can be runtime-proven there. When a rewrite kernel
with patch 0002 is booted, run at minimum:

```bash
cd /home/yi/Code/rock-5b-ysp

sudo PROFILE=rewrite \
  RGA_REQUIRED_CASES='ysp_librga_smoke rga_copy_demo rga_resize_rect_demo rga_transform_rotate_demo' \
  bash kernel-drivers/tests/librga-suite.sh

sudo PROFILE=rewrite \
  RUN_SYSTEM_INFO=0 RUN_ABI_REPLAY=0 RUN_MPP_SUITE=0 \
  RUN_GSTREAMER_SUITE=0 RUN_FFMPEG_SUITE=0 RUN_LIBRGA_SUITE=1 \
  RUN_COUNTER_CHECKS=1 \
  RGA_REQUIRED_CASES='ysp_librga_smoke rga_copy_demo rga_resize_rect_demo rga_transform_rotate_demo' \
  bash kernel-drivers/tests/rewrite-conformance-run.sh
```

Pass criteria:

- all selected librga cases pass;
- `ysp_librga_smoke` artifacts remain deterministic against the selected
  forward-port baseline where comparable;
- rewrite debugfs counter deltas show RGA hardware starts and busy time;
- dmesg has no new RGA/IOMMU fault signature.

## Completion Rule

Route B is complete only after the forward-port runtime gate passes on RK3588
hardware and includes route-specific evidence that the fallback executed for at
least one selected scattered userptr case. Rewrite runtime evidence is still
required before promoting patch 0002 from build-verified parity to
runtime-proven parity.
