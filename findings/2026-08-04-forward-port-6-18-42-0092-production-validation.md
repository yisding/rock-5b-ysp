# Forward-port 6.18.42 production validation boots 0092 and closes the functional recovery gates

> Scope: RK3588 MPP, RGA, IOMMU, FFmpeg, GStreamer, and independent
> `rockchip-vaapi` validation on the installed forward-port production kernel.
>
> Source: on-board runs from `/home/yi/Code/rock-5b-ysp` and
> `/home/yi/Code/rock-5b/rockchip-vaapi`, with durable artifacts under
> `../rock-5b/build/rockchip-conformance/logs/forward-port/`.
>
> Date: 2026-08-04 PDT.
>
> Trust: **MEASURED** / **BOOT-VERIFIED** / **PRODUCTION-PROFILE** /
> **PARTIAL**.

## Result

The exact `0001`–`0092` production package is Published, installed, and
booted. Its broad codec, direct RGA, IOMMU, VP9 hard-lock regression, RGA
cancellation/reset, and independent VA-API gates have now run on the ROCK 5B.
The kernel-facing functional and recovery results are green: no MPP, RGA,
IOMMU, DMA-API, Oops, BUG, or memory-corruption signature was attributable to
the accelerator workloads.

This closes the production-profile runtime gate that the
[0090–0092 fix finding](2026-08-04-forward-port-rga-uaf-recovery-safety-fixes.md)
left open. It does **not** close same-tail memory-safety qualification: this
kernel has no KASAN or lockdep, only `sudo dmesg` is allowlisted, and the
root-only debugfs leak/counter snapshots were unavailable. The same targeted
cancellation and recovery paths still need a KASAN/lockdep boot before the
three-patch tail is described as memory-safety qualified.

The broad userspace verdict is green modulo existing and separately
attributed gaps:

- GStreamer passes 100/102 required cases. The two failures are the previously
  documented DMABUF caps-negotiation and malformed H.264 flush-harness cases.
- The official librga demo matrix remains unsuitable as a release oracle:
  most demos perform their work, print success, and return librga's success
  enum value `1` as a failing process exit; others require Android-style
  fixtures or heaps. The maintained direct smoke exits 0 with 31 artifacts.
- The VP9 `show_existing_frame` stress passes its kernel hard-lock/UAF oracle,
  but all 120 successful direct-MPP decodes still reproduce the known libmpp
  buffer-slot assertions and userspace leaked-buffer cleanup.
- VA-API normal and ASan/UBSan gates pass. The remaining same-process TSan
  report is in FFmpeg `libavfilter`/`libswscale`, not the Rockchip VA driver.
  Desktop VLC/mpv/Firefox and WebRTC-peer setup/integration gaps remain.
- The full dual-codec encode soak passes flat and kernel-clean. The full 4K
  decode workload and kernel window pass, but its strict fd-span oracle fails
  36 versus 32 because of four rare stream-loop-boundary samples; its ending
  fd median is lower, so this does not resemble sustained descriptor growth.

## Boot identity and package provenance

Run `20260804-202931-boot-health-canonical` records:

- `uname -a`: `Linux rock-5b 6.18.42-ysp-rockchip64 #1 SMP PREEMPT Thu, 09 Jul 2026 12:00:00 -0700 aarch64 GNU/Linux`.
- Installed image, DTB, and headers:
  `6.18.42+rk3588av1fwport20260804-0ubuntu1~rk1`.
- APT candidate/source: the same version from
  `ppa.launchpadcontent.net/yi-ding/ubuntu-rock-5b`.
- `/boot/vmlinuz-6.18.42-ysp-rockchip64` MD5:
  `109355735fd5c23397e3a209521071a4`; this matches the installed package
  manifest.
- `/sys/kernel/notes` SHA-256:
  `dec594c536338fc3925d20c8f28fefbfed9241ff3fac48a95dbb3ae624b19da8`.
- Taint `0`, two encoder cores, two decoder cores, both device nodes, and all
  three RGA engines present.
- `CONFIG_DMABUF_DEBUG`, `CONFIG_KASAN`, and `CONFIG_PROVE_LOCKING` are all
  disabled.

The preflight whole-boot fatal scan reported zero canonical fatal lines. The
identity directory also retains the exact package policy, package versions,
hashes, and debug-config boundary.

## Native conformance

The complete forward-port runner used `RUN_ID=20260804-203002`, required AV1,
continued after userspace failures, and was enclosed by privileged before/after
`dmesg` snapshots:

```sh
PROFILE=forward-port FFMPEG_REQUIRE_AV1=1 RUN_CONTINUE_ON_FAIL=1 \
RUN_ID=20260804-203002 SUITE_DMESG_SCAN=0 SUITE_REQUIRE_DMESG=0 \
  bash kernel-drivers/tests/rewrite-conformance-run.sh
```

Results:

| Suite | Result |
|---|---|
| ABI replay | PASS |
| MPP | 12/12 required PASS; H.264/H.265 decode and encode, VP9, slice, multi-instance, and RC2 paths |
| FFmpeg | 21/21 required plus 3/3 diagnostic PASS; H.264/H.265/VP9/AV1 bit-exact, AV1 AFBC, encode/transcode, RGA scale/vpp/overlay, and Main10→P010 |
| GStreamer | 100/102 required PASS; the same two userspace/harness failures described above |
| Outer kernel scan | clean over 3,297 new lines; zero fatal lines |

The two GStreamer failures do not submit a failing kernel operation. The
DMABUF transcode stops at `h264parse`/caps negotiation; plain transcode and the
DMABUF decode sibling pass. Direct H.264 flush sends data after
`FLUSH_STOP(TRUE)` without a new segment; H.265 flush and the well-formed
controls pass.

## Direct RGA and decoder gates

- `20260804-203317-librga-smoke`: exit 0, 31 output artifacts, clean outer
  kernel scan. It covers virtual and DMABUF copy, RKNN RGB/NV12/NV21 paths,
  async resize/fence, crop/flip/letterbox, legacy blit/fill/I420, AFBC16x16,
  tile8x8, P010→NV12, P210→NV16, jobs, forced RGA3, and RKMppEnc-style fd
  chains. Unsupported AFBC32x8/RFBC64x4 and pre-intr/gauss probes are recorded
  as expected rejects/skips.
- `20260804-203345-decoder-smoke`: H.264 and H.265 liveness decode 30 frames;
  H.264, H.265, VP9, and AV1 hardware output is bit-exact against software with
  average PSNR `inf`. The kernel delta is clean.
- `20260804-203408-iommu-machinery`: scattered-userptr RGA, four-codec
  differential decode, and concurrent RGA+AV1 phases all exit 0 with correct
  output and no IOMMU/DMA fault. Debugfs counter/leak snapshots are unavailable
  without a root shell, so this proves correctness and fault absence, not
  counter-based leak freedom.

The upstream librga demo rerun `20260804-203201-librga-suite` records 3/34
required demos passing under the wrapper. That number is not a kernel failure
count: most red demos print `running success!` and exit 1, while the remaining
fixture/heap assumptions are userspace environment gaps. The direct maintained
smoke above is the content-checked RGA release oracle.

## Lifetime and recovery stress

### VP9 hidden-reference regression

`20260804-203604-vp9-show-existing` runs 30 loops with four concurrent direct
MPP decoders, then waits 60 seconds for deferred faults. All 120 decoder
processes report success, zero kernel lines are flagged, and the board remains
responsive.

