# Rust counterfactual for the RGA clean-room rewrite: wrong call in 2026, right call once dma-buf/fence/IOMMU abstractions land

> Scope: retrospective language-choice assessment for the RGA clean-room
> rewrite (`kernel-drivers` rewrite track), prompted by the July 2026 pile of
> use-after-free findings in the kernel forward-port work
> Source: `linux-6.18-rkvenc@0d71ded1690c`
> (`drivers/video/rockchip/rga-rewrite/rga_rewrite.c`, `rust/kernel/` at
> v6.18-237); `linux@32696e87c9c7` (`rust/kernel/` at v7.2-rc2-226); the
> 2026-07 findings ledger in this directory
> Date: 2026-07-21
> Trust: **CODE-INSPECTED** for the API-surface counts, the Rust-abstraction
> inventory, and the crash-ledger provenance; **INFERRED** for the verdict;
> **UNVERIFIED** for the DKMS-Rust tooling claim

## Result

Question: given that so many July 2026 crashes were lifetime bugs
(use-after-free, double-free, NULL-deref), should the completed clean-room RGA
rewrite have been written in Rust instead of C? Verdict: **no for this driver
at this kernel generation — and the reasoning identifies when that flips.**

Three grounds:

**1. The crash ledger indicts the vendor forward-port, not the rewrite.**
Every 2026-07 KASAN/oops lifetime finding is in the vendor-code track —
`rga_job.c` request-completion vs session-close
([2026-07-21](./2026-07-21-rga-request-completion-vs-session-close-uaf-kasan.md),
[2026-07-17](./2026-07-17-rga-session-close-uaf.md)), the MPP reset-session
DMA double-free
([2026-07-18](./2026-07-18-mpp-reset-session-dma-double-free-kasan.md)), the
rkvenc2 wait-result task UAF
([2026-07-18](./2026-07-18-rkvenc2-wait-result-task-uaf-kasan.md),
forward-port-introduced), the client-less session NULL-deref
([2026-07-21](./2026-07-21-mpp-collect-msgs-clientless-session-null-deref-crash.md)),
and the procfs session-teardown oops
([2026-07-17](./2026-07-17-mpp-procfs-session-teardown-oops.md)). The rewrite
appears in the ledger only as the **reference model** (the per-core DMA-mask
pattern cited by
[2026-07-21-rga2-dma-api-ownership](./2026-07-21-rga2-dma-api-ownership-and-over-4g-scope.md)).
A greenfield C design with an explicit ownership/mapping/scheduling/IRQ model
— which the rewrite is, per
[`../kernel-drivers/rga/docs/rewrite-5.10-reconciliation.md`](../kernel-drivers/rga/docs/rewrite-5.10-reconciliation.md)
(vendor fixes could not even be cherry-picked across the model difference) —
already averted the bug class. Rust's marginal value over that is
machine-checking the discipline instead of trusting convention: real (the
rkvenc2 UAF shows hand-ported C slips ordering), but far smaller than the
Rust-vs-vendor-C gap the crash pile suggests at first glance.

**2. The rewrite's center of gravity sits exactly in the subsystems Rust
cannot yet express safely.** Measured on `rga_rewrite.c` (20,048 lines,
single file — essentially the same size as the vendor rga3 at ~20.9k):
201 lines mention `iova`, 172 `iommu_`, 138 `dma_fence`, 28 `dma_buf`,
4 `pin_user_pages`, plus an internal-API `#include <linux/dma-map-ops.h>`.
Against that, `rust/kernel/` at the v6.18 pin provides platform/OF,
miscdevice, ioctl, irq, clk, regulator, coherent DMA (`dma.rs`),
scatterlist, mm, uaccess, workqueue, and sync — the driver *chassis* — but
**no dma-buf, no dma-fence, no iommu, no iova, no userptr pinning**. Even the
v7.2-rc2 pin only adds `iommu/pgtable.rs` (io-pgtable, the Tyr-driven work)
and DRM gem/gpuvm; `grep dma_fence rust/ → 0`. A 2026 Rust rewrite would have
meant hand-writing thousands of lines of unsafe bindings *underneath* the
lifetime-critical import/mapping/fence layer — the compiler blind exactly
where the sharp edges are — while the safe-Rust fraction (ioctl parsing,
session bookkeeping, scheduling) covers the parts the C design was not
getting wrong. The binding work would have displaced the actual value of the
rewrite: the contract archaeology recorded in
[the maintained import contract](../kernel-drivers/rga/docs/userptr-iommu.md),
[the BSP scatter contract](../kernel-drivers/patches/rga-userptr-iommu/architecture.md),
and [2026-07-21-rga-forward-port-abi-gaps](./2026-07-21-rga-forward-port-abi-gaps.md).

