# rockchip-vaapi review: a working PoC VA-API-over-MPP driver exists; strategic architecture is right, two load-bearing shortcuts must be replaced; recommend fork-and-renovate

> Scope: full source review of woodyst/rockchip-vaapi v1.0.11 (~1,750 lines:
> `rockchip_drv_video.c`, `h264.c`, `bs.h`, docs, debian packaging), plus
> extension analysis for Chromium/desktop apps and the browser-sandbox
> gate structure for `/dev/mpp_service`-backed drivers
> Source: `github.com/woodyst/rockchip-vaapi@e8c64dd` (clone at
> `~/Code/rockchip-vaapi`); ioctl numbers cross-checked against
> [`../kernel-drivers/docs/dev-uapis.md`](../kernel-drivers/docs/dev-uapis.md)
> Date: 2026-07-21
> Trust: SOURCE-INSPECTED for everything stated about the driver code;
> INFERRED for app-portability judgments and effort estimates; UNVERIFIED
> (flagged inline) for Firefox/Chromium sandbox-internals claims, which are
> from model knowledge and need pinning against current browser sources
> before being baked into a plan

## Result

`rockchip-vaapi` (Eduardo García-Mádico Portabella / EGP Sistemas, LGPL-2.1,
written with Claude Sonnet 4.6 in a claimed 3–4 hours on 2026-04-24 and then
hardware-debugged through 12 commits to 2026-05-28) is the first known working
VA-API driver over MPP. It validates the exact bridge architecture the
[app enablement map](../docs/app-enablement.md) sketched — ignore VA's parsed
parameters, reconstruct bitstream, let MPP parse and manage the DPB, route
output frames by smuggling the `VASurfaceID` through packet PTS, export via
DRM PRIME 2 through libva's sanctioned plugin path. In its current state it is
a **Firefox-only, effectively H.264+VP9-only beta**; the README's
codec table oversells (HEVC is advertised but near-certainly non-functional).
Verdict: **fork and renovate rather than start from scratch or treat as
PoC-only** — the strategic architecture is the one we would choose anyway, the
scaffolding and app-contract knowledge are the expensive parts, and the two
wrong load-bearing decisions (per-frame CPU copy, polling sync) are
renovations within the same architecture, not reasons to greenfield.

## 1. What it is

Single-file libva backend implementing the VA-API 1.20 vtable
(`__vaDriverInit_1_20`) over `decode_put_packet`/`decode_get_frame`
(`src/rockchip_drv_video.c`, 1,577 lines), a 170-line hand-rolled Exp-Golomb
writer reconstructing H.264 SPS/PPS from `VAPictureParameterBufferH264`
(`src/h264.c`, `src/bs.h`), Debian packaging, two manual test harnesses, and
genuinely good developer docs. Deployed as `LIBVA_DRIVER_NAME=rockchip` — no
fake device nodes, no patched system libraries (the structural deployment
advantage over the libv4l-rkmpp bridge). Tested by the author on Orange Pi 5
Plus with Firefox 128+ (requires `MOZ_DISABLE_RDD_SANDBOX=1`). Development
timeline: v1.0.4 2026-04-26 → v1.0.11 2026-05-28, quiet since (bus factor 1,
no CI, not in any distro or the libva ecosystem).

## 2. Codec reality vs claims

| Codec | README claims | Code shows |
|---|---|---|
| H.264 | ≤4K, CB/Main/High/High10 | Works, with correctness caveats (§4.2) |
| VP9 Profile 0 | 8K | Works — raw frames need no reconstruction; the altref (`show_frame=0`) handling is real debugging (MPP never outputs hidden frames; driver detects them by parsing the uncompressed header and skips polling) |
| VP8 | — | Advertised, plausible (raw frames), no test evidence |
| HEVC | 8K Main/Main10 | **Near-certainly non-functional**: advertised in `rk_QueryConfigProfiles`, but `do_generic_decode` concatenates VA slice data with no VPS/SPS/PPS reconstruction and no start codes (the only start-code writer is in the H.264 path, `rockchip_drv_video.c:747`); `docs/DEVELOPMENT.md` admits HEVC reconstruction is pending |
| AV1 | 8K | Honestly not advertised at runtime, with the correct diagnosis: VA hands headerless tile data, MPP needs full OBUs |

