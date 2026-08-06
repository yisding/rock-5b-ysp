# FFmpeg RKMPP async-frame lifetime fix clears reset/close double release

> Scope: FFmpeg `h264_rkmpp` encoder lifetime on RK3588; `status.md` track 5
> Source: `yisding/ffmpeg-rockchip-81` `fix/rkmpp-output-timeout@c9428bedaa45448d79c629f6be83a41257ac6167`; `libavcodec/rkmppenc.c` `rkmpp_submit_frame()`, `clear_frame_list()`, `rkmpp_encode_flush()`, and `rkmpp_encode_close()`
> Date: 2026-07-30
> Trust: MEASURED, SOURCE-INSPECTED, COMPILE-VERIFIED, CONFIRMED

## Result

The delayed libmpp errors seen after a GNOME Remote Desktop hardware-encode
timeout were a deterministic FFmpeg lifetime defect:

```text
mpp_buffer_ref_dec buffer from rkmpp_submit_frame found non-positive ref_count 0 caller mpp_frame_deinit
mpp_mem_pool_put invalid mem pool ptr ... check (nil)
```

A successful nonblocking `encode_put_frame()` hands the `MppFrame` to libmpp.
The frame stays owned there until it is returned in `KEY_INPUT_FRAME` packet
metadata. On reset, libmpp completes or skips queued inputs and places those
ownership returns on its packet list. On destroy, the packet/input-list
destructors deinitialize any frames still owned by libmpp.

FFmpeg retained the same raw `MppFrame` pointer in `MPPEncFrame`. Its close path
called MPP reset and destroy, then `clear_frame_list()` recovered the
`MppBuffer` through that already-destroyed frame and deinitialized the frame a
second time. The first extra put freed the last buffer reference; the following
`mpp_frame_deinit()` produced the non-positive reference count and returned the
same frame-pool node twice.

Source commit `c9428bedaa` makes the ownership boundary explicit:

- `MPPEncFrame` retains FFmpeg's independent imported-`MppBuffer` reference, so
  cleanup does not need to recover it through an `MppFrame`;
- after MPP teardown, `clear_frame_list()` releases only unsent frames, because
  submitted frames have already been released by MPP;
- encoder flush drains the reset-return packet list and reclaims each returned
  input before dropping FFmpeg's tracking records; and
- submit-failure and normal packet-return cleanup release both references
  exactly once.

## Upstream scope

Current `nyanmisaka/ffmpeg-rockchip` master
`388741a3544b92cf525f1cb3746ba9fb8f301d9a` has the same defect. Its encoder
selects nonblocking MPP input, retains raw `MppFrame` pointers in
`MPPEncFrame`, and still performs `reset()` → `mpp_destroy()` →
`clear_frame_list()`, where the clear path recovers the buffer through and
deinitializes the stale frame.

Current mainline FFmpeg master
`a441a2eb383960d76632eb5dc42639ec52d46bd8` does not have this exact defect.
Its distinct RKMPP encoder leaves MPP input in the default blocking mode,
deinitializes the frame after `encode_put_frame()` has returned the input task,
and has no async FFmpeg-side `MPPEncFrame` list to walk after reset. This does
not establish that mainline RKMPP is free of other defects; it only excludes
the reset/close double release proven here.

## Evidence and reproduction

- **Runtime identity:** ROCK 5B, kernel
  `6.18.41-video-rewrite-kasan-rockchip64 #21`; installed FFmpeg
  `7:8.0.3+rockchip+git20260729.33a651a55b-0ubuntu1~rk1` and MPP
  `1.5.0+git20260729.3381fd2c+ds-0ubuntu1~rk1`.
- **Affected observation:** the user GRD daemon created a
  2064×1296 `h264_rkmpp` session, then hit bounded 499–505 ms `EAGAIN`
  failures. Closing/recreating that encoder produced the two diagnostics above.
- **Source discriminator:** libmpp's nonblocking encoder keeps submitted
  `MppFrame` pointers in `mFrmIn`, returns them through packet
  `KEY_INPUT_FRAME` metadata, and gives its packet/input lists destructors that
  deinitialize retained frames. FFmpeg's old close order was
  `reset()` → `mpp_destroy()` → unconditional `mpp_frame_deinit()`.
- **Compile gates:** a system-toolchain build of
  `libavcodec/rkmppenc.o` passed; the RKMPP-only static libraries and focused
  test binary linked successfully; `make fate-source` passed.
- **Package gate:** source package
  `7:8.0.3+rockchip+git20260730.c9428bedaa-0ubuntu1~rk1` builds from the exact
  fix commit; `dscverify --nosigcheck` validates every source artifact and
  `lintian --fail-on error` passes with only the inherited
  `newer-standards-version` warning. A fresh `dpkg-source -x` succeeds, and its
  `rkmppenc.c`/`.h` byte-match commit `c9428bedaa`.
- **Hardware close gate:** a local, untracked API harness submitted one
  2064×1296 NV12 input, required `avcodec_receive_packet()` to report an
  outstanding asynchronous frame, and immediately closed the context. The old
  cleanup signature reproduced in one iteration during diagnosis. The corrected
  commit passed 10/10 consecutive close iterations with no refcount or pool
  diagnostic.
- **Hardware flush gate:** the same harness performed reset/flush with an
  outstanding frame, resumed submission until a post-flush packet returned,
  and then closed. It passed 10/10 iterations with no lifetime diagnostic.
- **Kernel scan:** the hardware gates added no RKVENC, IOMMU, KASAN, timeout, or
  fault line to the kernel journal.
- **Artifacts:** none committed. The local harness is intentionally not added
  to this public repository because its affected-code run provokes a
  double-release; the repository contract places such reproducers in
  `rock-5b-security`.

## Source upload — 2026-08-05

The source package was signed with
`0FDDE6BC55FF095DF2A92BB78F3025C4AA2228E6`. Direct GPG verification reports a
good signature from `Yi Ding <yi.s.ding@gmail.com>` for the `.dsc`, source
`.buildinfo`, and source `.changes`. `dput` passed its distribution,
required-field, checksum, suite, source-only, and GPG gates and transferred all
five source artifacts to `ppa:yi-ding/ubuntu-rock-5b` at approximately 13:35
PDT. At this finding's requested stop point, Launchpad acceptance, build, and
publication had not been queried, so predecessor `33a651a55b` was the last
confirmed live version. [W05](../status.md#watch-w05) owns every later service
recheck; this dated upload record is not a publication ledger.

## Boundary

This closes the buffer/frame double-release in FFmpeg source and proves close
plus flush/reuse against the board's real MPP encoder. It does **not** explain
why the original RDP frame missed the 500 ms encoding deadline, and it does not
make the currently installed `33a651a55b` binary safe. The GRD hardware-path
latency/backpressure investigation remains separate.

## Verification gate

Build and install
`7:8.0.3+rockchip+git20260730.c9428bedaa-0ubuntu1~rk1`, then repeat the measured
RDP fallback/recreation workload. Require:

1. no `mpp_buffer_ref_dec ... non-positive ref_count` or
   `mpp_mem_pool_put invalid mem pool ptr` line across repeated hardware
   cooldown/recreation cycles;
2. an active RDP session through the same cycles, including software fallback;
3. a clean kernel fatal-signature scan; and
4. an exact installed package/payload identity capture.

That integration gate can confirm the lifetime fix in the real daemon. Encoder
latency still needs its own timing evidence around import, input submission,
and packet return.
