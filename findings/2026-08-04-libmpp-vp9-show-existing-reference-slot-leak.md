# libmpp VP9 `show_existing_frame` reuses a slot-keyed display node as an output event

> Scope: Rockchip userspace MPP VP9 decode, the retained
> `vp9-show-existing.ivf` conformance vector, and the installed RK3588 MPP
> package. This is not a kernel-driver leak.
>
> Source: direct-MPP run
> `20260804-203604-vp9-show-existing`, installed MPP
> `1.5.0+git20260730.ad325345+ds-0ubuntu1~rk1`, maintained source
> `/home/yi/Code/rock-5b/rockchip-userspace/mpp-rockchip`, and a freshly
> fetched Rockchip `develop@df4864bd1e90` (2026-07-28).
>
> Date: 2026-08-04 PDT.
>
> Trust: **MEASURED** for deterministic reproduction, the three dropped
> presentation frames, and the slot-operation imbalance; **SOURCE-PROVEN** for
> duplicate queue-node collapse and missing per-output buffer ownership;
> **INFERRED** only where noted.
>
> Resolution update, 2026-08-05: **FIXED, PUBLISHED, INSTALLED, AND
> HARDWARE-VALIDATED** at `yisding/ysp/main@a8b19653` and PPA package
> `1.5.0+git20260805.a8b19653+ds-0ubuntu1~rk1`. Source publication `18657949`
> is Published, arm64 build `33468629` succeeded, the live normal-PPA packages
> are installed, and installed-runtime correctness, stress, broad differential,
> official-MPP, and bounded kernel-log gates pass.

## Result

The “decode-side libmpp reference-slot defect” was localized and repaired in
public MPP commit `a8b19653`. Before that repair it dropped three required
presentation frames on the retained vector
and left the corresponding reference slots/buffers inconsistent at teardown.
VP9 `show_existing_frame` treats a repeated presentation as if it were
ownership of the underlying decoded slot:

1. the VP9 parser updates the reference slot's canonical `MppFrame` in place;
2. it increments `SLOT_QUEUE_USE` and enqueues that slot on `QUEUE_DISPLAY`;
3. the generic queue has only one intrusive list node per slot, so a second
   enqueue of the same slot removes the first list occurrence and adds the
   same node again; but
4. both enqueues remain charged in the slot's `queue_use` counter, while only
   one occurrence remains available to dequeue.

The retained vector deliberately issues eight consecutive show-existing
events with reference-map indices:

```text
6, 7, 3, 4, 5, 6, 7, 3
```

The repeated `6`, `7`, and `3` targets map to the three residual physical
slots seen at teardown. One-pass decode loses the first presentation of each
of those targets and retains only their later queue positions. Every run also
leaves those three slots `used=1, refer=0, decoding=0, display=2`, then emits
three `clear_slots_impl` assertions and leaked-buffer cleanup.

This is an output-event design bug, not merely a missing decrement. A display
queue keyed by a unique decoded slot cannot represent “display this same
reference twice,” and the parser also overwrites the shared slot frame's
PTS/DTS before the delayed output is consumed.

## 2026-08-05 repair and validation

Public `ysp/main@a8b19653` implements the fix contract at the event boundary:

- slot queues now allocate one queue entry per occurrence instead of reusing
  one intrusive `slot->list` node;
- VP9 `show_existing_frame` uses `mpp_buf_slot_enqueue_frame()` to snapshot the
  presentation `MppFrame`, including its PTS/DTS, and acquire one owned buffer
  reference while atomically adding the queue's two usage holds;
- display dequeue transfers that owned snapshot to `mpp_dec_put_frame()`, which
  publishes it directly instead of creating another shallow frame copy;
- no-hardware-task parser returns push any display entries that are already
  ready, while not-ready entries remain ordered for the HAL completion path;
  and
- `queue_use` is widened from five to twelve bits. The focused regression
  queues 40 snapshots of one slot—beyond the old counter's 32-state range—and
  verifies that every event and its distinct PTS/DTS returns in order.

The native CMake build used the required system `pkg-config`, the centralized
ccache store, and build directory
`../rock-5b/build/libmpp-slot-fix`. Full build and the new
`mpp_buf_slot_test` executable pass. The retained vector was then decoded in
one pass (`-n 0`) through all three relevant client paths:

