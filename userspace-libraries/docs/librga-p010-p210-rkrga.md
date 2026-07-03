# RKRGA P010/P210, compact 10-bit, and librga compatibility

This note records the P010/P210 investigation across `ffmpeg-rockchip-81`,
Rockchip's BSP RGA driver, older librga drops, Jellyfin's Rockchip pipeline, and
nyanmisaka's patched librga branch.

The short version: P010/P210 through the legacy RGA API is only safe when librga
copies the 10-bit layout flags into the kernel request. The older source tree
did not. Jellyfin's packaged Rockchip path relies on a patched librga branch that
does copy those fields for the blit path; we extended the local fix to the other
legacy request builders too.

## Source trees checked

The investigation used these local sibling trees:

| Tree | What it contributed |
|------|---------------------|
| `../ffmpeg-rockchip-81` | Current RKRGA filter implementation under review. |
| `../librga-src` | Buildable librga source lineage, initially missing the 10-bit copy. |
| `../librga` | airockchip-style prebuilt/header distro, version `1.10.6_[3]`. |
| `../rockchip-kernel` | BSP RGA3/RGA2 kernel UAPI and driver behavior. |
| `/tmp/jellyfin-server` | Jellyfin server FFmpeg command generation. |
| `/tmp/jellyfin-ffmpeg` | Jellyfin FFmpeg patch set for Rockchip. |
| `/tmp/jellyfin-rk-mirrors` | `nyanmisaka/rk-mirrors`, including branch `jellyfin-rga`. |

The important Jellyfin RGA source branch was:

```text
https://github.com/nyanmisaka/rk-mirrors/tree/jellyfin-rga
commit 1d330cc28551943bed3380261a5a9c6fbd58ff53
```

## Format model

There are two different 10-bit semiplanar layout families involved:

| Layout | FFmpeg/DRM names | Meaning |
|--------|------------------|---------|
| Padded MSB-aligned 10-bit | `AV_PIX_FMT_P010`, `AV_PIX_FMT_P210`, `DRM_FORMAT_P010`, `DRM_FORMAT_P210` | Samples live in 16-bit containers with unused low bits. |
| Compact bitstream 10-bit | `AV_PIX_FMT_NV15`, `AV_PIX_FMT_NV20` / `NV20_PACKED`, `DRM_FORMAT_NV15`, `DRM_FORMAT_NV20` | No 16-bit padding; samples are packed into a bitstream layout. |

The RK3588 BSP RGA3 kernel UAPI does not expose native `P010` or `P210` format
enums. It exposes generic 10-bit semiplanar RGA formats, for example
`RGA_FORMAT_YCbCr_420_SP_10B` and `RGA_FORMAT_YCbCr_422_SP_10B`, plus request
fields that describe whether the 10-bit layout is compact or incompact and how
the 10-bit samples are aligned.

This creates a naming trap:

- In the kernel request ABI, the field at this slot is `compact_mode`.
- The enum value `RGA_10BIT_COMPACT` is `0`.
- The enum value `RGA_10BIT_INCOMPACT` is `1`.
- Older librga internal structs name the same ABI slot `is_10b_compact`.
- Therefore setting userspace `rga_info_t.is_10b_compact = 1` is actually used
  by these FFmpeg paths to request the kernel's incompact/padded P010/P210-style
  layout, not compact NV15/NV20.

That naming mismatch is why this bug was easy to miss.

## What ffmpeg-rockchip does

The RKRGA filters in `ffmpeg-rockchip-81` still use the legacy RGA API:

- `configure` probes `rga/RgaApi.h` and `c_RkRgaBlit`.
- `libavfilter/rkrga_common.h` stores `rga_info_t`.
- `libavfilter/rkrga_common.c` eventually calls `c_RkRgaBlit()`.

The format map uses the same RGA format code for padded and compact 10-bit:

