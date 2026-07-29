# Upstreaming decisions — rockchip-vaapi

This package holds the maintained `yisding/rockchip-vaapi` fork — the libva
backend that translates desktop VA-API decode/encode requests into Rockchip
MPP/RGA operations — and this file is its upstream submission disposition as
decided on 2026-07-29; cross-package ordering and coupling constraints live in
the central [upstreaming ledger](../../docs/upstreaming-ledger.md). Dated
claims below (upstream commit state, gate results, package versions) must be
re-verified against a fresh fetch or install before anyone acts on them.

## Decision list

| ID | Item | Artifact | Upstream target | Decision | Priority | Gates / prerequisites |
|----|------|----------|------------------|----------|----------|------------------------|
| VA-1 | Declare yisding/rockchip-vaapi the maintained successor to the dormant woodyst/rockchip-vaapi | Issue on the upstream repo announcing the fork, capability delta and evidence map, plus a lineage/attribution notice on the fork's README and first tagged release | woodyst/rockchip-vaapi (GitHub issue), lineage notice in yisding/rockchip-vaapi | SUBMIT-NOW | P2 | — |
| VA-2 | Offer the whole Phase 0/1/2/4 renovation back to woodyst/rockchip-vaapi as a pull request | Full delta `e8c64dd`→`491533e`: generation-tagged objects, zero-copy pool retention, worker/fence sync, HEVC/VP9 reconstruction, Main10 AFBC->P010, H.264/HEVC encode, vaDeriveImage/vaAcquireBufferHandle, conformance/sanitizer/fuzz gates, Debian packaging | woodyst/rockchip-vaapi (GitHub PR) | NEVER | P3 | — |
| VA-3 | Firefox RDD sandbox: broker paths and seccomp ioctl requests for Rockchip MPP/RGA/dma-heap | Source-hash-pinned patch to `SandboxBrokerPolicyFactory.cpp` and `SandboxFilter.cpp`, held as `contrib/firefox/patches/firefox-{152.0.6,153.0}-rdd-rockchip-vaapi.patch` | Mozilla Firefox (Bugzilla / Phabricator) | SUBMIT-AFTER-GATE | P1 | Finish the paused arm64 Firefox 153.0 package build and inspect patch/version provenance; prove live hardware decode in a real session with the RDD sandbox enabled; re-measure the ioctl request set against the patched 153.0 build; VA-1 must land first so the driver is publicly identifiable |
| VA-4 | Carry the Rockchip RDD sandbox patch in the distro Firefox package for arm64 | `debian/patches/rockchip-rdd-vaapi.patch` plus `series` entry, applied against `firefox 152.0.6+build1-0ubuntu0.26.04.1~mt1` | Ubuntu firefox source package (Launchpad) / mozillateam PPA | HOLD | P3 | VA-3 accepted or landed in Mozilla; the same sandboxed runtime proof VA-3 needs, plus a decision on whether the arm64 deb channel is a supported delivery path |
| VA-5 | Let GStreamer's va plugin register the Rockchip VA driver without GST_VA_ALL_DRIVERS=1 | Change to the gst-plugins-bad `va` plugin vendor gate, backed by measured byte-exact readback results | gst-plugins-bad `va` plugin (GitLab MR) | HOLD | P3 | VA-1 plus an actual published, installable driver release; confirm the exact upstream allowlist mechanism in current sources before writing the MR; the DMABUF display negotiation path remains unproven |
| VA-6 | Chromium cannot create a GL context on Mali-G610/Panfrost, so no VA-API path is reachable | Bug report: Chromium 150 fails GL init under X11 and Wayland while VLC/Firefox run accelerated GL in the same session | Chromium (crbug.com) or Mesa/Panfrost (freedesktop GitLab) — target chosen after triage | HOLD | P3 | Triage which side owns the failure (ANGLE/`chrome://gpu` diagnostics, Mesa/Panfrost version, backend/flag variation); check whether current upstream Mesa or Chromium already fixes it before filing |
| VA-8 | VLC VA-API hardware-decoder fallback on Rockchip — do not report as a VLC bug | Would have been a VideoLAN bug report that VLC drops its `vaapi` decoder module on this stack; falsified | VideoLAN VLC (GitLab issue) — not filed | NEVER | P3 | — |

