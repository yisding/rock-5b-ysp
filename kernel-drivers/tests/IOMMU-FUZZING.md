# Debugging & fuzzing the RK3588 IOMMU machinery

How to exercise and validate the whole Rock 5B IOMMU surface: RGA3 scattered
userptr through the driver-owned IOMMU fallback, hardware video decode, and the
AV1 decoder.

Older findings and kernel debugfs still use the internal name `route_b`. Current
repo-facing docs call the mechanism **RGA userptr-IOMMU fallback**.

Scope note: "the IOMMU machinery" here is **two** providers. `rockchip-iommu.c`
serves RGA3, RKVDEC/VP9/H26x, RKVENC, VOP and NPU; `vsi-iommu.c` (Verisilicon)
serves **only** the standalone AV1 decoder. Anything claiming "whole IOMMU"
coverage has to touch both, which is why AV1 is a first-class phase below.

---

## 0. TL;DR

```sh
# device-free maintenance: compile the RGA scatter fuzzer object only
IOMMU_FUZZ_VALIDATE_BUILD=1 bash kernel-drivers/tests/iommu-machinery-fuzz.sh

# one-time: build a debug kernel with the config fragment (section 2), boot it
sudo kernel-drivers/tests/iommu-machinery-fuzz.sh          # full A+B+C run
sudo env IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS=1 \
  kernel-drivers/tests/iommu-machinery-fuzz.sh             # require direct RGA userptr-IOMMU fallback attribution
# then read the verdict + counters it prints, or drill in with sections 5–6
```

The run passes iff: every RGA op is byte-correct, every codec decodes bit-exact
(PSNR=inf), no IOMMU page fault fired on either provider, and the RGA
userptr-IOMMU `active` gauge returned to baseline (no leaked mapping). When
fallback counters are present and an RGA phase ran, the orchestrator also requires positive
`attempt`/`ok` deltas, no `attempt - ok` failures, and `active == 0` after the
run. Set `IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS=1` to make missing counters a
hard failure rather than an indirect-attribution warning.

---

## 1. What is instrumented (kernel side)

The original broad instrumentation is in the forward port
(`../kernel/linux-6.18-rkvenc-av1-fwport`). The rewrite intentionally keeps a
narrower debug surface: aggregate MPP/RGA counters under
`/sys/kernel/debug/rk_mpp_rewrite` and `/sys/kernel/debug/rk_rga_rewrite`, plus
RGA userptr-IOMMU fallback counters under the compatibility path
`rk_rga_rewrite/route_b`. The forward-port provider-level
per-master fault counters and DIAG logs are useful while debugging that tree, but
they are not part of the rewrite contract.

| Signal | Path / mechanism | Answers |
|--------|------------------|---------|
| MPP/RGA rewrite faults | `/sys/kernel/debug/rk_mpp_rewrite/iommu_fault_count`, `/sys/kernel/debug/rk_rga_rewrite/iommu_fault_count` | did a rewrite-owned IOMMU fault callback run |
| RGA userptr-IOMMU fallback fired? how often? | forward-port: `/sys/kernel/debug/rkrga/route_b/attempt`, rewrite: `/sys/kernel/debug/rk_rga_rewrite/route_b/attempt`; same for `ok` | did the scattered-userptr fallback run, and succeed |
| RGA userptr-IOMMU fallback leak? | `.../route_b/active` | maps minus unmaps — **must be 0 at rest** |
| Force every driver-owned RGA map through the fallback | `.../route_b/force_remap` (forward-port also has module param `rga_force_iommu_remap`) | 100% coverage + same-buffer differential |
| RGA userptr-IOMMU fallback span detail | forward-port `dmesg` when `DEBUGGER_EN(MM)` on | nents, data/map size, offset, programmed IOVA |
| Multi-segment trigger (DIAG) | forward-port-only `dmesg` `DIAG rga_dma_map_sgt: ...` | did `dma_map_sg` fail to coalesce (the RGA userptr-IOMMU fallback trigger) + contiguity walk |
| Per-master IOMMU faults | optional forward-port debugfs: `/sys/kernel/debug/rockchip-iommu/<dev>`, `/sys/kernel/debug/vsi-iommu/<dev>` | which master page/bus-faulted, across both providers |
| Fault IOVA + type | `dmesg` `rk_iommu ... Page fault at <iova>` / vsi `int_status` | where in IOVA space, read vs write |
| DMA-API misuse | `dmesg` `DMA-API: ...` (needs `CONFIG_DMA_API_DEBUG`) | unbalanced map/unmap, wrong-device sync, leaks — any master |

