# Rewrite KUnit gate passes all 232 cases on the follow-up boot

> Scope: clean-room MPP/RGA rewrite drivers on the ROCK 5B
> Source: user-reported follow-up boot of the latest rewrite driver, kernel release `6.18.40-video-rewrite-kasan-rockchip64`; `sudo kernel-drivers/tests/rewrite-kunit-log-check.sh`
> Date: 2026-07-26
> Trust: MEASURED / SOURCE-INSPECTED / ROOT-CAUSED / PARTIAL

## Result

The follow-up rewrite boot passes the complete booted KUnit result gate:

| Suite | Expected | Planned | Results | Failed | Skipped | Verdict |
|-------|----------|---------|---------|--------|---------|---------|
| `rk_mpp_rewrite` | 85 | 85 | 85 | 0 | 0 | pass |
| `rockchip-rga-rewrite` | 147 | 147 | 147 | 0 | 0 | pass |

The checker reported kernel release
`6.18.40-video-rewrite-kasan-rockchip64` and ended with:

```text
rewrite KUnit result check passed
```

This advances the failed repaired-boot result from 84/85 MPP and 139/147 RGA
to 85/85 and 147/147 with zero skips. In particular, the boot-time KUnit
fixtures no longer fail before userspace testing begins.

The boot is not warning-clean. At 7.15 seconds it emitted the separately
[root-caused DWC PCIe PMU bus-notifier lockdep report](./2026-07-26-dwc-pcie-pmu-bus-notifier-lockdep-false-positive.md).
That report contains no rewrite frame and mistakes two distinct bus notifier
rwsems for recursive acquisition because both have the same lockdep class. It
nevertheless disables lockdep for the rest of the boot.

A full boot-journal sweep also found five real debug-object warnings inside
three nominally passing RGA KUnit cases:

| KUnit case | Warnings | Cause |
|------------|----------|-------|
| `rk_rga_release_fence_fd_state_kunit` | one work-object warning | stack `rk_rga_job` reaches production `INIT_WORK()` |
| `rk_rga_hw_abort_queued_jobs_kunit` | one work plus one timer warning | stack `rk_rga_hw` reaches `INIT_DELAYED_WORK()` |
| `rk_rga_iommu_fault_generation_kunit` | one work plus one timer warning | stack `rk_rga_hw` uses ordinary work/delayed-work initializers |

Each warning says the object is on the stack but is not annotated, and each
case still reports `ok`. Therefore the 232/232 result means the KTAP
expectations pass; it is not a clean KUnit execution.

The warning count follows directly from the embedded objects. `INIT_WORK()`
registers one ordinary `work_struct`; `INIT_DELAYED_WORK()` registers both its
embedded `work_struct` and `timer_list`. Debug Objects sees that their owners
reside in a KUnit thread's stack range, but the ordinary initializers did not
mark them as on-stack, so the three fixtures produce `1 + 2 + 2 = 5` reports.
This is a fixture allocation/lifetime defect rather than evidence that a
production work item was queued incorrectly.

The source fix moves the three affected `rk_rga_job`/`rk_rga_hw` fixture owners
to `kunit_kzalloc()` storage while retaining the ordinary production
initializers. That is safer than ad-hoc stack destruction here: KUnit-managed
heap cleanup still runs if a fatal assertion returns early, while an on-stack
object would need every early-exit path to destroy both embedded debug objects
before its frame disappears. The identical fixes are committed as 6.18
`4273266a990ef` and mainline `ef79d16bd9020`. A warning-free boot is still
required to prove the runtime gate.

No KASAN report, Oops, panic, UBSAN report, or general-protection fault appears
elsewhere in the boot journal. The remaining non-rewrite warnings are lower
priority for this driver gate: repeated power-domain `-EPROBE_DEFER` messages
precede the late regulator probes; `mmc0` and `mmc2` fail to initialize
non-removable devices while the system boots from and runs on NVMe; and static
GPIO-base deprecation notices are platform cleanup rather than runtime
failures. The RGA fixture warnings are the additional rewrite issue worth
fixing before another qualification boot.

## Hardware binding follow-up

Live sysfs and the boot journal separate the expected mainline Hantro JPEG
encoder from the rewrite's RKVENC2 encoder:

