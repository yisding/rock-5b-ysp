# rockchip-vaapi now measures green on the shipping stack, HEVC Main ships by default, and VLC and Firefox hardware-decode in a real session

> Scope: `rockchip-vaapi` decode and encode gates re-run on the production-shaped
> stack, HEVC Main promotion out of experimental, and the VLC/Firefox
> application rows of [`docs/app-enablement.md`](../docs/app-enablement.md).
> Supersedes the "nothing has ever been measured on the shipping combination"
> boundary in the [decode-readiness finding](2026-07-28-vaapi-decode-readiness-and-remaining-work.md).
>
> Source: fork `/home/yi/Code/rockchip-vaapi` advanced `main@db5e0f0` →
> `main@5a7b305` (17 commits) on the board; gates run natively; stack identity
> from `uname -r`, `sha256sum /sys/kernel/notes`, and `dpkg -l`.
>
> Date: 2026-07-28
>
> Trust: **MEASURED** (every gate result and stack fingerprint below) /
> **SOURCE-INSPECTED** (the Firefox 153.0 patch rebase) / **UNVERIFIED** (HDR
> display presentation, mpv, Chromium, a patched Firefox build).

> **Follow-up, 2026-07-29:** local `rockchip-vaapi@491533e` now refuses the
> unsupported 64-pixel Main10 geometry at VA context creation and keeps a
> matching pre-submit guard. The focused FFmpeg gate software-decoded all 48
> frames after one refusal, with zero RGA conversion submissions and zero new
> kernel `no core match` messages. See the
> [narrow-AFBC finding](2026-07-29-rga-no-core-match-narrow-afbc-10bit.md).

## Result

The measurement gap that dominated track 14 is closed. Every gate below ran on
the production-shaped kernel with the post-fix MPP — not the KASAN kernel, and
not the pre-fix parser.

**Stack under test**

| Layer | Identity |
|---|---|
| Kernel | `6.18.40-ysp-rockchip64`, notes `db18acdd…900c`, package `6.18.40+rk3588av1fwport20260725-0ubuntu1~rk2` |
| KASAN / DMABUF_DEBUG | `CONFIG_KASAN` unset, `# CONFIG_DMABUF_DEBUG is not set` |
| MPP | `librockchip-mpp1 1.5.0+git20260727.d8c6b88a+ds-0ubuntu1~rk1` (the **Published** same-ID PPS fix, installed) |
| librga | `librga2 2.2.0+git20260725.26a50ef-0ubuntu1~rk1` (`rga_api 1.10.6`) |
| libva | `libva2 2.23.0-1ubuntu1` |
| Driver under test | fork working tree `main@5a7b305` via `LIBVA_DRIVERS_PATH`, **not** the installed `rockchip-vaapi 1.0.11+ysp1` deb from 2026-07-21 |

**HEVC Main is now a default-advertised profile.** `mpp@d8c6b88a` being
installed removed the `errinfo=1` on `TILES_A_Cisco_2.bit`:
`make check-hevc-tiles-backend` passes the known-good control, the full
100-frame vector, and the reduced two-picture same-ID PPS core. The pinned gate
is 8/8 byte-exact, deterministic across three runs, and green with the complete
ASan/UBSan driver. Evidence was then widened from 8 vectors to **all 163 HEVC
Main candidates in the FFmpeg FATE conformance suite**: 142 byte-exact, **zero
driver failures**, pinned by class and re-runnable as
`make check-hevc-conformance-sweep`.

**VLC hardware-decodes.** The [earlier VLC result](../docs/app-enablement.md)
attributed the fallback to the headless session. With a real GNOME session that
was only half the story: `vaDeriveImage` and `vaAcquireBufferHandle` were
unimplemented in the driver, so VLC's OpenGL VA-API converter could not bind and
VLC dropped its hardware decoder module *after* creating 38 surfaces through
this driver. Implementing both over the surface's own DMA-BUF closed it. Stock
VLC 3.0.23 now logs `using hw decoder module "vaapi"` and `Using Rockchip MPP
VA-API Driver 0.1 for hardware decoding` for H.264 High and HEVC Main.

**Firefox hardware-decodes**, H.264 and HEVC, 677/672 external-pool frames with
1350/1340 DMA-BUF exports and no driver error markers — with
`MOZ_DISABLE_RDD_SANDBOX=1`, so this is the decode/export row and not the
sandbox row.

### Driver defects this exposed and fixed

The wide sweep and the two application gates found six real defects, all of
which had been invisible to the previous 8-vector evidence:

