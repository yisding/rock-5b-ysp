# Rust librga rewrite assessment

This note records the findings from reviewing the local `librga-src` checkout
and comparing a possible Rust userspace rewrite with the in-progress
`rga-rewrite` kernel driver work in `../linux-6.18-rkvenc`.

The short version: a useful Linux-first Rust `librga` replacement is feasible
and materially smaller than the kernel rewrite, but it is still real ABI work.
The best point estimate is **about 45% of the work already done on
`rga-rewrite`**, assuming the target is source-compatible IM2D plus the legacy
paths needed by current samples, FFmpeg, and GStreamer-style users.

## What `librga` exposes

The recommended public API is IM2D:

- C++ includes `im2d_api/im2d.hpp`.
- C includes `im2d_api/im2d.h`.
- Applications link `librga.so` or `librga.a`.

The old `include/RgaApi.h` / `include/RockchipRga.h` layer still exists for
legacy `RgaBlit`-style callers. New code should prefer IM2D, but replacement
library planning cannot ignore the legacy layer because existing Rockchip media
software still emits those request shapes.

IM2D is organized into these pieces:

| Header group | Role |
|--------------|------|
| `im2d_type.h` | ABI structs, status codes, usage flags, formats, rectangles, options. |
| `im2d_common.h` | `querystring`, `imStrError`, `imcheck`, `imsync`, `imconfig`. |
| `im2d_buffer.h` | `importbuffer_*`, `releasebuffer_handle`, `wrapbuffer_*`, alpha/color-space option setters. |
| `im2d_single.h` | One-shot operations: copy, resize, crop, convert, rotate, flip, blend, fill, mosaic, OSD, gauss, palette, generic `improcess`. |
| `im2d_task.h` | Batch job API: `imbeginJob`, `im*Task`, `imendJob`, `imcancelJob`. |
| `im2d_mpi.h` | Context-style entry points used by the newer kernel request path. |
| `im2d_expand.h` | Android `GraphicBuffer` / `AHardwareBuffer` helpers. |

The central data model is:

- `rga_buffer_t`: image memory plus width, height, stride, format, color space,
  alpha state, read mode, and optional imported buffer handle.
- `rga_buffer_handle_t`: driver-side imported memory handle.
- `im_rect`: `{ x, y, width, height }`.
- `im_opt_t`: optional per-operation state for color, color-key, NN quantize,
  ROP, priority, core, mosaic, OSD, line interrupts, interpolation, and gauss.
- `IM_STATUS`: success/error return codes.

The normal call flow is:

1. Allocate or receive image memory, usually a dma-buf fd or a userspace virtual
   address.
2. Import it with `importbuffer_fd`, `importbuffer_virtualaddr`, or
   `importbuffer_physicaladdr`, when the caller wants a persistent driver-side
   handle.
3. Wrap it as an `rga_buffer_t` with `wrapbuffer_handle`, `wrapbuffer_fd`, or
   `wrapbuffer_virtualaddr`.
4. Optionally call `imcheck` during development to validate parameters and
   hardware support.
5. Call a one-shot operation such as `imresize`, `imcopy`, `imrotate`, or the
   generic `improcess`, or build a task job with `imbeginJob` and `im*Task`.
6. If async mode is used, consume the release fence with `imsync` or pass it to
   the next hardware stage.
7. Release imported handles with `releasebuffer_handle` at teardown.

## Operation surface

The one-shot API covers:

| Area | Public entry points |
|------|---------------------|
| Basic movement | `imcopy`, `imresize`, `impyramid`, `imcrop`, `imtranslate`. |
| Format/layout | `imcvtcolor`, `imsetColorSpace`, DRM fourcc/modifier wrapping in C++. |
| Transform | `imrotate`, `imflip`, rotate-plus-flip through transform flags. |
| Composition | `imblend`, `imcomposite`, Porter-Duff flags, global/per-pixel alpha, alpha bitmap. |
| Keying/OSD | `imcolorkey`, `imosd`, OSD auto-invert/statistics config. |
| Drawing/fill | `imfill`, `imfillArray`, `imrectangle`, `imrectangleArray`, `immakeBorder`. |
| Effects | `immosaic`, `immosaicArray`, `imgaussianBlur`, `impalette`. |
| NN/logic | `imquantize`, `imrop`. |
| Escape hatch | `improcess` / `improcessOpt` with usage flags and `im_opt_t`. |

The task API mirrors most of those operations with `im*Task` variants and
submits them as a single job. Existing librga users rely on this for copy-splice,
multi-rectangle fill, multi-mosaic, and mixed serial request shapes.

## Why the Rust rewrite is smaller than the driver rewrite

The current `rga-rewrite` driver already owns the hard kernel problems:

- ioctl ABI parsing and compat/native layout handling;
- dma-buf import, userspace virtual-address pinning, sg-table construction, and
  per-core DMA mapping;