Effective surface: **H.264 + VP9 in Firefox** — the YouTube case.

## 3. Strengths

1. **Existence proof of the right architecture**, through libva's sanctioned
   plugin path. The "months, from scratch" VA-API-bridge estimate is obsolete.
2. **Encoded app-contract knowledge** (the expensive-to-rediscover part):
   Firefox's `DMABufSurfaceYUV` separate-layer export layout (R8 + GR88; R16 +
   GR1616 for P010) vs the composed single-layer NV12/P010 layout for
   mpv/GStreamer; placeholder dmabufs so Firefox's pre-decode
   `ExportSurfaceHandle` capability probe succeeds; async `EndPicture` with
   sync-on-export because blocking 1.6 s on a 4K keyframe triggers
   `NS_ERROR_DOM_MEDIA_FATAL_ERR` at DASH segment boundaries.
3. **Honest failure analysis in docs**: the CMA-exhaustion section (MPP's DPB
   lives in CMA; 4K dies after ~70 frames with zero driver-side errors unless
   `cma=512M`) is directly relevant to our stack; AV1 parse failure vs CMA
   resource failure correctly distinguished.
4. Clean licensing, tiny and auditable (reviewed in full in one sitting),
   Debian packaging included.

## 4. Weaknesses

1. **The DPB/surface-ownership mismatch is "solved" by a full CPU memcpy of
   every decoded frame** into a per-surface private buffer
   (`assign_mpp_frame`), because exporting MPP's ~3-buffer internal pool
   directly let MPP overwrite frames the compositor was displaying. ~1.5 GB/s
   of memory traffic at 4K60; "zero-copy" is true only at the export seam.
2. **H.264 reconstruction is minimal**: the IQ-matrix buffer is ignored
   (`seq/pic_scaling_matrix_present_flag=0` — scaling-list streams drift),
   PPS `num_ref_idx_*_default` hardcoded to 0 (multi-reference-by-PPS-default
   streams corrupt; the dev doc admits this), `level_idc` forced to 5.1, no
   VUI. Fine for typical web H.264; not spec-honest.