| FFmpeg format | RGA format |
|---------------|------------|
| `AV_PIX_FMT_P010` | `RK_FORMAT_YCbCr_420_SP_10B` |
| `AV_PIX_FMT_P210` | `RK_FORMAT_YCbCr_422_SP_10B` |
| `AV_PIX_FMT_NV15` | `RK_FORMAT_YCbCr_420_SP_10B` |
| `AV_PIX_FMT_NV20_PACKED` | `RK_FORMAT_YCbCr_422_SP_10B` |

The distinguishing state is `uncompact_10b_msb`:

- `P010` and `P210` set `uncompact_10b_msb`.
- When that bit is set, the RKRGA code writes
  `info.is_10b_compact = info.is_10b_endian = 1` before the legacy blit call.
- `NV15` and `NV20` do not set that bit, so they stay on the compact default.

The RKMPP decoder maps MPP 10-bit output to compact formats, not P010/P210:

- `MPP_FMT_YUV420SP_10BIT` -> `DRM_FORMAT_NV15` / `AV_PIX_FMT_NV15`.
- `MPP_FMT_YUV422SP_10BIT` -> `DRM_FORMAT_NV20` / `AV_PIX_FMT_NV20_PACKED`.

So RKRGA's P010/P210 paths are mostly about conversion, scaling, and filter
outputs that need padded 10-bit surfaces, not the raw RKMPP decoder surface
itself.

## What the BSP kernel expects

The BSP RGA3 driver expects the old-style request shape:

1. A generic 10-bit semiplanar RGA format.
2. A layout selector in `compact_mode`.
3. An endian/alignment selector in `is_10b_endian`.

In `../rockchip-kernel`, the RGA3 path converts the user request roughly as:

| User request | Internal window meaning |
|--------------|-------------------------|
| `compact_mode = RGA_10BIT_COMPACT` or default `0` | compact 10-bit, NV15/NV20-style |
| `compact_mode = RGA_10BIT_INCOMPACT` / `1` | incompact/padded 10-bit, P010/P210-style |

The RGA2 path has much less explicit 10-bit layout selection. Its code contains
legacy assumptions for 10-bit raster formats and does not expose the same
compact/incompact selector.

### RGA2 compatibility request path

In `../librga-src`, the fallback is selected only when
`RGA_IOC_GET_DRVIER_VERSION` fails and the older `RGA2_GET_VERSION` or
`RGA_GET_VERSION` ioctl succeeds. librga then sets
`ctx->driver = RGA_DRIVER_IOC_RGA2`.

That path is easy to misread because librga names its fallback userspace request
`rga2_req`, but this struct is shaped like the old `RGA_BLIT_SYNC` `struct
rga_req`, not like the standalone kernel driver's `RGA2_BLIT_SYNC` internal
request. The compatibility flow is therefore:

1. Build the modern `struct rga_req` in `NormalRga.cpp`.
2. Convert it with `NormalRgaCompatModeConvertRga2()`.
3. Submit the converted old-style request with `RGA_BLIT_SYNC`.
4. On a standalone RGA2 kernel, the driver copies that old request and runs its
   own `RGA_MSG_2_RGA2_MSG()` conversion into the real RGA2 register request.

The conversion is intentionally lossy. The fallback image struct preserves
addresses, format, active/virtual geometry, endian mode, and alpha swap, but it
has no fields for RGA3-only state such as `rd_mode`, `compact_mode` /
`is_10b_compact`, or `is_10b_endian`.

The standalone RGA2 BSP code does include 10-bit semiplanar format enums such as
`RGA2_FORMAT_YCbCr_420_SP_10B` and `RGA2_FORMAT_YCbCr_422_SP_10B`. Those enums
only say "generic 10-bit semiplanar". They do not distinguish padded P010/P210
from compact NV15/NV20-style layout. The RGA2 register generator sets its YUV10
enable bit from the format and uses implicit legacy stride/layout rules.

Implication: compact 10-bit surfaces are the only 10-bit case that looks plausibly
compatible with the RGA2 fallback. Padded P010/P210 should be considered unsafe on
this path. The request can be accepted as a generic 10-bit semiplanar operation
even though the ABI cannot say "this is incompact/padded 16-bit P010/P210", so
the likely failure mode is corrupted image data rather than a clean unsupported
format error.

