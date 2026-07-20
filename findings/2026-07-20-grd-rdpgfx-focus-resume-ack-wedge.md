# macOS focus return can wedge GRD in restored RDPGFX acknowledgement history

> Date: 2026-07-20
> Scope: gnome-remote-desktop `exp5@b3f0e20`, Windows App on macOS, RK3588
> Result: MEASURED / CORE-INSPECTED / SOURCE-INSPECTED /
> RUNTIME-RECOVERY-VALIDATED. Cleaned fix `0018@34145d9` builds; its
> functionally equivalent installed `exp6@7e958e6` predecessor fired once and
> restored hardware frame progress in the exact live focus workload.

## Outcome

This freeze is not another MPP, FFmpeg, Mesa-readback, or kernel failure. The
client explicitly suspended RDPGFX frame acknowledgements while Windows App was
in another macOS desktop. On return it resumed acknowledgements with a large
decoded-frame deficit. GRD reconstructed the frames accumulated during the
suspension as ordinary unacknowledged work, drove the surface's available frame
slots to zero, and never received enough acknowledgement progress to release
that throttle.

The captured process remained alive, accepted input, and retained a connected
transport. Its encoder and renderer workers were idle because the frame
controller allowed no new work. This explains both observations from the same
test: returning to Windows App first delivered a burst of queued frames, and a
later return left the image completely wedged.

## Exact captured state

The preserved core is:

```text
/home/yi/Code/grd-wedge-runs/20260720-0635-focus-ack-wedge/core.8343
```

At capture time:

- the graphics pipeline had encoded 16,636 frames;
- frame IDs 15,728 through 16,635 were retained as one contiguous set of 908
  reconstructed/unacknowledged frames;
- `frame_acks_suspended` was false, proving the resume PDU had been processed;
- the frame controller was still active/throttled (`activate=2`,
  `deactivate=1`) with a measured 6,961 µs RTT;
- the surface renderer had zero total frame slots;
- the latest and pending source serial were both 17,087, so capture was not
  waiting on an unseen newer source frame; and
- no concurrent kernel codec/GPU/IOMMU error or hardware-encode failure
  explained the stop.

The 908-frame interval and zero-slot controller state are the decisive data.
This was backpressure retained after an acknowledgement resume, not an encoder
thread blocked inside MPP and not the uncached `glReadPixels` cliff fixed by
patch `0017`.

## Protocol and source boundary

Microsoft's MS-RDPEGFX specification defines queue depth `0xFFFFFFFF` as
`SUSPEND_FRAME_ACKNOWLEDGEMENT`. On receipt, the server clears its set of
unacknowledged frames and must not block frame transmission. A later PDU with a
normal queue depth resumes acknowledgement processing; `totalFramesDecoded` is
the number decoded since the connection began:

- [RDPGFX_FRAME_ACKNOWLEDGE_PDU structure](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/0241e258-77ef-4a58-b426-5039ed6296ce)
- [Processing a Frame Acknowledge PDU](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/d64cfae6-f30a-47e7-9655-d019d3d8fb0f)

GRD correctly clears live unacknowledged state on suspension, but intentionally
keeps a bounded encoded-frame history. On resume,
`maybe_rewrite_frame_history()` converts the client's decoded-frame deficit
back into tracked unacknowledged frames. That reconstruction was introduced to
support clients such as mstsc opting back into acknowledgements, so discarding
all history on every resume would remove intended slow-client throttling.

The defect is narrower: reconstructed history can become permanent when the
client sends a syntactically valid resume but then makes no decode progress.
There was no independent escape from the resulting zero-slot state.

## Candidate fix: patch 0018

Commit `34145d92e8ee` preserves normal reconstruction and adds a bounded escape:

1. log acknowledgement suspend/resume values under `[RDP.RDPGFX.ACK]`;
2. arm a two-second watchdog only after a real suspended-to-resumed transition
   that reconstructed pending history;
3. keep waiting while `totalFramesDecoded` advances;
4. if it does not advance and reconstructed acknowledgements remain, clear the
   stale frame/controller history, unthrottle the surfaces, and request a full
   render-context refresh; and
5. cancel the watchdog on another suspension, graphics reset, or disposal.

The refresh is deliberate: it makes the first post-recovery hardware frame a
clean stream restart rather than depending on delta content the client may not
have decoded. The timeout is scoped to this transition, so ordinary long-lived
slow-client throttling is unchanged.

## Verification state

- Meson/Ninja build: pass.
- Focused tests on the functionally equivalent `exp6@7e958e6` predecessor:
  `gnome-remote-desktop/rdp` passes; EGL and TPM skip because the isolated test
  environment has no accelerated EGL device or TPM; zero test failures.
- Debian source and arm64 binary package build for
  `50.1+rkmpp+git20260720.7e958e6-0ubuntu1~exp6` passes. The cleaned final
  commit removes only a high-volume zero-slot transition diagnostic.
- Final combined source and arm64 package
  `50.1+rkmpp+git20260720.8.3e4480e-0ubuntu1~exp7` also builds; lintian reports
  only descriptive-version filename-length warnings.
- Installed binary package requires the published FFmpeg backpressure fix
  `libavcodec62 >= 7:8.0.3+rockchip+git20260719.da5befc806-0ubuntu1~rk1`.
- The live `exp6` focus run fired the real watchdog once at `08:43:39` with
  `total-decoded=7756` and two pending acknowledgements. A pre-recovery core is
  preserved at
  `/home/yi/Code/grd-wedge-runs/20260720-exp6-ack-recovery.core`.
- Before recovery, buffers advanced from 8,082 to 8,142 while queued work and
  hardware submissions remained fixed at 7,915 and 7,758. The two-second
  warning then cleared the stale ACK state, forced a full refresh, recreated
  `h264_rkmpp`, and advanced submissions to 7,761 in the same journal second.
  Continued hardware traffic later advanced the submission counter past
  11,000; the service stayed active.
- The same run independently exposed the false pipeline-starvation actuator
  fixed by `0019`; see the
  [separate finding](2026-07-20-grd-focus-return-false-pipeline-starvation.md).
- Remaining gate: install final `exp7@3e4480e` and confirm repeated focus cycles
  retain the validated ACK recovery while eliminating the idle-time false
  fallback.

Patch `0018`'s functional recovery is runtime-confirmed. The final cleaned
`exp7` package is not yet installed, so combined `0018` + `0019` promotion
remains gated on that last run.
