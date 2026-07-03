# How the fix works: a from-first-principles walkthrough

A conceptual walkthrough of the Panfrost blit-transfer patch series, written for
someone who is a developer but new to C and to Mesa. It builds up the graphics
concepts first, then the bug, then what each patch changes. For the terse
root-cause analysis see [`blit-precision.md`](./blit-precision.md); for the
patch/MR shape and test results see [`validation.md`](./validation.md) and
[`rebuild-and-test.md`](./rebuild-and-test.md).

## 1. Where this code lives: the graphics stack

When an app draws or reads pixels, the call passes through several layers:

```
Your app  ->  OpenGL / OpenGL ES API
          ->  Mesa "state tracker"   (translates GL calls into generic GPU ops)
          ->  Gallium                (Mesa's internal driver-independent API)
          ->  Panfrost               (the driver for Arm Mali GPUs)
          ->  Mali-G610 hardware
```

Two of these matter throughout:

- **Gallium** is an interface *inside* Mesa. Rather than each GPU driver
  re-implementing all of OpenGL, Mesa translates OpenGL down to a smaller, cleaner
  set of operations ("draw these triangles", "copy this texture"), and each driver
  implements only *those*. Panfrost is one such driver.
- **The state tracker** turns `glReadPixels(...)`, `glTexImage2D(...)`, etc. into
  Gallium operations.

Our patches touch two layers:

- **`u_blitter`** — a *shared helper* in Gallium's `auxiliary/util`, used by many
  drivers. ("Auxiliary" = optional shared utility code, not a driver.)
- **Panfrost** — the Mali driver specifically.

That split (shared vs. driver-specific) is exactly why the reviewer wanted the
blitter change in its own merge request: it affects *every* driver that uses
`u_blitter`, not just Mali.

## 2. Textures, texels, formats, and "readback"

A **texture** is an image the GPU can read: a grid of **texels** (texture pixels),
each holding a value in some **format** — e.g. `RG32UI` is "two channels (R, G),
each a 32-bit unsigned integer"; `RGBA32UI` is "four such channels".

**Readback** is when the CPU wants the pixels back (`glReadPixels`). This sounds
trivial but has two complications:

1. **Format conversion.** The app might render into an `RG32UI` buffer but read it
   back as `RGBA32UI`. So the copy is not a raw `memcpy` — each texel must be
   reformatted (here, pad RG out to RGBA).
2. **Memory layout.** GPUs do not store textures as simple row-major arrays; they
   tile and compress them (see AFBC in section 7). So the bytes in GPU memory are
   not in the order the CPU expects.

Because of this, the fastest converting readback is often to make **the GPU
itself** produce a plain, CPU-friendly copy in the destination format. The GPU's
natural tool for "read one image, write another, maybe reformat" is a **blit**.

## 3. What a "blit" is, and the surprising way GPUs do it

**Blit** = "block image transfer": copy a rectangle of pixels from a source image
to a destination, possibly scaling, flipping, or changing format.

The non-obvious part: a GPU has no dedicated "copy image" circuit for the general
case. Instead, **a blit is implemented by drawing:**

- Draw a rectangle (two triangles) covering the whole destination.
- Bind the *source* image as a texture.
- Run a tiny **fragment shader** that, for each destination pixel, looks up the
  matching source texel and writes it out.

A **fragment shader** (a.k.a. pixel shader) is a small program the GPU runs **once
per pixel** being drawn; its job is to compute that pixel's output. For a blit,
the output is "whatever texel sits at the corresponding spot in the source."

`u_blitter` is the shared helper that sets all of this up (rectangle, shader,
state), so drivers get blits "for free".

### TXF — the exact-texel lookup

A shader can read a texture two ways:

- **Sampling** (`texture()`): "give me the filtered color at this floating-point
  position" — blends neighboring texels, does mipmapping. Great for smooth
  rendering, *wrong* for an exact copy.
- **texelFetch** (`texelFetch()`, which Mesa/Gallium calls **TXF**): "give me the
  exact texel at integer coordinate (x, y), no filtering." This is what a faithful
  copy needs.

So a converting readback becomes: draw a rectangle, and for each destination pixel
run a shader that does `texelFetch(source, <the integer coordinate of this pixel>)`
and writes it out. That "integer coordinate of this pixel" is the crux of the bug.

## 4. Varyings and interpolation — the actual bug

