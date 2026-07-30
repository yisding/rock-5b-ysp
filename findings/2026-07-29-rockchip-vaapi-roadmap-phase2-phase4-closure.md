# rockchip-vaapi closes 10-bit throughput and the remaining Phase 4 qualification slices, while Firefox Main10 stops at Panfrost EGL import

> Scope: `rockchip-vaapi` Phase 2 10-bit decode qualification, Phase 3
> display consumers, Phase 4 encode/import/concurrency qualification, and the
> Firefox/Panfrost P010 boundary.
>
> Source: `/home/yi/Code/rock-5b/rockchip-vaapi` `main@5d558fa` (the roadmap change is
> `3c6f43c`, followed by two Debian source-package fixes); the measured gates
> named below;
> Firefox 153.0 runtime logs; exact official
> `FIREFOX_152_0_6_RELEASE`/`FIREFOX_153_0_RELEASE`
> `widget/gtk/DMABufSurface.cpp` preimages; the preserved Ubuntu Firefox
> 152.0.6 package tree; and the exact signed 153.0 Mozilla Team package tree
> under `/home/yi/Code/rock-5b/firefox-rdd-build`.
>
> Runtime: ROCK 5B on `6.18.40-ysp-rockchip64`, installed
> `librockchip-mpp1 1.5.0+git20260727.d8c6b88a+ds-0ubuntu1~rk1`,
> `librga2 2.2.0+git20260725.26a50ef`, and FFmpeg
> `7:8.0.3+rockchip+git20260719.da5befc806-0ubuntu1~rk1`. The newer MPP
> `3381fd2c` and FFmpeg `33a651a55b` source/binary publications are already
> successful in the normal PPA but were **not installed for these runs**.
>
> Date: 2026-07-29
>
> Trust: **MEASURED** / **SOURCE-INSPECTED** / **COMPILE-VERIFIED** /
> **PARTIAL** (Firefox package/runtime, physical HDR output, Chromium, host
> package installation, and release remain open).

## Result

The roadmap no longer has open questions for 1080p 10-bit throughput,
linear two-object YUV import, equal-row multi-slice encode, same-process
decoder/encoder concurrency, WebRTC peer transport, or the two-hour encode
soak.

| Gate | Measured result |
|---|---|
| HEVC Main10 throughput | 240 visible/decoded 1920×1080 frames at **261.38 fps**, with exactly 240 AFBC NV15→P010 conversions |
| VP9 Profile 2 throughput | 240 visible and 254 decoded/reference outputs at **261.08 fps**, with 254 conversions and assignments |
| Linear two-object NV12 encode import | 48/48 H.264 High frames at **50.683977 dB**, normal and full-driver ASan/UBSan |
| Equal-row multi-slice | H.264 and HEVC each produced 12 frames with exactly four parser-clean slices per frame, normal and ASan/UBSan |
| Same-process concurrency | Two decoders plus two encoders completed 120 frames/context; normal, ASan/UBSan, and unsuppressed TSan gates pass |
| Native WebRTC peer | 120 direct-I420 `vah264enc` frames traversed SDP/ICE/DTLS/SRTP and decoded at **41.061795 dB**, normal and ASan/UBSan |
| Dual-codec encode soak | **7,200 seconds**, 216,000 frames/codec; RSS 56,328→52,708 KiB, 3,620 KiB span and no growth; fds 60→60 |
| Exact-PPA decode soak | **7,200 seconds**, 216,005 external 4K frames through checksum-verified Published MPP/FFmpeg packages; RSS 169,248→139,776 KiB, 53,592 KiB transient span and no growth; fd medians 57→54 |

Two-object imports are deliberately linear and canonical. Separate luma and
chroma object sizes, zero offsets, pitches, modifiers, and owned-fd lifetime
are validated independently. The driver normalizes the input privately under
DMA-BUF CPU synchronization and re-exports an accurate two-object descriptor.
The object gate covers P010 too and rejects undersized objects, nonzero plane
offsets, and non-linear modifiers. Tiled/modifier-bearing import remains
unsupported and fails at surface creation.

Multi-slice support is equally narrow: contiguous full macroblock/CTU rows,
equal non-final heights, a permitted smaller final remainder, and complete
picture coverage. It does not reopen arbitrary slice maps or claim B-frame,
packed-header, or Main10 encode support. P010 encode remains blocked below the
driver because RK3588 MPP `vepu5xx` rejects compact format id 1.

## Display-consumer result