| Path | Image frames | Raw bytes | Software comparison |
|------|-------------:|----------:|---------------------|
| `mpi_dec_test` | 16 | 2,433,024 | byte-identical |
| `mpi_dec_nt_test` | 16 | 2,433,024 | byte-identical |
| `mpi_dec_mt_test` | 16 | 2,433,024 | byte-identical |

All three outputs match the retained software NV12 oracle with SHA-256
`0056282676abd243c2f36ab3ca13262f57a278a5129d204c88227651ac950098`.
The focused one-pass log contains none of `clear_slots_impl`, `non-positive
ref_count`, `cleaning leaked buffer`, `found * used buffer`, assertion, abort,
or segfault diagnostics.

The original 30-loop × 4-concurrent gate also passes with the patched runtime:
120/120 decoder processes succeed, all 120 logs contain `test success`, none
contains the ownership/teardown signatures above, and the 60-second deferred
kernel scan reports `flagged_kernel_lines=0`. Its `-n 16` behavior still loops
the input and therefore remains a stress/lifetime oracle, not the frame-count
oracle; the separate `-n 0` comparisons above own correctness.

As a regression check beyond VP9, `decode-differential.sh` decodes 30 frames
each of H.264, H.265, VP9, and AV1 through the patched library. Every 640×480
output is 13,824,000 bytes and `average:inf` against software. A sudoers-backed
`dmesg --since` read covering the runs returns no kernel messages; the stress
gate's independent journal scan is also clean.

The reconstructible source-build logs, raw comparisons, and stress bundle
remain disposable build state under `../rock-5b/build/libmpp-slot-fix/`; no
binary or full log bundle is copied into this repository.

<a id="installed-ppa-package-closure"></a>
### Installed PPA package closure

The normal PPA now publishes the exact fixed source and binaries. An official
Launchpad API recheck reports source publication `18657949` Published at
2026-08-05 15:43:46 UTC and arm64 build `33468629` Successfully built. The
live Resolute arm64 index selects
`1.5.0+git20260805.a8b19653+ds-0ubuntu1~rk1`; `librockchip-mpp1`,
`librockchip-mpp-dev`, `librockchip-vpu1`, and `rockchip-mpp-demos` are all
installed at that exact version. `debsums -s` reports no payload mismatch, the
library's ELF package note names the same source/version, and each installed
decoder test resolves `/usr/lib/aarch64-linux-gnu/librockchip_mpp.so.1`.

Installed-runtime replay ran on rewrite KASAN kernel
`6.18.42-video-rewrite-kasan-rockchip64 #2 g19634f4eebba`. This is a compatible
MPP-service implementation and isolates the userspace-package result; it does
not add runtime evidence to the separate `0092` forward-port kernel tail.

| Installed-package gate | Result |
|------------------------|--------|
| Retained one-pass VP9 vector through `mpi_dec_test`, `mpi_dec_nt_test`, and `mpi_dec_mt_test` | Each path returns 16 frames / 2,433,024 bytes, reports `test success`, and is byte-identical to a fresh software NV12 oracle at SHA-256 `0056282676abd243c2f36ab3ca13262f57a278a5129d204c88227651ac950098`; zero slot/refcount/leak diagnostic. |
| Original 30-loop × 4-concurrent teardown stress | 120/120 decoder processes succeed; zero slot/refcount/leak diagnostic and zero fatal line after the 60-second deferred-fault window. |
| Four-codec differential | H.264, H.265, VP9, and AV1 each return 30 frames / 13,824,000 bytes with `average:inf`; bounded journal scan is clean. |
| Official MPP suite | 12/12 required cases pass: info, H.264/H.265/VP9 decode, multi-thread/multi-instance decode, H.264/H.265 encode, both low-delay slice paths, multi-thread H.265 encode, and H.264 RC2. The harness cannot read unprivileged `dmesg`, so an exact 12:43:30–12:43:52 journal sidecar supplies the zero-fatal-line oracle. |

