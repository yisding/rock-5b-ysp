# Debugging plan: `ysp_librga_smoke` regressed between 2026-07-21 and 2026-08-01

> Scope: RGA rewrite driver (`drivers/video/rockchip/rga-rewrite/rga_rewrite.c`)
> on the handle-import submit path.
> Status: **plan, not a finding** — the failure is reproduced and localized to a
> window of commits, but no root cause is established.
> Observed on: `6.18.41-video-rewrite-kasan-rockchip64 #27`,
> `rk3588-rewrite-6.18 @ b37f6e9825b1`, conformance run
> `20260801-161134-librga-suite`.
> Date: 2026-08-01

## What actually failed

`ysp_librga_smoke` fails on its **first** operation — a 128×128 RGBA8888
`imcopy()` between two imported dma-buf handles:

```
librga:  src | raster( 0x1) | 0, 0, 0, 0 | 128, 128, 128, 128 | rgba8888( 0) | 0x1, 0, 0, 0
librga:  dst | raster( 0x1) | 0, 0, 0, 0 | 128, 128, 128, 128 | rgba8888( 0) | 0x2, 0, 0, 0
imcopy failed: Fatal error: Failed to call RockChipRga interface
```

Three facts pin the shape of it:

1. **The buffers are CMA-backed.** `dmabuf_alloc_any()` in `librga-smoke.cpp`
   walks a heap preference list; the first three entries
   (`system-uncached-dma32`, `system-dma32`, then `default_cma_region`) resolve
   on this board to **`/dev/dma_heap/default_cma_region`**, because the dma32
   heaps do not exist on an upstream-style kernel. So this is the *contiguous*
   import path, not the fragmented one.
2. **Import succeeds; submit fails.** `importbuffer_fd()` returned handles
   `0x1` and `0x2`. The same conformance run's ABI probe independently shows
   `RGA_IOC_IMPORT_BUFFER` and `RGA_IOC_REQUEST_CONFIG` returning 0 with
   imported handles. Only the submit is untested there, and only the submit
   fails here.
3. **The rejection is silent.** `dmesg-new.txt` and `dmesg-fatal.txt` are both
   **0 bytes** for the whole suite. `rk_rga_check_dma_sgt()` (~:2043) logs two
   of its reject branches via `pr_err` but returns `-EINVAL` unlogged from two
   others, so a silent path exists and was taken.

## What is already excluded

- **Not the reset-domain lock.** `git show --name-only b37f6e9825b1` touches
  exactly one file, `mpp_rewrite.c`. No RGA source is in that commit.
- **Not the missing dma-heaps.** The other 14 suite failures are
  `open /dev/dma_heap/system-uncached{,-dma32} fail!` — samples dying before
  they reach `/dev/rga`. Those same cases failed identically on the 2026-07-21
  run and are environmental. `ysp_librga_smoke` is the only case that
  **passed on 2026-07-21 and fails now**.
- **Probably not the multi-SG defect.** The
  [multi-SG finding](../../../findings/2026-07-31-rga-rewrite-multisg-dmabuf-cma-einval.md)
  concerns fragmented *system-heap* imports. This allocation is CMA. That same
  finding, however, flags a **CMA `EINVAL` branch that it explicitly leaves
  untraced and marks HYPOTHESIS** — which is exactly the path this lands on, so
  it is the closest existing lead.

## Plan

Ordered by cost. Each kernel build is ~40 minutes, so builds come last and only
if the cheap steps have not answered it.

### Phase 0 — reproduce in seconds, without the suite

`rga-core-match-test` takes explicit backing for each side
(`<src_spec> <dst_spec> <dim> [alloc_mb]`, where a spec is a dma-heap path or
`malloc`), which is precisely the variable in question:

| Command | Question it answers |
|---|---|
| `rga-core-match-test /dev/dma_heap/default_cma_region /dev/dma_heap/default_cma_region 128` | Does the smoke's exact backing fail on its own? |
| `... /dev/dma_heap/system /dev/dma_heap/system 128` | Is it CMA-specific or all dma-buf imports? |
| `... malloc malloc 128` | Does the userptr path still work? |
| `... /dev/dma_heap/default_cma_region /dev/dma_heap/default_cma_region 64` | Below RGA3's 68-px floor — forces RGA2, separating core selection from import |

