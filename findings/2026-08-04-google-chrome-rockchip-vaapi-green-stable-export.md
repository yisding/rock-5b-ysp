# Installed ysp13 fixes Google Chrome's green H.264; VP9 selects VA-API above Chromium's software cutoff

> Scope: supersede the assumption that every Chromium-family arm64 package on
> this host lacks libva, root-cause Google Chrome 151's entirely green Vimeo
> playback after it selected `VaapiVideoDecoder`, record the source fix and its
> hardware proof, and close the installed-driver browser replay with H.264 and
> VP9 decoder-selection evidence.
> Source: Google Chrome 151 GPU report
> [`evidence/2026-08-04-chromium-151-gpu/`](evidence/2026-08-04-chromium-151-gpu/README.md),
> SHA-256 `2df477cf3281fd39a846019b2734c76623845c6d37f79ba2439eb5c58b50ce2a`;
> operator-provided `chrome://media-internals` records preserved in
> [`media-internals-operator-records-2026-08-05.txt`](evidence/2026-08-04-chromium-151-gpu/media-internals-operator-records-2026-08-05.txt);
> live GPU-process sandbox probe preserved in
> [`gpu-process-sandbox-probe-2026-08-05.txt`](evidence/2026-08-04-chromium-151-gpu/gpu-process-sandbox-probe-2026-08-05.txt);
> installed package database and payload hash; Chromium
> [`VaapiVideoDecoder::AllocateCustomFrame`](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/media/gpu/vaapi/vaapi_video_decoder.cc)
> and
> [`ExportVASurfaceAsNativePixmapDmaBuf`](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/media/gpu/vaapi/vaapi_wrapper.cc);
> Chromium
> [`DecoderSelector`](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/media/filters/decoder_selector.cc);
> `rockchip-vaapi main@184d7d4` plus the local `ysp13` UNRELEASED fix.
> Date: 2026-08-04–05 local / 2026-08-05 UTC artifacts and replay
> Trust: **MEASURED** (GPU enumeration, live process allocation inspection,
> installed package/payload identity, and hardware decoder gates) +
> **USER-REPORTED** (green-before/correct-after H.264 presentation and the
> copied media-internals selections) + **SOURCE-INSPECTED** (Chromium surface
> lifetime and decoder priority, plus driver lifetime) + **ROOT-CAUSED** +
> **FIX-RUNTIME-VERIFIED** (exact worker lifetime and installed Chrome H.264)

## Result

Google Chrome and the installed XtraDeb Chromium are different backend builds.
Chrome `151.0.7922.75` loads `rockchip-vaapi` and reports the driver's default
decode profiles:

| Profile | Exported range |
|---------|----------------|
| H.264 Main | 16x16 through 8192x8192 |
| H.264 High | 16x16 through 8192x8192 |
| VP9 Profile 0 | 16x16 through 8192x8192 |
| HEVC Main | 16x16 through 8192x8192 |
| HEVC Main still picture | 16x16 through 8192x8192 |

The earlier XtraDeb Chromium finding remains valid for that binary: it exposes
only Hantro V4L2 VP8 and omits libva. It is not a universal Chromium-family
limit.

On Vimeo, Chrome selected the correct hardware decoder for an unencrypted
1920x1080 H.264 High Level 4.2 stream with BT.709 limited-range color, but the
picture was entirely green. The operator-provided selection record was:

```text
Selected VaapiVideoDecoder for video decoding, config: codec: h264,
profile: h264 high, level: 42, coded size: [1920,1080]
```

The decoder and MPP path were active. The green frame was an all-zero NV12
surface-lifetime failure after decode, not codec selection, colorimetry, or an
8-bit format conversion error.

That symptom is now resolved with the installed ysp13 packages. The operator
reports correct H.264 playback in Google Chrome after installation. Chrome also
selects `VaapiVideoDecoder` for an unencrypted 640x480 VP9 Profile 0 source.

## Root cause: Chromium retains the export made before decode