## Rationale and evidence

### VA-1 — Declare yisding/rockchip-vaapi the maintained successor

This is the only upstream action the dead-upstream situation supports, and it
is the prerequisite that lets every other external target (Mozilla,
GStreamer, distro packaging) answer where the driver comes from and who
maintains it. Upstream `woodyst/rockchip-vaapi@e8c64dd` is unmoved since
2026-05-28 and was rechecked 2026-07-28, with bus factor 1, no CI, and no
distro or libva-ecosystem presence; the fork is 651 files / 20,559
insertions / 1,496 deletions ahead, i.e. a rewrite rather than a patch set.
Every decode gate was re-run 2026-07-28 on the production-shaped
`6.18.40-ysp-rockchip64` kernel with 142/163 FATE HEVC Main vectors
byte-exact and zero driver failures, and stock VLC 3.0.23 and Firefox 153.0
hardware-decoding; the announcement must state the caveat that the shipping
deb (`1.0.11+ysp5` as of 2026-07-29, packaging the pinned `491533e` source)
and the exact provenance of the 2026-07-28 gates against that installed
driver should be re-checked before repeating any staler caveat text.

- Evidence: [status.md](../../status.md), [README.md](README.md), [findings/2026-07-21-rockchip-vaapi-driver-review.md](../../findings/2026-07-21-rockchip-vaapi-driver-review.md), [findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md](../../findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md), [docs/source-trees.md](../../docs/source-trees.md), [packaging/userspace-patches.md](../../packaging/userspace-patches.md)
- Coupled with: VA-2, VA-3, VA-5

### VA-2 — Offer the whole renovation back as a pull request

A PR is the wrong instrument for this delta against this repository. The
diff replaces the two load-bearing designs the 2026-07-21 review condemned
(per-frame CPU copy, polling sync) rather than amending them, so there is no
reviewable decomposition into a single thread, and the sole upstream author
has been unresponsive since 2026-05-28 with no CI to validate a merge
against. The individual defect fixes inside it (buffer caps, teardown races,
pool sizing, RPS reconstruction, unbounded sync, encode QP floor, a
fuzzer-found slice-rewriter shift) are fixes to code paths that either do not
exist upstream or exist only in PoC form, so they are fork-only by
construction, not withheld improvements. If upstream ever revives, VA-1's
issue is the re-entry point and this decision is reopened there.

- Evidence: [findings/2026-07-21-rockchip-vaapi-driver-review.md](../../findings/2026-07-21-rockchip-vaapi-driver-review.md), [findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md](../../findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md), [status.md](../../status.md), [docs/status-ledger.md](../../docs/status-ledger.md)
- Coupled with: VA-1

### VA-3 — Firefox RDD sandbox broker/seccomp policy

Highest-value item on this track and the only one blocking a user-visible
capability for an entire browser: VA-API is Firefox's only native hardware
route on Rockchip, so this policy change is what turns the driver into
working Firefox decode without disabling the RDD sandbox. The patch keeps the
sandbox enabled, adds paths only when the node exists, and permits only
measured ioctl requests, pinning both preimages by SHA-256 — but the repo
holds source-inspection and a measured trace only, with the Firefox sandbox
row explicitly untouched as of 2026-07-28. Submitting on source inspection
alone invites a reviewer to close it as unvalidated; Mozilla may also resist
vendor-specific device policy for an out-of-tree driver with no distro
presence, which is a further reason VA-1 lands first.

- Evidence: [findings/2026-07-26-firefox-rdd-rockchip-vaapi-policy.md](../../findings/2026-07-26-firefox-rdd-rockchip-vaapi-policy.md), [findings/2026-07-26-firefox-rdd-package-build-checkpoint.md](../../findings/2026-07-26-firefox-rdd-package-build-checkpoint.md), [findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md](../../findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md), [findings/2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md](../../findings/2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md), [README.md](README.md)
- Coupled with: VA-1, VA-4

### VA-4 — Carry the RDD sandbox patch in the distro Firefox package

