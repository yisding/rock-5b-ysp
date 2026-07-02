# STATUS — project-wide scoreboard (dated)

Whole-project state at a glance. [kernel status](./kernel-drivers/docs/status.md) stays the deep
scorecard for the *kernel port*; this page rolls up **every** track.

**How to read it.** Every row carries a **last-verified date** — trust a row
only as of its date. Facts that can go stale *silently* (external PRs/MRs,
distro versions, un-pushed dev-box state) are concentrated in the
[watchlist](#watchlist--facts-that-go-stale-silently) so routine maintenance
means re-checking one list. Update rule: the
[resyncing guide §6](./kernel-drivers/docs/resyncing.md) update-propagation table names this page
whenever a gate changes; keep dates honest (re-verify, don't re-date).

## Scoreboard

| # | Track | State | Last verified | Canonical detail |
|---|-------|-------|---------------|------------------|
| 1 | **Kernel forward-port** (combined `=y` kernel) | ✅ **Hardware-validated**: H.264/H.265 encode + decode + full HW transcode on build `Pb6ab-Cb831`, kernel 6.18.37-current-rockchip64 #7. Tests re-run on the board 2026-07-01 (decode 1470/3765 fps; encoder + transcode paths re-exercised). | 2026-07-01 | [kernel status](./kernel-drivers/docs/status.md), [`kernel-drivers/tests/README.md`](./kernel-drivers/tests/README.md) § Observed results |
| 2 | **BSP-audit fix series** ([`kernel-drivers/patches/cleanup-split/`](./kernel-drivers/patches/cleanup-split/README.md)) | ⚠️ **Staged, not shippable yet.** 65 mailbox patches; `git am` onto the forward-port tip is clean. The initial drop (`aa859ad`) was byte-identical to the adversarially-verified draft aggregate, but the `808f7cb` regeneration **diverges in 8 files** (deliberate strengthenings, *not* covered by the adversarial verification) and the current series **does not compile** — patch 0024 calls `rkvenc2_free_rcbbuf()` before its definition (one-line forward-declaration shim verified 2026-07-01; TODO: regenerate 0024). Runtime gate: see warning below. | 2026-07-01 | [`kernel-drivers/patches/cleanup-split/README.md`](./kernel-drivers/patches/cleanup-split/README.md) § History; findings: [BSP audit](./kernel-drivers/docs/bsp-audit.md) |
| 3 | **DKMS channel** ([`packaging/dkms/`](packaging/dkms/README.md)) | ⚠️ Compiles + links on **6.18 only** ("6.18 → 7.2" is intended, untested); the boot DT overlay is **dtc-validated, not boot-validated**. Mutually exclusive with track 1's kernel. | 2026-07-01 | [`packaging/dkms/README.md`](packaging/dkms/README.md) |
| 4 | **Clean-room rewrite drivers** (`mpp-rewrite`/`rga-rewrite`) | 🚧 Bring-up: builds pass on 6.18 + mainline-master worktrees (incl. KUnit compile gates); ABI ledgers written. **No hardware-validation record**; exists **only as dev-box local commit `981a832452454a`** — not pushed anywhere public (single point of failure). | 2026-07-01 | [rewrite-driver track](./kernel-drivers/docs/rewrite-drivers.md) §6 |
| 5 | **ffmpeg — which tree is current** | The rebased **`github.com/yisding/ffmpeg-rockchip-81`** (branch `main`, tip `b59509b609`, 2026-07-01) is current; the documented `40c412dacc` nyanmisaka tip is preserved as `backup-pre-upgrade-master`. The 9 review-fix commits are exported in-repo as [`ffmpeg/patches/`](ffmpeg/patches/README.md). Note: the fixed tree is **not** what is installed/built on the board ([`ffmpeg/docs/rebase-notes.md`](./ffmpeg/docs/rebase-notes.md) §3). | 2026-07-01 | [`ffmpeg/docs/rebase-notes.md`](./ffmpeg/docs/rebase-notes.md), [`ffmpeg/docs/fix-candidates.md`](./ffmpeg/docs/fix-candidates.md) |
| 6 | **ffmpeg submissions** | ❌ **Nothing sent anywhere** — neither the nyanmisaka backport series nor the two FFmpeg-upstreamable V4L2 fixes. | 2026-07-01 | [`ffmpeg/docs/rebase-notes.md`](./ffmpeg/docs/rebase-notes.md) §6 (per-item ledger) |
| 7 | **GNOME Remote Desktop backend** | ✅ 7-patch series applies on pristine GRD 50.1; HW path **sustains 60 fps** vsync-bound, MPP encode 1.26 ms median. ⏸️ The handover-reconnect fix (`a3a1a32`) is parked on the fork branch `rdp-handover-reconnect` **awaiting upstream submission** (no MR exists yet). | 2026-07-01 | [`gnome-remote-desktop/docs/profiling.md`](./gnome-remote-desktop/docs/profiling.md), [`gnome-remote-desktop/patches/README.md`](gnome-remote-desktop/patches/README.md) |
| 8 | **Mesa / Panfrost (Mali-G610)** | 🔄 COMPUTE-only was rejected in review (cannot write AFBC). **On-device verification 2026-07-01 selected the `gl_FragCoord` u_blitter fix** (`panfrost-transfer-fragcoord-blit`, `2f6e8a6afcc`) and **disqualified the targeted integer fallback** — the drift also corrupts non-integer format changes (`RG32F` readback 96.1% corrupt through its gate). Constant-varying/offset probes cleared the fragcoord design risks; **Pushed 2026-07-01 as a 3-MR stack**: !42563 (reviewed unbind fix), [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613) (u_blitter fragcoord fix + BLIT enablement), [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614) (gallium blit test). `textureQueryLevels` commit `a59b9dfcac1` pushed to `yisding/mesa` branch `panfrost-texture-blit`. | 2026-07-01 | [`mesa-panfrost-g610/README.md`](mesa-panfrost-g610/README.md) § Status |
| 9 | **Launchpad PPA (userspace stack)** | ⚠️ **Full local arm64 binary builds succeeded 2026-06-30** (ffmpeg: complete 25-artifact set, but `nocheck`/`noextra` — FATE and the `-extra` flavour untested locally; mpp + librga encode-tested). **Nothing `dput`**; the five `debian/` trees still live only in dev-box `~/Code/grd-ppa` (import plan pending). | 2026-07-01 | [`packaging/ppa/README.md`](packaging/ppa/README.md) § Status |
| 10 | **Binary publishing** | No built binaries in git (policy enforced); **no GitHub Releases published yet** (TODO when the first release is cut). | 2026-07-01 | [`packaging/README.md`](packaging/README.md) § Binary policy |

> **⚠️ Runtime gate PENDING** — the runtime codec regression test (encode/decode/transcode plus the targeted triggers listed in `kernel-drivers/patches/cleanup-draft/verification.md`) has **never been run** on a kernel carrying these fixes. Compile status alone is not verification. Do not ship the series without the runtime gate; track it in `status.md` and record the result in `kernel-drivers/patches/cleanup-draft/verification.md` when run.
>
> *(This warning travels verbatim with every promotion of `kernel-drivers/patches/cleanup-split/`; the result placeholder is in [`kernel-drivers/patches/cleanup-draft/verification.md`](./kernel-drivers/patches/cleanup-draft/verification.md).)*

## Watchlist — facts that go stale silently

Re-check these on any maintenance pass; each row records the last time anyone
looked.

| Watch item | Why it matters | Last checked | State then |
|------------|----------------|--------------|------------|
| Armbian `media-0001` drift (node labels, av1d `@@` anchor) | DT patch 02 converts its nodes in place — a change breaks the build or the decoder DT | 2026-07-01 (running kernel derives from it) | Assumptions hold on `rockchip64-6.18`; checklist: [resyncing guide §4](./kernel-drivers/docs/resyncing.md) |
| [armbian/build#10085](https://github.com/armbian/build/pull/10085) (udev rule upstreaming) | If merged, stock Armbian ships the rule and `codec-udev` becomes optional | 2026-07-01 | Open/merged state **UNVERIFIED** (not re-checked against GitHub) |
| Ubuntu ffmpeg version on resolute | A future `7:8.1.x` silently supersedes the `+rkmpp` debs | 2026-06-30 | Stock is `7:8.0.1-3ubuntu2`; hold recipe: [`packaging/README.md`](packaging/README.md) |
| Mesa MR stack [!42563](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42563) / [!42613](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42613) / [!42614](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/42614) (+ superseded [!38433](https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/38433)) | Review feedback / CI results / merge state drive next steps | 2026-07-01 | All three `opened` (created/updated 2026-07-01 via authenticated `glab api`; web UI stays bot-blocked — use `glab api "projects/176/merge_requests/<iid>/notes"`) |
| `ffmpeg-rockchip-81` tip | It moved mid-documentation once already (`1c73bd8e65` → `b59509b609`, 2026-07-01) | 2026-07-01 | `b59509b609`; [`ffmpeg/patches/`](ffmpeg/patches/README.md) snapshots it |
| GRD handover fix upstream MR | Row 7's "awaiting submission" has no artifact to point at yet | 2026-07-01 | Not submitted |
| **Dev-box-only artifacts** (single point of failure) | Loss = unrecoverable: rewrite-driver commit `981a832452454a` (un-pushed), `~/Code/grd-ppa` `debian/` trees, GRD async-PBO/MemFd prototype worktrees, the headless-harness driver script | 2026-07-01 | All still dev-box-only; capture TODOs live in [rewrite-driver track](./kernel-drivers/docs/rewrite-drivers.md) §6, [`packaging/README.md`](packaging/README.md) § Import plan, [`gnome-remote-desktop/docs/baseline.md`](./gnome-remote-desktop/docs/baseline.md) §7, [`gnome-remote-desktop/docs/profiling.md`](./gnome-remote-desktop/docs/profiling.md) §4 |