Stock VLC 3.0.23 now hardware-decodes and presents all three generated cases:
118 H.264 High frames, 120 HEVC Main frames, and 120 HEVC Main10 frames.
Allowing an aligned provisional P010 `vaDeriveImage` is required for VLC's
converter setup; imported, stale, compressed, and unaligned provisional P010
layouts still fail closed.

Stock Firefox 153.0 completes H.264 and HEVC Main hardware decode. Main10
reaches only three external frames before software fallback. The logs locate
the boundary precisely:

1. `rockchip-vaapi` exports a standards-correct split P010 DMA-BUF descriptor:
   `R16` luma and `GR1616` interleaved chroma, linear modifier, 1280×720
   visible geometry, 2,560-byte pitch, 736-row backing.
2. Firefox creates the luma `R16` EGL image successfully.
3. Panfrost rejects the chroma `GR1616` `eglCreateImage` with
   `EGL_BAD_MATCH`.
4. Firefox reports `CreateImageVAAPI(): failed to get VideoFrameSurface`,
   disables VA-API, and restarts with software decode. The driver records no
   decode, conversion, export, or layout error.

Changing the VA descriptor to claim `RG1616` would make the producer contract
false. The fix therefore belongs in the Firefox consumer: retain GR1616 as the
first attempt, then retry Firefox's existing RG/GR alternative only if real
EGL image creation fails.

Version-specific patches for Firefox 152.0.6 and 153.0 implement that retry.
The validator pins all three affected official source preimages per version,
applies both the RDD sandbox and P010 patches, and verifies the retry contract.
Both exact-source application gates pass. The patched Firefox 152.0.6
`Unified_cpp_widget_gtk0.o` also compiles under the Ubuntu package's release
flags. The exact signed 153.0 source package (`.dsc` SHA-256
`5fb63a47f969bc97479bf19abecc4d8d790ad2bcb1d3e7b2adde26248d50c8ed`)
has both byte-matched patches quilt-applied as local `~mt1+ysp1`; its native
arm64 package build is in progress. A full binary package and sandbox-enabled
Main10 playback result do not yet exist, so source/compile evidence is not
promoted to runtime evidence.

## Remaining release boundary

- The exact Published MPP
  `1.5.0+git20260729.3381fd2c+ds-0ubuntu1~rk1` and FFmpeg
  `7:8.0.3+rockchip+git20260729.33a651a55b-0ubuntu1~rk1` runtime debs were
  checksum-verified from the live PPA and exercised from an isolated package
  root. The complete 163-vector HEVC sweep passes with 144 byte-exact, 17
  classified skips, two size refusals, and zero driver/backend failures; the
  full normal and ASan/UBSan shipping matrices are green. A repaired
  7,200-second 4K soak completed 216,005 external frames with no RSS or fd
  growth. Install those exact packages through APT and confirm the installed
  payload/runtime identity to close the remaining system-package lifecycle
  gate.
- Finish and install the patched Firefox package, then prove H.264, HEVC Main,
  and Main10 with the RDD sandbox enabled.
- Rerun mpv Main10/HDR in a session with a real Wayland `wl_output`; the
  current GNOME session exposes neither a physical connector nor a usable
  Wayland/Xwayland output. Mutter's read-only `GetCurrentState` returns empty
  physical-monitor and logical-monitor arrays, confirming this is an output
  boundary rather than an mpv/VA decode result.
- Chromium 150 remains blocked before VA-API by ANGLE's failure to create a
  Mali-G610/Panfrost GL context.
- Final driver/config version `1.0.11+ysp6-0ubuntu1~rk1` builds and passes
  binary/source Lintian error gates plus the isolated clean
  install/upgrade/purge lifecycle. Its signed source package is exact to
  `main@5d558fa`. The signed `.dsc` and source `.changes` SHA-256 values are
  `a5abacc7db68b33b13c70eb2906ad41e03a192e9e9faa3509b73939481bf19e2`
  and
  `411f20048a0ad5fdb98023a13ae98424ad5ceb8eaa2da75d252e94834d4ac240`;
  the driver/config debs are
  `c397efc99dbe7253153f3f44c35953f5a862007a9136d1248d4f0915640554ed`
  and
  `6f4c393388710347631befbeb5ea510aab2f8f64fe2c0a74380e928216d6766c`.
  Host installation, PPA upload, physical HDR-monitor
  passthrough, genuinely clean-image hardware decode, and release publication
  remain open.

This finding supersedes the open-item portions of the 2026-07-26 dual-codec
soak smoke and the 2026-07-28 app-matrix checkpoint. Their measured historical
results remain valid within their stated scope.
