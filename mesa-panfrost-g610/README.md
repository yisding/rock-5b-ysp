# Mesa/Panfrost Notes For Mali-G610

This folder collects the Mesa-side information learned while debugging ROCK 5B
readback performance and Panfrost texture-transfer enablement on Mali-G610 MC4.
It is deliberately broader than the GNOME Remote Desktop note in
[`../gnome-remote-desktop/`](../gnome-remote-desktop/): the GRD docs explain why
the readback matters for remote desktop, while this folder preserves the driver,
hardware, reproducer, and validation details.

Hardware and software used for the local investigation:

- Radxa ROCK 5B / RK3588
- Mali-G610 MC4
- Mesa 26.2-devel local builds
- Panfrost/Panthor on the OpenGL ES path
- dEQP GLES3 with surfaceless pbuffer

## Short Version

Panfrost historically advertised no Gallium texture-transfer acceleration:

```c
caps->texture_transfer_modes = 0;
```

For GRD, that meant `glReadPixels` on the software path spent most of a frame in
CPU-side detile/swizzle work. `MESA_COMPUTE_PBO=1` proved that moving that work
to the GPU helped: the 1080p `GL_BGRA` readback benchmark went from about
19.9 ms to about 11.0 ms.

The original upstream direction was to enable the sampled BLIT transfer path,
but local testing on Mali-G610 found that BLIT is not bit-exact for some integer
format-changing transfers. The problematic path is:

1. Mesa state tracker expands an integer renderbuffer/readback through a staging
   resource.
2. `u_blitter` emits a fragment shader that reads interpolated texture
   coordinates.
3. The shader truncates those coordinates and performs `TEX_FETCH`/TXF.
4. Mali-G610's `LD_VAR_IMM` varying interpolation drifts by about `2^-10`.
5. Truncation turns that coordinate drift into wrong texel selection.

The exact key instruction sequence from the generated blit fragment shader was:

```asm
LD_VAR_IMM.slot0.v4.f32.center.store.wait0 @r0:r1:r2:r3, r61^, table:0x1, index:0x0
F32_TO_S32.rtz.discard r2, r3^
F32_TO_S32.rtz r1, r1^
F32_TO_S32.rtz r0, r0^
TEX_FETCH.slot1.reserved.32.2d.texel_offset.wait0126 @r0:r1:r2:r3, @r0:r1:r2, [r4^:r5^]
```

The compiler did not obviously choose the wrong operation. The generated code
loads an interpolated f32 coordinate, truncates it, then does a texel fetch. The
problem is that the interpolation result is not precise enough for an integer
texel address.

The current upstream fix direction for Mesa MR
[!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563) is:

```c
caps->texture_transfer_modes = PIPE_TEXTURE_TRANSFER_COMPUTE;
```

COMPUTE avoids the varying unit entirely by using integer invocation coordinates.
On the measured G610 cases it was also slightly faster than BLIT, so this is both
the correctness fix and not a measured transfer-performance regression.

## Folder Map

- [`blit-precision.md`](blit-precision.md) - the root-cause investigation: why
  BLIT fails, what the `2^-10` drift means, why `noperspective` does not fix it,
  what alternatives were considered, and why COMPUTE is the practical answer.
- [`validation.md`](validation.md) - performance numbers, dEQP reruns, and the
  shader-image unbind bug found while testing the transfer path.
- [`reproducers/`](reproducers/) - the standalone C probes and benchmark used to
  reproduce the problem, isolate interpolation, rule out shader-side recovery,
  and compare BLIT vs COMPUTE.

## Key Facts To Carry Forward

- The failure is specific to sampled BLIT paths that need an exact integer texel
  coordinate after interpolation and truncation.
- The failing dEQP symptom was in shader precision tests, but the shader math was
  not the underlying bug. The precision tests happened to read back a very wide
  one-row integer buffer through a format-changing blit.
- The important repro size was `W=16307`; BLIT returned wrong texels for
  `15672 / 16307` samples.
- Example drift:
  - `i=1024` sampled texel `1023`
  - `i=8192` sampled texel `8185`
  - `i=16306` sampled texel `16293`
- `gl_FragCoord.x` was exact in the same probe: `0 / 16307` floor mismatches.
- `noperspective` was not exact on Mali-G610; Panfrost lowers it through the
  same perspective machinery.
- A derivative-based reconstruction was worse: `16187 / 16307` mismatches.
- `PAN_MESA_DEBUG=nofp16` did not matter; the issue is not ordinary fp16 ALU
  lowering.
- `PAN_MESA_DEBUG=linear`, `PAN_MESA_DEBUG=sync`, `ST_DEBUG=noreadpixcache`,
  single-triangle blits, and TXF toggles did not make BLIT correct.
- Compute transfer avoids `LD_VAR_IMM`, uses integer invocation IDs, and fixed
  the readback/precision failures in local testing.
- The only remaining dEQP warning in the MR rerun was
  `dEQP-GLES3.functional.shaders.builtin_functions.precision.acos.mediump_fragment.vec2`,
  and it reproduced in a clean run, so it was not introduced by the transfer
  change.

## Relation To The GRD Work

The GRD software path is slow because it has to bring the captured frame back to
CPU memory for software RFX encoding. The Mesa compute transfer path makes that
software fallback less bad by moving detile/swizzle work to the GPU. It does not
change the larger conclusion of this repo: hardware encode is the real fix
because it removes the GPU-to-CPU readback from the hot path.

The application-facing summary remains in
[`../gnome-remote-desktop/MESA-PANFROST-TRANSFER.md`](../gnome-remote-desktop/MESA-PANFROST-TRANSFER.md).
