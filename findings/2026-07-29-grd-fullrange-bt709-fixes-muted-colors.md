# Full-range BT.709 signaling fixes the muted GRD AVC colors after a clean reboot

> Scope: `apps/gnome-remote-desktop`, the packaged FFmpeg/RKMPP AVC path, and
> the Microsoft macOS RDP client
> Source: GNOME Remote Desktop
> `release/50.2-rkmpp@24f4392bb0daa40b9c411de1b1bcb9d0078e506a`;
> installed experiment
> `50.2+rkmpp+git20260721.13.cf60b4d+fullrange709-0ubuntu1~exp1`
> Date: 2026-07-29
> Trust: MEASURED, PACKAGE-VERIFIED, FIX-RUNTIME-VERIFIED

## Result

The clean post-reboot visual check closed the live boundary from the
[package experiment](2026-07-28-grd-avc-fullrange-bt709-handover-boundary.md):
with the experimental package active, the RDP client colors looked correct.
Changing only the FFmpeg encoder context from limited/unspecified signaling to
full-range BT.709 therefore fixes the muted client-visible colors for this
tested GRD → RKMPP → macOS RDP path.

This agrees with the source and bitstream evidence from the first experiment:
the AVC Vulkan shader already emits the full-range BT.709 conversion required
by MS-RDPEGFX, and `AVCOL_RANGE_JPEG` plus `AVCOL_SPC_BT709` survives through
FFmpeg/RKMPP into H.264 VUI metadata. The tested delta is promoted as
`release/50.2-rkmpp@24f4392` and package
`50.2+rkmpp+git20260729.14.24f4392-0ubuntu1~rk1`.

## Boundary

The result is a visual client verdict, not a colorimeter measurement. No
client-side screenshot, GRD runtime bitstream, or paired pixel-value capture
was preserved, so it does not quantify residual transfer-function, display
profile, or chroma-subsampling differences. It establishes the fix for the
tested macOS RDP path; other RDP clients still need confirmation.