The local `../librga-src` follow-up now rejects this instead of attempting the
lossy conversion. When `ctx->driver == RGA_DRIVER_IOC_RGA2`, the legacy wrappers
return `-EINVAL` before ioctl submission if an active image slot uses:

- Any non-raster RGA3 `rd_mode`, because RGA2 compatibility does not carry FBC or
  tile mode state.
- Any generic 10-bit semiplanar format with `is_10b_compact` or `is_10b_endian`
  set, because those flags are the only way callers express padded/incompact
  P010/P210-style layout.

The palette-table update sub-request was also routed through the same RGA2
compatibility conversion instead of submitting the larger RGA3-shaped request
directly to `RGA_BLIT_SYNC`.

Display support in the checked BSP also points toward compact native 10-bit:
the Rockchip VOP/VOP2 DRM format tables include linear `NV15`/`NV20`, while the
checked tables did not show the same native scanout path for `P010`/`P210`.

## What was broken in older librga

In the older buildable librga source, the public `rga_info_t` contains:

- `rd_mode`
- `is_10b_compact`
- `is_10b_endian`

But the legacy request generator only copied `rd_mode` into the ioctl request.
It did not copy `is_10b_compact` or `is_10b_endian` from the caller-level
`rga_info_t`.

The same issue appeared in the older im2d implementation path: it copied
`rd_mode`, but there was no public `rga_buffer_t` field for P010/P210 compactness
and no observed copy of the legacy caller-level 10-bit layout fields.

The first Jellyfin patch fixed the main `RgaBlit()` path only. A follow-up audit
of `../librga-src/core/NormalRga.cpp` found two more legacy request builders that
assigned `rd_mode` but did not copy the 10-bit layout fields:

| Legacy operation | Public wrapper | Missing state |
|------------------|----------------|---------------|
| Blit / scale / CSC / overlay | `c_RkRgaBlit()` | Fixed by nyanmisaka's patch, then refactored locally through a helper. |
| Color fill | `c_RkRgaColorFill()` | Destination `is_10b_compact` / `is_10b_endian`. |
| Color palette | `RkRgaCollorPalette()` C++ wrapper | Source, destination, and LUT/pattern `is_10b_compact` / `is_10b_endian`. |

The palette path also had a separate legacy submission bug: after selecting
either `&rgaReg` or `&compat_req` into `ioc_req`, it called
`ioctl(..., &ioc_req)`. That passes a pointer-to-pointer to the kernel instead
of the request buffer. The blit and color-fill paths use `ioctl(..., ioc_req)`.

Implication:

- Compact NV15/NV20 often still appears to work because compact is the kernel
  default.
- Padded P010/P210 can be silently interpreted as compact 10-bit by the kernel.
- That is image corruption territory, not a clean unsupported-format failure.

The `../librga` 1.10.6 prebuilt/header distro added public P010/P210 names and
DRM fourcc handling for im2d, but its legacy `c_RkRgaBlit()` path still looked
suspicious from disassembly: it copied `rd_mode`, and we did not find the
corresponding caller-field copies for the 10-bit layout fields.

For im2d 1.10.6, the binary clearly has new branches for P010/P210-ish format
constants. What we could not prove from the binary alone is whether it translates
those new im2d P010/P210 constants into the old BSP kernel request shape. That
needs full source or a hardware test.

## What Jellyfin does

Jellyfin server does use the Rockchip P010 path.

In the Rockchip RKMPP/RKRGA/OpenCL filter chain, when RKMPP decode is feeding
OpenCL tonemapping, Jellyfin chooses:

```text
outFormat = doOclTonemap ? "p010" : "nv12"
```

That becomes a `vpp_rkrga` or `scale_rkrga` output format before mapping the DRM
surface into OpenCL for tonemapping. This is the important Jellyfin use case:
HDR or 10-bit decode -> RKRGA P010 surface -> OpenCL tonemap -> NV12 output.