The mechanical work is done — the patch is in Debian format, applied and
partly compiled against the exact `152.0.6+build1-0ubuntu0.26.04.1~mt1`
source on 2026-07-26 — but a distro is the wrong first target for a
sandbox-policy change: relaxing seccomp and the broker in a shipped browser
for an out-of-tree driver is exactly what a distro security team defers to
upstream, and it benefits only boards with `/dev/mpp_service`. The honest
interim path is carrying it in this project's own PPA, which is not an
external submission. Revisit once VA-3 resolves; if Mozilla lands it, this
item collapses to nothing.

- Evidence: [findings/2026-07-26-firefox-rdd-package-build-checkpoint.md](../../findings/2026-07-26-firefox-rdd-package-build-checkpoint.md), [findings/2026-07-26-firefox-rdd-rockchip-vaapi-policy.md](../../findings/2026-07-26-firefox-rdd-rockchip-vaapi-policy.md), [packaging/userspace-patches.md](../../packaging/userspace-patches.md), [status.md](../../status.md)
- Coupled with: VA-3

### VA-5 — GStreamer va plugin vendor allowlist

A genuine, small upstream unit that would retire a user-visible papercut:
every GStreamer consumer currently needs `GST_VA_ALL_DRIVERS=1` to see the
hardware at all. Byte-exact system-memory readback is measured for pinned
H.264 High, VP9 Profile 0, VP9 Profile 2 and HEVC Main10, and `vah264enc`
produced High-profile output at 48.644034 dB — but an allowlist entry is a
statement about a shipped driver's general fitness, and the two things
upstream would check (that the driver is obtainable, and that the display
path works, not just readback) are exactly the open boundaries; a fakesink
probe correctly failed for lack of `GstVideoMeta`. Unripe rather than wrong;
revisit after the driver package is published and a real display sink is
exercised.

- Evidence: [findings/2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md](../../findings/2026-07-26-rockchip-vaapi-main10-afbc-p010-validation.md), [findings/2026-07-26-rockchip-vaapi-h264-va-encode-validation.md](../../findings/2026-07-26-rockchip-vaapi-h264-va-encode-validation.md), [findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md](../../findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md), [status.md](../../status.md)
- Coupled with: VA-1

### VA-6 — Chromium GL context failure on Mali-G610/Panfrost

Report-worthy and squarely in browser-enablement scope, but not yet a
submission: the record is one observed symptom (ANGLE "Could not create a
backing OpenGL context" under both X11 and Wayland, no GPU process) with an
explicit non-attribution — it rules out the VA layer and the session, not
Chromium or Panfrost. Filing against the wrong project wastes the report.
Priority is low because Chromium, unlike Firefox, has alternative routes on
this hardware (mainline V4L2 stateless, or the `libv4l-rkmpp` shim), so this
blocker does not gate the track's headline capability.

- Evidence: [findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md](../../findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md), [findings/2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md](../../findings/2026-07-21-mainline-v4l2-vs-vaapi-browser-decode-landscape.md), [docs/app-enablement.md](../../docs/app-enablement.md), [status.md](../../status.md)

### VA-8 — VLC fallback is not a VLC bug

Recorded so the falsification is not re-litigated. Two successive
explanations for VLC's fallback were both wrong about VLC: a 2026-07-26
finding attributed it to the headless dummy video output never supplying a
VA decoder device, which was only half the story. The actual cause was on
our side — `vaDeriveImage` and `vaAcquireBufferHandle` were unimplemented, so
VLC's OpenGL VA-API converter could not bind and VLC dropped the hardware
module after already creating 38 surfaces through this driver. Implementing
both over the surface's own DMA-BUF closed it; stock, unpatched VLC 3.0.23
now hardware-decodes H.264 High and HEVC Main. Nothing is owed to VideoLAN;
the fix is in the fork and is covered by VA-1/VA-2.

- Evidence: [findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md](../../findings/2026-07-28-vaapi-shipping-stack-gates-hevc-main-and-vlc-firefox-decode.md), [findings/2026-07-26-vlc-headless-vaapi-device-boundary.md](../../findings/2026-07-26-vlc-headless-vaapi-device-boundary.md), [README.md](README.md)