Chromium allocates a driver-owned VA surface, immediately synchronizes and
exports it as a read-only separate-layer DMA-BUF, imports that object into a
NativePixmap, and retains the pixmap for later decoded pictures. At export
time this driver had not decoded anything, so it returned the conservative
zeroed `priv_buf` placeholder.

The old driver then changed which allocation represented the VA surface:

```text
surface creation
  -> zeroed priv_buf
  -> Chrome exports/imports priv_buf into a persistent NativePixmap
  -> MPP decodes into an external-pool buffer
  -> driver sets backing_buf/frame as the active VA storage
  -> later VA exports would see MPP output
  -> Chrome keeps presenting the original unchanged priv_buf
  -> all-zero NV12 appears green
```

Live inspection of Chrome's GPU process matched this model: PID 316845 held the
exact 1920x1080 conservative placeholder allocation (5,013,504 bytes) while MPP
owned separate output buffers. `/dev/mpp_service` was active and no matching
kernel decode fault explained the presentation.

Chromium's contract is reasonable: an exported handle retained for a VA
surface must continue to represent that surface's later contents. Re-exporting
a different object after decode cannot update a NativePixmap the application
already created.

## The fix

The first export of an empty, driver-owned decode surface now marks its
`priv_buf` as stable external storage. Each completed picture is copied into
that same allocation under the surface lock and generation fence before the
surface is signaled:

- linear NV12 uses the existing checked RGA repack;
- converted P010 uses synchronized CPU row copies;
- driver-owned NV12 placeholders use a 64-byte-aligned pitch from creation, so
  a retained CIF-sized allocation is also Panfrost-importable; and
- consumers that first export after decode still receive the retained MPP
  external-pool buffer directly, preserving the ordinary zero-copy path.

The P010 path is included because this is an export-lifetime contract, not an
NV12-only color bug. A focused on-device test found that RGA returned success
for P010-to-P010 but left the destination all zero, so the fix does not trust
that operation. HEVC Main10 and VP9 Profile 2 remain opt-in, but their retained
pre-decode exports now have defined behavior rather than the same stale-buffer
failure.

Imported decode surfaces are already address-stable. Encoder inputs have a
different ownership path. Neither needs this fallback.

## Verification

The source worktree passes:

| Gate | Result |
|------|--------|
| `make check-stable-export-decode` | 24 lossless 352x288 VP9 pictures decoded through eight DMA-BUFs exported and retained before decode; every luma sample correct across surface reuse; 24/24 stable-copy log records |
| `make check-driver-objects` | NV12 and P010 patterned copies byte-exact; pre/post export object identity and plane layout unchanged |
| `make check-driver-objects-sanitize` | Same lifecycle under ASan/UBSan, clean |
| `make check-zero-copy` with `/usr/bin/ffmpeg` | 12 contexts and 1,440 ordinary H.264/VP9 frames remain external-pool zero-copy |
| `make check-conformance` | All 17 pinned cases green |
| `make test`, `make lint`, `git diff --check` | Clean |
| `make package` plus Lintian | Driver, config and dbgsym packages built; Lintian emitted no findings |
| Host package state | `rockchip-vaapi` and `rockchip-vaapi-config` `1.0.11+ysp13-0ubuntu1~rk1` both registered `ii`; installed driver and deb payload share SHA-256 `ed578a241803f35f51ccc6afe38b1d132539ae48ca691b5a3180e37565fe56c0` |
| Google Chrome H.264 replay | **USER-REPORTED PASS**: H.264 renders correctly instead of green after installing ysp13 |
| Google Chrome VP9, 384x240 | `VpxVideoDecoder`, matching Chromium's below-360p software preference |
| Google Chrome VP9, 640x480 | `VaapiVideoDecoder`, Profile 0, unencrypted |
| Stock Chrome GPU sandbox | **OPEN**: no operator sandbox-disabling flags, but `chrome://gpu` says `Sandboxed: false`; live GPU PID reports `NoNewPrivs: 1`, zero effective capabilities, `Seccomp: 0`, zero seccomp filters, and `LSM: unconfined` |