Rewrite counters are `atomic_t`/`u64`, updated in the fast path with no locking
(a stat race just loses a count — fine for debug). `attempt − ok` = fallback
failures. The forward-port interior trace / DIAG can tell you *why* when those
temporary patches are built.

Provenance: `iommu: rockchip, vsi: count per-device IOMMU faults in debugfs`,
`media: rockchip: rga3: add userptr IOMMU debug stats and force knob`, and the
rewrite slice `media: rockchip: rga-rewrite: count RGA userptr-IOMMU fallback mappings`.
The DIAG commit above the forward-port instrumentation adds the trigger log; it
has not been replicated in the rewrite.

---

## 2. Building the debug kernel

Merge the config fragment, then build as usual:

```sh
cd ../kernel/linux-6.18-rkvenc-av1-fwport
./scripts/kconfig/merge_config.sh -m .config \
    ../../rock-5b-ysp/kernel-drivers/patches/iommu-debug/kconfig-debug.fragment
make olddefconfig
# (Armbian: drop the fragment into userpatches or append + olddefconfig)
```

What the fragment buys you (all currently `n` on the stock config):
- `CONFIG_DMA_API_DEBUG` — transparent map/unmap/sync auditing across every
  master; the single highest-value flag. Violations print `DMA-API:` to dmesg.
- `CONFIG_KALLSYMS_ALL` — makes the static RGA userptr-IOMMU fallback / IOMMU helpers kprobe-able by
  name (section 6), otherwise only exported symbols resolve.
- `CONFIG_IOMMU_DEBUGFS` — generic per-domain IOMMU debugfs.

The rewrite's own counters + force knob work **without** the fragment. The
fragment only adds cross-cutting DMA-API/kprobe coverage; forward-port-only
provider counters require the matching debug patches in that tree.

Everything under `/sys/kernel/debug` is root-only — run the harness under `sudo`
(or arrange group access), same as `rga-mmu-debug.sh`.

---

## 3. The tools

### 3a. `iommu-machinery-fuzz.sh` — the orchestrator
Composes everything and brackets each phase with a dmesg fault scan + debugfs
counter delta + leak assertion. Structured logs land under
`../rockchip-conformance/logs/iommu-machinery/<ts>/`.

```sh
IOMMU_FUZZ_VALIDATE_BUILD=1 bash kernel-drivers/tests/iommu-machinery-fuzz.sh  # device-free C++ build gate
sudo kernel-drivers/tests/iommu-machinery-fuzz.sh              # full A+B+C
sudo env IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS=1 \
  kernel-drivers/tests/iommu-machinery-fuzz.sh                 # direct RGA userptr-IOMMU fallback counter gate
sudo RGA_ITERS=256 PHASES=A  kernel-drivers/tests/iommu-machinery-fuzz.sh   # RGA only, heavier
sudo DECODE_LOOPS=20 PHASES=B kernel-drivers/tests/iommu-machinery-fuzz.sh  # decode soak
sudo PHASES=C kernel-drivers/tests/iommu-machinery-fuzz.sh                  # cross-domain concurrency
```

Phases:
- **A — RGA scatter**: `rga-iommu-fuzz` forces scattered userptr (RGA userptr-IOMMU fallback) and
  checks output byte-for-byte.
- **B — decode**: `decode-differential.sh`, HW vs SW, PASS iff bit-exact.
- **C — concurrent**: RGA scatter + a 600-frame AV1 decode running together, so
  `rockchip-iommu` and `vsi-iommu` map/unmap simultaneously (cross-domain races).

`IOMMU_FUZZ_VALIDATE_BUILD=1` compiles `rga-iommu-fuzz.cpp` to an object with
the staged librga headers and exits before any device, debugfs, dmesg, or target
librga shared-library access. It is also part of
`VALIDATE_ONLY=1 rewrite-conformance-run.sh`, so normal device-free maintenance
catches source/header drift in the RGA userptr-IOMMU fallback fuzzer. It is not hardware evidence.

`IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS=1` is for debug-capable RGA
userptr-IOMMU kernels.
It fails the run when no `route_b` debugfs counters are captured during RGA
phases; without it, missing counters are reported as indirect attribution while
correctness and dmesg fault checks still decide the behavioral result.

### 3b. `rga-iommu-fuzz` — RGA scattered-userptr correctness (built by the orchestrator)
Forces physical scatter with an interleaved-fault trick (mmap the buffer + an
equal spacer, `MADV_NOHUGEPAGE`, fault them page-interleaved so consecutive
virtual pages get non-adjacent PFNs, so `dma_map_sg` cannot coalesce and the
RGA userptr-IOMMU fallback
runs). Then checks correctness: **absolute** for copy (output == known pattern),
**differential** for resize/rotate/cvtcolor (scattered-src output == contiguous
output). Sub-page offsets and src/dst scatter are exercised.

```sh
LD_LIBRARY_PATH=../rockchip-conformance/sources/airockchip-librga/libs/Linux/gcc-aarch64 \
  ./rga-iommu-fuzz -n 128 -o all -t both -v      # 128 iters, all ops, scatter src+dst
./rga-iommu-fuzz -o copy -t dst -W 1920 -H 1080  # copy, scatter only the write buffer, fixed size
# -o copy|resize|rotate|cvt|all   -t src|dst|both   -s <seed>   -W/-H fixed dims
```
Exit 0 iff every check passed; on mismatch it prints the op, dims, offset and the
first differing byte.

### 3c. `decode-differential.sh` — HW-vs-SW bit-exact decode oracle (reused)
Decodes H.264/H.265/VP9/AV1 on the hardware (`mpi_dec_test`) and in software,
then PSNRs them. Video decode is normative, so a conformant HW decoder is
bit-exact → PSNR=inf; anything finite is a real decode/IOMMU-corruption bug. AV1
(`-t 16777224`) is the `vsi-iommu` path; H265 is `16777220`, VP9 `10`, H264 `7`.

```sh
sudo kernel-drivers/tests/decode-differential.sh    # all four codecs, PASS = all bit-exact
```

---

## 4. Enumerate the masters (know what you're testing)

```sh
for g in /sys/kernel/iommu_groups/*/devices/*; do
  echo "group $(basename $(dirname $(dirname $g)))  $(basename $g)"; done | sort -V
```
On this board: `fdb60000.rga`/`fdb70000.rga` (RGA3 cores → RGA userptr-IOMMU fallback),
`fdc38100/fdc40100.video-codec` (RKVDEC), the `fdba*`/`fdb50000`/`fdc70000`
codec/AV1 nodes, `fdd90000.vop`, `fdbd0000/fdbe0000.rkvenc-core`, three `npu`.
The AV1 decoder sits behind `vsi-iommu`, everything else behind
`rockchip-iommu`. Provider debugfs dirs exist only on debug-instrumented
forward-port builds. PCIe is behind ARM `smmu3` — out of scope here.

---

## 5. Reading the signals

**RGA userptr-IOMMU fallback coverage & health** (after a run):
```sh
RGA_USERPTR_IOMMU_DEBUGFS=/sys/kernel/debug/rk_rga_rewrite/route_b   # rewrite
[ -d "$RGA_USERPTR_IOMMU_DEBUGFS" ] || RGA_USERPTR_IOMMU_DEBUGFS=/sys/kernel/debug/rkrga/route_b
cd "$RGA_USERPTR_IOMMU_DEBUGFS"
grep . attempt ok active
```
- `attempt > 0` → the fallback actually ran. **`attempt == 0` means your test
  never scattered anything — the run proved nothing about RGA userptr-IOMMU fallback** (this was the
  original trap: stock demos always coalesce). Force it (section 6a) or scatter harder.
- `attempt − ok` → failures. If non-zero, grep dmesg for the `routeB` trace and
  the specific `rga_err` reason.
- `active` → live mappings. Read it **at rest** (no jobs running): must be `0`.
  Non-zero after the fuzzer drains = a leaked IOVA/GUP pin.

