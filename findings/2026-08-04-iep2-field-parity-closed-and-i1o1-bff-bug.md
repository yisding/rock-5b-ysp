# IEP2 field parity settled: the mode suffix selects the field and `dil_order` does nothing, so MPP's hardcoded I1O1T is wrong for BFF streams

> Scope: kernel-drivers/iep2 and C15 hardware codecs; the RK3588 IEP2
> deinterlace mode/field-order semantics, the previously unmet TFF/BFF
> validation gate, and the `mpp_dec_vproc` bootstrap mode selection.
> Source: booted `6.18.42-ysp-rockchip64`
> (`6.18.42+rk3588av1fwport20260803-0ubuntu1~rk1`); `iep2_test` built from
> libmpp fork `~/Code/rock-5b/rockchip-userspace/mpp-rockchip`, inputs
> `~/Code/tmp/iep2-test-2026-08-03/smoke/{tff,bff}-320x240.yuv` (6 frames,
> 320x240 NV12); `mpp/vproc/mpp_dec_vproc.c`
> `dec_vproc_dei_v2_deinterlace()` (~:682-693) and
> `dec_vproc_dei_v2_detection()` (~:767-778); `mpp/vproc/inc/iep2_api.h`
> `enum IEP2_DIL_MODE` (~:49-59); `inc/mpp_frame.h` (~:24-28).
> Date: 2026-08-04
> Trust: **MEASURED** (14 mode x field-order runs plus a 4-run isolation
> control on hardware) + **ROOT-CAUSED** + **SOURCE-INSPECTED** +
> **COMPILE-VERIFIED** (the fix builds; the corrected decode path is **not**
> runtime-verified) + **RESOLVED** (the audit's TFF/BFF + I5O2/I2O2/I1O1 gate)

## Result

Three questions left open by the
[interlaced-decode regression](2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md)
are now settled, and one of them is a real libmpp bug.

**1. The mode's T/B suffix selects the emitted field. `dil_order` does not.**

Running every deinterlace mode against both field orders and comparing output
luma lines against the source: in a single-field mode the emitted field's lines
survive byte-exactly while the opposite parity is interpolated, which identifies
the field the hardware actually produced regardless of what the mode is named.

| Mode | best even-line match | best odd-line match | Emits |
|---|---:|---:|---|
| `I5O1T` | 1.0000 | 0.9340 | top field |
| `I5O1B` | 0.9337 | 1.0000 | bottom field |
| `I1O1T` | 1.0000 | 0.9194 | top field |
| `I1O1B` | 0.9192 | 1.0000 | bottom field |
| `I5O2`, `I2O2` | 1.0000 | 1.0000 | both — one output frame per parity |
| `BYPASS` | 1.0000 | 1.0000 | passthrough |

The same table holds for the BFF input, to within noise (0.9280/0.9274,
0.9118/0.9124). **The field order of the content does not change which field a
mode emits.**

An isolation control makes it unambiguous — same input file, varying only one
thing at a time:

| Comparison | Result |
|---|---|
| `-m 5` with `-f TFF` vs `-f BFF` | **byte-identical** |
| `-m 6` with `-f TFF` vs `-f BFF` | **byte-identical** |
| `-m 5` vs `-m 6`, same `-f` | **differ** |

So on this path `dil_order` has no observable effect at all, and the suffix is
the only control.

**2. That makes MPP's hardcoded `I1O1T` a bug for BFF content.**

Both 2-in-1-out bootstrap sites in `mpp_dec_vproc.c` set
`dil_mode = IEP2_DIL_MODE_I1O1T` unconditionally, and `IEP2_DIL_MODE_I1O1B` was
never selected anywhere in the file — it appeared only as a case label. For a
bottom-field-first stream the bottom field is the temporally first one, so the
first output frame after start or reset showed the wrong field, and because
`dil_order` does nothing here, configuring the field order correctly could not
compensate.

Fixed in the fork (`yisding/mpp@7e2c24bd`) by selecting the mode from the
frame's field-order flags:

```c
dil_mode = (mode & MPP_FRAME_FLAG_BOT_FIRST) && !(mode & MPP_FRAME_FLAG_TOP_FIRST) ?
           IEP2_DIL_MODE_I1O1B : IEP2_DIL_MODE_I1O1T;
```

The condition deliberately requires `BOT_FIRST` *without* `TOP_FIRST`, so the
both-flags-set case — which `dec_vproc_config_dei_v2()` already maps to
`IEP2_FIELD_ORDER_UND` — keeps the previous top-field behavior instead of
silently changing.

**3. The "50 % nonzero" observation was a harness artifact, as suspected.**

Every mode writes 921,600 bytes = 8 frames of 115,200. In the single-output
modes exactly **4 of those 8 frames are empty**; in the two-output modes
(`I5O2`, `I2O2`) none are. `iep2_test` always writes the `dst0`+`dst1` pair
regardless of mode, so in a 1-out mode the unused second buffer is written as
zeros. This is the same class of defect as the
[2026-08-03 non-determinism finding](2026-08-03-rk3588-iep2-nondeterministic-output.md):
the driver is fine, Rockchip's test harness is what misleads.

## The audit gate this closes

`kernel-drivers/iep2/docs/rk3588-iep2-vdpp.md` required *"top- and
bottom-field-first content plus I5O2, I2O2, and I1O1 modes behave correctly"*.
All 14 mode x field-order combinations ran on the production kernel:

- every run exited 0 and produced the expected 921,600 bytes;
- no error or failure line in any run log;
- the kernel journal logged **nothing** across the whole matrix — no IEP2, MPP,
  IOMMU, fault, reset, timeout, or error entry;
- and the per-mode parity semantics above are now established rather than
  assumed.

This also closes **step 6.0** of the fork roadmap's Phase 6, which was the
declared blocker for the rest of the `VAEntrypointVideoProc` plan.

## Boundary

- **The fix is not runtime-verified on a decode path.** Its premises are
  measured, and it compiles, but proving the corrected bootstrap frame needs a
  bottom-field-first interlaced clip driven through the decoder with vproc
  enabled. No such clip is in any pinned vector set, and `rockchip-vaapi` now
  disables vproc, so exercising it needs the `enable_deinterlace=1` override.
- **"Correct" here means field parity and exactness, not quality.** Nothing
  measures deinterlacing quality, cadence handling, or motion-vector behavior.
  `IEP2_DIL_MODE_PD` (pulldown) and `DECT` (detection) were not run.
- **One geometry, one format, one clip pair.** 320x240 NV12, 6 frames, from the
  2026-08-03 smoke set. No 1080p, no 4:2:2, and nothing near the documented
  1920x1088 motion-data bound.
- **The interpolated-parity match values (~0.92) are not a quality claim.** They
  only establish that the opposite parity is *not* byte-exact, which is what
  distinguishes an emitted field from an interpolated one.
- **`I5O2`/`I2O2` reading 1.0000 on both parities is expected**, not
  passthrough: each emits one output frame per parity, and the analysis takes
  the best match across all output frames.

## Reproduction

```sh
B=<build>/mpp/vproc/iep2/test/iep2_test
S=~/Code/tmp/iep2-test-2026-08-03/smoke
for fo in TFF BFF; do for m in 1 2 3 4 5 6 8; do
  "$B" -w 320 -h 240 -f $fo -m $m \
       -i "$S/$(echo $fo | tr A-Z a-z)-320x240.yuv" -o out-$fo-m$m.yuv
done; done
```

Then compare each output frame's even/odd luma lines against the source frames;
the emitted parity matches exactly and the other does not. The isolation control
is the same command with one input file and both `-f` values.

## Why it matters / follow-up

The earlier read of this code — that the hardcoded `I1O1T` was *suspicious but
unprovable without the TRM* — was correct to stop there, and the measurement
turned it into a defect with a mechanism. The general lesson is that mode
semantics of this kind are cheaply testable on hardware: one 6-frame clip and a
line-parity comparison settled what register documentation would have been
needed to argue.

Follow-up: add a bottom-field-first interlaced vector to the pinned set. It is
the missing input for runtime-verifying this fix, and the interlaced-decode
regression separately noted that a single 352x288 TFF clip is the entire current
guard against that whole class of defect.