How does the shader know *which* source texel corresponds to the destination pixel
it is shading?

The classic mechanism is a **varying**. When you draw the rectangle you attach a
value to each of its four corners (vertices) — here, the source texture coordinate
at that corner. As the GPU fills in the pixels between the corners, it
**interpolates**: a pixel 30% of the way across gets 30% of the way between the
corner values. The fragment shader reads this interpolated value as its "current
coordinate":

```glsl
coord = <interpolated varying: 0 at the left edge, WIDTH at the right edge>
texel = texelFetch(source, int(coord));   // truncate to integer, then fetch
```

For a 16307-wide readback the varying runs 0 -> 16307 across the rectangle, pixel
*i* should see `coord ~ i`, fetch texel *i*, done.

### The bug: Mali interpolates imprecisely

**Interpolation is done by fixed-function hardware — a dedicated circuit, not the
shader.** On Arm Mali, that circuit is accurate to only about **2^-10 relative
error** (~0.1%). It is tuned for texture coordinates in normal rendering, where
0.1% of a pixel is invisible.

But for an **exact texel copy**, 0.1% is catastrophic at large coordinates:

- At coordinate ~16000, a 2^-10 relative error is about **13 texels**.
- So the shader computes `coord ~ 16293` instead of `16306`, truncates, and
  **fetches texel 16293** — the wrong one.
- The error is *relative*, so it grows with position: early pixels are fine, later
  pixels drift further off.

Measured on the G610: a 16307-wide `RG32UI -> RGBA32UI` readback returned
**15672 of 16307 texels wrong**, each holding a neighbor's value. The CPU fallback
was correct; only the GPU blit was wrong.

### Two details that made this hard to find

- **It is not integer-specific.** The same test with floats (`RG32F -> RGBA32F`)
  fails identically — proving the problem is the *coordinate*, not the data. This
  rules out "just special-case integer formats."
- **It only happens at non-power-of-two widths.** A blit that is exactly 8192 or
  16384 wide is bit-exact; 5000, 8193, 12000, 16307 all drift. The interpolator's
  internal reciprocal happens to be exact for powers of two. This is why the bug
  hid for years — ordinary sizes are often powers of two, and the onset is only
  past ~3000-5000 pixels of width.

### Why you cannot "just interpolate more precisely"

- The shader never *sees* the raw corner values or the interpolation math — the
  hardware hands it the already-interpolated (already-lossy) result. There is no
  instruction to fetch the underlying data and redo it.
- The one alternative, `flat` interpolation, gives a single corner's value with
  **no** interpolation — exact but constant across the rectangle, useless for a
  per-pixel coordinate.
- Even `noperspective` ("linear, no perspective correction") is *emulated* through
  the same lossy path on Mali, so it does not help.

(Aside: Apple's GPU driver uses the same `u_blitter` code and does *not* have this
bug, because its hardware keeps the large part of the coordinate as an exact
per-tile constant and interpolates only a tiny local offset. Mali has no
equivalent, so the full large coordinate flows through the imprecise step.)

## 5. The fix: use `gl_FragCoord` instead of a varying

There is one exact per-pixel value available in a fragment shader:
**`gl_FragCoord`** — the pixel's own screen position. It does **not** come from the
interpolation circuit; it is produced by the **rasterizer** (which decides the
pixels a triangle covers) directly from the integer pixel index. It is bit-exact
by construction: the pixel at column 16306 knows it is at column 16306, exactly.

So the fix is: **stop deriving the source coordinate from an interpolated varying;
derive it from `gl_FragCoord` instead.**

But `gl_FragCoord` only says *where the pixel is on screen* (the destination). It
must be converted to *which source texel to fetch*, via an **affine map** (a scale
and an offset):

```
source_coord = fragment_position * scale + offset
```

- **scale** stretches/flips: `+1` for a plain copy, `-1` for a flipped blit;
  offsets shift.
- Because `u_blitter` is doing an *unscaled* TXF blit (no zoom — source and
  destination are the same size), **scale is always exactly +-1**. A convenient
  fact we use.

### Why this must live in `u_blitter`

The scale and offset come from the *specific blit request* — which source
rectangle, which destination rectangle, flipped or not. `u_blitter` knows all of
that when it sets up the draw. But once the shader is compiled by Panfrost, that
information is **gone** — the driver's compiler just sees "a generic fragment
shader that reads a varying and does a texelFetch." It has no idea "this varying is
a blit coordinate from source-box A to dest-box B."