`iommu-machinery-fuzz.sh` enforces these rules automatically when it captures
RGA userptr-IOMMU fallback counters. If a clean RGA run prints "no RGA userptr-IOMMU fallback counters captured", it
is still useful behavioral evidence, but not direct fallback attribution unless
you rerun with a kernel exposing `route_b` counters or enable
`IOMMU_FUZZ_REQUIRE_RGA_USERPTR_IOMMU_COUNTERS=1`.

**Rewrite fault counters and optional per-master provider counters:**
```sh
grep -r . /sys/kernel/debug/rk_mpp_rewrite/ /sys/kernel/debug/rk_rga_rewrite/ 2>/dev/null
```
Non-zero `iommu_fault_count` means the rewrite fault callback ran for that driver
class. Correlate with dmesg for the fault IOVA and read/write direction.

On forward-port debug builds, per-master counters may also exist:
```sh
grep -r . /sys/kernel/debug/rockchip-iommu/ /sys/kernel/debug/vsi-iommu/ 2>/dev/null
```
Any non-zero provider value names the exact faulting device. A fault on
`vsi-iommu/*` implicates the AV1 path specifically.

**DMA-API violations** (debug-kernel only): any `DMA-API:` line in dmesg is a
real bug — unbalanced unmap, sync on the wrong device, double free. The
non-coherent RGA/decoder sync paths are the likely source.

**Decode:** `PSNR hw-vs-sw average:inf` = bit-exact = pass. Finite = decoder or
IOMMU data corruption.

---

## 6. Debugging playbooks

### 6a. "Make RGA userptr-IOMMU fallback run on demand" (coverage without luck)
```sh
RGA_USERPTR_IOMMU_DEBUGFS=/sys/kernel/debug/rk_rga_rewrite/route_b   # rewrite
[ -d "$RGA_USERPTR_IOMMU_DEBUGFS" ] || RGA_USERPTR_IOMMU_DEBUGFS=/sys/kernel/debug/rkrga/route_b
echo 1 | sudo tee "$RGA_USERPTR_IOMMU_DEBUGFS/force_remap"            # every driver-owned map -> RGA userptr-IOMMU fallback
# run any librga workload or rga-iommu-fuzz; then:
cat "$RGA_USERPTR_IOMMU_DEBUGFS/attempt"                              # climbs on every job
echo 0 | sudo tee "$RGA_USERPTR_IOMMU_DEBUGFS/force_remap"
```
With `force_remap=1`, even *contiguous* buffers traverse the fallback, so you get a
same-buffer normal-vs-remapped differential (run the same op with it off and on,
compare output) that isolates the remap+cache-sync logic from the scatter trick.
dma-buf imports are unaffected — they never use this path. (Module-param
equivalent: `/sys/module/<rga-module>/parameters/rga_force_iommu_remap`; the
debugfs bool is the reliable path.)

### 6b. "Did the fallback actually fire, and on what?"
On rewrite kernels, use the RGA userptr-IOMMU counters above as the primary signal. On
forward-port debug kernels, the BSP RGA trace and DIAG trigger add span detail:
```sh
echo mm | sudo tee /sys/kernel/debug/rkrga/debug     # enable DEBUGGER_EN(MM)
sudo dmesg -w | grep -E 'DIAG rga_dma_map_sgt|routeB'
```
`DIAG ...` prints when `dma_map_sg` returned multi-segment (the trigger) with the
contiguity walk; `routeB: ...`/`routeB ok: ...` print the synthetic span and the
programmed IOVA. On either kernel, silence + `attempt==0` = nothing scattered.

### 6c. "A fault fired — localize it"
```sh
sudo dmesg | grep -iE 'rk_iommu|vsi.*int_status|Page fault|BUS_ERROR'
grep -r . /sys/kernel/debug/rk_mpp_rewrite/ /sys/kernel/debug/rk_rga_rewrite/ 2>/dev/null
grep -r . /sys/kernel/debug/rockchip-iommu/ /sys/kernel/debug/vsi-iommu/
```
The rewrite counters tell you which driver class saw the callback; optional
provider counters name the exact device; the dmesg line tells you the IOVA and
read/write. Cross-check the IOVA against the RGA userptr-IOMMU fallback mapping range when available
to see if a fallback span is implicated, and whether it wrapped the 32-bit guard
(`>= 0xe0000000` should never appear).

