# rockchip-vaapi decode is codec-complete except AV1; the remaining work is deployment, one confirmation run, promotion, and browser integration

> Scope: `rockchip-vaapi` decode readiness (H.264, VP9 Profile 0/2, HEVC
> Main/Main10 — **AV1 excluded**), and the 2026-07-28 build of the fork at
> `main@db5e0f0`. Answers "how much work is left to get the decode side
> working".
>
> Source: fork `/home/yi/Code/rockchip-vaapi` at `main@db5e0f0` (remote `fork` =
> `yisding/rockchip-vaapi`, matching); native build and unit gates run on the
> board; `dpkg -l` for installed userspace; Launchpad API for PPA states;
> [`video-libraries/vaapi/README.md`](../video-libraries/vaapi/README.md)
> capability matrix and Next gate; [`docs/app-enablement.md`](../docs/app-enablement.md)
> per-application rows; [Firefox packaging checkpoint](2026-07-26-firefox-rdd-package-build-checkpoint.md).
>
> Date: 2026-07-28
>
> Trust: **MEASURED** (build, unit gates, installed/published versions) /
> **SOURCE-INSPECTED** / **DESIGN** (the effort estimates and tiering).

## Result

**No decode codec work remains for anything except AV1.** H.264 and VP9
Profile 0 are default-exposed with conformance and sanitizer coverage; HEVC
Main is 8/8 byte-exact against pinned official vectors; HEVC Main10 and VP9
Profile 2 are byte-exact P010 through MPP AFBC V2 plus RGA. What is left is
**deployment, one confirmation run, promotion out of experimental, and getting
an application to consume it** — engineering effort concentrated almost entirely
in the last of those.

The single most important fact for planning: **nothing has ever been measured on
the stack you would ship.** Every July gate ran on
`6.18.40-video-port-kasan-rockchip-rk3588` with the pre-fix MPP, against a
driver build that is now a week and ~50 commits stale.

## Build record, 2026-07-28

Fork `main@db5e0f0`, built natively on the board with
`PATH=/usr/sbin:/usr/bin:/sbin:/bin` per [`AGENTS.md`](../AGENTS.md) so
`/usr/bin/pkg-config` drives it rather than Linuxbrew's.

- **Compile: clean.** `-Wall -Wextra -Werror`, zero warnings, 14 objects into
  `rockchip_drv_video.so`. Resolved against libva 1.23.0, rockchip_mpp 1.3.10,
  librga 2.1.0.
- **Unit gates: 6/6 pass** — object heap, frame layout, H.264 reconstruction,
  HEVC reconstruction, VP9 header, logging.
- **Packages built** (`dpkg-buildpackage -b -us -uc`), version `1.0.11+ysp3`,
  whose changelog entry was last touched in `db5e0f0` itself, so the version is
  current for the tree rather than stale:

  | package | size | ships |
  |---|---|---|
  | `rockchip-vaapi_1.0.11+ysp3_arm64.deb` | 83 KB | `/usr/lib/aarch64-linux-gnu/dri/rockchip_drv_video.so` |
  | `rockchip-vaapi-config_1.0.11+ysp3_all.deb` | 9.7 KB | `/etc/environment.d/61-rockchip-vaapi.conf`, `/etc/profile.d/rockchip-vaapi-config.sh` |
  | `rockchip-vaapi-dbgsym_…ddeb` | 201 KB | detached symbols |

Working tree at build time also carried uncommitted additions: a `Makefile`
fuzz-target block (purely additive — `FUZZ_*` variables and three rules; the
driver build path is untouched) and three untracked harnesses
`tests/{h264,hevc,vp9}_fuzz.c`. They require `clang` and libFuzzer and were not
built or run.

**Dependency note worth acting on:** the driver package declares
`librockchip-mpp1 (>= 1.5.0+git20260529.1375813c+ds)`. That is satisfied by the
*old* MPP already installed, so installing this driver does **not** pull the
published HEVC TILES fix. That upgrade stays a separate, explicit step.

## The deployment gap

| component | built / published | installed on the board | gap |
|---|---|---|---|
| rockchip-vaapi | `1.0.11+ysp3` @ `db5e0f0` (built today) | `1.0.11+ysp1`, `.so` dated 2026-07-21 | ~50 commits: all of Phase 0/1, both encode paths, TILES reducer, P010 import boundary |
| librockchip-mpp | `1.5.0+git20260727.d8c6b88a` **Published** 2026-07-28 | `1.5.0+git20260529.1375813c` | the HEVC same-ID PPS / TILES fix |
| librga | `2.2.0+git20260725.26a50ef` Published | same | **none — current** |
| kernel | `…-0ubuntu1~rk2` building | `~rk1` published; board booted on `video-port` | `DMABUF_DEBUG` still set on `~rk1` |