3. **The 10-bit path is near-certainly wrong on stock MPP**: rkvdec2 emits
   compact NV15 (`MPP_FMT_YUV420SP_10BIT`), but the copy/export math treats
   10-bit as 2-bytes-per-sample P010 (`bpp=2`, R16/GR1616 layers) — a layout
   mismatch. This is exactly the NV15/P010 problem of
   [W13](../status.md#watch-w13) and kernel fixes `0048`/`0049`; the fix is
   RGA-backed NV15→P010 conversion (or requesting MPP output format change).
4. **Robustness at scale**: no locking on the global config/context/surface/
   buffer tables (concurrent decoders race `CreateBuffer`); sync is 1 ms
   `usleep` polling with 3 s deadlines; a hard 64-slices-per-frame cap
   *silently truncates* (per-row-slice encoders emit >64 at 4K); fixed pools
   of 8 contexts / 64 surfaces.
5. **The sandbox tax, confirmed**: needs `MOZ_DISABLE_RDD_SANDBOX=1` (§6).
6. **Compat surface is Firefox-shaped**: `vaDeriveImage` deliberately
   disabled, `vaGetImage` is a CPU copy, `DRM_PRIME_2` export only;
   mpv/ffmpeg *may* work via the composed-layers path (untested by author);
   GStreamer-VA and Chromium assuredly need the §5 hardening.

## 5. Architecture verdict: fork-and-renovate

Three layers, three verdicts:

- **Strategic architecture (VA → reconstruct → MPP-stateful → PTS routing →
  PRIME export): keep.** It is the design we sketched independently; a
  from-scratch driver converges on the same shape.
- **Two load-bearing implementation decisions: replace.**
  (a) *Buffer model*: invert ownership — external/committed MPP buffer group
  sized for DPB + display pipeline, keep each output `MppFrame` alive
  (holding its buffer ref) until the app releases the surface, let the
  exported fd change per frame. libv4l-rkmpp demonstrates this exact model
  working over MPP. Preserve the Firefox pre-decode-probe placeholder
  behavior through the redesign. Touches ~⅓ of the driver.
  (b) *Sync model*: per-context drain thread on MPP blocking/timeout output
  + per-surface condvars, replacing the polling loops; add driver-wide
  locking. Structurally compatible surgery, not amputation.
- **Worth inheriting**: the ~700 lines of vtable scaffolding/stubs, the ID
  object model (once locked), `h264.c`/`bs.h` (right method, needs §4.2
  fixes), the VP9/altref path, the export descriptor code, and all §3.2
  contract knowledge.

Why not greenfield: everything a from-scratch effort produces in month one
already exists here, including five weeks of on-hardware app-contract
debugging; the two replacements fit inside the same architecture; the
abandoned upstream means we simply own the fork (LGPL keeps it clean).
Why not PoC-only: that undersells it, but it *is* the correct phase zero
(§7). Renovation ledger to a solid H.264+HEVC+VP9 Firefox+mpv-grade driver
(INFERRED): buffer-model surgery 1–2 wk; drain-thread sync + locking ~1 wk;
HEVC VPS/SPS/PPS writer 1–2 wk (unlike H.264, HEVC scaling lists *are* in the
VA buffers, so it can be spec-honest); H.264 correctness fixes days; 10-bit
via RGA ~1 wk leaning on W13 work. AV1 descoped (frame-header OBU
reconstruction is the one genuinely hard codec; VP9 covers the content).
Total ~4–8 weeks vs roughly double from scratch. Caveat: this verdict is
code-inspection-based; if the phase-zero board test exposes something
structurally rotten (e.g. PTS→frame mapping not holding on our MPP build),
revert to PoC-only.

## 6. Extension reach: Chromium and the desktop

**Chromium: yes — it is the point of the VA-API road.** `VaapiVideoDecoder`
ships in stock desktop builds behind runtime flags (`VaapiVideoDecodeLinuxGpu`
family + `VaapiIgnoreDriverChecks`; names drift by milestone — UNVERIFIED).
No Chromium patches or custom builds for the basic path, unlike the
libv4l-rkmpp road. Two taxes: the sandbox (below), and a conformance tax —
Chromium runs multiple concurrent in-process decoders (locking mandatory),
recycles surfaces aggressively, expects honest sync semantics, probes driver
strings against blocklists. The §5 renovation items are prerequisites, then
a 1–3 week Chromium hardening pass. Electron apps inherit it (per-app flag
glue needed).

**Also unlocked by a working VA driver** (all needing the same display-path
and 10-bit caveats): VLC (stock libavcodec-hwaccel + `hw/vaapi` GL interop —
flips from "nobody has solved it" to nearly free; its CPU fallbacks route via
`vaGetImage` since `vaDeriveImage` is disabled); mpv and derivatives
(`--hwdec=vaapi` first-class, no forked ffmpeg needed player-side); the
GStreamer `va` plugin world (Totem, Clapper, WebKitGTK/Epiphany) without the
gstreamer-rockchip rank-hijack question; **stock distro FFmpeg**
(`-hwaccel vaapi` in Ubuntu's own ffmpeg — the `+rkmpp` fork stops being a
hard dependency for third-party apps and remains the encode/filter/CLI
powerhouse); Kodi's VAAPI path on desktop sessions (complementary to the GBM
DRMPRIME tty1 track); OBS decode side. **Not unlocked**: encode — the driver
is decode-only; `VAEntrypointEncSlice` over MPP's encoder is a coherent
phase-2 (smaller impedance mismatch than decode), which would light up
GStreamer `vah264enc`, ffmpeg vaapi encode, and Chromium WebRTC send.

## 7. The sandbox gate structure (and whether path aliasing sidesteps it)

Device access is granted by **major:minor, not path**, so mknod'ing (or
bind-mounting; not symlinking — brokers may refuse symlinks) real alias nodes
under an allowed directory (`/dev/dri/`) defeats **pathname**-based checks.
Normal DAC still applies (group `video` as today). But there are four gates:

