# Upstreaming decisions — Rockchip MPP library

This package holds the userspace `librockchip_mpp` fork (codec parsers, HALs,
buffer pools, and the MPP ioctl client); this file is its upstream submission
disposition as decided on 2026-07-29, and it does not itself resolve
cross-package ordering or coupling — that lives in the central
[upstreaming ledger](../../docs/upstreaming-ledger.md). Dated claims below
(upstream develop state, PR/merge counts, "still present verbatim") must be
re-verified against a fresh fetch before anyone acts on them.

## Decision list

| ID | Item | Artifact | Upstream target | Decision | Priority | Gates / prerequisites |
|----|------|----------|------------------|----------|----------|------------------------|
| MPP-1 | Harden the eight vepu5xx split-output encoder slice poll loops against poll failure | yisding/mpp@ysp/main `0ba460e` | rockchip-linux/mpp (PR, develop) | SUBMIT-NOW | P1 | — |
| MPP-2 | Fix the h264e poll cfg allocation size and the vepu511a single-cfg reg_idx indexing | yisding/mpp@ysp/main `d2dbe1b` | rockchip-linux/mpp (PR, develop) | SUBMIT-NOW | P1 | — |
| MPP-3 | HEVC same-ID PPS update never reaches the HAL (stale hardware tile table on TILES_A_Cisco_2) | yisding/mpp@ysp/main `d8c6b88` | rockchip-linux/mpp (no longer needed) | NEVER | P3 | — |
| MPP-4 | mpp_runtime_test pthread start-routine signature (GCC 15 / newer glibc build failure) | yisding/mpp@ysp/main `7c4fcda` | rockchip-linux/mpp (not needed) | NEVER | P3 | — |
| MPP-5 | HEVC RADL pictures suppressed at random access: h265d_nal_unit()'s second, over-broad non-IRAP/POC test drops valid pictures (NUT_A_ericsson) | yisding/mpp@ysp/main `3381fd2c` (fixed 2026-07-29) | rockchip-linux/mpp (issue) | SUBMIT-AFTER-GATE | P2 | Confirm the over-broad non-IRAP/POC test still exists at the develop tip (present at 1.0.12 base `1375813c`, h265d has taken four upstream fixes since); re-confirm by local diff of a fetched develop tree, not a summarised web fetch |
| MPP-6 | Modernize the in-tree debian/ packaging (debhelper 13, Standards 4.7.4.1, SONAME-correct librockchip-vpu1, dev-package symlinks, distro build flags) | `packaging/ppa/mpp/debian/` (full replacement of upstream's in-tree debian/) | rockchip-linux/mpp (PR, develop) | HOLD | P3 | Strip ROCK-5B/PPA-specific choices (arm64-only Architecture, "resolute" distribution, +git/+ds/~rk versioning, ysp changelog lineage); confirm upstream still builds from its in-tree debian/ and maintains the independent 1.5.x packaging lineage; decide whether the librockchip-vpu0 → librockchip-vpu1 SONAME correction goes alone as a small bug-shaped PR |
| MPP-7 | MPP async encoder input backpressure: mpp_put_frame_async returns MPP_NOK under sustained load with no documented flow-control contract | No MPP-side patch; diagnosis only | rockchip-linux/mpp (issue) — not filing | NEVER | P3 | — |
| MPP-8 | Ask MPP for a wider AFBC decode geometry so narrow (<68px) 10-bit surfaces can be RGA-converted | No patch, no confirmed defect | rockchip-linux/mpp (issue / feature question) | HOLD | P3 | Read the MPP AFBC allocation path to establish from source whether pixel_stride/header geometry is caller-controllable at all; rule out cheaper alternatives first (linear NV15 with CPU repack, per-core/per-storage-mode rejection in librga); only then file a question upstream |

## Rationale and evidence

### MPP-1 — Harden the eight vepu5xx split-output encoder slice poll loops against poll failure

All eight vepu5xx split-output HALs assign the `MPP_DEV_CMD_POLL` return value
but never check it, terminating only on a last-flag read out of the returned
records (the four h264e HALs also leave that flag uninitialised); a kernel
poll error with `count_ret == 0` spins forever, matching hardware logs of
continuous `mpp_service_cmd_poll` failures. The fix consumes returned records
first, fails the frame on a poll error, bounds consecutive empty-but-successful
polls, and emits a terminal `ENC_OUTPUT_FINISH` so a low-delay consumer is
never left waiting. Verified on booted hardware (2026-07-25, forced
`MPP_ENC_SPLIT_MODE=2`/`SPLIT_ARG=4`/`SPLIT_OUT=1`) with both slice suites
passing and zero flagged kernel lines, and shipping in the PPA since
1.5.0+git20260725.7c4fcda2+ds; the defect is confirmed still present verbatim
at the rockchip-linux/mpp develop tip as of 2026-07-29. rockchip-linux/mpp is
active (pushed 2026-07-28) but merges only about 3 of 48 PRs, so a companion
issue should accompany the PR rather than relying on merge rate as a
receptiveness signal. Couples with the kernel-side rkvenc2 FIFO reservation
(KFP-6): the kernel fix alone still leaves this loop able to spin, and this
fix alone still drops the terminal record, so both should be referenced from
each other even though they land in different upstreams; within this package,
submit MPP-2 first and stack this on top since they touch the same four
h264e files.

- Evidence: [findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md](../../findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md), [kernel-drivers/tests/conformance/patches/rockchip-mpp/0001-harden-encoder-slice-poll-loops.patch](../../kernel-drivers/tests/conformance/patches/rockchip-mpp/0001-harden-encoder-slice-poll-loops.patch), [packaging/userspace-patches.md](../../packaging/userspace-patches.md), [packaging/ppa/mpp/debian/changelog](../../packaging/ppa/mpp/debian/changelog), [docs/source-trees.md](../../docs/source-trees.md), [docs/status-ledger.md](../../docs/status-ledger.md)
- Coupled with: MPP-2, KFP-6

### MPP-2 — Fix the h264e poll cfg allocation size and the vepu511a single-cfg reg_idx indexing

The four h264e vepu5xx HALs size their `MppDevPollCfg` allocation with
`sizeof(p->poll_cfgs)` (pointer size, 8 bytes) rather than the struct it
points at (16 bytes), so the kernel — told the buffer is 48 bytes via
`sizeof(*cfg) + count_max * 4` — is licensed to write past a 40-byte
allocation; in vepu580/vepu510 this can alias adjacent task records, masked
today only by allocator rounding. vepu511a separately derives its poll cfg
pointer via `task->flags.reg_idx` over a single-config allocation copied from
the multi-task vepu580 HAL — an out-of-bounds access for any non-zero
reg_idx, though reg_idx is always 0 today so it does not currently fire. The
fix uses `sizeof(MppDevPollCfg)` and indexes the single config directly, as
hal_h264e_vepu511.c already does; the h265e HALs already allocate enough
space and are untouched. Verified on the same booted-hardware gate as MPP-1
(2026-07-25) and shipping in the PPA since 1.5.0+git20260725.7c4fcda2+ds; the
sizing defect is confirmed still present at the develop tip as of 2026-07-29.
Filed as its own review thread rather than folded into MPP-1 because it is a
self-contained sizing/indexing correction, reviewable independently of MPP-1's
larger 348-line behavioural change; if the maintainer prefers a single PR,
submit this one first and stack MPP-1 on top, since both touch the same four
h264e files.

- Evidence: [findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md](../../findings/2026-07-20-rkvenc2-slice-fifo-terminal-drop.md), [packaging/userspace-patches.md](../../packaging/userspace-patches.md), [packaging/ppa/mpp/debian/changelog](../../packaging/ppa/mpp/debian/changelog), [docs/source-trees.md](../../docs/source-trees.md)
- Coupled with: MPP-1

### MPP-3 — HEVC same-ID PPS update never reaches the HAL (stale hardware tile table on TILES_A_Cisco_2)

Superseded: rockchip-linux/mpp fixed this independently before this fork did,
so nothing remains to submit. Root-caused and fixed here on 2026-07-27 with a
strong evidence chain (measured, root-caused, board-reproduced, fix-verified,
package-verified) — a stream replacing PPS ID 0 with a different tile grid
between pictures left the RK3588 HAL running the stale layout — but a
2026-07-29 check of develop shows the equivalent consumer already landed as
upstream commits 4229f17 (2026-06-03) and 974914b (2026-07-27). This fork's
commit exists only because the packaging baseline is tag 1.0.12 (predating
both fixes); the useful follow-up is rebasing `ysp/main` onto a post-4229f17
base to retire the commit, not an upstream submission.

- Evidence: [findings/2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md](../../findings/2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md), [packaging/userspace-patches.md](../../packaging/userspace-patches.md), [packaging/ppa/mpp/debian/changelog](../../packaging/ppa/mpp/debian/changelog), [docs/source-trees.md](../../docs/source-trees.md), [findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md](../../findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md), [status.md](../../status.md)

### MPP-4 — mpp_runtime_test pthread start-routine signature (GCC 15 / newer glibc build failure)

Already fixed upstream; a pure baseline artifact. `mpp_runtime_test` passed a
no-argument `wait_thread` to `pthread_create()`, which newer GCC/glibc headers
reject; a 2026-07-29 fetch of develop confirms the fix (`void
*wait_thread(void *data)` with `(void)data;`) is already present. The commit
exists solely because the packaging baseline is the 1.0.12 tag and disappears
on rebase past current develop. A related but unfixed GCC 15 enum/int test
build error (worked around with `-DBUILD_TEST=OFF`, not patched) is
deliberately not turned into a second item — revisit only if it survives a
rebase onto current develop.

- Evidence: [packaging/userspace-patches.md](../../packaging/userspace-patches.md), [packaging/ppa/mpp/debian/changelog](../../packaging/ppa/mpp/debian/changelog), [findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md](../../findings/2026-07-11-kodi-ffmpeg-rockchip-hwaccel.md), [docs/source-trees.md](../../docs/source-trees.md)

### MPP-5 — HEVC RADL pictures suppressed at random access (NUT_A_ericsson)

Root-caused and fixed as of 2026-07-29, superseding an earlier hold based on
an unreduced two-vector count from the 2026-07-28 FATE sweep. `h265d_nal_unit()`
suppressed every non-IRAP picture whose POC is below `max_ra`, which catches
valid RADL as well as RASL; the fix (`ysp/main` `3381fd2c`, h265d_flow.c +3
-7) runtime-verifies all 34 pictures of the stream with zero error or discard
flags. Two premises in the prior sweep were also wrong: NUT_A_ericsson_4 and
_5 are one byte-identical stream counted twice, and 27-of-34 decoded is not
"undecodable." This absorbs the vaapi track's duplicate row for the same two
vectors (their dedup note assigns ownership here) and the librga track's
narrow-AFBC row's MPP half is a separate question (MPP-8), not this one. The
PICSIZE_A/B_Bossen_1 failures from the same sweep remain correctly-refused
oversize streams, not defects. Gate before filing: confirm the (now fixed
downstream) over-broad non-IRAP/POC test's upstream state via a local diff of
a fetched develop tree, since h265d has taken four upstream fixes since the
1.0.12 packaging baseline and no fresher develop fetch has been done locally.

- Evidence: [findings/2026-07-29-hevc-nut-radl-and-unused-rps-reference-fixes.md](../../findings/2026-07-29-hevc-nut-radl-and-unused-rps-reference-fixes.md), [findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md](../../findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md), [findings/2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md](../../findings/2026-07-27-rockchip-mpp-hevc-tiles-same-id-pps-update.md), [docs/status-ledger.md](../../docs/status-ledger.md)

### MPP-6 — Modernize the in-tree debian/ packaging

Retires genuine fork delta — an entire tracked packaging tree — against a
real defect (upstream's debian/ untouched since 2021, naming a
`librockchip-vpu0` runtime package that no longer matches the shipped
SONAME). But it is the weakest-value item in this track: Debian/Ubuntu
packaging offered to a vendor SDK repo, entangled with ROCK-5B-specific
choices (arm64-only, "resolute" distribution, +git/+ds/~rk versioning) that
must be unpicked first. Held until the two functional PRs (MPP-1, MPP-2) have
landed or been answered, since their reception is the cheapest available read
on whether a packaging PR is worth writing; if only one piece is ever sent,
send the SONAME rename alone.

- Evidence: [packaging/ppa/mpp/debian/changelog](../../packaging/ppa/mpp/debian/changelog), [packaging/ppa/mpp/debian/control](../../packaging/ppa/mpp/debian/control), [packaging/userspace-patches.md](../../packaging/userspace-patches.md), [packaging/ppa/build-source-packages.sh](../../packaging/ppa/build-source-packages.sh), [packaging/external-workspaces.md](../../packaging/external-workspaces.md)

### MPP-7 — MPP async encoder input backpressure

Correctly diagnosed as a caller-side flow-control problem, so there is no MPP
defect to report. A finite input task pool signalling backpressure with
`MPP_NOK`, followed by a bounded `get_packet` returning `MPP_ERR_TIMEOUT`, is
legitimate MPP behaviour; what was wrong was the FFmpeg rkmpp wrapper, fixed
in ffmpeg-rockchip-81 (FF-8), not here. The only MPP-side idea on record —
raising the input task/buffer count — is unimplemented, unmeasured, and a
tuning knob rather than a bug; recorded so it is not re-opened as an MPP
defect.

- Evidence: [findings/2026-07-19-grd-rkmpp-encoder-wedge-mpp-input-backpressure.md](../../findings/2026-07-19-grd-rkmpp-encoder-wedge-mpp-input-backpressure.md), [findings/2026-07-19-grd-rkmpp-encoder-wedge-userspace-not-driver.md](../../findings/2026-07-19-grd-rkmpp-encoder-wedge-userspace-not-driver.md), [docs/status-ledger.md](../../docs/status-ledger.md)
- Coupled with: FF-8

### MPP-8 — Ask MPP for a wider AFBC decode geometry

Unripe, and possibly not an MPP item at all. For `WPP_D_ericsson_MAIN10_2.bit`,
MPP hands over an AFBC surface whose header stride equals the visible width,
leaving no spare columns for RGA3's 68-pixel minimum active rectangle; it is
explicitly unverified whether MPP exposes caller control over that geometry.
The user-visible failure is already closed downstream — local rockchip-vaapi
commit `491533e` refuses sub-68-pixel Main10/VP9 Profile 2 contexts at
`vaCreateContext()` — so the upstream ask, if any, is a throughput
optimisation rather than a correctness fix. Filing before reading MPP's own
AFBC allocation path, and before ruling out cheaper alternatives (linear
NV15 with CPU repack, per-core/per-storage-mode rejection in librga), would
be premature; neither this nor the paired librga item (RGA-8) is filed until
that reading happens, since the two share one root cause and a speculative
pair of reports would expose that the cheaper alternatives were not checked.

- Evidence: [findings/2026-07-29-rga-no-core-match-narrow-afbc-10bit.md](../../findings/2026-07-29-rga-no-core-match-narrow-afbc-10bit.md), [findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md](../../findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md), [findings/2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md](../../findings/2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md)
- Coupled with: RGA-8
