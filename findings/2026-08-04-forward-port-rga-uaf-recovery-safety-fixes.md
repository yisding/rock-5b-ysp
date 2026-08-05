# Forward-port 0090–0092 close the RGA job-task and decoder recovery lifetime gaps

> Scope: forward-port kernel RGA, MPP fault handling, and RKVDEC2 recovery;
> `docs/support-coverage.md` C02/C03.
> Source: `../rock-5b/kernel/linux-6.18-rkvenc-av1-fwport`, branch
> `rk3588-video-6.18@7d53bc7a3adc3`; Rockchip comparison
> `develop-6.1@b4ef083dc0c3`.
> Date: 2026-08-04
> Trust: **SOURCE-INSPECTED** / **SOURCE-CONFIRMED** /
> **FIX-COMPILE-VERIFIED** / **PARTIAL**

## Result

> **Subsequent runtime update, 2026-08-04:** the source-only boundary recorded
> below has been superseded for publication, install, boot, and
> production-profile runtime. Exact `0092` and all three arm64 binaries are now
> Published; the image, DTB, and headers are installed and booted, and the broad
> functional/recovery campaign is green. Exact-tail KASAN/lockdep and the
> remaining targeted hostile paths are still open. See the
> [production validation finding](2026-08-04-forward-port-6-18-42-0092-production-validation.md).

The maintained forward-port source and exported series now end at `0092`.
Three commits close the remaining non-unbind lifetime/recovery items from the
[2026-08-01 audit](2026-08-01-forward-port-uaf-oops-audit-round-2.md):

- `4081e39e87125` / `0090` makes every RGA job own a private snapshot of its
  task list. Cancellation can free the request without leaving the completing
  IRQ with a borrowed pointer. RGA2 OSD result fields are copied back only in
  `rga_request_release_signal()`, while the request has a live kref and its
  lock is held; `task_start` preserves the mapping for parallel jobs.
- `552a9eea6aab5` / `0091` invokes Rockchip and VSI provider callbacks while
  holding their `fault_lock`. Clearing a handler/token through the same lock is
  therefore a non-sleeping callback-quiescence barrier. Generic MPP and both
  RKVENC2 fault-handler arms inspect `cur_task` under `running_lock`; the full
  provider-IRQ synchronization helper remains for device teardown.
- `7d53bc7a3adc3` / `0092` leaves a timed-out or aborted soft-CCU decoder task
  and its core busy until reset has stopped hardware access. Completed sibling
  tasks can still retire; after no healthy task remains, reset runs and only
  then releases the failed task. Soft- and hard-CCU reset paths claim queue and
  per-core reset requests with `atomic_xchg()` before reset, so a request raised
  during reset remains pending. The link-mode IOMMU task dump also stays under
  `running_lock` for the complete walk.

The decoder retirement/reset-request shapes and the unlocked generic,
RKVENC2, and link-mode fault-task reads are present in Rockchip
`develop-6.1@b4ef083dc0c3`. The provider callback/token hook is a 6.18
forward-port adaptation. The RGA multi-task borrowed-list shape came from the
later vendor batching import; Rockchip's inspected `develop-6.1` branch still
stores a single task by value and does not have that exact layout.

## Evidence and reproduction

- **Identity:** 92 commits on `v6.18`; tip `7d53bc7a3adc3`.
- **Style:** `git diff | ./scripts/checkpatch.pl --no-tree --strict -` returned
  zero errors, warnings, and checks before the commits were recorded.
- **Build:** a clean detached worktree at the exact tip used external output
  directory
  `/home/yi/Code/rock-5b/build/kernel/uaf-recovery-safety-20260804`, the
  existing forward-port arm64 configuration, Ubuntu GCC 15.2, and ccache. The
  build completed with exit status 0 and no diagnostics. For reproduction, use
  the repository's sole cache store as shown here:

  ```sh
  CCACHE_DIR=/home/yi/Code/.ccache \
    make -j8 W=1 \
      O=/home/yi/Code/rock-5b/build/kernel/uaf-recovery-safety-20260804 \
      ARCH=arm64 CROSS_COMPILE='ccache aarch64-linux-gnu-' \
      drivers/iommu/rockchip-iommu.o \
      drivers/iommu/vsi-iommu.o \
      drivers/video/rockchip/mpp/mpp_iommu.o \
      drivers/video/rockchip/mpp/mpp_rkvenc2.o \
      drivers/video/rockchip/mpp/mpp_rkvdec2_link.o \
      drivers/video/rockchip/rga3/rga_job.o
  ```

- **Series:** `git format-patch --no-signature` exported the three commits as
  contiguous `0090`–`0092` in `kernel-drivers/patches/forward-port-rk3588/`.
- **Artifacts:** build objects remain in the external disposable build
  directory; no binary or raw runtime artifact is committed here.

## Boundary at the source-only checkpoint

This is source inspection and affected-object compilation, not runtime proof.
Exact source package `6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1` now exists
without a local kernel build. Patch-only staging first caught and refused stale
rewrite build directories; after exact cleanup, full-tree comparison against
the Published orig differed only in the expected eight files, and a fresh
`.dsc` extraction byte-matched all eight to tip `7d53bc7a3adc`. Launchpad
Published source publication `18656958`; remote arm64 build `33467257`
completed successfully in 41m44s. At this checkpoint, before binary ingestion
and the later production run, none of these patches had booted on the ROCK 5B
and the Published/booted binary remained the `0089` / `7615b69a744af`
predecessor. That was the correct boundary for this source-inspection result;
the later production finding linked above now owns the booted
functional/recovery verdict.

The patch closes soft-CCU failed-task retirement. It does not claim a new
hard-CCU task-retirement result, and it does not address the root-only MPP/RGA
unbind lifetime items deliberately left outside this change.

## Verification gate

The publication/install/boot and broad production-profile campaign are now
complete in the later production finding. The remaining source-tail gate is to
exercise exact `0092` with KASAN/lockdep through the existing RGA
cancellation/session-close and decoder recovery/reset-contention coverage,
retain a fatal-journal scan, and run the remaining targeted hostile/ownership
paths. The strict decode fd-span oracle, root-only counters, and authenticated
RDP/display integration remain separate qualification gaps.