The 352x288 width is deliberate. MPP's VP9 layout can be 768 bytes wide while
the persistent public NV12 object is 384-byte aligned, exercising real
repacking rather than an equal-stride memcpy.

The locally built binary artifacts are unsigned and came from a changelog
stanza whose distribution remains `UNRELEASED`:

| Artifact | SHA-256 |
|----------|----------|
| `rockchip-vaapi_1.0.11+ysp13-0ubuntu1~rk1_arm64.deb` | `09f8677d7d310a7567523c61966f768fc72635bdd838313c3e8ffb0dbd6b59a8` |
| `rockchip-vaapi-config_1.0.11+ysp13-0ubuntu1~rk1_all.deb` | `8e5a08255fb1a28325adce67892223f10fbd78be70b86cd67a1355688cb20685` |
| `rockchip-vaapi-dbgsym_1.0.11+ysp13-0ubuntu1~rk1_arm64.ddeb` | `573d94a09bfb68ffd188061c3ccf54e6f969d5fd2f367a9ab0c95754ebb66f7c` |

## VP9 software at 240p is selection policy, not fallback

The first VP9 probe selected `VpxVideoDecoder` at 384x240. That initially looked
like a VP9-specific block, but the driver was already advertised for VP9
Profile 0 from 16x16 through 8192x8192. Chromium's decoder selector prefers
software below 360 pixels of visible height and platform decoders at or above
that cutoff when resolution-based selection applies. A second 640x480 Profile
0 source selected `VaapiVideoDecoder`, exactly discriminating policy from an
initialization failure.

The VP9 records carry no level and mark primaries/transfer/matrix `INVALID`.
Those fields describe absent stream metadata; they did not prevent hardware
selection at 640x480.

## Stock launch does not close the GPU-sandbox gate

The working browser is Google Chrome's directly downloaded deb launched
without extra options. The exported browser command line contains neither
`--no-sandbox` nor `--disable-gpu-sandbox`, and the live GPU child command line
contains neither switch. This closes the user-configuration hypothesis: the
operator did not weaken the sandbox to make VA-API work.

It does not prove sandboxed decoding. Chrome reports `Sandboxed: false`, and a
live read of the GPU process records `Seccomp: 0`, `Seccomp_filters: 0`, and an
unconfined LSM label. `NoNewPrivs: 1` and `CapEff: 0` provide partial process
hardening but are not Chrome's syscall sandbox.

The GPU log contains `InitializeSandbox() called with multiple threads in
process gpu-process`. This is a useful discriminator for the next audit, not a
root cause yet. The extra thread could arise in Chrome itself, ANGLE/Mesa,
libva initialization, or the MPP/RGA dependency stack; the current evidence
does not attribute it.

## Boundary and next gate

- The fix remains uncommitted and unpublished in the dirty local driver
  worktree, whose changelog still labels `1.0.11+ysp13-0ubuntu1~rk1`
  **UNRELEASED**. The binary packages were nevertheless built and installed on
  this host; the driver deb has SHA-256
  `09f8677d7d310a7567523c61966f768fc72635bdd838313c3e8ffb0dbd6b59a8`.
- The worker reproducer validates Chromium's exact pre-export/retain/reuse
  lifetime, and the installed Chrome H.264 replay now supplies visual evidence.
  Browser stable-copy markers were not captured during that manual replay, so
  they remain a requirement for an automated browser gate.
- Google Chrome's GPU process remains unsandboxed even under a stock launch
  without sandbox-disabling flags. A correct picture does not close the
  broker/seccomp deployment gate; the ownership is now narrowed to default
  process initialization rather than operator configuration.
- VP9 hardware selection is confirmed at 640x480; a pixel-checked or explicit
  operator visual verdict for that VP9 source was not separately recorded.
- Next, automate H.264 and VP9 browser playback with decoder selection,
  stable-copy markers, visible-output checking and no fallback/display errors,
  then identify which initialization step precedes the multiple-thread sandbox
  warning and qualify the GPU sandbox. HEVC browser playback also remains
  untested.