| Hardware | Driver/result |
|----------|---------------|
| VEPU121 `fdba0000.video-codec` | `hantro-vpu`; registers `/dev/video2` as the mainline V4L2 JPEG encoder |
| VEPU121 `fdba4000`, `fdba8000`, `fdbac000` | intentionally ignored because Hantro lacks RK3588 multicore scheduling |
| RKVENC2 `fdbd0000`, `fdbe0000` + CCU | both bound to `rk-mpp-rewrite-hw` |
| RKVDEC2 `fdc38100`, `fdc40100` + CCU | both bound to `rk-mpp-rewrite-hw` |
| RGA2 `fdb80000` | bound to `rockchip-rga-rewrite` |
| RGA3 `fdb60000`, `fdb70000` | unbound: each fails `request_irq()` with `-EBUSY` |

The RGA3 MMIO fix is active: the live DT reports `0x200` core windows disjoint
from the IOMMUs at `+0xf00`, and probe now advances past resource reservation.
It exposes the next independent probe defect instead. Each RGA3 core shares its
level IRQ with its external IOMMU (GIC SPI 114/115). `rockchip-iommu` requests
that line with `IRQF_SHARED`, while the packaged rewrite requests
`IRQF_ONESHOT`; genirq rejects the incompatible second registration:

```text
genirq: Flags mismatch irq 48. 00002004 (fdb60000.rga) vs. 00200084 (fdb60f00.iommu)
rockchip-rga-rewrite fdb60000.rga: probe with driver rockchip-rga-rewrite failed with error -16
genirq: Flags mismatch irq 49. 00002004 (fdb70000.rga) vs. 00200084 (fdb70f00.iommu)
rockchip-rga-rewrite fdb70000.rga: probe with driver rockchip-rga-rewrite failed with error -16
```

The shared-IRQ repair is committed identically in both rewrite source trees.
The first commit selects `IRQF_SHARED` for RGA3 and retains `IRQF_ONESHOT` for
RGA2; the review follow-up models that wiring as an explicit match-data quirk
instead of treating every external-IOMMU phandle as proof of IRQ sharing, and
moves the IRQ policy assertions into their own KUnit case:

| Tree | Shared-IRQ commit | Review follow-up |
|------|-------------------|------------------|
| 6.18 | `bc420aca1300e` | `eb64bc7de3270` |
| mainline | `d28fdd9c75694` | `6ac18425f66c7` |

The new case raises the next-tip RGA plan from 147 to 148, so the repository
KUnit/evidence gates now require 85 MPP plus 148 RGA results. Source review
found the hard handler suitable for a shared line: it returns
`IRQ_NONE` when no RGA done/error status belongs to it and clears owned RGA3
status before returning `IRQ_WAKE_THREAD`. Both diffs are whitespace- and
checkpatch-clean. The clean-archive normal-profile gate builds the IOMMU
provider, both rewrite objects with KUnit enabled, and the ROCK 5B DTB
warning-free at both exact follow-up tips. The installed kernel does not
contain these commits, so boot verification remains open.

## Evidence and reproduction

- **Exercise:** `sudo kernel-drivers/tests/rewrite-kunit-log-check.sh`
- **Pass signal:** both required suites reported `summary=ok` and
  `verdict=pass`; all 232 expected, planned, and result cases were present,
  with zero failures and zero skips.
- **Source verification:** `rewrite-build-gate.sh all` passed the clean-archive
  normal profile at 6.18 `4273266a990e` and mainline `ef79d16bd902`, with no
  compiler warning; `git diff --check`, `checkpatch.pl`, and byte-identity
  comparison also passed.
- **Artifacts:** none recorded in the repository; this finding preserves the
  pasted terminal transcript.

## Boundary

The standalone checker proves the KUnit plan/result counts and verdicts, but
does not inspect warnings surrounding those results. The
follow-up sysfs/journal inspection proves MPP core binding and shows the RGA3
DT-resource repair took effect, but both RGA3 cores still fail at shared-IRQ
registration. The separately supplied dmesg proves the interval is not
warning-clean: the DWC PCIe PMU report ends lockdep coverage, and five RGA
KUnit debug-object warnings expose remaining fixture defects. No userspace
ioctl was exercised, and the captures do not independently fingerprint the
installed package/source commit or close ABI/media conformance.

## Next gate

Before starting the broad media suites:

1. package and boot the committed fixture and shared-IRQ repairs, then require
   no debug-object report and no DWC PCIe PMU report so lockdep stays enabled
   through a warning-clean 85-MPP/148-RGA interval;
2. prove RGA2 plus both
   RGA3 cores are bound (the intended MPP encoder/decoder cores are already
   present on this boot), and capture the installed-kernel/package fingerprint;
   and
3. run ABI replay alone, then verify its exit status, clean dmesg, and readable
   rewrite debugfs state.

Only after those checks should the paired counter/artifact conformance run
resume.