Jellyfin also has a targeted workaround for a BSP RGA P010 corruption issue in
one extreme scaling path. For two-pass downscales beyond RGA3's single-pass
ratio, it uses `nv15` as the first-pass intermediate when OpenCL tonemapping is
active, then continues through the normal pipeline. That workaround is not a
global avoidance of P010.

I did not find a Jellyfin server command-generation path that emits `format=p210`.
P210 exists in the FFmpeg/RKRGA capability code and is relevant for 4:2:2 paths,
but Jellyfin's normal Rockchip server pipeline appears to use P010, NV15, and
NV12 rather than P210.

Jellyfin-ffmpeg's RKRGA patch uses the legacy `c_RkRgaBlit()` API, not im2d, for
the RKRGA filters. Therefore Jellyfin's P010 path depends on a librga where the
legacy path copies the 10-bit layout fields.

## nyanmisaka's librga patch and local follow-up

The `nyanmisaka/rk-mirrors` `jellyfin-rga` branch adds exactly the blit-path copy
we were missing:

```cpp
/* rga3 is_10b_compact and is_10b_endian */
if (rgaReg.src.rd_mode == raster_mode) {
    rgaReg.src.is_10b_compact = !!src->is_10b_compact;
    rgaReg.src.is_10b_endian  = !!src->is_10b_endian;
}
if (rgaReg.dst.rd_mode == raster_mode || rgaReg.dst.rd_mode == tile_mode) {
    rgaReg.dst.is_10b_compact = !!dst->is_10b_compact;
    rgaReg.dst.is_10b_endian  = !!dst->is_10b_endian;
}
if (src1 && rgaReg.pat.rd_mode == raster_mode) {
    rgaReg.pat.is_10b_compact = !!src1->is_10b_compact;
    rgaReg.pat.is_10b_endian  = !!src1->is_10b_endian;
}
```

The same branch also carries other useful changes:

- RGA3 FBCE RGB/BGR fixup for older drivers.
- A full-CSC ordering/masking fix in `NormalRga.cpp`.
- Meson cleanup removing a duplicate static `librga` target.

We replayed that three-file delta onto `../librga-src`, then added a local
follow-up to cover all legacy request builders in `NormalRga.cpp`.

The follow-up introduced a shared helper:

```cpp
static inline void NormalRgaSet10BitMode(rga_img_info_t *img,
                                         rga_info *info,
                                         int allow_tile_mode) {
    if (!img || !info)
        return;

    if (img->rd_mode == raster_mode ||
        (allow_tile_mode && img->rd_mode == tile_mode)) {
        img->is_10b_compact = !!info->is_10b_compact;
        img->is_10b_endian = !!info->is_10b_endian;
    }
}
```

The tile exception is intentionally destination-only, matching nyanmisaka's
original policy. Source and pattern/LUT channels only receive these layout flags
for raster mode; destination receives them for raster and tile mode. FBC paths do
not use this 10-bit layout selector.

Current local `../librga-src` changes:

| File | Result |
|------|--------|
| `core/NormalRga.cpp` | Added FBCE fixup, full-CSC fixup, shared 10-bit layout helper, blit/fill/palette 10-bit layout field copies, and fixed palette `ioctl(..., ioc_req)`. |
| `include/RgaApi.h` | Added `RGA_NORMAL_DST_FULL_CSC_FIXUP` and `RGA_NORMAL_FBCE_RGB_BGR_FIXUP`. |
| `meson.build` | Removed the duplicate `static_library()` target. |

Validation after replay:

```bash
meson setup /tmp/librga-src-build-codex-1783097466 ../librga-src -Dlibrga_demo=false
CCACHE_DISABLE=1 ninja -C /tmp/librga-src-build-codex-1783097466
```

The build completed and linked `librga.so.2.2.0`. The first build attempt failed
only because `ccache` could not write `/home/yi/.cache/ccache`; disabling ccache
fixed the environment issue.

After the local follow-up, the incremental rebuild also completed:

```bash
CCACHE_DISABLE=1 ninja -C /tmp/librga-src-build-codex-1783097466
```

It rebuilt `core_NormalRga.cpp.o` and relinked `librga.so.2.2.0`.