Disposable installed-package evidence lives under
`../rock-5b/build/libmpp-installed-a8b19653/` and
`../rock-5b/build/rockchip-conformance/logs/rewrite/20260805-installed-a8b19653-mpp-suite/`.
The source fix, PPA publication, package selection, package payload, focused
correctness, lifetime stress, cross-codec regression, and official sample
matrix are therefore closed. Broader application-specific behavior remains
owned by the FFmpeg, VA-API, and GRD tracks rather than this MPP defect.

## Reproduction

The production-kernel validation ran:

```sh
LOOPS=30 CONCURRENCY=4 \
  bash kernel-drivers/tests/mpp-vp9-show-existing-repro.sh
```

Artifact directory:

```text
../rock-5b/build/rockchip-conformance/logs/forward-port/
  20260804-203604-vp9-show-existing/
```

All 120 decoder processes exit successfully and the 60-second deferred kernel
window is clean, but the userspace diagnostic is deterministic:

- 720 `mpp_buf_slot` assertion lines: six per process, because each of three
  teardown passes emits the failed `clear_slots_impl` assertion and its
  `_dump_slots` assertion;
- 120 `mpp_buffer_service_deinit cleaning leaked buffer` lines: one per
  process;
- 240 `mpp_buffer_ref_dec ... non-positive ref_count 0 ...
  mpp_frame_deinit` reports: two per process;
- 120 frame-pool teardown reports, each retaining three `MppFrame` objects;
  and
- the first slot dump identifies slots 4, 5, and 6 with `display 2` and status
  `00184001`.

That original command uses `mpi_dec_test -n 16`. It is not a one-pass
16-frame correctness check: because the first pass under-produces, the MPP
test program prints `loop again`, rewinds the input, and decodes part of a
second pass until its requested output count is reached. Its exit 0 therefore
hides the missing presentations while still exposing their ownership damage.

A separate one-pass/EOS run, `20260804-220220-libmpp-vp9-full-eos`, removes
that masking behavior with `mpi_dec_test -n 0` and compares raw NV12 frame
hashes against `/usr/bin/ffmpeg` software VP9 decode:

| | libmpp | Software |
|---|---:|---:|
| Display frames with image data | 13 | 16 |
| Raw bytes | 1,976,832 | 2,433,024 |
| Fatal kernel lines | 0 | 0 |

Each 352×288 NV12 frame is 152,064 bytes, so the byte counts independently
confirm the 13/16 split. Frames 0–7 match software. Software frames 8–15 are
the eight show-existing presentations; libmpp emits only the hashes
corresponding to software frames 11–15. Software frames 8, 9, and 10—the first
presentations of reference-map identities `6`, `7`, and `3`—are absent. The
later repeats survive because `list_del_init()` moves their unique slot nodes
to the later queue positions. The one-pass decoder still exits 0 and retains
the same six assertions, two non-positive references, three frame objects,
and leaked-buffer cleanup.

The operation history makes the lost event/count mismatch direct. Slot 4,
with equivalent sequences on slots 5 and 6, records:

```text
set queue use   00180005 -> 00182005
enqueue display 00182005 -> 00184005
set queue use   00184005 -> 00186005
enqueue display 00186005 -> 00188005
dequeue display 00188001 -> 00186001
clr queue use   00186001 -> 00184001
```

Two logical output events add four queue-use units, but the single slot list
node can be dequeued only once and removes two. The residual is exactly
`display=2`.

FFmpeg's VP9 header trace independently confirms that the final eight one-byte
IVF packets are the reference sequence above. This is why both the dropped
frame count and the residue are exactly three rather than timing-dependent.

## Source mechanism

### VP9 parser queues the reference slot itself

In `mpp/codec/dec/vp9/vp9d_parser.c`, the show-existing arm obtains the
reference slot's `SLOT_FRAME_PTR`, mutates its PTS/DTS, then performs:

```c
mpp_buf_slot_set_flag(slots, slot, SLOT_QUEUE_USE);
mpp_buf_slot_enqueue(slots, slot, QUEUE_DISPLAY);
```

It returns without a hardware task. The parser thread can therefore consume
several show-existing packets while the HAL thread has no task to wake it and
drain display output. Consecutive repeats of one reference slot accumulate in
this window.

### The queue stores slots, not events

`mpp/base/mpp_buf_slot.c:mpp_buf_slot_enqueue()` increments `queue_use` and
then unconditionally does:

