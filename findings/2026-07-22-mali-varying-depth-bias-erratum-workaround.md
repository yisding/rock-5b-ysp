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

## PanVK implementation implications

### Internal meta blits already avoid the affected path

PanVK implements `vkCmdBlitImage*` by saving the application's graphics state,
calling Mesa's generic `vk_meta_blit_image2`, and restoring the state
(`src/panfrost/vulkan/panvk_vX_cmd_meta.c:221-232`). Consequently, application
depth-bias state neither leaks into nor controls the internal blit pipeline.

Source inspection changes the earlier expectation that this meta pipeline
would need its own zero-valued depth-bias state. The generic meta-blit fragment
shader in `src/vulkan/runtime/vk_meta_blit_resolve.c:219-221`:

```c
nir_def *out_coord_xy = nir_load_frag_coord(b);
out_coord_xy = nir_trim_vector(b, out_coord_xy, 2);
nir_def *src_coord_xy = nir_ffma_weak(b, out_coord_xy, xy_scale, xy_off);
```

It reconstructs source coordinates from fragment position and push-constant
scale/offset values rather than receiving them through a smooth interpolated
varying. It therefore already uses the avoidance technique that passed the
`gl_FragCoord` control. This is SOURCE-INSPECTED, not a direct
`vkCmdBlitImage*` A/B measurement; a large-extent meta-blit test would still be
useful confirmation.

The generic meta-pipeline default has `depthBiasEnable = false`
(`src/vulkan/runtime/vk_meta.c:385-392`), but changing that shared default
would affect every Mesa Vulkan driver and is neither justified nor apparently
needed for this erratum.

### Proposed workaround for general application draws

The narrow implementation point is `build_zsd()` in
`src/panfrost/vulkan/csf/panvk_vX_cmd_draw.c:1939-2005`, where PanVK packs the
depth/stencil descriptor. A product-scoped patch could:

1. Add a named model quirk, such as `varying_interp_depth_bias_wa`, to
   `struct pan_model::quirks` in `src/panfrost/model/pan_model.h`.
2. Enable it only for the measured G610 model
   (`PAN_PROD_ID(10, 8, 7)`) in `src/panfrost/model/pan_model.c` until the
   official affected product/revision range is known.
3. Force the descriptor's depth-bias-enable bit in `build_zsd()` while
   preserving real application depth bias and substituting explicit zero
   values only when the application disabled it:

```c
const struct panvk_physical_device *pdev =
   to_panvk_physical_device(cmdbuf->vk.base.device->physical);
const bool app_bias = rs->depth_bias.enable;
const bool wa = pdev->model->quirks.varying_interp_depth_bias_wa;

cfg.depth_bias_enable = app_bias || wa;
cfg.depth_units = app_bias ? rs->depth_bias.constant_factor : 0.0f;
cfg.depth_factor = app_bias ? rs->depth_bias.slope_factor : 0.0f;
cfg.depth_bias_clamp = app_bias ? rs->depth_bias.clamp : 0.0f;
```

Explicitly zeroing the numeric fields is necessary. Vulkan dynamic state can
retain previously configured nonzero depth-bias factors while
`depthBiasEnable` is false; forcing only the enable bit could otherwise shift
depth and violate application semantics. When the application enables depth
bias, the patch leaves all of its values intact.

No new dirty-state plumbing appears necessary:
`prepare_ds()` already rebuilds this descriptor when either
`RS_DEPTH_BIAS_ENABLE` or `RS_DEPTH_BIAS_FACTORS` changes
(`src/panfrost/vulkan/csf/panvk_vX_cmd_draw.c:2021-2022`).

The code change is low complexity, approximately 20-30 lines across two or
three files. Validation is the substantial part:

- Do not gate every architecture-10 GPU from the G610 result alone; confirm
  the erratum's product and revision range.
- Run Vulkan CTS/dEQP coverage for static and dynamic enable toggles, genuine
  nonzero depth bias, depth/stencil attachments, early-Z, MSAA, flat and absent
  varyings, dynamic rendering, and pipeline libraries.
- Measure whether enabling the zero-valued hardware path broadly changes depth
  optimization or draw performance.

A shader- or topology-scoped predicate might reduce the affected draw set, but
it is easier to make incomplete: the failing condition depends on interpolated
varyings and runtime primitive extent, and the existing shader metadata does
not provide an obviously sufficient smooth-varying predicate. The
product-scoped descriptor workaround is mechanically simpler, subject to CTS
and performance validation.

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
  PanVK's internal meta pipelines. However, the inspected generic Vulkan
  meta-blit shader already derives source coordinates from `FragCoord`, so it
  does not appear to need the depth-bias workaround for this varying erratum.
  This remains source-inspected rather than directly measured.
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
because the workaround changes rasterizer state. For PanVK specifically, the
general-draw code is localized and small, but selecting the correct affected
GPU range and proving semantic and performance safety require the bulk of the
work.
