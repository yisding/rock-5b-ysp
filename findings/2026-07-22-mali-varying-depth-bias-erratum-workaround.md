# Mali-G610 varying erratum: zero-valued depth bias repairs GL, Vulkan, and ordinary TEX

> Scope: Mali-G610 MC4 on ROCK 5B, Panfrost OpenGL ES, PanVK Vulkan, wide
> non-power-of-two triangle draws, and the workaround discussed on Mesa MR
> [!42679](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42679#note_3578636).
> Source: maintainer diagnosis in MR !42679; local A/B runs against system
> Mesa 26.0.3; shader dumps from that driver; and Mesa source inspection at
> `4c23f1db1f9c`.
> Date: 2026-07-22.
> Trust: CONFIRMED (maintainer classification as a hardware erratum) /
> MEASURED (OpenGL raw-varying, ordinary-TEX, and Vulkan raw-varying A/B
> results) / SOURCE-INSPECTED (GL- and Vulkan-to-Valhall state mappings) /
> INFERRED (the internal hardware path selected by the descriptor bit).

## Result

The wide, non-power-of-two varying drift is a Mali hardware erratum, not a
general architectural limit of roughly ten fractional bits. The previously
measured `~2^-10`-class error remains a useful failure signature at widths
12288 and 16307, but it is not the root cause.

Kusma's workaround, issued immediately before the draw, is:

```c
glEnable(GL_POLYGON_OFFSET_FILL);
glPolygonOffset(0.0f, 0.0f);
```

It makes both the raw-varying probe and an ordinary normalized-coordinate
`texture()` probe exact at the two failing widths tested. Because factor and
units are both zero, it does not numerically move the primitive in depth.

The Vulkan equivalent is also confirmed. A graphics pipeline with
`depthBiasEnable = VK_TRUE` and constant factor, clamp, and slope factor all
zero makes PanVK's raw-varying probe exact at the same widths.

## Why the workaround works

The source-visible state chain is:

```text
GL_POLYGON_OFFSET_FILL
  -> gl_context::Polygon.OffsetFill
  -> pipe_rasterizer_state::offset_tri
  -> mali_depth_stencil::depth_bias_enable

VkPipelineRasterizationStateCreateInfo::depthBiasEnable
  -> vk_rasterization_state::depth_bias.enable
  -> mali_depth_stencil::depth_bias_enable
```

At the inspected Mesa revision:

- `src/mesa/main/polygon.c:353-358` initializes factor, units, and clamp to
  zero and `OffsetFill` to false.
- `src/mesa/main/polygon.c:297-300` returns early when
  `glPolygonOffset(0, 0)` repeats those initial values. In this fresh-context
  reproducer, `glEnable(GL_POLYGON_OFFSET_FILL)` is therefore the operative
  state change; the explicit zero call makes the intended no-offset values
  unambiguous and robust to prior state.
- `src/mesa/state_tracker/st_atom_rasterizer.c:155-163` maps `OffsetFill` to
  `offset_tri` and carries the zero-valued parameters.
- `src/gallium/drivers/panfrost/pan_cmdstream.c:887-890` maps `offset_tri` to
  `cfg.depth_bias_enable` in the packed depth/stencil descriptor.
- `src/vulkan/runtime/vk_graphics_state.c:624-629` imports Vulkan's
  `depthBiasEnable` and its three numeric values.
- `src/panfrost/vulkan/csf/panvk_vX_cmd_draw.c:1995-2000` maps that PanVK
  rasterization state to the same `cfg.depth_bias_enable`, depth-units,
  depth-factor, and clamp fields.
- `src/panfrost/genxml/v10.xml:2100-2104` defines the Valhall v10
  `Depth bias enable` bit and its factor, units, and clamp fields.

The measured interpretation is that setting the depth-bias-enable descriptor
bit selects an unaffected triangle-setup/interpolation path while zero factor
and units leave depth unchanged. That last internal connection is an inference:
the public Mesa source exposes the state-bit transition, but not the
microarchitectural erratum or the circuitry selected by that bit.

## Raw-varying A/B evidence

`tiny_interp_probe.c` draws one oversized triangle and writes the raw bits of a
varying that should equal `x + 0.5`:

| width | mode | wrong pixels | first bad x | last value (expected) |
|---:|---|---:|---:|---:|
| 12288 | baseline | 11744 / 12288 | 529 | 12275.5312 (12287.5) |
| 12288 | polygon offset, zero values | 0 / 12288 | none | 12287.5000 (12287.5) |
| 16307 | baseline | 15672 / 16307 | 623 | 16293.2832 (16306.5) |
| 16307 | polygon offset, zero values | 0 / 16307 | none | 16306.5000 (16306.5) |

The 8192-wide varying baseline and the 12288-wide `gl_FragCoord` control also
pass.

Reproduce from the YSP root:

```bash
cd video-libraries/mesa/reproducers/interp_probe
cc -O2 -o tiny_interp_probe tiny_interp_probe.c -lEGL -lGLESv2 -lm
./tiny_interp_probe 12288 varying baseline
./tiny_interp_probe 12288 varying polygon-offset
./tiny_interp_probe 16307 varying baseline
./tiny_interp_probe 16307 varying polygon-offset
```

## Vulkan A/B evidence

[`vk_interp_probe.c`](../video-libraries/mesa/reproducers/interp_probe/vk_interp_probe.c)
now accepts a backward-compatible fourth `baseline|depth-bias` argument. The
workaround mode creates the otherwise identical pipeline with:

```c
.depthBiasEnable = VK_TRUE,
.depthBiasConstantFactor = 0.0f,
.depthBiasClamp = 0.0f,
.depthBiasSlopeFactor = 0.0f,
```

PanVK on the same G610 produces:

| width | mode | wrong pixels | first bad x | last value (expected) |
|---:|---|---:|---:|---:|
| 12288 | baseline | 11744 / 12288 | 529 | 12275.5312 (12287.5) |
| 12288 | depth bias, zero values | 0 / 12288 | none | 12287.5000 (12287.5) |
| 16307 | baseline | 15672 / 16307 | 623 | 16293.2832 (16306.5) |
| 16307 | depth bias, zero values | 0 / 16307 | none | 16306.5000 (16306.5) |

The `gl_FragCoord` plus depth-bias control passes at 12288. llvmpipe also
passes both baseline and depth-bias modes at 12288.

Reproduce after compiling the shaders and executable per the reproducer
README:

```bash
./vk_interp_probe 12288 varying Mali baseline
./vk_interp_probe 12288 varying Mali depth-bias
./vk_interp_probe 16307 varying Mali baseline
./vk_interp_probe 16307 varying Mali depth-bias
```

This proves that the workaround is not OpenGL-specific. Both APIs reach the
same Valhall descriptor bit and both become exact when that bit is enabled
with zero-valued parameters.

## Non-integer ordinary-TEX A/B evidence

[`tex_interp_probe.c`](../video-libraries/mesa/reproducers/interp_probe/tex_interp_probe.c)
tests the non-integer texture-coordinate case directly:

- a smooth, normalized floating-point varying runs from `0` to `1`;
- the fragment shader calls GLSL `texture()` with `GL_NEAREST`;
- the source is an `R32F` ramp where texel `x` contains `float(x)`;
- raw sampled float bits are stored in `R32UI` and checked for exact equality.

The system-driver shader dump contains a NIR `tex` and a Valhall computed-LOD
`TEX_SINGLE` instruction. This is ordinary TEX, not an integer-coordinate TXF
test.

| width | mode | wrong samples | first bad x / sample | last sample (expected) |
|---:|---|---:|---|---:|
| 12288 | baseline | 11744 / 12288 | 529 / 528 | 12275 (12287) |
| 12288 | polygon offset, zero values | 0 / 12288 | none | 12287 (12287) |
| 16307 | baseline | 15670 / 16307 | 623 / 622 | 16293 (16306) |
| 16307 | polygon offset, zero values | 0 / 16307 | none | 16306 (16306) |

The 8192-wide baseline passes, and llvmpipe passes both the 12288-wide baseline
and workaround modes. Reproduce with:

```bash
cc -O2 -o tex_interp_probe tex_interp_probe.c -lEGL -lGLESv2
./tex_interp_probe 12288 baseline
./tex_interp_probe 12288 polygon-offset
./tex_interp_probe 16307 baseline
./tex_interp_probe 16307 polygon-offset
```

This answers the non-integer question: the workaround is not specific to
`floor()`, f32-to-integer conversion, or TXF. It prevents the bad coordinate
from reaching an ordinary filtered texture instruction too.

## Boundary

- This validates direct, single-sample OpenGL and Vulkan triangle draws on
  G610, plus OpenGL ordinary TEX-nearest at 1:1 scale. Scaled sampling, linear
  filtering, MSAA, Midgard, and other Mali generations remain untested.
- Enabling polygon offset in an application does not automatically alter
  rasterizer state saved and installed by Mesa's internal `u_blitter`.
  A production Mesa blit workaround must explicitly select the safe state for
  the internal blitter draw.
- Likewise, an application's Vulkan graphics-pipeline state does not control
  PanVK's internal meta pipelines. Any affected Vulkan meta blit must install
  the safe depth-bias state itself.
- The proprietary Mali userspace stack reproduced the baseline varying values
  bit-for-bit before this workaround was known, supporting a hardware
  attribution. The workaround itself has been exercised here on Panfrost and
  PanVK, but not the proprietary stack.
- Reconstructing coordinates from `gl_FragCoord` remains a valid avoidance
  technique for !42679's TXF path, but the new evidence supersedes the claim
  that an inherent low-precision varying format is the root cause.

## Why this matters

The finding changes both diagnosis and scope. The original TXF corruption is
still real, and the `gl_FragCoord` reconstruction still avoids it, but the
underlying defect is a conditional hardware erratum. The ordinary-TEX result
also proves that fixing only the f32-to-integer conversion does not address
the whole affected draw class, while the Vulkan result proves the descriptor
workaround crosses API frontends. For a general Mesa fix, the maintainer notes
that blits can be worked around properly; general application draws are harder
because the workaround changes rasterizer state.
