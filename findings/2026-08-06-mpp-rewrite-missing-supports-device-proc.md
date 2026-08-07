# MPP rewrite omitted the BSP `supports-device` proc inventory

> Scope: rewrite MPP userspace discovery during the 2026-08-06 FFmpeg conformance run
> Source: booted `rk3588-rewrite-6.18@c49308313ce7`; BSP `mpp_service.c` `mpp_show_support_device()`; fixed 6.18 `e43b83afabf08` / mainline `755b92b790dbc`
> Date: 2026-08-06
> Trust: USER-REPORTED, SOURCE-INSPECTED, ROOT-CAUSED, FIX-COMPILE-VERIFIED

## Result

The FFmpeg suite stopped in preflight with
`missing readable /proc/mpp_service/supports-device`. This was a rewrite procfs
compatibility omission, not a missing decoder/encoder backend: the rewrite
already maintained the live `hw_support` bitmap and per-device hardware IDs,
and its query ioctls returned them, but `rk_mpp_create_procfs()` created only
`supports-cmd` and the `support_cmd` alias.

Rockchip's BSP exposes `supports-device` as a read-only inventory. The
conformance harness uses it before launching cases to prove that RKVDEC and
RKVENC are actually present. An empty `summary.tsv` in
`../rock-5b/build/rockchip-conformance/logs/rewrite-kasan/20260806-142819-ffmpeg-suite`
confirms that no FFmpeg case ran after this preflight failure.

## Fix

`e43b83afabf08` (mainline mirror `755b92b790dbc`) adds the BSP-shaped
`/proc/mpp_service/supports-device` entry. It lists the currently usable
AV1DEC (type 4), RKVDEC (type 9), and RKVENC (type 16) devices from the same
live support state used by `MPP_CMD_QUERY_HW_SUPPORT`, and prints each nonzero
validated register-0 hardware ID in the BSP format. The existing support-table
KUnit case now checks the descriptor inventory too.

The warning-fatal clean-archive gate passed normal and KASAN/fault-injection
profiles on 6.18 `67f323aebdf39` and mainline `7a6d4cb075a67`.

## Boundary

The proc callback and both kernel-version builds are compile-verified. A booted
kernel still needs to show a readable file containing RKVDEC and RKVENC before
the FFmpeg preflight and suite can be called fixed at runtime.