```c
list_del_init(&slot->list);
list_add_tail(&slot->list, &impl->queue[type]);
```

There is one `slot->list` node, shared by every queue type and every logical
presentation. Re-enqueue therefore coalesces an old occurrence without
undoing its accounting. `mpp_buf_slot_dequeue()` can observe only the surviving
node.

`SLOT_SET_QUEUE_USE` and `SLOT_ENQUEUE_DISPLAY` each increment the same
five-bit `queue_use` counter. The matching normal output path decrements it
once in `SLOT_DEQUEUE_DISPLAY` and once in `SLOT_CLR_QUEUE_USE`. That +2/-2
protocol is balanced for one queue occurrence, but not after an occurrence is
silently removed by duplicate enqueue.

### Repeated external frames do not acquire a buffer reference

The output side compounds the slot leak. `mpp_dec_put_frame()` creates an
external `MppFrame` and calls `mpp_frame_copy(out, frame)`. The copy is a
structure copy; it increments metadata ownership but does not increment the
copied `MppBuffer`. `mpp_frame_deinit()` later puts that buffer.

The normal decoder allocation path carries one buffer reference intended for
one external output frame. Re-presenting one decoded reference more than once
creates multiple shallow external frames without taking one corresponding
buffer reference per presentation. The observed non-positive refcount reports
are consistent with that source-proven ownership mismatch. The exact point at
which the final service cleanup retains its buffer is not separately traced,
so that last transition remains inferred rather than claimed as measured.

## Upstream state

The installed package contains Rockchip commit `b5f30438150e` (“Fix error when
show existing frame case,” 2026-01-28). That change correctly moves the
show-existing return ahead of compressed-header parsing, but preserves the
same slot mutation and enqueue sequence. The older `774f1ffbc5b3` PTS fix
(2021-02-01) also retained that sequence.

After a fresh fetch, `origin/develop` is `df4864bd1e90` dated 2026-07-28. Its
VP9 show-existing code and its slot enqueue implementation are unchanged from
the affected installed source; the only newer `mpp_buf_slot.c` change is an
unrelated scale-down format correction. Searches of the public
`rockchip-linux/mpp` issue and pull-request tracker for the exact assertion,
refcount, leak-cleanup, and show-existing terms returned no report or pending
fix. The source tree also contains no targeted show-existing regression test.

## Why this was not fixed with the July crash work

The July finding correctly split one trigger into three independent defects:

1. a VA-API stride/allocation overrun;
2. this libmpp VP9 slot/refcount defect; and
3. a kernel client-less-session NULL dereference.

The VA-API and kernel defects received owning patches and gates. The libmpp
leg was labelled “separate, open userspace item,” but no libmpp track/watch,
patch branch, or upstream issue was created. The retained reproducer remained
a kernel crash-capture gate: it requires at least one decoder success and a
clean kernel journal, but never scans `dec-*.log` for libmpp assertions,
non-positive references, or leak cleanup. Consequently it has kept returning
PASS while preserving the defect in every process log.

## Fix contract

A correct repair must treat show-existing output as an event with independent
metadata and lifetime, not as another ownership bit on the decoded DPB slot:

1. represent every display occurrence with a distinct queue entry, even when
   several entries name the same physical/reference slot;
2. snapshot PTS/DTS and other presentation metadata per occurrence instead of
   mutating the shared DPB `MppFrame`;
3. acquire one `MppBuffer` reference for every external output frame and
   release it exactly once when that frame is destroyed; and
4. retain the DPB slot/reference independently until the codec no longer
   references it.

Simply refusing a duplicate enqueue or compensating the counter would hide
the teardown assertion while dropping required frames and retaining the
shared-PTS overwrite. A fresh-slot workaround could satisfy the contract, but
an explicit display-event queue is the less codec-specific design and would
also cover AV1, whose `set_output_frame()` currently uses the same slot-keyed
queue pattern.

The regression gate should decode the retained vector without an artificial
output-count truncation, compare output count/order/frame hashes and PTS to a
software decoder, then require all of the following to be absent:

```text
clear_slots_impl
non-positive ref_count
cleaning leaked buffer
found * used buffer
```

It should repeat one reference slot several times before any display drain so
the test cannot pass merely because scheduling happened to serialize enqueue
and dequeue.