This is a kernel gate, not a claim that libmpp is clean. Every one of the 120
logs contains the known `mpp_buf_slot` assertions and
`mpp_buffer_service_deinit cleaning leaked buffer`: 720 assertion lines and
120 cleanup lines total. A fresh source-and-operation-history audit localizes
the defect: consecutive `show_existing_frame` packets enqueue the same
physical reference slot into a queue that has only one intrusive node per
slot. The second enqueue coalesces the first queue occurrence while retaining
both +2 usage charges, leaving the three twice-repeated references at
`display=2`; repeated shallow output frames also lack a per-presentation
buffer reference. A one-pass follow-up emits only 13 of the software
decoder's 16 frames, proving that the three coalesced occurrences are dropped;
the original `-n 16` stress rewinds the input until it reaches its requested
count. That userspace defect was subsequently repaired and promoted into the
maintained [MPP presentation-event explanation and evidence basis](../vendor-libraries/mpp/docs/mpp-library-architecture.md#vp9-presentation-event-ownership).

### RGA cancellation and reset

`20260804-203938-rga-recovery-stress` runs a continuous multi-task
`rga_copy_splice_task_demo` workload through three kill and three reset loops.
Each loop waits for cancellation/recovery and replays the ABI probe. All six
loops and all six ABI rechecks exit 0; the enclosing privileged kernel scan is
clean over 3,128 new lines.

This is direct production-profile exercise of the job-task lifetime shape
changed by `0090`: a session exits while multi-task requests are active, and
reset/cancellation then has to retire the request without leaving IRQ
completion with a borrowed task list. It is strong functional regression
evidence, but the absence of KASAN means it cannot prove that a silent stale
access did not occur.

## Independent VA-API gate

The installed `rockchip-vaapi` and config packages are
`1.0.11+ysp12-0ubuntu1~rk1`; source `main@184d7d438376` reproduces the installed
driver through the package-provenance gate.

Host run `20260804-204223-vaapi-host` passes build/unit, ASan/UBSan, TSan unit,
Valgrind, lint, Firefox RDD policy, package install, package provenance, and
Python parsing. Shellcheck passes after correcting the invocation to the
existing `tests/*.sh` set. LibFuzzer could not link because this host's LLVM 21
installation lacks its AArch64 fuzzer and ASan runtime archives; no fuzz target
executed.

Hardware run `20260804-205100-vaapi-hardware` executes 45 cases with a separate
privileged kernel window around each. Thirty-eight pass on the first run; the
initial concurrent-decode TSan exit 66 passes on retained-log rerun
`20260804-211029-vaapi-tsan-classification`. The effective passing set includes:

- driver-object lifecycle under normal, ASan/UBSan, and TSan;
- zero-copy and concurrent decode under normal and ASan/UBSan, plus concurrent
  TSan on rerun;
- normal and sanitized pinned conformance;
- all 163 pinned HEVC Main vectors, the Main10 boundary sweep, HEVC tiles,
  AV1 capability, Main10/HDR, VP9 Profile 2, 10-bit throughput, and repeated
  small-geometry RGA;
- GStreamer-VA;
- H.264 and HEVC encode, RGB and multiplane DMABUF import, multislice, and
  WebRTC RTP in normal and sanitized variants;
- concurrent encode/decode, same-process encode/decode in normal and
  ASan/UBSan variants; and
- a 180-second dual H.264+HEVC encode soak smoke with flat resource checks.

The six remaining non-green application cases are not kernel failures:

- VLC and Firefox did not select/load this VA driver in the available desktop
  session; mpv had no Wayland session for its required Panfrost EGL DMABUF
  import gate.
- WebRTC peer normal/sanitized require the uninstalled
  `gir1.2-gst-plugins-bad-1.0` introspection package.
- Same-process TSan exits 66 on a race between FFmpeg's `libavfilter.so.11`
  and `libswscale.so.9`; the retained report contains no Rockchip VA driver
  frame. Normal and ASan/UBSan versions pass.

One per-case canonical kernel scan matched a desktop Wi-Fi deprecation warning
from `ThreadPoolForeg`. The warning is unrelated to the test process or any
accelerator; all accelerator-specific fatal scans remain empty.

## Sustained soak

### 4K H.264 decode: workload and kernel green, strict resource gate red

Run `20260804-211300-vaapi-soak-7200` completed the paced 7,200-second 4K
H.264 VA-API decode workload; the enclosing wrapper elapsed 7,239 seconds.
FFmpeg exited successfully and the before/after `dmesg` snapshots are
byte-identical: zero new lines and zero fatal lines.

The committed `check-soak` resource oracle nevertheless exits 1, propagated as
`make` status 2. Across 239 samples, RSS ranges from 174,644 to 186,808 KiB, a
12,164 KiB span within the 65,536 KiB limit. FD head/tail medians decrease from
56 to 54, but four transient stream-loop-boundary samples are 41, 77, 42, and
75; those make the total span 36, four above the committed limit of 32. The
remaining 235/239 samples are 51–57, including 151 at 54 and 57 at 55.

This is **not evidence of a sustained descriptor leak**: the terminal median
is lower than the initial median, and the rare symmetric close/reopen samples
match the harness's documented MP4 stream-loop behavior. It remains a real
release-gate failure because the committed default rejects the span, and the
script exits before evaluating its retained driver-log lifecycle/frame-count
checks. The result is therefore recorded as workload PASS, kernel scan PASS,
strict userspace resource gate FAIL; no threshold was overridden and no PASS
was manufactured after the fact.

### Dual H.264+HEVC encode

Run `20260804-215805-vaapi-encode-soak-7200` passes the committed full-duration
gate: 7,200 seconds, 216,000 H.264 frames and 216,000 HEVC frames. All
post-warmup samples are exactly 57,260 KiB RSS and 60 fds, for zero span and
zero growth. Both encoder pipelines, lifecycle/resource checks, and the gate
wrapper exit 0. The wrapper elapsed 7,214 seconds; its `dmesg` delta is empty
and the canonical fatal count is zero.

The first approximately 75 minutes overlapped the 4K decode soak, so that
interval also provides mixed sustained decode/dual-encode load. The full raw
driver logs, codec logs, and resource samples are retained under the encode
artifact directory's `work/` subdirectory.

Final whole-boot capture `20260805-000252-final-boot-health` confirms the same
kernel after 4 hours 8 minutes of uptime with taint `0`. The canonical scan has
one match: the already-classified desktop warning that `ThreadPoolForeg` uses
deprecated wireless extensions. It contains no MPP, RGA, IOMMU, DMA-API,
Oops, BUG, hang, or memory-corruption signature; the raw line remains retained
instead of being silently excluded from the count.

## Remaining qualification gaps

- Repeat the default 4K decode soak without unrelated desktop activity and
  require the committed 32-fd span oracle as well as its driver-log lifecycle
  checks. Do not replace this with a raised threshold.
- Rebuild exact `0092` with KASAN, lockdep, and the validation debug options;
  repeat RGA cancellation/session-close and decoder recovery/reset contention.
- Run the root-only debugfs counter/leak snapshots and the remaining targeted
  hostile gates from the `0076`–`0087` audit tail. `sudo dmesg` access supplied
  the journal evidence here, but it does not expose those debugfs files.
- Run authenticated RDP encode/reconnect and the display-session VA-API gates
  in their required session environments. The headless codec and encoder
  results do not substitute for those application integrations.
- Close the already-known GStreamer, libmpp VP9 slot/refcount, official-librga
  demo, FFmpeg TSan, and missing WebRTC-introspection userspace items in their
  owning projects; none changes the production kernel verdict above.
