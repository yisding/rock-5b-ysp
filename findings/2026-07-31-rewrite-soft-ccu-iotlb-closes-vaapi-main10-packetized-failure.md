# The soft-CCU IOTLB flush closed the VA-API Main10 packetized decode failure

> Scope: MPP rewrite driver (rkvdec2 soft-CCU submit path) as exercised from
> userspace by `rockchip-vaapi` HEVC Main10 decode (work tree
> `~/Code/rockchip-vaapi-hevc-reducer-work-20260731/rockchip-vaapi-hevc`);
> the reducer built for that failure on 2026-07-31.
> Source: fix `75a34815b132a` on `~/Code/rock-5b/kernel/linux`
> (`rk_mpp_rkvdec2_submit()` in `drivers/video/rockchip/mpp-rewrite/mpp_rewrite.c`),
> booted as `6.18.41-video-rewrite-kasan-rockchip64 #23`; failing baseline was
> the same tree at `06ab78b696157`, booted as `#21`.
> Date: 2026-07-31
> Trust: MEASURED (before/after on both builds, same userspace) +
> SOURCE-INSPECTED (the three-commit delta) + CONFIRMED (the purpose-built
> reducer reports `not-reproduced` in its `EXPECTED_RESULT=fixed` mode) +
> INFERRED (the stale-IOTLB mechanism explains the recorded signature; it was
> not instrumented directly)

## Result

The stateful HEVC Main10 failure that `rockchip-vaapi`'s reducer isolated on
kernel `#21` is **cured** by `75a34815b132a`, which invalidates the shared
IOTLB after cache setup and before the task-register writes, `CORE_STA`, and
START — matching the vendor `rkvdec2_soft_ccu_enqueue()` sequence. Six lines:

```c
/*
 * Match rkvdec2_soft_ccu_enqueue(): invalidate the shared IOTLB after
 * cache setup and before the task-register writes, CORE_STA, and START.
 */
if (soft_ccu && hw->iommu_domain && hw->iommu_domain->ops)
	iommu_flush_iotlb_all(hw->iommu_domain);
```

No userspace change was involved. The VA driver source, `librockchip-mpp1`
`1.5.0+git20260729.3381fd2c+ds-0ubuntu1~rk1`, and
`librga2 2.2.0+git20260725.26a50ef-0ubuntu1~rk1` were identical across the two
boots; only the kernel differed.

| Case (identical bytes on both boots) | `#21 g06ab78b69615` | `#23 g75a34815b132` |
|---|---|---|
| Archived six-packet manifest, internal-pool AFBC replay below libva | 3/3 bad frames | **10/10 clean** |
| Same manifest, external-pool AFBC replay | 1/3 bad frames | not re-run (superseded) |
| Six-access-unit prefix, full VA path, hash-compared | 2/3 attempts failed | **5/5 bit-exact** |
| Full 240-frame 1280x720 Main10 clip, full VA path | reproduced the failure | **3/3 bit-exact** |
| Reducer, `EXPECTED_RESULT=fixed`, 32 prefixes x 3 attempts | n/a | **`result=not-reproduced`** |

The failure signature recorded on `#21` — MPP `errinfo`/discard markers that
appeared only through the packetized VA submission path, were stateful across
submissions within a session, were nondeterministic run to run, varied with
buffer-group mode (internal AFBC worst, external linear clean), and never
implicated any individual reconstructed parameter set — is what a stale shared
IOTLB produces: the decoder core reads through translations that no longer
describe the buffers the current job was programmed with.

## Boundary

- The mechanism is **inferred from the signature and the fix's content**, not
  observed directly; no IOTLB or fault instrumentation was added.
- This closes the failure the reducer was built for. It does **not** clear the
  10-bit path on this kernel: requalifying Main10 immediately afterwards found
  a *different*, silent defect at small picture sizes — see
  [the RGA dropped-write finding](2026-07-31-rga3-afbc-p010-dropped-destination-write.md).
  That one produces no `errinfo` at all, so the reducer's accept criterion
  (nonzero MPP `errinfo`/discard) cannot see it.
- Only the rewrite kernel is in evidence here. The production
  `6.18.40-ysp-rockchip64` line was never affected by this bug and its recorded
  `rockchip-vaapi` results stand unchanged.
- `995a0aa710fb2` (RGA2 multi-SG MMU) and `a12e4116c758e` landed in the same
  three-commit window. Neither plausibly cures an MPP decode-error signature,
  but the before/after here is a window comparison, not a single-commit bisect.

## Evidence and reproduction

- **Identity:** rock-5b, `6.18.41-video-rewrite-kasan-rockchip64 #23 SMP
  PREEMPT Fri, 31 Jul 2026 19:37:04 +0000 g75a34815b132`; driver
  `rockchip-vaapi-hevc @ aee5926` (`rockchip_drv_video.so` sha256
  `bac470d5639457fc088643c07364ae3fd5075e98f62e2758ed7a6d952e6f8c68`);
  reproducer `tests/hevc_mpp_repro` sha256
  `fc56b506dc216505951a399a10698cb9039810bedefb9838c23231204d1fa376`.
- **Exercise (below libva, the archived failing manifest):**
  ```sh
  REPRO_IMMEDIATE_OUT=1 REPRO_AFBC=1 REPRO_EXTERNAL_POOL=0 REPRO_NO_EOS=1 \
    tests/hevc_mpp_repro --packetized \
    hevc-reducer/run-hardened/minimal-reconstructed.h265 \
    hevc-reducer/run-hardened/minimal-reconstructed.h265.sizes 6
  ```
  Pass signal: `RESULT status=clean frames=6 expected=6 bad_frames=0`.
- **Exercise (whole gate):**
  ```sh
  FFMPEG=/usr/bin/ffmpeg FFPROBE=/usr/bin/ffprobe EXPECTED_RESULT=fixed \
    tests/minimize-hevc-main10-reconstruction.sh \
    /path/to/hevc-main10.mp4 /path/to/report-dir
  ```
  Pass signal: exit 0 and `result=not-reproduced` in `report.txt`. Note the
  harness needs `/usr/bin/ffmpeg`; a Homebrew `ffmpeg` earlier in `PATH` lacks
  `-vaapi_device` and fails every attempt at argument parsing, which the gate
  would otherwise count as VA failures.
- **Artifacts:** `hevc-reducer/attrib-20260731/` in the driver work tree
  (`fixed-mode-run/report.txt` plus per-attempt logs); the `#21` failing
  baseline is preserved alongside in `hevc-reducer/run-hardened/` and
  `hevc-reducer/run-final/`.

## Why it matters

The `rockchip-vaapi` roadmap had this recorded as the open blocker for stock
Firefox HEVC Main10 playback, immediately below the (separately fixed) GR1616
export defect. It was never a bitstream-reconstruction bug: the reducer's
control-first design — software decode clean, whole-stream direct MPP clean,
and only then a VA attempt counted — is what kept it from being misattributed
to the driver's HEVC parameter-set rewriting across two days of reduction.