### 6d. "Output is wrong (but no fault)"
This is the coherency class of bug (non-coherent RGA/decoder, stale cache).
`rga-iommu-fuzz` already localizes it: the first-diff byte offset points at the
page/plane. Re-run with `-t src` vs `-t dst` to tell read-path from write-path
(write-path / `DMA_FROM_DEVICE` is the usual coherency culprit). For decode, a
finite PSNR with a clean fault log is the same signature on the AV1/RKVDEC path.

### 6e. "Prove there's no leak" (soak)
```sh
# baseline at rest
RGA_USERPTR_IOMMU_DEBUGFS=/sys/kernel/debug/rk_rga_rewrite/route_b
[ -d "$RGA_USERPTR_IOMMU_DEBUGFS" ] || RGA_USERPTR_IOMMU_DEBUGFS=/sys/kernel/debug/rkrga/route_b
cat "$RGA_USERPTR_IOMMU_DEBUGFS/active"                     # expect 0
grep MemAvailable /proc/meminfo
sudo RGA_ITERS=512 DECODE_LOOPS=50 kernel-drivers/tests/iommu-machinery-fuzz.sh
# after: active back to 0, MemAvailable stable, dmesg has no 'DMA-API:' lines
```
`active` back to baseline + stable `MemAvailable` + clean DMA-API = no IOVA/GUP/
buffer leak over the soak.

### 6f. Cross-domain stress
`PHASES=C` runs RGA scatter and AV1 decode together. Watch both providers'
fault counters and `active` during it — this is where allocator/domain races
between `rockchip-iommu` and `vsi-iommu` would surface.

---

## 7. Ad-hoc / low-level probes (debug kernel)

With `CONFIG_KALLSYMS_ALL` the RGA userptr-IOMMU fallback helpers become kprobe-able:
```sh
cd /sys/kernel/debug/tracing
echo 'p:rb rga_dma_map_sgt_iommu' | sudo tee kprobe_events      # count fallback entries
echo 1 | sudo tee events/kprobes/rb/enable
sudo cat trace_pipe
# fault handlers:
echo 'p rk_iommu_irq' >> kprobe_events ; echo 'p vsi_iommu_irq' >> kprobe_events
```
`rga_dma_check_iova_span` is exported even without KALLSYMS_ALL, but it fires on
both the normal and RGA userptr-IOMMU fallback paths, so it is not a clean fallback counter — prefer
the `route_b/attempt` counter or a kprobe on `rga_dma_map_sgt_iommu`.

---

## 8. Gotchas

- **`attempt == 0` invalidates an RGA run.** Scatter is probabilistic; a clean
  pass with zero attempts tested the contiguous path only. Confirm coverage, or
  use `force_remap`.
- **AV1 ≠ rockchip-iommu.** On forward-port debug builds, AV1 faults show under
  `vsi-iommu/`, not `rockchip-iommu/`; grep both. On rewrite builds, use dmesg
  plus aggregate MPP/RGA fault counters.
- **MPP needs the from-source build.** The distro `librockchip_mpp` reports
  "parser not registered" and fails decode; the harness uses
  `../rockchip-conformance/out/mpp` which has parsers registered. AV1 = `-t 16777224`.
- **`force_remap` only affects driver-owned maps** (userptr / physical). dma-buf
  imports keep the fail-closed single-span contract regardless.
- **debugfs/dmesg are root-only** — run under sudo.
- Guard band invariant: no RGA userptr-IOMMU fallback IOVA should ever be `>= 0xe0000000`
  (`DMA_BIT_MASK(32) − SZ_512M`); if one is, the 32-bit-wrap protection regressed.

---

## 9. Files

- Kernel instrumentation: commits `iommu: rockchip, vsi: count per-device IOMMU
  faults in debugfs` and `media: rockchip: rga3: add userptr IOMMU debug stats
  and force knob`; rewrite commit `media: rockchip: rga-rewrite: count userptr
  IOMMU fallback mappings`.
- Config fragment + patch notes: `../patches/iommu-debug/`.
- Tools: `iommu-machinery-fuzz.sh`, `rga-iommu-fuzz.cpp`, `decode-differential.sh`
  (+ `suite-common.sh`, `debugfs-counters.sh`) in this directory.