| Defect | Symptom |
|---|---|
| Per-picture buffer list capped at 64 | Legal many-slice streams returned `MAX_NUM_EXCEEDED` |
| Teardown cancelled in-flight decodes | Intermittent wrong frames (3 of 6 runs) when an app destroys a context on a sequence change and then syncs surfaces it was still filling |
| Fixed 24-frame decode pool | **Hard deadlock**: frame-threaded FFmpeg held 29 surfaces, MPP waited forever for a free buffer, the process hung until killed |
| Long-term RPS rebuilt instead of reproduced | 45 of 300 frames wrong on `RPS_E_qualcomm_5` — `ReferenceFrames[]` carries no ordering, and RefPicSetLtCurr order decides the initial reference list |
| `vaSyncSurface` had no watchdog | A backend that stops responding hung the calling media process indefinitely |
| `init_qp_minus26` bounded at −26 | The 8-bit range; the floor is −(26 + QpBdOffsetY), so legal Main10 streams were rejected as unreconstructable |

A libFuzzer gate over the H.264/HEVC/VP9 reconstructors additionally found an
out-of-range shift in the HEVC slice rewriter, which had trusted an earlier
parameter-set call to have bounded the picture parameters.

### A stale audit invalidates earlier soak evidence

`check-soak`, `check-zero-copy` and `check-concurrent-decode` counted frames by
matching the literal string `zero_copy=1 external=1`. That string stopped
appearing on 2026-07-25 when `converted_10bit` was inserted between those two
fields. The gates failed closed rather than passing wrongly, so **none of them
can have passed since that date** — including the multi-hour soak whose numbers
the roadmap records. With the audit repaired, an 1,800 s paced 4K soak completed
54,005 external frames with post-warmup RSS moving 164,876 → 165,344 KiB (a
468 KiB span, against 47,844 KiB in the previously recorded run) and fd
head/tail medians both 54.

## Boundary

- **The shipping artifact is still stale.** Every result above used the fork
  build through `LIBVA_DRIVERS_PATH`. The installed package is
  `rockchip-vaapi 1.0.11+ysp1` from 2026-07-21. A `1.0.11+ysp4` changelog entry
  exists and both debs build, Lintian-clean, and pass the isolated-root
  install/upgrade/purge gate — but they are not installed, and no result here
  is evidence about the installed driver.
- **Phase-1 soak duration is not met.** 1,800 s is a smoke run; the exit
  criterion is 7,200 s.
- **HEVC Main10 stays hidden.** 10 of 11 FATE Main10 vectors are byte-exact.
  `WPP_D_ericsson_MAIN10_2.bit` at 64×240 fails because no RGA core can take an
  AFBC 10-bit job that narrow — root-caused in
  [the no-core-match finding](2026-07-29-rga-no-core-match-narrow-afbc-10bit.md);
  the 2026-07-29 source fix now refuses it at context creation and verifies
  complete software fallback without an RGA submission. 10-bit throughput is
  unmeasured and HDR display presentation is unvalidated.
- **Two FATE Main streams remain undecodable** — `NUT_A_ericsson_4/5`, which
  direct MPP also cannot decode. Two more (`PICSIZE_A/B_Bossen_1`, 1056×8440 and
  8440×1056) are correctly refused against the advertised 7680×4320 constraint.
- **The Firefox sandbox row is untouched.** The RDD patch was rebased onto
  `FIREFOX_153_0_RELEASE` and verified to apply and to produce sources
  byte-identical to applying the 152.0.6 patch, and 153.0 was confirmed not to
  permit those paths already — but no patched Firefox was built, and the ioctl
  set is inherited from the 2026-07-26 measurement rather than remeasured.
- **Chromium is blocked outside this layer.** Chromium 150 cannot initialize a
  GL context on Mali-G610/Panfrost under either X11 or Wayland (ANGLE: "Could
  not create a backing OpenGL context"), so its GPU process never starts and no
  VA-API path is reachable. VLC and Firefox run accelerated GL in the same
  session, so this is not a driver or session fault. **mpv is not installed**,
  and the two-peer WebRTC gate cannot run without
  `gir1.2-gst-plugins-bad-1.0`.

## Verification gate

Package the post-`1.0.11+ysp4` source including `rockchip-vaapi@491533e`,
install it, then re-run
`make check-safe`, `make check-hevc`, `tests/check-vlc-display.sh` and
`tests/check-firefox-decode.sh` against the *installed*
`/usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so` with no
`LIBVA_DRIVERS_PATH` override. That converts every result above from
"the fork builds and works" into "the shipped package works".

## Why it matters

Track 14's headline caveat — that no gate had ever run on the combination that
would actually ship — no longer holds for the driver itself. The remaining
distance to a user-visible capability is now an **install**, not a build, a
codec, or a confirmation run. It also revises two earlier conclusions: VLC's
fallback was a driver gap rather than purely a session gap, and the soak
evidence recorded for Phase 1 has not been reproducible since 2026-07-25.
