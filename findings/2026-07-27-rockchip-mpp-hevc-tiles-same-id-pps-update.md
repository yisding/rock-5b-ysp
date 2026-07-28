# Rockchip MPP HEVC TILES failure: same-ID PPS changes never reach the HAL

> Scope: `rockchip-vaapi` HEVC Main conformance on RK3588 and its
> `librockchip_mpp` decoder dependency; support-coverage row C15.
> Source: `rockchip-vaapi@03e6cb6359e0534b497e20654c2f8895ad9da760`
> direct-MPP reducer/reproducer; installed
> `librockchip-mpp1 1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1`; matching
> `mpp@1375813cbbae5ad6861b166475dd8fb672183220`
> (`h265d_flow.c` `h265d_slice_head()` and `h265d_nal_unit()`,
> `h265d_syntax.c` `fill_picture_parameters()`, and `hal_h265d_com.c`
> `hal_h265d_vdpu38x_output_pps_packet()`); regression boundary
> `fcfd59d2d2bd2333fce29fedcb2c8d4b511761c1`; fix
> `yisding/mpp@ysp/main@d8c6b88a2211d08a4427abd3c5e8275905a934f5`;
> package `1.5.0+git20260727.d8c6b88a+ds-0ubuntu1~rk1`.
> Date: 2026-07-27
> Trust: **MEASURED** / **CODE-INSPECTED** / **CONFIRMED** /
> **ROOT-CAUSED** / **BOARD-REPRODUCED** / **FIX-COMPILE-VERIFIED** /
> **FIX-RUNTIME-VERIFIED** / **PACKAGE-VERIFIED** /
> **PREDICTION-HARDWARE-CONFIRMED**

## Result

`TILES_A_Cisco_2.bit`, the only non-exact vector in the eight-vector
`rockchip-vaapi` HEVC Main gate, is not failing in the VA-to-Annex-B
reconstruction. A software-valid six-NAL reduction reproduces the error through
`librockchip_mpp` directly, bypassing libva and `rockchip-vaapi`. The first
picture decodes cleanly; the second picture returns MPP `errinfo=1`.

MPP fix `d8c6b88a` consumes the existing PPS-update bit when a slice selects
that PPS. The exact staged library decodes both reduced pictures and all 100
frames of `TILES_A_Cisco_2.bit` cleanly. The complete eight-vector
`rockchip-vaapi` HEVC Main matrix is now byte-exact with that library.

The reduced stream contains:

```text
VPS, SPS, PPS ID 0 layout A, IDR, PPS ID 0 layout B, P-slice
```

Both PPS definitions enable a non-uniform 5x5 tile grid, but the second
definition changes the grid and cross-tile filtering:

```text
layout A:
  column_width_minus1 = [3, 9, 4, 5]
  row_height_minus1   = [7, 2, 1, 2]
  loop_filter_across_tiles_enabled_flag = 1

layout B:
  column_width_minus1 = [10, 4, 5, 3]
  row_height_minus1   = [6, 2, 0, 0]
  loop_filter_across_tiles_enabled_flag = 0
```

MPP parses the replacement PPS and detects that its contents changed.
`h265d_nal_unit()` stores the new PPS and sets bit `pps_id` in
`p->pps_update_mask`. That mask has no consumer in the pinned source: aside
from its declaration and this set, it is only initialized to zero.

When the following slice is parsed, `h265d_slice_head()` sets
`p->ps_need_upate` only when `pps_id != p->pre_pps_id` or the referenced SPS
has changed. Both pictures reference PPS ID 0, so neither condition reports the
new PPS. `fill_picture_parameters()` consequently exports
`ps_update_flag = 0`, and the RK3588 HAL's
`hal_h265d_vdpu38x_output_pps_packet()` skips rewriting the hardware SPS/PPS
configuration packet. The software parser uses layout B for the P-slice while
the decoder hardware retains layout A. Tile boundaries determine
coding-tree-block traversal and CABAC entry points, so the stale hardware tile
table explains the second-picture stream error.

This is a regression of MPP commit `fcfd59d2` (`refactor[h265d]: Update H.265
decoder`, 2026-01-29). In its parent, the monolithic H.265 parser compared the
raw PPS NAL with `pre_pps_data` and set `ps_need_upate` whenever the PPS bytes
or length changed, regardless of PPS ID. The refactor replaced that direct
dirtying with `pps_update_mask` but did not connect the new mask to slice
parameter-set selection.

## Evidence and reproduction

- **Board and boot:** Radxa ROCK 5B / RK3588,
  `Linux 6.18.40-video-port-kasan-rockchip-rk3588 #2 SMP PREEMPT
  Sat, 25 Jul 2026 22:35:13 +0000 aarch64`.
- **Userspace:** `tests/hevc_mpp_repro` dynamically loaded
  `/usr/lib/aarch64-linux-gnu/librockchip_mpp.so.1` from
  `librockchip-mpp1 1.5.0+git20260529.1375813c+ds-0ubuntu2~rk1`.
