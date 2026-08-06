# rockchip-vaapi validation scorecard

This page owns accumulated validation conclusions for the RK3588 VA-API
bridge. It separates focused source/hardware/package evidence from the moving
fork, publication, installed, and browser verdicts owned by
[W18](../../../status.md#watch-w18), [W05](../../../status.md#watch-w05), and
[status track 14](../../../status.md).

## Evidence ladder

| Class | Positive signal | Boundary |
|-------|-----------------|----------|
| Source/model | Pinned code and codec/API contracts explain a route or refusal | No packet, surface, or hardware result |
| Unit/parser safety | Unit, sanitizer, thread, static, corpus, or fuzz gate passes | No real MPP/RGA/kernel interaction |
| Focused hardware | Named packet/surface path produces bounded exact output | Not an application, package, or broad matrix |
| Driver matrix | Required conformance, reference, geometry, determinism, fallback, and sanitizer cases pass | Exact package and consumer identity remain separate |
| Package artifact | Debian payload, metadata, dependencies, lifecycle, and extracted driver pass | The installed host may load another payload/configuration |
| Installed stack | Package payload identity and broad hardware/application gates pass on the booted board | Only the exercised CMA, kernel, sandbox, and display path |
| Consumer | A named application selects the driver and presents correct output | No transfer to other apps, sandboxes, codecs, or displays |

Do not promote a result merely because a version string or codec name matches.
Source, local package, archive package, extracted payload, installed payload,
and application-selected payload are different identities until directly
matched.

## Accumulated release evidence

| Evidence point | Trust and decisive signal | Durable conclusion | Boundary |
|----------------|---------------------------|--------------------|----------|
| Renovation review | Source-inspected original bridge, reconstruction shortcuts, lifetime, format, and failure policy | VA-to-MPP translation is viable, but stream reconstruction and asynchronous surface ownership are load-bearing | The [architecture guide](architecture.md) owns the repaired model; this is not a current fork-tip claim |
| Shipping-stack HEVC sweep | Exact Published MPP/FFmpeg payloads; 163 candidates produced 144 byte-exact passes, 17 classified skips, two intentional size refusals, and no driver/backend failures | Default H.264/VP9/HEVC Main decode and opt-in 10-bit paths have broad focused coverage | Installed-package, sandbox, and display proof are separate |
| Installed ysp8 matrix | Package/payload hash match; decode, encode, GStreamer, VLC, mpv, and Firefox gates; clean kernel interval | The installed bridge worked across the standard framework/app paths and five display codecs on the measured stack | Firefox RDD sandbox disabled, virtual display only, 256 MiB CMA, in-place install, risky VP9 vector guarded |
| Clean ysp9 RC and extracted payload | Source/package identity; normal plus complete ASan/UBSan matrices; exact package-payload replay; parser corpora and 20,000 fuzz executions per parser | The VP9 quarantine could retire and package installation/lifecycle mechanics were qualified | Packages were not installed; fresh-image 512 MiB CMA, sandboxed Firefox, physical HDR, and publication were not proved |
| ysp9 RGA discriminator | 30 decodes and 1,440 exact P010 frames; focused sanitizer run 240/240; clean journal | Small-geometry AFBC NV15-to-P010 conversion is a permanent forward-port regression gate | The rewrite driver's separately proven dropped destination write remains open |

The installed audit used `rockchip-vaapi{,-config}
1.0.11+ysp8-0ubuntu1~rk1`; the installed and extracted driver payloads both
hashed to `7fd9a7ba637f06e9bbbda90680adb8ada4d32ca831515a133cd637d31b59a732`.
The clean RC was `main@43c3c3501f14` packaged as
`1.0.11+ysp9-0ubuntu1~rk1`; its extracted driver payload hashed to
`01b624a7985ffbe9167eaf051aca363e6d914888901fdd414438a8a6542ddd69`.
These immutable identities bound the dated results; they do not claim to be the
current fork or archive payload.

The ysp8 run's optional IEP2 initialization warning was once harmless because
MPP fell back and the vector stayed exact. After IEP2 became available, the
separate [live interlaced finding](../../../findings/2026-08-04-vaapi-interlaced-decode-broken-by-iep2-enablement.md)
proved a real 1:N-versus-1:1 contract failure; it remains intake until that
current regression is resolved.

## Decode and conversion conclusions

| Path | Established result | Important boundary |
|------|--------------------|--------------------|
| H.264 | Reconstruction, multi-reference/B-frame cases, 4K, installed apps, and software comparison pass | Sandbox and presentation remain consumer gates |
| VP9 Profile 0 | Retained-output routing, five-run determinism, installed apps, and sanitizer matrix pass | Pre-decode surface identity still matters to Chrome |
| HEVC Main | Same-ID PPS, RPS/random-access fixes, broad sweep, installed apps, and default advertisement pass | MPP-native failures and oversize pictures still refuse |
| HEVC Main10 | MPP AFBC V2 NV15 plus crop metadata converts byte-exactly to P010; 240 visible frames measured 261.38 fps in the closure run | Width below 68 is permanently refused; physical HDR and sandbox proof remain separate |
| VP9 Profile 2 | P010 conversion, metadata, installed apps, and 240 visible / 254 converted frames at 261.08 fps pass | Physical HDR remains unproved |
| HEVC RPS | P010 storage/conversion was correct below the failure; missing-reference behavior belonged to MPP/FFmpeg and was repaired there | A clean conversion cannot repair an invalid or rejected codec reference state |
| VLC headless | Surface creation alone did not prove hardware decode; a real display session later passed | Headless failure before output can be device/display setup, not a driver verdict |

The terminal conversion invariant is `assigned + canceled == converted`, while
every requested visible frame must still be assigned. A focused early-stop
run reached one safe cancellation among 1,059 conversions, proving the
accounting branch without hiding missing presentation frames.

## Encode, import, and transport conclusions

| Contract | Measured result | Boundary |
|----------|-----------------|----------|
| H.264 VA encode | FFmpeg and GStreamer produced 48 parser-clean, software-decodable High-profile frames with the expected rate-control and metadata path | H.264 Main/High, NV12-family input; no B-frames, Main10, or packed slice headers |
| HEVC VA encode | Native RK3588 CTU64 geometry produced parser-clean software-decodable output | Main/NV12 only; visible and aligned dimensions must remain distinct |
| Dual H.264/HEVC soak | 7,200 seconds and 216,000 frames per codec; RSS and fd counts showed no growth | One board/package/kernel tuple |
| Planar upload | Checked I420/YV12 input is privately normalized to MPP NV12 under CPU ownership synchronization | It is a copy/normalization path, not zero-copy |
| PRIME 2 import | Linear two-object NV12 encoded 48/48 frames at 50.683977 dB normally and under full-driver sanitizers | Nonzero offsets, undersized objects, and non-linear modifiers fail closed |
| PRIME RGB import | Checked linear RGB DMA-BUFs cross RGA into NV12 encode input | Modifier-bearing/tiled input remains unsupported |
| Multi-slice | H.264 and HEVC emitted four parser-clean equal-row slices for all 12 frames in normal and sanitizer runs | Arbitrary slice maps are not supported |
| Same-process concurrency | Two decoders plus two encoders completed 120 frames per context under normal, sanitizer, and unsuppressed TSan gates | Not a multi-process resource-exhaustion result |
| WebRTC-shaped H.264 | 120 direct-I420 frames crossed SDP/ICE/DTLS/SRTP and decoded at 41.061795 dB | Transport compatibility, not browser WebRTC integration |

MPP cannot accept a client-authored slice header separately from the complete
slice NAL it emits. That makes packed-slice-header clients such as GRD a policy
wall rather than an unfinished driver feature. Likewise, shared RK3588
`vepu5xx` input tables reject the requested 10-bit encode format; silently
down-converting would violate the requested precision.

## Consumer and sandbox conclusions

| Consumer | Durable result | Boundary / route |
|----------|----------------|------------------|
| Firefox | H.264, HEVC Main, VP9, Main10, and Profile 2 ran through installed ysp8 in an isolated Mutter display; split P010 export reached Panfrost, where the chroma import needed Firefox's existing GR/RG retry | RDD needs both device-broker paths and ioctl policy; the measured broad run disabled the sandbox |
| VLC/mpv | Five installed decode/display cases passed, including P010 inputs | Virtual display; no physical HDR link or connector metadata |
| GStreamer/FFmpeg | Generic VA decode/encode paths passed and remain the framework-level interoperability baseline | Command-line success does not prove a desktop app selected the same path |
| Chromium 151 package | ANGLE/Panfrost initialized, but the installed arm64 binary exposed Hantro V4L2 VP8 and lacked the libva integration needed for this driver | Distribution backend selection, not a `rockchip-vaapi` defect |
| Google Chrome | Retained pre-decode storage is the stable-export contract; current install/automation/sandbox proof stays in the [live finding](../../../findings/2026-08-04-google-chrome-rockchip-vaapi-green-stable-export.md) | Status track 14 owns the moving verdict and next proof |
| Sunshine/OBS | Source contract is a strong match for opt-in H.264 VA encode | Unmeasured; [application sequencing](../../../docs/app-enablement.md#suggested-sequencing) owns priority |
| Archived ubuntu-rockchip Chromium bridge | Source/package survey proved a V4L2-stateful-over-MPP integration existed and supplied reusable packaging patterns | Archived external project; provenance, not a maintained binary or recommendation |

The Firefox source-package checkpoint proved that the distro source could carry
the narrow broker/seccomp and P010 retry patches, but source and compile gates
never implied an installed sandboxed playback result. The exact package source
identity is retained in [the source map](../../../docs/source-trees.md).

## Canonical operations and freshness

| Goal | Route |
|------|-------|
| Understand reconstruction, workers, surfaces, and failure policy | [Architecture](architecture.md) |
| Decide capability exposure and permanent walls | [Project policy](../README.md) |
| Choose or compare consumers | [Application map](../../../docs/app-enablement.md) |
| Run project-owned source, parser, matrix, package, and RGA gates | The external `rockchip-vaapi` tree named by [source reconstruction](../../../docs/source-trees.md) |
| Check intended package input | [PPA build owner](../../../packaging/ppa/README.md) |
| Check current public/package/browser state | [Status track 14](../../../status.md#next-gates), [W05](../../../status.md#watch-w05), [W18](../../../status.md#watch-w18) |

Update this scorecard when a result changes accumulated evidence or its
boundary. Keep a new unresolved experiment in a finding until promotion, and
do not copy moving fork, archive, installed, or browser state here.