So `u_blitter` is *the lowest layer that still has the scale/offset*. That is why
the fix belongs there and not in the Panfrost compiler — and why this cannot be a
pure Panfrost patch: the knowledge is not available inside Panfrost.

### The clever part: passing scale/offset without re-introducing imprecision

We still need to get `scale` and `offset` (which differ per blit) *into* the
shader. The normal channel — a varying — is the very thing that is imprecise.
Wouldn't we just reintroduce the error?

No. The key insight: **the imprecision only affects values that *change* across
the rectangle.** A varying holding the *same value at every corner* (a constant)
interpolates **bit-exactly**, even on Mali (verified: 0 errors at magnitudes up to
16306.5). The error scales with how much the value varies between corners; for a
constant that is zero.

Scale and offset are the same for every pixel in a given blit — they are
**constants for the draw**. So we can safely ship them through the coordinate
attribute. What we do *not* do is ship the per-pixel coordinate through it (that is
what varied and broke); the per-pixel part comes from the exact `gl_FragCoord`.

The generated shader now computes:

```
src = floor(pos) * scale + offset'
```

- `pos` is `gl_FragCoord`, exact.
- `floor(pos)` gives the exact integer pixel index.
- `scale` and `offset'` are per-draw constants, delivered exactly.

The `floor()` and `offset'` also handle a fiddly hardware-convention issue:
different GPUs report `gl_FragCoord` as either the pixel *center* (x + 0.5) or the
pixel *corner* (integer x). `floor()` normalizes both to the integer index, and
the missing half-texel is folded into the offset (`offset' = offset + 0.5*scale`).
With a `+1` scale the missing half-texel would be hidden by truncation anyway, but
with a `-1` scale (a **flipped** blit) it shifts every fetch by one and sends row 0
out of bounds — so flipped blits are exactly the case that tests this term (a real
bug caught during development).

### The attribute encoding (why it looks odd)

In the code the coordinate attribute is packed compactly:

```
x  = scale_x                     (+-1)
y  = scale_y * (layer + 0.25)    (sign carries scale_y; magnitude carries the
                                  array layer / 3D slice)
zw = the offsets (with the half-texel bias folded in)
```

This squeezes several per-draw constants into the four channels (x, y, z, w) of
one attribute. The `y` channel does double duty: its **sign** encodes whether the
vertical axis is flipped (`scale_y = +-1`), and its **magnitude**, when truncated,
recovers *which layer* of an array texture or *which slice* of a 3D texture to
read. The `+ 0.25` is a bias so truncation lands on the right integer. The shader
decodes this in **two cheap operations** (a sign extraction and an absolute value);
an earlier version used six operations and a review simplified it.

### The safety boundaries

The new path is deliberately narrow, and the code carefully **excludes** cases it
must not touch:

- **Only single-sample TXF blits** to 1D/2D/RECT, 1D/2D arrays, and 3D.
- **MSAA (multisample) blits are excluded** — they use *different* shaders
  (resolve/copy) that read the coordinate attribute the old way; feeding them
  scale/offset would corrupt them. (An earlier revision missed this and broke 62 of
  70 MSAA tests; now fixed by gating on sample count.)
- **The "ZS<->color pack" shaders and any caller-supplied shader are excluded** —
  they also read the plain attribute. The code decides *once*, where it picks the
  shader, whether the draw uses the new decode, and threads that single decision to
  the draw.
- **The flag defaults off.** Any driver that does not opt in generates exactly the
  shaders it did before. This is what makes the shared-code change safe for the ~10
  other drivers using `u_blitter`, and why it is structured as an opt-in flag
  (`blitter_context::use_txf_fragcoord`) rather than a behavior change for
  everyone.

## 6. The patches, one by one

Six commits across four merge requests:

### (a) `panfrost: clear shader image mask on trailing unbinds` — prerequisite bugfix (!42563)

Independent of everything else. A Panfrost function that unbinds "shader images"
(a kind of resource binding) freed the resource pointers for a trailing range of
slots but only cleared the *tracking bitmask* for part of it. Result: a slot could
have a null resource but still be marked "bound," and later code would dereference
that null and crash. The fix makes the bitmask-clearing cover the same range as the
resource-freeing. It has a `Fixes:` tag and is already reviewed; it is its own MR
because it stands alone.

