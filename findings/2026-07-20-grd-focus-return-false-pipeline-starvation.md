# Focus return can falsely charge idle time as a GRD pipeline stall

> Date: 2026-07-20
> Scope: gnome-remote-desktop `exp6@7e958e6`, Windows App on macOS, RK3588
> Result: GDB-INSPECTED / LOG-CORRELATED / SOURCE-FIXED; candidate fix
> `0019@3e4480e` and its `exp7` source/arm64 packages build, with live focus
> validation pending.

## Outcome

Switching away from Windows App to another macOS desktop can suppress capture
long enough for the timestamp of the last hardware submission to become old.
When focus returns, the first new view makes the pipeline nonempty. The
starvation watchdog sampled that new work against the pre-idle submission
timestamp and immediately diagnosed the whole idle interval as a pipeline
stall, forcing a ten-second software-encoding cooldown.

This explains the previously observed correlation between returning to
Windows App and an immediate switch to software rendering. It is separate from
the RDPGFX acknowledgement wedge in
[`2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md`](2026-07-20-grd-rdpgfx-focus-resume-ack-wedge.md):
the ACK failure can hold the renderer at zero frame slots indefinitely, while
this bug falsely trips the defensive hardware-starvation actuator as fresh
work arrives after an otherwise healthy idle interval.

## Exact captured transition

The independent diagnostics were fully drained at `08:24:00`: views and
encodes were complete, and the most recent hardware submission was only 452 ms
old. After the macOS focus return at `08:24:42`, capture had produced fresh
buffer/view activity only about 1 ms old, but no new encode had yet reached the
hardware submission counter. The watchdog reported a 42.493-second stall and
immediately entered software fallback:

```text
[GRD-GDB:92] hardware encode cooldown: reason=pipeline starvation
             duration-us=42493074
[RDP] Hardware encode is unavailable (pipeline starvation,
      duration 42493074 us); using software encoding for 10000000 us
```

The software path continued, and hardware encoding was recreated after the
bounded cooldown. No codec timeout, IOMMU fault, GPU fault, or kernel oops
accompanied the transition. The nearby `rkvenc2_wait_result ... break by
signal` / `ret -512` pairs are interruptible waits stopped by debugger signals,
not evidence of an encoder failure.

## Root cause

Patch `0016` computes starvation age from the later of renderer startup and the
last hardware submission, then actuates recovery whenever any view or encode
work is outstanding. That is correct for a continuously busy pipeline, but it
does not record when a previously drained pipeline first becomes nonempty.
Consequently, a newly started view inherits the age of the last pre-idle
submission.

## Candidate fix: patch 0019

Commit `3e4480e066d3` records the monotonic timestamp when view/encode work
transitions from fully drained to outstanding. The starvation baseline becomes
the latest of renderer start, last hardware submission, and that new-work
timestamp. The timestamp is cleared whenever the pipeline drains again.

Continuously busy pipelines still use submission progress and retain the
existing three-second watchdog. Newly resumed work instead receives the normal
three-second window; idle or output-suppressed time is no longer charged as a
stall.

## Verification state

- The exact false actuator was captured at the `start_hw_encode_cooldown()`
  boundary with arguments and backtrace under GDB.
- Meson/Ninja rebuild of the final two-commit GRD tip passes.
- The portable patch series replays the change as `0019`.
- Debian source and native arm64 package build for
  `50.1+rkmpp+git20260720.8.3e4480e-0ubuntu1~exp7` pass. Lintian reports only
  descriptive-version filename-length warnings. The arm64 package SHA-256 is
  `4adefb3f6cfee85eec767f817a517a2a0458aa11955e90f4a53a6e204add56c0`.
- Remaining gate: install `exp7` after the active debug session ends, repeat
  focus-away/focus-return cycles, and require no immediate `pipeline
  starvation` cooldown from idle time.