1. **File-broker/AppArmor pathname check** — defeated by aliasing (udev RUN
   script or systemd unit; same pattern as ubuntu-rockchip's created nodes,
   and ChromeOS ships codec nodes at broker-blessed paths).
2. **librockchip_mpp's hardcoded paths** — MPP opens `/dev/mpp_service` and
   `/dev/dma_heap/*` as literal strings; aliases need a small env-override
   patch in our MPP package (we ship it; trivial).
3. **seccomp ioctl request-number filtering** — the path cannot disguise the
   ioctl magic. `MPP_IOC_CFG_V1` = `_IOW('v',1,…)` = `0x40047601`
   ([dev-uapis.md](../kernel-drivers/docs/dev-uapis.md) §top-level ioctl);
   dma-heap alloc is magic `'H'`; DRM is `'d'`. **Firefox RDD filters ioctls
   by request family** (DRM whitelisted for VA-API-in-RDD; `'v'`/`'H'` not) →
   SIGSYS regardless of how the fd was opened; aliasing cannot fix Firefox —
   that needs a small `SandboxFilter.cpp` whitelist patch or
   `MOZ_DISABLE_RDD_SANDBOX` (likely the real reason the author needed it).
   **Chromium's GPU-process policy allows `ioctl` without argument
   inspection** (it needs the vendor-DRM ioctl zoo) → for deb/flatpak
   Chromium, aliasing + the MPP path patch is plausibly a complete
   zero-browser-patch sidestep. Both browser claims are UNVERIFIED against
   current sources — pin `SandboxFilter.cpp` / `bpf_gpu_policy_linux.cc`
   before planning on them; the alias experiment is self-verifying (decodes
   or SIGSYSes, and the crash signature names the gate).
4. **major:minor-based confinement** — snap Chromium (Ubuntu's default) adds
   a snapd device-cgroup filtered by major:minor via udev tags, which
   aliasing preserves → needs a udev tagging accommodation (fragile against
   snapd's generated rules). Flatpak `--device=dri` bind-mounts host
   `/dev/dri` (aliases appear inside) and does not arg-filter ioctls, but
   Firefox flatpaks still carry the inner RDD seccomp (gate 3).

Security honesty: alias, env var, or policy patch produce the identical end
state — a semi-trusted media process gains ioctl access to
`/dev/mpp_service`, which the
[BSP driver-quality finding](2026-07-16-rockchip-bsp-driver-quality.md)
classifies as a security boundary with below-mainline hostile-input
hardening. The mechanisms differ in auditability, not exposure; a policy
patch states the decision reviewably. This is also the strongest long-term
argument for the maxline/kernel-V4L2 road, where `/dev/video*` is already in
every sandbox allowlist.

## 8. Recommended probe order (phase zero, before any fork work)

1. Build v1.0.11 unmodified against our stack; point Firefox at it on the
   6.18 board with `MOZ_DISABLE_RDD_SANDBOX=1` (H.264 + VP9/YouTube smoke).
   ~1 day; also validates vendor-MPP behavior parity with the author's
   Orange Pi setup and gives a regression baseline for the renovation.
2. mpv `--hwdec=vaapi` against it (first non-Firefox client; tests the
   composed-layers export path).
3. deb-Chromium alias experiment: udev aliases under `/dev/dri/` + MPP
   path-override patch + VA flags (tests gate 3's Chromium half for free).
4. Green results here are the runtime evidence that would justify a status
   track and the fork decision; a structural failure reverts the verdict to
   PoC-only.

## Local artifacts

- Clone: `~/Code/rockchip-vaapi@e8c64dd` (v1.0.11, upstream quiet since
  2026-05-28).
- This finding supersedes the "no VA-API driver over MPP exists anywhere"
  claim in the [app enablement map](../docs/app-enablement.md) (corrected
  same day) and in the
  [ubuntu-rockchip survey](2026-07-21-ubuntu-rockchip-piggyback-survey.md)
  (left as written; its bridge comparison table remains valid — the
  "months, per-codec" bridge-side estimate now has a concrete head start).