## Remaining work

### Tier 0 — refresh the stack · ~1 hour, mostly waiting

`apt upgrade` MPP to `d8c6b88a` (this alone retires the HEVC Main boundary),
install the `ysp3` packages built above, boot `~rk2`. librga needs nothing.

`~rk2` is not optional: the driver calls `DMA_BUF_IOCTL_SYNC` directly
(`src/surface.c:26`, `src/buffer.c:27`), the ioctl that reaches
`system_heap_dma_buf_end_cpu_access()` where a `DMABUF_DEBUG=y` kernel
[oopses deterministically](2026-07-28-dmabuf-debug-mangle-sg-table-is-the-sg-writer.md).

### Tier 1 — confirmation run on the shipping stack · ~half a day

Re-run the existing decode gates on production kernel + published MPP + `ysp3`
driver. The harnesses exist in the fork's `tests/`, so this is execution, not
authorship. Until it runs, "decode works" is an inference across three
components that have never been in the same room.

### Tier 2 — promote out of experimental · small, gated on Tier 1

HEVC Main, HEVC Main10 and VP9 Profile 2 are byte-exact but hidden behind
environment opt-ins. Flipping them to default is a small driver change plus the
capability-matrix update.

### Tier 3 — application integration · the real remaining work

| app | estimate | basis |
|---|---|---|
| **VLC** | **hours** | Modules already installed and selected; the only recorded blocker is the dummy headless vout providing no decoder device, so it falls back before loading the driver. Needs a real Wayland/X11/DRM session. `app-enablement.md` states patching is "not yet shown necessary". |
| **mpv** | hours | Cheapest end-to-end display proof, but it rides libavcodec + DRM PRIME, **not** VA-API — it validates the display path, not this driver. Useful to separate "display broken" from "driver broken". |
| **Firefox** | **days** | The project's declared next gate. The package build stopped 31 minutes in during Cargo `toolkit/library` — *not* on an error, so it is resumable, but multi-hour on this board. Then the five-part live gate: RDD sandbox still enabled, driver load markers, MPP/RGA access confined to the pinned broker/ioctl policy, real display path, and software fallback tested separately rather than counted as a pass. |
| **Chromium** | **unknown: hours to weeks** | `app-enablement.md` says try the stock deb with runtime flags first and let measured blockers decide. Downside branch is a multi-week `libv4l-rkmpp` re-target with permanent custom builds, or maxline stateless V4L2. |

### Summary

- Decode **proven on the shipping stack**: ~1 day (Tiers 0–2, mechanical).
- Decode **working in a browser**: days for Firefox, compile-dominated.
- **Chromium is the only open-ended item** and the largest schedule risk on the
  track.

## Risks and unknowns

1. **Firefox RDD sandbox policy has never been runtime-tested.** The patch is
   source-hash-pinned into the exact Ubuntu source but no binary has ever run.
   This is the biggest technical unknown, distinct from the compile time.
2. **Chromium is unbounded** until someone runs the stock deb with flags.
3. **The whole stack is unvalidated in combination.** Three components each
   moved independently; the July evidence pairs none of the current versions.
4. **AV1 remains out of scope** by design — a separate backend with the VA-to-MPP
   reconstruction unimplemented. `f30490b` plans it and `4d98eca` adds a bounded
   capability probe, but no decode path exists.

## Boundary

- No runtime capability check was performed. `vainfo` is not installed
  (`libva-utils` absent) and installing it needs root, so the freshly built
  driver has **not** been exercised at all — only compiled and unit-tested.
- The `ysp3` packages are built but **not installed**; the board still runs
  `ysp1`.
- Every effort estimate is **DESIGN**, derived from recorded state, not from
  timed attempts. The Firefox figure inherits whatever remains of a compile that
  was stopped once already.
- The claim that this driver would fault on a `DMABUF_DEBUG=y` kernel is a
  strong expectation from the shared ioctl and heap, not a measured result for
  the VA-API path.
- Fuzz harnesses were neither built nor run.

## Next action

Tier 0, in order: upgrade MPP, install `ysp3`, boot `~rk2`. Then the Tier 1
confirmation run before any promotion or browser work — it is the cheapest step
that converts three independent inferences into one measurement.