**3. Shipping constraints.** The rewrite is carried on three branches
(`rk3588-rewrite-6.18`, `-armbian-6.18.38`, `-armbian-7.2-rc3`); the kernel's
Rust APIs are explicitly unstable and churn per release, so each branch-sync
would cost more than the C does. And the kernel-drivers DKMS distribution
path has effectively no Rust story today (target machines would need a
matching rustc/bindgen per kernel).

**When the calculus flips:** once dma-buf/dma-fence/IOMMU-attach abstractions
mainline (the Nova/Tyr/Asahi GPU drivers are dragging them in; io-pgtable is
already there at 7.2), a Rust port becomes the ideal-shape project — the
existing rewrite is a known-good reference implementation and the
`tests/conformance` suite is the oracle, which is precisely the setup where
Rust rewrites succeed. The same logic applies with more force to any future
clean-room MPP service: that is where the vendor lifetime bugs actually live
([2026-07-16-rockchip-bsp-driver-quality](./2026-07-16-rockchip-bsp-driver-quality.md)
rates the BSP D on hostile-input robustness), and it is also the driver whose
platform entanglements (power domains, resets, SRAM, per-codec churn) will
take longest to gain Rust coverage.

## Evidence and reproduction

- **Identity:** code-only. `linux-6.18-rkvenc@0d71ded1690c` and
  `linux@32696e87c9c7` (both trees local under `../rock-5b/kernel/`), plus this
  directory's 2026-07 findings.
- **Exercise:** `wc -l rga_rewrite.c`; `grep -c` per subsystem prefix on
  `rga_rewrite.c`; `ls rust/kernel/` on both pins;
  `grep -rl dma_fence\|dma_buf rust/kernel/`; provenance grep of
  `findings/*.md` for KASAN/UAF/double-free vs rewrite mentions.
- **Pass/fail signal:** counts as stated above; zero crash findings name the
  rewrite track; the one provenance-checked UAF marked
  "forward-port-introduced" is rkvenc2 wait-result.
- **Artifacts:** none.

## Boundary

Absence from the crash ledger is not absence of bugs: the rewrite has not
been through a systematic KASAN + syzkaller sweep of its ioctl surface, and
this note does not claim it is UAF-free — only that its measured crash record
contradicts "our UAFs argue for Rust" as applied to it. The Rust-for-Linux
inventory was checked only against the two local pins, not lkml series or
out-of-tree work (Asahi carries dma-fence/dma-buf Rust code that is not
mainline). The DKMS-Rust claim is from general tooling knowledge, not tested.
No attempt was made to estimate the binding-layer effort quantitatively.

## Why it matters / follow-up

Closes the "should we have used Rust" question without scheduling a redo, and
records the trigger condition for revisiting: **when `rust/kernel/` gains
dma-buf + dma-fence + IOMMU-attach abstractions, re-evaluate a Rust port of
RGA (reference implementation + conformance oracle already in hand) and treat
a Rust MPP-service rewrite as the higher-value target.** Near-term, the cheap
80% of the safety benefit for the C code stands: written ownership-model doc,
kref/completion audit of remaining paths, KASAN kept in the validation loop,
syzkaller on the `/dev/rga` + `/dev/mpp_service` ioctl surface.
