# AV1 rewrite adversarial validation

Date: 2026-07-26
Kernel tree: `/home/yi/Code/kernel/linux-6.18-rk-av1-rewrite`
Branch: `rk3588-rewrite-av1-6.18`
Validated/fixed tip: `e58c57e50d0a0caa5a90535712e3081c7649d2f2`

## Verdict

Three independent read-only reviews attacked the AV1 rewrite from concurrency
and lifetime, ABI/DMA-boundary, and backend/oracle/test-coverage perspectives.
They found five confirmed correctness or containment gaps. Commit
`e58c57e50d0a0` fixes all five and adds discriminating KUnit coverage:

1. A VSI IOMMU fault masks the provider exception source. The MPP fault worker
   reset/completed the job without refreshing VSI, so later faults could remain
   invisible until a timeout. Recovery now refreshes after DMA is quiescent,
   including the stale-worker case where completion or abort already removed
   the marked activation. Refresh failure quarantines the core.
2. A completion or timeout worker could claim an activation after the fault
   callback marked its generation but before fault work took the slot. Faulted
   work could therefore report success. IRQ and timeout claims now reject a
   fault-owned generation, and scheduler/admission treat the slot as busy until
   refresh completes.
3. AFBC power-off synchronized the auxiliary IRQ without first masking and
   acknowledging its level-high source. The backend now masks and flushes the
   AFBC interrupt-enable register, acknowledges a pending source while clocks
   are live, then publishes the inactive state and synchronizes the IRQ.
4. `SET_REG_ADDR_OFFSET` ran after fd translation. A known DMA-address register
   containing optional fd zero could receive a nonzero offset and reach MMIO
   without retained dma-buf provenance. The completed register image is now
   checked against the custom-plus-built-in address tables after offsets.
5. AFBC validation proved only that the first payload byte was inside the
   output dma-buf. It now computes the checked worst-case 16x16-block payload
   for 12-bpp or 15-bpp output and requires the complete
   header-plus-payload span to fit. Raw userspace AFBC-class writes no longer
   overwrite the kernel-derived AFBC configuration.

The review also compared the rewrite against the local forward-port/BSP and
libmpp. The hardware ID, three MMIO windows, IRQ ordering, start/status/error
semantics, AFBC field derivation, and all 67 VCD + 24 cache + 12 AFBC
translation entries match their local oracles. The exact-table KUnit now walks
the real region-based indices rather than 103 synthetic consecutive values.

## New regression discrimination

- zero-fd plus nonzero post-translation offset rejects;
- bound in-range offset succeeds and cumulative out-of-range offset rejects;
- a fault-marked activation cannot be claimed by normal IRQ completion;
- fault-pending state prevents an idle/scheduler decision;
- 8-bit and 10-bit AFBC exact-fit buffers pass and one-byte-short buffers
  reject, including a nonzero binding offset;
- a deliberately chosen width/padding fixture distinguishes the BSP's
  floor-before-64-byte-align payload offset from a rounded-up implementation;
- the AV1 hardware ID literal, match, and mismatch cases are explicit;
- the AV1 MPP suite is now 90 cases; combined with 147 RGA cases, the branch
  boot requirement is 237.

## Compile and static evidence

- focused arm64 GCC `W=1`, KUnit-enabled MPP + VSI objects: pass;
- focused arm64 Clang `W=1`, KUnit-enabled MPP + VSI objects: pass, with the
  pre-existing `rk_mpp_rkvdec2_soft_ccu_program_kunit` 6,672-byte stack-frame
  warning under Clang;
- strict checkpatch on the repair patch: 0 errors, 0 warnings, 0 checks;
- committed clean-archive `normal`: pass;
- committed clean-archive KASAN/fault-injection `memory`: pass;
- committed clean-archive KCSAN/lockdep `race`: pass.

Each clean profile built both IOMMU providers, both KUnit-enabled rewrite
objects, and `rk3588-rock-5b.dtb`, warning-free at `e58c57e50d0a0`.

## Boundary and remaining gates

This is source-, compile-, and static-concurrency evidence, not hardware
validation. The branch still has no booted 237-case KUnit report, raster or
8/10-bit AFBC decode result, injected two-fault VSI refresh result, timeout
recovery result, or clean board counter/dmesg evidence. The BSP accepts a
single register request that overlaps multiple sparse AV1 classes by clipping
it per class; the rewrite deliberately rejects cross-class/hole spans. Current
local libmpp sends a VCD-only `0x800`-byte request, so no current-userspace
regression was reproduced.

Classification: **SOURCE-CONFIRMED / ADVERSARIALLY REVIEWED /
FIX-COMPILE-VERIFIED / HARDWARE-UNVERIFIED**.
