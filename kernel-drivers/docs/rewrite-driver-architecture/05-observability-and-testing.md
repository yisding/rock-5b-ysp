# Observability and testing

[← Design lessons](04-design-lessons.md) · [Guide home](README.md) ·
[Next: source reading and review →](06-source-reading-and-review.md)

## 8. Observability

Architecture is easier to debug when transitions are countable.

MPP exposes `rk_mpp_rewrite` debugfs state including:

- submitted, scheduled, dispatched, started, completed, failed, and aborted
  job counts;
- per-core scheduling/start counts;
- total/max hardware time;
- IRQ/spurious IRQ counts;
- timeout, IOMMU fault, IOMMU refresh, reset, and recovery-failure counts;
- bound hardware/support masks;
- a recent-event ring with lifecycle and error events.

The MPP `state` file is observational, not part of the workload ABI. Its
hardware-list and scheduler snapshots use `mutex_trylock()` and return
`-EBUSY` when either protected structure is changing. This keeps a diagnostic
reader from waiting forever if a preceding fatal path abandoned a service
mutex. Interactive tooling may retry; qualification preflight treats `EBUSY`
as a dirty-boot failure. Submit, scheduling, completion, and recovery retain
their normal blocking synchronization. An unbounded debugfs wait must not be
restored; a future guaranteed-under-load snapshot would need bounded retry or
copy-under-lock formatting.

RGA exposes `rk_rga_rewrite` state including:

- prepared, scheduled, dispatched, started, and completed counts;
- per-core scheduling/start counts and hardware time;
- IRQ/error/spurious counts;
- timeout, IOMMU fault/refresh, and recovery-failure counts;
- command allocations and power cycles;
- RGA2 parser/config errors;
- USERPTR IOMMU-route and shadow-page activity;
- unsupported-operation counts.

Counters should describe transitions, not merely ioctl traffic. A test can then
prove that it reached hardware by requiring `started_job_count` and hardware
time to increase, while also requiring timeout/fault counters to stay flat.

---

## 9. Testing architecture

The embedded KUnit suites test logic that does not require live RK3588 silicon.
At the documented source revisions:

- MPP registers 85 KUnit cases.
- RGA registers 148 KUnit cases.

The [rewrite KUnit guide](../rewrite-kunit.md) documents their source
organization, fixture contract, debug-kernel autorun, exact-count KTAP parser,
kernel-log gate, and evidence-capture workflow.

The tests concentrate on boundaries that are difficult to reproduce reliably
on hardware:

- ABI structure sizes and command parsing;
- overflow and range validation;
- mapping/provenance/alias rules;
- core routing and topology;
- refcount and list ownership;
- fence callback/cancel races;
- timeout/fault generation matching;
- IRQ status decoding;
- reset/quarantine behavior;
- CCU/link/DCHS coordination;
- task progression and command emission;
- close/remove handoffs.

The evidence levels must not be collapsed:

| Level | Example | What it can establish | What it cannot establish |
|-------|---------|-----------------------|--------------------------|
| Source inspection | Review ownership and lock order | Intended invariants and obvious missing paths | That every race or hardware behavior matches the design |
| Compile/build gate | Build both drivers, provider, DTB, and KUnit objects | API compatibility and configuration coverage | That the tests ran or the board boots |
| KUnit execution | Boot and record all 232 cases | Pure helper/state-machine behavior in the running kernel | Correct pixels, bitstreams, IRQ wiring, or real reset behavior |
| Hardware smoke | Run one encode/decode/blit per backend and inspect counters | Basic probe, power, MMIO, DMA, and IRQ function | Broad ABI compatibility or stress safety |
| Differential conformance | Compare outputs and behavior with the forward port | Compatibility across real applications and data paths | Exhaustive recovery/security behavior |
| Fault/race/soak gates | KASAN, KCSAN, failure injection, close/unbind stress, long runs | Evidence for rare lifetime and recovery paths | A mathematical proof that no defect remains |

The build gate builds both kernel lines under normal, memory-safety, and
race/concurrency configurations:

```bash
REWRITE_BUILD_PROFILES='normal memory race' \
  kernel-drivers/tests/rewrite-build-gate.sh all
```

All six profiles completed without compiler warnings at the cited tips on
2026-07-23. That is current compile evidence, not a boot or hardware result.
For a release claim, also record the exact kernel configuration, boot identity,
KUnit log, suite logs, debugfs counter deltas, artifacts, and before/after
kernel-fatal scan.

KUnit and compile-time tests cannot establish that register programming matches
silicon. On-board conformance must additionally exercise:

- real encode/decode/transform output;
- every physical core;
- DMA-BUF and USERPTR paths;
- synchronous and asynchronous fences;
- timeout/fault injection;
- session close under load;
- driver unbind/rebind where safe;
- counters proving hardware execution.

The immediate status-changing milestone is therefore not “add another unit
test.” It is: install and boot the current-tip KASAN image `P3695-C9fc5` on the
ROCK 5B, record all 233 KUnit cases, prove that each expected hardware family
starts, then run paired rewrite-versus-forward-port conformance with clean
kernel logs. Timeout, IOMMU-fault, reset-failure, close, and removal stress
follow before a production-readiness claim.

---

[← Design lessons](04-design-lessons.md) · [Guide home](README.md) ·
[Next: source reading and review →](06-source-reading-and-review.md)
