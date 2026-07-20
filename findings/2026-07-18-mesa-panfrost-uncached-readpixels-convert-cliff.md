# Mesa/panfrost: glReadPixels convert fallback is catastrophic over uncached imported buffers

> Scope: two upstream Mesa bugs found while root-causing the gnome-remote-desktop
> RK3588 hang ([finding](./2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md)).
> Environment: RK3588 (Mali-G610, **panthor** kmod), Mesa `26.0.3-1ubuntu1`;
> analysis against the `fdo/mesa` tree (`26.2.0-devel`, `4c23f1db1f9`).
> Date: 2026-07-18
> Trust: MEASURED (gdb: 99.9% CPU in `convert_ubyte`, 5+ min CPU/frame) /
> SOURCE-INSPECTED (Mesa + panfrost + panthor) / CONFIRMED (build-id-matched
> symbols)

## Summary

`glReadPixels(GL_BGRA, GL_UNSIGNED_BYTE)` from a texture backed by an **imported,
linear** dma-buf takes **seconds to minutes** for a single full-resolution frame
on panfrost/panthor, pinning a CPU core at 100%. It is a CPU-read performance
cliff, not a GPU hang (panthor logs no fault/timeout). Two independent upstream
issues combine:

## Bug A (core Mesa) — readpix fallback converts per-pixel from the raw source map

`st_ReadPixels` rejects its blit-based fast path (BGRA-from-import trips a
`goto fallback` — format/base-format/`_mesa_readpixels_needs_slow_path`) and
falls to `_mesa_readpixels` → `read_rgba_pixels` (`src/mesa/main/readpix.c`):

```c
_mesa_map_renderbuffer(ctx, rb, x, y, width, height, GL_MAP_READ_BIT,
                       &map, &rb_stride, fb->FlipY);
... _mesa_format_convert(dst, ..., map, ...);   /* convert_ubyte: per-pixel reads of *map */
```

`_mesa_format_convert`/`convert_ubyte` (`src/mesa/main/format_utils.c`) reads the
mapped source **one pixel at a time**. When `map` points at **write-combined /
uncached** memory (~100–300 ns per access, no burst/prefetch), a multi-megapixel
frame costs seconds. Mesa already ships `util/format/streaming-load-memcpy.h`
(MOVNTDQA-style streaming loads) for exactly the uncached/WC-source case, but the
readpix fallback does not use it — it never bulk-copies the source into a cached
bounce before converting.

**Fix:** in the readpix fallback, when the source map is uncached/WC (or
unconditionally, since a cached bounce is cheap relative to per-pixel WC reads),
`streaming_load_memcpy` each row into a cached scratch buffer, then convert from
that. Benefits any driver that maps the readback source uncached.

## Bug B (panfrost driver) — imported linear buffers are read back via a direct uncached map

`panfrost_ptr_map` (`src/gallium/drivers/panfrost/pan_resource.c`) has a cached
staging path only for compressed/tiled sources:

```c
/* We don't have s/w routines for AFBC/AFRC, so use a staging texture */
if (drm_is_afbc(rsrc->modifier) || drm_is_afrc(rsrc->modifier)) {
    ... pan_blit_to_staging(...); ...   /* GPU-decompress into a cached, panthor-owned BO */
}
```

**Linear** imports fall through to a **direct** map of the imported BO. On
panthor that BO is **uncached**: panthor maps its own BOs `DRM_PANTHOR_BO_WB_MMAP`
(write-back cached) but treats imports as uncached —
`src/panfrost/lib/kmod/panthor_kmod.c:471`:

> *"we've always assumed exporters were exposing uncached mappings with NOP
> {begin,end}_cpu_access() implementations…"*

So a CPU read of an imported linear buffer (exactly what `glReadPixels` fallback
does) reads uncached memory directly.

**Fix:** route imported-linear CPU readback through a cached staging blit too
(as AFBC/AFRC already do), or honor `DMA_BUF_IOCTL_SYNC` and map cached when the
exporter supports coherent CPU access.

## Reproducer

RK3588 + panthor + any GL client that `glReadPixels(GL_BGRA)` from an imported
linear dma-buf FBO (gnome-remote-desktop's `download_in_impl` — its RDP
generic-GL/software and VNC capture path — under a busy desktop such as
full-screen video). gdb shows the thread at 99.9% CPU in
`convert_ubyte`←`_mesa_format_convert`←`read_rgba_pixels`←`st_ReadPixels`, stuck
at the same PC across samples.

## Relationship / consumer-side mitigation

The GRD consumer worked around this in
`0017-egl-thread-read-back-via-a-cached-GPU-copy` (copy the import into a cached,
driver-owned texture with `glCopyTexSubImage2D`, then read that back) — see the
[GRD finding](./2026-07-18-grd-starvation-detector-diagnostic-only-no-recovery.md).
Either Mesa fix (A or B) removes the cliff for all GL clients without the
app-side copy; A is the broadest (any uncached-import driver), B is panfrost-local.

## Filing notes

Two separate upstream reports (gitlab.freedesktop.org/mesa/mesa): A against
`mesa/main` readpixels; B against the panfrost driver. Include the gdb evidence
in `scratchpad/grd-hang-150509-pid75635/` and this analysis. Verify the exact
`goto fallback` reason at runtime (`MESA_DEBUG`/apitrace) before filing A, to
name which condition rejects the blit path for BGRA-from-import.
