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

## Boundary

This is source inspection and affected-object compilation, not runtime proof.
No `0092` kernel package exists yet, none of these patches has booted on the
ROCK 5B, and no cancellation, IOMMU-fault, timeout, concurrent-reset, KASAN, or
lockdep gate has exercised the new paths. The Published and booted production
package remains the `0089` / `7615b69a744af` build; its runtime evidence does
not transfer to this source tail.

The patch closes soft-CCU failed-task retirement. It does not claim a new
hard-CCU task-retirement result, and it does not address the root-only MPP/RGA
unbind lifetime items deliberately left outside this change.

## Verification gate

Package and boot the exact `0092` tip with KASAN/lockdep, then run the existing
RGA cancellation/session-close coverage and decoder recovery/reset-contention
gates with a fatal-journal scan. A production-profile build should then repeat
the current-package MPP/FFmpeg, librga/RGA, GStreamer, ABI, RDP-encode, and soak
campaign before this tail is described as wider-audience ready.
