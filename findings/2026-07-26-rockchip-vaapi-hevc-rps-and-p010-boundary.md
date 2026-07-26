# rockchip-vaapi HEVC RPS boundary, with P010 fixed below it

> **Superseded 2026-07-26:** this records an intermediate investigation, not the
> final HEVC result. `rockchip-vaapi` commit `f03905a` subsequently made seven of
> eight pinned HEVC Main vectors bit-exact by reconstructing SPS reference sets
> and picture scaling lists; the remaining TILES vector also fails in direct MPP.
> Commit `820d88c` then validated Main10 bit-exact through MPP AFBC and RGA P010.
> See `2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md`.
>
> Scope: `rockchip-vaapi` Phase 2 HEVC/10-bit work on RK3588, plus the
> kernel/librga dependency it rides on.
>
> Source: working checkout `../rockchip-vaapi` (`src/hevc.c`
> `validate_picture_parameters()` / `collect_rps()` /
> `rk_hevc_rewrite_slice_nal()`, `src/mpp_dec.c` `build_hevc_job()`), direct
> VA-API/FFmpeg/MPP experiments from that tree, and booted forward-port
> validation artifacts under `../rockchip-conformance/logs/forward-port/`.
>
> Date: 2026-07-26.
>
> Trust: **MEASURED** / **CODE-INSPECTED** / **INFERRED** / **PARTIAL**.

## Result

The P010/NV15 failure that could have confused `rockchip-vaapi` Main10 work is
closed below the VA-API driver: on the booted `6.18.40-video-port-kasan-rockchip-rk3588 #2`
KASAN forward-port (`/sys/kernel/notes` sha256
`66e0815b10770bdc8ec4352076eacc693d7fc0a39c39b3b50d5a7eb7eda5eac4`), raw RGA
10-bit stride/UV-offset gates passed, fresh-librga P010/NV15 im2d probes passed,
and the installed `librga2` / `librga-dev 2.2.0+git20260725.26a50ef-0ubuntu1~rk1`
smoke later exited 0 with the 10-bit subcases enabled. Treat this as a
kernel+librga pair, not as a kernel-only fact; stale librga builds can still make
P010 probes fail on an otherwise fixed kernel.

That leaves the current `rockchip-vaapi` HEVC blocker in userspace bitstream
reconstruction. Direct MPP decode of the original `SLIST_A_Sony_4.bit` Annex B
stream succeeds (`mpi_dec_test` decoded eight frames), so the kernel/MPP path can
handle the source bitstream. The VA-API path has to rebuild Annex B access units
from VA picture/slice buffers and cannot always reconstruct the original SPS RPS
semantics. VA exposes counts such as `num_short_term_ref_pic_sets` and
`num_long_term_ref_pic_sps`, but it does not preserve the original SPS short-term
RPS table or the SPS long-term POC/used arrays.

The experiments narrow the boundary:

- Before the latest fail-closed guards, the experimental HEVC gate reached
  bit-exact output for simpler vectors (`LTRPSPS_A_Qualcomm_1.bit`,
  `PPS_A_qualcomm_7.bit`, `RPS_A_docomo_4.bit`) and then stalled or corrupted on
  `SLIST_A_Sony_4.bit`.
- Repeating reconstructed VPS/SPS/PPS before every access unit makes `SLIST`
  worse: software decode of dumped driver AUs produced only the first frame, so
  repeated headers can invalidate decoder DPB state.
- Emitting headers only on first use and IRAP lets the reconstructed `SLIST`
  stream get much farther: software decode reached 49 framemd5 lines versus 75
  for the reference, with the first IDR matching and later post-CRA frames
  matching later reference frames. The pre-CRA inter frames still differ, and MPP
  reports missing references around CRA POC 32 (`missing ref poc 24/22/20/16`).
- Changing `used_by_curr_pic_*_flag` derivation from VA RPS flags to the active
  `RefPicList` changed the POC 23 trace but did not change the decoded framemd5
  output for `SLIST`, so that was not the discriminating fix.
- The defensive direction is to fail closed for HEVC classes whose exact RPS
  syntax cannot be rebuilt. The working tree currently rejects the
  scaling-list-plus-SPS-RPS class in `validate_picture_parameters()`, and logs
  the corresponding unsupported state from `build_hevc_job()`.

The practical learning for future work: do not chase RGA/P010, the kernel, or
MPP as the explanation for the `SLIST` failure. The remaining problem is the
VA-to-Annex-B reconstruction contract for HEVC streams that depend on SPS-stored
RPS/long-term-reference tables or on DPB continuity across repeated parameter
sets.

## Boundary

This is not a completed `rockchip-vaapi` HEVC implementation record. The working
checkout is still experimental and dirty; after the latest active-list/header and
fail-closed changes, `make check-hevc-experimental` regressed earlier than before
on `LTRPSPS_A_Qualcomm_1.bit` with MPP slice-parse errors (`collocated_ref_idx`
invalid). Clean up that regression before treating any HEVC gate result as final.

The finding also does not advertise HEVC Main/Main10 or VP9 Profile 2 support.
Those profiles should stay hidden until the pinned conformance gate is bit-exact
or the unsupported stream class is intentionally rejected with a stable fallback
contract.