Mixed specs (`default_cma_region` → `system` and the inverse) isolate whether it
is the source or destination leg. Build the probes with
`build-librga-samples-full.sh`; `librga-smoke.sh` builds and runs the smoke on
its own if you want just that case.

**Also worth one run:** `rga_copy_demo` **passes** in the same suite. Diffing
its buffer setup against the smoke's is free and may isolate the variable
immediately.

### Phase 1 — get the errno, still without a rebuild

`strace` gives the failing ioctl and its errno directly, which maps to a
specific reject branch:

```
sudo strace -f -e trace=ioctl -o /home/yi/Code/tmp/rga-smoke.strace <smoke binary>
grep -E 'RGA|0x5017|72(05|06|07)' /home/yi/Code/tmp/rga-smoke.strace | tail -20
```

Expect `RGA_IOC_REQUEST_SUBMIT` (`0xc0987206`) returning `-1`. The errno
discriminates: `EINVAL` points at the unlogged branches of
`rk_rga_check_dma_sgt()`; `EOPNOTSUPP` at the non-adjacent-segment branch (which
*does* log, so it would contradict the silent dmesg); `ENODEV`/`EBUSY` at core
selection in `rk_rga_task_hw_type_mask()`.

### Phase 2 — make the driver say why

The existing `rga-mmu-debug.sh` enables `/sys/kernel/debug/rkrga`
`reg msg int mm time`, brackets the run with kmsg markers, and captures
before/after dmesg plus debugfs snapshots. It was written for the 2026-07-04
`INTR[0x2]` hunt and fits this exactly. Pair it with an RGA debugfs counter
delta to see which counter moves (rejected vs import vs job).

### Phase 3 — source-inspect the named branch

Candidate sites, in the order the submit path reaches them:

| Symbol | Line | Why it is a candidate |
|---|---:|---|
| `rk_rga_job_map_import()` | ~4700 | maps the import for the job; calls the SG checks |
| `rk_rga_check_dma_sgt()` | ~2043 | has two **unlogged** `-EINVAL` returns |
| `rk_rga_check_dma_sgt_coverage()` | ~2089 | size/coverage rejection |
| `rk_rga_job_prepare_hw_mappings()` | ~22671 | per-HW mapping preparation |
| `rk_rga_task_hw_type_mask()` | ~22855 | core eligibility; returning an empty mask fails the job |

### Phase 4 — bisect, only if Phases 0–3 have not answered it

Six rga-rewrite commits land in the 2026-07-21 → 2026-08-01 window. Ranked by
suspicion:

1. **`66ae8c0f03f5`** *"harden userspace-driven import and fence paths"* —
   hardening is by definition the addition of new rejections, and this is the
   import path.
2. **`995a0aa710fb`** *"add RGA2 multi-SG MMU"* — 887 insertions, and it is the
   fix whose own finding is marked `RUNTIME-UNVERIFIED`; large changes to the
   mapping path can regress the contiguous case while fixing the fragmented one.
3. **`ac8c4433c7a1`** *"keep the power domain on across IOMMU work"*.
4. `29904d8e2fa4`, `cd71f985a784`, `35eb735d21dd` — fixture/review changes,
   lower prior.

**Bisect by reverting onto the current tip, not by checking out old trees.** A
revert keeps every other fix in place, so a pass identifies the culprit without
also un-fixing the multi-SG and AFBC work — and the resulting kernel is one
commit from shippable rather than ten days behind.

### Phase 5 — cross-check the forward-port driver

The forward-port kernel carries an independent RGA implementation. Booting it
and running `librga-smoke.sh` costs a reboot and no build. A pass there confirms
the defect is rewrite-specific; a failure would point at librga or the board
configuration instead and would invalidate most of the plan above.

## Worth doing regardless of the outcome

**The silent `-EINVAL` is its own defect.** A submit path that rejects a job
with no log entry is why this took a full conformance run to notice and will
cost time on every future occurrence. Adding a rate-limited `dev_err` (or
routing these through the existing debug event ring, as the MPP rewrite does for
its IRQ statuses) is a small change that pays for itself the next time — and it
would likely have answered this question at Phase 0.

## Non-goal

This should not block the reset-domain-lock work, which is verified and green
on both the statistical gate and the MPP conformance suite. The RGA regression
predates the lock by roughly ten days and is independent of it.