After adding the RGA2 rejection guard, the same rebuild completed again and
relinked `librga.so.2.2.0`.

## What this fixes, and what it cannot fix

This now closes the known userspace legacy-request propagation hole for the
multi-RGA/RGA3 ioctl path. In `NormalRga.cpp`, every live assignment of
`rgaReg.*.rd_mode` in the public legacy operations is followed by a call that
copies the matching 10-bit layout fields when that channel mode can use them.

Fixed by the local source tree:

| Case | Status |
|------|--------|
| Legacy blit/scale/CSC/overlay P010/P210 | 10-bit layout fields now propagated. |
| Legacy color-fill into padded 10-bit destination | Destination layout fields now propagated. |
| Legacy color-palette request with padded 10-bit channels | Source/destination/LUT layout fields now propagated where applicable. |
| Palette final ioctl request pointer | Fixed from `&ioc_req` to `ioc_req`. |
| RGA2 compatibility fallback for unsafe inputs | Rejects non-raster `rd_mode` and padded/incompact 10-bit layout flags with `-EINVAL` before ioctl submission. |
| Palette-table update on RGA2 fallback | Uses the RGA2 compatibility request conversion instead of submitting the larger RGA3 request shape directly. |

Still not proven or not fixed by this source patch:

| Case | Reason |
|------|--------|
| BSP/kernel P010 corruption independent of userspace flags | Jellyfin carries an `nv15` first-pass workaround for one RGA P010 corruption case. This patch does not change kernel behavior. |
| im2d P010/P210 | The fix is in the legacy `NormalRga.cpp` path. im2d 1.10.6 may have its own P010/P210 handling, but that needs source proof or hardware validation. |
| RGA2 compatibility request | The old `RGA_BLIT_SYNC` ABI has no RGA3 `rd_mode`/`compact_mode`/`is_10b_endian` fields. Compact 10-bit may work through the legacy implicit format behavior, but padded P010/P210 and non-raster modes are now rejected locally. |
| Android-only `NormalRgaPaletteTable()` | It does not receive caller-level `rga_info_t` 10-bit layout fields, so there is no equivalent state to propagate. |
| Unknown prebuilt librga binaries | The local source is fixed; an external `.so` must be tested or audited separately. |

## Shipping guidance

Do not ship RKRGA P010/P210 support against an unverified librga legacy path.
The local source-built `../librga-src` is now the preferred legacy-library input
because it fixes every known userspace propagation site in the public legacy
operations.

Safe options:

| Option | Risk profile |
|--------|--------------|
| Build and stage the patched `../librga-src` | Best match for Jellyfin-style legacy RKRGA P010 use; covers blit, color fill, and palette legacy builders. |
| Migrate RKRGA to im2d P010/P210 and validate on hardware | Potentially the long-term supported API, but needs proof against the deployed kernel/librga pair. |
| Disable padded P010/P210 in RKRGA | Conservative if the deployed librga is unknown or unpatched. |
| Keep compact NV15/NV20 handling | Lower risk because compact is the default/implicit 10-bit interpretation, though RGA2/RGA3 restrictions still apply. |

If the packaged stack uses airockchip's prebuilt 1.10.6 library, do not assume
the legacy P010/P210 path is fixed. Either test the exact binary on hardware or
ship a known patched source-built librga.

## Test cases to keep

Minimum validation before enabling padded 10-bit RKRGA paths:

1. RKMPP 10-bit HEVC or VP9 decode with OpenCL tonemapping through Jellyfin's
   Rockchip path, which exercises RKRGA `format=p010`.
2. Direct FFmpeg `vpp_rkrga` or `scale_rkrga` conversion to `format=p010`, then
   `hwmap=derive_device=opencl` or `hwdownload` plus checksum/visual validation.
3. A compact input path using `NV15` or `NV20` to ensure the patch did not break
   the compact default.
4. A forced unsupported/old-core path to confirm P010/P210 still reject cleanly
   when RGA3 is not available.

P210 should be treated as capability code rather than a Jellyfin-critical path
until a real 4:2:2 10-bit Rockchip workload is identified.