- **Reduced stream:** 75,496 bytes, SHA-256
  `54a4defe45864fb743c209d7bd30a36c0b9c0d5bc4bf959e800bdd4820367802`.
  The direct runner inventories exactly six NAL units. FFmpeg software decode
  exits 0, and `ffprobe -count_frames` reports 1920x1080 and two read frames.
- **Control:** direct MPP decode of checksum-pinned
  `PPS_A_qualcomm_7.bit` exits 0 with 81 expected frames, zero bad frames, one
  info change, and EOS.
- **Failure:** direct MPP decode of the six-NAL core exits 1 with two expected
  frames. Frame 1 has `errinfo=0x0`; frame 2 has `errinfo=0x1` and EOS.
- **VAAPI exclusion:** the failing command links only libMPP and submits the
  Annex-B stream directly. No libva or `rockchip-vaapi` entry point participates.
- **Artifacts:** the ignored local `rockchip-vaapi` evidence workspace retains
  `tiles-backend-repro-20260727/host-analysis/prefix-002-core.h265`. The checksum
  above and the pinned original vector allow it to be reconstructed with
  `tests/minimize-hevc-tiles.sh`; no generated stream or raw board log is added
  to this repository.

The decisive direct commands were:

```bash
cd ../rockchip-vaapi

./tests/hevc_mpp_repro tests/vectors/PPS_A_qualcomm_7.bit 81
./tests/hevc_mpp_repro \
  .hevc-probe/tiles-backend-repro-20260727/host-analysis/prefix-002-core.h265 \
  2
```

The first command reported:

```text
RESULT status=clean frames=81 expected=81 bad_frames=0 info_changes=1 eos=1 api_status=0
```

The second reported:

```text
FRAME index=1 errinfo=0x0 discard=0x0 eos=0 width=1920 height=1080
FRAME index=2 errinfo=0x1 discard=0x0 eos=1 width=1920 height=1080
RESULT status=stream-error frames=2 expected=2 bad_frames=1 info_changes=1 eos=1 api_status=0
```

## Fix

Commit `d8c6b88a` consumes the existing `pps_update_mask` in
`h265d_slice_head()` after validating the slice's PPS ID and before filling the
picture parameters:

```c
/* Bit set means the selected PPS was parsed with new content. */
if (MPP_GET_BIT64(p->pps_update_mask, pps_id)) {
    p->ps_need_upate = 1;
    MPP_CLR_BIT64(p->pps_update_mask, pps_id);
}
```

This restores the pre-refactor semantic contract while preserving the new
per-PPS bitmap: the first slice that references a newly parsed or changed PPS
marks the hardware parameter set dirty and consumes the bit. The change belongs
in the codec parser rather than the RK3588 HAL or `rockchip-vaapi`, because the
parser already owns PPS change detection and every HAL consumes its exported
picture-parameter update state.

## Fix verification

- **Source/build:** the full native MPP build, install staging, and all build
  targets complete at `d8c6b88a`. The staged `librockchip_mpp.so.1` has
  SHA-256
  `3185e2fe222362c8abd2a75ca55eac51c61062679ed580f974f27f385e5df923`
  and embeds the `d8c6b88a` source identity.
- **Direct control:** `PPS_A_qualcomm_7.bit` remains clean at 81/81 frames,
  zero bad frames, one info change, and EOS.
- **Reduced reproducer:** both 1920x1080 pictures are clean (`errinfo=0`,
  `discard=0`); the runner reports two expected frames and EOS.
- **Full failing vector:** `TILES_A_Cisco_2.bit` is clean at 100/100 frames,
  zero bad frames, one info change, and EOS.
- **VAAPI matrix:** `make check-hevc-experimental` reports all eight pinned
  HEVC Main vectors byte-exact, including TILES.
- **Package:** the fork tip exports as
  `1.5.0+git20260727.d8c6b88a+ds-0ubuntu1~rk1`; source construction and a
  native arm64 binary package build completed, producing the five expected
  runtime/development/demo binary packages. The runtime package metadata is
  `Package: librockchip-mpp1`, the exact version above, and
  `Architecture: arm64`.

## Boundary

This finding does not promote experimental HEVC Main to a default
`rockchip-vaapi` capability. The new package has not been installed from a
published archive, no new parser-level unit test was added, and MPP exposes no
CTest tests in this configuration. The wider official MPP decoder suite and
the `rockchip-vaapi` sanitizer matrix remain useful regression coverage beyond
the direct control/reproducer and complete HEVC Main matrix run here.

## Verification gate

The fix gate is complete: pinned source and package identity, native source and
binary package builds, the direct control, the two-picture reproducer, the full
TILES vector, and all eight VAAPI HEVC Main vectors are recorded above. Archive
publication and broad decoder/sanitizer regression runs remain release gates,
not blockers to the narrowly scoped fix result.