### (b) `u_blitter: use fragment position for unscaled TXF blits` — the shared fix (!42679)

Everything in section 5, in the shared helper: adds the opt-in
`use_txf_fragcoord` flag; when set, generates blit shaders that read
`gl_FragCoord`, declare position appropriately (as a "system value" or an input per
a driver capability flag), and decode `src = floor(pos)*scale + offset'`; packs
scale/offset/layer into the coordinate attribute as constants; excludes MSAA, pack,
and override shaders. Touches `u_blitter.c/.h` (the blitter), `u_simple_shaders.c/.h`
(the shader generator), and one line in `u_tests.c` — a caller that had to change
because a function signature gained a parameter (in C, changing a function's
parameters forces every call site to change, or it will not compile). This is the
MR the reviewer wanted isolated, because it is shared code.

### (c) `panfrost: use fragment position for blitter TXF coordinates` — the driver opt-in (!42613)

Nine lines. Sets `use_txf_fragcoord = true` for Panfrost — but **only on "Bifrost
and newer" GPUs** (the `arch >= 6` gate, which includes the Valhall-based G610).
Older Mali ("Midgard") reads the fragment position through the *same* imprecise
varying machinery, so `gl_FragCoord` is not guaranteed exact there — turning the
fix on would not actually fix it, so Midgard is left on the old path.

### (d) `panfrost: Enable hardware texture conversion` — the payoff (!42613)

Joshua Watt's original patch (kept under his authorship at the reviewer's request,
with a note explaining the arch gate we added). It flips **one capability flag** to
tell the state tracker "Panfrost can do texture transfers via blit"
(`PIPE_TEXTURE_TRANSFER_BLIT`). That switch routes wide converting readbacks
through the GPU blit path — which is only *correct* now because (b) and (c) made
that path exact. In his testing it cut texture-heavy work by ~60%. The cap is also
gated on `arch >= 6`, so Midgard never routes transfers through the still-lossy
path.

### (e)+(f) The test and its enabler (!42614)

- `u_tests: add a wide unscaled format-changing blit test` — a self-contained test
  that blits a 16307-wide texture whose texels encode their own coordinates, then
  checks *every* destination texel. It **fails without the fix** (40884 wrong
  texels) and **passes with it**. It uses a large non-power-of-two width, because a
  power-of-two width could never expose the bug.
- `panfrost: hold a glsl_type singleton reference for the screen` — pure
  test-plumbing. Running Gallium's unit tests on Panfrost tripped over an
  initialization-order issue (a shared type table was not set up yet); this holds a
  reference so the tests can run. radeonsi already does the same.

## 7. Why not simpler approaches?

Three alternatives were tried and rejected — worth knowing because they justify the
fix's shape:

- **Fall back to the CPU for these transfers.** Correct but slow, and it would
  pessimize *every* driver, not just Mali.
- **Special-case integer formats.** Rejected because the float test (`RG32F`) fails
  identically — the bug is in the coordinate, not the data type, so an integer-only
  gate misses real corruption.
- **Use GPU *compute* shaders instead of blits.** Compute can compute exact
  coordinates (it addresses pixels directly, no interpolation) and was even faster
  in benchmarks. But the Mali maintainer rejected it: *"Compute isn't the right
  solution. We can't write AFBC that way."*

  **AFBC** (Arm Frame Buffer Compression) is Mali's lossless texture compression —
  most textures live in a proprietary compressed layout to save bandwidth. Writing
  AFBC requires the fixed-function render/blit hardware; a compute shader cannot
  produce that layout. A compute-based transfer would either fail on AFBC surfaces
  or silently force them into an uncompressed layout — unacceptable for things like
  the screen buffer. Keeping the **blit** path (and making its coordinate exact)
  preserves AFBC, which is why the `gl_FragCoord` approach won.

## The one-sentence version

Mali's fixed-function interpolator is ~0.1% imprecise, which silently corrupts wide
GPU texture copies because those copies derive each pixel's source coordinate from
an interpolated value; we rewrote Gallium's shared blit helper to derive that
coordinate from the exact `gl_FragCoord` plus per-draw constants instead — behind
an opt-in flag Panfrost turns on for Bifrost+ — and only then enabled the faster
GPU-blit texture-transfer path.