- acquire/release fence ownership;
- async job lifetime and file-close cleanup;
- scheduler, per-core queues, priority aging, runtime PM, clocks, IRQs,
  timeouts, resets, and IOMMU fault recovery;
- RGA2/RGA3 command-buffer generation and hardware profile selection.

A Rust userspace library would mostly normalize public API calls into the ioctl
shapes that the driver already accepts. It would still need exact ABI behavior,
but it would not need to program MMIO registers, handle IRQs, reset hardware, or
own kernel memory lifetime hazards.

## What remains difficult in Rust

The main risks are compatibility risks, not Rust-language risks:

- Exact `#[repr(C)]` layout for `rga_buffer_t`, `im_rect`, `im_opt_t`,
  `rga_info_t`, import-buffer pools, request arrays, and legacy structs.
- Constants and bit flags must match the C headers exactly.
- C compatibility is straightforward; C++ ABI compatibility is not. IM2D uses
  C++ overloads and default arguments in headers, while Rust naturally exports a
  C ABI. The sane path is Rust core plus stable C exports plus compatibility
  headers/macros, not pretending to be a compiler-specific C++ ABI library.
- The library has to preserve old librga quirks: return-code differences,
  version/capability probing, header-version checks, default alpha/color-space
  policy, core-mask behavior, async fence close ownership, and parameter
  normalization before ioctl submission.
- Android `GraphicBuffer`, gralloc4/gralloc5, and `AHardwareBuffer` support is a
  separate expansion, not part of a minimal Linux-first replacement.

## Estimated size relative to `rga-rewrite`

The useful planning estimate is:

| Target | Estimate relative to work already done on `rga-rewrite` |
|--------|----------------------------------------------------------|
| Thin Rust wrapper over existing `librga.so` | ~5% |
| Common IM2D only, Linux-first | ~25-35% |
| Practical Rust `librga` replacement matching current `rga-rewrite` ABI coverage | **~40-55%**, point estimate **45%** |
| Linux plus Android gralloc/AHardwareBuffer and broad BSP quirk compatibility | ~70-100% |
| True binary-compatible drop-in for already-compiled C++ consumers | >100%, not recommended |

The 45% estimate assumes:

- Linux-first only.
- Source compatibility, not binary compatibility for existing C++ objects.
- The current `rga-rewrite` ABI slice is the kernel contract.
- Current librga samples, ffmpeg-rockchip, JeffyCN GStreamer-style conversions,
  and the existing support-repo smoke/suite shapes define the first milestone.

## Suggested implementation strategy

Build it as a Rust core with a C ABI boundary:

1. Define Rust `#[repr(C)]` structs and constants generated or checked against
   the C headers.
2. Export stable `extern "C"` functions for the real symbols used by C callers
   and macro-backed IM2D C compatibility.
3. Keep C/C++ headers as thin source-compatibility wrappers around the C ABI.
4. Implement buffer wrapping/import/release first.
5. Implement `improcess` as the central request builder, then layer convenience
   calls such as `imcopy`, `imresize`, and `imcvtcolor` on top.
6. Add task-job state and async fence behavior after one-shot sync paths pass.
7. Reuse the existing support-repo librga sample and GStreamer/FFmpeg suite
   shapes as the acceptance matrix.

Do not start by trying to reproduce every C++ overload symbol. That turns a
manageable userspace rewrite into a C++ ABI archaeology project.

## Practical milestone plan

| Milestone | Contents |
|-----------|----------|
| 1. ABI skeleton | Struct layout tests, constants, status/error strings, `querystring`, header-version checks. |
| 2. Buffer basics | `wrapbuffer_*`, fd/virtual-address imports, release, direct no-handle buffer paths. |
| 3. Sync one-shot ops | `imcopy`, `imresize`, `imcrop`, `imtranslate`, `imcvtcolor`, `imrotate`, `imflip`, `imfill`, backed by `improcess`. |
| 4. Validation | `imcheck` behavior that matches the supported driver ABI slice and reports useful `IM_STATUS` failures. |
| 5. Async | release-fence export, `imsync`, acquire-fence ownership semantics. |
| 6. Task API | `imbeginJob`, `im*Task`, `imendJob`, `imcancelJob`, serial multi-task request building. |
| 7. Advanced profiles | Blend/composite, color-key, OSD, mosaic, ROP, gauss, quantize, palette, border helpers, as covered by `rga-rewrite`. |
| 8. Legacy layer | `RgaApi.h`/`RgaBlit` source compatibility and the request shapes used by older media plugins. |
| 9. Android, optional | gralloc4/gralloc5 and `AHardwareBuffer` helpers if Android becomes a target. |

## Bottom line

For this project, the Rust userspace rewrite is best viewed as a compatibility
frontend for the cleaner kernel ABI learned during `rga-rewrite`. It is not as
dangerous as the driver rewrite because the driver already owns hardware and
kernel lifetime, but it is not a weekend wrapper either. Budget it as **roughly
half of the already-completed `rga-rewrite` effort** for a useful Linux-first
replacement, with the point estimate at **45%**.
